"""Chat turns the Mac answered, handed to the app for the ledger.

Measured 2026-11-13 (docs/CHANNEL-SYNC-AUDIT-2026-11-13.md, F1/F4/F5): the
Mac wrote ledger turns only for the app's own conversations. A Telegram
message the Mac answered over the relay, and every WhatsApp message (the
linked device lives only on the Mac), stayed in Hermes's state.db and never
reached Away — 10 + 101 messages on the owner's account.

Away's moe-ledger appends its own channel turns because it holds its own
signing key. On the Mac the key is the app's (Keychain, Swift), so this side
only queues the turn; ``ConversationLedger.importChannelTurns`` reads the
queue on the next sync round, records the turns as a thread per chat, signs
and pushes them with everything else.

The queue is plaintext on the Mac's disk, as the same words already are in
Hermes's state.db: mode 0600, under the app's own home, and capped.
"""

from __future__ import annotations

import json
import os
import time
import uuid
from pathlib import Path
from typing import Optional

#: The chats that are the person talking (moe-ledger ``MESSAGING_PLATFORMS``),
#: less Slack: the owner's rule keeps no copy of Slack words (§5b).
CHANNELS = frozenset({
    "telegram", "whatsapp", "whatsapp_cloud", "signal", "discord", "sms", "email",
    "imessage", "bluebubbles", "photon", "line", "moemail",
})
PRIVATE_CHAT_TYPES = frozenset({"private", "dm"})
WRITE_CONTEXTS = frozenset({"primary", ""})
SPOOL_NAME = "channel-turns.jsonl"
#: Lines kept when the app has not drained the queue (sync off): the newest.
MAX_LINES = 2000


def spool_path(moe_home: Path) -> Path:
    return Path(moe_home) / "cloud" / SPOOL_NAME


def wanted(platform: str, chat_type: str, agent_context: str) -> Optional[str]:
    """None when this turn belongs in the queue, else why not."""
    platform = (platform or "").strip().lower()
    if platform not in CHANNELS:
        return "not a chat app" if platform != "slack" else "Slack words are never kept"
    if (chat_type or "").strip().lower() not in PRIVATE_CHAT_TYPES:
        return "not a private chat"
    if (agent_context or "") not in WRITE_CONTEXTS:
        return "not the person talking"
    return None


def append(moe_home: Path, *, platform: str, chat_id: str, user: str, assistant: str,
           now: Optional[float] = None) -> bool:
    """Queue one turn. False (and nothing written) when there is nowhere to
    sync it to — this Mac is not enrolled — or nothing was said."""
    home = Path(moe_home)
    if not (home / "cloud" / "credential.json").exists():
        return False
    if not (user or "").strip() and not (assistant or "").strip():
        return False
    chat_id = str(chat_id or "").strip()
    if not chat_id:
        return False
    line = json.dumps({
        "v": 1, "platform": platform.strip().lower(), "chat_id": chat_id,
        "at": float(now if now is not None else time.time()),
        "you_id": str(uuid.uuid4()).upper(), "you": user or "",
        "moe_id": str(uuid.uuid4()).upper(), "moe": assistant or "",
    }, ensure_ascii=False)
    path = spool_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    _cap(path)
    return True


def _cap(path: Path) -> None:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return
    if len(lines) <= MAX_LINES:
        return
    tmp = path.with_suffix(".tmp")
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines[-MAX_LINES:]) + "\n")
    os.replace(tmp, path)
