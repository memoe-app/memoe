#!/usr/bin/env python3
"""Who is actually holding each chat app — asked of the provider, not of us.

  channel-holder.py check     ask each provider where it sends, and record it
  channel-holder.py heal      …and put one back that has drifted (bounded)
  channel-holder.py say       the sentences only, for a screen

**The failure this exists for, measured on the owner's account 2026-09-14.**
Their cloud machine was paired at 01:17Z. `channels.py migrate` did its job:
the edge took the Telegram app, `setWebhook` pointed the bot at it, and this
Mac wrote `cloud/channel-telegram.json`. But this Mac's gateway was still
polling with `getUpdates`, and Telegram permits a webhook OR polling and never
both. Telegram refused the poll — `can't use getUpdates method while webhook
is active` — and the adapter "recovered" by calling `deleteWebhook`. That
webhook was the edge's. From then on the machine they pay for could not
receive one message, `channel_bindings` stayed empty, and **both halves went
on reporting themselves connected**, because each was reading its own config.

Three opinions exist about a channel and only one of them decides:

  * `MOE_HOME/cloud/channel-<name>.json`  — what this Mac believes
  * `moe_auth.channel_apps` at the edge   — what the edge believes
  * the provider                          — where the messages actually go

This asks the third one, and what "asking" means differs by channel.
`getWebhookInfo` for Telegram and the webhook endpoint read for LINE — both
name an address. Slack and Discord name none: the edge opens a connection
outwards to them and holds it, so what decides is whether the platform took
that connection, which only the edge knows (`GET /v1/channels/<name>/socket`).
WhatsApp Business is the one left that a person points by hand in a dashboard,
and it has no read-back at all — so it is reported as *unknown* rather than
guessed at. An answer invented for a channel that cannot be asked would be the
same lie in a new place.

**Nothing here prints a bot token, a webhook path or a device credential.** The
token is in the URL of every Telegram call, so no URL is ever logged; a webhook
address is compared and reported as *ours* or *somewhere else*, never quoted.

**Repair is bounded and it goes through `channels.py`.** Re-pointing a webhook
channel needs the shared secret the edge verifies it with, which this Mac
deliberately does not keep — so the repair is `channels.py register <channel>`,
which mints a new secret, hands it to the edge and points the provider at the
result in one step. For a socket channel there is no address to re-point and
the repair is `channels.py socket <channel>`, which hands the keys over again
and waits for the platform to confirm. At most `MAX_REPAIRS` of either per
channel, never twice inside `REPAIR_COOLDOWN_S`, and the counter resets the
moment a check finds the channel carrying again. A self-heal with no ceiling
is a loop that bills somebody.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 15

#: How many times Moe will re-point one provider before it stops and asks the
#: person. Three, and then a sentence: a repair that has failed three times is
#: not a transient, and trying for ever would hide it.
MAX_REPAIRS = 3
#: And never twice inside ten minutes **while something else is holding the
#: channel** — `elsewhere`. The job runs every fifteen, but `heal` is also run
#: straight after a migration, and two repairs in one minute would re-mint the
#: webhook secret under a message in flight. Re-pointing a provider that is
#: already pointed somewhere is a tug-of-war with whoever pointed it, and ten
#: minutes between pulls is what stops that becoming a loop.
REPAIR_COOLDOWN_S = 600
#: **And a minute, not ten, when the channel is pointed NOWHERE.**
#:
#: Measured on the owner's Mac 2026-09-14. `heal` diagnosed it exactly —
#: *"Telegram is not sending your messages anywhere"* — and then refused with
#: *"waiting — it was repaired less than 10 minutes ago"*, leaving the channel
#: dead for the rest of the window. The cooldown above protects a message in
#: flight and a contested channel; a channel pointed at no address has neither.
#: There is nothing a wait can improve and nobody to tug against, so waiting
#: is purely time in which nothing reaches the person.
#:
#: Not zero, because a caller in a loop must not be able to hammer a provider:
#: a minute is far below the fifteen-minute job and far above a hot loop, and
#: `MAX_REPAIRS` still caps the total at three either way.
DEAD_REPAIR_MIN_S = 60

#: The channels whose provider can be asked where it sends over its own API.
#: WhatsApp Business is the only one left that a person points by hand in a
#: dashboard, and it has no read-back — CHANNELS-CONNECTORS-DECISIONS §5c.
ASKABLE = ("telegram", "line")

#: The channels the edge reaches over a socket it opens outwards, where
#: "where does the provider send" is not a question with an address for an
#: answer. What decides for these is whether the platform accepted the
#: connection — Slack's `hello`, Discord's `READY` — which the edge knows and
#: this Mac does not. Spelled here rather than imported at module scope so
#: this file still runs when `channels.py` is absent; `_channels()` is the
#: one place that loads it.
SOCKET_CHANNELS = ("slack", "discord")


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def vault():
    return os.environ.get("MOE_CLOUD_VAULT") or os.path.join(moe_home(), "cloud")


def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def state_path():
    return os.path.join(vault(), "channel-holder.json")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def write_json(path, obj):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(obj, fh)
        os.replace(tmp, path)
    except OSError as exc:
        print("could not record what the providers said: %s" % exc, file=sys.stderr)


def env_value(key):
    """One value out of `.env`. Never printed, by anything here."""
    path = os.path.join(hermes_home(), ".env")
    prefix = key + "="
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("export "):
                    line = line[7:].lstrip()
                if line.startswith(prefix):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def held_by_the_edge():
    """{channel: webhook_url} for every channel this Mac recorded as the
    cloud's. The same marker `channels.py` writes after the edge accepted a
    registration, and `moeledger.relayconfig.edge_holds` reads."""
    out = {}
    for channel in ("telegram", "slack", "discord", "whatsapp", "line"):
        obj = read_json(os.path.join(vault(), "channel-%s.json" % channel))
        if isinstance(obj, dict) and obj.get("webhook_url"):
            out[channel] = str(obj["webhook_url"])
    return out


def _telegram_api_base():
    return (os.environ.get("MOE_TELEGRAM_API_BASE") or "https://api.telegram.org").rstrip("/")


def _line_api_base():
    return (os.environ.get("MOE_LINE_API_BASE") or "https://api.line.me").rstrip("/")


def _get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {}, method="GET")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as answer:
        return json.loads(answer.read() or b"{}")


#: How recently a delivery must have failed for the address to be called
#: broken rather than merely once-troubled. Telegram retries hard and reports
#: the LAST failure, so an error from days ago over an empty queue is history,
#: not a fault — but a failure inside this window with messages still waiting
#: is a channel that is not being delivered right now.
FAULT_FRESH_S = 900

#: The provider's own report about a channel, from the call that asked where
#: it sends. Keyed by channel; `provider_endpoint` fills it, `verdict` reads
#: it. Module state rather than a return value so the two callers and every
#: other channel's branch keep their shape.
_FAULTS = {}


def _remember_fault(channel, fault):
    _FAULTS[channel] = fault


def provider_fault(channel):
    """What the provider last said about delivering this channel, or None.

    ``{"error": text, "at": epoch, "pending": n}``. Never the endpoint: for
    Telegram that URL is the bot token.
    """
    return _FAULTS.get(channel)


def failing_now(fault, now=None):
    """True when the provider reports a delivery failure that is still live.

    Both halves matter. A recent error alone can be a blip the provider has
    since got past; a queue alone can be a channel that is merely busy. A
    recent error AND messages still waiting is nothing getting through.
    """
    if not isinstance(fault, dict):
        return False
    error = str(fault.get("error") or "")
    if not error:
        return False
    try:
        at = float(fault.get("at") or 0)
        pending = int(fault.get("pending") or 0)
    except (TypeError, ValueError):
        return False
    now = time.time() if now is None else now
    return pending > 0 and at > 0 and (now - at) < FAULT_FRESH_S


def provider_endpoint(channel):
    """Where the provider says it sends. ``(state, endpoint)``.

    ``state`` is one of ``"ok"`` (it answered), ``"unreachable"`` (it did not),
    ``"unaskable"`` (there is no API for this one), or — for a socket channel
    — ``"down"``, meaning the edge says the platform does not have its
    connection. ``endpoint`` is the URL it named, ``""`` when it named none,
    ``None`` when it did not answer, and for ``"down"`` the edge's reason.

    The Telegram call carries the bot token in its path, so neither the URL nor
    the exception text is ever returned to a caller that prints.
    """
    if channel in SOCKET_CHANNELS:
        # No address to read back: what decides is whether the platform took
        # the connection the EDGE opened, which only the edge can answer.
        return socket_state(channel)
    if channel == "telegram":
        token = env_value("TELEGRAM_BOT_TOKEN")
        if not token:
            return "unaskable", None
        try:
            said = _get("%s/bot%s/getWebhookInfo" % (_telegram_api_base(), token))
        except (urllib.error.URLError, ValueError, OSError):
            # Deliberately not the exception's text: an HTTPError's message
            # can carry the request URL, and that URL is the bot token.
            return "unreachable", None
        if not said.get("ok"):
            return "unreachable", None
        info = said.get("result") or {}
        # The SAME response carries whether the address works. Until
        # 2026-09-20 only `url` was kept and the rest thrown away, so a
        # webhook pointing at a tenant that had been deleted — every delivery
        # answered 401, five of the owner's messages stacked up in Telegram's
        # queue — read here as a clean match and the screen stayed green. An
        # address is not a delivery. The URL itself carries the bot token and
        # never leaves this function; the fault below is the error TEXT and
        # the counts, which do not.
        _remember_fault("telegram", {
            "error": str(info.get("last_error_message") or ""),
            "at": float(info.get("last_error_date") or 0),
            "pending": int(info.get("pending_update_count") or 0),
        })
        return "ok", str(info.get("url") or "")
    if channel == "line":
        token = env_value("LINE_CHANNEL_ACCESS_TOKEN")
        if not token:
            return "unaskable", None
        try:
            said = _get("%s/v2/bot/channel/webhook/endpoint" % _line_api_base(),
                        {"Authorization": "Bearer " + token})
        except (urllib.error.URLError, ValueError, OSError):
            return "unreachable", None
        return "ok", str(said.get("endpoint") or "")
    return "unaskable", None


def _channels():
    """`channels.py` as a module, or None.

    Loaded by path rather than copied from: it owns the edge address, the
    device credential and the HTTP shape, and a second implementation of
    those here is a second thing to keep in step. Guarded because this script
    is useful (and must not crash) on a Mac where the payload is partial.
    """
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "channels.py")
    if not os.path.isfile(path):
        return None
    try:
        import importlib.util

        spec = importlib.util.spec_from_file_location("moe_channels", path)
        module = importlib.util.module_from_spec(spec)
        written = sys.dont_write_bytecode
        sys.dont_write_bytecode = True      # the payload is shared; see relayconfig
        try:
            spec.loader.exec_module(module)
        finally:
            sys.dont_write_bytecode = written
        return module
    except Exception:      # noqa: BLE001 — a payload we cannot read is not fatal
        return None


def socket_state(channel):
    """``(state, detail)`` for a channel the edge holds over a socket.

    ``state`` is ``"ok"`` when the platform has confirmed the connection,
    ``"down"`` when the edge says it has not, and ``"unreachable"`` when the
    edge could not be asked — which includes **the route not existing yet**.
    That last case matters: the edge half of the socket work lands separately,
    and a 404 from it is not a person's problem and must never be reported as
    their channel being broken.
    """
    module = _channels()
    if module is None:
        return "unreachable", ""
    try:
        status, body = module.call("GET", "/v1/channels/%s/socket" % channel)
    except SystemExit:
        # `channels.py::call` dies on an unreachable edge and `edge()` dies on
        # a Mac that is not enrolled. Neither is this channel being broken.
        return "unreachable", ""
    except Exception:      # noqa: BLE001
        return "unreachable", ""
    if status >= 400:
        return "unreachable", ""
    if (body or {}).get("open"):
        return "ok", ""
    why = (body or {}).get("stopped") or (body or {}).get("last_error") or ""
    return "down", str(why)[:160]


def waiting_to_be_let_in():
    """Who has messaged one of this account's bots and is not let in.

    **Nothing told anybody this was happening.** A knock is a real safety
    feature — a bot anybody can message must not answer anybody — but when one
    exists Moe simply stops replying, and on 2026-09-14 the owner met exactly
    that and concluded their Moe was broken. The edge has had the data all
    along (`GET /v1/channels/knocks`); nothing carried it to a screen.

    Read here, on the fifteen-minute job that already talks to the edge, and
    written into the same file the Connections screen reads offline — so the
    screen stays instant and still tells the truth.

    A list of ``{channel, chat_id, sender, attempts}``, or ``[]``. Never a
    refusal: a Mac that is not enrolled, or an edge that cannot be reached, has
    nobody waiting as far as anyone here can tell, and saying otherwise would
    put a fault on a screen for a question that was never asked.
    """
    module = _channels()
    if module is None:
        return []
    try:
        status, body = module.call("GET", "/v1/channels/knocks")
    except SystemExit:
        return []
    except Exception:      # noqa: BLE001
        return []
    if status >= 400:
        return []
    out = []
    for k in (body or {}).get("knocks") or []:
        if not isinstance(k, dict) or not k.get("channel") or not k.get("chat_id"):
            continue
        out.append({
            "channel": str(k["channel"])[:32],
            "chat_id": str(k["chat_id"])[:64],
            # A STRANGER chose this. One line, capped, and rendered as plain
            # text by whoever draws it — never markup. `cmd_knocks` and
            # `Pairing.parse` apply the same rule.
            "sender": str(k.get("sender") or "").replace("\n", " ")[:60],
            "attempts": int(k.get("attempts") or 1),
        })
    return out


def waiting_sentence(rows, channel=None):
    """One sentence about people waiting, for a person. ``""`` when nobody is.

    **It explains rather than apologises.** A knock is Moe doing its job: the
    bot is reachable by anybody and it does not answer anybody. What was
    missing was not a fix but a sentence, and the action next to it.

    ``channel`` narrows it to one chat app — and the sentence NAMES the chat
    app either way, because nothing here may read as Telegram-shaped when it
    is equally true of the other four.
    """
    rows = [r for r in rows if channel is None or r["channel"] == channel]
    if not rows:
        return ""
    if len(rows) == 1:
        who = rows[0]["sender"] or rows[0]["chat_id"]
        return ("%s messaged Moe on %s and is waiting to be let in. Moe does "
                "not answer anybody who has not been let in, so nothing has "
                "been sent to them. Approve them in Ways to reach Moe."
                % (who, rows[0]["channel"].capitalize()))
    names = ", ".join(sorted({r["channel"].capitalize() for r in rows}))
    return ("%d chats are waiting to be let in (%s). Moe does not answer "
            "anybody who has not been let in, so nothing has been sent to "
            "them. Approve them in Ways to reach Moe."
            % (len(rows), names))


def _origin(url):
    """``https://host`` — safe to print. A webhook path carries an id that is
    part of what makes the address unguessable, so it never appears."""
    try:
        parts = urllib.parse.urlsplit(url)
        return "%s://%s" % (parts.scheme, parts.hostname) if parts.hostname else ""
    except ValueError:
        return ""


def verdict(channel, expected, state, endpoint):
    """``(verdict, sentence)`` for one channel. The sentence is for a person.

    ``verdict`` is ``ours`` / ``nowhere`` / ``elsewhere`` / ``unreachable`` /
    ``unaskable``. Only the middle two are a fault, and only they get a
    sentence: a line that fires on the ordinary case is one people learn to
    scroll past.
    """
    if state == "unaskable":
        return "unaskable", ""
    if state == "unreachable":
        return "unreachable", ""
    if state == "down":
        # A socket channel: there is no address, so "elsewhere" is not a state
        # it can be in. Either the platform has the edge's connection or it
        # does not.
        return "nowhere", (
            "%s is connected to Moe's cloud, but the cloud's connection to %s is "
            "not open%s — so nothing reaches Moe while this Mac is asleep."
            % (channel.capitalize(), channel.capitalize(),
               " (%s)" % endpoint if endpoint else ""))
    if endpoint == expected:
        fault = provider_fault(channel)
        if failing_now(fault):
            # The address is right and nothing is arriving: the cloud is
            # refusing what the provider sends it (a tenant that was deleted
            # gives exactly this). Repointing the bot would not help, so this
            # is NOT one of the states `heal` repairs — it is said, and the
            # Connections row turns amber on the sentence.
            return "failing", (
                "%s is sending your messages to Moe's cloud and the cloud is "
                "refusing them (%s), so nothing is reaching Moe. %d %s waiting."
                % (channel.capitalize(),
                   " ".join(str(fault.get("error") or "").split())[:120],
                   int(fault.get("pending") or 0),
                   "message is" if int(fault.get("pending") or 0) == 1 else "messages are"))
        return "ours", ""
    if not endpoint:
        return "nowhere", (
            "%s is not sending your messages anywhere. Moe's cloud was set up to "
            "receive them, and the bot has since been pointed away from it — so "
            "nothing reaches Moe while this Mac is asleep." % channel.capitalize())
    where = _origin(endpoint)
    return "elsewhere", (
        "%s is sending your messages to %s, which is not Moe's cloud. Moe cannot "
        "answer them from there, and nothing reaches Moe while this Mac is asleep."
        % (channel.capitalize(), where or "somewhere else"))


def repair(channel):
    """Put the channel back, once. ``(done, what happened)``.

    Through `channels.py`, not by calling the provider directly. For a webhook
    channel that is `register`: re-pointing needs the secret the edge verifies
    the webhook with, this Mac does not keep one, and `register` mints a new
    secret, gives it to the edge and points the provider at the result in a
    single step — so the two can never disagree about which secret is current.
    For a socket channel it is `socket`, which hands the edge the keys again
    and waits for the platform to confirm; there is no address to re-point.
    """
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "channels.py")
    if not os.path.isfile(script):
        return False, "channels.py is not installed beside this script"
    verb = ["socket", channel] if channel in SOCKET_CHANNELS \
        else ["register", channel, "--yes"]
    try:
        done = subprocess.run([sys.executable, script] + verb,
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=120)
    except (OSError, subprocess.SubprocessError) as exc:
        return False, "could not run the repair (%s)" % exc.__class__.__name__
    if done.returncode != 0:
        # `register` prints no secret; its refusals are safe to carry, capped.
        text = (done.stdout or b"").decode("utf-8", "replace").strip().splitlines()
        return False, (text[-1][:160] if text else "the repair did not complete")
    return True, "re-pointed at Moe's cloud"


def run(heal=False, quiet=False):
    """Ask every provider, record it, and optionally put one back.

    Exit code is 0 when nothing is wrong or everything wrong was repaired, and
    2 when a channel is still pointing away at the end. Never 1: 1 is what a
    crashed interpreter gives, and this runs unattended.
    """
    expected_by_channel = held_by_the_edge()
    previous = (read_json(state_path()) or {}).get("channels") or {}
    channels, faults = {}, []
    for channel, expected in sorted(expected_by_channel.items()):
        state, endpoint = provider_endpoint(channel)
        outcome, sentence = verdict(channel, expected, state, endpoint)
        was = previous.get(channel) or {}
        repairs = int(was.get("repairs") or 0)
        repaired_at = float(was.get("repaired_at") or 0)
        did = None
        if outcome == "ours":
            # Pointing at us: whatever went wrong before is over, and the
            # budget comes back. Without this a channel that drifted twice
            # months apart would be one drift away from never healing again.
            repairs = 0
        elif heal and outcome in ("nowhere", "elsewhere"):
            if repairs >= MAX_REPAIRS:
                sentence += (" Moe has put it back %d times and it keeps moving, so "
                             "it has stopped trying. Open Settings › Away and connect "
                             "%s again." % (MAX_REPAIRS, channel.capitalize()))
            # **How long to wait depends on what is wrong, and that is the
            # repair.** `nowhere` is a channel receiving nothing at all: no
            # message in flight to protect and nobody holding it, so the ten
            # minutes bought nothing and cost the owner a dead Telegram.
            # `elsewhere` is a channel somebody else is pointed at, which is
            # the case the long bound was written for.
            elif time.time() - repaired_at < (DEAD_REPAIR_MIN_S
                                              if outcome == "nowhere"
                                              else REPAIR_COOLDOWN_S):
                waited = (DEAD_REPAIR_MIN_S if outcome == "nowhere"
                          else REPAIR_COOLDOWN_S)
                did = ("waiting — it was repaired less than %d %s ago"
                       % ((waited // 60, "minutes") if waited >= 120
                          else (waited, "seconds")))
            else:
                done, said = repair(channel)
                repairs += 1
                repaired_at = time.time()
                did = said
                if done:
                    state, endpoint = provider_endpoint(channel)
                    outcome, sentence = verdict(
                        channel, expected_by_channel.get(channel, expected),
                        state, endpoint)
        row = {"holder": "edge", "provider": outcome, "at": int(time.time()),
               "repairs": repairs}
        if repaired_at:
            row["repaired_at"] = repaired_at
        if sentence:
            row["say"] = sentence
        channels[channel] = row
        if outcome in ("nowhere", "elsewhere"):
            faults.append(channel)
        if not quiet:
            if sentence:
                print("✗ %s" % sentence)
            elif outcome == "ours":
                print("✓ %s reaches Moe's cloud, which hands it to whichever Moe "
                      "is awake." % channel.capitalize())
            elif outcome == "unreachable":
                print("… %s could not be asked where it sends right now."
                      % channel.capitalize())
            else:
                print("… %s is pointed by hand in its own dashboard; there is "
                      "nothing to read back, so Moe does not guess."
                      % channel.capitalize())
            if did:
                print("  %s" % did)
    # **Who is waiting to be let in, on every channel.** Asked once, here,
    # because this is already the thing that talks to the edge on a clock; and
    # written into the same file the Connections screen reads offline. A knock
    # is not a fault of the channel's, so it is a key of its own rather than a
    # `say` on a channel row — a channel can be perfectly held and still have
    # somebody standing at the door.
    waiting = waiting_to_be_let_in()
    write_json(state_path(), {"at": int(time.time()), "channels": channels,
                              "waiting": waiting})
    if waiting and not quiet:
        print("• %s" % waiting_sentence(waiting))
    if not expected_by_channel and not quiet:
        print("Moe's cloud carries no chat app for this account — "
              "this Mac holds them all.")
    return 2 if faults else 0


USAGE = "\n".join(line for line in __doc__.split("\n")
                  if line.startswith("  channel-holder.py"))


def cmd_say():
    """The recorded sentences, one per line; nothing when all is well. Reads
    the file only — a screen must not wait on a provider."""
    state = read_json(state_path()) or {}
    for channel, row in sorted((state.get("channels") or {}).items()):
        if row.get("say"):
            print("%s\t%s" % (channel, row["say"]))
    # Per channel, so a screen drawing one chat app's row gets the sentence
    # that belongs to it and the word "Telegram" is never hard-coded anywhere.
    waiting = state.get("waiting") or []
    for channel in sorted({r.get("channel") for r in waiting if r.get("channel")}):
        said = waiting_sentence(waiting, channel=channel)
        if said:
            print("%s\twaiting\t%s" % (channel, said))
    return 0


def main(argv):
    verb = argv[0] if argv else "check"
    quiet = "--quiet" in argv
    if verb == "check":
        return run(heal=False, quiet=quiet)
    if verb == "heal":
        return run(heal=True, quiet=quiet)
    if verb == "say":
        return cmd_say()
    print(USAGE)
    return 0 if verb in ("-h", "--help", "help") else 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
