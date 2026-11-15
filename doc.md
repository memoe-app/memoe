# Memoe docs

> How to use Memoe: Moe is the assistant in your notch that you speak to,
> that speaks back, and that does the work on your Mac. Every screen, what
> starts on and off, and what leaves your Mac and when.

## Memoe, in short

Memoe is an app that lives on your Mac, and Moe is the assistant inside it.
You say what you need, out loud or typed, and Moe goes and does it: reads the
mail and calendar you connect, takes the notes in a meeting, works the Mac
itself, remembers what you told it last month, and asks before anything goes
out to another person. It is free, it runs on your Mac, and the thinking comes
from an AI account you already have. The Mac app is open source, under the
Apache-2.0 licence, and its code is at
[github.com/memoe-app/memoe](https://github.com/memoe-app/memoe).

These pages describe every part of Memoe as it is today: what each screen
does, what each switch changes, what starts on and what starts off, and
what leaves your Mac and when. They are written for you, not for the people
building Memoe, and they are kept in step with the app.

### What you need

- A Mac with Apple silicon, running macOS 15 or later.
- Something for Moe to think with: a Claude or ChatGPT plan, a key from a
  model company, or a model running on your own Mac. Moe has no mind of its
  own and no account of its own. See [Settings › Brain](#settings-brain).
- For the cloud half, an optional plan: [Away](#away-moe-when-your-mac-is-closed).
  Everything else is free and stays free.

### Where things are

- **The notch.** Moe lives under the notch at the top of your screen. Hold
  the talk key and it listens; hover and it opens; when something arrives its
  line slides out beside the notch, and what it has waits in its
  [inbox](#your-inbox). A Mac without a notch gets a small black tab in the
  middle of the menu bar instead.
  On a MacBook whose camera sits in a small floating capsule rather than a
  notch, Moe is that capsule: at rest it looks exactly like the camera and
  nothing more — even while something waits in your inbox (hover to see it),
  and while a conversation is open but nobody is speaking. The capsule
  widens sideways while you are speaking to Moe, while it thinks, works or
  speaks back, and when something has just arrived, and it opens into a rounded card that hangs from the capsule
  instead of from the top of the screen. You do not have to hit the capsule
  itself: pointing anywhere near it at the top edge of the screen opens Moe.
  While a microphone is in use, macOS shows its own orange dot beside the
  camera, and sometimes a wider outlined pill with a microphone in it. That
  is the system's, not Moe's, and nothing can be drawn over it, so Moe puts
  what it has to say either side of it: its bars or ring on the left, its
  word on the right. Opened, the card says what Moe is doing once, beside
  the camera.
- **VoiceOver and Reduce Motion.** The island and every button on its panel
  are named for VoiceOver, and the folded island reads out what it is
  showing (*Listening*, *Muted*, *Thinking*, a notice's line). With **Reduce
  Motion** on in System Settings, the island changes shape at once instead
  of springing, and its working light holds still.
- **The main window** (⌘0, or *Show Window* in the Memoe menu) has six rows:
  **Chat**, **Inbox** and **Meetings**; **Memory** under *Library*; **Connections** and
  **Message Moe** under *Reach*. **Settings** (⌘,) is at the bottom, and the
  footer shows two dots: *Connected* and *Voice ready*. If the microphone
  stops working, the second dot turns to *Microphone not working* and the
  island's status line says so once — nothing is added to your
  conversation — and Moe tries the microphone again the next time you talk
  to it.
- **Settings** has thirteen panes: Brain, Voice, Meeting Capture,
  Permissions, Reminders, Running in the background, Activity, Chats, Skills,
  Usage, Upgrade (called Away once you have a plan), Privacy, and About &
  Licences. Each has a page here.
- **The menu-bar icon** is a small waveform; it turns into a red dot while a
  meeting is recording. Its menu has *Talk to Moe*, *Open Memoe*, *Start
  meeting*, *Always Listening ("Hey Moe")*, *Hide Island* and *Quit Memoe*.

### Memoe is in beta

You are early. Memoe does a great deal already and it is still being built, so
expect the odd bug and a few rough corners, and expect it to change often
between versions. The app says so beside its version in Settings › About &
Licences and on the first screen of the welcome.

When you hit something, tell Moe: out loud or typed, "that didn't work" is
enough. It writes the report itself and, once you have allowed problem
reports, it reaches us with what is needed to fix it. See [When Moe itself
breaks](#when-moe-itself-breaks). From outside the app, hello@moebot.app.

### How to read these pages

Every page is one part of Memoe, in the order you meet it: getting started,
talking, the settings that shape the answers, driving the Mac, the gate in
front of anything that goes out, meetings, the things Moe does on its own,
its memory, what you connect, the chat apps you can message it from, the
cloud, privacy, and what happens when Moe itself breaks. Search at the top
looks through all of it; press `/` to jump to the box.

## Getting started

### Download and first open

Download Memoe from [memoe.app/download](https://memoe.app/download). Every
Download button on the site opens a short sheet first, saying what is in the
box and what opening it looks like; **Download Memoe for Mac** starts the
download. It is a large download, a little over a gigabyte, because
everything Moe needs is inside it: the speech and voice models that run on
your Mac, and the part of Moe that does the thinking, with the tools it
uses (its own Node and ffmpeg). Setting up fetches nothing, so the first run
works offline, and that part of Moe never downloads pieces of itself while
it runs.

If you use Homebrew, `brew install --cask izzy-gottz/moe/memoe` installs the
same app. Each version is also on the open-source repository's
[Releases](https://github.com/memoe-app/memoe/releases) page.

The one exception is the browser Moe uses for web pages (about 330 MB),
which Memoe downloads in the background the first time it opens, just as it
always has. Until it arrives, asking Moe to use a web page gets the answer
*Memoe is still downloading its browser (about 330 MB). Try again in a
minute*; everything else works meanwhile. If you are offline, it tries again
the next time Memoe opens.

Open the disk image and drag Memoe onto Applications. Memoe is signed and
notarized by Apple, so the first time you open a copy you downloaded, macOS
checks it and asks once: *"Memoe" is an app downloaded from the Internet. Are
you sure you want to open it?* Click **Open**. That is all of it: there is no
trip to System Settings and no Privacy & Security step.

If you open Memoe straight from the disk image instead of dragging it
first, it says so and offers **Move to Applications**: it copies itself
there, opens from there, and changes nothing else. It never moves without
that click. If there is already a Memoe in Applications it asks first:
**Replace it** (the old one goes to the Trash; your notes, memory and
settings are kept elsewhere and are not touched), **Open the one in
Applications**, or **Quit**. Memoe has to live in Applications to keep
itself up to date and run its background jobs, so the other choice is
**Quit**. If it cannot copy itself, it says nothing was changed and asks
you to drag it there yourself.

After that, the welcome asks for what Moe needs, one thing at a time: the
microphone, so it can hear you, then permission to notice its talk key and
to see your screen. You can skip any of them, and whatever you skip is asked
for again the first time it is needed. Those are macOS asking on your
behalf, not warnings about Memoe.

Moe keeps everything it makes in `~/Library/Application Support/Moe`:
memories, meeting notes, transcripts, settings and connections. That is
where macOS puts an app's data, and where to look to back it up. (An older
name for the same folder, `~/.moe` in your home folder, still works; it
points at the same place.)

Moe keeps that folder from filling your disk on its own. Its logs are
capped at a few megabytes each and roll over. The record of past
conversations it searches, and that the Usage page counts from, keeps one
year. Moe's own browser keeps only its newest copy of Chrome, and Chrome's
built-in AI model (about 4 GB, which Moe never uses) is removed while that
browser is closed. When a meeting's transcript looked incomplete, Moe keeps
its recording so the problem can be checked; that recording is removed after
30 days, and the meeting's notes say so. Your memories, meeting notes and
the files you give Moe are never trimmed.

### The welcome

The first time Moe opens, a short welcome walks you through it: seven
screens, one thing each, all of them skippable. **Back** and **Skip** are on
every screen, nothing in it is permanent, and nothing breaks if you say no.

Closing the welcome part-way does not end it: the next time Moe opens, the
welcome comes back on the screen you left. It is finished when you reach the
last screen and press **Take me to Connections** or **Not now**. To see it
again at any time, choose **Show Welcome Again** in the Moe menu.

1. **Hi, I'm Moe.** The four things it does: answer out loud, take meeting
   notes, remember you, reach your things. One line says Memoe is in beta.
2. **Can I hear you?** The one permission asked up front. **Turn on the
   microphone** shows macOS's own prompt. Say no and Moe still works; you
   type to it instead. Your voice is turned into words on this Mac and is
   never sent anywhere.
3. **Give me something to think with.** Moe has no account of its own, so
   pick the one you already use. The first two are marked **Recommended**,
   side by side, because they are a plan you may already pay for: **Sign in
   with Claude** or **Sign in with ChatGPT**; Moe works as well with either.
   Below them: **Paste a key you already have** (Anthropic, OpenAI,
   OpenRouter, Google Gemini, DeepSeek, xAI and others), or **Run a model on
   this Mac**. And for someone who pays for no AI at all, **No AI plan?**
   with **Start free**: a Google Gemini key is free up to Google's daily
   allowance (pennies a question after that), and a model on this Mac is
   free for good. Memoe has no free AI of its own. Those three open
   Settings › Brain, where the key or the model is chosen, and the welcome
   stays open and waits: it says what to press there, notices when the
   choice is made, asks it one question to check it answers, and carries on
   at *Say hello* with a tick, *I'm thinking with … now*. If it does not
   answer, the welcome says why and checks again when you fix it. Signing in happens in your browser, never in a Terminal: Moe
   opens the page, and for ChatGPT it shows you the code the page asks for,
   already copied. Whichever plan you sign in with, the screen shows a tick,
   *Signed in with…*, and moves on to the next step. If Moe cannot download
   what a sign-in needs, it says so and offers **Try again**. On a fresh
   copy of Memoe this screen says *getting ready* for the few seconds it
   takes to lay down the part that thinks.
4. **Say hello.** Press **Talk to me**, or ⌃⌥Space, and say "what can you
   do?". Both work straight away. Holding right ⌥ needs **Accessibility**
   first, so until that is on its card is at the top of this screen: press
   **Allow it**, switch Memoe on in System Settings, and the screen waits
   and notices by itself — there is nothing to quit and reopen. Once it is
   on, the screen leads with the key: hold right ⌥, say it, let go;
   double-tap the key to stop Moe. The screen also asks for **Screen
   Recording**, so Moe can see your screen when you ask about it; that one
   takes effect the next time Moe opens. Both are one button and one line,
   and both can be skipped. Neither of them is what lets Moe click and
   type for you: a helper app called **CuaDriver** does that, and macOS
   asks about it under that name, Accessibility and Screen Recording once
   each, the first time you ask Moe to do something on your Mac. The screen
   says so, so the name is not a surprise. If System Settings shows Moe switched on for
   Accessibility and Moe still says it is off, macOS is remembering an older
   copy: **Reset and ask again** clears that. While Moe is still getting
   ready to listen, the screen says so (*Getting my ears on…*), the same
   line the island shows. The welcome moves on once Moe has finished
   answering you, not while it is still talking. If you ask before an AI is
   connected, Moe says so out loud instead of staying silent.
5. **I'll take the notes.** What a meeting records and where it stays, and
   one switch, **Start and stop a meeting with ⌃⌥M**, off: a key that
   records other people is one you switch on yourself.
6. **What may I learn from and watch?** One switch for each thing on this
   Mac Moe could learn from (*Learn from Calendar and watch it*, and its
   like), and under them the daily pass itself, *Once a day, read back over
   what I've allowed and note what it learns*. Everything connected starts
   switched on, marked **Recommended**; untick what you would rather Moe
   left alone and press **Save and continue**. Nothing is read until you
   save. **Skip** records nothing, so Moe can ask again later, the first
   time you connect something — any of them, the apps on this Mac or any
   service you sign into. With nothing connected yet, the screen says so.
   See [Memory](#memory-what-moe-knows-about-you).
7. **Connect your world.** What to connect first, in the order the
   Connections page lists it: the apps already on this Mac (Calendar,
   Reminders, Notes and Contacts), then Google (Gmail, Calendar and Drive,
   one sign-in for all three), then everything else. Then two switches you
   see before the welcome closes: **Start Moe when my Mac starts**, on, and
   **Let Moe send problem reports**, off, with **What is sent?** beside it
   and **Report without saying who I am** under it. Both are the same
   switches as Settings › Privacy. **Take me to Connections** ends the
   welcome.

Skip everything and Moe still takes meeting notes; the brain can be chosen
any time in Settings › Brain.

### Moe starts with your Mac

When you finish the welcome, Moe adds itself to System Settings › General ›
Login Items, so it is there under the notch when you sign in. The last
welcome screen shows it as the switch **Start Moe when my Mac starts**,
already on; turning it off there and turning it off in Login Items are the
same thing. Moe never switches it back on behind you: it asks macOS once,
and after that the switch is yours. A copy that opens after *Erase Moe from
this Mac* adds nothing.

### The part of Moe that thinks looks after itself

Moe's thinking part ships inside the app and is laid down on first launch.
Moe starts it when Moe opens and restarts it if it stops. If it keeps
stopping, Moe says so once, *The part of Moe that thinks kept stopping*, and
then keeps trying quietly in the background about once a minute until it is
back; you don't have to quit Moe or open it again. When it is back, Moe is
back with it: the window says *Connected* again and your next question is
answered. You don't have to wait for the minute either. Asking Moe something
while it is down makes it try again right then, as New Conversation does.

It can also be running and answering nothing. When an answer does not come
at all, *Moe is taking too long to answer*, Moe asks its thinking part
whether it is still there. If it answers, it was only that one question
that was slow, and nothing is touched: a long piece of research is allowed
to take its time. If it does not answer twice in a row, Moe replaces it,
which takes a few seconds, and your next question is answered. Until this
version that check did not exist, and every question after the first one
ended the same way until you quit Memoe.
Each version of Memoe also keeps that part current on its own: a
small update in the background, one brief *restarting*, and that is all you
see.

## Talking to Moe

Four ways in, and they all end in the same place: Moe listening, the notch
lit green.

- **Hold right ⌥** and talk. Let go when you are done. This one always works
  and never mishears its name, because it does not listen for one. It needs
  Accessibility; until that is on, Moe says so wherever you look, on the
  island when you hover, at the top of the open panel and above the chat box,
  each with a **Fix** button, and the warning goes the moment it is on.
  **Settings › Voice › Hold a key to talk** changes the key to **right
  ⌘**, **right ⌃** or **fn / 🌐**, and the new key works straight away.
  Right ⌃ is only on some keyboards, and fn works only if macOS is not
  already using it: set **System Settings › Keyboard › Press 🌐 key** to
  **Do Nothing**, or macOS will act on it too. Everywhere Moe names the key,
  it names the one you picked. A key held as part of a shortcut doesn't
  start Moe: hold fn and press Delete, or right ⌘ and Tab, and the press is
  dropped: nothing is recorded, no picture is taken, and a reply it paused
  carries on.
- **Double-tap the talk key** and talk with nothing held, for when your
  hands are busy or you have a lot to say. The notch breathes and says
  *Listening — tap to send*. Pause as long as you like to think: Moe never
  decides you have finished. **Tap the key once** and what you said goes to
  Moe, exactly as if you had held the key and let go; if you said nothing,
  nothing is sent. **Esc** drops it without sending, and so does locking the
  screen or the Mac going to sleep. A tap within a moment of the double-tap
  (a triple-tap, in effect) is read as "never mind": nothing is sent and
  Moe stops listening. This is only when Moe is completely at rest. In
  every other moment — talking, working on an answer, listening after
  "Hey Moe" or waiting for a follow-up — **a double-tap stops everything**:
  what it is saying, the answer it is working on and the microphone. You
  hear a short low two-note sound and the notch says **Stopped** for a
  moment, so you know it worked. While *Stopped* is showing, another
  double-tap only stops again.
- **⌃⌥Space** to start and stop, hands free. It needs no permission at all.
  *Shortcut to ask*, under **More** in Settings › Voice, offers
  **⌥Space**, **⌘⌥Space** and **⌃Space** instead, for when another app
  already owns it. A new shortcut takes effect when Moe restarts.
- **Say "Hey Moe"**: **Settings › Voice › Or just say "Hey Moe"**, off by
  default.
  The menu-bar icon has the same switch, *Always Listening ("Hey Moe")*.

A quick tap from rest does nothing you can see: the notch only shows Moe
listening once you have held the key for a moment, so the first tap of a
double-tap never flashes the microphone on. Nothing you say at the start of
a hold is lost; Moe keeps the audio from the instant the key went down.

**Esc** stops Moe too, when the panel under the notch or the chat window is
the window you are typing in. In any other app Esc belongs to that app.

Two switches under *Moe and your screen* in **Settings › Permissions** go
with the key. **Moe sees my screen
when I ask** is on: a picture of the screen under your cursor, taken as you
press the key, goes with your words, so "what do I do here" just works. It
is never saved. **Move my mouse to what Moe points at** is off: Moe only
draws a ring around the thing it means, and it never clicks.

Moe starts reading your turn back the moment you stop talking, not the
moment it decides you have finished, so when you stay quiet the answer
starts sooner. Say anything more and the whole turn is read again; nothing
is ever taken from a half-heard sentence.

### Hands-free, with nothing held down

Only one of the four ways needs nothing pressed at all: **Say "Hey Moe"**.
Turn it on in **Settings › Voice › Or just say "Hey Moe"**, or from the
menu-bar icon, and Moe starts listening from the name alone, with nothing
pressed and nothing held.

**⌃⌥Space** needs nothing *held* down — it starts and stops a turn with a
tap, and needs no permission at all — but a tap is still a key press, not
an answer for someone who cannot press one.

### If the shortcut does nothing

- **The hold-key method stays silent:** it needs Accessibility first. Until
  you turn that on, Moe says so wherever you'd look for it — hovering the
  island, at the top of the open panel, above the chat box — each with a
  **Fix** button, and the warning clears the moment it's on.
- **Another app already answers to the key you picked:** right ⌥, right ⌘
  and right ⌃ are free on most Macs, but if something else gets there
  first, pick a different one in **Settings › Voice › Hold a key to
  talk** — the new key works straight away, no restart. fn is the one
  exception: set **System Settings › Keyboard › Press 🌐 key** to **Do
  Nothing** first, or macOS answers to it instead of Moe.
- **⌃⌥Space does nothing, or clashes with another app:** under **More** in
  Settings › Voice, *Shortcut to ask* offers **⌥Space**, **⌘⌥Space** or
  **⌃Space** instead. A changed shortcut takes effect once Moe restarts,
  not the moment you pick it.
- **The key works, then suddenly doesn't — same key, same app:** if the
  moment you held it, it was also partway through a shortcut another app
  was mid-press on (fn + Delete, or right ⌘ + Tab), the press is dropped on
  purpose: nothing is recorded, no picture taken, and any reply Moe had
  paused carries on where it left off. That's Moe staying out of your own
  shortcut's way, not a miss.

### Staying in the conversation

**Keep listening after Moe answers**, in Settings › Voice, is on to start
with: when Moe finishes answering, it keeps listening for a few seconds so a
follow-up needs no key and no name; you just keep talking. Turn it off and
Moe answers one question and stops listening. While it is on, two controls
sit under it: **Waits for** chooses 8, 12, 16, 20 or 30 seconds (it starts
at 8), and **When you go quiet** is covered under *Ending a conversation*.
Longer is friendlier in a quiet room and worse in a busy one, because
everything said in that window is something Moe has to judge. A sound in
the room that starts the microphone and comes to nothing, a television or
somebody else talking, does not start the wait over: the window gets a few
more seconds, and after the third such sound in a row it closes.

**Keep listening after a held-key turn too**, under **More**, decides whether
the window opens after a hold-to-talk turn as well, or only after the name
and the shortcut. Holding the key is meant as a one-off question, so this is
off unless you want otherwise, and it is greyed out while *Keep listening*
is off.

### Not everything you say is for Moe

The hard part of an always-listening assistant is not hearing you; it is
working out which of the things it hears were meant for it. In the follow-up
window Moe weighs several signals rather than matching a phrase: how long
ago it spoke, whether it had just asked you a question, how loud you are
compared with the room, whether the voice is the one that started the
conversation, and what the words themselves suggest. In English it reads the
words closely; in other languages it goes by the name, the timing, the
loudness and the voice. If the answer is still unclear it asks the Mac's own
on-device judgement (on macOS 26 with Apple Intelligence), and without that
it takes a turn that looks like a request and leaves one that does not. A
long answer straight after Moe asked you something is taken as the answer,
however long it runs, and a turn in your own voice, close to the Mac, is
taken even when the words alone leave it unclear. If Moe still decides a
long turn was not for it, what you said is not lost: it appears in the
conversation marked *Not sent to Moe*, so you can read it and say it again.

It also knows its own voice. If the microphone picks up Moe's own speech,
that is echo and not a new turn; it never answers itself.

**Whoever opens a conversation owns it.** The moment you say "Hey Moe" or
hold the key, Moe takes a reading of that voice and uses it for the rest of
the conversation, so a second person talking beside you is not answered, and
a guest who opens their own conversation is. A reading that disagrees is not
enough on its own to ignore you, though: a turn as loud as you usually are,
or one that matches the voice Moe has learned is yours, is judged on its
words. Someone else can still join by
name: saying "Moe" gets through regardless. This needs no setup, because the
voice it compares against is the one that just spoke.

**Teach Moe your voice**, under **More** in Settings › Voice, learns what
you sound like from a few sentences read aloud. It is optional; with it, "is
this the person who started this conversation" becomes a measurement
instead of a guess. Press **Read one**, read the sentence on screen, and
after three the row reads **Moe knows your voice**. Moe keeps learning from
the turns you open by name. Nothing is recorded; what is kept is a
description of the voice, on this Mac. **Forget** appears beside it once you
have read one: Moe stops using how a voice sounds as a signal, and nothing
else changes.

### Interrupting

Brushing the hold key does not cost you the answer. The sound stops the
moment the key goes down, which is what you want when you have something to
say, and the reply is kept, not thrown away, until what you do next says
whether you meant to replace it.

Stop Moe to say something, with the key or by talking over it, and what
you say next **changes** what you asked for
rather than replacing it: ask for five things, correct one of them halfway
through, and Moe keeps the other four. Withdraw it outright, "never mind",
"forget it", "scratch that", and it drops the lot. Amending is the default
because it is the one you can undo.

**Let me interrupt Moe by talking**, off to start with, lets you talk over it
without a key. **Off means off:** while Moe is thinking or answering,
nothing you say stops it, restarts it, pauses it or makes it quieter, not
even its name, so you can talk to someone else in the room, or to yourself,
without losing the answer. The only exception is finishing your own
sentence: carry on within about a second and a half of pausing and it is
joined to what you asked (see **Pausing mid-sentence**). The hold key, the
shortcut and the buttons on the island still stop or pause it whenever you
like. With it on, start speaking while it is answering and, as soon as it
hears a word, it fades a little quieter while it listens for the rest. It
stops when it hears **two words, or one word that means stop**: "stop",
"wait", "no", "hold on", or its name. A fan, a dish, a cough or a door has no
words in it, so Moe carries on at full volume having interrupted nothing, and
the same sound does not use up your one interruption. Before it stops, Moe
checks that the words are not its own coming back through the speakers and
that the voice is not much quieter than yours, as someone across the room or
the television would be. A stop word or its name stops it unless it is the
very word Moe is saying at that moment. Each reply can be paused this way once; a false alarm
does not get a second go until the next turn.

Moe listens for you the whole way through a reply, not just at the moments
it goes quiet between sentences. A little of its own voice always comes back
through the microphone, so it also listens for a voice clearly louder than
that, and when you start talking over it mid-sentence it hears you the same
way. In that case it does not fade first: it stops once it has heard your
words.

If Moe did stop and it turns out nothing was said to it, it carries on: from
the very word it stopped at if the pause was short, or from the start of that
sentence if it was more than about three seconds.

The same rule holds while Moe is still thinking about your question: a noise
in the room does nothing to it. Only words take the floor.

The same is true while Moe is still thinking: pressing the shortcut again
mid-thought puts you back in control. Pressing the shortcut never waits; it
stops Moe immediately. Saying "Hey Moe" clearly over an answer does the
same, whether or not **Let me interrupt Moe by talking** is on; any other
voice over the answer only stops it when that setting is on.

### Pausing what Moe is saying

**Tap the hold key while Moe is talking and it stops there. Tap it again and
it carries on from the same word.** Nothing is re-said and nothing is
skipped. The island says *paused — tap again to carry on* so you can tell a
pause from a problem. It works the same on an answer to something you typed,
and on one you are replaying with ▶ in Chat.

The same pause is a button too. On the island, every control sits behind
the small **⋯** at the bottom right of the panel: click it and a short row
of icons slides out. While Moe is talking they include **pause** and **start
over**; pause becomes **resume**, which carries on from the word it stopped
at, and start over says it again from the top. Once an answer is finished
the same place offers **read aloud** and **copy**. Hover any icon to see
what it does. In Chat, the answer being said has ⏸ and ↺ beside Moe's name.

A tap never throws an answer away. While Moe is working on it and nothing
is being said (before the answer starts, or in the gap between two sentences
while it looks something up), a tap changes nothing and the answer comes as
usual. While Moe is talking, a tap pauses it and the next tap carries on. If
you started talking over Moe and it paused for you, a tap keeps it paused
rather than dropping it.

That is a tap, a quick press. Holding the key is still "let me say
something": the sound stops the same way, and then your words either replace
the answer or, if you say nothing, let it carry on. Double-tapping while Moe
is talking or working stops everything outright; double-tapping while it is
completely at rest is how you talk hands-free.

### Seeing what Moe heard

The panel shows the whole conversation as a chat: yours on the right, Moe's
on the left, and while you talk your words appear in the newest bubble as
you say them. The **captions** icon
behind the **⋯** turns on the live transcript: while it is on, the island
opens by itself when you start talking, and again when Moe starts to answer,
so you can read along without hovering, even with *Open by itself* set to
Never. It fills in white while it is on, and it lasts for that conversation:
when the conversation ends it switches itself off.

**A long answer.** Hovering shows the panel at its usual size; click the
notch and the panel opens taller, with the extra room given to the
conversation. A long answer stays at its first line while Moe is still
writing it, so you can read down from the top instead of being pulled to
the newest word, and the scroll bar shows when there is more.

### Muting yourself

**In a spoken conversation, the microphone icon on the island mutes you.**
It is the first icon behind the **⋯** for the whole conversation, while Moe
thinks, while it speaks and while it waits for you to say something more. Moe keeps working on what
you asked, and keeps talking, but nothing said in the room reaches it: not a
word while it works, not a word over the reply, not "Hey Moe".

**While you are muted, you can't miss it.** The word beside the notch
says **Muted**, a red **Unmute** button with a crossed-out microphone sits at
the left end of the island's controls, away from the **⋯**, and when the
island folds away after an answer the notch keeps saying **Muted**, with a
crossed-out microphone, on its left side. Nothing there moves when you talk,
because nothing you say is reaching Moe.

**Only the Unmute button unmutes you.** Clicking the notch or the Muted
beside it opens the island and leaves you muted, so you can look at what Moe is doing
without switching the mute off. If the island has only dropped down because
your pointer passed over the notch, the first click on **Unmute** keeps it
open and you stay muted; click **Unmute** again to unmute. The same switch is
in Chat, on the bar above the box: it reads *Muted* in red, with **Unmute**
beside it.

**A mute stays on until you turn it off.** It lasts through Moe's answers,
through the next question and through the pause after each reply. Moe
finishing an answer never unmutes you. While you are muted, Moe doesn't give
up on the conversation after a few quiet seconds the way it normally does: it
waits for you to unmute. When you do, it listens for your reply with the
whole pause to give it. If a muted conversation is left alone for ten
minutes, it closes.

**Holding the talk key talks through a mute.** Moe hears you while the key is
down, answers, and you are still muted when you let go, so you can ask one
thing without unmuting. A quick tap of the key still pauses and resumes the
reply, and never unmutes you. Pressing the shortcut that starts a
conversation does unmute you, because that is you asking Moe to listen. When
a conversation ends, any mute ends with it, so Moe always listens for its
name again.

### Pausing mid-sentence

A breath is not the end of your turn. How long Moe waits depends on how
finished you sounded: when you plainly finished a sentence it starts working
straight away; when your last words trail off ("and", "so", "um") or you
sounded mid-thought, it waits a few seconds of quiet before deciding. Either
way it holds its answer back until you have been quiet for a moment longer:
about a second and three quarters after a request that could still go on,
more when it was less sure, and a little less after a whole answer like
"yes", "not yet" or "go ahead", which cannot be the start of something
longer. It keeps listening
until the moment you would hear its first word. Go on talking inside that
window and nothing is lost: the half-answer is thrown away unheard, what you
said before the pause and after it are joined into one request, and that is
what Moe answers. It has to be you talking, something Moe can write down,
even an "uh" while you find the next word; a sound in the room with nothing
said in it leaves your question exactly as it was. Stay quiet and the answer arrives
exactly when it would have anyway. This applies to turns you start with the name or the shortcut;
a held key ends the turn when you let go.

With **Let me interrupt Moe by talking** off, that window is short: you can finish
the sentence you were in the middle of if you carry on within about three
seconds of pausing, and after that Moe is working on what you said and
nothing you say changes it (see **Interrupting**).

### Talking in a noisy room

Moe does not wait for the room to go quiet to know you have finished. It
listens for when your **words** stop: a second or so after the last one, it
decides whether you sounded finished, even with a fan, music or a television
going. If you sounded mid-thought it gives you about three more seconds, or
six when your words trail off ("…and then"), and neither a noise in the room
nor Moe asking itself the same question again resets that wait; only more
words do. When the premium hearing heard no words at all in a sound, Moe
reads it on the Mac within a second instead of waiting on the cloud, and the
cloud stays on for the next thing you say.

Moe also learns how loud the room is on its own and only treats a sound as
speech once it rises clearly above that. And if something starts the
microphone but no words ever come, Moe lets it go after a few seconds
without reading it or answering it, so a room cannot put words in your
mouth.

### Ending a conversation

Say you are done in whatever words you would use, "that's all", "thanks",
"I'm good", and Moe closes the conversation. This is Moe's own judgement of
what you meant, not a phrase it matches.

With the conversation switch on, if it has been quiet for a few seconds and
Moe is not waiting on you, it offers to step out rather than sitting there
lit. **When it goes quiet** chooses how: **Ask on the island** (a tick and a
cross by the notch, the default), **Ask out loud**, **Both**, or **Just stop
listening**.

### The name

"Hey Moe" runs entirely on your Mac, on a small model that listens only for
those two syllables; the room is not transcribed. It is off by default, and
there are honest limits worth knowing:

- It sometimes misses the name, and it sometimes fires on a phrase that
  sounds like it ("hey Joe", "a moment"). It learned from hundreds of
  voices in many accents, and from meetings and read speech that never
  say it, but not from your voice or your room; *Teach Moe its name*,
  below, measures it on yours.
- The words after the name are the request, and the name itself is never
  part of it: when the hearing writes "Hey Moe" as another word ("Emma?",
  or a bare "Hey,"), Moe drops it rather than answering it.
- When it fires on something that was not the name, the checks above usually
  stop anything from happening, but the light comes on for a moment.
- Hold-to-talk and the shortcut are unaffected by any of this.

**Teach Moe its name.** Under the *Or just say "Hey Moe"* switch in
Settings › Voice, once it is on, **Teach…** opens a card that takes about two minutes. It says what
it is for, how long it takes and that the clips stay on this Mac; press
**Start** (or Space) and it shows one phrase at a time in large type —
"Hey Moe" twelve times, said normally, quietly, from across the room and
so on, then eight sound-alikes such as "Hey Joe". Say each one when it
appears. A meter shows the microphone hearing you, the line reads
*Recording…* while you speak and *Got it* with a tick when the clip is
kept, and the card moves on to the next phrase by itself; a row of dots
at the top shows how far you are.

Speak as you normally would when you call Moe: the card judges each clip
by the same microphone sound the wake word listens to, so a voice loud
enough to wake Moe is loud enough to teach it. A clip that is quiet is
still kept — the tick reads *that one was quiet*, with a suggestion to
come a little closer next time. If a clip is no good — nothing heard, too
short, or so loud the sound broke up — the card says which and what to do
about it, and waits: press **Try again** (or Space) to say it again, or
**Skip this one**. **Redo the last one** throws away the clip you just recorded and
asks for it again. **Pause** (or Space) turns the microphone off until you
press **Carry on**; from a pause, **Finish with these** measures what you
have so far. **Cancel** (or Esc) stops at any point and changes nothing:
the clips from that run are deleted and Moe listens for its name as it did
before.

After the last phrase the microphone turns off and Moe measures how well
it hears you, with a bar that fills as it listens back to each clip. Then
it shows the result against how it was before — for example *Catches 11
of your 12 "Hey Moe"s (was 8) · lets through 1 of 8 sound-alikes (was
2)* — with a before-and-after bar for each, and uses the new setting from
then on. **Done** closes the card; **Teach again** starts over, in a
different room, say. The row then reads **Moe knows how you say its
name**, with what was measured and when.

The clips stay in Moe's folder on this Mac; nothing is sent anywhere
unless you choose to. Once you have recorded, the card's first and last
steps show how many clips are on this Mac, and that menu has two more
choices: **Send them to the Moe team…** opens a new message to
hello@moebot.app in your mail app with your clips zipped and attached, so
the next version of the wake word learns from real voices in real rooms,
and nothing goes until you press Send; **Forget my recordings** removes
the clips from this Mac and puts the wake word back to the setting it
shipped with. When a new version of Moe brings a new wake word model, a
setting taught to the old one no longer applies and the new model's own
is used; press **Teach again** to fit it to your voice.

### What Moe says while it works

During a long job Moe says what it is doing, "Going through your mail",
"Searching your files", and repeats the current one every so often so you
know it is still there. Anything it does through a connected service says
which service, whether the service is on this Mac or reached through
Composio. The switch for this is **Tell me what it's doing while it works**,
under **More** in Settings › Voice.

**The panel keeps one shape for the whole turn.** Beside the notch, one
word says where things are: *Listening*, *Thinking*, *Working* with a clock,
*Speaking*, *Paused*, *Your turn*. Under it is the whole conversation, like
any chat: what you said in bubbles on the right (live as you say them, with a
green edge), Moe's answers on the left, newest at the bottom; scroll up for
the rest of the session. A long message of yours shows its start and
**More**; Moe's answers are always shown whole. While
Moe works, its step is the newest row: what it is doing right now, in plain words
("Searching your files", "Working through the page"), and then, in the same
place, the answer. Nothing swaps out underneath you. While Moe works, the
send arrow beside the box becomes **■**: press it, or **Esc**, to stop the
job. The box to type in is always there. Anything you type while Moe is still
on the last thing is held, shown in the chat as *Sends when Moe finishes*,
and sent the moment it does; **×** beside it drops it, and stopping Moe drops
it too. Answers are laid out here as in Chat: paragraphs, lists, and code in
its own box with **Copy**. A table too wide for the panel shows as one line,
*A table, 3 rows · Open in window*; click it to read it in Chat. The
popped-out chat has the room and shows the table itself. Once the answer is in, what Moe did folds to one line under it,
*3 steps · 48 s · 1 source*; click it to see the steps and the pages Moe
read, and again to fold them. The **⋯** beside the send arrow slides out the
rest of the controls.

**Work silently.** When a long job is more talk than you want, click the
speaker icon behind the **⋯** beside the send arrow. It shows what is true now: a speaker while
Moe is saying what it does, a crossed-out speaker, filled in white, once
you have turned that off. For the rest of that job Moe stops saying what
it is doing, and when the job is done it says only the answer. The step it
is on stays on the row as text, so you can still see it is working. Two
things are never silenced: a message waiting on the confirmation sheet for
you to press Send, and anything that went wrong. Press it again to hear the
updates for the rest of the job. It lasts one job, and the button only
appears while a spoken question is being worked on; a typed one is already
quiet.

### Language

Moe starts in your Mac's own language, the first language in System
Settings › Language & Region that Moe can hear, and in English when none of
them is one it knows. **Language**, under **More** in Settings › Voice,
changes it. Talking to
Moe is tuned for English: in another language Moe waits for a moment of
silence to know you have finished, and "Hey Moe" is an English phrase, so
the shortcut is the reliable way in; a banner at the top of Settings › Voice
says so. The fast engine hears English and about two dozen European languages;
other languages use a universal engine that downloads once, about 600 MB.

Moe answers in the language you set it to, and stays there. A stray foreign
phrase in a turn, which speech recognition sometimes produces, is treated as
the mishearing it usually is rather than a reason to switch.

### Addresses and numbers

Numbers arrive written: say "twenty five thousand four hundred dollars" and
you get "$25,400". Email and web addresses are written too. "Email jane
three at jklumen dot ai" becomes `jane3@jklumen.ai`; "example dot co dot uk"
becomes `example.co.uk`; letters said one at a time run together. It only
happens where the shape is unmistakable, "dot" followed by a real domain
ending, so "a dot matrix printer" stays an ordinary sentence.

### Moe's own voice

Moe speaks with **Kokoro**, which ships inside the app: twenty-eight voices,
male and female, British and American, all running on your Mac with nothing
sent anywhere. **Voice**, under *Moe's answers* in Settings › Voice, is one
list of every voice, grouped by where it comes from; a voice you pick is
used straight away, and the **▶** beside it plays a sample. The row is there
while answers are out loud.

Two more groups are offered in the list. **PocketTTS** has twenty-six voices and is
the only local one that starts speaking before it has finished thinking.
It holds half a second of speech before the first word, and longer when
your Mac is busy, so it does not run out partway through a sentence and
leave gaps. After a minute or more of quiet it warms itself up again while
you are still talking, so the first answer after a pause starts as quickly
as the rest. It
is not in the app: pick one of its voices and a Download row appears under
the voice, saying what it costs, 939 MB, once, kept on this Mac; its button
fetches it with a bar, a percentage and a
Cancel. Until it is here Moe keeps speaking with Kokoro, and the voice you picked
is used the moment it lands. Stop a download and what has arrived stays; the
next Download carries on from there. **Premium**
is Moe's cloud-rendered voice, streamed back as it speaks. It is part of the Away
plans; picking it on the free plan opens Settings › Upgrade.

Each set starts on a voice chosen by ear, and you can change it whenever you
like: Kokoro begins on **Heart**, PocketTTS on **Peter**, and Premium on
**Clive**, one of three Premium voices.

Premium is given what Moe has to say a passage at a time rather than a
sentence at a time, so it speaks the way one person reads a paragraph, and
it no longer starts on half a sentence. Settings › Voice shows the voice you
are hearing: reopening the page no longer shows Kokoro (or Clive) when
Premium and another voice are what is speaking.

**If Moe cannot use the voice you picked, it tells you.** When Premium is
out of reach, no network, a plan that does not include it, this month's
allowance spent, Moe speaks with the voice on your Mac instead and a line
under the voice says so: which set you chose, which voice you are actually
hearing, and why. Your choice is kept, so Moe goes back to it by itself the
next time it can.

### Premium voice and hearing, on paid plans

On the **Away** and **Away+** plans Moe can hear and speak through the
cloud: sharper ears and a more natural voice than the ones that run on your
Mac. Each plan includes a monthly allowance, counted for the whole account
rather than per Mac and reset on the 1st:

| Plan | Spoken | Listening |
|---|---|---|
| Away | 300,000 characters | 6 hours |
| Away+ | 1,000,000 characters | 12 hours |

If you need more in a month, a **voice pack** adds 150,000 characters and 2
hours of listening for the rest of that month, for $5, from Settings › Away.

Moe never holds the keys to those services: it asks for a single-use token
each time it opens a connection. Each connection to the premium voice
counts as at least 100 characters, which what Moe then says is taken out of
first, so in ordinary use the count is simply what was spoken. While *Hey Moe* is listening, Moe keeps one
fresh token ready, so starting to talk never waits on fetching one. The
premium voice gets its connection ready as soon as you start talking, so
the first answer after a quiet spell starts as quickly as any other. On a
slow connection Moe waits for premium hearing to catch up with what you
said rather than deciding too soon that you said nothing, and when your
Mac clearly heard you speak it never takes the cloud's silence for an
answer. Moe's log records that a connection failed and why, but never the
address it was using, the token, or anything you or Moe said. When the allowance is used up, or if
anything goes wrong on the way, no network, a slow answer, a service down,
Moe carries on with the voice and ears on your Mac without asking, and
nothing you said is lost. If your connection drops for a moment, Moe
notices within about a second, finishes that answer in the voice on your
Mac, picking up where the premium voice stopped rather than starting the
sentence again, and shows *Connection dropped — using the Mac's voice for a
moment* once in the conversation. The Mac's voice is the closest match to
the one you chose (a British man for Clive), and one answer is never split
back and forth between the two: the premium voice comes back at the start of
your next answer. Before each answer Moe also checks that its connection
to the premium voice is still alive, and replaces it while you are still
talking if it is not. If the premium voice runs out of credits, Moe
switches to the voice on your Mac at the next sentence and stays with it,
and a line in the conversation says so once: *The premium voice has run out
of credits, so Moe is using its built-in voice for now.* Premium hearing covers English and about twenty
other languages; in any other language the Mac's own hearing is used.

**Premium hearing and voice**, under **More** in Settings › Voice, is on by
default and does nothing on the free plan: what
decides is the plan, not the switch. Turn it off and, paid or not, your
voice never leaves your Mac: Moe hears and speaks here. (What you said, as
text, still goes to the AI provider you think with.) The line under it says which is true right now: *Cloud
voice: on · 41% of this month used*, *Cloud voice: not part of your plan*,
*Cloud voice: off*, *this month's allowance is used up · back on* a date, or
that Moe's cloud could not be reached just now.

### Checking the microphone

**Check my microphone and speakers**, which appears under *Let me interrupt
Moe by talking* once it is on, says a sentence out loud, listens to how much of it comes back,
and tells you whether your speakers are leaking into your microphone. Stay
quiet for the eight seconds it takes. If they are leaking, Moe hears itself,
and interrupting by voice gets harder; headphones, or the built-in
microphone and speakers together, fix it. It also says when a call app has
taken echo cancellation away; that is expected, and it comes back when the
call ends.

### Settings › Voice

One page for how you talk to Moe and how it answers, in three short
sections. A switch that has settings of its own shows them just under it,
and only while it is on.

- **Starting** — **Hold a key to talk** (right ⌥ to start with) and **Or
  just say "Hey Moe"** (off). With "Hey Moe" on, **Teach Moe how you say it**
  appears under it.
- **The conversation** — **Keep listening after Moe answers** (on), with
  **Waits for** and **When you go quiet** under it; and **Let me interrupt
  Moe by talking** (off), which works best in a quiet room on the Mac's own
  microphone and speakers, with **Check my microphone and speakers** under
  it.
- **Moe's answers** — **Answers**, *Out loud* or *On screen only*; **Voice**,
  with **▶** to hear it, while answers are out loud; and **How much Moe
  says**, *Short*, *Balanced* or *Detailed*.

**More**, at the foot of the page, opens everything else in four groups:
*Starting* (Shortcut to ask, Keep listening after a held-key turn too,
Language), *While Moe works* (Say "on it", Tell me what it's doing, Ding when
a written answer is ready), *Answers* (which questions are answered out
loud, written answers, the island panel and how long it stays, Typed
questions open the Chat window, Hovering the notch opens it) and *Your voice and Premium* (Teach Moe your
voice, Premium hearing and voice). Each is described in its own section on
this page. The switches about your screen are in Settings › Permissions,
under *Moe and your screen*.

### Giving Moe a photo or a file

Press **+** beside the message box in Chat and choose where it comes from:

- **Photos…** — from your library, through Apple's own picker, so Moe sees
  only the photos you choose and needs no access to the rest.
- **Files…** — anything on your Mac, folders included.
- **Take a Screenshot** — drag across the part of the screen you mean, the
  same as ⇧⌘4. Escape cancels.
- **Paste from Clipboard** — whatever you last copied, if it is a file or an
  image.
- **Recent on this Mac** — the three newest things in Downloads and on your
  Desktop, one click each.

Or drag files anywhere onto the conversation, or press **⌘V** in the box
with a picture or a file on the clipboard: it is added, not pasted as its
name. Copied words still paste as words. What you have added waits
above the box, with an × to take any of it back, until you send, with words
or on its own.

The panel under the notch has the same **+** and **⌘V**, without the recent files, and
you can drag a file onto the notch itself: it opens as the file arrives and
stays open until you let go. Once something is waiting in its box it stays
open, so you can say what the file is for.

Moe opens what you send where it is on your Mac, so a large file costs
nothing to send. Up to four photos per message are shown to Moe as
pictures. Photos, pastes and screenshots that did not already have a file of
their own are kept in an *attachments* folder inside Moe's own folder.

### Links to what Moe read

Moe is spoken, so it never reads a web address out loud, but the links are
there to click. Under an answer that involved the web, **Sources** lists the
pages Moe actually opened, taken from the steps it ran rather than from what
it says it did. When Moe cites something in the answer itself it writes a
real link, live in Chat and in the panel under the notch; the spoken version
says the label and skips the address. Emoji and other symbols in an answer
are shown but not spoken, and an arrow is read as a pause. Ask for "the
links" and you get exactly these.

### Reading the chat

In Chat, what you said is on the right, in a tinted bubble, and Moe's
answers are on the left under its name. Notes that belong to neither of you,
like *Stopped.*, sit in the middle. Under an answer, a small chip says what
Moe did to get there and how long it took, *3 steps · 48 s*, and opens into
the list. When the model you use shows its thinking, that is in the list
too, folded under **Thinking**; with no steps besides, the chip says
*Thought it through*. Most plans and models do not show it, and then
nothing appears. Answers are laid out the way they were written: each line its own
paragraph, lists with their bullets or numbers in a column of their own so
a long item wraps under its text, tables as tables, and code in a box of its
own, in a fixed-width font, with its language and a **Copy** button. Hebrew
and Arabic read right to left, paragraph by paragraph, in your bubbles and in
Moe's answers alike, even a line that starts with an English word; English
in the same message keeps to the left, and code always reads left to right.
The same goes for the panel under the notch and the popped-out chat. Times are shown the way
your Mac shows them, in 12- or 24-hour time. The bar at the top of Chat
carries the conversation's name, and beside it the model this chat uses.
Click it to choose another of the models your AI service offers, for this
chat only; the menu marks your default, and **Back to the default** puts
the chat back on it. Every other chat keeps the default you chose in
Settings › Brain. Change the service itself in Settings and each chat
goes back to that service's default. Next to Moe's name on each answer, **▶** reads
it aloud in Moe's voice, even when typed answers are set to stay on screen.
While it plays, ▶ becomes **⏸**; pressed, it pauses there, and ▶ again
carries on from the same word. **↺** starts it over from the top. Tapping the
hold key pauses and resumes it too. **⋯** copies the answer, or reads it
from the top.

**While Moe works.** The newest line of the conversation says what Moe is
doing right now, *Thinking* and then the step ("Opening OpenTable"), with a
clock and a **Stop** button. The send arrow becomes a **■** while Moe works and
the box is empty: press it, or **Esc**, to stop. Type while Moe works and the
arrow comes back; what you send then waits in the conversation, dimmed, under
*Sends when Moe finishes*, with **Send now** (stop the job and send this
instead), **Edit** (put it back in the box) and **×** (don't send it).

**Buttons under the newest answer.** When Moe has written a draft for you,
an email or a message, **Send**, **Edit** and **Copy** sit under it.
**Send** tells Moe to send it as it is; you still see and confirm what goes
out before anything is sent. **Edit** puts the draft in the box to change
and send back, and **Copy** copies just the draft. When the answer ends by
offering to do something (*Want me to add it to your calendar?*), **Yes, do
it** answers for you. When Moe could not answer, **Retry** asks the same
question again. The buttons are on the panel under the notch and in the
popped-out chat too, and only on the newest answer.

**Copying.** Right-click any message, yours or Moe's, in Chat or on the
island, for **Copy message** or **Copy conversation**. To select across
several messages, press **Select** in the bar at the top of Chat: the
conversation becomes one page you can drag across, or ⌘A for all of it,
and you stay at the latest message. **Done** goes back. **Copy all** beside
it copies the whole conversation.

**With VoiceOver.** Each message is one stop, read as who said it, when,
and what it says. Its actions, from the VoiceOver rotor, are **Copy**,
**Read aloud**, **Show the steps** and one to open each page Moe read. When
an answer finishes, VoiceOver reads it out.
While a spoken conversation is open, a bar above
the box says whose turn it is, *Your turn — just talk, no wake word needed*,
*Thinking…*, *Speaking…*, with **End conversation** beside it.

## Settings › Brain

Moe has no mind of its own; it borrows one you already have. **Settings ›
Brain** is whose, which model, and how hard it thinks: three things on one
page, and no Apply button. Tapping a chip saves it, hands it to the part of
Moe that thinks, and checks that Moe still answers.

### The account card

The card at the top names the account Moe is borrowing, *Claude, on your
monthly plan*, *Anthropic, with your key*, *Ollama or a local server, on
this Mac*, with a dot and one line saying how it is: *Working, on Sonnet.*
(or *Working, on Sonnet, high effort.*) while all is well; *Waiting for a
sign-in.*, *Not signed in yet.* or *Starting…* while it is not; and, while a
change goes through, *Saving…*, *Switching to ChatGPT…* or *Checking Opus…*
until the verdict lands: *It works. Moe is thinking with Claude (Opus).*, or
a plain sentence about what went wrong. When a change could not be saved it
says that, that nothing was changed, and what to try (*Moe couldn't save
that key… Check it is the whole key…*), never the technical output behind
it, which Moe keeps in its log. If a sign-in is outstanding, the
button for it is right there: **Sign in with Claude…** or **Sign in with
ChatGPT…**. Under the name, one sentence on what this way of paying costs,
*Nothing on top of the plan you already have.*

### Change account…

**Change account…** opens the one sheet with fields in it, *Which account
should Moe use?*, listing every choice in three groups:

- **A plan you already pay for** — **Claude** and **ChatGPT**, both marked
  **Recommended**, equally. Each signs you in through a page in your
  browser; for ChatGPT, Moe shows you the code the page asks for.
- **A key you have — you pay by the word** — **Anthropic**, **OpenAI**,
  **OpenRouter**, **Google Gemini**, **DeepSeek**, **xAI (Grok)**, and
  **Anywhere else** with your own key and address. Each takes **Paste your
  key here**; the key is kept on this Mac, readable only by you, and never
  shown again (a row that has one says *Key stored*). *Anywhere else* adds an
  **Address** field and a **Test** button that tries the key against it
  before you commit.
- **On this Mac — private, and free** — **LM Studio** and **Ollama or any
  local server**. Each takes an **Address**, the one your server answers on,
  ending in /v1; `http://127.0.0.1:1234/v1` for LM Studio and
  `http://127.0.0.1:11434/v1` for Ollama are filled in for you. Load a model
  there first. A local model is slower and less sure of itself than one in a
  data centre; whether it can look at your screen or use your connections
  depends on which model you load, and Moe says what the one you picked can
  do.

The row in use is marked *In use*; one you have signed in to says *Signed
in*. **Use Claude** (or whichever you picked) at the bottom applies it;
**Cancel** leaves everything as it was.

### Model

**Model** is a row of chips, the provider's own names with two words under
each saying what picking it gets you, and **Other…** at the end for typing a
model name the row does not show.

- On a **Claude plan**: Opus (*Smartest, slower*), **Sonnet** (*Quick and
  capable*, where a new Moe starts), Haiku (*Fastest*), Fable (*Newest*).
- On a **ChatGPT plan**: the models your plan actually offers, read from
  your account when you sign in; a new Moe starts on **GPT-5.6 Sol**. A
  saved model your plan does not offer is
  said so plainly, *Your ChatGPT plan doesn't offer that, so questions on it
  fail*, rather than failing quietly.
- With a **key**, the provider's current models, from the fastest and
  cheapest to the smartest; OpenRouter's chips are the popular models across
  vendors.
- **Anywhere else**, **LM Studio** and **Ollama** have no chips: type the
  name of a model your server has loaded.

Under the chips, one line, *Can see your screen ✓ · Can use tools ✓*, says
what the model you picked can do, with a note when it cannot: *This model
can't see images, so Moe won't attach your screen*, or *No tool calling:
Moe can talk but not act*.

### How hard it thinks

Another row of chips: **Default** (*Let Claude decide*) and then the
provider's own levels, from *none* or *low* up to *xhigh* or *max*, each
captioned (*No thinking, fastest*, *Quick*, *Everyday*, *The usual choice*,
*Careful, slower*, *Slowest, most thorough*). Higher is slower and more
thorough; Default, where every Moe starts, lets the provider choose. On
Claude, changing it restarts Moe's thinking part, which takes a few seconds;
on a key it takes effect on your next question; a local model that does not
think ignores it. A model with no levels shows no row.

A question you ask **out loud** starts at the lowest level your account has,
whatever is chosen here, because after you stop talking you hear nothing
until Moe has its first words. Where an account can switch thinking off for a
moment, it is off for that question; where it cannot, it runs at its lowest
level. On a Claude plan this covers only the opening: once Moe has said its
first words or started looking something up, the level you chose is back for
the rest of the work. A question you **type** always runs at the level you
chose. If spoken answers seem less careful to you, tell Moe so: that reaches
us as a problem report, and this can be switched off for your Moe.

### How long Moe may work on one thing

On a Claude plan, a row of four chips: **5 minutes** (*Quick jobs only*),
**15 minutes** (*Most errands*), **30 minutes** (*The usual choice*, and
where every Mac starts) and **1 hour** (*Long research*). It is a ceiling
for one request, not a timer on every answer: most questions are done in
seconds whatever you pick. If a task is still going when time is up, Moe
stops it and tells you, *That was taking longer than Moe may work on one
thing, so Moe stopped it*, and you can give it longer here. Tapping a chip
takes effect from your next question.

### When the account Moe borrows stops working

Two very different things can go wrong with the account Moe is borrowing,
and Moe tells them apart.

**Something that will pass.** Your provider is busy, or limiting how fast
you can ask. Moe says so where you asked, *"I've hit the limit on your
Claude plan — I'll answer as soon as it clears, in about 10 minutes"*, and
then does exactly that. There is nothing for you to do.

**Something that will not pass on its own.** Your sign-in was cancelled,
your key was revoked, the account ran out of credit, or the address Moe has
for a local model stopped answering. Waiting will not fix any of these, so
Moe never says it will. You are told where you asked, in the chat you typed
into or out loud if you were talking, in your own provider's name: *"OpenAI
wouldn't let Moe in — the key is missing, wrong, or no longer good. Moe
can't think until that's sorted: Settings › Brain."* And it stays in
Settings until it is fixed: the account card on this page carries an amber
line, *OpenAI turned down the key*, followed by the one next thing to do,
and Connections stops calling Moe's brain *Working* while it plainly is
not. It clears itself the moment Moe answers anything at all; there is
nothing to dismiss and no need to restart Memoe.

A question your provider simply refused to answer, a safety filter, is said
in the chat (*"Gemini wouldn't answer that one. Try asking it a different
way."*) and kept out of Settings, because there is nothing about your
account to fix. And nothing a provider says about your key ever reaches the
screen: Moe strips anything key-shaped first.

### If you have a cloud computer

Changing your brain here changes your cloud computer's brain too. The
moment you change it, a short line appears under the account card saying
what became of your machine. Most of the time it says *Your away machine is
getting this too — it picks it up the next time it syncs, and uses it from
then on.* That covers a different model on the same account, a new key or
the key already on this Mac, your ChatGPT plan, and your Claude plan:
signing in to Claude again here, or to a different Claude account, gives
your cloud computer the same sign-in. Moe also checks each time it starts,
so a change made while Moe was closed still reaches it.

Two cases it leaves alone. **A model running on this Mac**, LM Studio or
Ollama: your machine cannot reach it, so nothing is sent and the line says
why. **A cloud computer you gave a brain of its own** under Settings › Away
(**Change…** there): changes on your Mac stop reaching it until you choose
**Use the same as my Mac** on that page. If you have no cloud computer, none
of this appears.

### If the thinking part is not installed

On a Mac that has the app but not yet the part of Moe that thinks, the page
says so, *Moe's thinking part isn't installed yet*, and **Set it up**
downloads it, about a gigabyte. Meetings and your connections work without
it; answering a question is the part that needs it.

## How Moe answers you

Moe is a voice assistant that you can also type to, and it tells the
difference: a question asked out loud comes back out loud and short; a
question typed comes back written, at the length it needs. *Moe's answers*
in **Settings › Voice**, and the *Answers* and *While Moe works* groups under
its **More**, are where that is decided. It holds to that however long the
conversation runs: Moe is reminded of how to answer you at the start and
again every twenty messages, so an afternoon-long conversation ends the way
it began.

### Who Moe is

Moe is on your side: part colleague, part friend, and the one who actually
gets things done. Warm without gushing, direct without being curt. It says
the answer first and does not narrate.

It is honest about what it knows, because you act on what it tells you. A
judgement call comes as its best guess, and it says so. A fact it could not
check, a price, a date, a count, it will not guess: it goes and finds it
out, and if a real attempt still cannot confirm it, it tells you what it
tried and what it will try next. It has opinions.
If something looks like a mistake, it says so once, kindly, with its reason;
then it is your call, and it helps with whatever you choose.

Moe knows where it is. On your Mac it may use all of it: files, apps, the
browser, mail, calendar, messages and the screen. Moe in the cloud (see
[Away](#away-moe-when-your-mac-is-closed)) knows it answers while the Mac is
asleep, that it cannot see the Mac's files or screen, and that anything
needing the Mac waits for the Mac to wake. To you it is one Moe, with one
memory, on every channel you set up.

### Moe does it, rather than telling you how

Tell Moe something is not working, or ask how to do something, and if its
tools can do it, your files, your mail, the web, your apps and browser, it
does it and tells you what it did, instead of giving you a list of steps. If
it is not sure you want it to, it offers in a line: "Want me to take care of
it?" You only get steps for the part that needs your own hands, like typing
a password, paying, or signing, or when you ask for steps.

Anything that sends, posts, buys or deletes still waits for your yes (see
[Before anything goes out](#before-anything-goes-out)): Moe does the work up
to that point and asks.

### Moe finishes what it starts

When you ask for something, or Moe says it will do it, it keeps going until
it is done. A page that will not load, a result that is not there, a tool
that fails: each is a reason to try another way, another source, another
search, not a reason to stop. It will not hand you an estimate in place of
the answer you asked for, or part of an answer as if it were the whole. It
stops only when the next step needs you, a yes, a password, a choice only
you can make, and then asks for exactly that. If it is taking a while, it
tells you what it has so far and keeps going.

### How much Moe says

**How much Moe says** sets how long Moe's answers are:

- **Short** — one sentence out loud, a few lines in writing. The answer and
  nothing around it. This is the default: Moe is something you talk to, and
  a spoken answer is better short.
- **Balanced** — a sentence or two out loud, and whatever a typed question
  needs.
- **Detailed** — up to a short paragraph out loud, and an in-depth written
  answer with the reasoning, the options and what to watch out for.

Spoken answers stay tighter than written ones at every setting, because you
cannot skim something you are listening to. Asking for more, "tell me
everything", always gets more, whatever this is set to. The chat apps you
message Moe from follow the same setting.

### Out loud, or on screen

Three choices, because talking and typing are separate questions:

- **Answers: Out loud / On screen only** is the master. On screen only, Moe
  never says anything and every answer is on screen. Moe is also silent for the whole of a recorded
  meeting whatever this says; the room and the call would hear it.
- **Answer questions I ask out loud, out loud**, under More — on. You asked
  out loud, so the answer comes back out loud.
- **Answer typed questions out loud too**, under More — off. Typed in, text
  out. Turn it on if you want a
  typed question answered aloud as well as shown.

### Written to be read

**Write typed answers to be read**, under More, changes what the
answer is, not just how it arrives. A spoken answer is one or two short
sentences with no lists and no formatting, which is right when you are
listening and wrong when you are not. On, and it is on, a question you typed
comes back written as writing: short lists and headings where they help,
links you can click, and the length the question needs. Off, a typed
question gets the same spoken-shaped answer.

### The panel under the notch

**Open the island panel by itself**, under More, decides whether the island
expands to show you an answer.

- **Only when Moe stays quiet** — the default. An answer you were told is an
  answer that reached you; a panel over your screen would be an interruption
  rather than a delivery.
- **Always** — to read along while Moe talks.
- **Never** — for a shared screen. The answer is still in Chat.

A recorded meeting always opens it, whatever this says: the reply is not
being spoken then, so the panel is the only place it exists.

**How long the panel stays** is **6 seconds**, **12 seconds**, **30 seconds** or
**Until I dismiss it**; it starts at *until I dismiss it*, because an answer
Moe did not say out loud is one you have not seen yet, and it should not
vanish on a timer. With a number, the clock restarts while the cursor is on
the panel, while the field has the keyboard, or while there is a half-typed
question in it; a click in another app folds it at once either way.

**Clicking the island opens it, and does nothing else.** A click on the
notch opens the panel and keeps it open; a click on the panel's own space
does nothing. The whole conversation is in the Memoe window: press **⌘J**,
or the window icon behind the **⋯**, or use the menu bar. ⌘J and the window
icon take what you had typed and any files waiting in the box with you, into
Chat's box. Anything Moe brought up on its own
waits in the [inbox](#your-inbox): the tray icon at the top of the panel, with
a count. The panel always opens on your conversation, never on a card.

To close it yourself: the **⌃** button in the top right, or **Esc**. Folding
is only folding; it leaves Moe alone and the conversation where it was. To
stop Moe, press the **■** that takes the send arrow's place while it works,
or **Esc**. On a Mac with a notch the ⌃
and the one-word status sit in the black strip beside the notch. The panel
shows the conversation, yours on the right and Moe's on the left, a
**new conversation** button beside the ⌃ (the one on screen is kept in
Chat), and a box to type in whenever you can
use it, with an arrow to send and a **+** that takes a photo or a file.

**A conversation left alone for an hour is put away.** The next thing you
say starts a fresh one, so Moe answers quickly instead of re-reading a
long thread first. The old one is kept in Chat, and Moe's memory still
knows what was said. It never happens while Moe is answering, while you
are in a meeting, or while the panel or a Moe window is open in front of
you.

Anything Moe needs you to see before the conversation, a call it can record, a new version of Memoe ready to install, or the
talk key waiting on Accessibility, sits at the top of the panel, and the
panel grows to hold all of it.

**Every Mac.** The island fits whatever notch your Mac has, at any display
scaling, and lines up with the notch itself rather than the middle of the
screen. A Mac with no notch, an iMac, an older MacBook Air or an external
display, gets a small black tab in the middle of the menu bar instead, and
everything below happens around that tab the same way. With a laptop and an
external display, Moe stays on the laptop's notch. Before you have said
anything, the panel greets you by the hour, *Good morning — I'm here*.

**What the notch shows.** No colours and no glow: the notch grows small
black "ears" either side, and everything is white or grey.

- **Idle**: one dim dot just right of the notch, so you know Moe is there.
- **Listening**: three white bars on the left, moving with your voice.
- **Thinking or working**: a white light runs round the edge of the notch.
- **Speaking**: the bars on the left move gently. Pause the reply and they
  become **Paused**.
- **Muted**: **Muted** on the left, with a crossed-out microphone.
- **Something arrives**: the right side widens into a short line for a few
  seconds, then shrinks back to the dot, which stays bright white while
  something is waiting for you.
- **Moe is using your Mac**: the right side says *Using Safari* (or
  *Browsing*) with **Stop**; click **Stop** to end it there and then.
- **A meeting is being recorded**: **Recording** on the left, with a small
  red dot, the one colour the notch keeps, because it is about your privacy.
  Off the record, the dot turns grey; when someone says your name it flashes
  white twice. Action items Moe spots appear on the right.

Each side stays narrow at rest, so it covers as little of the menu bar as it
can. Open the panel and it simply drops down in black, with no light around
it.

### Popping the chat out of the notch

If the panel under the notch is in the way, take the chat out of it and put
it anywhere. Three ways do it:

- the **pop-out** button in the panel's header, beside the ⌃;
- **Pop Out Chat** in the Moe menu, or in the menu bar icon's menu;
- **⌃⌥P**, from any app.

The chat opens in a window of its own, the first time in the top-right corner
of the screen. It is the same conversation, not a copy: the same messages,
the same **⋯** controls, the same box to type in (with whatever you had half
typed), and the same **+** for photos and files, whose pickers open in front
of the window on the desktop you are on. You can also drop a file anywhere
on the window.

- **Move it** by dragging its header, to any part of any screen.
- **Resize it** from any edge or corner. Widen it and the conversation
  widens with it.
- **It stays over every app**, on every desktop and over apps in full
  screen. Clicking it, scrolling it or pressing its buttons leaves the app
  you are in in front; clicking into the box to type gives it the keyboard.
- **Keep on top** is the pin in the header. Turn it off and the window
  behaves like any other, so the app you click covers it. Right-click the
  header for **See-Through When Not in Use**, which fades the window
  slightly while you are working somewhere else.
- **Close it** with the **✕** or **Esc**. Closing is only putting it away:
  the conversation carries on, and a click on the notch, **⌃⌥P**, or an
  answer Moe wants you to see brings it back where you left it.
- **Put it back** with the **put back in the notch** button in its header,
  **Put Chat Back in the Notch** in the Moe menu, or **⌃⌥P** while it is in
  front of you. The panel opens under the notch again with the conversation
  in it.

While the chat is out, the notch shows only its usual small signs, and
hovering it or clicking it brings the window to the front, even over a
full-screen app (hovering only while **Hovering the notch opens it** is on). A meeting still
uses the notch's own panel. The window remembers where you
put it on each display, and comes back to the same place, kept fully on
screen if the display has changed. If you quit Memoe with the chat popped
out, it stays out next time, and opens when you first want it.

On a 16-inch MacBook Pro the strip beside the notch has room for one fewer
button, so there the pop-out takes the place of **new conversation** in the
panel's header; **new conversation** is still in the popped-out window.

### While Moe is working

These five are under **More** in Settings › Voice.

- **Say "on it" as soon as I ask** — off to start with. Said the moment you
  finish asking, before Moe has started on the answer, so you know it heard
  you. It is said from your Mac, before anything is asked of the model, and
  it only ever repeats what you asked and never guesses how it will go.
- **Tell me what it's doing while it works** — on. "Checking your calendar",
  said when something takes a while; you are listening rather than
  watching, and a long silence sounds like Moe has stopped. Off, Moe says
  nothing between "on it" and the answer; the island still shows the step.
- **Ding when a written answer is ready** — on. One soft note, only when Moe
  is not going to say the answer out loud, so a question you typed and went
  back to work does not sit unread in the panel. **Hear it** plays the note.
- **Typed questions open the Chat window** — off. The answer stays in the
  panel under the notch, on whatever you were reading; a question asked
  while looking at your notes is often about the notes. On, every question
  you type opens Chat, where a long answer has room.
- **Hovering the notch opens it** — on. Resting the pointer on the notch
  opens its small panel, or brings the chat window forward when the chat is
  popped out. Off, hovering does nothing and only a click opens it.

**Handing a job off.** Say "in the background", or ask for something that
is plainly a long job you do not need to sit through, and Moe hands it to a
helper of its own, tells you in one line that it is running, and gives you
the conversation back. Ask it something else meanwhile; it answers. When
the helper finishes, Moe tells you the outcome the way it would a reminder:
spoken, in its own words, with what got done, what did not, and anything
you need to decide. That is the whole of what you hear about it; the
helper's own steps stay in its transcript. It works the same whichever
brain Moe thinks with.

A finished helper does not wait behind anything on the island: a reminder
or suggestion you have not answered yet stays where it is, and Moe tells you
the helper's outcome as soon as it is not busy talking or listening, and not
during a meeting. The outcome comes back in the conversation you handed the
job off from. If you have moved to another conversation by then, Moe says in
the one you are in which conversation it belongs to, and offers it on the
island: play it and that conversation opens and Moe tells you there. Signing
in to a different account, or choosing a different AI in
Settings, keeps the conversation you are in, and the helpers you started in
it. The chat stays on screen and Moe carries on from where it was. Changing
only how hard Moe thinks still starts a fresh conversation.

While Moe itself works on something in front of you,
what it says is its own account of the work; there is no stock "still on
it" line, and if you would rather hear nothing at all, **Work silently** on
the notch is the switch.

**A question outlives a sleep.** While Moe is working on something for
you, your Mac does not doze off on its own — the idle timer is held until
the answer is in. Close the lid and it sleeps as ever; if that cut the work
off, Moe notices on wake and carries on where it was, once, telling you it
is picking up rather than starting again. The same if you quit Moe, or it
was closed for you, in the middle of an answer: within half an hour of
opening it again it goes back to that conversation and picks the question
up. It never picks up a question twice, and it never picks up on its own a
question that had already sent, paid, booked or deleted something — that
one stops, tells you why, and waits for you to say the word. If you moved
on while it was about to pick up — asked something else, or started a new
conversation — the old question is dropped, not slipped in behind the new
one.

**A promise to do something is kept.** Once in a long while the part of
Moe that thinks ends its turn on a promise, "one sec while I set up the
search", and then does nothing more. Moe notices when an answer ends on work
it said it was about to do, with nothing running and nothing asked of you,
and tells it once to carry on, or to say plainly why it can't. What it says
next follows on in the same answer, and you can interrupt it, pause it or
talk over it as you would any answer. It never does this after a question
or an offer that waits on you ("want me to…?", "tell me which and I'll
check"), never when Moe itself stopped the work (for instance after your
Mac slept in the middle of something that sends or pays), and never more
than once for anything you asked.

**If no answer comes back, Moe says so.** Now and then the part of Moe
that thinks ends a turn without a word. Moe does not leave you looking at a
quiet panel: it says *I couldn't answer that. No answer came back. Ask me
again.* (out loud if you asked out loud, and in the chat either way). If it
had already started sending or changing something when that happened, it
says to check what it did before you ask again.

**You can always say the next thing.** Moe does a few things around an
answer that you never see, going back over the conversation for anything
worth remembering, keeping its notes in order, and none of them hold the
conversation: say something while one is running and Moe answers. If Moe is
genuinely still finishing the answer before, your message waits for that one
and is answered next.

### Addresses are shown, never spoken

Moe never reads a web address out loud. Any address in an answer is a real,
clickable link in Chat and in the panel, whether Moe wrote it as a link or
simply as an address, and the spoken version says the label and skips the
address entirely.

### Your inbox

Everything Moe brings up by itself (a reminder you asked for, a question, a
draft it has ready, a morning brief, a heads-up) goes to one inbox, and
stays there until you finish it, or until the thing it was about is over.

**One card per thing.** When Moe has something new to say about something
already in your inbox (the same conversation, the same follow-up, the same
meeting), it updates that card rather than adding another one. The card
shows the newest words and moves back to the top as unread. Once you have
finished a card, a later message about the same thing arrives as a new
card.

**Cards close on their own when the thing is over.** A meeting heads-up
goes once the meeting has started. A follow-up closes when Moe's follow-up
is closed. A draft reply closes when the conversation has been settled or
the offer is more than a day old. These cards move to *Done* with a word
saying why (*Meeting started*, *Settled*, *No longer current*), so you can
still find them.

**Every card has something to tap.** A card is something Moe can finish
with you in one tap: a reply it has drafted, answers to choose from, a send
waiting for your yes, a job of yours that finished, a follow-up to close or
snooze. Your own reminders and routines always arrive, because you asked
for them, and so does anything Moe was told to bring to you. A plain "just
so you know" becomes a card only when it cannot wait. Everything else Moe
would have said stays quiet: no glow, no line by the notch. It is not
thrown away; it is under *Done this week* on the Inbox page for a week,
marked *Kept quiet*, with all its words.

**What Moe does not bring up.** Anything you already have in front of you.
A new email, WhatsApp, Telegram or text is never passed on as it arrives:
you see it in its own app. Moe raises a message only when a person has
been waiting on you for three hours or more, you have not answered in that
chat since, and — for mail, where Moe can tell — you have not opened it.
A business, a newsletter or a marketing text never counts as someone
waiting. Your Reminders stay in the Reminders app, a meeting gets its
ten-minute heads-up and at most one offer to prepare a day (a meeting that
moves is news again), and Moe offers help with any one conversation at most
once a day, and not while you are writing in it.

**When something arrives**, the notch shows one line for a few seconds, what
it is and why, such as *Marketing brief · One Reddit reply ready to post*,
sliding out to the right of the notch, and then settles into a bright white
dot beside it. Nothing opens by itself, nothing is
read out, and whatever you were doing on the island stays where it was.

**Open the island** and you see your conversation, as always. The **tray
icon** at the top carries a count. Press it and the conversation turns into
the inbox; **‹ Chat** at the top of the inbox takes you back, and it is
there even while Moe is working. Closing the panel leaves the inbox too, so
the next time you open it you are back in your conversation. *Needs you*
comes first, then *For your information*. Each item says what kind it is, and its buttons fit it:

- **Reminder**: **Done**, **Snooze** (15 minutes, an hour, this evening,
  tomorrow morning) or **Reply**.
- **Question**: its answers as buttons, or **Answer in words**.
- **Ready for you**, a draft Moe has already written: **Review**, **Done**
  (you handled it yourself), **Not now**, or **Not this kind**, which tells
  Moe to stop offering this kind of thing.
- **Brief**, a report from a job you set up: **Open** or **Got it**.
- **Heads-up**, nothing to do: **Got it**.

**Done**, **Skip** and **Got it** finish it where it came from: a follow-up
Moe was keeping is closed, and Moe stays quiet about that subject until the
thing it came from changes — a Reminder that is edited, moved or ticked
off, a meeting that moves. The same thing said again in different words is
not said; something new about it — a cancellation, a changed time, a new
message — still is. When it came from Apple Reminders,
the inbox asks **Also mark it done in Reminders?**: **Mark done** ticks it
off there, **Leave it** changes nothing. Moe never touches your Reminders
without that tap. **✕** dismisses it: it leaves the count and moves to
*Done* in the Inbox page, and a follow-up behind it goes quiet the same way
Done does. Looking at the inbox puts the bright dot back to its dim one.

**Done is not "no thanks".** Pressing **Done** on a draft Moe prepared means
you dealt with it another way, so Moe does not take it as a sign you do not
want help like that. **Not now** and **Not this kind** are the ones that
tell Moe to hold back.

**Reading one.** **Open** or **Review** puts the whole thing on your screen as a
card, over whatever you are doing: the summary on top, then the rest laid
out as headings and lists. Every draft in it has **Copy**. A draft Moe wrote
for someone has **Send to…**, which still shows you the message and asks
before anything goes, and **Done** for when you took care of it another way. Ask about it in the box at the bottom, **Continue in
island**, or **Open in app**. **✕** or **Esc** closes the card and keeps the
item.

**Replying starts a new conversation**, named after the item, with the item
at the top, so a reminder never lands in the middle of something else. A
strip above the box says *Replying to this. Type below and press Return*,
with **Cancel**, which sends nothing and leaves the item in the inbox. The
item is finished once your answer is sent. A **Back to…** button returns
you to the conversation you were in. If the item
is about what you were just talking about, Moe answers there instead.

**The Inbox page** in the Memoe window shows the same items, filtered by
**All**, **Needs you**, **Reminders**, **Ready** or **Briefs**, with what is
snoozed and what you finished this week below them. A dot marks what you
have not looked at yet. Selecting one shows the same card, so it works the
same wherever you open it. With the keyboard, Tab to the list and ↑ and ↓
walk it, the card on the right following.

**With VoiceOver.** Each card is one stop, read as a sentence (*Unread.
Reminder. Call the dentist before five. 3:00 PM*), and its buttons are its
actions, so Done, Snooze, Archive and the rest are in the Actions menu
instead of being five more stops. The same goes for the cards in the panel
under the notch. If you have **Reduce Motion** on in System Settings ›
Accessibility › Display, a finished card simply goes instead of sliding
away, and the same is true of the questions on the Memory page and the
switches in Settings.

**Clearing many at once.** Above the list, **Mark all read** clears every
unread dot, and **Archive all** moves everything waiting (under the filter
you are on) to *Done*, after asking once. To archive just some, press
**Select** and tick them, or ⌘-click rows to pick them one by one and
⇧-click to pick a run, then **Archive selected**. Archived cards stay under
*Done* for a week, like anything else you finish.

**A fresh start.** The first time you open this version, Moe archives the
cards that piled up before it, keeping only drafts it prepared in the last
two days. Nothing is deleted; the rest are under *Done*.

**Long reports get a real summary.** When a job's report is long, Moe writes
a short title and a one-sentence summary for it with the least expensive
model your own provider offers. If that is not possible, the inbox uses the
report's own headings.

### Moe comes back to things

Moe keeps a list of open loops and brings them up later, without being
asked: on the notch if you are at the Mac, otherwise on whichever chat app
you set up. Five kinds of thing go on it: what you said you'd do; what Moe
started (a booking, an order) and should check landed; people waiting on
you; deadlines, with the preparation done early; and things you looked at
that can change, a price, a slot, a delivery, which Moe watches without
thinking and speaks about only when they move. How it works, and the
switches for it, are under [Running in the
background](#running-in-the-background).

### Knowing where you are

Ask "what's the weather", "is there a pharmacy near me" or "how long to
drive to Newark" and Moe needs to know where you are. It uses your Mac's own
location for that, the same one Maps uses, so the answer is for the town you
are actually in.

The first time a question needs it, macOS asks whether Memoe may use your
location. That is the only time it is asked: not when Moe starts, and not in
the welcome. **Allow**, and Moe answers; from then on it just knows. **Don't
Allow**, and Moe keeps working: it asks you where you are, or goes by the
rough place your internet connection gives, which can be a town or two off,
and tells you that is what it used. It never quietly guesses.

What Moe gets is the town, region and country, and a position rounded to
about a kilometre. An exact position is used only when the question needs
one, such as directions from where you are. Your location is read only while
you are at the Mac asking: never in the background, never for a scheduled
job, and not when you message Moe from your phone, since your phone is not
where your Mac is. It is not sent to us, Moe keeps no log of where you have
been, and it does not add where you are to its memory unless you tell it
where you live.

To change your mind either way: **Settings › Permissions › Location
Services**, or System Settings › Privacy & Security › Location Services.

### Moe changes its own settings

Moe knows every switch in Memoe's Settings, so you don't have to. Tell it
what bothers you in your own words ("stop dinging at me", "your answers are
too long", "the notch keeps popping open") and it finds the setting, says in
a sentence what it is, and offers to change it. You never have to know
there is a setting, or where it lives.

- **Moe can change it for you** — how much it says, sounds, how long the
  panel stays, how the notch and Chat open, how it listens once you have
  started talking, reminders it brings up, quiet hours, and whether it looks
  at what's connected every 10 minutes. It changes one
  only after you say yes, tells you what it changed, and puts it back if
  you ask. A change that makes Moe do more — speak its answers, bring
  things up on its own, listen longer, a new talk key — also shows you a
  confirmation first, so nothing Moe reads can turn those on for it.
- **You flip it yourself** — anything to do with the microphone, your
  screen and moving your mouse, money (Premium voice), which AI Moe uses,
  your language, anything sent to your chats for you, what Moe learns about
  you and keeps as memory, which browser profile it signs in as, and the
  area of the screen meeting pictures take. For these, Moe
  offers to open Settings: the window opens on the right page with the row
  highlighted, and you make the change.

Moe changes or opens Settings only while you are at your Mac. From your
phone it tells you where the setting is instead.

## Driving your Mac

Moe can see your screen and use your Mac, open an app, click a button, fill
a field, through the same accessibility machinery a screen reader uses.
Clicks are delivered straight to the target window in the background, so
your cursor does not move, your keyboard focus does not change, and you can
keep typing while Moe works in another window.

**It tries not to touch the screen at all.** Driving a window is the last
resort, not the first. Asked to open a meeting link, Moe reads the join
address off the calendar event and opens it: no screenshot, no clicking,
nothing that can miss. The order it works through is: the data it already
has, then the app's own scripting, then a menu item or a keyboard shortcut,
then its own browser for anything on the web, and only then a click.

**It knows your apps' menus.** Ask Moe to do something in an app and it can
read that app's menu bar directly, the items and their shortcuts, and invoke
the one it needs by name rather than hunting for it on screen. That is
faster and far more reliable than clicking, and if the item does not exist
Moe is told so plainly. It also works where looking does not: music
software, CAD, 3D tools and games draw their main window as one canvas Moe
cannot read, but their menus are ordinary. Items that are greyed out are
reported as greyed out, which is the difference between "not available right
now" and "does not exist".

### Moe's own browser

When the job is a web page, look something up, fill a form, work through a
site, Moe drives a browser of its own rather than yours. It reads the page
as text, so it knows what the buttons and fields actually are instead of
guessing from a picture, and it clicks the exact one. Nothing appears on
your screen while it happens, nothing takes focus, and your own tabs are
untouched.

**It is signed in as you.** If your default browser is Chrome, Edge or
Brave, Moe browses on a private copy of your profile: your logins and
cookies come along, so a booking site with your account, or a cart you
started, are places Moe can work without you signing it in. The copy lives
in Moe's own folder, is refreshed each time Moe opens its browser — and
again when you sign in to something in your own browser while Moe's is open,
once Chrome has saved it — and never touches the browser you have open.
Google is the one sign-in that does not come along: Google ties it to your
own Chrome. So when a site offers "Continue with Google", Moe presses it and
picks your account in Google's list itself. It only brings the page up for
you if Google then asks for something only you can give — your passkey, a
security key, a verification step or your password — and carries on once you
have done it. Moe's browser is its own application on
your Mac, separate from your Chrome: opening or quitting yours never reaches
Moe's, and Moe's never shows up as yours. To carry your logins across, your
own Chrome runs for a fraction of a second, hidden, on the copy, to read its
cookies and hand them over, and it is gone before Moe's browser starts; Moe
never asks for your Keychain and never keeps its key. Moe's browser closes
itself a couple of minutes after the last job, and when Moe quits. Moe never
starts a second copy of your browser. If a site still blocks Moe's own
browser, Moe can do it in your Chrome instead, once you have added the Memoe
extension (see [Moe in your Chrome](#moe-in-your-chrome)); without it, Moe says
so and offers to do it on your screen with you watching. With Safari, Firefox or Arc as your default,
Moe browses signed out, because it has no profile it can copy. Change your
default browser and Moe follows at its next launch. Away from your Mac, Moe
has a browser of its own on your cloud computer, but not your profile: it
starts with no sign-ins, a site you sign it in to stays signed in only if
the site is on the list in **Settings › Away › Cloud browser**, and
everything else it browses signed out (see [The cloud
browser](#the-cloud-browser)).

**When your signed-in browser won't open.** Now and then Moe can't open its
browser with your logins. It no longer stops dead, and it never carries on
quietly without them: it tells you why and asks whether to continue signed
out. Before anything runs signed out, a card on your Mac asks *Continue
signed out?* Say yes and Moe carries on, and that one yes covers the rest of
the conversation. Say no and nothing runs. Whatever Moe does signed out, it
tells you was not done as you: a site sees a stranger, not your account. A
scheduled job that meets this while you are away does not wait and does not
continue. It tells you what is waiting.

**Signing in on your cloud computer.** When a site there needs you (a
password Moe doesn't have, a code, "is this you?"), Memoe sends a link to your
own chat: *Sign in to x.com on your cloud computer*. It only ever goes to your
own chat, never to anyone Moe is talking to, and Moe itself never sees it. Open it on your phone and tap **Open
the browser**; you see the page as it is on your cloud computer, and you tap
and type into it as you would on any site. Your password goes to the site,
not to Moe. Tap **Done**, tell Moe, and it carries on. The sign-in stays there
for later jobs if the site is on your **Cloud browser** list in Settings ›
Away; otherwise it lasts for that one job, and Moe says so. Passkey-only
sign-ins, with no password, cannot be done this way. The link works for ten minutes, only on the first phone
that opens it (a forwarded copy won't open), and a newer link ends the older
one. Treat it like a key: don't share it.

**"Are you human?" checks.** When a site puts up a check that it is a person
visiting (a "Just a moment" page, an "I'm not a robot" box, a press-and-hold
button), Moe deals with it itself where it can: it waits out a page that
clears on its own, ticks the box, or holds the button, just as you would, and
carries on. It only does this in its own browser on your Mac, never from your
cloud computer. When a check needs more than that, or keeps coming back, Moe
brings the page up in front of you itself, without you having to ask, tells
you in one line what to do, and carries on when you say you are done. It never tries on ticket-selling sites, where
getting past these checks automatically is against the law in the US, and a
page saying your connection has been blocked goes straight to you.

**When no page will load.** If your Mac is set to send web traffic through a
proxy that is not running (System Settings › Network › your connection ›
Details › Proxies; `scutil --proxy` in Terminal shows it), every page in
Moe's browser fails with "There is something wrong with the proxy server".
Moe now says that it is your Mac's proxy setting, not the website, instead of
retrying the site. It never switches the proxy off for you; turn the proxy
off there, or start whatever it points at.

For the picture puzzles ("click every square with a bus"), Moe can use a
solving service on your own account, NopeCHA or CapSolver, once that
service's key is added to Moe's settings. Only the puzzle's picture is sent; Moe clicks the squares itself, in its own browser,
and tries at most three rounds on one puzzle. hCaptcha's puzzles are read
straight from the picture on the page; a puzzle that moves or asks you to
drag something is swapped for a new one (a few times, free) rather than sent
to the service. Without a key, those puzzles come to you. Cloudflare's checks
are never sent to a service.

**When a check comes to you.** Moe shows you its own browser window with that
page open, and anything it had already typed into the form is still there.
Solve the check, tell Moe you are done, and its window goes back out of sight
while it carries on in the background. A sign-in page, or any page in the
middle of something Moe was doing, is never sent to your own Chrome, where it
would mean nothing; if Moe cannot show you its window, it says so. Only a plain
public page may open in your browser, and Moe then says plainly that it is your
browser and that you will need to finish that step there yourself.

A passkey usually cannot be used from Moe's browser, because your passkeys
live with your own Chrome and Touch ID. When a site asks for one, Moe first
tries the page's "Try another way" for something that works anywhere, such
as a prompt on your phone or a code.

**When a page is slow.** A page that is busy, or waiting on a pop-up, gets
half a minute to answer before Moe gives up on that step, and Moe is told
which page it was rather than that its browser broke. A pop-up nobody can
answer is dismissed instead of holding the page. Moe closes the older tabs
it opened itself, keeping at most six, so a long job does not slow down as
it goes.

**Logins and passwords.** When a site wants you signed in, Moe first checks
whether it already has a login saved for that site, and uses it if so. If it
has none, there are two ways to give it one, and in neither does the
password pass through the conversation or through Moe's own thinking:

- **You type it, in Moe's password window.** A small Moe window comes up in
  front of whatever you are doing, headed with the site's address — "Save
  your login for fazier.com". Type your username or email and your password
  (the password box shows dots) and press **Save** or Return; Esc or
  **Cancel** leaves without saving anything. Moe stores the login without
  ever seeing the password, and only ever fills it in on that site. Check the
  address in the heading before you type: if it uses letters from another
  alphabet, the window warns you. A window nobody answers closes by itself
  after five minutes, and nothing is saved.
- **Moe makes one, for a new account.** When Moe is signing you up somewhere
  new, it can make a strong password itself and keep it, so you never have
  to think one up. It asks you first, every time, with a card headed
  **Create an account on fazier.com?** that says Moe will make a strong
  password and keep it for you, and shows the email or username the account
  will use. Press **Create account**, or **Not now** and nothing is made. A
  yes covers that one site only — never the next one, and not for an hour
  the way some browser steps are — and no "always allow" can switch this
  question off. Moe only asks once it has what a signup needs, the page's
  address and the email to use; if either is missing, you are not asked to
  approve something that cannot work: nothing is made, and Moe is told what
  it left out.

**Codes a site emails you.** When a site signs you in by emailing a code
("we sent a 6-digit code to your email"), Moe finds the box for it, reads
the fresh email from that site in your connected mail itself, and puts the
code in. It waits up to a minute for the email to arrive, and it looks in
every Gmail account you connected. It only uses mail that arrived in the
last ten minutes and that comes from, or is about, the site it is signing
in to, and the code never appears in your conversation. It does this only
while you are there, in a conversation you started. A scheduled job never
reads a code out of your mail — a code in your inbox can sign someone in,
and a job runs on words that are not always yours — so the job reports that
the sign-in is waiting for you instead. If no email turns up, Moe asks you
for the code in its password window — "Sign-in code for fazier.com" — where
you type it and press **Enter code**, and Moe puts it in the page without it
appearing in your conversation. If you read a code out to Moe, or type it
in the conversation, Moe does not type it for you yet: it brings the page up
in front of you and asks you to type the code in yourself.

**Passcodes and PINs you know.** When a site asks for a passcode or PIN that
only you know (a chat app's passcode, a PIN to unlock something), Moe does
not stop and tell you it cannot: it asks for it in the same password window,
headed with what the site wants, and you type it there and press **Enter
code**. Moe puts it into the page without ever seeing it, and it never
appears in your conversation. Read it out or type it in the chat instead and
Moe will not use it; it asks you to type it into the window, or into the page
yourself.
<!-- FLIP WHEN recipient-ground LANDS: Moe then enters a code you read out, when it is in what you said just now, at your Mac or in your own chat; never one a page or a message suggests. Same note on MOE_SOUL in moe-home/hermes/configure-hermes.py. -->

**When a page needs you.** Some steps only you can take: a passkey or a
security key, a "confirm it's you" check, an "are you human?" check Moe could
not get past itself. Moe watches for these by what the page says and
offers: a sign-in or verification page that tells you to do one thing
("Use your passkey to confirm it's you"), with nothing else to fill in — not
by the word alone: a sign-in page that merely offers "Sign in with a passkey"
beside a password box, or an article about passkeys, is not one. It reads
English first, and a few common lines in French, German, Spanish and Hebrew;
in other languages it relies on seeing that the page is stuck, and you can
always ask to see the page. Moe's browser is out of sight, so when
it meets one — or when you ask to see the page ("open that so I can approve
it") — and you are at your Mac, Moe brings the page up in front of you in
its own browser window, on the same page and still signed in, tells you in
one line what to do, and waits. Say "done" and it carries on from where you
left the page; the window stays open until you do. If Moe's browser had to
restart to show you the page, every tab comes back, but anything typed on a
page that the site had not saved is gone, and Moe says so. If another
conversation is using Moe's browser at that moment, Moe does not restart it
under that work: it opens the page in its tab group in your Chrome (when
the Memoe extension is connected), or else in your default browser — and
then says that its own sign-in did not come with it.

"At your Mac" means you asked from the Mac itself and it is unlocked, awake
and its display on. If you asked a moment ago and are now waiting without
touching anything, that still counts for the first three minutes. If you are messaging Moe from your phone, or a scheduled job
meets the step, nothing pops up on an empty screen: Moe tells you what is
waiting and where, and picks it up when you are back. Moe only tells you
that something was sent, or is waiting on your phone or another device,
when the site itself said so.

**Which of your profiles.** Chrome keeps one set of logins per profile — the
faces in its profile menu. Moe carries one of them. Left alone, it is
whichever profile you used last, and if you have several that changes as
you switch windows: Moe can be signed in to X in one profile and signed out
in another. **Settings › Permissions › Browse as** lists your profiles by
name and account and lets you pick the one Moe should always use; "Whichever
I used last" is the other choice. It takes effect the next time Moe opens
its browser. The row appears only when there is something to choose — one
profile, or a browser Moe cannot copy, and it stays out of the way.

If Moe meets a sign-in page where you should already be signed in, it
stops and says which profile it is browsing as, and that Browse as picks
another — it does not guess a password, and it does not report the job as
done.

For a tab you have open on screen, or a browser's own menus and dialogs,
Moe looks at the screen the way it looks at any other app.

**Moe does not ask before every click.** Clicking a date, typing a search,
scrolling a list, opening a page: none of that is a question. What Moe asks
about, in a browser, is the moment that matters: paying, buying or booking;
sending a message, an email or a post; deleting or cancelling something that
does not come back; entering a password or a card number; letting an app
into one of your accounts. One yes covers that kind of moment for the rest
of the conversation, up to an hour, so a booking is one question, not one
per page. See [Before anything goes out](#before-anything-goes-out).

### Moe in your Chrome

Some sites refuse any browser but the one you use yourself. For those, and
whenever you ask, Moe can work in your own Chrome through the **Memoe
extension**. Moe works in its own tab group in your Chrome, only on turns you
start; Chrome shows a bar while it does.

- **Its own tab group.** Moe's tabs sit in a group called *Moe*, in a window
  of their own behind yours. Moe never reads, moves, closes or types into a
  tab outside that group — unless you ask, or drag a tab into it — and it
  leaves your focus where it is.
- **Only on turns you start.** A scheduled job, a background task or a
  message from your phone uses Moe's own browser, never yours.
- **The bar.** While Moe is working in a tab, Chrome shows *"Memoe — Moe in your
  Chrome" started debugging this browser* across the top. That is Chrome saying an extension
  is at work; it goes when Moe is done.

**Setting it up.** Open **Connections › Moe in your Chrome** and click **Add
to Chrome**. Memoe tells Chrome how to reach it and opens the extension's page
on the Chrome Web Store in your Chrome. There, click **Add to Chrome**, then
**Add extension**. The row turns to **Connected** within a few seconds, and
Chrome keeps the extension up to date from then on. If the store page did not
open, click **Add to Chrome** again. Without Google Chrome on the Mac, the
button says to install it first and changes nothing.

**What the row says.** It names what is wrong, not just that something is:

- **Not installed** — the extension is not in your Chrome yet: **Add to Chrome**.
- **Installed, not connected** — it is in Chrome, and Memoe is ready for it,
  but it has not connected. Chrome may be closed (**Open Chrome**), or the
  extension is in a Chrome profile that is not the one open: open that
  profile, or add Memoe to the one you use.
- **In another Chrome profile** — Memoe can see the extension is only in a
  profile that is not open, and names it. **Add to this profile** opens the
  store page in the profile Chrome is using.
- **Installed, can't reach Memoe** — the extension is in Chrome, but the link
  Memoe gives Chrome is missing, out of date or broken, so the two cannot talk.
  **Repair** rewrites it. Memoe also mends an out-of-date link by itself each
  time it opens.
- **Off** and **Connected**. If it also says Chrome lets the extension open
  files on your Mac, turn off **Allow access to file URLs** under Chrome ›
  Extensions › Memoe; Moe never uses it.

**In Chrome, too.** When the extension cannot reach Memoe, its toolbar button
shows a red **!**; hold the pointer over it to see why (Memoe isn't set up for
Chrome, Memoe doesn't recognise this copy yet, or its link stopped) and where
to fix it. Click the button to try again; the **!** goes as soon as it
connects. And if you ask Moe to use your Chrome while it cannot, Moe tells you
which of these it is rather than only that it failed.

**Turning it off.** **Turn off** on the same row stops Moe using your Chrome
within a few seconds. The extension stays in Chrome until you remove it there
(Chrome › Extensions › Memoe › Remove). **Turn on** brings it back.

If Moe needs your Chrome and the extension is not connected, a Fix card says
so with a **Set up Chrome** button that opens this row.

### Windows on another desktop

If you use several Spaces, an app on a desktop you are not looking at cannot
be clicked; macOS does not allow it. Moe can still read such a window, and
it will tell you where the window is rather than pretending the app is
missing. **Let Moe bring a window to the front when it has to**, in Settings
› Permissions under *Moe and your screen*, is on: for the few things that cannot be
done in the background, a window on another desktop, a minimised one, or a
menu in an app that is not in front, Moe brings that window forward, which
on a full-screen app means moving you to another desktop. Off, it leaves
your screen alone and tells you what it could not reach. Reading the screen
is never affected either way.

### It stops instead of looping

Every action comes back with a verdict saying whether it actually landed,
and Moe checks that rather than assuming. If the same action returns the
same result several times, Moe changes approach; if it happens again, the
action is refused outright and Moe tells you what it is seeing and asks.
Actions whose whole point is repetition, scrolling, arrow keys, undo, are
never counted against that.

**And it knows when to stop.** A screen task has an allowance: 150 actions,
and 30 looks in a row with nothing done between them. Past those, Moe stops
and tells you where it got to and what is in the way, rather than clicking
on for another ten minutes; the allowance refills once you have answered.

### You can always stop it

While Moe has your screen the notch says so in words beside it, *Using
Safari* with a **Stop** you can click, and a thin magenta line glows around
the edge of the screen, so you can tell at a glance, wherever you are
looking, that it is clicking and typing rather than just thinking. The line never gets in
the way of a click and never shows in a screenshot. When Moe is in its own
browser, working through a page off-screen, the notch says *Browsing*. Hover
the notch and the word in the open panel names the same thing; the stop icon behind the **⋯** turns magenta and its label says
what it ends: **End computer use** or **End browser use**. Pressing it gives
up the whole run: no further click
or keystroke is sent, and whatever Moe was part way through is abandoned
rather than finished behind your back. **Stop** beside the folded notch
does the same. The words and the line go when the run ends.
Stopping is something you do, not something Moe guesses: it cannot tell your
hand on the mouse from its own typing, so it does not try.

Moe never types a password, a passcode, a PIN, a 2FA code, a card number or
a recovery phrase you read out to it or that it sees on screen. That does not
stop the job: in a web page, it asks you for it in its password window and
enters it without seeing it; anywhere else, it tells you which field needs
you, waits while you type it, and carries on.

Screen access needs two macOS permissions, Accessibility and Screen
Recording, and they belong to the small driver Moe installs for this rather
than to Moe itself; Settings › Permissions shows which are missing and takes
you to the right place.

### Settings › Permissions

What Moe asks macOS for, and whether macOS has said yes. None of these is
required: Moe works without every one of them. A permission you don't give
just switches that one thing off, and Moe says so instead of pretending it
looked. Nine rows, in the order they tend to come up:

- **Microphone** — hearing you while you hold the talk key.
- **Accessibility** — noticing the talk key while you are in another app.
- **Input Monitoring** — the same job; some Macs ask here instead.
- **Automation** — asking Notes, Calendar and Messages for what is in them,
  and clicking and typing on your behalf when you ask Moe to drive the Mac.
- **Calendar** — what you have on, every calendar in Calendar.app including
  Google ones, and adding events when you ask.
- **Reminders** — what you still owe people, and adding one when you ask.
- **Contacts** — who you mean when you say a name.
- **Full Disk Access** — the things macOS keeps locked away even from you:
  Messages and SMS, call history, Chrome history, and the Google Drive
  folder on this Mac.
- **Screen & System Audio Recording** — seeing your screen when you ask
  "what do I do here", and recording the other side of a call in a meeting.

Under those, **Location Services** — which town you are in, for the weather,
"near me" and directions. It says *Not asked yet* until the first question
that needs it, because that is when macOS asks; see [Knowing where you
are](#knowing-where-you-are).

The word beside each name is the state: **Allowed**, **Not allowed**, **Not
asked yet** (nothing is broken; Moe has not needed it yet) or **Can't
tell**. Input Monitoring and Automation always say *Can't tell*: macOS gives
no way to read those two without either prompting you or guessing, and an
honest blank beats a wrong guess. **Re-check** at the top reads them all
again.

**How do I?** on a row (**Details**, on one that is allowed) opens what it
is for, what happens if you say no, the click path in System Settings, and
**Open the settings pane**, which takes you to the right place. The three
permissions macOS only reads when an app launches, Input Monitoring, Full
Disk Access and Screen Recording, also offer **Quit and reopen Memoe**.
Accessibility does not: it works the moment you switch it on, and the pane
says so. On Accessibility there is one thing more: if System Settings
shows Moe switched on and this still says Not allowed, that switch belongs
to an older copy of Memoe; **Reset and ask again** clears it, and you switch
Moe on once more.

**Moe and your screen**, under the rows, holds three switches about what Moe
may see and touch on the screen: **Moe sees my screen when I ask** (on),
**Move my mouse to what Moe points at** (off) and **Let Moe bring a window to
the front when it has to** (on). *Talking to Moe* and *Driving your Mac* say
what each does.

**What Moe is allowed to do**, below them, is about Moe's own hands
rather than macOS's. Moe can do anything read-only on this Mac without
asking; sending mail, sending messages, sharing files and deleting are
denied to start with, because a voice assistant has nowhere to show you an
approval dialog mid-sentence, so the safe default is that nothing leaves
your machine. **Edit the permission rules** opens the file those rules live
in, where you can move a line from deny to allow when you decide you want
it; restart Memoe afterwards. It is a guard rail, not a sandbox: the real
protection is that outbound actions are off until you say otherwise, and
what stands in front of a send when you do is the next page.

### When something needs a switch turned on

Sometimes Moe can't do what you asked because macOS, or one of your
connections, is keeping it out: Memoe isn't allowed to read Chrome's data,
or into your Desktop folder, or to control Notes. When that happens a
**Fix card** appears on the panel under the notch and in Chat: one line
saying what is in the way, in plain words, and a button that fixes it.

- **Open Settings** opens the exact page of System Settings where the
  switch is. Turn it on and Moe notices within a couple of seconds, then
  carries on with what you asked — you don't have to ask again. It keeps
  looking for five minutes; after that, just ask again.
- Moe also tells you in its reply what is in the way, in one sentence, and
  offers to open the setting. Say yes and it opens the page for you, the
  same way the button does. It only does that while you are there, in a
  conversation you started: never from a scheduled job, a background task or
  a message from your phone.
- The card always names **whose** switch it is. Most are Memoe's own (Memoe
  Dev's, if you are running that). Seeing and using your screen is done by
  a helper called **CuaDriver**, which has its own rows under Accessibility
  and Screen & System Audio Recording; when the card says *CuaDriver (the
  screen helper)*, that is the one to switch on, not Memoe.
- Some fixes aren't a switch. A connection that needs you to sign in again
  offers **Open Connections**; an expired sign-in to Claude offers **Sign
  in**; Moe's Chrome extension not being connected offers **Set up Chrome**,
  which opens [Moe in your Chrome](#moe-in-your-chrome); a screen helper that has stopped offers **Quit and reopen Memoe**,
  which starts it again. A few only explain what happened, with **Dismiss**.
- A window on another desktop gets no card: Moe switches to it, or asks you
  to.
- The card only ever names things it recognises — a browser, a folder like
  Desktop or Downloads, an app like Notes, a connection like GitHub. Anything
  else is just "another app", "that folder" or "a connection", so nothing a
  web page or a program says can put its own words on the card.
- A card about controlling another app (Automation) appears only after Memoe
  has checked with macOS that the switch really is off for that app.

A card shows once for each cause while Moe works on one request, however
many times the same thing failed, and goes when you press a button,
**Dismiss** it, or ask Moe something new. Moe never turns a permission on
for you (macOS doesn't allow it); it tells you which one and takes you there.

## Before anything goes out

Moe never sends anything to another person on its own. When it is about to,
an email, a WhatsApp or Telegram message, a reply in a thread, a calendar
invitation, a file shared with someone, a sheet opens on this Mac first:
which service it is going out on, who it is going to, and the whole
message. **Send** sends it. **Cancel** (or Esc) does not, and Moe is told
you said no rather than trying again. The line at the top says *Nothing has
been sent yet* for as long as the sheet is up. Return is deliberately bound
to nothing; ⌘↩ is Send.

**You can change the words before they go.** The message on the sheet is a
field, not a label: click into it, fix the sentence, cut the paragraph, add
the thing Moe forgot, and click **Send**. The button says *Send edited* when
you have changed something, and what goes out is exactly what is in the
field. A mail's subject can be rewritten the same way. Who it is going to
cannot: change your mind about the recipient and it is Cancel and ask
again. The words stay read-only when a message contains characters that can
reorder text on screen (the sheet names them instead), when it is too long
to draw whole, or when the service has nowhere to take an edited version
back to.

**Moe knows the sheet is waiting on you.** When it opens, Moe says so, "It's
up on your screen — press Send when it looks right, or change the words
first", and the island reads *Waiting for you to press Send* until you
answer. If you take your time, Moe reminds you once. When you have
answered, Moe tells you what happened: sent, or cancelled. (This is Moe on
your Mac. When your Mac is closed, Moe Away asks on your phone instead; see
[Away](#away-moe-when-your-mac-is-closed).)

**The sheet gets out of your way.** It arrives in front of everything, off
to the side of Memoe's own windows when there is room, so it does not land
on top of the chat it is about. Drag it anywhere by its top strip. The
moment you click somewhere else it stops floating over your other windows;
it stays on every desktop, one click away, until you answer it. **Cancel**
works on the first click, even when the sheet is not the window in front;
Esc works while it is. (Send alone waits half a second after the sheet comes
forward, so a click that was already on its way to something else cannot
send.)

**A sheet never outlives what asked for it.** If the task that wanted to
send stops before you answer, whether it finished, was interrupted, or you
moved to another conversation, the sheet closes itself and nothing is sent.
Once you have pressed Send, the send is let finish, and Moe reports what
actually happened. The same
happens when nobody answers within its time (never more than an hour). If
you were away and the sheet never reached your screen, it leaves one note on
the island saying what did not happen: *That WhatsApp send to "Dad" expired
before you answered — nothing was sent*, or *…was withdrawn because the task
that asked for it stopped*. If you saw the sheet go, or you are at the Mac,
there is no note — you already know.

**Sends from background work.** When a scheduled job or a helper working on
its own wants to send a WhatsApp, Telegram or Gmail message through Moe's own
connection on this Mac:

- **If you are at the Mac**, the sheet appears as usual, marked *Asked by a
  scheduled job, not by anything you just said*, so it is not mistaken for
  part of what you are doing.
- **If you have stepped away** (the screen is locked, the Mac is asleep, or
  it has not been used for a few minutes), no sheet is put on an empty
  screen. The send waits on the island instead: *Waiting on you: a scheduled
  job wanted to send a WhatsApp message to "Dad": "Running late". Nothing has
  been sent.* Play it and say yes, and Moe puts the usual sheet in front of
  you; say no, or ignore it, and it is never sent. A day after it was
  asked, a held send that is still unanswered is taken down, even if it is
  showing on the island, and the island says it expired and nothing was
  sent; it can no longer be sent from there.

Only work Moe knows started without you counts as background work: a
scheduled job, a helper, a background worker, a webhook. A message you send
Moe yourself, from your phone or anywhere else, is always treated as yours.

The same goes for everything else background work wants to do that would
normally show a sheet: a Gmail send through Composio, a post or a click on
a website, a Return on the screen. If you are at the Mac you get the sheet,
marked with who asked. If you have stepped away, nothing waits on an empty
screen: the job stops at that step straight away, nothing is typed, pressed
or sent, and the island tells you what it wanted to do (*Waiting on you: a
scheduled job wanted to “Click a button on x.com”. Nothing was done.*). A job
that tries the same thing again asks you once, not once per try. The job's
own report says plainly that it is waiting on your OK, so it no longer blames
the website for a step Moe held back.

A sheet that background work put up closes itself, sending nothing, when
the job that asked stops, or after about five minutes with no answer, and
Moe is told that nobody answered, not that something broke.

### When the sheet appears

The sheet appears for exactly the things that reach another person, on
every route Moe has to them:

- **Mail** — Gmail, through your own mailbox on this Mac or through Google
  via Composio. Sending, replying, forwarding, sending a draft. *Writing* a
  draft is not a send; it stays in your mailbox.
- **Chats** — WhatsApp, Telegram, and any other chat app Moe is connected
  to. The one exception is a note Moe sends to *your own* Telegram: that is
  how meeting notes reach your phone.
- **Invitations and sharing** — a calendar event with guests on it, a Drive
  file shared with someone. Each of those puts a message in somebody's
  inbox.
- **The keyboard** — while Moe is driving your Mac, pressing Return in a
  message box is what sends in Mail, Messages, Slack and every web chat, so
  that key is asked about too. The first Return in a computer-use session
  asks, and saying yes covers the rest of that session for an hour. Quitting
  an app (⌘Q) is asked about the same way, because unsaved work is lost.
- **A browser** — five moments: paying, buying or booking; sending a
  message, an email or a post; deleting or cancelling something that may not
  come back; typing a password, a card number or another secret into a page
  (a button or link that mentions a password, like "Forgot password", is
  not one); letting an app into one of your accounts. The first one of a kind in a
  conversation asks, and the yes covers that kind of moment for the rest of
  the conversation, up to an hour. A click, a keypress or a page opening is
  never a sheet on its own. Posting counts on any site, not just the ones
  Moe knows by name: if Moe has typed into a page and is about to submit
  it — a forum post, a comment, a form with your words in it — that asks.
  Searching and signing in do not.
- **GitHub** — anything that writes: opening a pull request, pushing a file,
  merging, commenting, deleting.

It never appears for reading. Searching your mail, listing your calendar,
opening a Drive file, checking a WhatsApp chat, looking something up in a
spreadsheet: none of that is a dialog, whichever route Moe takes.

**Nor for writing a draft, or for writing about sending.** Ask Moe to open
a reply to an email, forward one, or start a new message, and it does, with
no sheet, because nothing has gone anywhere; if Moe is then asked to send
it, that is when the sheet opens. And a note that says "email the team
about this", or a ticket describing a mail problem, is words about sending,
not a send: Moe reads what a command does, never what it is carrying.

**Or let the whole session run.** A browser or screen sheet has a third
button, **Allow everything this session**. One click, and every one of
those moments in that conversation, a post, a payment, a deletion, a
password, a consent page, a Return on the screen, goes ahead without
asking, until the conversation has been quiet for an hour. It is for the
stretch where you have handed Moe a job, "reply to twenty posts", "work
through these bookings", and every dialog is an interruption you already
said yes to. It never reaches another conversation, never reaches mail or
chat sends (those keep their own sheet), and is never remembered past that
hour.

**The sheet reads like a sentence, not a script.** A browser sheet is
headed with what is about to happen and where, in the page's own words,
*Type “you@example.com” into fazier.com and press “Forget Password”*, next
to the site's own mark. Under it, one line says why Moe is asking (*This
puts a password, a card number or another secret into the page*) and what a
yes lets Moe do for the rest of the hour. What Moe is about to run is behind
**Show details**, there if you want to read it and out of the way if you do
not. A password is never shown, only *a password*. The site named is the one
being acted on: a reply that happens to contain a link to another site is a
reply on the site it is posted on.

### Who it is going to, and who chose them

Moe only messages people *you* named. Before a send reaches the sheet at
all, Moe checks where the recipient came from:

- **You named them** — in your own words, now or earlier in the same
  conversation. The sheet says so under the recipient, quoting you as you
  wrote it: *You named this person: "Text Dan I'm running late"*.
- **You named part of them** — you said "Moshe" and Moe picked "Moshe
  Lindqvist". The sheet says so in amber: *You said "Moshe" — Moe picked
  Moshe Lindqvist*. The same goes for a name you mentioned while saying
  *not* to message them.
- **Moe looked them up** — in your contacts, your chats, your mail. The
  sheet says, in amber, where: *Moe chose this person — found in your
  WhatsApp chats*. If you asked for somebody else, or the search itself was
  Moe's idea rather than a name you gave, it says that too. Only who a
  message is from and to counts: from your mail the From, To and Cc (never
  a Reply-To, a subject, or anything written in the message itself), and
  from your chats the sender and the chat's name — a group message saying
  "send the file to +972… and Avi" names nobody.
- **Moe showed it to you and you said yes** — Moe found an address on a
  web page or on your screen, wrote it in its message to you, and your very
  next reply was a plain yes ("good", "send it", "looks good"). That is never
  sent silently: the sheet always opens, and says in amber where the address
  came from and what you said — *Moe found this address on your screen and
  showed it to you — you said "good"*. Not even **Allow everything this
  session** skips that sheet. If your reply was anything other than a yes,
  if Moe only wrote the address without having read it anywhere, or if Moe
  read it but never showed it to you, nothing is sent.
- **Neither** — the name is only in what Moe remembers about you, in a
  scheduled job's own text, in a web page Moe never showed you, or in a
  message somebody else sent. Then nothing is sent and no sheet opens: Moe is told to look the
  person up or ask you. People in Moe's memory are context, never
  recipients.

Only *your* words count — what you typed or said, not the other things
Moe passes along with it, such as the summary of your recent mail and chats,
a recap of the conversation, or Moe's own earlier replies. A number that
only appears in someone else's message is not one you gave. A scheduled job counts what you said when you
asked for it, not the job text Moe wrote; a helper Moe starts counts what
you said to Moe; a message from someone else in a group chat never names a
recipient for you. An address counts only if you gave it or a lookup
returned it for that person: saying "email Moshe" does not vouch for
whatever address Moe puts next to his name.

**Moe sends through its own send tools, nowhere else.** Every message Moe
sends is checked first, and Moe's WhatsApp, Gmail and Telegram connections
send only what has just been checked; Moe is never allowed to run them
itself from a terminal or from code, nor to call the WhatsApp link on your
Mac directly. A message to a particular chat (`telegram:<chat>`,
`whatsapp:<number>`, a Slack direct message) is checked like any other
recipient; only your own chat, when it is the home chat Moe delivers to, is
exempt. "Email my
accountant" works when Moe finds them in your Contacts — that lookup counts.
(Writing into a website's own compose box in your browser is not covered by
this check yet; the ordinary confirmation for acting on a site still is.)

**Scheduled jobs.** A job counts the words of the conversation in which you
asked for it; a job you set up in Settings › Reminders counts what you typed
into the form. A job made before Moe checked recipients has no such record:
what it sends to a person its own text asks it to message still reaches the
sheet, marked in amber *This job was made before Moe checked recipients*,
and Settings › Reminders asks you once, per job, *This job messages Dan —
keep?* — **Keep** records your answer and the amber goes away. Anybody else
such a job tries to message is stopped, and an old job that messages nobody
(a digest, a summary) is simply treated like a new one. A job that names
someone by who they are to you — "text my wife", "send mom the list",
"remind dan" — is asked about too.

**Messages meant for you.** When you ask for something to come to you —
"email it to me", "message me when it's done" — Moe may send it to your own
address, and your own Telegram still gets your meeting notes. A message
whose only recipient is you that nobody asked for is stopped, and a request
to reach you is never sent to one of your contacts instead: Moe is told to
reach you its own way, or to put it in its reply. Who "you" are is written
down on your Mac from the accounts you have linked (your own Telegram, the
WhatsApp number this Mac is linked as, the Google account you signed in
with, the mailboxes Moe reads — including Gmail connected through Composio —
your Mac account's name, and any nicknames you add), in Moe's own folder.

**Replies Moe prepared for you.** When you press **Use draft** on a reply
Moe offered and it is not sent, the chat says why in words — the offer was
more than ten minutes old, the request did not come from the Memoe app, or
the app's signature could not be checked — instead of just "Not sent".

On WhatsApp, Telegram, Messages (iMessage and SMS), Apple Mail and every
service connected through Composio, **Use draft** is sent by your Mac
itself, straight to the conversation the offer came from — no AI chooses
who it goes to — after the same send sheet, where you can still change the
words. In Apple Mail it is a reply to the newest message someone else wrote
in that conversation. Messages and Mail need Memoe allowed to control them
(**System Settings › Privacy & Security › Automation**); a Messages chat
Moe only knows by a phone number, not as a chat, is handed to Moe to send
instead.

### The smaller question

A smaller dialog covers the things that change something without messaging
anyone: rewriting a spreadsheet, adding a task, creating an event with no
guests, or a tool from a service Moe has never seen. It asks one plain
question, *Let Moe make a change in Google Sheets?*, or for something Moe
has not used before, *Let Moe try something it hasn’t done before?*, and
says in a line why it is asking. The tool's own name and exactly what Moe
would hand it are behind **Show details**. It says *Nothing has been done
yet*, with **Do it**, **Always allow** (don’t ask about this again) for that
one tool, or **Cancel**.
That memory is per tool: allowing a Sheets edit says nothing about Tasks,
and nothing you allow ever silences the send sheet. Moe's own housekeeping,
closing a follow-up you have answered, moving a reminder, asks nothing at
all.

Moe cannot change the check itself. The files that decide whether to ask
you, and the list of what you have allowed, are refused to it outright, by
whatever name or route it reaches for them, and so is moving or deleting the
folder they sit in. There is no dialog for that, because it is not a
question you should be handed. The list of what you allowed is yours to
change, in your own Terminal.

## Meetings

Moe sits in on a meeting on your Mac, records your microphone and the call's
audio, writes a live transcript and, at the end, notes: a title, a summary,
decisions, action items, to-dos and open questions. Everything stays on
your Mac. Recording never starts without you.

### Starting a meeting

Four ways, all explicit:

- **The Memoe menu** or the menu-bar icon: *Start meeting*.
- **Just ask, in your own words**, spoken or typed. "Start a meeting",
  "begin taking notes", "record this call"; "stop taking notes", "wrap up
  the meeting" to finish. Moe recognises the plain ones itself, instantly; a
  wording it does not know goes to its thinking part, which asks Moe to
  start, so a phrasing that has never been seen before still works. Either
  way the consent sheet still appears and the red ring still comes on.
- **⌃⌥M**, off by default: a global shortcut that records other people is
  one you switch on yourself, under *Advanced* on the Meetings page.
- **The Meetings page**: **Start meeting**.

A consent sheet appears first: what is captured, where it goes, and that
the other people should be told. **Copy a line to tell them** puts a
one-line announcement on your clipboard to paste into the call's chat;
Moe cannot tell them itself. **Ask before starting**, on the Meetings page,
turns the sheet off. While recording, a red ring sits around the notch. Red
means one thing: you are being recorded. It dims while you are off the
record.

### Noticing a call automatically

Moe can notice when you're on a call and offer to record it, so you don't
have to remember to start one. It asks macOS which app has the microphone
open: Zoom, Teams, FaceTime, Slack, Discord, Webex, WhatsApp, Signal, and a
browser on a Google Meet call, among others. It never listens to the audio
to decide this. For a browser, which could just as easily be a voice-typing
site, Moe also checks whether the camera is on: a browser holding the
microphone with the camera on is a video call, and Moe offers to record it
within a few seconds. A browser holding only the microphone waits longer
before Moe asks. The one lag Moe can't remove is that a browser only opens
the microphone when you actually join the call, not on the preview screen.

**Settings › Meeting Capture › Noticing calls:**

- **When a call starts** — **Offer to record** (the default): the island
  glows amber and opens by itself under the notch, "Zoom meeting detected —
  Record it?", with **Record**, **Not this one**, and **Never for Zoom**. It
  never takes your keyboard, and it is asked only there. Each app uses its
  own word (Slack's is a *huddle*). **Start recording**: the same question
  counts down five seconds and then starts by itself; the consent sheet
  still applies, and you can cancel it. **Don't notice calls** switches it
  off entirely.
- **Never for …** lists each app you said never for, with **Ask again**.
- **When the call ends** — on. Moe stops the recording, saves it and writes
  the notes without asking, about half a minute after the call app lets go
  of the microphone (long enough that a reconnect or a mute doesn't end
  anything). This is a separate switch from the one above on purpose:
  whether to *start* recording people is your decision, but a recording you
  already started has nothing left to capture once the call is over. Off,
  Moe asks on the island, **Stop** or **Keep going**, and waits.
  It applies to meetings you started by hand as well as ones that began
  from the card.

**Your call keeps working.** Recording never takes the microphone away from
the call. Moe normally cancels echo on its own copy of the microphone, so it
doesn't transcribe the other side twice when you're on speakers, but on a
Mac that mode changes the built-in microphone for every app at once, and
some call apps then send silence to the other side. So while a call app has
the microphone, Moe records plainly and leaves the microphone as the call
expects it. With headphones or earbuds nothing changes either way. A call
app is believed at once; a browser only once it has kept the microphone for
about ten seconds, because a web page can open it for a moment for all sorts
of reasons. Echo cancellation comes back once the microphone has been free
for about ten seconds, and never in the middle of something Moe is saying.

### The live experience

While a meeting records, hover the notch to see the panel. Beside the notch
it says **Recording** with a red dot, and the time on the other side. It
opens on the **Transcript**, you and the others in two colours, with **Ask
Moe** and, once there is anything to show, **To do** a tab away. Under the
transcript is a place to ask Moe something quietly: hold the talk key and
whisper, or type into *Ask Moe about the call, quietly*. Hovering never puts
the cursor in that box, so a pass of the mouse can't take your typing away
from the call; click the panel, or the box, to type. Replies are shown,
never spoken, while recording.

Every control is behind the small **⋯**, as in the rest of the island:
**mark this moment**, **off the record**, **screenshot**, **record the
screen**, and a red **stop**, which ends the recording and writes the notes.
Their keyboard shortcuts work whether the ⋯ is open or not. If one of them is
actually running (you're off the record, or a screen clip is going) its icon
stays out beside the ⋯, filled in, so you can always see and stop what is
running. Off the record, the word beside the notch says so and the red dot
goes grey.

Beside the ⋯, in small type: *331 lines · 4 voices*, how much has
been said and how many people Moe has managed to tell apart so far. If it
says *only your voice* in the middle of a call with other people, Moe is not
hearing the call audio; see below.

Other live touches:

- **Note this** — ⌃⌥Space, or a tap of the hold key, drops a bookmark; the
  moments you mark, and what was being said, are weighted in the summary.
- **Catch me up** — away more than three minutes (screen locked, asleep, or
  idle) and back, Moe recaps what you missed.
- **What did they just say?** — ask, and Moe reads it back from the
  transcript at once.
- **Your name** — the ring flashes and the panel shows the line when your
  name comes up.
- **Live action items** — every two minutes the new lines go to your AI to
  spot action items, shown as a count on the **To do** tab and confirmed by
  the summary. This check uses the cheapest model your AI provider offers,
  so an hour-long call barely touches your allowance.
- **Off the record** — pause; nothing said while paused is recorded or
  transcribed, and the notes say where the gap was.

### When Moe can't hear the call

Moe records two things: your microphone, and the call's own audio. Who said
what depends on both. If the second one stops carrying sound, the microphone
is all that is left, and since it also picks up the other people through
your speakers, everything gets written down as yours.

Moe watches for this while the meeting runs and fixes it without being
asked: if something is playing on your Mac and no call audio has reached
Moe for a while, it turns off its own echo cancellation and tries again,
then rebuilds the connection to the call audio, twice. Most of the time you
will never know it happened.

The panel only tells you when the call audio has carried nothing at all
since the meeting began, in a bar you have to answer: *No call audio is
reaching Moe. If you are on a call, only your microphone is being recorded
— everyone on it will be written down as you.* **Open Settings** goes to
Privacy & Security › Screen & System Audio Recording, which is the usual
cause. **I know** dismisses it and carries on recording; half a meeting is
worth more than none, and in an in-person meeting there is no call audio to
miss.

### Screenshots and screen recording

Moe can capture what's shown during a meeting, the slides, a shared screen,
a demo someone walks you through, as screenshots and short silent clips,
kept in the meeting's own folder and listed in the notes. Moe's own windows
are never in the picture.

**Settings › Meeting Capture › Pictures of the screen during a call:**

- **Screenshots** — **Off**, **When I ask** (the default), or
  **Automatically**. Press ⌃⌥S for one, or ask, "grab that slide".
- **Screen recordings** — the same three, starting on **When I ask**. A
  clip of up to three minutes; ⌃⌥R starts and stops one, or ask, "record
  this bit".
- **What the pictures show** — **Whole screen** (the default), **The meeting
  window**, or **An area I choose**, which you drag once and Moe remembers.

The ⌃⌥S and ⌃⌥R shortcuts exist only while a meeting is recording, and can
be switched off under *Advanced* on the Meetings page.

**Automatically** fires on cues in the transcript. **Choose what counts…**
has six switches; the first five start on and the last starts off: *Someone
shares their screen* ("let me share my screen"), *Someone shows how
something works* ("walk you through"), *Someone points at something on
screen* ("this slide", "this chart"), *An action item is agreed*, *A
decision is made* ("let's go with"), and *My name comes up*. Automatic
capture takes at most one screenshot every 20 seconds and 60 per meeting
(your own don't count), and a clip a cue starts ends by itself after three
minutes, when the cues stop, or at "stop sharing". The same sheet has **Ask
my AI what each picture shows**, on: a one-line caption for the notes,
made by a vision model, sent only while *Summarise with your AI* is on.

**The notes read the screens.** With captions on, the summary reasons from
those descriptions the same as from the spoken words: a number on a slide,
a decision shown but not said aloud, goes into the notes with a note that it
came from the screen. Captures are listed in the notes under **Screens** and
shown as thumbnails on the meeting's page, and they are kept regardless of
the delete-audio setting; they are your own pictures, not a recording of
other people's voices.

### After the meeting: the notes

At the end, the whole transcript goes once to your AI for the title,
summary, decisions, action items, to-dos and open questions. On the
Meetings page each meeting has:

- the summary, the decisions, and the action items you can tick (a tick
  puts it in your Reminders; unticking is done in Reminders),
- **To do**: the things nobody put their name to,
- **Open questions**, when the meeting left any,
- the screens captured, as thumbnails,
- the transcript, folded away,
- who was speaking, named from the calendar invite where possible and
  renamable by hand,
- **Delete**, behind a confirmation: the recording, the transcript and the
  notes all go.

If Moe has never been allowed to read your calendar, the Meetings page
offers it, *Moe can put people's names in your notes by reading who was
invited* with **Use my calendar**, and the notch's notes panel offers it
once, right after a meeting whose voices it could only number.

Everything is one folder per meeting under *meetings* in Moe's own folder,
named by date and time, with the two recordings, the transcript, the notes
and *shots* and *clips* for what was captured, readable only by your
account. **Open folder** under *Advanced* on the Meetings page takes you
there.

**One task, one owner.** Action items are spotted twice, every two minutes
while the meeting runs and once at the end from the whole transcript. Where
the two describe the same commitment, the end-of-meeting reading wins,
including who owns it. Talk about the meeting's own machinery, recording,
muting, screen sharing, joining links, is never an action item.

**Each job asks your AI separately.** A meeting makes five different
requests, action items every two minutes, a recap when you come back, a
caption for a screenshot, the notes at the end, and sending those notes to
Telegram, and each happens in its own conversation, fresh for each meeting.
The notes use the model you chose; the other four use your provider's
cheapest model. If your account refuses that model, Moe asks again on yours.

**If the notes fail.** Your AI gets a second attempt before Moe gives up. If
both fail, the transcript is still saved and the Meetings page says what
came back instead of the notes, so you can tell a model that refused from
one that was never reachable.

**Write the notes, later.** A meeting that ended without notes (they took
too long, your AI was not reachable, or the meeting was stopped early) is
not stuck that way. Open it on the Meetings page and press **Write the
notes**: your AI reads the saved transcript and writes them now. It can take
a couple of minutes for a long meeting, and you can leave the page while it
works. If it does not work, the page says why in a sentence and the button
becomes **Try again**; the transcript is never changed, and nothing else
about the meeting is touched until the notes are really written.

**Quitting during a meeting.** Quit Memoe while a meeting is recording and it
asks first: **Stop and Write Notes** ends the meeting, writes the notes and
then quits by itself; **Quit Anyway** quits now; **Cancel** carries on
recording. It asks the same way if you quit while the notes are still being
written. While it waits, a small window says what for (*Writing your
meeting notes*), with **Quit Now** if you would rather not wait. If you have
the notes sent to your Telegram, Memoe also waits for that send to finish,
for up to twenty seconds, and the window counts it down; the notes are on
your Mac either way. A meeting Memoe was quit in the middle of keeps its
recordings and transcript, marked incomplete.

**A meeting can become something Moe knows.** When the notes are written,
Moe hands them to its thinking part as a quiet background note: it sat in
on the meeting, here are the notes, here is who was speaking, here are the
decisions and action items. What to keep is that part's decision, so "what
did we agree with Dan on Tuesday" has an answer weeks later without a
meeting dumping its whole transcript into your memory.

### The switches on the Meetings page

Under **Advanced** at the bottom of the Meetings page: **Summarise with your
AI** (on; off, Moe keeps the transcript and writes no notes); **Keep the
audio after the notes are written** (off: the audio is deleted once the
notes are written, unless almost nothing was transcribed in a short meeting
and the recording is the only evidence of why, which the meeting's page then
says); **Send the notes to my Telegram when a meeting ends** (off, and
greyed out until Telegram is connected); **⌃⌥M starts and stops a meeting**
(off); **⌃⌥S takes a screenshot and ⌃⌥R records the screen, while a meeting
is on** (on); and the **Folder** row.

### Privacy

Nothing leaves your Mac unless summarising is on (then the transcript and
screenshot captions go to your connected AI) or Telegram delivery is on.
Recording is always visible (the red ring), always explicit, and the other
people should be told; the consent sheet gives you a line to paste.

## Running in the background

**Settings › Running in the background** is everything Moe does on its own
while you work: one pane, five tabs, **Speaking up · Reminders · Keeping up
· Learning about you · Activity**. Some of it starts on: the glow, the
ten-minute look at your calendar, notes and messages, thinking on its own,
the calendar heads-up, and quiet hours. The rest is off until you switch it
on, and each row says what it is doing right now. Turning anything off
stops it straight away, and it stays off after a restart.

### The amber glow

Everything Moe wants to tell you on its own arrives one way: the dot beside
the notch turns bright white. (It used to be an amber glow that pulsed; the
heading keeps the old name so links to it still work.) Hover and it opens a card: when it was for, what it
says, and three things you can do. **Play** hears it, and lets Moe know you
have. **Reply** opens a field on the card itself: type "I did", "not now",
"remind me tomorrow" or "stop reminding me about that" and Moe acts on it,
because it knows exactly which message you are answering. **Dismiss** drops
it without reading it out; Moe is told quietly. Moe never speaks first. One
thing waits at a time, the next stays in line until you have played or
dropped this one, and the dot stays dim while Moe is talking or during a
meeting; it shows the moment Moe is free again.

The same bright dot means a new version of Memoe has downloaded and is ready to
install. Tap the notch and the panel opens on *A new version of Memoe is
ready.* with **Restart to update** and **Later**; Later dims the dot again
for a day. If a reminder is waiting too, it plays first. An update shows
even with *Let Moe bring things up on its own* off, because an update is
Moe looking after itself.

### Speaking up

**Let Moe bring things up on its own** is the one switch for Moe looking at
your things on its own and saying so. It starts on. Off, nothing below runs
and nothing glows; reminders you asked for still arrive, and so does a new
version of Memoe waiting to be installed.

**Tell me before something in my calendar starts** — **Don't**, or **2**,
**5**, **10**, **15**, **30** or **60 minutes before**; it starts at 10.
That long before something in your calendar, you get one sentence,
"Standup with Dan starts in 8 minutes — Room 4", with the amber glow, and
forwarded to any chat you have ticked under Reminders. Nothing about it
thinks: it reads the copy of your calendar Moe already keeps, works out
what is starting, and says so, once per event. A meeting that moves is a
new thing and is mentioned again. All-day events are never announced, and
if the calendar copy is a day old Moe says nothing rather than warn you
about a meeting that may since have been cancelled.

Whether Moe may bring up something from one particular source is that
source's own switch, **Learn from Gmail and watch it**, under **Keeping up**:
off, Moe never starts a sentence about it.

**The half-hourly pass.** With the switch on, every half hour Moe looks at
the short brief it keeps of your day, calendar, notes, mail, messages,
tasks, and only when the brief has changed asks its thinking part whether
anything there matters: your next meeting, a missed call, a message from
someone you know. Something worth a word takes the amber glow, one or two
sentences; otherwise nothing is said and no thinking is spent. What it
learns along the way, a fact about a person, a project, a preference, goes
into the memory Moe carries into every conversation. This pass reads the
brief and nothing else; no connection is touched, and it has no way to run
anything on your Mac.

**Open loops.** When someone is waiting on you, a question, a request for a
call or a decision, an invitation that needs an answer, a deadline you have
not acknowledged, Moe does not just mention it once and forget. It keeps a
short private note of the thing and comes back to it: about three hours
later, then the next morning, then once a day. Each time, it checks your
own sent mail and messages first; if you have dealt with it, the note is
quietly dropped and you never hear about it again. If you have not, you get
one sentence, and only about the most pressing thing, never a list. After
four mentions, or a week, Moe lets it go by itself, and nothing can ask to
be brought back sooner than an hour. Answer it, "done", "not now", "stop
reminding me about that", and it closes, waits, or goes quiet for good.
Newsletters, receipts, automated notifications and anything you were only
cc'd on are never open loops; a loop is something a person is waiting on
you for. For something in your calendar you may not have got ready for,
Moe may offer to remind you nearer the time; say yes and it sets the
reminder. Moe writes loops down during a conversation too, silently, as
they come up: what you said you'd do, what Moe started and should check
landed, and a price or a page you looked at that can change, which Moe
checks every few minutes without thinking and speaks about only when it
moves.

**Watches** are the same idea for one connection at a time, a data
platform, a service, anything you have connected. A watch reads a fixed,
declared set of things from that connection on a schedule (what exists,
what changed, never rows or records), and when the answer changes asks
whether the change is worth a word. The word names the kind of change and
never quotes a name, an identifier, or anything the source marks as
personal. Nothing ships pre-written: ask Moe to watch a connection and it
sets one up; until then the connection's row says so. A watch costs
nothing while it is switched off.

### Reminders

Anything you ask Moe to remind you about is said out loud and shown on the
island when it comes due. This tab is where a reminder goes *besides* this
Mac. **On this Mac** is always on. Under it, one row per chat app Moe can
message you on, Telegram, WhatsApp, Slack and the rest: tick one and every
reminder is sent there too, useful when this Mac is shut. A chat is offered
once you have messaged Moe there at least once (that is how Moe knows which
chat is yours); until then its row says *Connected, but Moe has no chat of
yours there yet — message Moe there once, then come back.* The first chat
app you set up is ticked for you the moment it is ready; a second one waits
for you to tick it, and a chat you untick stays unticked. Before you have
one, the tab says *No chat app to reach you on yet — connect Telegram or
WhatsApp under Connections and it appears here.*

How reminders themselves behave, and the page that lists them, is
[Reminders](#reminders).

### When Moe messages you

When Moe needs to tell you something outside the conversation (a job it
finished, something that cannot wait, or because you asked: "message me on
Telegram when it's done"), it works out where you are at that moment:

- **At your Mac** (screen unlocked, used in the last few minutes), it shows
  on the island and your phone stays quiet. If you asked for a chat app in
  your own words at the Mac ("on Telegram"), it goes there instead. Moe
  choosing a chat app by itself is not enough, and nor is somebody else
  asking over a chat.
- **Away from it**, it goes to your own Telegram chat with Moe's bot through
  Memoe, if Memoe knows which chat is yours, and after that to the chat apps
  ticked under Reminders above.
- **Something urgent** goes to every one of your chat apps at once. Urgent
  messages are limited to a few an hour, and never use up the allowance for
  ordinary ones.
- **If none of them can be reached**, it waits in your inbox on the Mac, and
  Moe tells you it could not reach you. If Memoe's cloud is slow to answer,
  Moe says the message *may* have arrived rather than sending it again.

Where you are is checked when the message goes out, not when you asked. "Text
me on Telegram at 5" goes to the island if you are at the Mac at five.

Moe tells you which one it used. Asking twice with the same words does not
send it twice, and Moe sends only a handful of these an hour.

**Which Telegram chat is yours** is known to Memoe's cloud in one of two
ways, and it never guesses:

- **You made your bot with Memoe's Telegram setup.** Telegram tells Memoe
  who made it, and that account is you. This counts only for your first
  bot. Making another bot later never changes it.
- **Your account is older, and exactly one person's chat has ever
  messaged your bot.** That chat is yours.

Otherwise Memoe can't tell which chat is yours. Moe then keeps its messages
on your Mac (the island and your inbox), plus any chat apps you ticked under
Reminders, and Connections › Telegram says *Moe can't confirm which Telegram
chat is yours yet — messages stay on your Mac.*

When Memoe does know, open **Connections › Telegram** and click **Confirm
it's you**. Memoe shows a short code and your bot's name. Send the code to
the bot from that account within ten minutes. The bot tells you whether it
worked, and so does the panel. The code only confirms the chat Memoe already
knows. It never makes a different chat yours. Someone else's wrong guesses
lock out only them, and the bot answers a stranger at most once.

If Moe already reaches you on one chat and you send the code from another,
nothing moves yet. Your current chat gets a message with an **Allow** button
that lasts two minutes, and only tapping it there moves the chat. The old chat
then gets an **Undo** button for a day. For now only Telegram works this way.

What this protects against: Moe itself being confused or tricked into
messaging someone else, and contacts or strangers who talk to your bot. It
does not protect against something that has taken over your Mac and read your
bot's token. Anything holding the token can point the bot anywhere. Moving
the token off your Mac is separate work.

This only ever reaches **you**. Moe never messages you through one of your
contacts' chats. A routine you ask to "send me on WhatsApp" goes to you,
where you are, not to whichever chat that app treats as its default.

### Keeping up

**Learn and watch** comes first: one switch per connected thing, **Learn
from Gmail and watch it**, **Learn from Messages and watch it**, and so on.
**Everything you connect gets a row**: the apps on this Mac, and every
service you sign into on the Connections page (GitHub, Slack, Notion, Linear
and the rest). A row's switch covers everything Moe does with that source by
itself:
- it keeps it ready, for the apps on this Mac (a service connected through
  Connections is read when you ask);
- it learns from it;
- it watches it for things you'd want help with, and for promises;
- it mentions what happens there.

Off, Moe reaches that source only when you ask it something. Each row says
what it reads, and when Moe last read it back. Background thinking, the
daily pass and **Let Moe bring things up on its own** stay the switches over
all of it.

**When you're asked.** The first time you connect something, Moe asks once:
*Let Moe learn from Gmail and watch it for things you'd want help with?*,
with **Yes** chosen for you and **Not now**. **Not now** changes nothing and
asks once more a week later; after a second **Not now** the switch here is
the way back. Sources you connected another way, or before this question
existed, are asked about together in one question when you next open
Memoe. It never comes while another question or sheet is open, and at most
once every few hours. Anything you had already said yes to stays on. A
source you left unticked in the welcome is asked about again a week later.

**Look at what's connected every 10 minutes** is on to start with, so Moe
knows what is on today when you ask, without going to look first. Its row
ends with *Last looked:* and when. Every ten minutes Moe copies a short
window of each source it may learn from and watch into a small cache on
this Mac, replaced each time, so "what's on" is instant:
- the next three days of your calendar;
- the last day of mail, Messages, WhatsApp and Telegram;
- the last month of Drive;
- every open reminder;
- your most recent notes, only while Notes is already open.

Nothing is kept beyond the latest copy, and switching a source off removes
its copy. Off, Moe reaches your things only when you ask it something.

A conversation is told that copy once, in full, and after that only what
has changed in it: the message that arrived, the task that left your list,
the meeting that is now ten minutes away. Moe re-reads its side of a
conversation before every answer, so a conversation that was handed the
whole copy again every ten minutes took longer and longer to answer. In a
long conversation the whole copy is given again every twenty messages, so
nothing is lost along the way.

**Moe always knows what time it is.** Every message Moe is given starts
with the time where you are — *Wednesday 23 September 2026, 6:08 PM
(evening), New York time* — whether you spoke, typed, or wrote from
Telegram or WhatsApp, and on your cloud computer too, in your own time
zone. So your calendar reads the way you would read it: what is **over**
today (*Wed 23 Sep, 2:00–3:00 PM Project Atlas call — ended 3 h ago*),
what is on **now**, and what is **coming up** (*today, in 20 min*,
*tomorrow*, *on Friday*), each with its date — today's included — and
its end time, and all-day events as *all day* rather than a midnight
start. Because every event names its own date, a copy of your day read
hours later, or by Moe in the cloud, can't mistake today for tomorrow. Something already over is never offered to
you as upcoming. Switch a
source off and Moe reaches it only when you ask. The apps on this Mac start
on; a service connected through Connections is kept ready only once you
switch it on here, and then about once an hour, since each read there is a
fresh sign-in to the service. Chrome shows here like the others but reads
nothing until you have turned it on under Connections.

Before that copy is written, it is read through once for secrets: anything
that looks like a password, a PIN, a one-time code, a card number, or the
passcode in a meeting link is masked, and if that pass cannot run the copy
is not written at all.

### Learning about you

**Let Moe think on its own, on my AI plan** — on. It lets Moe use your AI
plan for work you did not just ask for: the half-hourly look over your mail,
calendar and follow-ups, and the daily learning below. Off, none of that is
spent. Moe still keeps its follow-up list, still checks a price or a page
you asked it to watch (that costs nothing), and still delivers any reminder
you set; it just does not think about any of it until you turn this back
on. Moe also watches its own budget: on a Claude or ChatGPT plan, past half
of your plan's short window (Claude's five-hour window, ChatGPT's session)
the background passes wait, your own conversation comes first, and catch up
when the window resets; the weekly window only pauses them past four
fifths. With an API key there is no window to watch; you pay per token, and
this switch is the control.

**Quiet hours, 10 pm to 8 am** — on. What Moe brings up on its own waits
for the morning before it reaches your phone; the notch still gets it,
silently, and a reminder you set yourself goes when you said. Moe uses this
Mac's own clock and time zone, so it follows you when you travel, and if it
has no fresh reading of your zone (the Mac has been off for a day) it holds
nothing rather than guess. Switching quiet hours off here switches them off
for your cloud computer too.

**Once a day, read back over what I've allowed and note what it learns** —
the daily pass. Off until you say yes, in the welcome or here. Only the
things you have said yes to below; it keeps a short list of what it works
out, who matters to you, what you're working on, on this Mac, in plain
writing you can read and change under Memory. Under the switch, a quieter
line says what the pass did last time, *Last daily pass, 14 Sep: read
Gmail, Calendar*, or that it didn't run and why: the switch was off, *Let
Moe think on its own* was off, or your plan was nearly used up, in which
case it tries again the next day. When it has waited for your plan several
days in a row, that line says so — *has waited every day since 12 Oct… so
Moe hasn't learned anything new about you since* — here and on the Memory
page, and nowhere louder.

The daily pass reads only the sources switched on under **Learn and
watch**. The first time you say yes to a source, Moe reads back over it
once, a year for most things and three months for browsing. It keeps what
it works out as facts, each with where it came from and when. After that it
catches up at a pace that suits the source:
- daily for mail and messages;
- weekly for notes and wikis;
- monthly for the shape of a database;
- never for a docs search.

A source switched off is skipped, and the others carry on.

For a service connected through Connections, the pass works out for itself
what is safe to read: what accounts, projects and structure exist — your
repositories and the organisations you belong to, your Slack channels, your
mail's labels — never rows of data or documents, and never anything that
writes. **For a service with messages** — Gmail, Outlook, Slack and the like —
it also learns from what the messages say, everything in the inbox. It reads
them from what Moe already fetched to watch that service, so this costs no
extra reads of the service, and each day only what is new since the last
pass. Automated mail and notifications are left out, and each conversation
is cut to its newest few messages. It learns what matters to you from them;
what someone else wrote is never taken as a fact about you. A row says whether Moe worked that out from
what the connection offers or you set it yourself, and the list of calls it
settled on is a file you can open and trim. A service you have not signed
into gets no row: there would be nothing behind it to read.

**Keep what it learns as Moe's memory** — off. On, what the pass works out
becomes part of the memory Moe carries into every conversation, not only a
list you can review under Memory. Off, the list is kept and Moe's memory is
left alone. **See what Moe knows** at the foot of the tab opens Memory.

### Promises

Moe keeps track of promises, both ways. It notes the ones you make ("I'll
send you the deck by Thursday") and the ones people make to you ("we'll
deliver on the 5th"). It finds them wherever it already reads for you:
- your chats and mail;
- your calendar;
- your Apple Notes and recorded calls (only while Notes is open);
- the notes of meetings Moe took;
- anything you tell Moe in chat, like "I told Dana I'd call her Monday".

Nothing extra is read and there is nothing to set up. Each promise is kept
with the exact words it was made in. A vague "let's catch up sometime" is
not a promise.

**Most promises never reach you.** When the deck goes out, in the same chat
or by mail, Moe sees it and closes the promise by itself. The same happens
when someone says it is no longer needed. Before a promise is brought up,
Moe looks once more across everything it reads for a sign it was kept.

**When one does, it's on time.** A promise with a date comes up at 9 in the
morning on the day it's due. If there is still no sign of it the morning
after, it comes up again. A promise with a time comes up two hours before
and an hour after. One with no date comes up once, a week later. A promise
made late on its own due day waits for the next morning rather than coming
up at night. One that has been past for two weeks is let go quietly, and
never comes up weeks late because your Mac was shut.

What comes up is whatever fits, the same way as anything else Moe noticed:
- a reply ready for Dana when your deadline is today;
- a polite nudge when someone else's has passed;
- the numbers worked out;
- or just the promise itself, said plainly, when there is nothing to get
  ready.

Nothing is ever sent unless you say so and confirm. A promise that came
from your own notes or a meeting has no conversation to reply in, so Moe
asks you where it should go. **Not now** or **Not this kind of thing** on
the card works as it does for any offer. Waving a promise's card away also
stops Moe watching that promise.

**Settings › Running in the background › More › Noticed** lists them under
*Promises*: open ones first, soonest due first. Each shows who it's with and
where it was made, with the words it was made in. Kept, called-off and
let-go ones are shown dimmed for a month. On an Away plan your cloud
computer notices promises and sees them kept while your Mac is shut, and
both keep one list. Only your Mac brings them up. What either side notices,
and what it has already told you, reaches the other within about five
minutes: no chat is needed for it to travel.

### Activity (the tab)

**What has been running**: one row per background job over the last seven
days, *Speaking up*, *Learning about you*, *Calendar heads-up*, *Watching
Notion*, with what it did last time (*Looked, and there was nothing new to
say.* / *Ran, and had something to do.* / *The last run didn't finish. Moe
will try again on its next turn.*), how often it ran and how many of those
failed, what it cost in tokens where anything was charged, and **on**,
**off** or **needs a look** at the end. A plan you subscribe to has no
separate charge, so those lines show the work rather than a price; a key
you pay per use is priced from published rates, which is an estimate and
not your bill. The fuller record, conversations included, is
[Activity](#activity).

Each of Moe's own jobs also says when: *Last ran 2 h ago.* while it is
working, *Has not worked since Tuesday.* when its runs have been failing,
and *Has not run since Tuesday.* when it has stopped running at all. That
last one is the case nothing else here would show you, because a job that
never runs never fails. If Moe's own look at its jobs has stopped, the list
says so in one line rather than leaving old times standing. None of this is
ever a card in your inbox or a sound; it is here for when you wonder why
Moe has gone quiet about something.

### When something Moe runs goes wrong

Nothing technical is ever put in front of you. Moe runs a handful of jobs
in the background, and when one of them does not finish, that is Moe's own
plumbing, not news for you. It never takes the amber glow and it is never
spoken. Where it does show is here: the job that had trouble reads **needs
a look**, with a plain line saying its last run did not finish and Moe will
try again. If something Moe was watching for you genuinely needs you, a
connection that has stopped working, an inbox it can no longer read, Moe
tells you about it in its own words: what it means for you and what it is
doing about it, never an error message.

**A job that could not do its work says so — it is never "done".** When a
scheduled job you asked for runs into something it cannot get past — the
browser not signed in where it should be, a login or verification code
needed, a page that is not what it expected — it stops, and the report
saying why reaches you the way that job's results do: in the chat, on the
card under the glow, or wherever you asked for it. The job shows as
**blocked** with that reason, never as having run fine. A job that found
nothing new keeps quiet as before; a job that could not look does not.

Jobs you set up yourself run on the same brain your conversation uses.
Moe's own background checks stay on the cheapest model your plan offers
(Settings › History › Usage says which); a job that acts in your name — posts,
follows, books, replies — is not one of those, and gets the brain you
chose.

### Answering something Moe started

Anything Moe says on its own, a reminder, a follow-up, a heads-up before a
meeting, you can answer in a word, wherever it reached you: the card under
the amber glow on this Mac, or Telegram, WhatsApp or any other chat you
have picked. "I did." "Not now." "Remind me tomorrow." "Stop reminding me
about that." Moe knows which of its own messages you are answering and acts
on it, and acting on it never brings up a permission dialog, because
changing its own reminders is Moe's own business.

- **Dealt with** — "I did", "done", "sorted". Moe drops the follow-up and
  never mentions it again.
- **Later** — "not now", "remind me tomorrow", "give me a couple of days".
  Moe moves it and says nothing until then. Deferring does not use up one
  of the four times Moe will ever mention something.
- **Stop** — "don't remind me about that any more". Moe drops it and will
  not raise it again, even if the thing that started it is still sitting
  unanswered in your mail. Ask for it back and it can come back.
- **A reminder you set yourself** is a schedule rather than a follow-up, so
  the same words change the schedule: Moe pauses it, deletes it, or moves
  it to the time you asked for. Moe's own background messages have no
  schedule of yours behind them, so if you want that kind of message to
  stop, Moe points you at the switch on this pane rather than quietly
  deleting the job the rest of them come from.

It only works on the message you have not answered yet, and only for about
half a day: a short reply the next morning is a new subject. In a group
chat nothing is attached at all; Moe's own messages go to your private
chat.

## Reminders

Ask Moe to remind you of anything: "remind me at three to call Dan", "every
weekday at nine, ask me what the day is for". Moe's thinking part keeps the
schedule. When one comes due it takes the amber glow, even with *Let Moe
bring things up on its own* switched off, because you asked for it, and it
is sent to every chat you ticked under Running in the background ›
Reminders.

A repeating reminder survives Moe being closed and the Mac being asleep: it
fires once, the next time Moe is running. A one-off reminder does not wait
for you: if the Mac is shut when its minute comes and is still shut two
minutes later, that reminder is dropped rather than fired late. A reminder
that came due while Moe was not running is shown when Moe is next open,
with when it was for (*Earlier, at 3:00 PM: …*); one more than a day old is
history rather than a reminder, and is written to the log instead.

**A reminder Moe was interrupted in the middle of is said anyway.** If Moe's
thinking part restarts while one of your reminders is being worked on, Moe
notices on the way back up and says it, once, as long as it is less than a
quarter of an hour late. Past that it is left alone, because a nine o'clock
stand-up arriving mid-afternoon is worse than silence, and the next
occurrence goes at its normal time.

With **Away**, a reminder set on this Mac fires from your cloud computer
while the Mac is shut, at its minute, and reaches the chats you ticked; a
reminder you set from your phone appears on this Mac as well. Whichever of
the two is awake says it, never both. See [Away](#away-moe-when-your-mac-is-closed).

**When one of yours fails, Moe tells you, once.** If a reminder or
routine you asked for doesn't work, a card comes to the island (and your
chats, if you're away from the Mac) within a few minutes, whatever it was
meant to send to. It says which one and when, in plain words, with two
buttons: **Show me what went wrong**, and Moe looks at the run and tells
you what happened and what would fix it; or **Run it again**, and Moe
starts it now (a finished one-off is made again, due straight away), after
saying first if something only you can do, like signing in, has to happen
for it to work. If it ran but its message never reached you, the card
offers **Show me what it said** instead. A one-off is told the moment it
fails; a repeating routine from its second failure in a row, since one
miss is usually a hiccup; one that got stuck and couldn't say why to you,
straight away. After that, nothing more about it until it works again: no
card per retry, no reminder a week later. Moe's own upkeep never makes a
card.

### Settings › Running in the background › Reminders

Asking is the quickest way, but **Settings › Running in the background › Reminders** is where you can
see everything at once and change it without saying a word. Two lists.

**Yours** is everything you asked for. Each one says what it does, how
often (*Every weekday*, *Every 2 hours*, *Once*), when it will next happen
(*Next tomorrow at 9:08 am*), and where it goes (*Spoken here, and sent to
the chats you picked* or *Sent to Telegram*). Beside it: **Pause** (and
**Resume**), **Run now** if you want to see what it produces without
waiting, and **Remove**, which asks once, **Really remove** or **Keep**.

The "next" line is careful about the difference between waiting and not
going to happen. A reminder you paused says *Paused*. One that has run the
number of times you asked for says *Finished*. One set up for a different
brain than Moe is on now says *Skipped every time* and asks you to remove
it and make it again. And if the part of Moe that runs the clock is not
running at that moment, a note at the top of the page says nothing will
fire until it is back, rather than every row quietly promising a time it
cannot keep.

**Moe's own upkeep** is what Moe runs to stay current: reading what
changed, learning about you, watching the things you asked it to watch,
checking the pages you asked it to watch, keeping your chat apps connected,
picking up work handed back from Moe Away, and the word before a meeting
starts. They are listed so nothing is hidden, and they have no buttons:
what you can change about them is what Moe may read, and that lives under
Running in the background.

### New reminder

**New reminder** starts from one of Moe's sixteen templates: **A morning
briefing**, **Only the mail that matters**, **A weekly look back**, **A
nudge when work starts**, **Remind me to…**, **Winding down**, **News on one
subject**, **Bills and renewals**, **Watch a price**, **Watch other
companies**, **Keep a habit going**, **Water and a stretch**, **A week of
meals**, **Learn a little daily**, **Something to reflect on**, and
**Something worth knowing**. Pick one and it asks its own questions: what to
remind you, what time, which days, where to send it.

**Call it**, under the questions, is the one thing filled in for you: the
template's own heading, yours to change. It is what the row is called, and
what stops a second morning briefing from silently replacing the first.
Nothing else is filled in for you: every question is blank until you answer
it, and **Create** stays greyed out until they all are, with the line
*Every question needs an answer — Moe does not fill any of them in for
you.* A form that arrives pre-filled is a form you can tap straight through.

Times are written as 24-hour `HH:MM`, `08:00`, `18:30`, and Moe says so if
you write one it cannot read, before anything is created. Where it goes is
**Moe, here** (spoken and on screen on this Mac, plus whichever chats you
ticked under Running in the background) or a single chat app on its own.
Only apps you have actually connected are offered.

A reminder made here is exactly the same kind of thing as one you asked for
out loud: same schedule, same amber glow, same "not now" and "stop
reminding me about that".

## Activity

Most of what Moe does happens where you are not looking. A reply goes out
on Telegram while you are in a meeting. A briefing runs at seven and is
gone by the time you sit down. Something Moe watches for you stops working
and the only sign is a line in a file nobody opens. **Settings › History › Activity**
is the one place all of that lands, newest first, under *Today*,
*Yesterday*, then the weekday for the rest of the week and the date beyond
that. **Refresh** at the top reads it again.

Pick the window at the top: **Today**, **This week** (the default) or **Last
30 days**. Four kinds of thing appear.

- **Conversations** — the ones you had, one line per conversation per day,
  *You and Moe went back and forth 6 times.* **Read** opens it in Chats.
- **Replies from elsewhere** — a turn that happened on Telegram, WhatsApp
  or any other chat you have connected. The row says where, when and which
  model answered, and how much was written on each side. It does not say
  what was said, and there is no button to find out: what is written down
  about a turn that happened elsewhere is that it happened. The
  conversation itself is in Chats if it reached this Mac.
- **Things that ran on a clock** — your reminders and anything else on a
  schedule, gathered per day: *Ran once, at 7:00 am* for a morning briefing,
  *Ran 152 times, last at 1:36 pm* for something that ticks every couple of
  minutes, and how many of them stopped on a problem.
- **Things that stopped** — a job that failed, with the first line of the
  reason and whether Moe has already told you.

**Moe's own upkeep is folded away.** The jobs that keep Moe current run a
few hundred times a day between them, and almost none of it is about you;
**Show Moe's own upkeep** puts them back. A failure is never folded away,
whoever's job it was. A very busy window says how many older things are not
shown, and narrowing the window shows further back in detail.

At the bottom, **Underneath**, is the raw log Moe's thinking part keeps for
this Mac: **Show the raw log** shows the last forty lines, and **Reveal in
Finder** puts you next to the file. It is there because sometimes the honest
answer is "look at the log", and it is described as exactly what it is: not
a complete record, and not filtered, so it can contain the text of turns.

**This is this Mac.** Moe Away runs on a machine of its own and keeps its
own record there; nothing on this page can see it, and a quiet day here does
not mean a quiet day there.

## Skills

A **skill** is a page of instructions Moe reads when a job looks like the
one the page describes: how to work a spreadsheet, how to read a PDF, how
to run a GitHub review, how to talk to Obsidian. Moe does not run a skill;
it reads it, and then does what it says with the tools it already has. A
fresh install comes with about a hundred of them.

**Settings › Brain › Skills** lists all of them, grouped by what they are for,
*Your Mac and your Apple apps*, *Documents and everyday work*, *Looking
things up*, *Email*, *Writing code*, and so on, with each skill's own
one-line description underneath and a **Switch off** or **Switch on**
button beside it. Four chips at the top narrow the list, each with its
count: **Everything**, **Can't run**, **Switched off** and **Moe has used**.
**Refresh** reads the list again.

**The banner at the top is the reason the screen exists.** Some skills say
in their own text that they need a command installed, and nothing checks
whether that command is actually on your Mac. So Moe finds out the way you
would: it reads the page, runs the command, and is told there is no such
thing, which costs you the answer you asked for. This page does the check
nothing else does, says how many skills are in that state, and lists them
first, each with *Needs …, which isn't installed on this Mac.* When nothing
is in that state the banner says so: *Everything switched on can actually
run on this Mac.*

**Switching one off** means Moe stops being offered it, here and on Moe
Away, because the list of switched-off skills travels between them like
everything else. Switching one on puts it back. Two kinds of row have no
button and say why instead: one skill Moe needs to work at all, *Always
on*, and any skill that is only ever offered inside a different kind of
session, *Not offered here*.

Each row also says where the skill came from, *Comes with Moe*, *Written
for this Mac*, *Installed from a registry*, and, if Moe has ever opened it,
how many times and when. This page does not install, write or delete
skills.

**Your skills are the same on Moe Away.** Every skill on your Mac is on your
cloud computer too, and a skill Moe writes or improves there comes back to
the Mac. If the same skill was changed on both, the newer change wins. A
skill deleted on one side is deleted on the other, and the deleted copy is
kept aside rather than thrown away.

### Sounding like you, not like a chatbot

Ask Moe to make something *sound like you*, *less like a chatbot*, or *more
human*, and it edits the text for the habits that give machine writing
away: "it's not X, it's Y", a one-line closer that repeats the paragraph,
"let's dive in", everything in threes, a dash in every sentence, bold
labels down a list, "I hope this helps". What the text says stays exactly
as it was: Moe adds no fact, name, number or quote it was not given, and if
a sentence needs one, it asks. Give it a sample of your own writing first
and it matches that instead.

This works on anything: a draft reply, an email Moe wrote for you, a note,
a post, a file. It is a skill, so it shows up on this page as *humanizer*
under *Writing*, can be switched off like any other, and needs nothing
installed. Moe does not run it on every message it sends, only when you ask
for it, or say that something reads as AI-written.

## Usage

Every question you ask costs tokens. On most plans what runs out is not
money but a window, how much you can use in five hours, or in a week, so
**Settings › History › Usage** puts that first and the money second. **Refresh** at
the top reads it again. This is what Moe has used on this Mac; Moe Away
keeps its own record on its own machine.

**When you get close to a limit.** Once you pass nine tenths of a plan
window, Moe's answer arrives with a line saying how much of it is gone, so
you hear it from Moe rather than from Moe suddenly going quiet. The top of
this page says whether that has ever happened on this Mac and shows the
last one if it has, *Moe has never had to say that on this Mac*, or that it
couldn't read its own log and so can't say.

Then, over **Today**, **This week** or **Last 30 days** (the default):

- **Tokens**, as two numbers that are deliberately never added together.
  *What you and Moe said* is everything typed, spoken and answered. *What
  Moe re-read each turn* is Moe re-reading what it already knows on every
  turn: your instructions, the thread so far, the tools it has. The second
  is normally far bigger than the first and is billed at a fraction of the
  rate, where it is billed at all, so one combined total would look like a
  bill and be almost entirely re-reading.
- **What it cost**, in three honest buckets. *Covered by a plan you already
  pay for* is the conversations your AI subscription settled by the
  month; they have no per-token price, so none is shown. *Billed per token*
  is the smaller models Moe reaches for titles, summaries and background
  work, an estimate from a published price list, and where the actual
  pennies are. *Nothing recorded* is anything with no billing route at all;
  when those have no tokens either, they are simply sessions that opened
  and never took a turn, and the page says so.
- **Which brain answered**, per model, with how much each said, how much it
  read back, whether it was covered by your plan or billed per token, and
  what it cost, or a dash where nothing costed it.
- **Where the work came from** — the app on this Mac, things on a clock,
  work Moe handed to itself, the command line, or a chat app.
- **What Moe reached for** — how often each tool ran, the twelve most used.
  Not what each tool cost: tokens are counted per conversation and never
  per tool, so there is no such figure anywhere, and the page says so.
- **Day by day**, folded away, if you want to see which day was the
  expensive one.

## Chats

### The Chat page

**Chat** in the main window is where you type to Moe and read what it
said. The rail on the left, **Conversations**, lists your conversations by
day; the pencil starts a fresh one (⌘N). **Search** at the top of the rail
narrows it to the conversations with those words in their name or anywhere
in them, archived ones included; **Esc** clears it. Right-click a
conversation for **Pin**, which keeps it under **Pinned** at the top,
**Rename…**, which lets you type its name in place (Return keeps it, Esc
leaves it as it was), **Archive**, which moves it under **Archived** at the
foot of the rail, and **Delete…**. The box at the bottom says *Ask Moe*, or *Ask Moe — quietly*
while a meeting is recording; **+** beside it adds a photo or a file, the
microphone button talks, and Return sends. An empty conversation greets
you, *Hey. What's up?*, and says to hold the talk key or type.

Delete a conversation and its key is destroyed on every device you use Moe
on, so nothing can read it again.

What you say to Moe on Telegram, WhatsApp, LINE, Email Moe and the other
chat apps shows up here too, one conversation per chat, and a new one after
six quiet hours, whether your Mac answered it or your cloud computer did.
With Away on, those conversations reach your cloud computer, so it knows
what you said to your Mac and you can search them on either side. A group
chat Moe is in is never one of them: what people say in a group stays out of
your conversations with Moe. Slack is the exception: Moe keeps what it
learns there, never the words.

### Changing a message you sent

Click the pencil under one of your messages, or right-click it and choose **Edit message**. It comes back into the box,
with a line above saying you are editing it; change it and press Return.
The conversation is cut at that message: it and everything after it are
gone, everywhere you use Moe, and Moe answers the new version knowing only
what came before it. The conversation keeps its name, pin, model and tags.
**Cancel**, or Esc, leaves it as it was. You cannot edit while Moe is
still working on something.

### Don't remember this chat

The eye beside the conversation's name at the top of Chat is **Don't
remember this chat**. Click it and it reads *Not remembered*: from your next
message, nothing said in that conversation is saved to Moe's memory. Moe
learns nothing about you from it, cannot write anything from it to memory
when asked, and does not look back over it afterwards for things worth
keeping. This holds on your cloud computer too. The conversation itself is
still kept, in Chat and in your history, and Moe still remembers it while
you are talking in it; it is only memory, the things Moe knows about you
from one conversation to the next, that it stays out of. A conversation
marked this way shows the same eye in the rail and is never tagged.

It is per conversation: a new one starts remembered. Turning it on does not
take back what Moe already learned from that conversation earlier; take
anything you do not want out on the **Memory** page. Click the eye again to
let Moe remember from that conversation once more.

### Tags

Once a conversation has gone back and forth three times, Moe gives it up to
three short tags, like *travel* or *work email*, shown under its name in the
rail. The tags you have appear as a row under **Search**: click one to see
only the conversations tagged with it, archived ones included, and click it
again to see them all. To take a tag off, right-click the conversation and
choose **Remove tag**.

Tagging is one small request per conversation, sent once, to the cheapest
model of the account Moe thinks with, never your main model. Tags are kept
on this Mac, beside your pins and names.

### Settings › History › Chats

The Chat page lists the conversations you have had recently. **Settings ›
Chats** is the whole archive: all of them, newest first, each with the last
thing said in it, how many turns it ran to, where it happened, *here*, *on
Telegram*, or both if you carried one on from your phone, and when.
**Read** opens it and shows every turn.

**Searching goes through the words**, not the titles. Type a phrase, press
**Search** or Return, and Moe looks in two places: what it holds itself,
and its thinking part's index of everything ever said on any channel. The
second one finds things the first cannot, because the index keeps more of
a conversation than Moe's own record does, and a result found that way says
so underneath.

**A conversation you deleted can never come back here.** Deleting destroys
the key, so Moe can no longer read its own copy, and the search is only
ever allowed to look inside the conversations Moe still holds the keys to:
a deleted one is never on that list. Some conversations are in Moe's record
without their words; the page counts them rather than listing them, and
says what that means: a deleted one, or one from another device whose key
has not arrived here yet.

## Memory: what Moe knows about you

Moe carries what it has learned about you into every conversation, so you
do not have to explain yourself twice. It is a short list of plain facts,
who you are, who matters to you, how you like things done, and you can read
the whole of it, correct any line of it, or throw a line out. All of it
stays on this Mac unless you set up Away, and even then it travels sealed.
It is deliberately small, because every word of it is read before Moe
answers anything at all, so what is in there has to earn its place.

### The Memory page

**Memory** is a row in the sidebar of the main window, under *Library*. It
is not in Settings, and that is deliberate: what Moe believes about you is
not a preference you tune once, it is something worth looking at.

The page has a short list of its own down the left: **Memory**, then
**You**, **People**, **Right now** (what is going on at the moment) and
**To check**, each with how many lines it holds. *To check* shows its
number in a small blue pill, and only when Moe has something to ask. When
Moe has kept notes of its own from your conversations (the invoice day,
*never send without reading it back*), a fifth row, **From your chats**,
holds them, so they are never mixed in with what Moe believes about you.
At the foot of the list, quietly, are **Past**, **Open folder** and **Your
notes**. Click a row and the right side shows that section: its name, one
line saying what it is, and its lines, one under another with a thin rule
between them. Nothing is boxed or tagged. The page remembers which section
you were on while Moe is running, and a section with nothing in it says so
in one quiet line. That line means what it says: if Moe was not able to
read what it knows, the page says *Moe couldn't look at what it knows about
you just now* instead, and nothing has been lost.

Hover over a line and, faintly under it, you see where it came from and
when, *WhatsApp · Sep 21* or *Your words*, and at its end **Discuss** and
an **×**. Hovering never moves anything: every line keeps its width and its
wrapping whether the pointer is on it or not. In **People** each line starts
with the person's name in bold, then who they are to you, in a few words
(*Shaindy — sister*). Lines speak to you: anything Moe wrote as *the user*
is shown as *you*.

**Talking it through with Moe.** Every section has **Go through with Moe**
at the top right. It opens Chat with a message already typed — for You:
*Let's go through what you know about me — the You lines in my memory
(identity.md, preferences.md, voice.md and USER.md). Ask me about anything
that looks off, one at a time, and fix it as we go.* Nothing is sent until
you send it. **Discuss**, on a line, does the same for that one line, and
**Review everything with Moe**, at the foot of the list, starts a walk
through all of your memory, one file and one question at a time. Moe
changes what you tell it as you go — confirms what is right, corrects
what is wrong in your words, forgets what you want gone, adds what is
missing — and each change is kept as your own word.

**Every line is corrected where it stands.** Click a line and it becomes a
text field right there, in the same place and the same type, outlined in
blue. Change the
words and press **Return** to save, or just click somewhere else; **Esc**
puts it back as it was. Clear the line and save, or click its **×**, and
Moe forgets it; a small *Forgotten · Undo* appears at the bottom for a few
seconds in case that was a slip (**⌘Z** works too). From the keyboard,
**↑** and **↓** move between lines, **Return** edits the one you are on
and **Delete** forgets it.

**Adding something yourself.** Under the lines of **You**, **People** and
**Right now** is **+ Add something Moe should know**. Click it, type the
line and press **Return** (or click away); **Esc** leaves it. What you add
is kept as your own words, just like a correction: nothing Moe reads later
competes with it, and the nightly tidy never moves it or asks about it. In
**People**, type *Dana — co-founder* (or *Dana - co-founder*) and the name
is set in bold like the others.

Every change is written at once, with no waiting on Moe, and it is yours
from then on. For something Moe learned by reading, a later look at the same
mail or chats will not bring the old wording back, and the nightly tidy
never merges it away, moves it to *Past* or asks about it again. For a line
from Moe's own memory of your conversations, the change is recorded in the
same place Moe's own notes are, so it reaches your machine in the cloud
too, and the two files Moe reads before every conversation (USER.md and
MEMORY.md) are rewritten before the page reloads; the old line does not
come back.

Moe writes what it notes about you as plain facts, *Prefers action over
explanation*, not in its own voice. A note from before it did, one that
says *I* or *me* where it means Moe, is shown under **From your chats**
rather than **You**, so it never reads as your own words; reword it and it
moves up.

**To check** is where Moe asks for your help, never more than five things
at a time, disagreements first, and it asks **one thing at a time**. A
card shows the question — *Is Shaindy your sister?*, or *Is this right?*
above a line Moe is unsure of — with three choices: **Yes**, **No** and
**Something else…**, which opens a field in the card for the right answer
(**Return** saves, **Esc** goes back). **Skip** moves on and asks again
another time, and *1 of 5* says how far you are. When two lines disagree,
the card asks *Which of these is right?* and each line is a choice; the one
you pick stays and the other moves to *Past*. Not every question is a yes or
no — *Who is "he" in that line?* can't be answered with **Yes** — so a card
that asks *who*, *what*, *when*, *which*, offers two answers (*your sister or
your cousin?*) or just notes something unclear shows a box for your answer
instead, with **Save**, **Doesn't matter** (Moe stops asking) and **Skip**.
After each answer the next
card slides in; at the end the page says *All caught up.* From the
keyboard: **Y**, **N**, **E** (something else), **1**/**2** on a
disagreement, **→** skips and **←** goes back to one you skipped. **Yes**
keeps the line as your own word, **No** forgets it, and what you type is
kept as something you told Moe. Questions are always put to you as *you*,
never *the user*.

A fact you deleted that Moe picks up again is never quietly brought back:
it waits in *To check* as **Remember this again?**, with **Yes** and **No**.

**Moe tidies its memory overnight.** Once a day, while you are away from the
Mac, Moe reads everything it keeps in mind before a conversation and
tidies it on its own: two lines saying the same thing become one, *next
Tuesday* becomes the date it meant, a plan whose day has passed is set
aside, two lines that disagree are settled, and changes Moe's own review
had set aside are decided. It never adds a name or a number that was not
there, never drops one, and never changes a line in your own words.
Nothing is deleted: every line it tidied away is under **Past** with what
happened to it (*Merged into …*, *Reworded as …*, *Over, so set aside*),
and **Restore** puts that change back. It uses the cheapest model your
provider offers, and does nothing while background thinking is off.

**Past**, at the foot of the list, shows the lines Moe keeps but no
longer treats as how things are now: events that are over, older wordings,
lines that did not fit, and what the overnight tidy set aside. Hover over
one for **Restore**, which puts it back.

**Open folder**, under it, opens one Finder window, *What Moe knows*,
with every memory file side by side: **USER.md** and **MEMORY.md**, the two
files Moe reads before every conversation, and the files it learned from
reading, **summary**, **identity**, **people**, **threads**, **voice**,
**preferences**, **questions** and **check**. The bookkeeping files around
them are left out. The files themselves stay where Moe keeps them; the
folder holds a link to each, so opening one and saving it in any editor
changes the real file. The folder is rebuilt every time Moe starts and
every time you open it, so it always shows what is there.

**Your notes** opens the plain notes Moe was set up from. A fresh Moe has
four, **About me**, **People**, **Projects** and **Preferences**, and you
edit them here as plain text, with a list on the left and the page on the
right. An *unsaved* mark and a **Save** button appear the moment you change
something; **Done** closes the sheet. What these say is carried into what
Moe knows once, when Moe is first set up on this Mac; the sure way to give
Moe a fact after that first day is to tell it.

With Away on, one more quiet line at the foot says your machine in the
cloud keeps a sealed copy in step.

**When there is nothing to show**, the page says so in one sentence, why
if Moe knows why (the daily look has never been switched on, or ran but
read nothing), and under it **Choose what Moe may read** opens the same
question the welcome asks: one switch per thing Moe could read, the daily
pass under them, **Save** or **Not now**.

### Where what Moe knows about you comes from

Four things feed what Moe knows, and they are not the same kind of knowing.
Three of them are Moe working something out; one of them is you saying it.
The difference is kept, and shown.

**Talking to Moe is the ordinary way, and it needs no switch.** After every
exchange, Moe quietly reads back what you just said and keeps anything worth
remembering for weeks: a name and who they are to you, a company or project,
a date, how you like a thing done. Only what you said yourself counts, never
Moe's own suggestions, the result of a job it ran for you, a web page, or
the text of something you pasted or quoted. A name or a number you did not
say is never kept, and before anything is kept a second quick check reads
it against your words and drops it if it adds anything you did not say, or
turns a remark about one thing into a general rule ("I didn't like that
restaurant's pasta" is not "dislikes pasta"). It
happens in the background, on the cheapest model your own plan or key
offers (the model you chose, on a custom or local endpoint), so your answer
never waits for it, and Background thinking off turns it off. Nothing asks you first, because you said it out
loud to your assistant. A moment after the answer, a quiet line under that
answer says what was kept, *Noted: Dana is your business partner*, in the
island and in Chat, with **Undo** beside it: one click and Moe forgets it,
here and on your cloud computer. It stays under the answer it came from even
if you have already asked the next thing. A fact you deleted is not picked
up again from later conversations. Lines that
arrived this way are marked *From your conversations*, and the way to
change one is to tell Moe. Every ten turns Moe also reads back over the
conversation for anything it should have written down and did not (see
*The read-back* below). When a conversation ends, Moe reads what you said
once more for things left open, a promise, a booking still to confirm,
and comes back to them later; that pass looks for follow-ups, not for
things to remember about you.

**Everything Moe reads by itself is opt-in, once, per source.** The welcome
asks on one screen. You are asked again the first time you connect a
source: a small sheet, *Let Moe learn from Notes and watch it for things
you'd want help with?*, with **Yes** and **Not now**. **Yes** switches that
source on, and the daily pass too if you had never answered it. **Not now**
records nothing and asks once more a week later. The switches under
Settings › Running in the background › Keeping up › Learn and watch are the
same answers, so you can say yes to your calendar and no to your mail.
Everything that pass works
out is stamped with where it came from and when, and how sure Moe is; a
fact you cannot trace is a fact you cannot argue with, so none are kept
that way.

**What the daily pass keeps is short, current and checked.** Reading a
year of your messages turns up thousands of things, and almost none of
them are worth carrying into every conversation. So each one has to pass
one test first: *would this be useful to recall in six months?* Greetings,
who is picking up whom, splitting a bill, and anything already said are
let go. Nothing about you is taken from what someone else wrote about you,
only from what you wrote or did. Where you live is kept as a city, never a
street, and phone numbers, email addresses, payment details, amounts of
money, and anything about health are never kept at all, whatever the
message said; this is checked by Moe itself, not only asked of the model.

**Facts and events are kept differently.** A fact is something that will
still be true in six months: what you do, who someone is to you, how you
write. An event happens at a time: a trip, a deadline, a job for a friend.
Events go under *Right now* with their dates, and about a month
after one is over Moe moves it to *Past*. It is not deleted: it is still
there under **Past** at the foot of the Memory page, Moe can still find it
when you ask, and **Restore** puts it back. Something that keeps happening, the sukkah
you build every autumn, is kept as a fact only once Moe has seen it happen
at least twice.

**One line per thing.** The same person under three spellings, or in
Hebrew and in English, is one person; the same trip mentioned a dozen
times is one line, and Moe counts how often it saw it. When something
changes, the line is rewritten to how things are now, and the old wording
goes to *Past*. When two things Moe learned disagree and it cannot tell
which is true, it keeps both, marks them, and asks you under **Check
these**; it never quietly picks one. It asks at most about five things at
a time.

**Each night, Moe tidies what it knows.** After the daily pass, and on
days when there was nothing new to read, Moe merges what repeats, moves
what is over to *Past*, keeps only the most important few of each kind (up
to fifteen things about you, twenty-five people, fifteen things going on),
and rewrites its short picture of you, the one at the top of the Memory
page and the first thing Moe reads before every conversation. That
picture is made of what stays true about you, plus at most three things
happening now or coming up; something that already happened, *was
testing a bot*, *just wrapped up the season*, is never in it. The same
goes for the lines about you and your people: *friend; recently back
from abroad* keeps *friend*, and the news goes with what is going on.

**A meeting can become something Moe knows.** When a meeting ends and the
notes are written, Moe hands them to its own thinking part as a quiet note,
and what to keep is that part's decision.

**Your own notes outrank anything Moe worked out.** The plain files behind
**Your notes** are in your own words, and they are what Moe's memory is
first filled from when it is set up. When there is more to remember than
there is room for, your own words about yourself take about three quarters
of the space and Moe's own portrait of you fills what is left. A line you correct becomes yours:
it does not expire the way a worked-out fact does, and no later pass can
bring the old wording back.

**A line you have not filled in is not a fact.** *About me* starts as a
short form, *Name:*, *What I do:*, *Where I am / timezone:* and so on, and
only the lines you have written something after are carried into what Moe
knows. A blank line stays a blank line on the page; it is never read as
"this person has no name". If an earlier Moe took the empty labels in, they
are dropped the next time Moe starts, on this Mac and on your cloud
computer alike, and nothing you actually wrote is touched.

**The honest state of a first week.** Moe learns your work and your people
from what you tell it, and from the daily pass once you have allowed it
something to read. Until one of those has happened, *About you* is short:
that is the truth, not a fault. Say it once, "I run the shop", and it is
kept.

**Your name it knows from day one.** The name on your Mac account (the one
on the login screen) is written into *About you* the first time Moe starts,
marked as coming from the Mac account so you can see where it came from.
Correct it or remove it on the Memory page like any other line: a name you
set yourself is kept over it, and one you removed is never put back.

**The read-back after a conversation runs on the brain you chose.** Every
ten turns Moe re-reads the conversation and may quietly save something it
learned. For a few days that read-back ran on the cheapest model your
provider offers, to save on the plan; it saved less than it should have
and once got a fact wrong, so it runs on your conversation's own model
again — whichever brain that is, a Claude or ChatGPT plan, your own key,
or a hosted service. If you had set a model for it yourself, that stays.

**Moe is told, in its own instructions, to keep memory the one way it is
read back.** Everything Moe knows about you is shown to it at the start of
every conversation from one place, its memory, and the instruction it
carries says to save there, in the same turn, without announcing it. An
earlier Moe's instructions pointed it at the note files under **Your notes**
instead, which nothing reads after setup, and for a week it saved almost
nothing anywhere. That paragraph is replaced on your Mac the next time Moe
opens; anything you wrote yourself in that file stays.

### Bringing in what another assistant knows

**Memory › Import from ChatGPT or Claude** takes what another assistant has
remembered about you:
1. Pick ChatGPT or Claude.
2. Copy the question the sheet shows into a new chat there. It asks that
   assistant to list everything it remembers about you.
3. Paste its whole answer back and press **Import**.

Moe reads it and keeps each fact marked as from ChatGPT or Claude. If one
disagrees with something Moe already knows, it becomes a question under
**To check**; nothing is overwritten. Nothing you told Moe yourself is
changed. The sheet then says how many things were new, how many Moe already
knew, and how many are waiting under To check. The pasted text itself is
not kept.

### What I learned this week

On Sunday morning, from 9 your time, Moe sends one short note, but only if
it learned something new that week. The note says how many things it
learned about you, lists up to five of the newest with where each came from
("from our chats", "from WhatsApp", "from ChatGPT"), and says how many more
are on the Memory page. It comes to the island, and to your chat apps too
if reminders go there; quiet hours hold it for the morning. If one is
wrong, say so ("forget the second one"): a fact from a conversation is
forgotten then and there, and anything else is on the Memory page with its
own Delete. Anything you told Moe yourself is never listed, since it isn't
news to you.

### What Moe remembers, and what it does not

**A memory is something that would otherwise make you repeat yourself.** A
preference you state. A correction, which is the same thing arriving the
hard way: you told Moe it had your job title wrong, or that the person
called Sam is your accountant and not your brother. A fact about you or
your setup, where your work lives on this Mac, which calendar is the real
one. And a convention you keep, the sort of thing a new colleague would
learn in the first week and then never need told again.

**Most of what you say is not that, and Moe is meant to let it go.** The
back and forth of getting something done is not memory. Neither is where a
task got to; that is what the conversation itself is for. Neither is
anything Moe can look up again in a second, or a to-do. If everything
became a memory, memory would be a transcript, and a transcript is exactly
what it must not be.

**Memory is small on purpose, and it stays small.** There is a hard budget,
about a page of what Moe knows about you and about a page and a half of
Moe's own notes. A save never fails because memory is full: what Moe was
told is kept, and other entries step out of the part that is read before
every answer to make room for it. Your name, and anything you told Moe or
wrote under Memory yourself, never step out for age; after those, the
newest entries are kept, and one long entry that does not fit no longer
pushes out every shorter, older one behind it. The entries that step out are
not deleted; they stay under Memory, and Moe brings one back when the
subject comes up. It finds them by the words in your question that are rare
in your memory, the dentist's name, *penicillin*, the name of a project,
and not by the ones every sentence has; *what do you know about my
accountant* brings back the line about the accountant, not three lines that
happen to contain *what* and *you*. The line comes back exactly as it was
saved. Moe tidies
as it goes, merging two overlapping entries into one, dropping something
that has stopped being true, so that what is read every time stays sharp.
The reason for the tightness is that all of it is read before every single
answer: ten good lines beat a hundred mediocre ones.

**A memory is written as a plain statement of fact, never as an order.**
"You prefer concise answers", not "always answer concisely". Because memory
is re-read at the top of every conversation, anything phrased as a command
would be read as a command, forever, and could quietly override what you
are actually asking for right now.

**Moe will also refuse to write a memory that reads like an attempt to
plant instructions for later.** Text arrives from all over, a web page, a
mail, a shared document, and memory is the most valuable place in the
system to hide something in. So anything shaped like "ignore your previous
instructions", or "do not tell the user", is turned away at the door rather
than saved. You will almost certainly never see this happen.

**The honest limit: Moe remembers when it judges something worth
remembering.** It is not recording you. There is no guarantee that a thing
you mentioned once, in passing, made it into memory. That is not the same
as gone: your conversations are kept, and searching them under Settings ›
Chats finds plenty that memory never held. Memory is the shortlist. The
conversations are the record.

### Where what Moe knows is kept, and what deleting really does

**All of it is on this Mac.** Two plain files are the part you can read
yourself: before every conversation Moe reads the things it knows and the
things it knows about *you*. **Open folder** on the Memory page opens one
folder with both of those files beside what it learned from the things you
let it read.
Open them in any editor; type a line in and Moe takes it as something it
now knows.

**Underneath, every single thing Moe knows is kept separately**, as its
own entry with its own identity, the time it was learned, and where it came
from. That is why a fact can be corrected or removed exactly, on its own,
and why two of your devices can both be learning things at once without
either overwriting the other: the same fact learned twice on two devices is
one entry, not two.

**Deleting is real.** When you tell Moe to forget something, it writes
down, permanently, that the fact is gone, and that goes everywhere the fact
itself went. A deleted fact does not quietly reappear from your phone or
your cloud computer a week later. If Moe meets the same fact again *after*
you deleted it, it does not decide on your behalf that you have changed
your mind: it sets the fact aside as a question rather than restoring it.

**What Moe knows is locked.** With Away, the words of every entry are
sealed with a key only your own devices hold. Someone holding the file,
including the service that carries entries between your devices, has the
entries and cannot read a word of them. If Moe cannot seal something, it
does not send it. What travels between devices is the entries, facts
learned, facts deleted, corrections; the two plain files do not travel.
Each device builds its own copy of them from the shared entries after every
sync, which is exactly why they cannot drift apart into two different
stories.

## Connections

**Connections**, under *Reach* in the main window, is everything Moe can
read and act on for you: the apps already on this Mac, Google, and around
1,400 other services. Everything on it works while the Mac is awake; asleep,
Moe is asleep too, unless you have [Away](#away-moe-when-your-mac-is-closed).

You can also just ask: "connect my Notion". When something you ask for
needs a service that is not connected, Moe says so and offers to connect
it. Say yes, confirm, and it gives you the sign-in link, from your Mac or
your phone.
You sign in on the service's own page, and it is connected the moment you
finish. Moe never starts a connection you did not ask for.

Connecting, disconnecting and checking a service are all done with the
Python that ships inside Memoe, never one that happens to be installed on
your Mac — so installing, updating or removing Python yourself changes
nothing here.

### The page

The list on the left is in a fixed order. **Thinking** at the top is the
brain row, the account Moe thinks with, with *Working*, *Needs a sign-in*
or *Starting…*. **Needs you** appears, in amber, when a connection has
broken. **Yours** is what you have connected. **Your Mac** is the apps
already here: Calendar, Reminders, Notes and Contacts first. **Popular** is
Gmail, Google Calendar, Google Drive and the rest of the everyday services.
**More on your Mac** is the rest of what this Mac holds. **Popular at
work** is Slack, Notion, GitHub, Linear and their kind. **Everything else**
is the rest of the catalogue, and a line under it says how many more a
search will find: the whole catalogue is one word away in the search box at
the top. **Advanced**, folded at the bottom, holds the other ways in for
people who know they need them, including **Add a server by address…** for
your company's own service or one nobody has heard of. **Check again** at
the foot re-reads everything.

Each row's second line is its state: **Working** (with *checked just now*
on the detail pane), **Needs you**, **Not available yet**, **Couldn't
check**, or, for something not yet connected, one line on what it does.
Click a row and the detail pane says what Moe can do with it, which account
is signed in (each account has **Rename**, for *work* and *personal*, and
**Remove**), and the button that connects it: **Sign in**, **Paste a key**,
**Connect**, **Turn on**, **Add a mailbox**, **Link my phone…**, or **Add
another** once one account is in. **Disconnect…** is on the right: Moe
forgets the sign-in and stops reading it; nothing at the service itself
changes.

The buttons stay at the foot of the detail pane whatever size the window
is, and the page above them scrolls when it is longer than the window, as
it is for a service with several accounts. In a narrow window the buttons
stack instead of running off the side.

If connecting fails, the sheet says what went wrong in a sentence and what
to try next, and nothing is changed. When Moe could not make a secure
connection to the service, it says *Moe couldn't make a secure connection to
finish setting this up*: quit Memoe, open it again and try once more, and if
it still fails, check that your Mac sets its date and time automatically
(System Settings › General › Date & Time) and pause any VPN or web filter
while you connect.

The first time you connect a source, a small sheet asks *Let Moe learn
from Notes and watch it for things you'd want help with?*, with **Yes** or
**Not now**; see [Keeping up](#keeping-up).

### The apps on this Mac

These need no sign-in, only the macOS permission each one names:

- **Calendar** — every calendar in Calendar.app, Google ones included.
- **Reminders** — what you still owe people, and adding one when you ask.
- **Apple Notes** — your notes, re-read every ten minutes.
- **Contacts** — who you mean when you say a name, and their number or
  email.
- **Messages** — what people have said to you in iMessage and SMS, every
  message including the ones recent macOS stores only in their formatted
  form. Needs Full Disk Access.
- **Mail** — the mail in the Mail app on this Mac, every account set up
  there, not only Gmail: inbox and sent, with the whole text of each
  message. Needs Full Disk Access, like Messages. When the same email also
  reaches Moe through Gmail or Composio, Moe thinks about it once, not once
  per route.
- **Phone call history** — who called and when, so you know who you missed.
- **Recorded calls** — what was said on calls your iPhone recorded, from
  their transcripts.
- **Google Drive** — the files Google's Drive app has synced to this Mac,
  read as files. No Google password.
- **Google Docs and Sheets** — documents you pick yourself in your browser,
  those and nothing else in your Drive; **Pick more files…** adds to them.
- **Chrome browsing** — the page you were reading, never your searches. Off
  until you turn it on; **Turn on** and **Turn off** are its buttons, and it
  is the one source that is opt-in for keeping ready as well as for
  learning.
- **Gmail** — your mail read directly over IMAP with an app password, never
  your Google password; Moe can read it and draft replies, and sending asks
  you first.
- **My own Telegram** and **WhatsApp on this Mac** — your own accounts;
  see below.

### Google, and about 1,400 other services

Moe reaches Gmail, Google Calendar, Drive, Docs, Sheets, Tasks and Meet, and
around 1,400 other services, through **Composio**, a broker that holds the
sign-in on your behalf. You connect one by clicking **Sign in**: a page
opens, you sign in the ordinary way, and you are done, with no developer
account to make and nothing to paste. Over a hundred services work that
way, and they are the names you would expect: Gmail, Google Calendar,
Drive, Docs, Sheets, Slides, Tasks, Meet and Photos, Slack, Notion, GitHub,
GitLab, Jira, Confluence, Linear, Asana, Trello, ClickUp, Salesforce,
HubSpot, Zendesk, Stripe, Square, QuickBooks, Zoom, Teams, Outlook,
OneDrive, SharePoint, Dropbox, Box, Figma, Canva, Miro, Airtable, Mailchimp,
Calendly, Typeform, YouTube, LinkedIn, Reddit and dozens more, each with its
own logo.

**What is listed before you type.** The services most people actually use,
most used first: a **Popular** shelf for everyday life (Gmail, Google
Calendar, Drive, YouTube, Outlook, Docs, Sheets, Maps, Photos, OneDrive,
Notion, Instagram, Discord, Dropbox, Reddit, Canva…) and a **Popular at
work** shelf (Slack, Teams, Zoom, GitHub, Salesforce, HubSpot, Jira,
LinkedIn, Google Meet, Stripe, Figma…). Only services you can connect today
are on the shelves: one sign-in, or a key from the service's settings.
Everything else follows, still most popular first, and typing a name finds
any of the around 1,400.

**Always on.** A few services need no sign-in at all: Yelp, Hacker News,
OpenWeatherMap, AllTrails and GoDaddy's domain search. Their rows say
*Always on — nothing to sign in to*, and Moe uses them whenever you ask ("find
a coffee place near me on Yelp", "is memoe-shop.com available?"). There is
nothing to connect or disconnect. Otter, Granola, Lucid, Descript and Mercury
sign in on the service's own page, the same way as Gmail.

**Pasting a key.** Most of the rest give you a key on their own settings
page, usually under a heading like *Developers*, *Integrations* or *API*.
Click **Paste a key** and Moe asks the broker what that service wants, the
field names are the service's own, so one may want a key and another a key
and a subdomain, shows each field with the service's description of where
to find it and a *Where do I find this?* link, and you paste and click
Connect. The key goes straight to the broker, is never shown again, never
written to a log, and Disconnect removes it there. A few dozen services
offer neither a sign-in page nor a key; those end with *Composio did not
return a sign-in link*, and Moe says so rather than pretending.

**The first time, Moe asks you to sign in with Google first**: its own
sign-in, a plain "which account is this" screen, before the service's. Your
connections belong to your Memoe account, so they follow you to your other
Macs and to your cloud computer, and signing in once is what creates that
account. The rows say *Sign in with Google to connect* until you have. Under
the button, one line, *By signing in you agree to the Terms and Privacy
Policy*, both linked. Signing in records nothing else: nothing you say is
sent anywhere by it. If you connect nothing, you are never asked.

**What you will see, and it is worth knowing in advance.** The permission
screen Google shows you says *Composio* rather than *Memoe*. That is honest,
Composio is the service holding the sign-in, and it is the one real cost of
this route. In exchange you never meet Google's developer console. Your
mail and calendar requests travel through Composio's servers when Moe uses
this route, and through Memoe's own server before that: it holds the
Composio key, so your Mac never does, and it checks each request against
your plan. Asking is free on every plan. Anything that runs on a schedule
(a reminder that reads your inbox every morning, say) needs a paid plan, and
every plan has an hourly and a daily limit on actions; past one, Moe says
the limit is reached and when it resets.

**A second account.** Once a service is connected its button says **Add
another**; sign in again there and it becomes a second account beside the
first, a work one and a personal one, say. Moe can use both: say which one
("send it from my work address", "check my personal inbox") and it acts as
that account. If you don't say, it uses the account Composio holds as your
default, which is usually the one you connected most recently. Moe knows
each Gmail account by its address, even one Composio never recorded a name
for, so naming an address always reaches that account; name one that isn't
connected and Moe says which ones are rather than sending from the default.
Composio holds up to **five accounts per service**. At that limit, **Add
another** says so, and removing one you no longer use makes room. A
sign-in you started and never finished no longer takes one of the five.

**Removing one account.** Each account's row has **Remove**. Moe asks
first, naming the account (*Remove work@example.com from Gmail?*), then
forgets that one sign-in; the others stay connected and nothing at the
service changes. The list and the count of accounts update when the sheet
closes. Removing the only account left is the same as **Disconnect…** and
asks the same question. **Disconnect…** on a service with several accounts
still asks which one.

**Moe prefers the broker.** Where a service can be reached two ways, Gmail
through the broker or through an app password on this Mac, Drive through
the broker or through the Drive folder on this Mac, the broker's row comes
first, and the Mac route sits inside it under *Also*: **Use an app password
instead**, **Read the folder on this Mac instead**, **Read documents you
pick, on this Mac**. One sign-in at the broker works on your Mac and on
your cloud computer, which the Mac-only routes cannot promise; the Mac
routes never leave your Mac, and where privacy matters most they remain the
better path. Anything you connected either way stays under **Yours**.

**How it behaves.** Moe does not carry 1,400 services' worth of tools
around with it. When you ask for something calendar-shaped, it searches for
the right tool at that moment and runs it, so adding services does not make
Moe slower or more expensive to think. If a service is not connected yet,
Moe offers you a link rather than failing; sign in through it and Moe
carries on with what you asked. Moe also ships with short guides to the
Google services, which tool answers which question and which settings keep
an answer small, and it applies the cheap settings for you unless you ask
for the whole thing.

**Asking is free. Watching is not.** Connecting these services and using
them whenever you ask costs nothing. What needs a paid plan is anything
that runs on a clock: watching a mailbox for a particular sender, a
calendar for changes, or the background passes reaching into Google on
their own. On a free Mac that is stopped before the request is made, and
Moe tells you once what it did not do. Ask for the same thing yourself and
it happens immediately.

There is also a ceiling on how many requests Moe will make to these
services, on every plan, so that something going wrong in the background
cannot quietly spend a month's worth of requests in an afternoon:

| Plan | Calls an hour | Calls a day |
|---|---|---|
| Free | 50 | 150 |
| Away | 100 | 200 |
| Away+ | 200 | 500 |

What counts is what Moe does with a service: reading your mail, adding an
event, sending a message. Before it does any of those Moe looks up which
tool to use, and that looking-up is not counted, so one thing you ask for
is one request and not two or three.

You are very unlikely to meet it by asking questions. If you do, you see
one plain line in the conversation, *Moe has reached this hour's limit of
50 requests to your connected apps. It can use them again at 3 PM.*, once,
and Moe starts again at the top of the next hour or day; nothing
is disconnected. Moe reads which plan you are on from your account, and if
it cannot reach us it keeps using the answer it last got for up to a month,
so a few days offline costs you nothing.

### GitHub, and the code on this Mac

**GitHub** is in the catalogue and connects with one click, **Sign in**,
through the broker. Connected, Moe can read repositories, issues, pull
requests, releases, commits and code search, and it can also write: open a
pull request, push a file, merge, comment. GitHub marks which of its tools
write, so Moe asks you before any of them run, the same way it asks before
sending a message.

**Without connecting anything.** If you use the GitHub command line (`gh`)
and are already signed into it, Moe can use that sign-in as it stands. That
path is read-only on purpose: it lists your repositories, your recent
commits, your pull requests and issues, and searches your code, but never
pushes, merges, comments or opens a pull request.

**The repositories on this Mac** need neither. Moe can list every git
repository on your Mac with its branch and whether it has uncommitted work,
and show the status, log or uncommitted changes of any one of them, which
is often the fastest true answer to "where did I leave off".

### Your own WhatsApp and Telegram

Two rows on Connections are your own accounts, Moe reading and writing as
you. They are different from the Telegram and WhatsApp on [Message
Moe](#message-moe), which are a bot you message and Moe answers.

- **WhatsApp on this Mac.** You link this Mac from your phone, the way you
  link WhatsApp Web: **Link my phone…** shows a code, and you scan it under
  WhatsApp › Settings › Linked Devices › Link a Device. That one link keeps
  a copy of your chats on this Mac, the ones your phone sends over when you
  scan and every one after while Moe is running. From it Moe can look back
  for what someone said, list who you talk to, find a chat by name, listen
  to a voice note, and write a message when you ask, asking you before
  every one it sends. Every message Moe reads there says who sent it to
  whom — you to them, them to you, or who wrote in a group — so Moe never
  tells you someone sent you a message you sent them. Looking a long way
  back (a month, a year) reads the newest messages up to its limit rather
  than failing. The moment your phone accepts the code, Moe says so
  and puts the code away; it then takes your recent chats from the phone
  and starts the link, and the row turns to "reading" by itself, with
  nothing to press. The row says which is true of the link: not linked
  yet; just linked and coming up, which takes seconds; linked, but Moe is
  not running; the link dropped (WhatsApp does that every few weeks, and
  you scan again); your chats still arriving; or reading, with how many
  chats it holds. A link you have only just made is never called a dropped
  one. Read the warning on the row first:
  linking a device this way is against WhatsApp's terms, accounts have been
  banned for it, and the link drops every few weeks. This row and the
  WhatsApp row on Message Moe are the same single link to your phone, one
  linked device, never two: scanning once gives you both.
- **My own Telegram.** Moe signs in as a linked device, the same as adding
  Telegram Desktop, so it can follow your conversations and write a message
  when you ask. Revoke it any time from Telegram › Settings › Devices.

Because the names collide, every screen says which one it means. Your own
account is *My own Telegram* and *WhatsApp on this Mac* wherever it
appears. Asked to send a Telegram message with no account signed in here,
Moe says it is not signed in to your own Telegram, and that this is
separate from the Moe you message on Telegram.

Asked whether it saw what you sent it on Telegram or WhatsApp, Moe on your
Mac no longer answers "not connected" when its bot there is working. Your
chats with the bot are their own conversation — Moe on the Mac does not
carry them in its head — but it can look them up when you ask ("what did I
just send you on Telegram?").

**WhatsApp Business**, in the catalogue, is something else: a company's
account, the kind used to answer customers, reached through the broker. It
cannot see a personal WhatsApp at all.

### How Moe knows what is connected

Moe answers "are you connected to my Gmail?" from one list with a part for
each kind of connection: the broker's services, every account you have
connected by name; what is on this Mac, each thing that is actually
working, with the exact way Moe reaches it; the servers you connected
directly; GitHub when the `gh` command is signed in; and the chat apps you
can reach Moe from. A connection that needs a permission you have not
given is left off rather than promised. A service connected one way is
connected: Gmail, Calendar and Drive can each reach Moe through Composio or
through this Mac, and Moe checks both before it says anything is not
connected; tell it you have just connected something and it checks for
itself rather than asking you to confirm. The list is rewritten the instant a
connection is added, renamed or removed, and the conversation you are in
picks it up on your next message.

The same list travels to your cloud computer, so Moe Away answers "check my
connections" from it too: the services connected through Composio by name,
the servers you added, and — marked as such — the apps that live on your
Mac, which it can only ask your Mac about. Ask either Moe about a service
you have connected, from Cloudflare to Notion, and it looks the service up
through Composio before it says anything; a service that is not connected is
reported as that, and Moe never starts a sign-in for you unless you ask it
to connect something. If you ask your cloud computer before your Mac has
sent the list across, it says so and still checks Composio for the service
you named.

## Message Moe

**Message Moe**, under *Reach* in the main window, is the chat apps you can
message Moe from, so a text from your phone gets an answer. It answers
while this Mac is awake; asleep, your message waits, unless you have
[Away](#away-moe-when-your-mac-is-closed), where your cloud computer answers
instead and it is the same conversation.

Seven rows: **Telegram**, **WhatsApp**, **Signal**, **Slack**, **Discord**,
**LINE** and **Email Moe**. The page groups them as *You can reach Moe
here* (connected), *Pick how you want to reach Moe* or *Also possible*, and,
at the top in amber, *Waiting to be let in* when somebody has knocked.

### Telegram

One click. **Create my Telegram bot** opens Telegram's own *Create bot*
screen for **@MoeSetupBot**, Moe's bot-making bot, with the name **Moe**
already filled in; tap *Create* and the bot is yours, belonging to your
Telegram account with an `@moe_…_bot` username of its own, and Moe picks it
up from there. No BotFather, no token to copy anywhere. The link is good
for about half an hour; if it goes stale Moe says so and gets you a fresh
one. Then pair your phone: open the bot Telegram just showed you and send it
any message. While the sheet says *Finish in Telegram…*, your hello appears
in it with an **Approve** button; press it and you are done. The
bot's `@username` is the one thing Moe does not choose beyond that pattern;
Telegram lets you change it yourself, in BotFather, if you care to.

Connecting the bot does not let Moe read your existing chats; that is
*My own Telegram* under Connections, a separate thing.

### WhatsApp

One QR code, shown in Moe: open WhatsApp › Settings › Linked Devices › Link
a Device and scan it. If the code expires on screen Moe shows the next one.
As soon as your phone accepts it the code goes away and Moe says it is
linked, takes your recent chats over from the phone, and finishes on its
own — there is nothing to press and nothing to scan twice.
This is the same link as *WhatsApp on this Mac* under Connections: one
linked device gives you both the number you can message Moe on and the
copy of your chats it reads from. On your phone the linked device is called
Moe. Read the warning first: linking a device is against WhatsApp's terms,
accounts have been banned for it, and the link drops every few weeks and
needs scanning again. Because it is a link to your phone, it stays on the
Mac that scanned it and cannot move to your cloud computer.

### Signal

Signal has no bots, so Moe joins your own Signal account as a device, the
same thing Signal Desktop is. You scan one code (Signal › Settings › Linked
devices › **+**) and from then on you talk to Moe in **Note to Self**; its
answers appear there. Before the code, a sheet says what linking means and
waits for **Continue**: this Mac receives your whole Signal account, every
chat and group, the way any linked device does. Moe acts only on what you
write in Note to Self; it never answers your contacts, it is never in your
groups, and a message from someone else gets silence rather than a reply
from your account. The first time you connect it, Moe downloads the Signal
software it needs, about 180 MB, once, and only if you connect Signal.
Unlink whenever you like from Signal › Settings › Linked devices, or with
**Disconnect** on the row, which deletes the keys from this Mac. Signal
answers while this Mac is awake and stays on this Mac.

**If anyone else logs in to this Mac, do not connect Signal.** While Moe is
running, the Signal software listens on a local connection that has no
password, and on a Mac every login and every program can reach a local
connection. Someone else signed in to the same Mac could read your Signal
messages and send them as you. On a Mac that only you use, that is no wider
than what the programs you run can already see.

### Slack

**Add to Slack** opens a page that first names the Memoe account Slack is
being added to, partly hidden, like *s\*\*\*\*@gmail.com*; if that isn't
yours, choose *This isn't my Memoe account* and nothing happens. Then you
sign in with Google as that same account, so a link somebody else made
cannot connect your Slack to their Memoe unless they can sign in as you.
Slack's own page follows: pick a workspace and choose **Allow**, and Moe is
there under Apps. Finally Moe on your Mac asks once more, *Slack workspace
… as … wants to connect — confirm?*, and nothing you write in Slack
reaches Moe until you confirm. Moe reads only what is written to it: its
own Messages tab, and "@Moe" in a channel someone has added it to. A
connected row offers **Add to Slack** again for a second workspace. If a
workspace deletes Moe or revokes its access, Moe removes itself from that
workspace and the row says so and why; **Add to Slack** puts it back.

If your workspace does not allow apps from outside, the sheet still takes
two keys from a Slack app of your own, a bot key and an app-level key.

**What Moe keeps of a Slack conversation: what it learned, not what was
said.** Slack is the one chat app where Moe reads your messages, updates
its memory, and does not keep the messages themselves. Once its reply has
been sent, the words of that exchange are removed from the conversation
history on your Mac and, if you have one, on your cloud computer; a short
note saying *no verbatim copy kept* stands where they were. What Moe took
from them stays: a fact it learned about you, a reminder it set, a task it
carried out. So Moe cannot quote back what you wrote to it in Slack last
week; ask it what it learned and it will tell you.

### Discord and LINE

**Discord** wants one key from its developer portal; **LINE** wants two
from its developers console. Each row says which and links to the page,
and the sheet leads with what the key is, why Moe needs it, the numbered
steps, and what happens if you skip. LINE only ever delivers to a public
web address, which a Mac at home does not have, so connecting LINE points
it at Moe's cloud, which hands each message to your Mac while it is awake;
that needs this Mac signed in to Memoe, and the row says so until it is.

### Email Moe

You can have an email address of your own for Moe: `yourname@in.moebot.app`.
**Choose my address** takes a name, and from then on you write to Moe at
that address from your usual email and Moe answers in the same thread, from
that address. The row shows the address with **Copy address**, and
**Change address…** lets you pick another name, up to three times in thirty
days; your old name isn't given to anyone else for thirty days, and
**Disconnect** lets it go with the same wait.

**Your mail is recognised as yours; everyone else has to be let in.** Mail
from the address you signed in to Memoe with is yours, once Moe has checked
it was really sent by that address, in the last two days, unchanged since
it was signed, and written to your Moe address. Mail from anyone else waits
on this page until you let that person in, the same as a stranger messaging
your Telegram bot. Mail that cannot be shown to come from the address it
claims is ignored; mail forwarded through a mailing list or a forwarding
service often fails that check.

**When a mail doesn't show it was written to Moe**, Outlook, Hotmail,
Microsoft 365 and Yahoo never sign that, and a blind copy is never in the
To line, Moe emails the address it came from: *Did you send this to Moe?*,
with its subject, first lines and a code. Reply **YES** within 30 minutes
and Moe reads it; reply **NO**, or ignore it, and Moe never does. A late
answer is told the question has expired. Replies in a conversation with
Moe don't ask: every email Moe sends ends with a short reference, and a
reply to it within three days from the same address is read without
asking. Moe never reads its own words back out of your quote of them. If an
email from your own address can't be checked, Moe doesn't read it and the
row tells you why.

**What Moe sends, and what it never does.** Moe replies only to the person
who wrote, in the same thread, and never copies anyone else in. It writes
first only to you; to anyone else it only replies, within three days of
their last email. At most 50 emails a day, and 20 a day to any one address.
An address that bounces or marks Moe's mail as spam is never written to
again. Moe ignores automatic mail, out-of-office replies, newsletters,
no-reply senders, so two robots never write to each other. A long answer
arrives as one email; if Moe is still working two minutes after it started,
you get what it has so far and the rest follows in the same thread. Moe
sees attachments' names and does not open them. When Moe needs your OK for
something while answering an email, it doesn't ask by email, and that step
isn't done; the row tells you, so you can ask again from your Mac.

**What is kept.** Your email conversations with Moe are kept like any
chat's. Moe's cloud keeps the subject of the last email in each
conversation, encrypted, for up to thirty days, so replies stay in the
thread. Resend, the service that receives and sends the mail, keeps a copy
of received mail in its own records. This address is separate from
connecting your own Gmail, which lets Moe read and send from *your*
address; neither affects the other.

### Strangers wait for you

Anyone can message a bot, so a chat Moe does not know does not get
answered: it waits, and the row says who is asking, with **Approve** and
**Not now**. Until you approve, their message is received and nothing is
sent back. Approving once is enough; after that the chat has a thread of
its own. While a chat is waiting, Moe keeps its id, whatever the sender
calls themselves, and when they last tried, enough for you to decide who
they are; it does not keep what they said.

### What arrives in the chat is Moe's answer

When you message Moe on any of these, what comes back is the answer, not a
running commentary on how Moe got there: no tool names, no step counts, no
notes written for the people who build Moe. Nor does Moe chatter about
itself: no message when it restarts, shuts down, goes to rest or comes back,
and no questions about its own disk space or housekeeping; the rare notice
that is left says what happened in plain words. File names, commands and
error codes stay out of its replies unless you ask for them. If something
genuinely takes a while, Moe says so in its own words, an account of the
work rather than a stock line. Interrupting
still works: send something while Moe is busy and it changes what Moe is
doing, without an announcement. On your Mac, the chips under Moe's reply
and what it says out loud as it goes are unchanged; that is Moe's own
screen, where seeing the work is the point.

### When your Mac is closed

With Away, one bot and one conversation: you message Moe on Telegram, or
Slack, or Discord, and if your Mac is awake it answers, and if your Mac is
closed your cloud computer answers instead, and you cannot tell which. Your
cloud computer carries Telegram, Slack, Discord, LINE, WhatsApp Business
and Email Moe. Signal and the WhatsApp you scanned a code for are links to
your phone that cannot move, so those two stay on your Mac. Everyone you
had already let in stays let in.

<!-- moe:switch MOE_EDGE_CHANNEL_SOCKETS on -->
**Discord, and a Slack app of your own, travel too.** Neither will deliver a
message to an address you hand it, so Moe's cloud opens a connection out to
each and holds it, using the key you gave Moe when you connected the app.
Moe will not call either of them connected until the app itself has
accepted that connection; while that is still coming the row says so, and
it corrects itself with nothing for you to re-run.

**When your cloud computer is the one answering, the row says so.** Handing
a chat app to your cloud computer takes it off your Mac on purpose, so the
row reads *Connected — your cloud computer answers Telegram, so it keeps
working while this Mac is closed*, and **Check again** agrees with it. The
whole of it is under [Away](#away-moe-when-your-mac-is-closed).

### Voice notes

When your chats go through your cloud computer, you can send Moe a voice
note instead of typing: a Telegram voice message, audio file or round video
message, or a WhatsApp Business voice note. Moe's cloud turns it into
words and Moe answers them the way it answers anything you type. Moe knows
it was a voice note, so it can say so if it misheard.

Listening to voice notes comes out of the same monthly **Listening**
allowance as the [premium hearing](#premium-voice-and-hearing-on-paid-plans)
(6 hours on Away, 12 on Away+), counted by the length of each note. The
recording is used once and not kept, and the written-out words travel
sealed like everything else you send.

If a voice note cannot be listened to, Moe still knows you sent one, and
tells you, usually by asking you to type it. That happens when your plan
does not include Away, when this month's Listening allowance is used up,
when a note is longer than 30 minutes, or if the listening service does
not answer in time. A note from someone you have not let in yet is not
listened to at all; they wait to be approved, the same as when they type.
**Premium hearing and voice** in Settings › Voice is about your Mac's
microphone and does not change this.

## Away: Moe when your Mac is closed

Everything Moe does on your Mac is free and stays free. **Away** is the
optional half: a private computer of your own in the cloud, running the
same Moe, so it keeps working while your Mac is closed. It answers your
messages from your phone, runs your reminders, checks what you've
connected on a schedule, keeps your memory and conversations in step across
your devices, and speaks in the Premium voice. Your words and your memory
travel sealed: the service in between carries them and cannot read them.

### Plans

| | Free | Away | Away+ |
|---|---|---|---|
| Price | $0 | $20 a month | $50 a month |
| Memoe on your Mac, everything on these pages | ✓ | ✓ | ✓ |
| Your own private computer in the cloud, with a browser signed in as you | — | ✓ | ✓ |
| Cloud computer hours a month | — | 150 | 400 |
| Connected services checked on a schedule | — | ✓ | ✓ |
| Calls to connected services, an hour / a day | 50 / 150 | 100 / 200 | 200 / 500 |
| Premium voice and hearing a month | — | 300,000 characters, 6 hours | 1,000,000 characters, 12 hours |

Your cloud computer rests when it has nothing to do, wakes when a message
arrives, and answers in a minute or two. Resting and waking are silent:
your chats only ever get Moe's own replies, never a note that the computer
stopped or started. Away+ gives it 400 hours a month instead of 150, and
larger allowances for everything else; for now it rests and wakes the same
way on both plans. The hours are counted while it is awake. The
thinking is the same on both, because it runs on your own AI account either
way. The allowances count for the whole account, however many Macs, and
reset on the 1st.

### This month's allowances, and packs

Settings › Away shows, under **This month**, how much of each allowance you
have used: the cloud computer's hours, the cloud voice, the cloud hearing,
and how many calls to your connected services it may make. When one reaches
80%, Moe shows a card once that month with a button to buy more.

Two packs are on sale on both plans, each $5 and each for the rest of the
month you buy it in, from Settings › Away:

- **Add 100 hours**: 100 more hours for your cloud computer.
- **Add a voice pack**: 150,000 more characters of the cloud voice and 2
  more hours of cloud hearing.

You see the price on Stripe's page before you pay, and the extra is added
as soon as the payment goes through. When your cloud computer's hours run
out, a message from you still wakes it and is answered; scheduled checks
wait for your Mac until the 1st, and we send you one email to say so. When
the cloud voice or hearing runs out, Moe uses your Mac's own voice and ears
until the 1st.

**What a plan does not buy is the thinking.** Moe uses your own Claude or
ChatGPT plan, or your own key, on your Mac and on your cloud computer. That
credential travels with you; we put no model of our own behind it and we do
not pay for the thinking, so there is no thinking allowance and nothing you
can run up a bill with us for by thinking too much. The only limit is
whatever your own plan or key already has.

Payment is Stripe's; your card number never reaches us. A subscription
renews monthly until cancelled; cancelling takes effect at the end of the
month you already paid for, so you keep the plan until then, and
part-months are not refunded. A failed card keeps working while Stripe
retries it. A price change takes 30 days' notice by email and only applies
at your next renewal.

### Settings › Upgrade

Until you have a plan the pane is called **Upgrade**: a headline, *Moe,
even when this Mac is closed*, two plan cards with what each gives you and
a button each, **Get Away** and **Get Away+**, and a line of fine print:
you'll sign in with Google first if you haven't, then pay on Stripe's page;
cancel any time; nothing on this Mac changes. Press one and that card says
*One moment…* while the next screen is prepared; the other card does not.
While something is still in the way of paying — the steps below, an open
payment page, a payment being confirmed — the two cards are put away and
the card at the top of the page is the whole story, so there is never a
plan button that cannot proceed. Where upgrades are not switched on, the
cards say what each plan gives you and carry no button.

### Before you start Away

Pressing **Get Away** (after signing in, if you had not) shows one short
screen before anything is paid for or sent:

> **Before you start Away**
> • You get your own private computer in the cloud, just for you. Moe keeps
>   working while your Mac is closed.
> • Moe moves in with everything it knows and everything it's connected to.
>   Encrypted on the way; we don't look at it. **What moves? ›**
> • Cancel whenever you like. We keep your copy 90 days, or delete it
>   yourself any time.
>
> By continuing you agree to the Terms and Privacy Policy.
> [Not now] [Agree and continue]

**What moves?** opens a short list in place: your memories and the
conversations you've had; what Moe knows about you and how you like things
done; the apps and accounts you've connected; the ways you message Moe;
your AI sign-in; your own Telegram and WhatsApp, where your cloud computer
becomes a device on each so it can read and send there. **Not now** closes
it, and nothing is recorded or sent. **Agree and continue** records that
you agreed, then opens the payment page. Your copy does not start moving at
the tap: it starts when your payment goes through.

**Steps first, then pay.** Before the payment page opens, Moe checks what
your cloud computer will need, so that it can start the moment you have
paid. Whatever this Mac thinks with, a key you pay for, your ChatGPT plan or
your Claude plan, comes along by itself. If nothing is connected for Moe to
reach you through, it needs one of those. Whatever is missing appears at
the top of the page, *Before you pay, your cloud computer needs this*, with
the plan you chose under it, one line each with the one button that does
it: **Sign in with Claude…**, **Connect one…**. **Continue to payment**
opens the payment page once every line is done; **Not now** puts the card
away. Nothing is charged and nothing leaves your Mac while you do them.

**While the payment page is open**, the top of the Away page says so:
*Waiting for your payment…* — pay on Stripe's page, then come back, and Moe
notices the moment it goes through. If your browser never brings you back,
**Check again** asks us now; if you closed the page without paying, **I
closed the page** puts the card away and nothing is charged.

**Back from paying, straight away.** When the payment page finishes, your
browser offers to open Moe, and Moe checks with us at once: *Confirming
your payment…*, asking again every few seconds for up to two minutes. If it
has not heard by then it says *We haven't heard from Stripe yet* and offers
**Check again** and **Put this away**. Back out of the payment page instead
and it says *Payment cancelled — nothing was charged*. Stripe also sends
you to a page of ours that names the plan you bought and lists the three
things worth doing first.

### Setting up your cloud computer

Paying makes your computer: one machine, one subscription, not shared with
anybody else's Moe. It is made switched off, and setting it up from your
Mac is what turns it on. **It starts by itself.** Once you are signed in,
on a paid plan you agreed to, with something for your cloud computer to
think with and a way for it to reach you, Moe starts the setup; there is no
button. If something is missing, the card at the top of the Away page says
exactly what, *Your cloud computer starts as soon as you do this*, with one
line and one button per thing, and it starts the moment you sort it out,
with Settings closed too. A line with a question mark means Moe could not
check, which is not the same as saying you have not done it; its button is
**Try again**.

**While it is being set up** the page becomes a short list you can watch,
under *Setting up your machine*: *Sorting out your plan*, *Making Moe a home
in the cloud*, *Waking it up*, *Introducing it to this Mac*, *Handing over
what it thinks with*, *Moving your memories*. Each ticks off as it is done.
There is no percentage, because there is nothing honest to work one out
from. It takes a few minutes; keep the window open while it works, and if
it is interrupted you can pick up again from here with nothing lost. The
island tells you when it starts and when your machine is ready. The list
and **Stop** are all the page shows while it works; your devices, what it
thinks with and the rest are behind **More** at the foot of the page, as they
are on every Away screen, and nothing about the setup asks you to compare or type a code.

Nothing is typed into the machine and nothing is typed off it: no pairing
code to carry, no message to send to a bot. The code shown on the screen
is the fingerprint of the pairing, there so you can see it happen. Your
cloud computer collects the keys and pulls your conversations; that first
pull happens inside your next message, so give the first reply time.

**When something goes wrong, there are two kinds.** Something that just
needs another go, a slow answer, a machine still starting or still being
made, is retried quietly and never mentioned. *Making Moe a home in the
cloud* keeps asking for the machine for as long as our side says it is on
its way, up to fifteen minutes, and the clock starts when our side first
answers, so a slow connection is never counted against it. If Moe could
not reach us at all, the page says so and offers **Try again**; nothing is
reported, because nothing is known to be wrong. Something that is ours
stops, reports itself to us, and says so: *We've hit a problem on our side
and we're on it — it's ticket #12. Nothing you've set up is lost, and you
don't need to do anything*, with the same emails as any report. If the
report could not be sent, the page says plainly that nobody has been told,
and **Tell Moe about this…** opens Chat so Moe can report it for you.

**A setup that has stopped carries on by itself.** *You don't need to do
anything* is meant literally: while the page says *We've stopped*, Moe goes
on checking, every half minute at first and then every few minutes, and the
moment your cloud computer is there it picks the setup up again and finishes
it, with nothing for you to press. Coming back to Memoe checks at once.
**Try again** is still there if you would rather not wait, and **Stop**
ends it. While it is stopped the list tells one story: the step that
stopped is marked, the steps before it keep their ticks, and nothing after
it is ticked or spinning. If you start again after an interruption and your
cloud computer turns out to be set up already, the page goes straight to
*How it is* instead of setting it up a second time.

### Settings › Away, once it is running

Once you have a plan the pane is called **Away**. *You're on Away.* Then
**Your plan**: when it renews or ends, **Manage plan** (Stripe's page:
change the card, switch plans or cancel; nothing about your card passes
through Moe), **Upgrade to Away+**, and **Check plan**, which asks us again
right now and answers beside the button. You only ever have one plan: if
you already have one, switching between Away and Away+ happens in **Manage
plan**, and Moe will not start a second subscription beside the first — it
tells you so and nothing is charged. **Upgrade to Away+** opens that same
Stripe page, already on the step where you change your plan, so you choose
Away+ and confirm. If Stripe opens the ordinary billing page instead, choose
Away+ under your plan there; and if the page shows no way to change plan,
tell Moe and we will switch it for you. If the last payment did not go
through, a banner says so with **Update card**; your plan stays on while
Stripe retries.

Under it, **This month** has one line for each allowance — *Cloud
computer*, *Cloud voice*, *Cloud hearing*, *Connected services* — with what
is used and when it resets, and the two packs, **Add 100 hours · $5** and
**Add a voice pack · $5**, each of which opens Stripe's page.

The first time Moe sees that you have a plan, a welcome card says what the
plan is for and offers the things worth doing first, each with a button
that lands on the control: **Open Message Moe** (a way to reach it), **Open
Connections** (something for it to watch), **Open Voice settings** (the
Premium voice). It only asks for what you have not done: a messaging app
you connected before paying, or a voice already set to Cloud, is left off
the list, and the sentence above it counts what is left. **Put this away**
dismisses it.

Then, once your machine is set up, four lines and nothing else, under *How
it is*: **Away** on · **Your machine** running or asleep · **Connections**
connected · **Memory** up to date. *Asleep* is normal: your machine rests
after about fifteen quiet minutes and wakes by itself when a message
arrives, so the first reply after a rest takes a little longer. The row
checks again every so often while the page is open, so it turns to
*running* when your machine wakes. Anything that needs you gets a sentence
and a button; anything merely in progress shows as busy. Everything else is
behind **More** at the foot of the page.

**Your devices**: this Mac, *Your machine in the cloud*, any other Mac, with when
each was added and **Remove…** where allowed. Only the first device you set
up can remove others; nobody can remove it; no device can remove itself. A
removed device can't sign in or receive anything new; what it already has,
it keeps. To use Memoe on another Mac, install it there and sign in with the
same Google account; it joins your plan by itself, though your
conversations stay on the Mac they were said on and do not travel between
Macs.

**What it thinks with.** Your cloud computer runs on your own model
account, never ours, and it thinks with whatever your Mac does: a key you
pay for travels as it is, a ChatGPT sign-in travels as a copy of the file
ChatGPT made on this Mac, and a Claude plan travels as the same sign-in your
Mac uses. Change any of it in Settings › Brain, or sign in to a different
account there, and your cloud computer follows; the page says *It thinks
with whatever your Mac does.* If you pick something different here with
**Change…**, your cloud computer keeps that, the page says *You gave your
cloud computer a brain of its own*, and **Use the same as my Mac** puts it
back to following. It uses the same model your Mac does, whichever
provider that is.
Removing it here never touches your Mac's, and a brain you removed is not
put back when you change your Mac's. **Change…** and **Remove…** are
beside it; Remove takes the credential off your machine, which then cannot
think until you give it another, and does not cancel the key at your
provider. Under the first line is your cloud computer's own word: *Your
cloud computer is using it*, or that it has it and can't open it yet, or
couldn't use it, or hasn't confirmed it. Whatever you choose is sealed on
your Mac before it leaves; only your machine can open it. A brain you give
it while it is running arrives without a restart, and a change made on your
Mac reaches it by itself where it can.

**Which one answers.** Two choices: **This Mac, while it's awake**, with
your machine taking over when it isn't, or **Always my machine**. It is
your account's choice, so it is the same on every device. Whichever you
choose, if that computer isn't reachable the other answers instead; this
setting can't leave you waiting. With *Always my machine*, a message that
arrives while it is asleep starts it, and this Mac covers that one message
while it comes up.

**Your chats in the cloud.** First, how Moe already reaches you — *Moe
reaches you on Telegram* — because the Moe you message is a different thing
from your own accounts, and this section is about the second. Your own
Telegram or WhatsApp account, if you connect it under Connections (**Open
Connections** is beside the line), joins your cloud computer as well: they
can't be copied, because each lets an account be signed in once per
device, so your cloud computer joins as another device, the way a new
laptop would. An account that is not connected on your Mac gets no line of
its own here; nothing on this page connects one. **Telegram joins by
itself** once you have agreed to Away's terms; it shows under Telegram ›
Settings › Devices like any other device, and if you remove it there Moe
does not add it back by itself; **Put Telegram back on your cloud
computer** is beside the line for when you want it again. If your Telegram
has two-step verification on, adding a device needs that password, and Moe
won't ask for it, so the line says so. **WhatsApp needs you once**, with
the number WhatsApp on this Mac already has: **Get a code** asks your cloud
computer for an 8-character code, and you type it on your phone under
WhatsApp › Settings › Linked Devices › Link a Device › *Link with phone
number instead*. It works for about three minutes; if it runs out, get
another. The warning that linking a device this way is against WhatsApp's
terms is beside the WhatsApp connector under Connections, where the linking
is done.

**While your Mac is off.** Not everything you connected on this Mac comes
along to your cloud computer by itself, so under your chats a short list
says, for each thing connected here, what your cloud computer can do with
your Mac shut: *works*; *waits for your Mac*, where Moe does it when your
Mac is next awake (Apple Notes, Messages, Reminders and the other Mac
apps); or one step away, saying where the step is. Your own WhatsApp
needs one code from your phone (**Get a code**, just above it, under your
chats); your own Telegram, if you took your cloud computer off it, can be
put back (**Put Telegram back on your cloud computer**, also above); and
Gmail you added with an app password, or Calendar and Google Drive read
from this Mac, work on your cloud computer once you connect the same
service under Connections (**Open Connections**). Signal stays on your Mac.

While one of those steps is still waiting, Moe reminds you once on the
island: *While your Mac is off*, the sentence, and **Show me** (this page),
**Not now** (it asks again in a week) or **Don't remind me** (never again
for that one). Each one is remembered separately, and **Remind me again**
beside the line on this page undoes a *Don't remind me*. The list itself is
always here, reminded or not.

**Sign out on this Mac…** stops this Mac taking part while your plan and
your other devices carry on; cancelling is under *Manage plan*.

**If one of your devices is no longer part of your account** — your cloud
computer was taken down or rebuilt, or another Mac was removed — this Mac
notices the next time it syncs, stops sending to that device, and carries on
syncing with the rest. Nothing on this Mac is lost. Settings › Privacy says
so once, under *Keep a copy in the cloud*, with what to do: set Away up
again in Settings › Away if it was your cloud computer, or add the other
device again if you still use it.

### What your cloud computer does

**It sleeps when you are not using it**, and starts back up when a message
arrives, so the first message after a quiet spell is slower than the rest;
everything after it is at the usual speed. It has two processors, so while it
is starting up it can answer you and do its own start-up chores at the same
time rather than one after the other, and 2 GB of memory, room for Moe and
its browser together. It is never put to sleep in the
middle of answering you. It has no address on the internet: nothing out
there can reach it or wake it, and the only thing that starts it is a
message that has already been checked as genuinely yours.

**If it stumbles mid-answer, it picks your message back up.** Should your
cloud computer restart while it is answering you, the restarted one is handed
your message straight away rather than after a wait. If a message still
cannot be answered after a couple of tries, Moe tells you so on the same chat
and asks you to send it again — it is never simply dropped in silence.

**It keeps itself up to date.** When a fix for the cloud computer is ready,
yours takes it the next time it is asleep: the update goes in while it is
off, so it is never interrupted in the middle of answering you, and the next
time it starts it is on the new version. If it is busy, it gets the update
after it next goes to sleep. There is nothing for you to do, and your
conversations, memory and connections on it are untouched.

**Anything you schedule still happens with the lid shut.** A sleeping
machine has no clock, so your cloud computer tells us when its next
scheduled thing is due, we start it a couple of minutes beforehand, and it
goes back to sleep afterwards. A repeating thing that was due while
everything was off happens once, when the machine next comes up, not once
for every time it was missed. Waking it keeps it up for a while afterwards,
so something scheduled more often than about every quarter of an hour
keeps it awake continuously; a few scheduled things a day is nothing.
While your Mac is away, your cloud computer also wakes at least once an
hour to look for anything that needs you, so a day with the Mac shut is
not a blind one.

**A question you closed the lid on is finished in the cloud.** Ask your Mac
for something that takes a while — some research, a comparison — and shut
the lid: for the first minute it stays your Mac's, in case you are only
moving rooms, and the Mac picks it back up when you open it. After that,
your cloud computer takes it over and carries on, and it tells you so in
one line on the chat you last spoke to Moe from, then answers there. Your
Mac, when you open it, is told the cloud has it rather than starting again
— even if its own work had quietly survived the sleep — and never answers
the same question twice. Only questions the cloud can do
travel: one that had already reached into your files, your screen or a Mac
app stays your Mac's and waits for it. If you have no chat connected there
is nowhere to answer you, so the question stays with the Mac.

**Your reminders travel with you.** A reminder you set on the Mac exists on
your cloud computer too, and the two take turns rather than both going
off: while your Mac is awake, the Mac runs it; when the Mac is asleep, your
cloud computer runs it and sends it to the chats you ticked. The moment
this Mac goes to sleep, locks or quits, it tells your cloud computer it is
away, and from then on the Mac runs nothing on its own, even in the brief
moments macOS wakes it in the background; the moment you open it, it takes
over again. A reminder you set from
your phone appears on this Mac as well, and "I did" said to either one is
understood by the other. The same goes for Moe's own nudges, the calendar
heads-up and the watches on connections that reached your cloud computer.
A one-time reminder whose moment has already passed is not brought back to
life on the other side.

**Every scheduled job is on both sides.** Ask Moe on your phone which jobs
you have and you get the same list as on the Mac, each with what it said
the last time it ran — wherever it ran. A job made on either side runs on
your Mac while the Mac is open and on your cloud computer while it is shut.
The one exception is a job that can only be done on your Mac, because it
needs a folder or file that is only there, a script of its own, or your
Mac's own browser. Moe marks such a job only when it has checked: what the
job needs is on your Mac, and it is not on your cloud computer. Your cloud
computer then lists it as *runs on your Mac only*, never runs it, and if it
comes up, tells you it runs on your Mac whenever the Mac is on and awake.

**Each run happens once.** Before a job runs, the side about to run it
checks that the other has not already started it, so a reminder your cloud
computer gave you while your Mac was shut is not given again when you open
the lid. Your Mac takes over again as soon as it is open; your cloud
computer covers once it has been shut or offline for about three minutes.
If your Mac has no internet when a job is due, it runs the job anyway rather
than miss it — that is the one time a job can run on both sides.

**A message that arrives while everything is off is kept, not lost.** If
something comes in on Telegram while your Mac is shut and your cloud
computer is asleep, we hold it, in a form only your machine can read, and
hand it over when the machine wakes, oldest first.

**What travels.** Your conversations, both ways: your cloud computer reads
what you said at the notch and answers from it, and what you say on
Telegram appears on the Mac in the same thread. Either Moe can look up what
was said on the other — ask at the notch "what did I tell you on Telegram
yesterday?", or on your phone "what did we decide on the Mac on Tuesday?",
and it searches both. A chat on Telegram that has been quiet for six hours
starts a new conversation next time, as the notch does. Your memory, sealed under a
key only your devices hold, so a fact saved at the notch is known on
Telegram after the next sync and a fact deleted on one is gone on the
other. Your AI sign-in. Your Google services and everything else connected
through Composio, which work on your cloud computer as they do on the Mac,
through a key made for you alone. The chat apps you connected: Telegram,
Slack, Discord, LINE, WhatsApp Business and Email Moe, moved across by Moe
itself, since it holds each bot's key from when you connected it. A
service you connect while your cloud computer is awake works on the next
message. The list of what is connected travels too, and so do the
skills you switched off on the Mac: your cloud computer reads the same
list before it says a service is not connected, and it never re-enables
a skill you turned off. Your skills themselves travel too, both ways.

**What stays on your Mac.** Messages, Calendar, Notes, Reminders, Contacts,
Chrome, calls, the Gmail you added with an app password, and the servers
you added by address. But *shut* is the word that matters: if your Mac is
awake, asking your cloud computer to read one of them, or to add to one,
is carried out on your Mac there and then, and the answer is in the same
reply, sealed both ways. If your Mac is shut, Moe queues it instead of
failing, tells you so in a sentence that does not over-promise, your Mac
carries it out when it is next awake, and you get one message afterwards
saying what was done. Signal, and the WhatsApp you scanned a code for, are
links to your phone and stay on your Mac.

**When it wants to send something, it asks you on your phone.** On your Mac
anything Moe sends to another person puts a sheet on your screen first. Your
cloud computer has no screen, so it asks the same question in the same
words on the chat you are talking to it on, with the recipient and the
message in front of you, and you answer it there — with a button where the
chat shows one, otherwise by replying *approve* or *deny*. Until you
answer, nothing is sent; if you never answer, nothing is sent. It is the same gate, not a
lighter one, and there is no "always allow" that means anything here: a
message is not a category, so the next one asks again. You have about an
hour to answer; miss it and Moe tells you it did not go, and you can ask
again.

**Every send asks, whichever way it would go.** The same question comes to
your chat for a message your cloud computer would send through a service you
connected in Connections — an email or a Slack message — or to someone on a
chat app, not only for Moe's own Telegram and WhatsApp connections. It is
checked by the same rules your Mac uses, and where your Mac would show you a
sheet, your chat shows the recipient and the whole message, however long
(a long email arrives over more than one message). Reply *approve* to send
it once, or *deny*. For these you have about nine minutes to answer. If
nobody can be asked — a scheduled job running while you are not in the
conversation, say — it is not sent, and Moe tells you why rather than
saying you cancelled something you never saw. Reading those services, and
everything else your cloud computer does, is unchanged.

**Who it listens to.** Only you, in a private chat. Strangers wait to be
let in, as on your Mac; a group chat is never written into your
conversation. Your cloud computer has no shell: it can search and read the
web, use your connected services and keep its own notes, but it cannot run
commands on a machine.

### The cloud browser

**Your cloud computer has a browser of its own.** When a job needs a website
while your Mac is shut — checking an order, reading a page that needs you
signed in, filling in a search — Moe uses a browser on your cloud computer.
Your own Chrome on the Mac is never used for this and never copied: your
cloud computer's browser starts with no sign-ins at all.

**You sign in to a site yourself, once.** Ask Moe on your chat app to sign
in to a site, and it sends you a one-time link. Open it on your phone and you
see that browser, live; type your password and answer your own two-step
check there. The link works only on the phone that opens it first, and only
for a few minutes. Moe never sees or types your password, and your sign-in
stays on your cloud computer — it is not sent to your Mac or to us.

**Settings › Away › Cloud browser** is the list of sites that stay signed in.
It starts empty. A sign-in to a site that is not on the list lasts for that
one job and is gone the next time the browser starts; Moe says so when you
sign in, and you can add the site to keep it. Type a site's address and press
**Add**; **Remove** next to a site signs your cloud computer out of it before
the browser next starts.

**It stops and asks you.** Before the cloud browser pays for something,
sends a message, deletes something, shares a password or grants access, Moe
asks you on your chat app first, exactly as it does for anything else it
sends. If a site asks whether you are human, Moe does not try to get past it:
it tells you on your chat app and leaves it to you.

**It stays small.** The browser keeps at most a few tabs open, closes itself
after a couple of quiet minutes, and is the first thing to go if your cloud
computer is short of memory, so Moe itself keeps answering.

### Keep a copy in the cloud

Agreeing to what Away does is something your account did, so once you have
paid, the copy is on, on every Mac you sign in on. The one thing that holds
it off is you: **Keep a copy in the cloud** in Settings › Privacy, on a
paid plan. Turn it off and your cloud computer stops learning anything new
from this Mac and keeps what it already has; it stops the copying, it does
not delete the copy. Turning it back on needs your yes to the current
Terms; if that is not on record, Moe shows you the summary to agree to
first. Moe pushes after every reply, and pulls on launch, when the Mac
wakes, when Moe comes to the front, every five minutes, and the moment
another device says it sent something.

### When you cancel

Cancel Away under *Manage plan* and your plan runs to the end of the period
you have paid for. When it ends, your cloud computer is switched off;
nothing on it is touched. About 90 days after that we send one email naming
the day it will be deleted, and 30 days after that email the cloud computer
and the copy we kept for it are deleted; your account is not. Start Away
again before then and it picks up exactly where it left off. You can also
delete it all yourself at any time with **Delete my account** under
Settings › Privacy. Nothing on your Mac changes when a plan ends: your
conversations, what Moe has learned about you and every service you
connected stay exactly where they are.

### Emails about your account

There are thirteen, and they are the only ones we send that you did not ask
for. Each goes to the address you signed in with, each is a short message
rather than a receipt, and every one of them can be replied to; a reply
reaches a person.

- **Welcome to Memoe**, once, when signing in with Google makes your account.
- **You're on Away** (or Away+), when a payment goes through.
- **You're now on Away+** (or Away), when you move between the two plans.
- **We couldn't take this month's payment**, if a card is declined. Sent
  once, not on every attempt.
- **Your cloud computer has used this month's hours**, once a month at
  most, when it does: it still answers when you write, scheduled checks
  wait for your Mac until the 1st, and it says how to add hours.
- **Your Away plan ends on …**, when you cancel.
- **Your Away plan is staying**, if you change your mind before then.
- **Your Memoe plan has ended**, on the day it does.
- **Your Memoe account is on hold**, and **Your Memoe account is back**, in the
  rare case we have to pause an account. Both say that nothing has been
  deleted.
- **Your Memoe cloud copy will be deleted on …**, once, about 90 days after
  your plan ends.
- **Your Memoe account is deleted**, when you delete your account: what went,
  what stays, and exactly what remains with us. It is the last email to
  that address.
- **A new key for agreeing was set up for your Memoe account**, when this
  Mac's key for agreeing is replaced (see [Privacy](#privacy)). If it
  wasn't you, reply to it.

A renewal gets no email from us; Stripe sends its own receipt. Connecting
Gmail, Drive or anything else produces no mail, and neither does signing in
on a second Mac.

## Privacy

On the free plan very little reaches us, and this is all of it. What you say to Moe, and
what Moe reads to answer you, goes to the AI provider you chose to think
with (your Claude or ChatGPT plan, or the company whose key you gave it), or
stays on this Mac if you use a model running here. Services you connect
through Composio go through Composio, and on the way they pass through our
server, which holds the Composio key, counts each request against your
plan's limits, and does not store what the requests say. Three things send something to us,
and each one asks you first: signing in with Google, which
sends only who you are; starting Away, which moves Moe into your own cloud
computer; and problem reports, which send what you asked us to look at. Two
more happen on their own, and there is no switch for them: once a day Moe
asks our website whether there is a newer version, a plain request that says
which version of Memoe is asking; and at most twice, ever, it sends our
server a single word to count a person coming back, once if a third spoken
command gets a real answer in your first week and once the first time one
does on or after day 7. That word is all it carries: no account, no device
or Mac identifier, and never what was said. Three more one-time counts work
the same way, each sent once per Mac with the app's version and nothing
else: the first time a newly installed Memoe is opened, when you finish the
welcome, and the first time Moe answers something you said or typed. A
fourth is off unless you turn it on: with **Tell us when Memoe crashes** on,
a Memoe that did not quit properly sends one count, with its version, the
next time it opens — no crash report and no logs. A Memoe you build yourself
from the open-source code sends none of these counts and does not check for
updates. The
speech recognition, the voice, the transcription and the memory all run on
your Mac. The full policy is at
[memoe.app/privacy](https://memoe.app/privacy), and it lists every service
that ever touches your data.

### Settings › Privacy

One page, in this order:

- **Let Moe send problem reports** — off to start with. *Sends Moe's
  description of the problem, the bit of your conversation it quotes, and
  recent lines from Moe's own logs to the Moe team. Our team and our coding
  assistant read them.* Under it, **What is sent?** opens the whole list.
  Turning it on sends nothing by itself: nothing was kept while it was off.
  See [When Moe itself breaks](#when-moe-itself-breaks).
- **Report without saying who I am** — off. *We can't reply or tell you when
  it's fixed.* On, no account, device, email or plan is attached to a
  report, and it isn't deleted with your account.
- **Tell us when Memoe crashes** — off. *If Memoe didn't quit properly last
  time, it sends one anonymous count with the app version — no crash
  report, no logs, nothing about you.* A force-quit or a Mac that lost
  power counts too: Moe only knows that it was not quit in the ordinary way.
- **Keep a copy in the cloud** — only on a paid plan. On, your cloud Moe
  keeps up with what Moe learns on this Mac. Turning it off asks first,
  *Stop keeping a copy in the cloud?*, and says what it means: your cloud
  Moe stops learning anything new from this Mac and keeps what it already
  has. Turning it back on needs your yes to the current Terms.
- **Cloud voice** — only on a paid plan. The same setting as Settings ›
  Voice's *Use the sharper voice and hearing that come with my plan*: on,
  what you say and Moe's replies go through speech services in the cloud;
  off, Moe hears and speaks on this Mac alone. The line under it says which
  is true right now.
- **Documents** — the Terms of Service and the Privacy Policy, each with
  **Open** and the version you accepted and when, *You accepted version
  2026-11-12.1 on …*, or *Not accepted yet. You're asked when you sign in or
  upgrade.*
- **Delete my account** — only while this Mac is signed in.
- **Erase Memoe from this Mac**.

### Terms and Privacy Policy: when you agree, and to what

You agree in three places, and each is recorded with the documents'
versions and the time: signing in with Google (the line under every sign-in
button), **Agree and continue** on *Before you start Away*, and turning on
problem reports. Turning problem reports off is recorded too. Each document
shows its version at the top; both currently carry **2026-11-12.1**. A small
correction changes only the date; a change that matters gets a new version,
and you are asked again: on a paid plan, *Our Terms and Privacy Policy have
changed* appears the next time Moe opens, in a small window of its own;
on the free plan, the next time you sign in, start Away or turn on problem
reports. Nothing stops while it waits, and closing the window changes
nothing.

### Only you can agree

Moe can work your Mac's screen for you, so the buttons that say yes on your
behalf answer only to you: **Agree** and **Agree and continue**, the
switches in Settings › Privacy, **Confirm it's you** under the problem
reports switch, the buttons that sign you in to your Memoe account with
Google (signing in is agreeing, as the line under each one says), and
**Delete my account** and **Erase this Mac**. A click or a key press you make works as normal. If anything else
presses one, Moe itself, another app, a script, nothing happens, and your
Mac asks you to confirm it's you with Touch ID or your password. If you
did not mean to, cancel, and the control says *Please click this yourself.*

One press is enough for everything that follows from it. When you press
**Agree**, Moe records it, and anything that agreeing needs (setting up this
Mac's key, see below) happens on the strength of that press, without asking
you to confirm it's you again. And when you were asked to agree because you
pressed **Turn it back on** in Settings › Away, or the *Keep a copy in the
cloud* switch, agreeing finishes that for you: the copy comes back on by
itself and you are not sent back to press the button a second time. So with
a mouse or trackpad the whole thing is two clicks and no Touch ID. Signing
in is the same: your click opens Google straight away, and if something
else presses the button no browser opens until you confirm it's you. If you
press these with VoiceOver, Voice Control or Switch Control, your Mac asks
you to confirm it's you once per press, because that kind of press looks the
same to Moe as one it could make itself.

Every yes is also signed by a key that only the Memoe app on this Mac can
use. It is set up when you sign in with Google, and our server accepts an
agreement only when it carries that signature, so nothing else on your
Mac, even something that could read Moe's files, can agree for you. If the
key has to be set up again (Moe was reinstalled, or the key was removed),
Moe asks you to sign in with Google once more when you next press
**Agree** (and to confirm it's you first, if that press wasn't a click of
your own), and we email the address you signed in with: *A new key for agreeing was set up
for your Memoe account*, naming the Mac and the time. If that wasn't you,
reply to that email.

If Memoe was updated and the new version could not use the old key, and
your Mac asks you to confirm it's you, the request says so: *Memoe was updated and needs you to confirm it's you once
more to keep agreeing on this Mac*. Nothing was lost; it is the same Google
sign-in, once.

If the key stops working on this Mac, Moe replaces it by itself the next
time you press **Agree**: it asks you to sign in with Google once more,
then records your agreement in the same press. If your
Mac still won't let it, Moe says so: *Memoe couldn't record that you
agreed, because this Mac wouldn't let it. Nothing was recorded. Restart
your Mac and try again*.

### Delete my account

**Delete my account** deletes everything of yours that we hold. The first
step says what that means: on a paid plan, *This cancels your plan and
deletes your cloud computer, everything on it, your connected accounts,
your problem reports and your Memoe account. Moe on this Mac keeps working,
signed out.*; on the free plan, that it deletes your sign-in with us, the
apps and accounts you connected through it, and your problem reports. The
second: *This can't be undone. Type DELETE to confirm.* Then Google asks
you to sign in, with the same account this Mac is signed in with; that is
how we know it is you, and it works on any Mac. Choose a different Google
account and nothing is deleted.

Your plan is cancelled at once (the time left in the current period is not
refunded), your cloud computer is deleted, and so are your connected
accounts, your problem reports, your agreements and your account. Stripe
keeps its own record of past payments, because tax law requires it. A
receipt goes to your address before we forget it. Moe on this Mac carries
on, signed out, on the free plan. A problem report you sent without saying
who you are isn't tied to your account, so it isn't deleted.

### Erase Memoe from this Mac

**Erase Memoe from this Mac** removes everything Moe put here: what it
remembers about you, your conversations, notes and meeting recordings, the
apps and accounts you connected, the ways you message it, the voices and
models it downloaded, its background jobs (stopped first), Moe's entry in
Login Items, the small tool Moe installed to work your screen (named only
when it will actually be removed; anything else on your Mac that uses it
stops working until it is installed again), and the permissions you gave
Moe. It warns you twice, in different words, and lets you **Delete my
account too** at the same time. **Show exactly what will be removed** lists
every item before you confirm. Then it asks you to prove it's you, Google
if you are signed in, otherwise Touch ID or your Mac's password, quits,
clears itself away, and opens again at the welcome screen like a new
install.

What stays: the Memoe app itself, the Python it downloaded, and Claude Code
and ChatGPT, their apps, their commands and their own sign-ins, which
belong to them, and your own files. If macOS won't let Moe remove
something, Moe doesn't pretend it did: when it opens again it shows one
note naming what is left, with **Show in Finder**, so you can finish the
job yourself. There is no separate uninstall; this is the one way out.

### What we can and cannot see

On your Mac, nothing. With Away, your conversations, your memory and your
AI sign-in are sealed on your Mac under keys only your devices hold; the
service that carries them between your devices holds them and cannot read
them. What that service can see is your email address, your plan and
usage, your agreements, your problem reports, the tokens for the chat apps
you connected for Away, the key to your Composio project, the name of a
stranger knocking at your bot before you let them in, and a message
crossing a chat app in transit, because that is what receiving a message
from another service means. Your cloud computer's own disk holds a readable
copy of your conversations, which is the point of it; someone with access
to our hosting account could technically open it, so staff open a cloud
computer only to fix something you asked about, with your yes on the
ticket. The privacy policy says all of this in full, and names where the
computers are.

## When Moe itself breaks

If something about Moe is wrong, not your mail or your calendar but Moe, a
feature that stopped working, a crash, an answer that was plainly wrong,
say so: **"report this to the Moe team."** Moe was there for the
conversation, so it writes the report itself: what you asked, what it did,
what came back, and where it went wrong. You don't have to explain it
twice. Moe also files a report on its own when it notices something of its
own failing that you haven't mentioned yet, and tells you it has.

What you get: **an email within a minute** saying we're on it, with a
ticket number, and **an email when it's fixed** saying in a few plain words
what was done, with a word from Moe on the island. If Moe updates itself,
the fix arrives with the next version. That is all: two emails, and nothing
about how. If the team ever has a question for you, Moe asks you on the
island and your answer goes back through Moe. Ask Moe to show
you a ticket and it reads you the title, what was written, everything that
has happened on it since, and exactly what was sent with it. You can add to
a ticket later ("tell them it also happens with the external mic") or ask
for the list. Reports need you to be signed in, because the email goes to
the address you signed in with. This works from your phone too: with your
Mac shut, tell Moe on Telegram or any chat app to report something and your
cloud computer files it the same way, under the same **Let Moe send problem
reports** choice in Settings › Privacy. Any way of saying it works —
"report this", "file a bug", "send feedback", "tell support" — and Moe
answers with the ticket number; it never tells you there is no way to
report a problem, and never just keeps it in its notes. If you turned that on before you
signed in to the account you use now, Moe tells your account for you, as
long as it can show the yes was yours: when you turn the switch on, Moe
keeps a signed note on this Mac that you were the one who pressed it, and
only a yes with that note is ever passed on without you. If there is no such
note (you turned it on in an older Memoe, or something else changed the
setting), or Moe needs you to sign in again, nothing is passed on and
Settings › Privacy says so with a **Confirm it's you** button: one click.

### What goes with a report

Moe's own short description of what happened; the part of the conversation
that shows the problem, when you asked for the report; Moe's version; your
macOS version; whether your Mac is Apple silicon or Intel; your plan; and
the last 40 lines of up to three of Moe's own log files, the app's, its
thinking part's and its background jobs', never the one that holds what
you say to it. A line in those that looks like a password, a key or a
token is left out, with a note that it was; where Moe's own description
mentions one, just the key is replaced. Your name is taken out of any file
path, and email addresses and your Mac's name are taken out of the log
lines and of what Moe wrote. A report is usually a few kilobytes and never
more than about 80 KB. Never your files, notes, memories, saved passwords,
screenshots, or any conversation beyond the quoted part.

Where it goes: it is kept on our side with your account so we can reply to
you; it also becomes an issue in our private code repository and a note in
our team chat; and it is read by our team and by Claude Code, the coding
assistant that investigates it and drafts a fix. **Settings › Privacy ›
What is sent?** has all of this in one place.

### Reporting without saying who you are

**Report without saying who I am**, under the problem reports switch in
Settings › Privacy, is off to start with. On, no account, device, email
address or plan is attached to a report; it is filed where no account can
be found for it, and our team still reads it and still fixes what it
describes. The log lines and Moe's description are scrubbed of your name,
email address and your Mac's name, but they may still mention things you
said or did. Your Mac still has to be signed in to send one, which is how
we keep strangers from flooding us, and it can send five a day that way; a
sixth is refused, and Moe tells you it can go tomorrow, or now with your
name. The cost is plain: we can't reply, you won't hear when it's fixed,
Moe can't show it to you again or add to it later, and deleting your
account doesn't delete it. You can also ask Moe, for one report, not to say
who you are.

### A report needs your yes, once

Nothing is sent to us until you turn on **Let Moe send problem reports** in
Settings › Privacy; it starts off. Until then, when you ask for a report,
Moe writes nothing and keeps nothing, not even a title, and tells you:
*Problem reports are off, so I haven't written or kept this report. To send
it to the team, open Settings › Privacy and turn on 'Let Moe send problem
reports', then ask me again and I'll write it then.* Turn it on and ask
again, and the report is written and sent. Turn the switch off again and
nothing more is sent; what was already sent stays with us.

### Some things we notice without you

If you are on a paid plan, a few things raise an alarm with us by
themselves: you paid and your cloud computer has no machine yet, after
about a quarter of an hour; your machine will not stay up; nothing has
synced between your devices for a whole day; or setting up your cloud
computer stopped on our side. Each of those opens a ticket in your name by
itself, and you get the same emails as any report, *We're on it* and
*Fixed*, one ticket however many times it is noticed. These need no switch:
a ticket like this carries only which step stopped and our own short word
for why, never your conversations, your memories or anything else of yours.
A problem that is ours alone, running low on machines, say, stays with us
and sends you nothing. None of this is a substitute for telling us: if
something looks wrong to you, say so, because most of what goes wrong is
not one of these.

## Updates, About and Licences

### Updating

Memoe updates itself, quietly. It checks once a day, sending a plain request
that says which version of Memoe is asking and nothing about you, and when
there is a new version it downloads it in the background. Once it has
downloaded, the notch glows amber, the same way it does when a reminder is
waiting, and the panel under the notch says *A new version of Memoe is
ready.* with **Restart to update**: press it and Moe closes, puts the new
version in place and opens again. **Later** puts the question and the glow
away for a day, or until Moe next opens. Moe never restarts on its own to
install an update, and it never asks in the middle of something: not while
a meeting is being recorded, not while it is listening or speaking, and
not while it is working on an answer. If you simply quit Moe or restart
your Mac, the update goes in then. No download on your part, no dragging,
and no Gatekeeper dialog again. A new version reaches everyone over a day
or so rather than all at once.

Updates are usually a megabyte or two rather than the whole download, since
the models and the thinking part rarely change between versions. Your
memories, meeting notes, connections and settings are untouched. The
thinking part is kept current the same way: when a new Memoe needs a newer
one, it is updated in the background and restarted once. When the new one
is a bigger change than an update can carry, Moe puts in place the copy
that came inside the new Memoe instead, keeping everything of yours.

### Settings › About & Licences

Which Memoe this is, what it is built on, and the way out. At the top,
**Memoe 0.3.x** with the **Beta** chip beside it, and one line on updates:
*Keeps itself up to date: a new version is downloaded quietly, and Moe asks
before restarting to install it.* A copy built from the source between two
releases has the last release's version number, so it adds one more line,
*Not the published release: built from commit …*, and a problem report
from it says *unreleased build* beside the version. Under that, what beta
means, and that telling Moe is what fixes a bug. Nothing technical is on it: no addresses, no keys, no
device ids.

**Built on open models and open source** credits everything that runs on
this Mac. **Models** and **Software** each name theirs on one line, and
**Show credits** opens the list: one row per component, its role and its
licence, and a **Their website** button that opens where its source is
published. The same list, with the full licence texts, is at
[memoe.app/licenses](https://memoe.app/licenses).

There is no uninstall button here. To take Memoe off your Mac, use *Erase
Memoe from this Mac* in Settings › Privacy.

### What Memoe is built on

Memoe did not build the hard parts, and says so. The models, all running on
your Mac:

| Model | Role | Licence |
|---|---|---|
| Parakeet TDT 0.6B v3 (NVIDIA; CoreML by FluidInference) | The main transcriber, English and two dozen European languages | CC-BY-4.0 |
| Parakeet Realtime EOU 120M (NVIDIA; CoreML by FluidInference) | Streaming and knowing when you have finished | NVIDIA Open Model License |
| Parakeet TDT-CTC 110M (NVIDIA; CoreML by FluidInference) | Vocabulary boosting | CC-BY-4.0 |
| Whisper large-v3-turbo (OpenAI; CoreML by Argmax) | Transcriber for other languages, downloaded on first use | MIT |
| Kokoro-82M (hexgrad; CoreML by FluidInference) | The default voice | Apache-2.0 |
| Inflect (the Inflect authors) | Text normalisation | Apache-2.0 |

The software:

| Component | Role | Licence |
|---|---|---|
| FluidAudio (FluidInference) | Speech recognition and synthesis framework | Apache-2.0 |
| WhisperKit (Argmax) | Whisper on CoreML | MIT |
| Hermes Agent (Nous Research) | The thinking part: model routing, memory, tools. Runs as a separate process that Moe launches | MIT |
| NeMo Text Processing (NVIDIA), text-processing-rs, rustfst, flate2 | Text normalisation, statically linked via FluidAudio | Apache-2.0 / MIT |
| VBx (BUT Speech@FIT) | Speaker clustering | Apache-2.0 |
| fastcluster | Hierarchical clustering | BSD-3-Clause |
| Sparkle | Software updates | MIT |
| signal-cli, libsignal, Eclipse Temurin JRE | Downloaded only if you connect Signal; run as a separate program, nothing linked in | GPL-3.0-or-later, AGPL-3.0-only, GPL-2.0 with Classpath Exception |

For the Signal components, the licences page carries a written offer of the
corresponding source, and links to the exact versions used. Kokoro-82M's
training data includes material from Koniwa (CC BY 3.0) and SIWIS (CC BY
4.0).

### Who Memoe comes from

Memoe is made by **Yisrael Gottlieb**, working as a sole proprietor in New
Jersey, United States. That is the name the [Terms of
Service](https://memoe.app/terms) name as the other party to the
agreement, and New Jersey law governs them. hello@moebot.app reaches us.

### The playground on memoe.app

Before you download anything,
[memoe.app/playground](https://memoe.app/playground) is a Mac in your
browser with Moe on it and one day of one person's life loaded in: Lena's
Friday from the home page. Talk to it (hold the space bar, or the button on
a phone) or type. It has her mail, messages, calendar, notes, reminders,
files and the memory Moe has built about her, and every app on the dock
opens and works. Four switches, *Mail*, *Messages*, *Calendar*, *Memory*,
let you take a source away and ask again; the answers get worse, on
purpose. Ask it to send something and the same sheet the app shows appears
first. Open FaceTime and a call starts; the card offers to record it, the
consent sheet asks, the red ring comes on, and when the call ends the notes
are in the Meetings tab, as in the app.

It is a demonstration, not the app: what you say goes to our server and on
to the AI provider that answers it, its voice is made in the cloud, and
each visitor gets a day's worth of that voice and a quarter of an hour of
listening before the browser's own carries on. A moment's hiccup (a busy
minute, a dropped connection) is waited out rather than handed to the
browser, so an answer is never half in one voice and half in another. No transcripts are kept; the
conversation lives in the page until you close the tab. The privacy page
says exactly what leaves your browser.

## Change log
- **unreleased (2026-11-14)** — **Moe knows five more settings**: the
  ten-minute look at what's connected (it can turn that off for you; on asks
  first), the daily read-back and keeping what it learns as memory, which
  browser profile Moe's browser signs in as, and the meeting capture area
  (yours to change; Moe opens the row).
- **unreleased (2026-11-14)** — **Moe changes its own settings.** Say what
  bothers you and Moe finds the setting, offers to change it, or opens
  Settings on the row for the ones that are yours to flip (microphone,
  screen, money, the AI, language, sending). "Connect my Notion" gets a
  sign-in link.
- **unreleased (2026-11-14)** — **Docs brought up to date.** Plan limits
  for connected services now read Away 100 / 200 and Away+ 200 / 500, and
  voice notes 12 hours on Away+; Away+ is described as 400 hours and larger
  allowances, without promising a machine that never rests; the cloud
  computer's 2 GB and the monthly hours email are listed; the browser on
  Away keeps a sign-in only for sites on the Cloud browser list; Telegram's
  setup sheet has the Approve button; group chats, LINE and Email Moe in
  Chat; Moe's quiet about its own restarts in your chats; the hover switch
  and the pickers in front of the popped-out chat; and vendor model names
  and settings paths taken out of the pages.
- **unreleased (2026-11-14)** — New switch, Voice › More › **Hovering the
  notch opens it** (on by default): off, a hover opens nothing and only a
  click does.
- **unreleased (2026-11-14)** — With the chat popped out, hovering the notch
  brings the chat window forward; before, it did nothing and the notch looked
  broken.
- **unreleased (2026-11-14)** — **+** in the popped-out chat opens the file
  and photo pickers in front of the chat, on the desktop you are on, full
  screen included; before, they could open hidden behind it.
- **unreleased (2026-11-13)** — Moe's engine moves to Hermes v0.23.1. The
  browser Moe drives is the same Chrome for Testing with the same sign-ins,
  now driven directly instead of through a separate helper; nothing to set
  up again.
- **unreleased (2026-11-13)** — A group chat Moe is in through Telegram,
  Slack, Discord, LINE or WhatsApp is no longer treated as you talking to
  Moe privately, so its messages stay out of your history; a LINE group
  message no longer lands in the sender's own chat.
- **unreleased (2026-11-13)** — LINE and email to Moe's own address are kept
  in your history on both your Mac and Away, like Telegram. Away also keeps
  the switch that stops "I'm back" messages in your chats after a restart.
- **unreleased (2026-11-13)** — The body handed a chat message now holds
  the presence lease at once, so the Mac and Away never both act as the
  awake one in the minutes after a lid closes (edge only).
- **unreleased (2026-11-13)** — **Chats on your phone are in your history.**
  A message the Mac answered on Telegram, WhatsApp or another chat app now
  becomes a conversation on the Chat page and travels to Away like the rest;
  before, only the cloud computer's own chat answers were kept.
- **unreleased (2026-11-13)** — **Only Moe's words reach your chats.** Away
  sent "Hermes is shutting down…" to Telegram every time it went to rest,
  and asked about pruning history over a disk that was nearly empty. Both
  are gone; the few notices left say what happened in plain words. Moe's
  own replies keep file paths, command names and error codes out unless you
  ask for them. A Telegram chat left pointing at a retired Away computer now
  follows you to the new one instead of being treated as a stranger.
- **unreleased (2026-11-13)** — **Telegram setup finishes.** After the bot
  was made, a hello from your phone waited behind a spinning *Finish in
  Telegram…* until the sheet timed out, with no way to let it in but a
  command. It now appears in the sheet with an **Approve** button, as the
  setup always promised, and the waiting line names no command.
- **unreleased (2026-11-13)** — **The microphone survives a call.** When
  a browser call took the microphone, Moe could lose it for good (macOS
  27.2: the audio engine's input stuck at 2 ch / 44.1 kHz over a 1 ch /
  48 kHz microphone) until it was quit. It now starts on a new audio engine
  instead of retrying the broken one. A microphone that is not working
  shows as *Microphone not working* in the window's footer and one status
  line, no longer as error bubbles in the conversation.
- **unreleased (2026-11-13)** — **Edit a message you sent.** The pencil
  under your message, or Edit message on right-click, puts it back in the
  box; sending cuts the conversation there on every device and Moe answers
  the new version with only what came before.
- **unreleased (2026-11-13)** — **Don't remember this chat.** The eye
  beside a conversation's name stops Moe saving anything from it to memory,
  on this Mac and on the cloud computer: no learning from it, no memory
  writes, no look back over it afterwards. Per conversation; a new one is
  remembered.
- **unreleased (2026-11-13)** — **Tags.** After three exchanges a
  conversation gets up to three tags from one call to the cheapest model of
  your provider; a row of tags under Search filters the rail. Never for a
  conversation marked Don't remember.
- **unreleased (2026-11-13)** — **Scheduled browser jobs run on Moe Away
  too.** A job that uses a website now runs in the cloud computer's own
  browser while the Mac is shut. Only a job that needs your Mac's own,
  signed-in browser stays on the Mac.
- **unreleased (2026-11-13)** — **Skills sync with Moe Away.** Every skill on
  the Mac is on the cloud computer too, and one written or improved there
  comes back; the newer change wins, and a deletion travels with the copy
  kept aside. Before, only the list of switched-off skills travelled.
- **unreleased (2026-11-13)** — **A signed-in browser on your cloud
  computer.** Jobs that need a website run in a browser on the cloud computer
  while the Mac is shut. You sign in yourself through a one-time link; only
  the sites listed in Settings › Away › Cloud browser stay signed in. It asks
  on your chat app before paying, sending or deleting, never gets past an
  "are you human?" check itself, and gives way first when memory is short.
- **unreleased (2026-11-13)** — **A model per chat.** The bar at the top of
  Chat has a menu of the models your own AI service offers; the choice holds
  for that chat only.
- **unreleased (2026-11-13)** — **Send · Edit · Copy, Yes and Retry.**
  Buttons under the newest answer: for a draft, an offer, or an answer
  that failed, in Chat and on the panel. Sending still asks you first.
- **unreleased (2026-11-13)** — **Thinking folds into the steps.** When the
  provider streams the model's thinking, it is kept with the answer under
  the steps, folded, in Chat and on the panel; it is never spoken.
- **unreleased (2026-11-13)** — **⌘J hands the conversation to the window.**
  From the panel or the popped-out chat, ⌘J opens Chat on the same
  conversation with your half-typed words and files in its box. The round
  buttons at the top of the panel are easier to hit.
- **unreleased (2026-11-13)** — **Search, pin, rename and archive
  conversations.** A search field tops the Chat rail; right-click a
  conversation to pin it, rename it in place, archive it or delete it.
- **unreleased (2026-11-13)** — **⌘V attaches, and Chat reads well to
  VoiceOver.** A copied picture or file pasted into the box is added to the
  message on every surface; each message is one VoiceOver stop with Copy and
  Read aloud as actions, and a finished answer is announced. Section labels
  in Chat are larger, without letter-spacing, and the small buttons by
  Moe's name are easier to hit.
- **unreleased (2026-11-13)** — **Hebrew and Arabic read right to left.**
  Each paragraph of a message, yours or Moe's, takes its own direction in
  Chat, on the panel and in the popped-out chat, settled from its first
  words so it never flips mid-answer; code stays left to right.
- **unreleased (2026-11-13)** — **Each Moe searches the other's chats.**
  What you said on Telegram can be found from the Mac, and what you said at
  the notch can be found from your phone. A Telegram chat quiet for six
  hours starts a new conversation.
- **unreleased (2026-11-13)** — **Each scheduled run happens once.** Both
  sides check before a job runs, so one your cloud computer already did is
  not done again by the Mac when it opens; a Mac with no internet runs it
  anyway rather than miss it.
- **unreleased (2026-11-13)** — **Every scheduled job is on both sides.**
  Your cloud computer lists every job you have on the Mac, with what each
  last said wherever it ran. A job is kept to the Mac only when what it
  needs is checked to be on the Mac and not on the cloud computer; the
  cloud lists it as running on your Mac only and never runs it.
- **unreleased (2026-11-13)** — **New plan limits, packs and warnings.**
  Away: 150 cloud computer hours, 300,000 characters and 6 hours of cloud
  voice and hearing, 100/200 service calls an hour/day. Away+: 400 hours and
  always ready, 1,000,000 characters and 12 hours, 200/500 calls. Two $5
  packs on both plans (100 hours; 150,000 characters + 2 hours). Settings ›
  Away shows **This month**; one card at 80% with a buy button; one email
  when the hours run out, after which scheduled work waits for the Mac. The
  cloud computer now uses an Away+ person's own service-call allowance. The
  site says "answers in a minute or two" instead of "the moment".
- **unreleased (2026-11-13)** — **Answers are laid out.** Lists, tables,
  paragraphs, and code with its language and **Copy**, in Chat, on the
  panel under the notch and in the popped-out chat, drawn by one renderer.
- **unreleased (2026-11-13)** — **Stop is the send button.** On the panel
  under the notch and in the popped-out chat, the send arrow becomes **■**
  while Moe works, the **⋯** sits beside it instead of on a row of its own,
  and a finished answer folds what Moe did to one line, *3 steps · 48 s ·
  1 source*, that opens into the steps and the pages read. A held message
  has an **×**.
- **unreleased (2026-11-13)** — **Chat shows Moe working.** The Chat page
  says what Moe is doing with a clock and **Stop**, the send arrow becomes
  **■** while it works, a message typed meanwhile waits in view with **Send
  now**, **Edit** and **×**, the steps chip says how long the job took, and
  times follow the Mac's 12- or 24-hour setting.
- **unreleased (2026-11-13)** — **The chat pops out of the notch.** A
  pop-out button in the panel's header, **Pop Out Chat** in the menus, or
  **⌃⌥P** moves the conversation into a window you can drag anywhere,
  resize, keep on top of every app, desktop and full-screen app, and put
  back in the notch. It is the same conversation and the same box to type
  in; while it is out, the notch opens no panel of its own. See *Popping
  the chat out of the notch*.
- **unreleased (2026-11-12)** — **Moe asks before browsing signed out.**
  When Moe can't open its browser with your logins, it tells you why and
  asks whether to continue signed out. A card on your Mac asks *Continue
  signed out?* before anything runs, and one yes covers that conversation.
  What Moe does signed out it says was not done as you. A scheduled job
  that meets this while you are away reports what is waiting and stops. See
  *It is signed in as you*.
- **unreleased (2026-11-12)** — **Moe starts answering sooner when you
  speak.** A question asked out loud now opens at the lowest thinking level
  your account has; on a Claude plan that covers the opening only, and the
  level you chose is back once Moe has said its first words or started
  looking something up. Typed questions are unchanged. See *Settings ›
  Brain*, *How hard it thinks*.
- **unreleased (2026-11-12)** — **A failed connection says so plainly when
  the problem is a secure connection.** If Moe could not make a secure
  connection while you connected a service or pressed **Add another**, the
  sheet showed a raw line about a certificate, or an unrelated line from
  earlier, with advice to copy the key again. It now says *Moe couldn't make
  a secure connection to finish setting this up* and suggests reopening
  Memoe, checking the Mac's date and time, and pausing any VPN or web filter.
- **unreleased (2026-11-12)** — **Moe in your Chrome installs from the Chrome
  Web Store.** **Add to Chrome** now opens the extension's store page — one
  click, kept up to date by Chrome — instead of Developer mode and Load
  unpacked. Memoe recognises the store copy, and on its next launch mends the
  link an earlier version gave Chrome, which only let the old copy in. The
  row now says which way it is stuck (not installed; installed, not
  connected; in another Chrome profile; installed, can't reach Memoe) with
  **Repair** where Memoe can fix it, the extension's own button shows a red
  **!** with the reason when it cannot reach Memoe, and Moe can say why too.
- **unreleased (2026-11-12)** — **Settings › Away no longer sits on
  "Checking…" for minutes.** On a Mac whose history had an old hiccup in it,
  Moe was re-sending its entire history to the cloud on every sync — over a
  hundred megabytes every five minutes — and the Away screen waited behind
  each one. Moe now sends only what the cloud does not have, so a sync with
  nothing new takes about a second again.
- **unreleased (2026-11-12)** — **Getting ready for a smaller download;
  nothing changes for you yet.** The next version of Memoe is the same size
  to download and does everything the same way, online or off. The one
  thing it does differently is out of sight: the first time it opens, it
  keeps its own copy of two optional models beside the others on your Mac
  (in `~/Library/Application Support/FluidAudio/Models`) instead of reading
  them from inside the app. They are the model that corrects your own names
  and terms, and the one that tells meeting speakers apart. It normally
  takes no extra disk space, and never more than about 115 MB. It is there
  so that a later, smaller Memoe can leave those two out of the download
  without your Mac having to fetch them again. If the copy cannot be made
  (a full disk, say), Memoe carries on using the ones inside the app.
- **unreleased (2026-11-12)** — **Connections fits its window, and one
  account can be removed.** With several accounts on one service, the
  Connections detail pane was taller than the window and nothing scrolled:
  the top of the page and the buttons at the bottom were cut off, and so
  was the end of the list beside it. The page now scrolls inside the pane,
  the buttons stay at its foot at every window size, and they stack in a
  narrow window. The Chrome row and the row for what Moe thinks with are
  built the same way and are fixed with it. Each account's row has
  **Remove** beside **Rename**: Moe asks first, naming the account, and
  removes only that one. After a removal that fails, the sheet no longer
  gives advice written for a failed sign-in.
- **unreleased (2026-11-12)** — **Add another, and Disconnect, work again on
  a Mac with its own Python.** If you had installed Python from python.org,
  pressing **Add another** on Gmail (or connecting or disconnecting any
  service) could fail with *could not start the sign-in* and a line about a
  certificate. Moe was starting its connection helpers with whichever Python
  it found first on the Mac, and that one could not check a website's
  certificate. Moe now uses the Python that ships inside it for all of them,
  and for the helpers its thinking part starts.
- **unreleased (2026-11-12)** — **Setting up Away no longer gets stuck
  saying two things at once, and a stopped setup finishes by itself.** The
  setup page could say *We've stopped* over a spinner, with later steps
  ticked beneath the one that failed, and then stay that way: it told you
  there was nothing to do while waiting for you to press **Try again**. Now
  a stopped setup keeps checking and carries on the moment your cloud
  computer is there; the list never shows a spinner or a later tick once it
  has stopped; and starting again notices a cloud computer that is already
  set up. The wait itself is fairer too: it used to give up two minutes
  after you pressed the button, however slowly our side was answering, and
  report a missing machine — with a "We're on it" email and a "Fixed" one
  two minutes later. It now waits up to fifteen minutes while our side says
  the machine is on its way, counts from our first answer rather than your
  press, and does not report anything when it simply could not reach us.
- **unreleased (2026-11-12)** — **A request for your OK is kept out of your
  email again.** Moe never emails its own working notes or a request for
  your OK: a request waits for an answer email can't give, and the Email row
  says Moe needed one. After Moe's engine reworded those notes, the email
  side no longer recognised the new wording, so a request for your OK — with
  the command, or the message Moe was about to send, written out in it —
  could arrive as if it were Moe's answer, and so could a note that Moe was
  stuck. Both are recognised again in either wording. When a reply fails, the
  email still says so in one plain sentence instead of repeating the engine's
  own instructions.
- **unreleased (2026-11-12)** — **How long a reply can go without a service
  you just connected, restated.** When you connect a service while your cloud
  computer is awake, it reconnects its services in place, and a message that
  arrives in those moments can be answered without them. This page once put
  that at up to about 259 seconds. With the Hermes Moe runs on now the longest
  it can last is about 629 seconds, usually a few: Hermes waits up to 310
  seconds for another process to finish connecting (it was 120) and allows up
  to 300 seconds to connect a long list of services (it was 120). The same
  entry used to warn that a conversation could lose what was said earlier in
  it when this went wrong; that was fixed in Hermes on 2026-09-15 and the
  warning is gone.
- **unreleased (2026-11-12)** — **A long conversation stays quick for
  longer.** Moe used to re-send the whole of "what is going on right now"
  (your calendar, tasks and recent messages) every ten minutes of a
  conversation, and all of it stayed in the conversation to be re-read with
  every question after. It now sends only the lines that are new or gone.
  And when the part of Moe that thinks has to restart under a question,
  which is a wait of about six seconds, Moe's log now says why.
- **unreleased (2026-11-12)** — **Two more yeses that answer only to you.**
  Signing in to your Memoe account with Google is agreeing to the Terms and
  Privacy Policy, so the buttons that do it are now among the controls only
  a person can press: your own click opens Google at once, and a press Moe
  or another app makes opens nothing until you confirm it's you. And a
  problem-reports yes that Moe passes on to a new account by itself must now
  carry a signed note that you pressed the switch; a setting that merely
  says "on" is no longer taken as your word, and Settings › Privacy asks you
  to **Confirm it's you** instead. See *Only you can agree*.
- **unreleased (2026-11-12)** — **The website counts a Download tap that
  could not be a download.** On a phone, a tablet or a PC the Download
  button shows *Memoe runs on a Mac* instead. That tap is now counted as
  its own line, saying only which button it was, the same as a Download
  click; nothing about your device is added to it.
- **unreleased (2026-11-12)** — **Upgrade to Away+ opens on the right
  step.** The button now opens Stripe's page already on *change your plan*,
  instead of the billing page where you had to find it. If Stripe will not
  open that step, you get the billing page as before.
- **unreleased (2026-11-12)** — **Three things that had slipped.** A
  reminder made before any brain is chosen is refused again, with nothing
  left on the clock, rather than quietly kept. Away's check for a way to
  reach Moe says it couldn't check when the list of chat apps could not be
  read, instead of saying nothing is connected. And on a Mac where Moe's
  ranking of services is missing, Connections still leads each service with
  the sign-in that also works on your cloud computer.
- **unreleased (2026-11-12)** — **The Privacy Policy and the Terms are now
  version 2026-11-12.1, and you are asked to agree once.** The policy now
  says that Moe can use where your Mac is when a question needs it and you
  have allowed it, names the first-open, welcome-finished and first-answer
  counts and the crash count you can turn on, and says that the website
  counts which Download button was pressed, a Download pressed on something
  that is not a Mac, and what kind of program asked for the download. That
  is a change that matters, so if you agreed to an earlier version: on a
  paid plan, *Our Terms and Privacy Policy have changed* appears the next
  time Moe opens; on the free plan, you agree the next time you sign in,
  start Away or turn on problem reports. Nothing stops while it waits. See
  *Terms and Privacy Policy: when you agree, and to what*.
- **unreleased (2026-11-12)** — **Upgrade to Away+ goes somewhere.** On
  Away, the button used to start a second purchase, which Moe refuses, so
  it could only fail. It now opens your billing page at Stripe, where you
  switch plans. If the page shows no way to switch, tell Moe and we will do
  it for you.
- **2026-11-12** — **The premium voice allowance is counted by us, not
  only reported by your Mac.** Each connection to the premium voice now
  counts as at least 100 characters, taken out of what Moe goes on to say,
  so normal use comes to the same number as before. A Mac that asks for
  connections far faster than Moe ever does is asked to wait a few minutes
  and uses the voice on your Mac meanwhile. Nothing changes for premium
  hearing.
- **2026-11-12** — **A plan that ended stays ended, and one you pay for
  is not lost.** Our payment provider's notices can reach us late or out of
  order. A late one could put a cancelled plan back, or end a plan you had
  just started again. Notices are now put in the order they happened, and
  once a day we can check every plan against the payment provider's own
  list, so what you have in Memoe is what you are paying for.
- **unreleased (2026-11-12)** — **Moe knows which town you are in.** "What's
  the weather" used to be answered for wherever your internet connection
  appeared to be, which could be a town or two away. Now Moe uses your Mac's
  own location. macOS asks your permission the first time a question needs
  it; say no and Moe asks you, or says it is going by your connection. See
  *Knowing where you are*.
- **unreleased (2026-11-12)** — **A device that left your account no longer
  stops syncing.** If your cloud computer was taken down or rebuilt, this
  Mac kept trying to send to the old one, was refused every time, and
  showed "couldn't reach your other devices… it will try again" for as long
  as it ran; setting Away up again was refused for the same reason. Now the
  Mac notices, stops sending to the device that is gone, carries on with
  the rest, and tells you once in Settings › Privacy what to do.
- **unreleased (2026-11-12)** — **Confirm it's you answers only to you.**
  The button under *Let Moe send problem reports* is now one of the
  controls only a person can press, like the switch above it. And your own
  click on that button, on the switch in the welcome, or on the switch in
  Settings is enough when this Mac's key for agreeing is new: you are no
  longer asked for Touch ID as well.
- **unreleased (2026-11-12)** — **Four small counts after the download.**
  Until now we could see how many people clicked Download and nothing after
  it. A newly installed Memoe now sends one anonymous count the first time
  it is opened, one when the welcome is finished, and one the first time
  Moe answers you — each once per Mac, with the app's version and nothing
  else. A Mac that was already set up sends none of them. A new switch in
  Settings › Privacy, **Tell us when Memoe crashes**, is off; turned on, a
  Memoe that did not quit properly sends one count the next time it opens,
  with no crash report and no logs. The website also counts each request
  for the download by what kind of program asked (a Mac browser, another
  browser, a script), without keeping an address. *Privacy* and the privacy
  policy list all of it.
- **unreleased (2026-11-12)** — **Every inbox card has something to tap.**
  Moe used to make a card out of anything it had to say, including notes
  about itself and news with nothing to do about it. Now a card needs a
  one-tap action, or to be something you asked for, or to be urgent.
  Everything else stays quiet and is kept under *Done this week* on the
  Inbox page, marked *Kept quiet*.
- **unreleased (2026-11-12)** — **Write the notes, later.** A meeting whose
  notes failed, or that was stopped early, now has a **Write the notes**
  button on the Meetings page, which writes them from the saved transcript,
  with **Try again** if it does not work.
- **unreleased (2026-11-12)** — **Quitting waits for your notes to reach
  Telegram.** "Stop and Write Notes" used to quit the moment the notes were
  written, which could cut off the copy being sent to your Telegram. Memoe
  now waits for the send, up to twenty seconds, and a small window says
  what it is waiting for.
- **unreleased (2026-11-12)** — **Lighter when idle, and reminders arrive
  sooner.** Memoe used to look for new reminders every five seconds and for
  two other things every few seconds, all day. It is now told the moment
  one arrives, so a reminder shows up within a second and an idle Mac is
  left alone.
- **unreleased (2026-11-12)** — **VoiceOver and Reduce Motion in the Memoe
  window.** Inbox cards, the Meetings page, Memory and Settings name their
  icon-only buttons, each inbox card is one stop with its buttons as
  actions, ↑ and ↓ walk the Inbox list, and things stop sliding when Reduce
  Motion is on.
- **unreleased (2026-11-12)** — **Nothing beside the floating camera
  capsule at rest.** With something unread in the inbox, the island kept a
  run of black and a white dot to the right of the camera all the time, and
  a much longer one whenever a microphone was open. It now shows nothing at
  rest; what is waiting is in the card on hover, and the capsule still
  widens when something arrives, while you speak, and while Moe thinks or
  answers. The open follow-up moment after a reply is rest too: the bars
  come back when you start speaking.
- **unreleased (2026-11-12)** — **No empty band in the island's card while
  Moe thinks.** On a MacBook with a floating camera capsule, opening the
  card before anything had been said showed an empty strip with a lone ⋯ at
  its right. The ⋯ now sits beside the camera with the other buttons, the
  card is just that band and the field, and the controls take a row only
  while you have them out.
- **unreleased (2026-11-12)** — **The first line of a short conversation is
  no longer cut off.** In the island's panel the top of the first row was
  shaved away, and faded as if more were above it, even when the whole
  conversation fitted. On every Mac.
- **unreleased (2026-11-12)** — **The island steps round the system's
  microphone indicator.** On a MacBook with a floating camera capsule, macOS
  draws its own orange dot and pill beside the camera while a microphone is
  in use, over everything. Moe's *Thinking* was drawn underneath it, with
  only the last letter showing. Moe now keeps its ring and its word either
  side of that pill, and the open card no longer says *Thinking* twice.
- **unreleased (2026-11-12)** — **The island fits the floating camera capsule.** On a
  MacBook whose camera is a capsule floating in the menu bar, Moe used to
  draw a black tab over it, twice as wide and running up to the top of the
  screen. Now Moe is the capsule itself: it grows sideways when there is
  something to show and opens into a rounded card below the top edge. Macs
  with a notch, and Macs with neither, look exactly as before. The island's
  buttons are named for VoiceOver, and Reduce Motion is honoured.
- **unreleased (2026-11-12)** — **A thinking part that has stopped answering
  is noticed and replaced.** It could be running and answer nothing, and
  every question then ended in *Moe is taking too long to answer* until you
  quit Memoe. Now a question that gets no answer makes Moe check; two
  checks unanswered and it is replaced in a few seconds. One that is only
  slow is left alone.
- **unreleased (2026-11-12)** — **Each background job says when it last
  ran.** Settings › Running in the background › More shows *Last ran 2 h
  ago*, *Has not worked since Tuesday* or *Has not run since Tuesday* on
  each of Moe's own jobs. A job that had quietly stopped used to show
  nothing at all. Never an inbox card.
- **unreleased (2026-11-12)** — **Moe brings back the right memory.** A line
  that did not fit the page Moe reads every time is found by the rare words
  in your question, not by *the*, *you* and *what*, and no longer by words
  from Moe's own instructions.
- **unreleased (2026-11-12)** — **Looking up a tool no longer uses up your
  requests.** Only what Moe does with a connected service counts toward the
  hourly and daily ceiling, so the same ceiling goes two to three times as
  far. If you do reach it, you are told once, in one line, when it lifts.
- **unreleased (2026-11-12)** — **Long conversations keep Moe's manners.**
  The full reminder of how to answer is repeated every twenty messages, so
  it cannot be lost when a long conversation is condensed.
- **2026-11-12** — **One plan at a time.** Starting a plan when you already
  have one used to open a second subscription beside the first. Now Moe
  says you already have a plan and points you to **Manage plan**, where
  switching between Away and Away+ is done; nothing is charged.
- **2026-11-12** — **The coming-back counts are sent reliably.** The two
  one-word counts described under *Privacy* were marked as sent before they
  had arrived, so a Mac that was offline at that moment never sent its own.
  Each is now marked only once our server has it. What they contain is
  unchanged: the name of the count and nothing else.
- **2026-11-12** — **Moe cannot rewrite the check that asks
  before it sends.** The check refused any attempt to change its own files,
  but only when they were named by Memoe's old folder name. Named by the
  folder's real place on your Mac, a few of them could have been rewritten
  with no question asked. Now it goes by which file it is, not what it was
  called. Nothing you do day to day asks more often because of it.
- **unreleased (2026-11-12)** — **A key or a model on this Mac no longer
  ends the welcome, and Memoe offers to move itself to Applications.** On
  *Give me something to think with*, **Use a key** and **Set this up** used
  to close the welcome for good; now Settings › Brain opens beside it, the
  welcome waits, checks the brain answers, and carries on at *Say hello*.
  A new line, **No AI plan? Start free**, says what is honestly free: a
  Google Gemini key up to Google's daily allowance, or a model on this Mac.
  *Say hello* no longer says Accessibility lets Moe "click for you"; it
  names the helper, CuaDriver, that does and that macOS will ask about.
  Opened from its disk image, Memoe offers **Move to Applications** and
  asks before replacing a copy already there. Settings › Permissions no
  longer offers **Quit and reopen** for Accessibility, which works the
  moment it is switched on. A language that will not load says so in a
  plain sentence.
- **unreleased (2026-11-12)** — **The welcome holds your place, and Say
  hello only asks for what works.** Closing the welcome part-way no longer
  ends it for good: it comes back on the screen you left, and **Show Welcome
  Again** in the Moe menu brings it up any time. Signing in with ChatGPT now
  shows the same tick and moves on the same way as signing in with Claude. A
  sign-in download that fails says so and offers **Try again**. *Say hello*
  leads with the button and ⌃⌥Space until Accessibility is on, waits for the
  grant instead of asking you to quit and reopen, shows *Getting my ears
  on…* while Moe warms up, and moves on after the answer has played. Ask a
  question with no AI connected and Moe says so out loud and opens the place
  to connect one. Set-up and sign-in failures are a plain sentence and what
  to do. The About box names the AI you chose.
- **2026-11-12** — **Agreeing takes two clicks, not four and four Touch
  IDs.** Turning the cloud copy back on used to ask you to confirm it's you
  at every step, including for your own clicks, and then left you to press
  the button again. Your own click is recognised now, one press on **Agree**
  covers what follows from it, and the copy comes back on by itself. See
  **Only you can agree**.
- **2026-11-12** — **Quitting during a meeting asks first.** ⌘Q an hour into
  a recorded call used to quit at once and leave the meeting without notes.
  Memoe now asks: stop and write the notes, quit anyway, or cancel.
- **2026-11-12** — **Long conversations stay quicker.** Every message used
  to carry the same page of speaking rules to your AI, and the copies piled
  up. They are sent once per conversation now, with a two-line reminder
  after. Nothing about how Moe answers is meant to change.
- **2026-11-12** — **Lighter at rest.** The island no longer checks four
  times a second whether a conversation is on, and a damaged file in the
  inbox is read once instead of every five seconds.
- **2026-11-12** — **Memoe by name where macOS says Memoe.** Messages that
  send you to System Settings to allow Calendar, Reminders, Contacts or
  Notes now name the app as it is listed there.
- **2026-11-12** — **Agree works again when this Mac's key for agreeing
  has stopped working.** Pressing Agree could fail every time, with a
  message about not reaching your other devices that was not true. Moe now
  replaces the key in the same press, after one Google sign-in, and when it
  cannot it says what happened and what to do.
- **2026-11-12** — **A build that is not a release says so.** A copy of
  Memoe built from the source between two releases showed the same version
  as the published one, so a problem report could not tell them apart.
  Settings › About now adds *Not the published release: built from commit
  …* on such a copy, and its reports say *unreleased build*. Nothing
  changes on a downloaded Memoe.
- **2026-11-12** — **Settings › Brain speaks plainly when a change fails.**
  A change that could not be saved used to show a line of technical output
  from Moe's insides. It now says what happened, that nothing was changed,
  and what to try; the detail goes to Moe's log.
- **2026-11-12** — **No more "install developer tools?" from Moe.** On a
  Mac without Apple's developer tools, opening Memory, Usage, Activity, Chat
  search and a few other pages could put up a system dialog asking to
  install them, and then show an empty page: *Nothing about you yet*, over
  a full memory. Moe now runs all of that with the Python that ships inside
  it, and a page that could not read says it couldn't look rather than that
  there is nothing.
- **2026-11-12** — **A turn that ends with nothing is said, not hidden.**
  When the thinking part ended a turn without a word, the panel just went
  quiet, as though Moe had answered. Moe now says *No answer came back. Ask
  me again.*, spoken when you asked out loud.
- **2026-11-12** — **Moe comes back when its thinking part does.** If the
  part of Moe that thinks would not start, Moe said it would keep trying, and
  it did, but every question after that was still answered *Moe isn't
  connected* until you quit and reopened the app. Now Moe is back as soon as
  that part is, the window says so, and asking a question while it is down
  makes Moe try again at once.
- **2026-11-08** — **A conversation left alone for an hour starts fresh.**
  One thread could run for days, and every answer re-read all of it: the
  first word took 12 seconds by the end of a week. Now an hour untouched
  puts it away in Chat, and the next question starts a new one.
- **2026-11-08** — **A new conversation starts faster.** Moe used to spend
  about a second and a half reading its memory before the first answer of
  every new conversation, and a little more before every answer after.
  That is now about half a second, and nothing per answer. What Moe
  remembers is unchanged.
- **2026-10-30** — **The way out of the inbox, and room for a long
  answer.** The inbox has a **‹ Chat** button at its top that is always
  there; before, the only way back was the tray icon, which was hidden
  whenever Moe was working. Closing the panel leaves the inbox. Clicked open,
  the panel is taller than on hover, and a long answer is shown from its
  start, with a scroll bar.
- **2026-10-20** — **Homebrew and GitHub Releases.** `brew install --cask
  izzy-gottz/moe/memoe` installs Memoe (the old `moe` cask still works and
  moves across), and every version is on the open-source repository's
  Releases page.
- **2026-10-20** — ***Privacy* names everything that reaches us.** It used
  to open with "on the free plan nothing about you reaches us", which left
  out three things the app does on its own: the daily update check and the
  two one-word coming-back counts. It now names all three, says there is no
  switch for them, and says a build from the open-source code sends neither
  count.
- **2026-10-20** — **The Mac app is open source.** Its code is public at
  [github.com/memoe-app/memoe](https://github.com/memoe-app/memoe) under the
  Apache-2.0 licence; Away, the cloud half, is not part of it. *Memoe, in
  short* says so, and memoe.app links to it.
- **unreleased (2026-10-19)** — **Composio goes through Memoe's server.**
  Your Mac no longer holds the key to Memoe's Composio account; requests to
  Gmail, Calendar and the other Composio services pass through Memoe's
  server, which holds it and checks each request against your plan (asking
  is free, schedules are paid, and every plan has hourly and daily limits).
  *Privacy* and *Google, and about 1,400 other services* say so.
- **unreleased (2026-10-19)** — **The privacy lines say where your words
  go.** *Privacy* used to open with "on the free plan nothing about you
  leaves your Mac", which was never quite true: what you say to Moe, and
  what it reads to answer you, goes to the AI provider you chose to think
  with. It now says that, and that nothing reaches us on the free plan. The
  same correction is made under *Premium hearing and voice*.
- **unreleased (2026-10-15)** — **Double-tapping the talk key always means
  stop.** It used to start hands-free listening whenever the notch showed
  Moe listening, including right after a mistaken "Hey Moe", so a double-tap
  meant to stop could send whatever was said next. Now it listens hands-free
  only when Moe is completely at rest, and stops everything otherwise. A stop
  makes a short low sound and the notch says **Stopped** for a moment; a tap
  straight after a hands-free double-tap cancels it instead of sending; a
  single tap pauses or leaves an answer alone and never throws it away; the
  first tap of a double-tap no longer flashes the microphone on; a stop
  during a meeting leaves the meeting's notch alone; and Esc stops Moe while
  its panel or chat window is in front.
- **unreleased (2026-10-15)** — **The notch stops glowing.** No more coloured
  light around the notch. It grows small black ears either side instead: a
  dim dot on the right says Moe is there, white bars on the left move with
  your voice, and a new notice slides out on the right for a few seconds and
  then leaves a bright dot. The white light that runs round the notch while
  Moe works stays, drawn sharp. Muted, a held reply and using your Mac are
  words beside the notch (*Muted*, *Paused*, *Using Safari · Stop*) instead
  of red, white and magenta, and **Stop** there ends computer use. A recorded
  meeting keeps one small red dot beside **Recording**. The open panel loses
  the coloured light behind it, and its status dot is white. Macs without a
  notch get the same, around their stand-in tab.
- **unreleased (2026-10-15)** — **Moe hears you more reliably on a slow
  connection, and PocketTTS no longer stumbles after a pause.** Premium
  hearing no longer decides you said nothing because the network was slow
  — the sentence used to come back garbled and split in two; it waits for
  what you said to be read, and when your Mac heard a voice it never takes
  the cloud's silence as the answer. A fresh token is kept ready while *Hey
  Moe* is listening, a premium answer that is not coming is given up on in
  2.5 seconds rather than 4, and a reading interrupted by a double-tap no
  longer holds up the next one. PocketTTS warms itself up again while you
  talk after a minute of quiet, and holds half a second of speech before
  the first word so it does not run dry mid-word. Moe's log no longer
  records the connection address, which carried a token and a line of
  Moe's reply. See **Moe's own voice** and **Premium voice and hearing, on
  paid plans**.
- **unreleased (2026-10-15)** — **Moe is lighter, and says when it could not
  read.** A source that isn't connected (Telegram never signed in, say) is
  no longer re-checked every few minutes; it is asked again as soon as you
  connect it, or after half an hour. Services read through Connections that
  had nothing new are read a little less often, up to every fifteen minutes,
  and back to every few minutes the moment something arrives. Apple Mail no
  longer shows as not connected on a day with no new mail. A daily pass
  whose every read failed now says *could not be read* instead of *nothing
  to read*. When memory is over its budget, your name and what you told Moe
  yourself are kept first, rather than whatever is oldest going first. And
  when the daily pass has waited for your plan several days running, the
  line under its switch and the Memory page say so. See **Learning about
  you** and **Memory: what Moe knows about you**.
- **unreleased (2026-10-15)** — **The cloud computer recovers from a restart
  faster, and never goes silent.** After your cloud computer restarts in the
  middle of an answer it is handed your message again at once, not two
  minutes later; a message that still could not be answered after its tries
  gets a short "please send it again" on the same chat instead of nothing.
  Its start-up is lighter so it fits comfortably in its memory, with a small
  overflow on disk for a spike. A one-time reminder that has already passed
  is no longer retried on the other side. See **What your cloud computer
  does**.
- **unreleased (2026-10-12)** — **Moe now says, anonymously, when you come
  back.** Owner decision, 2026-10-01: "retained" is three uses in the first
  week. Moe now sends one plain line the first time a third spoken command
  gets a real answer inside your first week, and a separate one the first
  time a spoken command gets a real answer on or after day 7 — each once,
  ever, per Mac, with no account, device or Mac identifier of any kind and
  never what was said. The Privacy Policy and the Terms are now version
  **2026-10-12.1**: not a material change (the same shape *Update checks*
  already discloses with no reaccept), so nobody who already agreed is asked
  again. See **What leaves your Mac, and when** and *Terms and Privacy
  Policy — when you agree, and to what*.
- **unreleased (2026-10-07)** — **The thinking part of Moe brings its own
  tools, and never fetches more of itself.** The part of Moe that does the
  thinking moved to a newer Python and now carries its own Node and ffmpeg
  inside the download, which stays the size it was. It no longer downloads
  extra pieces of itself while it runs: a feature that would need one says
  so instead. Its web browser is still downloaded the first time Memoe
  opens, and until it is there Moe says *still downloading its browser*
  rather than failing. On a Mac that already has Memoe, the first update
  after this puts the new thinking part in place from inside the app,
  keeping your memories, connections, chats and settings. See **Download
  and first open** and **Updating**.
- **unreleased (2026-10-07)** — **Long answers in the follow-up window are
  heard again.** When you answered Moe at length after it finished speaking,
  and paused somewhere in the middle, Moe could decide you were talking to
  somebody else and drop everything you said without a word. It was judging
  your whole answer by the last few words after your final pause. It now
  listens to all of it.
- **unreleased (2026-10-07)** — **Sending to an address Moe showed you.**
  When Moe finds an address on a page or on your screen, writes it in its
  message to you, and you answer "good" or "yes", the confirmation sheet now
  opens, in amber, saying where the address came from and what you said.
  Before this, Moe refused to send unless you typed the address yourself.
  Also, only what you actually typed or said now counts as you naming
  someone. Before this, numbers and addresses from the summary of your
  recent messages, or from Moe's own earlier replies, could count as yours.
  See **Who it is going to, and who chose them**.
- **unreleased (2026-10-07)** — **A job of yours that fails tells you, with
  a button.** A reminder or routine you set up that fails now puts one card
  in front of you within a few minutes, with **Show me what went wrong** and
  **Run it again** (or **Show me what it said** when it ran but its message
  never reached you). One-offs are told when they fail, repeating routines
  from the second failure in a row, and each failure is told once, not again
  per retry or a week later. Before, a one-off that failed, or a job meant
  for a chat app it could not reach, only showed up in its own record.
  See **Reminders**.
- **unreleased (2026-10-07)** — **Choosing which Gmail sends.** With several
  Gmail accounts connected, naming one by its address now always reaches
  that account. One that had never been given a name could not be picked by
  its address at all, so a send could only go through from whichever account
  was the default. Moe now learns each account's address, lists them when
  it chooses, and refuses an address that isn't one of yours (saying which
  are) instead of sending from the default.
- **unreleased (2026-10-07)** — **Moe knows which WhatsApp messages you
  sent.** Each message Moe reads from **WhatsApp on this Mac** now says who
  it is from and who it went to, so Moe no longer reports an invite you sent
  someone as one they sent you. A long look back through WhatsApp, Messages,
  calls, notes, reminders, the calendar, Drive or Chrome that reaches its
  size limit now keeps the newest part instead of failing. And a connection
  Moe could not check in time during its background reading is now noted as
  having taken too long, instead of being quietly left out. See **Your own
  WhatsApp and Telegram**.
- **unreleased (2026-10-07)** — **Moe tells you when it is your proxy, not the
  website.** When every page fails because your Mac's proxy setting points at
  something that isn't running, Moe now says so and where to fix it, instead
  of blaming the site. In its own browser Moe also clicks the way a person
  does on sites like X that ignore clicks made by a page script.
- **unreleased (2026-10-07)** — **Scheduled jobs ask instead of waiting on an
  empty screen.** When a scheduled job or other background work wants to
  post, click Send, or message someone while you are away from the Mac, it
  now stops at that step at once and leaves the question on your island,
  instead of putting a sheet up and waiting until it gave up. Its report
  says it is waiting on your OK rather than blaming the website. If you are
  at the Mac you still get the sheet, marked with who asked, and if nobody
  answers it Moe says so.
- **unreleased (2026-10-06)** — **Moe starts answering sooner.** When you
  speak to it, Moe now begins with the answer, or with what it is about to
  do, before working anything out at length. And when your connections
  change, Moe gets ready for that in the background instead of making you
  wait for it on the next thing you say.
- **unreleased (2026-10-06)** — **Moe hears you better, and stops
  inventing things you did not say.** "Hey Moe" no longer refuses your own
  voice, and a clear "Hey Moe" stops Moe mid-answer even with interrupting by
  voice off. A pause right after the name no longer ends the turn before you
  have asked anything. You have about three seconds, not one and a half, to
  carry on a sentence after a pause. Silence is no longer turned into words
  like "Thank you", an empty guess no longer throws away what you said, a
  silent moment no longer switches the online hearing off for the next
  minute, and sounds in the room that only faintly resemble a voice no longer
  count as you talking. After Moe asks you a question it waits 12 seconds for
  your answer instead of 8.
- **unreleased (2026-10-06)** — **A clearer request after an update.** When
  an updated Memoe has to set up its key for agreeing again, the Touch ID or
  password request now says *Memoe was updated and needs you to confirm it's
  you once more to keep agreeing on this Mac*, instead of reading like a
  first-time setup. See **Only you can agree**.
- **unreleased (2026-10-06)** — **Your cloud computer gets fixes on its
  own.** Until now a cloud computer stayed on the version it started with,
  so fixes made after you subscribed did not reach it. Now each one takes
  the newest version the next time it is asleep, never in the middle of
  answering you. See **What your cloud computer does**.
- **unreleased (2026-10-06)** — **A quieter inbox.** ✕ now dismisses a
  card instead of only hiding it, so it leaves the count. A new message
  about something already in your inbox updates that card instead of adding
  another. Cards close themselves once the thing is over: a meeting that
  has started, a follow-up that is closed, a draft that is no longer
  current. Done on a draft no longer counts as "not wanted", and drafts
  have a **Not this kind** button. The Inbox page has **Mark all read**,
  **Archive all** and multi-select **Archive selected**. On first launch
  the old backlog is archived to *Done*, keeping only drafts from the last
  two days.
- **unreleased (2026-10-06)** — **Mac and cloud take turns more cleanly.**
  A sleeping Mac no longer runs scheduled things in macOS's background
  wake-ups; the cloud computer has them until you open the lid. While the Mac
  is away the cloud computer checks in at least hourly, and it is no longer
  woken for jobs only your Mac can do. A reminder you ask for on Telegram
  comes back to you on Telegram from either machine. Moe's background
  check-ins no longer fail on invisible characters that WhatsApp puts inside
  messages.
- **unreleased (2026-10-06)** — **Double-tap to stop really stops.** Once
  Moe has stopped, nothing from the stopped answer can start it talking
  again or light the island back up, including an answer you typed. Extra
  double-taps in the two seconds after a stop no longer switch hands-free
  listening on. **PocketTTS sounds smoother:** it uses the setting Kyutai, its
  maker, recommends, and on a busy Mac it builds up a little more audio
  before speaking instead of stuttering mid-sentence.
- **unreleased (2026-09-30)** — **Moe checks what it can do before handing
  you a step.** Before something becomes yours to do, Moe looks at what its
  own tools say they can do and tries that first, instead of going by what it
  remembers they can do.
- **unreleased (2026-09-30)** — **Jobs survive your Mac dozing.** A job
  that was running when your Mac went into a few minutes of maintenance
  sleep was stopped as "stuck" the moment it woke — "X daily growth" failed
  five mornings in a row that way. Time asleep no longer counts. And a
  hidden review that ran after every marketing job, and died each time, no
  longer runs.
- **unreleased (2026-09-30)** — **Pasted keys work.** A service you connected
  by pasting a key (Cloudflare, Firecrawl and the like) showed as connected
  but Moe could not use it. Now it can, and connections made before this fix
  start working on their own. **Reconnect signs you in again** for a service
  whose sign-in ran out, such as Cloudflare. Before, it said "already set up"
  and opened nothing.
- **unreleased (2026-09-30)** — **Moe stays open when your microphone
  changes or the paid voice drops.** Plugging in a headset or switching
  microphones during a meeting or a conversation could make Memoe quit a
  few moments later, and so could the paid voice losing its connection
  mid-reply. Both now carry on: the microphone is picked up again, and the
  voice reconnects for the next sentence. And no more empty cards on the
  island: a card that just said "noop" is gone, and "That WhatsApp send
  … was withdrawn" appears only if you were away and never saw the send
  sheet — once, never raised again.
- **unreleased (2026-09-30)** — **Moe stops re-telling you what you
  already have.** A new email, WhatsApp or text is never passed on as it
  arrives — you see it in its own app. Moe raises a message only when a
  person has waited three hours or more and you have not answered it (or,
  for mail, opened it); businesses and marketing texts never count. Reminders stay in
  your Reminders app, and a meeting gets its ten-minute heads-up plus at
  most one offer to prepare a day. Moe offers help with a conversation at
  most once a day, and not while you are writing in it. See *Your inbox*.
- **unreleased (2026-09-30)** — **More services, ready to go.** Yelp, Hacker
  News, OpenWeatherMap, AllTrails and GoDaddy now work with nothing to sign in
  to. Otter, Granola, Lucid, Descript and Mercury can be connected. Every
  service on the shelves shows its own logo.
- **unreleased (2026-09-30)** — **"Report this" always reaches us.** Asked
  from your phone to report a problem to the Memoe team, Moe could say it
  had no way to report it and keep it in its notes instead. Reporting a
  problem is now one of Moe's own tools, on your Mac and on your cloud
  computer, so it files the ticket and tells you the number — or, if
  problem reports are off, says so and how to turn them on.
- **unreleased (2026-09-30)** — **Every calendar event says its date.**
  Moe's copy of your day now writes the date on every event, today's
  too, beside *today* or *tomorrow*. Moe in the cloud had read an older
  copy and told you a meeting happening today was tomorrow; with the
  date on every line that mix-up can't happen.
- **unreleased (2026-09-30)** — **Your cloud computer sees all your
  jobs.** Jobs you set up in a long conversation were too big to reach your
  cloud computer, so it could see only a few of them, and it called a job
  "healthy" that had not worked for days. Every job now reaches it, and Moe
  on both knows each job's real state — working, not working and why,
  paused, or not run yet.
- **unreleased (2026-09-30)** — **Hand-overs that go to the right place.**
  Moe shows you its own browser window even after it has restarted in the
  background, finds the page you need to act on, and never sends a sign-in
  page or an unrelated tab to your Chrome. For passkeys it tries "Try another
  way" first.
- **unreleased (2026-09-30)** — **Repeats, for real.** Something Moe
  already told you comes back only when something about it is new —
  a new message, a changed time, an edited Reminder — not because the
  meeting is still on your calendar. Reminders you had already dismissed
  count, and a reminder held back overnight is checked again before it
  reaches your phone, and does not go there at all while you are at your
  Mac.
- **unreleased (2026-09-30)** — **One Moe at a time.** Locking your Mac
  made your cloud computer think the Mac was gone, so both ran the same
  background checks and you heard about one meeting twice. Now a running
  Mac counts as here — locked or not, and right after it restarts — and the
  cloud computer only takes over a few minutes after your Mac goes to sleep
  or quits.
- **unreleased (2026-09-30)** — **Connections that say what is true.**
  Adding another Gmail inbox failed with no reason. Unfinished sign-ins were
  piling up at Composio and filling its five-account limit, and a service
  you had just connected, like Reddit, could show as not connected. Both are
  fixed. If you do reach the limit, Moe now tells you. The shelves list the
  services people use most, most used first, split into everyday and work.
  Spotify no longer opens a Hermes page: until Memoe has its own Spotify
  sign-in, it says it can't be connected yet.
- **unreleased (2026-09-30)** — **No machine talk.** A background job
  whose tools failed to load could send you its unrun tool calls as a
  message, and Moe's background check could send you its own reasoning
  about why it was *not* reminding you. Neither reaches you now: the job
  counts as failed (and shows so in Settings › Background), and the check
  says nothing unless it has something to tell you.
- **unreleased (2026-09-30)** — **Done means done.** Pressing Done, Skip or
  Got it on something Moe raised now closes it for real and keeps that
  subject quiet until what it came from changes, instead of the same
  reminder coming back several times a day. When it came from Apple
  Reminders, one tap marks it done there too.
- **unreleased (2026-09-30)** — **Select and Copy all have their own bar.**
  They sit in a slim bar at the top of Chat instead of floating over your
  messages, and pressing Select keeps you at the latest message instead of
  jumping to the top.
- **unreleased (2026-09-29)** — **Your cloud computer follows your
  Settings sooner.** Quiet hours switched off here now apply to reminders
  from your cloud computer too, and your offer settings reach it within
  minutes. What you tell Moe about its offers ("Not this kind of thing")
  now counts there as well. Offers from the cloud computer itself stay off
  for now.
- **unreleased (2026-09-29)** — **Every message, and every email once.**
  Moe's briefs and learning missed most iMessages on recent macOS, which
  keep their words only in their formatted form; they read them all now.
  And an email that reaches Moe by two routes (Apple Mail and Gmail, say)
  is thought about once. See *Messages* and *Mail* under the sources.
- **unreleased (2026-09-29)** — **Use draft sends from your Mac on every
  channel.** Only WhatsApp drafts went straight out; every other channel
  handed the draft to Moe's brain to send. Now Telegram, Messages, Apple
  Mail and every Composio service send it themselves, to that same
  conversation, after the same confirmation. See *Replies Moe prepared for you*.
- **unreleased (2026-09-29)** — **Picture puzzles, and a hand-over that
  stays in Moe's browser.** Moe now reads hCaptcha's picture puzzles and
  solves them with your solving service, swapping moving or drag puzzles for
  new ones. When a check does need you, Moe shows you its own window with the
  form still filled in, then hides it again and carries on, instead of
  opening the page in your Chrome.
- **unreleased (2026-09-29)** — **Clearer replies and a way to finish
  ready work.** Reply now shows what the box is for, with Cancel. A ready
  draft has **Done** in the inbox and on its card, and the card's buttons
  no longer fall below the Dock. An item's title and summary no longer
  repeat the same sentence.
- **unreleased (2026-09-29)** — **Copy any message, or the whole
  conversation.** Only Moe's answers could be copied, and a selection could
  not run from one message to the next. Now every message has Copy on
  right-click, in Chat and on the island, and Chat's **Select** shows the
  conversation as one page you can select across. See *Reading the chat*.
- **unreleased (2026-09-29)** — **One inbox for everything Moe brings up.**
  Reminders, questions, drafts Moe has ready, briefs and heads-ups used to
  arrive as one amber card, cut off after three lines, that disappeared when
  you dismissed it and answered into whatever conversation was open. They
  now wait in an inbox on the island and in the Memoe window. Each kind has
  buttons that fit it: Done, Snooze, an answer, Review, Got it. Long ones
  open as a readable card, and a reply starts its own conversation. See
  [Your inbox](#your-inbox).
- **unreleased (2026-09-29)** — **Moe no longer mistakes you for someone
  else mid-conversation.** A long turn in your own voice was dropped as
  "another voice" on one noisy reading; a turn as loud as you usually are,
  or matching your voice, is now judged on its words.
- **unreleased (2026-09-29)** — **A failed answer is said out loud, and the
  name stays out of the request.** When Moe cannot answer a spoken question,
  a weekly limit for instance, it now says so instead of going quiet and
  reopening the conversation. "Hey Moe" heard as "Emma?" or a bare "Hey," is
  no longer handed to Moe as part of what you asked.
- **unreleased (2026-09-29)** — **Import from ChatGPT or Claude, and a
  weekly "what I learned" note.** Memory › Import from ChatGPT or Claude
  gives you one question to ask the other assistant; paste its answer back
  and Moe keeps what it remembered about you, marked where it came from,
  with anything that disagrees shown under To check. On Sunday mornings Moe
  sends a short note of the new things it learned about you that week; say
  "forget" to any that are wrong.
- **unreleased (2026-09-29)** — **The microphone lets go sooner in a noisy
  room, and long answers are no longer dropped.** Noise in the follow-up
  window extends it by a few seconds instead of restarting it, and closes it
  after three in a row. A finished-sounding sentence that Moe was unsure of
  waits about three seconds, not six. A long answer to Moe's own question,
  or a turn clearly in your voice at the Mac, is answered rather than
  dropped. Premium hearing no longer treats a quiet room as a failure, and
  after a real one it rests for seconds, not a minute.
- **unreleased (2026-09-29)** — **Moe no longer goes quiet mid-sentence
  when the connection wobbles.** A premium-voice answer that stops arriving
  is noticed within about a second (it could take over a minute), the rest
  of that answer is spoken in the Mac's closest matching voice, starting
  where the premium voice stopped, and the premium voice returns at the next
  answer instead of switching back and forth inside one.
- **unreleased (2026-09-29)** — **Passcodes go through Moe's password
  window, and an earlier "can't" gets another try.** When a site asks for a
  passcode or PIN you know, Moe asks you for it in its password window and
  enters it without seeing it, instead of saying it cannot type passcodes.
  When an "are you human?" check needs you, Moe brings the page up in front
  of you itself. And something Moe could not do earlier in a conversation,
  it tries again when the task comes back to it, rather than repeating that
  it cannot. See *Moe's own browser* and *Driving your Mac*.
- **unreleased (2026-09-29)** — **Background helpers no longer go missing.**
  Seven helpers finished in the afternoon and Moe never said so, because an
  unanswered reminder on the island held back everything queued behind it,
  including their results. Then signing in to another Claude account cleared
  the chat and started Moe on a blank conversation, so when asked about the
  helpers, it said it had started none. Now a finished helper is reported
  whatever is waiting on the island. A sign-in or a new AI keeps the
  conversation you are in. And a result goes back to the conversation that
  started it: if you are somewhere else, Moe says where and offers to take
  you there.
- **unreleased (2026-09-29)** — **Moe learns from what your mail and
  messages say, not only their labels.** For Gmail, Outlook, Slack and other
  services connected through Connections, the daily learning pass now reads
  the messages themselves, everything in the inbox. It uses what Moe already
  fetched to watch them, so there are no extra reads. Automated mail is left
  out, and each conversation is cut to its newest few messages, so it stays
  cheap. The switch for each service says so.
- **unreleased (2026-09-29)** — **A search is not an email.** Code Moe
  runs that only mentions a service in its text — a list of web searches
  about Gmail, say — asked you to approve sending an email. Words inside
  quoted text in Moe's code no longer count as a send; code that actually
  sends is still asked about.
- **unreleased (2026-09-29)** — **Moe asks instead of moving on.** When Moe
  hit a step it could not do alone, it sometimes said so and went on to the
  next thing. Now it first tries another way, and if the step really needs
  you, it asks you for exactly what is missing, carries on with the rest,
  and comes back to it when you answer. It never skips part of what you
  asked for without your say.
- **unreleased (2026-09-29)** — **Your Mac and your cloud computer catch up
  within minutes.** What Moe notices in the background (open situations,
  promises, how far it has read each chat) and what it has already told you
  used to cross between your Mac and your cloud computer only when a chat
  with Moe started or ended. From the cloud's side, that meant only when you
  next messaged it. Now each side sends what changed, and takes in what
  arrived, every five minutes. Nothing is sent when nothing changed.
- **unreleased (2026-09-29)** — **One switch per source: Learn and watch.**
  Each connected thing now has one switch, under Settings › Running in the
  background › Keeping up, in place of three scattered ones (check every 10
  minutes, mention, learn about me). The switch covers everything Moe does
  with that source by itself: keeping it ready, learning from it, watching
  it and mentioning it. Connecting something asks once: *Let Moe learn from
  … and watch it for things you'd want help with?* **Yes** is chosen for
  you; **Not now** asks once more a week later. Sources connected before
  this question, or another way, are asked about together when you next
  open Memoe. Anything you had already said yes to stays on. A source with
  no yes is no longer copied every ten minutes or mentioned. Apple Mail now
  has a switch of its own too.
  this question, or another way, are asked about when you next open Memoe,
  one at a time. Anything you had already said yes to stays on. A source
  with no yes is no longer copied every ten minutes or mentioned.
- **unreleased (2026-09-29)** — **Away's browser stays signed in.** On your
  cloud computer Moe's browser now keeps its own sign-ins from one day to the
  next, on that machine only, where it used to start signed out every time.
  When a site there needs you, Moe sends a one-time link that opens that
  browser on your phone so you can sign in yourself. See *Moe's own browser*.
- **unreleased (2026-09-29)** — **Confirmation cards in plain words.** Every
  card now leads with what is about to happen and where — *Create an account
  on fazier.com?*, *Type “you@example.com” into fazier.com and press
  “Forget Password”* — with the code, the tool's name and its settings behind
  **Show details**. Signing up somewhere asks with its own card every time,
  showing the email it will use, with **Create account** / **Not now**; it
  used to reach you as "a tool Moe does not recognise", with an "Always
  allow" that would have stopped Moe asking about signups at all. Typing your
  email next to a "Forgot password" button no longer asks as if it were a
  password, and Moe no longer asks you to approve a signup that could not
  work. See *Moe's own browser* and *Before anything goes out*.
- **unreleased (2026-09-29)** — **Moe keeps track of promises.** It notes
  what you said you'd do and what others said they'd do for you, from your
  chats, mail, calendar, Notes, recorded calls, meeting notes and what you
  tell Moe. It closes a promise by itself when it sees it kept. If not, the
  promise comes up the morning it's due and again the morning after, with
  whatever would help ready, or just the promise itself. The list is under
  Settings › Running in the background › More › Noticed. See *Promises*
  under Running in the background.
- **unreleased (2026-09-29)** — **Your cloud computer can use its tools
  again.** Since 25 September the check that asks before anything is sent
  refused every step on your cloud computer, even reading, so from your phone
  Moe could talk but not look anything up or do anything. It works again.
- **unreleased (2026-09-28)** — **Services that can't be checked can
  tell Moe themselves (Away plans).** Some connected services have nothing
  Moe can look at for "what's new" — Slack's live messages, for one. On an
  Away plan, Moe now switches on that service's own notifications for
  things meant for you (a direct message, a mention), in your own Composio
  account. They reach Memoe's server already locked so that only your cloud
  computer can open them, are kept only until it collects them (24 hours at
  most), and count towards a daily limit (300 on Away, 600 on Away+). Your
  cloud computer reads them the way it reads everything else, and anything
  worth your attention reaches your Mac as usual. Disconnecting the service,
  or moving to the free plan, switches them off.
- **unreleased (2026-09-28)** — **Fewer Settings pages, each as calm as
  Voice.** Thirteen pages became nine: **History** holds Activity, Usage and
  Chats as tabs; Reminders is a tab of **Running in the background**, which
  now has three tabs (Speaking up, Reminders, Keeping up) with the run
  history and what Moe noticed under **More**; Skills is a tab of **Brain**.
  Brain picks the model and how hard it thinks from a menu, and how long it
  may work from one pill. Permissions is one line each, with anything not
  allowed at the top. The paragraphs that opened pages are gone, and the
  licence notices on About are one **Show** away.
- **unreleased (2026-09-28)** — **A site you just signed into is signed in
  for Moe too.** Moe's browser used to take your logins only when it opened,
  so a site you signed into a minute later stayed signed out for Moe until it
  restarted. It now picks them up as soon as your own browser has saved them.
  Google sign-ins never carry over (Google ties them to your own Chrome), so
  on "Continue with Google" Moe picks your account in Google's list itself,
  and brings the page up for you only if Google asks for your passkey, a
  security key, a verification step or your password.
- **unreleased (2026-09-28)** — **Moe watches more of your connected
  services.** Services connected through Composio with large tool lists,
  GitHub for one, were being passed over as having nothing to watch; Moe now
  finds the list of what is new for you (GitHub: your notifications) and
  reads it like the others. Notion pages, Outlook mail and HTML-only messages
  are read as words.
- **unreleased (2026-09-25)** — **Give Moe a password without saying it.**
  When a site needs a login Moe does not have, a small Moe window asks you
  to type it — headed with the site's address — and Moe stores it without
  seeing it; a sign-in code that never arrived by email is typed into the
  same window. For a new account, Moe can make a strong password itself and
  keep it, and asks you first, for that one site, every time. See
  [Moe's own browser](#moes-own-browser).
- **unreleased (2026-09-25)** — **Moe notices across more of your life, and
  reads the whole message.** Besides WhatsApp and your Composio services,
  what Moe watches for things you might want help with now includes
  **Messages** (iMessage and SMS), **My own Telegram**, **Gmail** connected
  with an app password, **Calendar** invitations and changes, and the new
  **Mail** connection (every account in the Mail app). Each reads the whole
  message rather than a preview — quoted earlier replies and signatures are
  left out — and Gmail connected through Composio now does too. Gmail skips
  Promotions, Social, Updates and Forums. Calendar now reads an invitation's
  notes (its agenda, dial-in and any questions), and the sentence Moe shows
  when asking to read your calendar says so. Each source still needs your
  yes before Moe reads it.
- **unreleased (2026-09-25)** — **Picture puzzles, with your own solving
  service.** Moe can now get past "click every square with…" puzzles using a
  NopeCHA or CapSolver key of yours; only the picture leaves your Mac. Moe's
  signed-out browser, and the one on your cloud computer, also stopped
  announcing themselves as automated, so fewer sites put up a check at all.
- **unreleased (2026-09-25)** — **Messages and phone calls are read again.**
  Moe could reach your iMessage, SMS and call history but found nothing
  in them: every recent message and call was passed over, both in the
  daily catch-up and when learning about you. Now it reads what arrived in
  the window it was asked about.
- **unreleased (2026-09-25)** — **Moe can message you, and only you.** Ask
  "message me on Telegram" and Moe works out on the spot whether you are at
  the Mac (the island) or away (your own Telegram chat through Memoe, then
  the chat apps you ticked), and says which one it used. Urgent messages go
  to all of them. If nothing can reach you, it says so and keeps the message
  for you. Your Telegram chat is one Memoe's cloud knows is yours (the
  account that made your bot), confirmed with a code in Connections. It is
  never one your Mac names, and Memoe never guesses: when it can't tell,
  messages stay on your Mac. A routine made to message you now goes to you,
  never to a contact's chat.
- **unreleased (2026-09-25)** — **Moe tidies its memory overnight.** Once a
  day, while the Mac is idle, Moe merges repeated lines, turns relative
  dates into real ones, sets aside plans that are over, settles lines that
  disagree and decides the changes its own review had left waiting — by
  itself, on the cheapest model, never adding or dropping a name or number
  and never touching your own words. What it set aside is under **Past**
  with **Restore**. A fact you deleted that Moe notices again is asked in
  *To check* as **Remember this again?**
- **unreleased (2026-09-25)** — **Every Settings page reads like Voice.**
  Headings in plain sentence case, no lines between rows, short quiet
  explanations, and choices laid out evenly: Brain's model and effort cards
  are one width, and Activity, Usage and Skills pick their window or filter
  from one pill. Settings › Away, once you have a plan, is your plan as
  three rows, how it is, your chats, and **More** for your devices, what it
  thinks with, which computer answers and signing out. Running in the
  background's tabs wrap instead of running off the window.
- **unreleased (2026-09-25)** — **When a page needs you, Moe shows it to
  you.** A passkey, a security key, a "confirm it's you" check or a CAPTCHA
  in Moe's out-of-sight browser now brings the page up in front of you, on
  the same page and still signed in; say "done" and Moe carries on. Ask to
  see a page and the same happens — when you are at your Mac. From your
  phone, or in a scheduled job, Moe tells you what is waiting instead of
  popping anything up on an empty screen. Moe no longer tells you to approve something on
  your phone unless the site said so. A sign-in code you read out, you type
  into the page yourself; Moe brings the page up for you. See
  [Moe's own browser](#moes-own-browser).
- **unreleased (2026-09-25)** — **Your cloud computer thinks with whatever
  your Mac does.** Signing in to a different Claude plan on your Mac left
  your cloud computer on the old one, even after it ran out. Now a new
  Claude sign-in, a different key or a ChatGPT sign-in on your Mac reaches
  your cloud computer by itself, unless you gave it a brain of its own in
  Settings › Away, which you can undo with *Use the same as my Mac*.
- **unreleased (2026-09-25)** — **Voice settings are one calm page.**
  Settings › Voice, Settings › Voice › How Moe sounds and Settings › Replies
  were thirty-two controls on three screens; they are now one page in three
  sections (Starting, The conversation, Moe's answers), where a switch shows
  its own settings under it only while it is on, and everything else sits
  under **More**. Nothing was removed. Renamed: *The key you hold to talk* →
  *Hold a key to talk*; *Say "Hey Moe"* → *Or just say "Hey Moe"*; *Keep
  the conversation going* → *Keep listening after Moe answers*; *How long it
  keeps listening* → *Waits for*; *When it goes quiet* → *When you go quiet*;
  *Interrupt Moe by talking* → *Let me interrupt Moe by talking*; *Also after
  I hold the key* → *Keep listening after a held-key turn too*; *Set of
  voices* and *Voice* → one **Voice** list, applied when picked, with ▶ in
  place of *Use and preview*; *Reply length* → *How much Moe says*; *Speak
  replies out loud* → *Answers: Out loud / On screen only*; *When you talk
  to Moe* / *When you type to Moe* → *Answer questions I ask out loud, out
  loud* / *Answer typed questions out loud too*; *Write answers to typed
  questions to be read, not heard* → *Write typed answers to be read*; *Open
  by itself when an answer is ready* → *Open the island panel by itself*;
  *How long it stays* → *How long the panel stays*; *Check this microphone
  and these speakers* → *Check my microphone and speakers*; *Use the sharper
  voice and hearing that come with my plan* → *Premium hearing and voice*;
  *Forget my voice* → *Forget*. The Replies pane is gone from the sidebar, and
  links to it open Voice. *Moe sees my screen when I ask*, *Move my mouse to
  what Moe points at* and *Let Moe bring a window to the front* moved to
  Settings › Permissions › *Moe and your screen*. **Keep listening after Moe
  answers** is now on for a new install; an existing install keeps the
  value it had. The Away welcome's button reads *Open Voice settings*.
- **unreleased (2026-09-25)** — **Problem reports follow you to a new
  account.** If you turned on "Let Moe send problem reports" and later signed
  in to a different Memoe account, the new account never heard your yes, so
  your cloud computer refused to send reports. Your Mac now tells the account
  itself, and when it needs you to confirm it's you, Settings › Privacy asks.
- **unreleased (2026-09-25)** — **Moe only messages people you named.** A
  send to someone who is only in Moe's memory, a job's own text, a web page
  or someone else's message is stopped before the sheet, and Moe is told to
  look them up or ask. The sheet now says who chose the recipient: *You
  named this person* with your words, or, in amber, *You said "Moshe" — Moe
  picked …* or *Moe chose this person — found in your WhatsApp chats*, with
  a warning when you asked for somebody else. A message meant for you never
  goes to one of your contacts, and a message to you that nobody asked for
  is stopped; "email it to me" and meeting notes to your own Telegram work
  as before. An address beside a name must itself come from you or a
  lookup; mail and calendar lookups count only their From/To/guest lines.
  Moe can look people up in your Contacts. A job made before this shows its
  sends in amber, and Settings › Reminders asks "This job messages … —
  keep?" once. Scheduled jobs are also told plainly never to deliver a
  report by any sending tool at all.
- **unreleased (2026-09-25)** — **Recipient checks, tightened.** Mail
  lookups count only From/To/Cc — never a Reply-To or a line in the message
  body; chat lookups count only the sender and the chat's name. A message to
  `platform:<chat>` or a Slack DM is checked like any recipient (your home
  chat excepted, and only when it is yours), and the WhatsApp link on your
  Mac cannot be called directly, nor written into a script to run later. An old job's amber covers only the people its own text names,
  and old jobs that message nobody are treated as new. Your Gmail connected
  through Composio now counts as you. A reply Moe prepared that is not sent
  says why.
- **unreleased (2026-09-25)** — **The send sheet can't get stuck.** A sheet
  now closes itself, sending nothing, when the task that asked for it stops
  or nobody answered in time, and leaves a note on the island saying what
  was not sent and why. A WhatsApp, Telegram or Gmail send from a background
  job waits on the island for your yes while you are away from the Mac, and
  shows a sheet marked with who asked while you are at it. **Cancel** works
  on the first click, the sheet can be dragged by its top strip, it stops
  floating over everything once you click elsewhere, and it steps aside
  from Memoe's own windows instead of covering the chat.
- **unreleased (2026-09-25)** — **Moe gets past "are you human?" checks
  itself.** A "Just a moment" page, an "I'm not a robot" box or a
  press-and-hold button used to stop Moe's browser, and Moe gave up on the
  site. It now waits, ticks or holds as you would, and asks you only when the
  check needs more than that. Ticket-selling sites and blocked connections
  always come to you.
- **unreleased (2026-09-25)** — **Moe says what reaches your cloud
  computer.** Settings › Away has a *While your Mac is off* list: for each
  thing you connected, whether your cloud computer can reach it with your
  Mac shut, waits for your Mac, or is one step away, and where the step
  is (a WhatsApp code, putting Telegram back, or connecting the same
  service under Connections). When a step is waiting, the island reminds
  you once, with Not now (a week) and Don't remind me (for good, per
  connection).
- **unreleased (2026-09-25)** — **Your cloud computer asks you before it
  sends through your connected services, instead of refusing.** An email or
  Slack message it would send through a service you connected now comes to
  your chat as a question, with the recipient and the whole message, and goes
  only when you reply *approve*. Long messages are no longer cut short in the
  question. When nobody can be asked (a scheduled job), Moe says so instead
  of saying you cancelled it. It also keeps your cloud computer's calls to
  connected services within the same hourly and daily bounds your Mac uses.
- **unreleased (2026-09-25)** — **Voice notes reach Moe.** With Away, a
  voice note you send Moe on Telegram or WhatsApp Business used to vanish
  without a reply. Now Moe listens to it and answers, counted in your
  monthly Listening allowance; when it cannot, it tells you instead of
  saying nothing.
- **unreleased (2026-09-25)** — **"Remind me" from your phone is a real
  reminder.** With your Mac shut, asking Moe on Telegram to remind you queued
  an Apple Reminder for your Mac to add later, so nothing reached you on
  time. Moe now sets its own reminder, which goes off on your Mac if it is
  open and on your phone if it is not. Say "put it in Apple Reminders" if
  that is what you want.
- **unreleased (2026-09-25)** — **"Report this to the Moe team" works from
  your phone.** With your Mac shut, your cloud computer said it had no way to
  file a report. It now files it the same way your Mac does, and only if
  problem reports are on in Settings › Privacy.
- **unreleased (2026-09-25)** — **Offers have their own switches.** Settings
  › Background › Noticed now has *Offer what's ready* (the island's card with
  Use draft, See it and Not now; off by default) and *Also send offers to my
  chats when I'm away* (off by default). With both off, Moe still notices and
  prepares, and shows it only in that tab.
- **unreleased (2026-09-25)** — **Mute no longer switches itself off, and
  stops following your voice.** Clicking the notch or the red tab under it
  opens the island and leaves you muted; only the red **Unmute** button
  unmutes, and it now sits at the far end of the controls from the **⋯**
  with its name on it (it was a bare red circle beside the **⋯**, and every
  unexpected unmute the owner reported was that circle). On an island that
  only dropped down on hover, the first press keeps it open instead. While
  muted, the glow around the notch is still and red and no longer pulses
  with the microphone. The folded tab now reads **Muted**.
- **unreleased (2026-09-25)** — **A reminder you set from your phone is no
  longer lost when your Mac wakes up.** Asking your cloud computer to remind
  you (over Telegram, with your Mac shut) made the reminder, but the next
  time your Mac synced it quietly deleted it, and it never went off
  anywhere. Your Mac now keeps it too, so it goes off whether your Mac is
  open or shut.
- **unreleased (2026-09-25)** — **Moe's browser no longer stalls on a slow
  page.** A page that took more than five seconds to answer made every
  browser step fail with "the browser is not responding", and a long job
  piled up dozens of tabs until it slowed to a stop (ticket #16). A page now
  gets half a minute, Moe is told which page was slow, pop-ups nobody can
  answer are dismissed, and Moe keeps at most six of its own tabs open.
- **unreleased (2026-09-25)** — **Your cloud computer no longer sends
  through connected services without asking.** An email, a Slack message or
  any other message your cloud computer would have sent through a service
  you connected went out with no question asked; only Moe's own Telegram and
  WhatsApp connections asked first. It now checks every send by the same
  rules your Mac uses, and until it can ask you on your phone about those,
  it refuses them and tells you nothing was sent.
- **unreleased (2026-09-25)** — **"Interrupt Moe by talking" off now means
  off.** With it off, talking while Moe was still thinking could make it
  drop the answer it was working on and start again with your words added
  on, even several seconds after you had finished. Now only carrying on
  within about a second and a half of pausing, to finish your own sentence,
  is joined to your question; after that nothing you say while Moe thinks
  or answers stops or restarts it, its name included. The key, the shortcut
  and the island's buttons work as before, and with the setting on nothing
  has changed.
- **unreleased (2026-09-25)** — **Moe stops growing on your disk.** Its
  logs roll over at a few megabytes instead of growing for ever, and past
  conversation records older than a year are cleared. Moe's browser keeps
  only its newest Chrome and no longer carries Chrome's 4 GB AI model, and a
  recording kept because a meeting's transcript looked incomplete is removed
  after 30 days. Memories, meeting notes and your files are kept as before.
- **unreleased (2026-09-25)** — **Conversations get short names, and Moe
  can look back through them.** Each conversation in Chat is named in a few
  words by the cheapest model on your plan, from your first message only,
  once Moe has answered; older conversations are named the first time you
  open Chat, twenty at most, one at a time. Ask Moe about something from an
  earlier conversation ("what did we decide about the pricing?") and it
  searches your past conversations instead of saying it doesn't remember.
- **unreleased (2026-09-25)** — **Drafts look like messages, and long text
  scrolls.** When Moe drafts an email or a message for you, it shows as a
  card, the way a mail app shows one, in Chat and on the island, instead of
  lines starting with ">". Bold and headings read as bold and headings,
  reminder cards included. The box you type into in Chat grows to six lines
  and then scrolls with the trackpad; on the island it grows to four. Return
  sends and Shift-Return starts a new line. An island panel you opened with
  a click now closes when you click anywhere else, and keeps what you had
  typed for next time.
- **unreleased (2026-09-25)** — **The box to type in never disappears.**
  It used to hide while Moe worked. It stays now, and what you type while
  Moe is busy is held and sent as soon as it finishes, instead of being
  turned away with "Still working on the last one".
- **unreleased (2026-09-25)** — **The panel always fits.** With a reminder
  card over a long conversation, the card no longer slides up under the
  notch and the box to type in no longer falls off the bottom: the
  conversation takes whatever room is left and scrolls, fading softly at
  the top.
- **unreleased (2026-09-25)** — **The send card works like a window
  should.** Paste (and cut, copy, select all, undo) now works in the
  subject and message you can edit on a card before Moe sends it, and the
  card follows you to every desktop and full-screen app instead of staying
  on the one it appeared on. On the island, Moe's answers are never cut
  short (only a long message of yours gets **More**), and a turn that has
  not reached its first step says *Thinking* rather than "…".
- **unreleased (2026-09-25)** — **The whole conversation, on the island.**
  The panel is a chat you can scroll: every message of the session, yours
  on the right and Moe's on the left, with **More** on long ones. While Moe
  works, its step is added under the conversation instead of replacing it.
  A **new conversation** button sits beside the ⌃; the old one stays in
  Chat.
- **unreleased (2026-09-24)** — **Moe's background thinking stays private.**
  On a Claude plan, the small background jobs (noticing situations in your
  chats, learning from conversations, titles, tidying) used to run inside
  your own Claude Code setup on this Mac, with your tools, add-ons and
  history turned on. Each one now runs sealed off on its own: no tools, no
  add-ons, nothing saved to your Claude Code history, and it cannot open
  your files.
- **unreleased (2026-09-24)** — **The panel reads like a chat.** What you
  said is a bubble on the right, up to four lines instead of one small
  line at the top, and live while you talk; Moe's answer is on the left.
  The end of a long answer is no longer cut off at the panel's edge, and the
  green light around the notch while you talk fades out softly on every
  side instead of ending in a hard edge.
- **unreleased (2026-09-24)** — **You can see when Moe has your screen.**
  While Moe clicks and types in an app, or works in its own browser, a thin
  magenta line glows around the edge of the screen as well as at the notch.
  It never blocks a click and never appears in a screenshot.
- **unreleased (2026-09-24)** — **A click on the island opens the island.**
  It used to open the Memoe window from anywhere on the island, so a click
  on empty space in an open panel threw a window over your screen, or read
  a waiting reminder aloud. The window is an icon behind the **⋯** now. A
  call Moe offers to record is asked once, on the island, with the amber
  glow, instead of on the island and a second card in the corner. The live
  transcript switches itself off when the conversation ends, instead of
  staying on silently and opening the island on every "Hey Moe" and every
  answer.
- **unreleased (2026-09-24)** — **The meeting panel matches the rest of the
  island.** One word beside the notch (*Recording*, *Off the record*), the
  time on the other side, and every control behind the **⋯**; off the record
  and a screen clip stay in view while they run. Hovering during a call no
  longer puts the cursor in the question box, so it can't take your typing
  from the call; click to type. The tabs are **Transcript**, **Ask Moe** and
  **To do**, and the panel is the same width as the conversation's.
- **unreleased (2026-09-24)** — **A calmer panel under the notch.** It
  keeps one shape for a whole turn instead of swapping between a one-line
  working row and the conversation. One word beside the notch says what Moe
  is doing; under it, your last words and Moe's line. Every control (mute,
  work silently, the live transcript, pause, start over, read aloud, copy,
  stop) sits behind one **⋯**, as small icons, always in the same order, and
  each switch shows what is true now. The ✕ that stopped Moe from the corner
  is gone; there is one stop. The field hides while Moe works or while you
  talk. The hover panel and the opened one are the same width.
- **unreleased (2026-09-24)** — **The notch's light is easier to read.**
  Idle, thinking and speaking are now all Moe's white light, told apart by
  how it moves, instead of two blues and a second green that looked like
  listening. A paused reply dims and holds still, where it used to look
  exactly like one being spoken.
- **unreleased (2026-09-24)** — **Moe starts noticing what you might want
  help with — quietly, for now.** Every few minutes Moe looks at what is new
  in what you have let it learn from — your WhatsApp chats, and every
  service connected through Composio that has something to list, such as
  Gmail and Google Calendar — and asks one question of each conversation
  that moved:
  is there something open here where you have something at stake and the
  next move is yours, that Moe could prepare for you? What it finds is kept
  for you to see, and nothing is said or sent while it is being tuned. It
  never reads a source you have not allowed, and Background thinking off
  stops it spending anything. In Settings › Background it is *Noticing what
  you might want help with*, and the **Noticed** tab there shows what it saw
  in the last day: how many conversations moved, how many it passed over and
  why, and each thing it noticed, whose move it is and what is at stake,
  with the words it rests on. For the ones where the next move is yours and
  it is fairly sure you would want help, it gets the work ready — it looks
  into how such things usually go (searching without ever naming who or
  quoting what was said), works out the options with the numbers, and drafts
  a reply in your voice, with no links or account numbers carried over from
  the conversation — and shows it there under *Ready*. When it is fairly
  sure you would want it, Moe offers it: the island glows with one line and
  **Use draft**, **See it**, **Not now** — and, when you are away from the
  Mac and have also turned on offers in your chats (a separate switch from
  reminders: off unless you choose it), the offer and the draft arrive there,
  never during your quiet hours. *Use draft* sends exactly that reply to that
  same conversation — the chat or mail thread it came from, not a name looked
  up again — after you see the words and confirm, every time; for WhatsApp
  your Mac sends it itself, with no AI in between. An offer for a
  conversation that has since settled, or whose draft has changed since you
  saw it, is not sent — its card says it is no longer current and offers only
  Dismiss. One tap sends once; the confirmation is shown every time, with
  nothing hidden in the text it shows. Offers are held back for now while they are finished. Never more than one
  offer every ten minutes, and at most five prepared a day, counted across
  your Mac and your cloud computer by your own day. It learns from what you
  do with its offers, with nothing to rate: a draft you use makes that kind
  of help more likely next time, *Not now* a little less, and *Not this kind
  of thing* stops that kind of offer for a month. It asks at most sixty questions a day, on the cheapest model your
  plan or key offers, and a message from someone you have never written to
  needs more than a number or a date in it to cost one. Switching a source
  off stops it at once and deletes what Moe kept of it; a Composio service
  is read only once it is actually connected. A conversation that was
  settled and flares up again is noticed again. With a cloud computer, it keeps noticing while
  your Mac is shut — in the services it can reach from there, such as Gmail
  and your calendar; chats that live only on your Mac wait for it — and both
  keep one list, so nothing is noticed twice or lost.
- **unreleased (2026-09-24)** — **Moe reads the sign-in code from your
  email.** When a site emails a code to sign you in, Moe finds the box,
  reads the code from the fresh email in your connected mail and enters it,
  instead of stopping. It also recognises plain "code" boxes it used to
  miss. And Moe now sees every account you connected for a service. Before,
  a second Gmail could be invisible to it.
- **unreleased (2026-09-24)** — **Moe learns from every conversation, not
  every tenth.** After each exchange Moe notes anything new and lasting you
  told it about yourself, your people and your work, in the background, on
  the brain you chose, and the same on your cloud computer while your Mac
  sleeps. Before, it remembered only when it decided to write something
  down, or when it reread the conversation every ten turns (now every
  twenty, since it no longer depends on it). What it kept shows under the
  answer as *Noted: …* with **Undo**.
- **unreleased (2026-09-24)** — **Moe's background reading runs on the
  cheapest model your plan or key offers.** Learning from your conversations,
  the follow-up pass at the end of one, noticing situations in your
  messages, planning what to read from a connected service, checking on a
  watch, and naming a conversation no longer run on the model you chose for
  conversation on a ChatGPT plan or an API key;
  they use your provider's cheapest model (on a custom or local endpoint,
  your chosen one, since there is nothing else to pick).
- **unreleased (2026-09-24)** — **What Moe learns from a conversation is
  only ever what you said.** The result of a job Moe ran in the background,
  a page it read, or an earlier conversation it was reminded of after a
  restart is never taken as something you told it, and neither is text you
  pasted or quoted. A fact is kept only when every name and number in it
  is one you said and a second quick check finds nothing in it you did not
  say. A fact you deleted, or a more detailed version of it, is no longer picked up again,
  and *Noted* always sits under the answer it came from, even once you have
  moved on to the next question. Updates such as "I moved to Queens" are no
  longer mistaken for something Moe already knew. On your cloud computer,
  learning waits until your memory's key has arrived from your Mac and never
  slows your messages reaching the Mac.
- **unreleased (2026-09-24)** — **The premium voice comes back after a
  blip.** When the connection drops for a few seconds, Moe now returns to
  the premium voice at a sentence boundary within a few seconds of the
  connection coming back, instead of staying on the Mac's voice for a full
  minute, and says once, quietly, why the voice changed. Running out of
  credits is handled as before.
- **unreleased (2026-09-24)** — **A routine that keeps failing tells you.**
  If a routine you asked Moe for fails twice in a row, Moe says so in one
  plain sentence and offers to look into it; again at the seventh failure,
  then every two weeks while it keeps failing. Moe's own background jobs
  stay quiet as before, and the developer instructions Hermes used to add
  to a failing routine's message are gone.
- **unreleased (2026-09-24)** — **Your routines reach you, and think with
  your model.** A routine you ask Moe for on the island is always delivered
  to you; before, one could be filed where nothing ever showed it. Routines
  made before this, and before routines started using your conversation's
  model, are brought up to date the next time Moe starts: they report to
  you and run on your own model rather than the cheapest one.
- **unreleased (2026-09-24)** — **The end-of-conversation follow-up check
  runs.** When a conversation ends, Moe reads back over what you said for
  things left open and comes back to them later. Until now it never did: it
  read Moe's own instructions along with your words, ran out of room after
  one turn, and stopped without saying so. It now reads only your words.
  The Memory section no longer says this check saves things about you; it
  looks for follow-ups, and the ten-turn read-back is what remembers.
- **unreleased (2026-09-25)** — **Teach Moe its name no longer calls a
  normal voice too quiet.** It was judging clips against a level from
  before Moe listened for its name without Apple's voice processing, so
  about half of ordinary "Hey Moe"s were turned away. Clips are now judged
  the way the wake word hears them, and a quiet one is kept with a note
  instead of refused; only nothing heard, too short or distorted asks for
  a retake.
- **unreleased (2026-09-24)** — **Teach Moe its name is a card now.** One
  phrase at a time in large type, a meter that shows Moe hearing you, a tick
  for each clip it keeps, and a plain reason with **Try again** when one is
  too quiet, too loud or not heard at all. Pause, redo the last clip, or
  cancel with nothing changed at any point; the result shows your "Hey Moe"s
  caught and sound-alikes let through, before and after. Sending the clips to
  the Moe team and forgetting them moved into the card.
- **unreleased (2026-09-24)** — **Mute stays on until you turn it off.** The
  end of an answer no longer unmutes you (it did six times in half an hour
  for the owner); a muted conversation waits instead of timing out, closing
  after ten minutes untouched. Holding the talk key talks through a mute
  without lifting it; the start-a-conversation shortcut, the button and the
  end of the conversation lift it, and every change is logged with its
  cause. Muted is now a red **Muted · tap to talk** pill on the island, and
  a red tab under the notch when the island is folded; Chat mirrors it.
- **unreleased (2026-09-24)** — **Signing in with ChatGPT now starts on
  GPT-5.6 Sol**, on your Mac and on your cloud computer. It used to start on
  GPT-5.5, which OpenAI retires from ChatGPT on every plan on October 14. If
  you picked a model yourself, Moe keeps it; with your own OpenAI key nothing
  changes, because the key still reaches GPT-5.5.
- **unreleased (2026-09-24)** — **Moe in your Chrome (ticket #13).** A new
  Connections row sets up the Memoe extension, so Moe can work in your own
  Chrome — in its own *Moe* tab group, only on turns you start — when a site
  blocks Moe's own browser or you ask. The Fix card for a missing extension
  now has a **Set up Chrome** button instead of only explaining.
- **unreleased (2026-09-24)** — **A breath after a whole sentence is waited
  out a little longer.** The words at a pause are now read for meaning
  (`TurnSemantics`): a request that could end or go on holds the reply 0.3 s
  longer, a whole answer ("yes", "not yet") 0.3 s less. Turn bench test split:
  cut-offs 26.2 → 23.1 %, "complete clause, more coming" 61.2 → 53.7 %; reply
  p50 1441 → 1717 ms (short answers 1389 → 1123 ms). The on-device model's
  vote and learning the owner's own pause length are built and off; every
  pause the owner talks through is now kept on the turn trace, and in the
  debug clips when those are on, as a labelled example.
- **unreleased (2026-09-24)** — **Two accounts of one service both work.**
  With a work and a personal Gmail connected, Moe can read or send from
  either one: name it and Moe uses it. Before, only one of them was ever
  reached, and asking Moe to send an email could fail with *the send tool
  isn't available* even though Gmail was connected. Moe now also finds the
  way to any connected service's actions instead of giving up when the one
  it wanted isn't in its list.
- **unreleased (2026-09-24)** — **Ticket #12: Moe's answer shows with the
  transcript, a spent premium voice is said, and a browser no longer flips
  echo cancellation.** With the transcript on, the
  island now opens when Moe starts to answer, not only when you talk, so the
  words are there to read while it speaks; before, a spoken answer never
  appeared under the default setting. When the premium voice ran out of
  credits, every sentence was first refused by the service and then read in
  the Mac's voice, with nothing said; now Moe switches at the next sentence,
  stays switched, and says so once. And a browser opening the microphone for
  a moment no longer turns echo cancellation off and on — on the owner's Mac
  Chrome did it eight times in half a minute, and each switch restarts the
  audio, which stops whatever Moe is saying at that moment.
- **unreleased (2026-09-24)** — **Moe carries on once the switch is on.**
  After a Fix card's **Open Settings**, or when you say yes to Moe offering
  to open the setting, Moe watches for the switch and, the moment it is on,
  picks up where it stopped — no need to ask again. Moe opens System
  Settings itself only while you are in a conversation you started. See
  [When something needs a switch turned on](#when-something-needs-a-switch-turned-on).
- **unreleased (2026-09-24)** — **The playground speaks in Moe's voice
  again.** Holding space on the playground started two conversations at
  once, the playground's and the site-wide island's, so two answers were
  spoken over each other and the per-minute voice allowance ran out twice
  as fast. Any sentence past it, or any brief hiccup from the voice
  service, was read by the browser's own voice instead. Now one press is
  one conversation. Hiccups are waited out and retried in Moe's voice. And
  a browser that hides which page it came from is no longer refused the
  voice for the whole visit.
- **unreleased (2026-09-24)** — **Moe asks before it posts anywhere, and
  asks which you meant.** Filling in a form with your words and submitting
  it now asks first on every site: before, only sites Moe knew by name did,
  so a Hacker News post went out without a question. And when Moe offers
  two ways to do something (it finishes, or it sets things up so you
  finish), a reply that could mean either gets a one-line "which one?"
  instead of a guess. If still unsure, Moe leaves the last click to you.
- **unreleased (2026-09-24)** — **To check asks the way the question
  does.** A question that is not a yes-or-no one — *who*, *what*, *which*,
  *A or B?*, or a note that something is unclear — now shows a box for your
  answer, with *Doesn't matter* and *Skip*, instead of Yes and No; your
  answer is kept as something you told Moe and never rewrites the line it
  asks about. The card itself is tidier: its buttons no longer break
  mid-word in a narrow window (the row folds whole instead), the count no
  longer repeats *Moe isn't sure* under a heading that already says it,
  quotes are set properly, long questions use a smaller size, and the note
  about Away's cloud copy stays off this section.
- **unreleased (2026-09-24)** — **Talking over Moe mid-sentence is heard.**
  Silero calls the canceller's residue of Moe's own voice speech from the
  reply's first word to its last, so a person joining it made no new VAD
  onset and was never listened to: on the turn bench 258 of 337 missed
  interruptions were that. The noise-floor gate now reports a voice rising
  10 dB over the last ~2 s (`.rose`), and over a playing reply that opens an
  onset like an edge — words, then the judge — without the first-word duck.
  Test split: missed 56.1% → 29.7%, false stops 12.5 → 14.4 per 10 min,
  stop p50 545 → 554 ms (`~/moe-voice-notes/barge-onset.md`).

- **unreleased (2026-09-23)** — **Moe says why, and offers the fix.** When
  something fails because a permission is off, a connection needs signing in
  again, or the screen helper has stopped, a Fix card on the island and in
  Chat says what is in the way and opens the exact System Settings page (or
  Connections, or the sign-in) with one press. It names the right app,
  including CuaDriver for screen control. See
  [When something needs a switch turned on](#when-something-needs-a-switch-turned-on).
  The card names only apps, folders and connections it recognises, never
  text a tool sent back.

- **unreleased (2026-09-23)** — **Moe knows what time it is.** Every
  message now starts with the time where you are, so a meeting that ended
  this afternoon is no longer read out as "a call at 2 today" at six in
  the evening. The calendar Moe keeps ready is split into what is over,
  what is on now and what is coming up, with end times and "all day" for
  all-day events. And what Moe learns from your messages keeps real
  dates: "tomorrow at 10" in a message from Monday night is remembered as
  Tuesday at 10:00, not as whichever day Moe happened to read it, and the
  picture of your life on the Memory page never says "today" or
  "tomorrow" (ticket #9).

- **unreleased (2026-09-23)** — **Four things that stopped working, fixed.**
  **Reset and ask again** and the **Fix** buttons for Accessibility did
  nothing since the rename to Memoe; they reset and ask again now. The
  microphone button is on the island for the whole of a spoken conversation,
  not only while Moe works. Every answer on the island has ▶ ⏸ ↺ and a ⋯
  menu, as in Chat, and Chat's answers gain the ⋯. And an answer that ends
  on "one sec while I…" with nothing happening gets one nudge to carry on.

- **unreleased (2026-09-23)** — **Moe finishes what it starts.** Asked
  for an exact price, Moe used to try one route, and when that route came
  up empty, give a rough range instead. Now a failed route is a reason to
  try the next one, and it keeps going until it has the real answer or
  something only you can give. See
  [Moe finishes what it starts](#moe-finishes-what-it-starts).

- **unreleased (2026-09-23)** — Premium voice: the connection is re-opened
  when you start talking if it has sat idle, instead of on the answer's
  first sentence (that cost 0.8–2.4 s after ten quiet minutes); the half
  second of silence the service leaves at the end of every answer is cut
  to a natural stop, so Moe finishes, and the follow-up window opens, about
  0.4 s sooner, while the pause between two sentences is kept; emoji and
  symbols are no longer read aloud.

- **unreleased (2026-09-23)** — **"Hey Moe" hears you more often and wakes
  by mistake less.** A new wake word model, trained on 250 more voices in
  many accents (British, Australian, Indian, Nigerian, Singaporean,
  Filipino, and speakers of other languages saying it in English), on your
  own recordings, and on hours of meetings where nobody says it. Measured
  on voices and recordings it never trained on:

  |  | before | now |
  |---|---|---|
  | heard you say "Hey Moe" | 64% | 77% |
  | heard other voices say it | 74% | 81% |
  | answered other voices' sound-alikes ("hey Joe", "hey Mona") | 23% | 5% |
  | answered your own sound-alikes | 8 of 30 | 8 of 30 |
  | woke during ordinary talk | about once in 5 hours | none in 9 hours |

  If you had taught Moe its name, that setting belonged to the old model
  and is set aside; *Teach again* fits the new one to your voice.

- **unreleased (2026-09-23)** — **Pause, resume and restart, everywhere.**
  ⏸ ▶ ↺ on the answer being said, in Chat and on the island; ▶ on a paused
  answer carries on from where it stopped instead of starting over. A tap
  of the hold key now really pauses: it had been read as a hold, which cut
  the answer and sent whatever the microphone half-heard as a question.
  And a **transcript** button on the island shows your words as they are
  heard while Moe works.
- **unreleased (2026-09-23)** — **A mute ends when the answer does.**
  Muting during a long task left you muted after Moe answered, so the
  follow-up window opened unable to hear you and closed while you were
  replying. Now the answer's end unmutes you and the window listens for
  its full length; a mute you set inside the window still holds.
- **unreleased (2026-09-23)** — **Mute yourself mid-conversation.** A
  microphone button on the island, and Mute in Chat, stops the room reaching
  Moe while it works and talks; the talk key unmutes.
- **unreleased (2026-09-23)** — **▶ reads any answer aloud, and a tap
  pauses it.** Every answer in Chat has a ▶ beside Moe's name; the hold key
  pauses and resumes it the way it does a spoken reply, and that now works
  on answers to typed questions too, which a tap used to end. Also fixed:
  pasting a long message with no question in it could get a summary of your
  day back instead of an answer to what you pasted.
- **unreleased (2026-09-23)** — **Knowing when you are done, and when you
  are interrupting.** Moe now decides how long to wait after you stop from
  how finished you sounded, starts on your request sooner and holds the
  answer instead, so a pause for breath is joined to the rest and a finished
  question is answered sooner. Talking over Moe takes two words or one word
  that means stop; Moe checks it is not hearing its own echo or a distant voice
  before it stops, fades rather than cuts, and after a false alarm carries on
  in place or restarts the sentence.

- **unreleased (2026-09-23)** — **"Did you get my Telegram?" gets the
  right answer.** Checking Telegram or WhatsApp used to report only your own
  account, so Moe on the Mac said it was not connected while its bot was
  answering you there. It now says the bot is connected and looks up those
  chats when asked.
- **unreleased (2026-09-22)** — **Memory: one question at a time, and
  talking it through with Moe.** *To check* is a single card — Yes, No,
  Something else…, Skip, *1 of N*, keyboard Y/N/E and ←/→ — ending in *All
  caught up.* Hovering a line no longer re-wraps it: where it came from
  sits faintly under it and its actions in a column of fixed width. Every
  section has **Go through with Moe**, every line **Discuss**, and the list
  **Review everything with Moe**, each opening Chat with a draft naming the
  memory files; Moe can now confirm, correct, delete, add, restore and
  answer lines while you talk. New lines are shorter (*Name — who they
  are*, a few words), *the user* is shown as *you*, and
  `python3 ~/.moe/learn/shorten.py` (a dry run unless `--apply`) shortens
  lines learned before.
- **unreleased (2026-09-22)** — **The Memory page has its own list of
  sections.** Down the left: *You*, *People*, *Right now* and *To check*
  with their counts (*To check*'s in a small pill), and *Past*, *Open
  folder* and *Your notes* at the foot; the right side shows one section at
  a time, with its name, one line about it, and its lines between thin
  rules. **+ Add something Moe should know** under *You*, *People* and
  *Right now* adds a line of your own. *To check* now says **Yes**, **No**
  and **Edit** on a line and **Answer** and **Skip** on a question. Moe's own
  notes from your conversations, which used to be *Also remembered*, are
  **From your chats**. Editing in place, Undo and the keyboard work as
  before. See **Memory › The Memory page**.

- **unreleased (2026-09-22)** — **Voice in a noisy room.** A sound that is
  not words (a fan, a dish, a cough, the TV's hum) no longer stops Moe,
  holds its answer or reopens your turn: it only quietens Moe for a moment
  while it listens, and only words take the floor, whether Moe is talking
  or still thinking. Moe now knows you have finished when your words stop,
  not when the room goes quiet, and a noise no longer resets the wait after
  a mid-sentence pause. It learns how loud the room is and lets go of sound
  with no words in it without answering it. Premium speaks a passage at a
  time, steadier from sentence to sentence, and Settings › Voice shows the
  voice that is actually speaking. See **Talking to Moe › Interrupting**,
  **Talking in a noisy room** and **Moe's own voice**.

- **unreleased (2026-09-22)** — **The product is called Memoe; the assistant
  is still Moe.** The app you install, the download, the site and your account
  are Memoe; the thing you talk to, the wake word and the voice are Moe, so
  "Hey Moe" is unchanged and nothing you say to it changes. These pages now
  say Memoe where the sentence is about the app you download, update, pay for
  or erase, and Moe wherever it is about the assistant that listens, speaks,
  remembers and acts. See **Memoe, in short**.

- **unreleased (2026-09-22)** — **Memory is one calm list, and every line
  is corrected where it stands.** The page that opened on a summary, with
  cards, marks and *Fix or forget…* sheets, is now a plain list of lines
  under *To check*, *You*, *People*, *Right now* and *Also remembered*.
  Click a line to edit it in place; **Return** saves, **Esc** cancels, an
  empty line is forgotten with a few seconds to undo. Where a line came
  from, and its **×**, appear only when you hover. *To check* takes an
  answer on the line and has **Right** and **Edit** instead of sending you
  to Chat. **Past** (with **Restore**), **Open folder** and **Your notes**
  sit at the foot. **Open folder** now shows USER.md and MEMORY.md beside
  everything Moe learned from reading, in one folder. Lines from Moe's own
  memory save instantly too, questions say *you* instead of *the user*,
  and Moe now writes its notes about you as plain facts rather than in its
  own voice. See **Memory › The Memory page**.

- **unreleased (2026-09-22)** — **Check these asks about five things, and
  your edits stick.** After Moe first learned about one person it asked
  about ten things at once, most of them marked *new* only because
  everything was new. Now it asks about at most five, disagreements first,
  and nothing is *new* the first time Moe learns about you. The picture of
  you at the top of the Memory page is built from what stays true, with at
  most three things happening now, and no longer includes things that
  already happened. A line you correct, or tell Moe is right, is yours:
  no nightly tidy merges it away, moves it to *Past*, or asks about it
  again. See **Memory › The Memory page**.

- **unreleased (2026-09-22)** — **What Moe learns from your messages is
  now short, current and checked.** A year of one person's WhatsApp had
  become about a hundred and forty lines, most of them events long over,
  the same trip told seventeen times, one friend under four spellings, and
  a few things that should never have been kept, a phone number, a street
  address, a health line. Moe now keeps only what would matter in six
  months, keeps facts and events apart and moves an event to *Past* about a
  month after it ends, counts one person or one trip once, asks you when
  two things disagree, never keeps contact, payment, money or health
  details at all, and tidies every night into a short picture of you that
  it reads first. It also reads your newest messages first: a long history
  used to be read from the oldest end and stopped months short of today, so
  nothing about what you are doing now was learned. See **Memory › Where
  what Moe knows about you comes from**.

- **unreleased (2026-09-22)** — **Memory is a page you can read at a
  glance.** It used to list every single thing Moe had learned, about a
  hundred and forty lines on a busy Mac, each with two tags and a button.
  Now it opens on Moe's short picture of you, with **Correct**; then the
  five people it is surest of; then **Check these**, the questions and the
  new or doubtful things Moe wants you to look at. The full list, past
  events included, is behind **See everything Moe has kept**. **Reveal
  files**, which opened two Finder windows, is now **Open folder**, which
  opens one. See **Memory**.

- **unreleased (2026-09-22)** — **Away: your machine says "asleep" instead
  of spinning, and is called by its name.** Your machine rests after
  fifteen quiet minutes, which is normal, but Settings › Away showed a
  spinner with no words for it for as long as you looked. It now says
  *asleep*, with one quiet line on how it wakes, and turns to *running* by
  itself when it does. Your devices list and our support tools called it
  "another Mac"; it is now *Your machine in the cloud*. On a Claude plan it
  thinks with the same Claude as your Mac, by its current name (Sonnet 5
  unless you chose otherwise), where before it was set to Sonnet 4.6
  whatever your Mac used. **Memory › Reveal files** now shows the profile
  folder that most of the page comes from, not only Moe's two small memory
  files, and the page says where each part is kept. See **Away** and
  **Memory**.
- **unreleased (2026-09-22)** — **Cloud computers get a second processor.**
  A cloud computer waking from sleep used to share one processor between
  answering your first message and its own start-up chores, and ran out of
  speed partway through. New cloud computers now have two, so both happen at
  once; existing ones are moved across once, by us. Nothing changes in what
  you pay. See **What your cloud computer does**.
- **unreleased (2026-09-22)** — *Internal.* The admin's Cloud cost page
  prices the new machine: shared-cpu-2x with 1 GB in `iad` is $6.39 a month
  (Fly's own figure) and about $7.39 from 1 October 2026 (derived); São Paulo
  $10.32, then about $11.94. See `docs/ADMIN.md`, Money, which also has the
  one command that resizes a machine made before the change.
- **unreleased (2026-09-22)** — **A sleeping cloud computer answers your
  first message much sooner.** When your cloud computer had been asleep, the
  first message after the quiet spell could take several minutes to answer:
  it spent most of its start-up doing its own housekeeping, and by the time
  it reached your message it had been slowed right down. It now does that
  housekeeping in a fraction of the time, and its other start-up chores
  now wait behind the work of answering you. This
  reaches your cloud computer with its next update. See **What your cloud
  computer does**.
- **unreleased (2026-09-22)** — *Internal.* The admin's Cloud cost page
  knows Fly's prices change on **1 October 2026**, when memory goes from about
  $5 to $6 per GB a month: a running machine in `iad` is $5.70 a month until
  then and about $6.70 from that day. Until the change the page shows today's
  price with the coming one and its date beside it, on the price table and on
  each person's cost card; on the day it switches by itself, with no deploy.
  It also names the dearest region correctly — São Paulo, not Mumbai. See
  `docs/ADMIN.md`, Money.

- **unreleased (2026-09-20)** — **Everything you connect can now teach Moe
  about you.** Moe has always offered, the first time you connect something,
  to read it back once and then keep up with it — but only for the apps on
  this Mac. Sign into GitHub, Slack or Notion on the Connections page and
  you were asked nothing, and Settings › Running in the background ›
  Learning about you had no row for it, so there was no way to say yes
  later either. Every service you connect now gets the same offer and the
  same two switches, and the daily pass reads it: what it holds that is
  structure — your repositories and organisations, your channels, your mail's
  labels — never messages, rows, documents or anyone's personal data, and
  never anything that writes. A service you have not signed into is not
  offered, because there would be nothing behind it to read. See **Running
  in the background: Learning about you**.
  Reading a service back had also stopped working altogether some time ago,
  on every service, without saying so: Moe asks its engine where a service
  is configured, the engine moved that answer to a different place, and every
  read was quietly skipped. Moe now looks in both places, and says so plainly
  if a future engine has neither, rather than reporting a successful run that
  learned nothing.
- **unreleased (2026-09-20)** — **Deleting your cloud account no longer leaves
  your chat bots pointed at it, and a channel that is receiving nothing says
  so.** Deleting the account tore down the cloud but left behind the note
  saying "the cloud answers Telegram" — so the bot kept sending to an account
  that no longer existed, this Mac would not take over because the note said
  the cloud had it, and Connections kept reading *Connected* the whole time,
  with messages piling up unanswered. Deleting now clears those notes, so this
  Mac picks the channel straight back up. And the row no longer trusts the
  address alone: Moe asks the chat service whether its messages are actually
  getting through, and when they are not, the row says so and how many are
  waiting instead of showing green. See **Away — Moe when your Mac is
  closed**.
- **unreleased (2026-09-20)** — **Scanning the WhatsApp code now says so,
  while you are watching.** You scanned the code, your phone said the
  device was active, and Moe went on showing the used code and then a row
  reading "the link to your phone has dropped — link it again", over a link
  that was seconds old and working; it turned green only minutes later,
  when the screen happened to be read again. Moe now says "Linked" the
  moment your phone accepts the code, tells you it is taking your chats
  over, and settles the row to what is true without anything being pressed.
  A link that is still coming up reads as coming up, never as one that has
  dropped, and Moe no longer suggests quitting it while it is restarting
  itself. See **Your own WhatsApp and Telegram** and **WhatsApp**.
- **unreleased (2026-09-20)** — **Moe stops asking permission to answer its
  own questions, and never says "Hermes".** Asked "are you connected to my
  Gmail and GitHub?", Moe put up a permission sheet titled *Hermes* over the
  very tool that answers that question. The sheet is for tools Moe cannot
  vouch for, and Moe's own tools were reaching it because each new one had to
  be added to a list by hand — the third time that has happened. The list is
  now read from Moe's own tools, so one can no longer be forgotten, and when
  the sheet does appear for something genuinely unknown it names Moe, which
  is whose tool it is. See **Before anything goes out**.
- **unreleased (2026-09-20)** — **Moe's browser is its own application, and
  it goes away when the job does.** Moe used to run a hidden second copy of
  your own Chrome to browse as you, and your Mac counted that copy as
  *Chrome*: while it lived, sometimes for days, your Chrome would not open
  from the Dock and would not quit. Moe now browses in a browser of its own,
  which your Mac never mistakes for yours; your Chrome runs hidden for a
  fraction of a second to hand over your logins, and is gone before Moe's
  browser starts. Moe's browser closes a couple of minutes after the last
  job, when Moe quits, and if one is ever left behind, the next Moe closes
  it. See **Moe's own browser**.
- **unreleased (2026-09-20)** — **Moe knows your name from the start.** The
  name on your Mac account is written into what Moe knows about you the
  first time it starts, once; a name you set yourself wins, and one you
  removed stays removed. Asked who you are on day one, Moe now has an
  answer. See **Memory: what Moe knows about you**.
- **unreleased (2026-09-20)** — **Your cloud computer knows what you are
  connected to.** Asked about a service connected through Composio —
  Cloudflare, say — Moe Away used to look for a tool by that name, find
  none and say there was no integration; asked to check your connections,
  it listed only the apps on your Mac and queued a check of each. It now
  has the same list your Mac's Moe has, sent across sealed like everything
  else, looks a service up through Composio before saying it is not
  connected, and answers "check my connections" with the Composio services
  by name and the Mac's apps marked as the Mac's. It also no longer starts
  a sign-in on its own to find out whether something is connected. The
  skills you switched off on the Mac now stay off there too. See **How Moe
  knows what is connected** and **What your cloud computer does**.
- **unreleased (2026-09-20)** — **Moe's memory read-back runs on your own
  brain again.** The ten-turn read-back that turns a conversation into
  memory had been moved to the cheapest model your provider offers (17
  September) to save on the plan; it saved less and once mis-remembered, so
  it follows the conversation's model again, on every provider. See **Memory:
  what Moe knows about you**.
- **unreleased (2026-09-20)** — **Moe's instructions about remembering
  point at its memory, not at files.** The persona file told Moe to append
  what it learned to the note files nothing reads after setup; a week of
  use left its memory of you nearly empty. It now says to save with its
  memory tool, facts about you and notes about how you like things done
  each in their place, silently, in the same turn — and the old paragraph
  is taken out of an existing Mac's file once. See **Memory: what Moe knows
  about you**.
- **unreleased (2026-09-20)** — **Reminders and the calendar heads-up run in
  the cloud again.** On a freshly made cloud computer, three of Moe's own
  background jobs (the proactive pass, the calendar heads-up, the loop check)
  failed to install at first boot, so while the Mac was closed those only ran
  on the Mac. They install now. Existing cloud computers pick this up with
  the next cloud image.
- **unreleased (2026-09-20)** — **The Away page in every state, with no
  button that cannot act.** Pressing **Get Away** put *One moment…* on the
  Away+ card too; the plan cards stayed live under the steps that were
  holding the payment back; the open payment page drew nothing at all; a
  "continue in your browser" line outlived the payment; and while the
  machine was being set up the page drew every technical section and the
  manual enrolment's own screen under the list. Now: only the pressed card
  says *One moment…*; the cards are put away while steps or a payment are
  in the way, and the one card names the plan; the open payment page has
  *Waiting for your payment…* with **Check again** and **I closed the
  page**; a note at the foot of the page goes when the page moves on; and
  setting up is the list and **Stop**, with everything else behind **Show
  the details…**. *Your chats in the cloud* now says how Moe already
  reaches you first, links to Connections, and asks for no number on this
  page. See **Settings › Upgrade**, **Before you start Away**, **Setting up
  your cloud computer** and **Settings › Away, once it is running**.
- **unreleased (2026-09-20)** — **Blank lines in *About me* are no longer
  "facts".** On a fresh Moe the unfilled form lines, *Name:*, *What I do:*
  and four more, were carried into what Moe knows about you as if you had
  answered them with nothing, and sat at the top of every conversation for
  a week; asked who you were, Moe read *Name:* followed by nothing and said
  your profile was blank. Only lines you have written something after are
  carried now, and the empty labels an earlier Moe took in are dropped the
  next time Moe starts, here and on your cloud computer. The read-back Moe
  does after a conversation, on a small model, is also told plainly that
  only writing a memory keeps it: twice in that week it found something
  worth keeping and said so instead of saving it. See **Where what Moe
  knows about you comes from**.
- **unreleased (2026-09-20)** — **Setting up your cloud computer waits for
  it.** A machine is not switchable-on for most of its first minute, and
  the setup used to ask once, ten seconds in, and then stop at *Making Moe
  a home in the cloud* with a ticket for a machine that was fine. It now
  asks again every few seconds for up to two minutes, and a machine that
  really will not start is reported as that, not as "no machine". On our
  side, one payment could make two machines when Stripe sent two events at
  once; it makes one. See **Setting up your cloud computer**.
- **unreleased (2026-09-20)** — **The welcome card asks only for what you
  haven't done.** A messaging app connected before you paid, or a voice
  already set to Cloud, no longer sits at the top of *You're on Away* as a
  thing to do first. See **Settings › Away, once it is running**.
- **unreleased (2026-09-20)** — **No stray asterisks on the notch.** A reply
  with bold or italic in it showed its `**` markers on the island unless it
  also held a link. The island now reads a reply's formatting the way the
  Moe window does.
- **unreleased (2026-09-19)** — **One line while Moe works.** Hovering the
  notch mid-job now shows a single row, what Moe is doing, how long, the
  speaker button and **Stop**, instead of the whole conversation with a raw
  step under it. The steps are listed in Moe's own words ("Searching your
  files") rather than as tool arguments, and once the answer lands they sit
  folded under it as **what it did · 3 steps · 48 s**. See **While Moe
  works, the notch shows one line**.
- **unreleased (2026-09-19)** — **The notch's chat box is always dark.** On a
  Mac in light mode the "Ask Moe" box inside the black panel could come up
  light. The island is dark in both appearances now, box included.
- **unreleased (2026-09-19)** — **The notch opens on hover while Moe works.**
  Hovering the notch mid-job used to show nothing until the job was done, or
  only while Moe was driving your Mac or its browser. The rest of a job,
  thinking, searching, reading mail, was the one time the dropdown would not
  come, which is exactly when the stop and **Work silently** are on it. It
  opens on hover in every state now.
- **unreleased (2026-09-18)** — **The app wears the site's colours.** Moe's
  windows, Settings and the welcome now use the same paper, ink and slate as
  memoe.app, in light and dark, and Moe's replies are set in the same sans as
  everything else rather than a serif. The island stays black glass under the
  notch, as before. Nothing moved and no switch changed; it is the same app in
  the same clothes as the page you downloaded it from.
- **unreleased (2026-09-19)** — **A finished helper says the outcome first.**
  When a job Moe handed off came back, Moe said "here's the synthesis", then
  read the helper's notes, then wrote a thirty-page report nobody asked for,
  then gave the synthesis — heard as "done", two minutes of thinking, "done"
  again. Now the first sentence is the outcome, there is no side work, and a
  long result comes as the gist with the rest on offer.
- **unreleased (2026-09-19)** — **The first real lid test: a crash, fixed.**
  Twenty seconds into the lid closing, the thinking part's stream ended
  cleanly with no answer; Moe called that a finished turn, and on wake went
  to chime for it while the audio device was still coming back — and the app
  quit. A stream that ends quietly during a sleep is now picked up like one
  that breaks, and the chime no longer goes through an audio engine at all —
  it plays a small sound file, which simply does not sound if there is no
  device ready, rather than taking the app down.
- **unreleased (2026-09-18)** — **A question you closed the lid on is finished
  in the cloud** (Away). After a minute's grace your cloud computer takes over
  a question your Mac was working on, tells you on your chat and answers there;
  the Mac, opened later, is told the cloud has it and never doubles it.
- **unreleased (2026-09-18)** — **A question outlives a sleep.** Closing the
  lid on a question used to lose it: on wake, "Moe is taking too long to
  answer", with nothing kept. Now the Mac stays awake on its own while Moe
  works, a question cut off by a sleep is picked up once on wake, and one
  Moe was quit on is picked up within half an hour of relaunch.
- **unreleased (2026-09-18)** — **A scheduled job that could not do its work
  is blocked, not done — and Moe browses as the Chrome profile you pick.** A
  daily job asked to sign in to X and follow accounts found the browser
  signed out, wrote a report saying so, and then marked itself quiet; the
  report was thrown away and the job read as having run fine. Now a report
  is a report even with a "nothing new" mark stuck on the end, a job that
  could not do its work shows as **blocked** with the reason and always tells
  you, jobs you set up run on the brain your conversation uses rather
  than the cheapest one, and "run it now" from a conversation works again
  on the Claude plan (it used to fail before starting). The signed-out browser had a cause of its own:
  Chrome had seven profiles, and Moe carried whichever one you had used
  last. **Settings › Permissions › Browse as** now picks the one Moe keeps.
- **unreleased (2026-09-16)** — **The docs page exists, and this file is
  its source.** docs.memoe.app is built from this file by
  `site/docs/build.py`, one page per `## ` heading, and
  `scripts/test-site-docs.sh` fails when the built pages are stale, when
  the docs host rewrite is missing from `site/vercel.json`, when dictation
  is mentioned anywhere, or when developer-only names reach a page. This
  file was rewritten end to end against the code on this date: every
  Settings pane is described with its real labels and defaults, the cloud
  section says what is true now (paying makes your cloud computer; it sleeps
  and wakes; there is no thinking allowance), and the history, the
  measurements and the internal names came out. The change log below is
  kept for the project and is not published.
- **unreleased (2026-09-15)** — **A problem with your account is told where
  you asked, and kept in Settings until you fix it.** A rate limit clears by
  itself, and Moe already says so and then waits. A cancelled sign-in, a
  revoked key and an account out of credit never clear — and until now they
  arrived as the provider's own line, which could carry part of your key in
  it, and then scrolled away, so the next question failed identically with
  nothing on screen saying why. Now each is said in Moe's words in the chat
  you wrote from, naming *your* provider and never another; an amber line on
  **Settings › Brain** says what is wrong and the one next thing to do; and
  **Settings › Connections** stops calling Moe's brain *Working* while it
  cannot answer. Both clear themselves the moment Moe answers anything, with
  nothing to dismiss and no restart. A question your provider simply refused
  is said in the chat and deliberately kept out of Settings, since there is
  nothing about your account to fix. See **When the account Moe borrows stops
  working**.
- **unreleased (2026-09-16)** — **One yes really does cover the conversation,
  and there is an "Allow everything this session" button.** A browser sheet
  said "approving also lets Moe send in this conversation without asking
  again" and then asked again on the very next reply — nine times in four
  minutes over one thread on X — because with Moe's Claude Code brain the
  grant was being written against an empty conversation id and never
  saved. It is keyed on the brain itself now and sticks. The same blind spot
  meant a bare "click Post" from a helper could go out with no sheet at all;
  the sheet now remembers which page the conversation is on. New on browser
  and screen sheets: **Allow everything this session** — every kind of
  moment, that conversation, until it has been quiet for an hour. The sheet
  itself now reads as a sentence with the code in its own block underneath,
  and names the site being acted on rather than the first link in the text
  (a reply on X that linked Product Hunt was headed "producthunt.com").
- **unreleased (2026-09-16)** — **A helper you hand a job to is no longer
  killed at ten minutes and reported as your "no".** A helper thinking with
  Claude Code never registered any progress with the part of Moe that
  watches helpers, so after ten minutes the watchdog cut the turn, ended
  the helper mid-task, and told Moe you had declined — three times in a row
  on one X reply job that had actually posted. Every step a helper takes
  counts as progress now.
- **unreleased (2026-09-17)** — **"Do it in the background" is real, on
  every brain.** Ask for a job in the background — a run of replies, a long
  search, anything you do not need to wait on — and Moe hands it off, says
  in one line that it is running, and gives you the conversation back.
  When the helper finishes, Moe tells you the outcome in its own words,
  spoken, the way a reminder arrives. Until now the hand-off held the
  conversation for the whole job on the Claude Code brain and, on an API
  key, parked the result until the next thing you said. Same on Claude
  Code, ChatGPT, or a plain key. See **Handing a job off** under *Driving
  your Mac*.
- **unreleased (2026-09-17)** — **Nothing stock is said while Moe works.**
  "Still on it", "Still going" and "Still handing part of this off" every
  twelve seconds are gone. What Moe says about a long job is its own account
  of it, and the island shows the running step as text the whole time. If
  Moe is quiet, it is quiet.
- **unreleased (2026-09-16)** — **Screen work gets 150 actions and 30 looks
  per task, not 20 and 10**, and both are settings. See *Driving your Mac*.
- **unreleased (2026-09-16)** — **A problem report gets two emails, not
  three.** "We're on it" when it is filed, "Fixed" with a few plain words
  when it is done. The plan-with-yes/no-links email in between is gone: it
  went to people who reported a problem and asked them to read a repair
  plan.
- **unreleased (2026-09-16)** — **Change your brain and your cloud computer
  changes with it.** Settings › Brain and Settings › Away ask the same question
  about two different computers, and nothing joined them: you could change what
  your Mac thinks with and your machine would carry on with whatever you gave
  it weeks ago, with no error and nothing on either page saying the two could
  disagree. Now a change here goes to your machine by itself wherever it can —
  a different model on the account it already has, a key you just pasted, or
  your ChatGPT sign-in — and where it cannot, the page says so at the moment
  you change it and offers the one click that finishes it: your Claude plan
  needs a sign-in of its own, a key you did not just retype is not sent off
  this Mac, and a model running on this Mac is somewhere your machine cannot
  reach. None of it appears if you have no cloud computer. See **Settings ›
  Brain**.
- **unreleased (2026-09-16)** — **One message at a time when setting up your
  machine's brain, and the one you can act on.** Picking *Your ChatGPT plan* on
  a Mac that had never run `codex login` showed a single run-on amber paragraph:
  forty words explaining why that way of doing it is the weakest of the three,
  then the only sentence that mattered, with the name of the program that ran
  printed at you twice. The page now shows one sentence, the one you can do
  something about, and never the program's own name. See **Away — what it
  thinks with**.
- **unreleased (2026-09-16)** — **Work silently.** Hovering the notch while
  Moe works on a spoken question now offers **Work silently**: no progress
  speech for the rest of that job, only the answer at the end, with the step
  still shown as text. The confirmation sheet's "press Send" is still said.
  Pressed again it reads **Talk me through it**. It resets for the next
  question.
- **unreleased (2026-09-16)** — **Talk hands-free: double-tap the talk key,
  tap to send.** With Moe idle, a double-tap of the key you hold to talk now
  starts listening with nothing held — the notch breathes and says *Listening
  — tap to send* — and a single tap sends what you said, however long you
  paused. Esc drops it. A double-tap while Moe is talking or working still
  stops everything, and a tap over a reply still pauses it.
- **unreleased (2026-09-16)** — **Connected through Composio means
  connected.** Moe no longer tells you Gmail, Calendar or Drive is not
  connected because the Mac's own route isn't set up; it asks Composio first,
  and checks for itself when you say you've just connected something.
- **unreleased (2026-09-15)** — **A chat app your cloud computer answers no
  longer reads as disconnected.** Handing Telegram, WhatsApp or Slack to your
  cloud computer takes it off your Mac on purpose, and the Connections list
  used to drop such an app from its answer entirely — so it came back as *not
  connected*, with a Connect button, over an app that was working. Where Moe
  had written you a sentence about one (*the cloud's connection to Slack is
  not open*), that sentence reached no screen. Those rows now say **Connected
  — your cloud computer answers WhatsApp, so it keeps working while this Mac
  is closed**, and name the app the way you do rather than by its internal
  name. **Check again** no longer contradicts that row by asking your Mac
  whether it is running an app your cloud computer holds — it used to answer
  *quit Moe and open it again*, which could not have helped. An offer to
  connect something stays an offer, with no status beside
  it. And where two different connections share a name, every screen now says
  which: *My own Telegram* and *WhatsApp on this Mac* are your own accounts,
  never the Moe you message. See **Chat apps, when your Mac is shut** and
  **Your own WhatsApp and Telegram, and the ones that only share a name**.
- **unreleased (2026-09-15)** — **Email Moe: Outlook and Yahoo work, by asking
  first.** Mail to your Moe address whose signature doesn't show it was
  written to Moe -- Outlook, Hotmail, Microsoft 365 and Yahoo never sign that,
  and a blind copy never has it -- is no longer ignored: Moe emails the sender
  "Did you send this to Moe?" with a code, and reads it on a YES. Replies in a
  conversation with Moe pass without asking for three days. Lines a signature
  doesn't cover are ignored rather than refused, a failed answer is said in one
  plain sentence, and the Email row says when emails had to wait to be
  checked because too many questions went in an hour. A reply that arrives
  twice counts once, a late YES or NO is told the question has expired, and
  writing again in that thread is ordinary mail rather than silence.
- **unreleased (2026-09-15)** — **What Moe does after an answer no longer
  takes your place in the queue.** When a reply finishes, Moe spends a moment
  going back over the conversation for anything worth keeping. That happened
  in the very session you talk to, so anything you said in the next minute was
  refused — and what appeared where Moe's reply goes was a line written for a
  developer: *another turn is still running for session 1e495ecf-d44; try
  again*. Twice in seventy-four seconds, on a real Mac. That work now runs in
  a session of its own, so you can keep talking while it happens; if Moe
  genuinely is mid-answer your next message waits for it rather than being
  refused, and anything Moe cannot finish is said in words, never in
  identifiers. See **While Moe is working**.
- **unreleased (2026-09-15)** — **When Moe can't answer, it says so instead of
  going quiet.** If your model provider is limiting how fast you can ask — your
  own plan's limit, or an API's — Moe used to say nothing at all while it
  waited and retried, for as long as ten minutes at a time, three times over.
  Worse, the notice it had written was thrown away when it finally worked, so
  you never learned where the time went. Now, any wait long enough to notice is
  said out loud in Moe's own words, naming *your* provider — *"I've hit the
  limit on your Claude plan — I'll answer as soon as it clears, in about 10
  minutes"* — and a brief stumble Moe recovers from on its own is still passed
  over in silence, because that is not worth interrupting you for.
- **unreleased (2026-09-15)** — **Answers that looked like machinery are no
  longer thrown away.** The rule that keeps Moe's plumbing out of your chat was
  reading the shape of a line and not who wrote it, so five kinds of real
  answer were being dropped before they reached you — a flight option written
  *(option 1/3)*, *Here's what I found (page 2/5)*, a total written
  `total_cost: $412`, a time written `check_in_time: 3pm`, and a sentence
  telling you to open */settings*. None of them arrived, and nothing showed
  that they had not. The rule now also asks whether the line *opens* the way
  Moe's plumbing opens — with one of its own symbols — and only then considers
  dropping it. See **What arrives in the chat is Moe's answer**.
- **unreleased (2026-09-15)** — **A conversation never loses what it
  remembers to a faster start.** Moe keeps a thinking session warm so replies
  begin sooner. A conversation that already had history could be handed one of
  those warm sessions and be pointed at its near-empty record instead — for
  good, not just for that reply. Now a conversation with history is never
  handed one; the warm start goes to a conversation that has nothing to lose.
- **unreleased (2026-09-15)** — **A WhatsApp link your phone has ended says
  so, instead of trying forever.** When WhatsApp logs the link out, the
  credentials it just cancelled are cleared and the row tells you to scan
  again. Before, they were left on the Mac, Moe read them as "still linked",
  and it restarted into the same refusal for as long as you left it on — with
  the only way out being to delete files by hand. See **Your own WhatsApp and
  Telegram, and the ones that only share a name**.
- **unreleased (2026-09-15)** — **The WhatsApp history you were promised is
  the history you get.** When you scan, your phone offers its past
  conversations; Moe asked for all of them and kept only what arrived in the
  first moments. It now keeps what your phone sends.
- **unreleased (2026-09-15)** — **Moe asks before it restarts for an update,
  and the Privacy Policy has a new version.** A new version still downloads
  quietly, but you no longer have to quit Moe to get it: once it is ready, the
  notch glows amber and the panel under it says *A new version of Moe is
  ready.* with **Restart to update** and **Later**, which puts the question and
  the glow away for a day or until Moe next opens. Tapping the glow opens the
  panel, unless a reminder is waiting, which plays first. It never asks or
  glows during a recorded meeting, while Moe is listening or speaking, or while
  it is working on an answer, glows even with *Let Moe bring things up on its
  own* off, and it never restarts by itself;
  quitting still installs the update, as before. Settings › About now says
  *Keeps itself up to date: a new version is downloaded quietly, and Moe asks
  before restarting to install it.* The Privacy Policy and the Terms are now
  version **2026-09-15.1**: the policy now says plainly that a report sent
  without saying who you are is not deleted with your account, and because
  that matters, anyone who agreed to 2026-09-10.1 is asked to agree again. See
  *Updating*, *Settings › About & Licences* and *Terms and Privacy Policy —
  when you agree, and to what*.

- **unreleased (2026-09-15)** — **Moe joins Login Items when you finish the
  welcome, not when it first opens.** Its two switches — **Start Moe when
  my Mac starts** and **Let Moe send problem reports** — now sit above
  **Take me to Connections**, where you see them before the welcome closes,
  and the problem-reports switch only moves for your own click, as in
  Settings › Privacy. *Erase Moe from this Mac* no longer puts Moe straight
  back in Login Items when the fresh copy opens. **Allow it** for Screen
  Recording no longer opens System Settings over macOS's own question. A
  new Mac now starts with its calendar heads-up (ten minutes) and Short
  replies on chat channels actually working, not only shown in Settings.

- **unreleased (2026-09-15)** — **A shortcut is not a talk press, and the
  Mac's own apps get the "learn about you?" question.** Holding the talk key
  as part of a shortcut (fn+Delete, right ⌘+Tab) no longer starts Moe, takes
  a picture of the screen or stops a reply; and granting Calendar, Reminders
  or Notes in System Settings, or switching on Chrome browsing, now asks
  whether Moe may learn from it, the way connecting a service already did.
- **unreleased (2026-09-15)** — **Pick the key you hold to talk.** Right ⌥
  is still where it starts, and **Settings › Voice › The key you hold to
  talk** now offers right ⌘, right ⌃ and fn / 🌐 as well. The change works
  at once, and every place that names the key — Say hello, the island, the
  Accessibility warning, the meeting hint — says the one you chose.
- **unreleased (2026-09-15)** — **The welcome recommends, and asks in the
  right places.** Still seven screens. *Give me something to think with*
  recommends a Claude plan and a ChatGPT plan equally — both marked
  **Recommended**, first, side by side — and Settings › Brain › Change
  account… does the same. *Say hello* now asks for **Accessibility** and
  **Screen Recording**, one button and one line each, both skippable.
  *What may I read to learn about you?* says what the daily pass does and
  recommends it: every connected source and the pass start on, and **Save
  and continue** with nothing touched is an answer; Skip still records
  nothing. The question comes again the first time you connect something:
  *Let Moe read … back and learn about you?*, once per source. *Connect
  your world* says what to connect first — this Mac's Calendar, Reminders,
  Notes and Contacts, then Google's Gmail, Calendar and Drive — and the
  Connections tab lists them in that order; the screen ends with **Start
  Moe when my Mac starts** (on) and **Let Moe send problem reports** (off,
  with **What is sent?** and **Report without saying who I am**).
- **unreleased (2026-09-15)** — **You choose how long Moe may work on one
  thing.** Settings › Brain has a new row, *How long Moe may work on one
  thing*: 5 minutes, 15 minutes, 30 minutes (the default, and what every Moe
  already had) or 1 hour, on the Claude plan. A task still going when time is
  up is stopped, and Moe now says so in plain words instead of an error
  message.
- **unreleased (2026-09-15)** — **Settings say what happens, in plain words.**
  Every switch that needed this page to be understood was relabelled; nothing
  behind them changed. Replies: *Say "yeah, on it" straight away* is now
  **Say "on it" as soon as I ask**; *Say what it is doing* is **Tell me what
  it's doing while it works**; *A small sound when a silent answer lands* is
  **Ding when a written answer is ready**; *A question typed in the notch
  opens the Chat page* is **Typed questions open the Chat window**; *Write
  typed answers to be read* is **Write answers to typed questions to be read,
  not heard**; *Open by itself when an answer lands* is **Open by itself when
  an answer is ready**. Background: *Let Moe get your attention* is **Let Moe
  bring things up on its own**; *Keep today's … ready* is **Check … every 10
  minutes**; *Background thinking* is **Let Moe think on its own, on my AI
  plan** (the line under the daily pass follows it); and the note at the foot
  of the tabs now says which switches start on instead of claiming nothing
  does. Voice: *Also move my mouse when Moe points at something* is **Move my
  mouse to what Moe points at**; *Let Moe take the screen when it has to* is
  **Let Moe bring a window to the front when it has to**; *Use Premium voice
  and hearing when your plan includes them* is **Use the sharper voice and
  hearing that come with my plan**; *Engine* under How Moe sounds is **Set of
  voices**. Meeting Capture's *Both capture* is **What the pictures show**;
  Brain's *Thinking effort* is **How hard it thinks**; Usage's *Context read
  back* is **What Moe re-read each turn**; and About's *Upstream* button is
  **Their website**. Sixteen labels in all.
- **unreleased (2026-09-15)** — **Dictation is put away for now, not gone.**
  Typing by voice — holding right ⌘ so your words land where your cursor
  is — is hidden while it is reworked: no key is watched for it, and its
  tab, its place in the sidebar, its welcome screen and the Brain row that
  picked its model are out of sight, including on a Mac whose settings had
  it switched on. The settings pane that held it is called **Voice** now,
  and the welcome is one screen shorter: seven screens, with four things on
  the first.
- **unreleased (2026-09-15)** — **Updates install themselves, and Erase is the
  one way out.** A new version of Moe is now downloaded quietly and put in
  place when Moe next quits — no window asking whether to install it, and no
  question about whether Moe may check. Moe never restarts itself to hurry an
  update; the next time it opens, it is the new version. Settings › About says
  so: *Keeps itself up to date: a new version is downloaded quietly and is in
  place the next time Moe opens.* And **Uninstall Moe…** is gone from About &
  Licences: it moved the app to the Bin and left your data behind, which was a
  second, different way out. *Erase Moe from this Mac* in Settings › Privacy is
  the one exit, and it now also takes Moe out of Login Items, as Uninstall did
  (it already stopped every background job). See *Updating*, *Erase Moe from
  this Mac* and *Settings › About & Licences*.
- **unreleased (2026-09-15)** — **Problem reports: nothing kept while they're
  off, everything readable after, and a way to send one without your name.**
  With **Let Moe send problem reports** off, asking for a report writes
  nothing at all — no logs, no conversation, not even a title — and Moe tells
  you to turn the switch on and ask again; a report an earlier version kept
  waiting on your Mac is deleted. Asking Moe to show you a ticket now reads
  back the version, macOS, plan, log lines and every word of its history. Many
  more kinds of key are kept out of a report (GitHub, Slack, Google, Telegram,
  Stripe, Composio and Fly keys, passwords in web addresses, cookies and
  private keys), your name, email addresses and your Mac's name are taken out
  of the log lines and of what Moe writes, and a long report is trimmed to fit
  — the start of the quoted conversation first — instead of being refused and
  lost. A new switch, **Report without saying who I am**, sends reports with
  no account, device, email or plan, up to five a day — at the cost of never
  hearing back, and they aren't deleted with your account. Settings › Privacy
  › **What is sent?** has the full list. See *When Moe itself breaks*.
- **unreleased (2026-09-15)** — **Background work leaves your plan alone,
  reminders find your phone, and a save never fails.** The daily learning
  pass now waits, like the half-hourly one, when your Claude or ChatGPT plan
  is nearly used up (past half of the five-hour or session window, or four
  fifths of the week), and the line under its switch says so. The first chat
  app you set up is ticked for reminders as soon as it is ready; later ones
  stay yours to tick, and one you untick stays unticked. The first read-back
  over a source now goes back a year rather than three (browsing stays 90
  days). And a memory save past the size limit is kept instead of refused:
  the oldest entries make room in what Moe reads every time, and stay kept.
  See *Running in the background*, *Reminders*, *Keeping up* and *Memory —
  what Moe knows about you*.
- **unreleased (2026-09-15)** — **A reminder Moe was interrupted in the middle
  of is no longer lost.** If Moe's thinking part restarted or crashed while one
  of your reminders was being worked on, the reminder simply never arrived and
  nothing said so — the schedule had already moved on to the next one. Moe now
  picks it up when it comes back and says it, once, as long as it is less than
  a quarter of an hour late; past that it is left alone, because a stand-up
  reminder delivered in the afternoon is worse than none. Moe's own background
  checks are not re-run this way, and the schedule is never moved: tomorrow's
  nine o'clock is still nine o'clock. See **Reminders**.
- **unreleased (2026-09-15)** — **A message that starts your sleeping cloud
  machine is answered in about half a minute again, not four and a half.**
  The machine was doing all of its own housekeeping — installing the
  background jobs it keeps and checking the connections it watches — before
  it would accept your message, and one of those steps sat for fifty seconds
  looking for something it was never going to find. All of it now happens
  behind the conversation instead of in front of it, so it cannot add to
  what you wait for.
- **unreleased (2026-09-15)** — **Only Moe's words reach your chat.** Messages
  Moe was never meant to send you — a redirect notice with a loop counter, a
  tip about slash commands, the internal name of each tool as it ran, and the
  memory system announcing itself by folder name — no longer arrive on
  Telegram or any other chat app. If something takes a while, Moe now says so
  once in plain words (*still on it*) with no tool name or step count.
  Interrupting Moe mid-answer works exactly as before; it just stops
  narrating that it happened. The chips and spoken commentary on your Mac,
  where watching the work is the point, are unchanged. The same is now true of
  the cloud computer that answers you when your Mac is shut, which is where
  these actually came from. See **What arrives in the chat is Moe's answer**.
- **unreleased (2026-09-15)** — **Moe can have an email address of your
  own: `yourname@in.moebot.app`.** Choose a name in Connections › Email, and
  mail to it reaches your Moe. Mail from the address you signed in with is
  recognised as yours, once Moe has checked it really came from there. Anyone
  else waits to be let in, and mail that can't be checked is ignored. Moe
  replies only to whoever wrote, in the same thread; it writes first only to
  you, and never to more than 50 a day. A long answer arrives as one email,
  or as a second one in the same thread if Moe takes more than two minutes.
  If an email from your own address can't be checked, Moe
  doesn't read it and says so on the Email row. A name you give up isn't
  anyone else's for thirty days. Not switched on until the owner of Moe's
  cloud sets up its mail. See *Email Moe at your own address*.
- **unreleased (2026-09-15)** — **Moe's email checks more than who wrote,
  and never loses a slow answer.** An email is taken as yours only when it was
  written to your Moe address, sent in the last two days, and not changed
  after it was signed, and it reaches Moe once. A reply that takes more than
  two minutes now arrives as a second email in the same thread instead of
  being dropped. Moe's own working notes and requests for your OK are never
  emailed, and the Email row says when either happened. Outlook and
  Microsoft 365 addresses can't write to Moe's email for now. See *Email Moe
  at your own address*.
- **unreleased (2026-09-15)** — **Moe spends less of your plan on work you
  are not waiting for.** During a meeting the live action-item check now
  runs every two minutes instead of every minute, and it, the recap,
  screenshot captions and sending the notes all use your provider's cheapest
  model; the notes themselves stay on the model you chose. Background
  thinking, the daily learn pass and Moe's memory and skill reviews also use
  the cheapest model, on every provider, not only on a Claude plan. A new
  Moe on a Claude plan starts on Sonnet rather than Opus; if you already
  picked a model, you keep it.
- **unreleased (2026-09-17)** — **The free month of Away, and its list, are
  gone.** Settings › Away shows the two plans and their prices again, and
  there is nothing to join or wait for. Nobody had been switched on, so
  nothing changes for anyone's plan.
- **unreleased (2026-09-15)** — **A cleanup Moe gave up on is where you can
  see it, and Disconnect keeps to its time.** A service whose cleanup at the
  broker Moe stopped retrying is now listed under *needs you* at the top of
  Connections with its Disconnect button — before, a service off the shelves
  was only findable by searching, so the button Moe told you to press could
  not be seen — and one whose name can't be looked up reads *A Composio
  service* rather than a bare short name. Disconnect now stops within its
  forty seconds however slowly the broker (or this Mac's keychain) answers,
  and says it couldn't reach Composio in time. A web address or host you
  typed with a token, password or path in it is kept out of refusals like a
  key; the Connections section now says exactly what a refusal can still
  show. See *Google, and about five hundred other services*.
- **unreleased (2026-09-15)** — **A watch your cloud computer can't keep is
  now said on your Mac.** A watch on a connection that never reached your
  cloud computer runs on the Mac alone — that was already so, but the only
  places that said it were the cloud computer's own logs. Now the cloud
  computer sends the list back, and the connection's row under Settings ›
  Connections carries one line: *Watched on your Mac only — your cloud
  computer doesn't hold this connection.* The row's status is unchanged — the
  connection is fine here — and the line disappears the moment the connection
  reaches the cloud computer and the watch starts there.
- **unreleased (2026-09-15)** — **What a fresh Moe starts with.** Reply
  length starts **Short**. A panel that opened for a silent answer now stays
  until you dismiss it. A question typed in the notch is answered in the
  notch, not in the Chat page. Moe warns **10 minutes before** something in
  your calendar, out of the box. Moe hears and speaks your Mac's own language
  when it can, English otherwise. And Moe starts with your Mac — it adds
  itself to Login Items once, on first run, and never touches that switch
  again. (The record of every default and why: `docs/DEFAULTS.md`.)
- **unreleased (2026-09-15)** — **Docs: the settings as they are.** This
  file now describes Settings › Brain, Typing by voice, Settings ›
  Permissions and Settings › About & Licences, which it never had; says
  which switches start on and which off across Voice, Replies, Meetings and
  Running in the background; uses the real labels (*Tell me before
  something in my calendar starts*, *Look at my calendar, notes and
  messages every 10 minutes*, *Call it*); says what the ten-minute look
  actually copies and that it is masked for codes and card numbers first;
  and tells the truth about a problem report — the last 40 lines of up to
  three log files, credential-shaped lines withheld, an issue in our
  private repository and a note in our team chat, and that "show me the
  ticket" reads back the words, not the log lines.
- **unreleased (2026-09-15)** — **Your cloud computer no longer reports
  "cannot think" while it is thinking.** Its start-up check counted the
  presence of a file the thinking engine keeps for itself — a note that it
  is using the credential you gave it — as a second credential, and printed
  the loudest alarm it has over a machine that had answered you two minutes
  earlier. The check now reads the file: your own credential's entry is
  yours; anything else in there is still named. And a machine that *can*
  think but has something else resolving beside its brain now says that,
  which is a different sentence from "cannot think".
- **unreleased (2026-09-14)** — **A connection made while the cloud computer
  is awake reaches it on the next message.** Measured on the owner's machine:
  Composio was set up at 00:23 and a message at 00:24 was told there was no
  Composio tool, because the machine only connected its services when it
  started. It now connects them once nothing is being worked on, and restarts
  once if it cannot. A message that is already being answered is never cut off.
  The same day's log also stopped calling Composio's own records "not a
  document this build knows". Revised 2026-09-15:
  - On a Claude plan, the next reply sees the new service. Before this, only
    the machine's own list of tools was refreshed, and that model never read
    it.
  - Scheduled jobs now count as work in progress.
  - A rotated key counts as a change.
  - Adding a service no longer disconnects the others.
  - The restart waits for work in progress to finish.
  - Revised again the same day, after a second review. The first version
    closed each conversation's Claude process, and a conversation's next
    message could land in a brand-new Claude session that had forgotten
    everything said so far. Now nothing is closed: the machine notes the new
    set of services where every conversation reads it, and each conversation
    restarts its own process on its next reply and carries on. The gap
    is now stated as up to about 259 seconds; the earlier 139 left out a wait
    of up to 120 seconds for another process to finish connecting. The
    machine no longer posts Hermes's "Gateway online" line into your chat. A
    key republished unchanged no longer counts as a change.
  - Revised a third time, 2026-09-15, after a third review. A bare `agent:`
    line in the machine's settings no longer stops new services being written
    at all. A line of your own instructions that merely starts like the
    services note is never removed. The note is now keyed with a secret kept
    on your machine, so it gives nothing away about your keys. When the
    note cannot reach a conversation, the machine restarts without first
    disconnecting and reconnecting your services. This page no longer says a
    failed warm-up costs only one reply: it can cost the conversation its
    earlier context (a Hermes flaw), and the one uncached reply per
    conversation is now stated.
- **unreleased (2026-09-15, latest)** — **A Slack workspace that stops
  accepting Moe is said, not silent.** When Slack refuses a reply because
  Moe's access to a workspace has ended, Moe removes itself there, stops
  answering from that workspace, and the Slack row says which workspace and
  why; a reply refused for good in one channel is named on the row too. A
  Slack row reading *Not available yet* now has *Check again*, and rechecks by
  itself every few minutes. Telegram, Discord, WhatsApp and LINE replies that
  fail are still always tried again.
- **unreleased (2026-09-15, later)** — **Slack in one click always asks you to
  sign in with Google, and then your Mac asks too.** A link somebody else made
  can no longer connect your Slack to their Moe by being clicked through: Add
  to Slack is off on Moe's cloud until its Google sign-in for the install page
  is set up, and the Slack row says *Not available yet* until then. Any
  unfinished Slack install from before was cancelled — choose Add to Slack
  again. After you choose Allow, Slack reaches Moe once Moe on your Mac
  confirms it, and the page now says truthfully what happens in between. A
  Slack reply Slack refuses for good (Moe was removed from the channel, say)
  is given up on instead of tried again, a shared channel whose host workspace
  removed Moe still gets answers through your own workspace's Moe, and Moe's
  cloud also says so when its connection to Slack keeps dropping.
- **unreleased (2026-09-15)** — **Adding Slack names the Moe account first,
  and a link somebody sends you is caught.** The page an *Add to Slack* link
  opens now says which Moe account it adds Slack to, partly hidden, with
  *This isn't my Moe account* beside *Continue*. Where Moe's cloud can ask
  you to sign in with Google as that account, a link made by someone else
  cannot finish (corrected above: it now always asks). A refused link can't
  be used again. A Slack account whose old Moe account has no Mac or cloud computer
  left can be added to your own. Removing a Slack of your own no longer
  disconnects Moe's Slack app too, and removing Moe's app no longer touches
  yours. A workspace that removed Moe and added it back lets earlier people
  ask to be let in again. Moe's cloud now says so when its connection to
  Slack has been failing for ten minutes, and when the three-day clean-up of
  unanswered Slack messages fails.
- **unreleased (2026-09-14, later)** — **Adding Slack is safer, and what Moe
  keeps of your Slack messages is said plainly.** *Add to Slack* now has to be
  finished in the browser it opened in, and a Slack account that already uses
  one Moe account is not moved to another by somebody else's link
  (corrected 2026-09-15: this line said a link somebody sends you "cannot
  connect your Slack to their Moe", which was not true — see the entry
  above).
  Moe's cloud now drops a Slack message nobody answered after three days
  instead of keeping it; the earlier line that Moe "keeps no copy" was wrong —
  the conversation is kept in the history of the Moe that answered, like any
  chat. In a channel shared between two companies, Moe looks for the Moe
  account of whoever wrote, from their own company's workspace, and answers
  through the company whose Moe app received the message; this has not yet
  been tried in a real shared channel. Disconnecting Slack
  now also stops your old Slack chat reaching the account you left.
- **unreleased (2026-09-14)** — **Slack is one click, and Moe keeps no copy
  of what you write there** (corrected above: the conversation is kept). *Add to Slack* opens Slack's own page: pick a
  workspace, choose Allow, and Moe is there under Apps — no keys to find, and
  nothing to paste into a dashboard. Moe reads only what is written to it
  (its Messages tab, and "@Moe" in a channel it has been added to), never
  your history; it answers, remembers what it learns, and sets up whatever
  you asked for, but keeps no copy of the messages themselves. A workspace
  that does not allow apps from outside can still use two keys from a Slack
  app of your own, as before. What you write there reaches Moe over a
  connection Moe's cloud holds to Slack, and Connections says so plainly when
  that connection is down rather than showing Slack as connected. And a chat
  app can now reach the Moe on your
  Mac whether or not you pay: until now letting one in needed a computer in
  the cloud, so it only worked for Away. If your Mac is shut, your message
  waits and Moe says so in the same chat.
- **unreleased (2026-09-14)** — **Moe asks, at first launch, what it may read
  to learn about you.** A new screen in the welcome — *What may I read to
  learn about you?* — with one switch per thing on this Mac Moe could read
  back over, and the daily pass under them; **Save and continue** is the one
  answer, and the pass starts that day. Skip records nothing. The same
  question is one click away on the Memory page while it is empty (**Choose
  what Moe may read**), and the switches are Settings › Background's own —
  one file, whichever way you answer. Found on the owner's Mac after an
  erase: the daily pass had run three days running and read nothing, because
  the sheet that asks about it waits for a source to be allowed first and
  nothing in the flow ever asked that — a new person, or anyone after an
  erase, was never learned at all.
- **unreleased (2026-09-14)** — **When Moe hasn't learned about you, it says
  why.** The daily pass that reads back over what you've allowed now writes
  down what it did each day — ran and what it read, or didn't run and why —
  and two places read that: the Memory page, when it has nothing to show
  (*Moe hasn't learned about you yet*, then the reason and where to change
  it), and the line under the switch in Settings › Background (*Last daily
  pass, 14 Sep: …*). Found by asking a cloud Moe "who am I" and getting
  nothing back: on the Mac behind it the pass had run three days running and
  done nothing each time, because the switch had never been turned on after
  an erase, and no screen could say so.
- **unreleased (2026-09-14)** — **Gmail's app-password mailbox is your Mac's
  alone.** The machine no longer offers it and then says "not set up": the app
  password never leaves your Mac's Keychain, and mail in the cloud goes
  through Composio. Asked about that mailbox from the machine, Moe reads it on
  your Mac when your Mac is awake; an email from it is confirmed on your Mac's
  screen, and is never queued when your Mac cannot be reached.
- **unreleased (2026-09-14)** — **Moe's background pass keeps going while
  the Mac is shut.** The pass that notices someone is waiting on you now
  runs from your cloud computer too, with your own brain and your own
  mutes; whichever side is awake speaks, and an answer you give either one
  is understood by the other.
- **unreleased (2026-09-14)** — **A watch follows you to the cloud when its
  connection did.** With Moe Away, a watch you set up on a connection that
  reached your cloud computer keeps looking while the Mac is shut, with the
  same switches and the same yes you gave it here; a watch on a Mac-only
  connection stays on the Mac, and the cloud computer says which.
- **unreleased (2026-09-14)** — **Your calendar heads-up and your watches
  keep going while the Mac is shut.** With Moe Away, "a couple of minutes
  before" and the checks on things you asked Moe to watch now run from your
  cloud computer too, with the switches you set in Settings › Background,
  and reach your phone through the chats you ticked. Nothing is said twice.
- **unreleased (2026-09-14)** — **Closing the lid hands over at once.** The
  Mac now tells your cloud computer it is away the moment it sleeps, locks
  or Moe quits, and that it is back the moment it wakes or unlocks — instead
  of the cloud computer finding out minutes later, during which a reminder
  could fall between the two.
- **unreleased (2026-09-14)** — **Reminders set from your phone reach the
  Mac, and nothing is said twice.** A reminder you give your cloud computer
  from Telegram now appears on the Mac too; whichever is awake says it, and
  a Mac waking ten minutes after the cloud computer already said it stays
  quiet. And with your chats ticked under Reminders, a reminder that fires
  from the cloud computer now reaches your phone rather than waiting for the
  Mac to open.
- **unreleased (2026-09-14)** — **"Remind me in two hours", close the lid,
  and it happens.** With Moe Away, a one-off reminder you set on this Mac
  now fires from your cloud computer while the Mac is shut, at its minute,
  to the chats you ticked under Reminders. Before, it fired only if the Mac
  was open at the time — and a one-off more than two minutes late was
  dropped, which the Reminders section used to describe as "survives the
  Mac being asleep". It now says what is true. Only one-off and
  clock-scheduled reminders wake the cloud computer; "every five minutes"
  jobs never bring it up on their own.
- **unreleased (2026-09-14)** — **Your Google services reach the away
  machine, and your devices stop waiting on the clock.** The machine is now
  given its own copy of the key to your Composio project — one project per
  person — sealed over the same road as your conversations, when it is set
  up and again if you connect Composio later; it is told to forget it if your
  plan lapses or you delete your account — and asked again at every check
  until it has — and is not given it again until you pay again. Keeping a copy in the cloud
  turns on for every Mac you sign in on once you have agreed and paid —
  except a Mac where you had turned it off, which stays off — also after you
  sign out and back in, and also one you turned off before this change if it
  had ever kept a copy. And when one device sends
  something, the others are told at once and fetch it within a second; the
  five-minute check stays as the backstop.
- **unreleased (2026-09-14)** — **Disconnecting a pasted key now removes
  all of it.** For a service that needs something set up at the broker
  before the key (a token of its own, say), Disconnect used to remove the
  connection and leave that setup — and what was pasted into it — behind;
  now both go, and a paste the broker refuses leaves nothing either. A
  refusal also never repeats your key back to you in any form (encoded,
  split across lines, partly masked, or most of it), however long the key —
  a long one used to turn the refusal into an error dump — and after a
  paste Moe says the broker accepted the key rather than promising more than
  it has checked. If the broker can't remove something on Disconnect, Moe
  says so and tries again by itself (and stops after three tries in a row,
  saying so); it only ever removes what it set up, and never something a
  paste is in the middle of using. Refreshing the Connections screen no
  longer stalls when the broker is slow to clean up, and if Moe can't read
  your accounts at the broker, Disconnect says that rather than "not
  connected". A refusal keeps a region, subdomain or address you typed
  readable. Being offline or a slow broker no longer counts towards giving
  up; a service whose cleanup Moe gave up on keeps its Disconnect button so
  you can retry it; every field that is not plainly a region, subdomain,
  address or username is typed out of sight and kept out of refusals in
  every form; and a Mac whose broker key can't manage accounts is told so,
  rather than asked to try again. See *Google, and about five hundred other services*.
- **unreleased (2026-09-14)** — **You and Moe are on opposite sides of the
  chat, and you can hand Moe photos and files.** What you say sits on the
  right in a tinted bubble; Moe's answers sit on the left under its name. A
  **+** beside the message box — in the chat window and in the panel under
  the notch — adds photos from your library, files, a screenshot, or what is
  on the clipboard, and you can drag files onto the chat window or onto the
  notch itself, which stays open until you let go.
- **unreleased (2026-09-14)** — **Your cloud computer stopped being able to
  get stuck with nothing to think with.** Fetching what you had given it was
  something it only did *while answering a message* — and a machine with
  nothing to think with turns messages down before it gets that far. So it
  never looked, and it would never have looked, however many messages you
  sent and however many times you gave it a brain from your Mac: the only
  thing that could have collected it was the thing it refused to start. One
  machine sat that way for fifteen hours, replying *"Provider authentication
  failed"* to its owner, who had done nothing wrong. It now looks for what you
  have given it **before** it tries to answer, every time, so the first message
  you send after setting one up is the one that gets a reply. And a machine
  that still cannot think now says so where you will see it: on your ledger,
  which is what Settings › Away reads, and — since a machine answered through
  your cloud Moe has no channel of its own to send on — by handing the
  sentence to your Mac to speak at the notch.
- **unreleased (2026-09-14)** — **A brain you give your cloud computer
  arrives, and when it cannot, it says which kind of "cannot".** Your machine
  decided once, seconds after it started and before it had fetched anything,
  whether it had something to think with — and never looked again on that run.
  It now applies a brain the moment one arrives, on the same sync that brings
  it and in the same turn, so a message that wakes your machine is answered by
  that message rather than after a restart it may never get. If a credential
  reaches it that it cannot open, it asks your Mac for the key instead of
  waiting for something else to happen to notice; before, a brain you set up
  *after* your machine was running could sit unopened indefinitely. And the
  one sentence it used to send for every kind of failure — *"give it one from
  Settings › Away"* — is now four: nothing given, given and unopenable, given
  and unusable, and could-not-look. Two of those cannot be fixed by giving it
  the same thing again, and they now say so instead of sending you round. And
  **Settings › Away says whether it arrived**: that section showed what this
  Mac had published and had no way to ask the machine, so it read "Your Claude
  plan · Sonnet 4.6" throughout. Your machine now says what came of it, on
  your own ledger, and the pane shows it — including *"hasn't confirmed it"*
  when your machine has not said, which is different from saying it has none.
- **unreleased (2026-09-14)** — **The panel under the notch fits what is in
  it, on every Mac.** A reminder that wrapped to two lines, with the
  Accessibility note under it, pushed the box you type in off the bottom of
  the panel and squeezed the conversation to half a line. Every row at the top
  is now counted, the Accessibility note wraps with its Fix button beside it,
  and the ✕ and ⌃ moved into the strip beside the notch. The island lines up
  with the notch itself, stays on the laptop's notch when an external display
  is plugged in, and on a Mac with no notch — MacBook Neo, M1 Air, iMac,
  external displays — draws a small tab to glow around and opens on hover,
  which before did nothing there.
- **unreleased (2026-09-14)** — **Moe can answer you on a chat app again.**
  Messages reached Moe and Moe's replies could not leave: every reply, on
  every chat app, was refused on the way out because the part that decides
  *which* app a reply belongs to was being asked about the connection instead
  of about the conversation — and one connection carries all five of your
  chat apps, so the answer was never right for any of them. It is now asked
  per conversation, and a reply that cannot be placed is refused with a
  sentence naming the chat rather than delivered to the wrong app.
- **unreleased (2026-09-15)** — **Slack: what Moe keeps is what it learned,
  not what was said — now true on disk as well as in its memory.** Moe's
  memory already skipped Slack; its conversation history did not, so every
  Slack message and every reply sat verbatim in the history on your Mac and on
  your cloud machine. Once a reply has been sent, the words of that exchange
  are now removed from both — a note saying *no verbatim copy kept* stands in
  their place — while the fact learned, the reminder set and the thread itself
  all stay. Slack only; every other chat app's conversation is kept as before.
  (See *What Moe keeps of a Slack conversation*, above.)
- **unreleased (2026-09-14)** — **Upgrading no longer makes you a stranger at
  your own bot.** Moving a chat app to the cloud took the bot's key across and
  left behind the list of people allowed to use it, so the very first message
  — from you, on the bot Moe made for you, from your own account — was held as
  an unknown chat and Moe went quiet with no explanation. Everyone you had
  already allowed is now carried across, on every chat app that has such a
  list; Slack and Discord have a real gap (a member id is not a conversation
  id) and Moe now says so rather than leaving it to be discovered, and LINE
  has no list to carry at all. **And somebody waiting to be let in is
  visible**: the app's row in Connections says who is waiting and what to do,
  and goes quiet again when nobody is.
- **unreleased (2026-09-14)** — **Your Mac does not let a chat app go until
  the app has actually been pointed at the cloud.** It used to give the app up
  first, so a move that failed left *neither* side receiving. And when a chat
  app is sending your messages nowhere at all, Moe now puts it back straight
  away instead of waiting out a ten-minute pause meant for a different problem
  — that pause was leaving a dead chat app dead while correctly describing
  what was wrong with it.
- **unreleased (2026-09-14)** — **Your chat bot's key is locked away.** The
  key that lets Moe answer as your Telegram, Slack, Discord, WhatsApp or LINE
  bot was written down as-is; it is now encrypted wherever it is stored and
  unlocked only for the moment it takes to send one message. Bots connected
  before today are moved over by themselves, with nothing for you to redo.
  What Telegram presents to prove a message is really from it is no longer
  stored either — only a fingerprint of it, which recognises the real
  Telegram and is no use to anybody who took a copy.
- **unreleased (2026-09-14)** — **A chat app is held by one Moe, and the
  other one says so.** When your cloud Moe takes a chat app over, this Mac
  now stops listening on it and answers through the cloud instead. It had
  been trying to do both, which Telegram does not allow: your Mac's attempt
  to collect messages was refused, your Mac cleared the cloud's setup to
  recover, and from then on the Moe in the cloud could not receive a single
  message — while both said "connected". Moe now decides which one holds
  each app from whether you have a cloud machine and whether that app has
  moved across, so a leftover setting cannot put you back there; apps the
  cloud does not carry, including a WhatsApp you linked here, are untouched.
  Connections reads an app the cloud carries as connected and says who
  receives it, instead of telling you to switch something back on. And Moe
  now asks Telegram and LINE where they are *really* sending — every so
  often and right after a move — and points them back if they have drifted,
  a few times quietly and then with a line telling you what to do.
  **Slack and Discord move to the cloud with nothing for you to fetch.**
  Buying Away used to leave both behind with "needs its Signing secret" — a
  secret for a kind of connection neither app offers for a message. Moe now
  hands its cloud the key you already gave it and the cloud connects outwards
  to the app. While the app is accepting that connection Moe says *still
  coming* rather than connected, and corrects itself with nothing for you to
  re-run.
- **unreleased (2026-09-14)** — **Signal, by scanning one code.** Ways to
  reach Moe now lists Signal as well. Moe links to your own Signal account as
  a device, the way Signal Desktop does: you scan the code Moe shows, and then
  talk to it in Note to Self. The Signal software this needs — about 180 MB —
  is downloaded the first time you connect it and not before, so it costs
  nothing to anyone who does not use Signal. Moe answers only your own Note to
  Self: your contacts never get a reply from your account, and Moe is not in
  your groups. Disconnecting deletes the account's keys from this Mac. If
  anyone else logs in to this Mac, do not connect Signal: while Moe runs, the
  Signal software listens on a local connection with no password, which
  every login on a Mac can reach. About & Licences, and the licences page on
  the website, now link the source of the Signal software Moe downloads. If
  a Moe update needs newer Signal software, the Signal row says so instead of
  reading connected, and connecting again downloads it — no new code to scan,
  and no second "Moe" in your phone's linked devices. Disconnect on the Signal
  row now stops Moe answering there at once, instead of at the next launch.
- **unreleased (2026-09-11)** — **Away: your Mac's own apps answer at once
  when your Mac is awake.** Asking for your Reminders, Notes or Calendar
  from your phone used to be queued for "when your Mac wakes" even with your
  Mac open in the next room. Now, if your Mac is awake, reading them and
  adding to them ("add a reminder") is done on your Mac there and then, and
  the answer is in the same reply. A shut Mac still gets it queued. Messages
  to people go out from wherever Moe is running, with your approval, as
  before.
- 2026-09-11 — Away: when setting up your cloud computer stops on our side, or we notice you've paid and have no machine, a ticket opens for you by itself — the "We're on it" email with its number, and "Fixed" when it clears — with no switch needed, because it carries only which step stopped. The Away page shows the ticket number; if the report couldn't be sent, **Tell Moe about this…** now really tells Moe in Chat instead of opening the connect-a-channel screen. A paid account whose machine couldn't be made is tried again automatically once one is free, and **Try again** reaches it too.
- **unreleased (2026-09-15)** — **Your own WhatsApp and Telegram, in the
  cloud.** With Away, your cloud computer joins your own Telegram as a device
  of its own by itself, once you have agreed to Away's terms, and your own
  WhatsApp with one 8-character code you type on your phone, from a new *Your
  chats in the cloud* section on the Away page. Nothing of this Mac's own
  sign-in is copied, because a copy would log both out. The upgrade summary
  now says your cloud computer becomes a device on your own Telegram and
  WhatsApp. Your Mac and your cloud computer sign what they ask and answer,
  for your own account, so the service in between cannot add a device of its
  own, sign your cloud computer in to somebody else's account, or show you a
  WhatsApp code of its own. Removing your cloud computer from your Telegram
  devices sticks until you press *Put Telegram back on your cloud computer*.
  The sign-in key your cloud computer hands your Mac is locked to that Mac,
  and your Mac checks it is on the same Telegram account before using it.
  Telegram accounts with two-step verification can't be added this way yet,
  and the Away page says so. (Drafts let Telegram in on an answer nobody could
  check, then behind a press; neither shipped.)
- **unreleased (2026-09-11)** — **Away, from paying to running, without a
  relaunch.** Agreeing to Away now checks what your cloud computer will need
  before the payment page opens, and asks for it right there (a Claude plan
  asks for one sign-in; a key or a ChatGPT plan comes along by itself). When
  you pay, Moe hears about it at once — the payment page opens Moe, and Moe
  also watches for the payment itself — instead of at its next hourly check.
  Anything still missing after that is the first thing on the Away page, one
  line and one button each, and the greyed *Set up my machine in the cloud*
  button is gone. Backing out of the payment page says nothing was charged.
  The welcome email no longer says your machine "arrives switched off". And a
  setup that stops no longer goes on asking our server about it.
- **unreleased (2026-09-11)** — **Your Telegram bot is made by Moe, not by
  somebody else.** "Create my Telegram bot" used to hand you to another
  company's bot-making bot, and the bot you came away with was named after
  their product until Moe renamed it. The link now opens Telegram's own
  *Create bot* screen for **@MoeSetupBot** with the name Moe filled in;
  tap *Create* and it is yours, `@moe_…_bot`, and if you have signed in to
  Moe your account knows about it at once. The sheet in Moe now says what
  actually opens.
- 2026-09-11 — Browsing: Moe's browser is signed in as you. On Macs whose default browser is Chrome, Edge or Brave it runs on a private copy of that profile, out of sight; Safari and Firefox users get the signed-out browser as before. The cloud stays signed out.
- **unreleased (2026-09-14)** — **Slack and Discord can move to the cloud
  with nothing typed.** Neither app will post a plain message to an address
  you give it — Discord offers no such thing, and Slack only for an app you
  set up by hand — so Moe now opens a connection outwards to each of them and
  holds it, using the key it has had since the day you connected the app.
  That removes the one step that used to stand in the way of buying Away and
  keeping the chat apps you already had: no reconnecting, no new bot, and
  neither of the two secrets Moe had never held (they prove a message came
  from the app, and on a connection Moe opened itself there is nothing to
  prove). Handing one over is not a one-way door: your Mac can take it back,
  your keys stay where they are, and the two sides are checked against each
  other every quarter of an hour so a disagreement fixes itself. Built and
  switched off for now — two connections on one key means Discord answering
  you twice, so nothing opens until your Mac has genuinely let go. Until then
  Slack and Discord stay on the Mac and Moe says so.
- **unreleased (2026-09-11)** — **Ways to reach Moe lists five chat apps,
  and each one has been checked.** Telegram, WhatsApp, Slack, Discord and
  LINE; the twenty-odd others the engine speaks are no longer offered
  (several could not even start from what Moe ships, and none reaches the
  cloud). One set up by hand still runs. Slack, Discord and LINE are now
  driven through the same script the sheet runs, into a scratch copy of the
  engine's own settings, and the engine's own loader is asked whether each
  came out enabled with its key — a listed app is a promise, and the test
  is the promise's receipt.
- **unreleased (2026-09-11)** — **LINE says how it reaches Moe.** LINE only
  delivers to a public address, so connecting it now registers it with Moe's
  cloud when this Mac is signed in and points LINE there, and says "nothing
  arrives yet" with the reason when it is not — instead of going green over
  a listener LINE could never call.
- **unreleased (2026-09-11)** — **Moe asks for its own name on your
  phone's WhatsApp link.** Linked Devices lists it under the engine's name
  until the engine update that honours the request ships; a link made
  before that keeps its old name until it is scanned again.
- **unreleased (2026-09-11)** — **Reminders says what its empty list means.**
  "No chat apps are connected yet" was read as "nothing is connected" with
  five connections working. It now says "No chat app to reach you on yet —
  connect Telegram or WhatsApp under Connections and it appears here." The
  connect script's opening line no longer promises an answer "even when the
  Mac is closed", which nothing on a free Mac does.
- **unreleased (2026-09-11)** — **WhatsApp on this Mac reads again.** Since
  2026-09-09 linking WhatsApp worked and reading it did not: the row went
  green, and then every question about your chats came back "your phone has
  not linked this Mac yet", because the copy of your chats Moe read from was
  kept by a second link that no longer existed. The one link now keeps that
  copy itself — the chats your phone sends over when you scan, and
  everything after — so looking back through a conversation, the list of
  chats, finding someone by name, voice notes and sending (still asked
  first, every time) all work from the same single device, with nothing to
  install. The row tells the truth of that one link, in order: not linked,
  Moe not running, the link dropped, chats still arriving, or reading. If
  you linked before this change, the row says so and Connect turns the copy
  on without a second scan — and from then on it keeps what arrives, not
  what is already on your phone: the history only comes over at the moment
  you scan, so link again if you want the past in too.
- **unreleased (2026-09-11)** — **Paste a key for the twelve hundred
  services that hand one out.** Most of the broker's services never had a
  sign-in page — Firecrawl, SerpApi, Perplexity and the long tail want a key
  from their own settings — and Connect on any of them ended in "Composio
  did not return a sign-in link". Those rows now say *Paste a key*: Moe asks
  the broker for exactly what the service wants, in its own field names,
  with the service's own note on where to find each one, and the broker
  takes the key the moment you click Connect. The key is kept at the broker with
  the sign-ins, so it works wherever Moe runs, and is never shown, logged or
  passed around again; *Add another* on a connected one adds a second
  account with the second key. See *Google, and about five hundred other
  services*.
- **unreleased (2026-09-11)** — **The broker comes first.** Where a service
  can be reached through the broker or through a Mac-only route (Gmail with
  an app password; Notion, GitHub, Linear, Stripe, Figma, GitLab, Dropbox,
  Todoist through their own servers), the broker's row now leads and a new
  connection goes that way, because one sign-in there works on your Mac and
  wherever else Moe runs. Anything already connected the other way is
  untouched and stays under *Yours*.
- **unreleased (2026-09-11)** — **Moe is told about everything that is
  connected, not just the broker's services.** The list Moe answers from
  now names what is on this Mac (Calendar, Notes, Messages, Gmail and the
  rest, each with the way Moe reaches it), the servers you connected
  directly under their own heading, GitHub when `gh` is signed in, and the
  chat apps you can reach Moe from — and it changes only when what is
  connected changes. See *How Moe knows what is connected*.
- **unreleased (2026-09-11)** — **Moe knows every service you connected,
  not just the first twenty.** Connecting something outside the everyday
  set — TickTick, say — left it off the list Moe answers from, so Moe could
  tell you it did not have TickTick a minute after you connected it. The
  list now comes from your connected accounts themselves, whatever position
  the service holds in the catalogue, and Moe is told to search before it
  ever says a connected service is unavailable.
- **unreleased (2026-09-11)** — **WhatsApp shows its code again, on both
  rows, and answers as Moe.** Since 2026-09-09 "Getting a code for you…"
  never turned into a code: the row under *Ways to reach Moe* started
  nothing at all, and the *WhatsApp on this Mac* row ran a script the
  download did not carry. Both work now, Moe waits longer than the code is
  valid for rather than giving up with a live code on screen, and replies
  no longer open with the engine's name. The install check now reads the
  scripts themselves for what they hand off to, so a missing one is a
  failed test rather than a spinner.
- 2026-09-11 — Browsing: Moe now keeps every page in its own out-of-sight browser and never opens, scripts or drives your Chrome, nor starts a second Chrome from the shell; when a site blocks it, it says so and offers your screen instead of taking it.
- 2026-09-11 — Meeting Capture and Permissions: the Screen Recording button asks macOS first and then opens System Settings. macOS lists an app under Screen Recording only after it has asked once, so the old deep link could open a list with no Moe on it.
- 2026-09-11 — Driving your Mac: the notch goes magenta for Moe's own browser too, the stop on hover is labelled **End computer use** / **End browser use**, and the colour clears when the run ends instead of waiting for a double-tap.

- **unreleased (2026-09-11)** — **Connections work after deleting and
  signing in again.** Moe's Composio identity belonged to the deleted account
  and was refused, so Gmail and every other connection said "no Composio
  session configured". Deleting your account now removes it, and a new sign-in
  gets a fresh one; another account's identity is never used.
- **unreleased (2026-09-11)** — **The page after a Google sign-in says why
  you signed in.** Confirming *Delete my account*, *Erase Moe from this Mac*
  or a new key for agreeing used to leave the browser on "Signed in." It now
  ends on a page for that moment — *Confirmed — it's you*, and what Moe is
  doing next — and one that didn't finish says plainly that nothing was
  deleted, erased or agreed to.
- **unreleased (2026-09-11)** — **Settings › Privacy, fixed on a real Mac.**
  *Delete my account* works on a Mac that signed in before Moe noted which
  Google account it was, and is hidden when there is no account; *Review and
  agree* always brings the agreement window forward instead of doing nothing
  while an older one sat behind another app.
- **unreleased (2026-09-11)** — **Away starts itself.** Once you are signed
  in, on a paid plan you agreed to, with something for your machine to think
  with and a way for it to reach you, Moe sets up your machine in the cloud
  by itself — there is no Start button, and it carries on with Settings
  closed. Miss one and Settings › Away shows which; sort it out and it
  starts. If this Mac thinks with a key you pay for or your ChatGPT plan,
  your machine is given the same; a Claude plan is one click, **Sign in with
  Claude…**. The island tells you when it starts and when it is ready, or
  that it didn't finish; it then tries once more by itself the next time Moe
  opens, and after that there is **Try again**.
- **unreleased (2026-09-11)** — **Erase Moe from this Mac says what it
  couldn't remove, and CuaDriver stays removed.** Anything macOS won't let it
  delete is named in one note when Moe opens again, with **Show in Finder**;
  before, a failure went unseen. CuaDriver used to come straight back a minute
  after an erase, because the fresh Moe reinstalled it on its first launch;
  now that waits until you have set Moe up again.
- **unreleased (2026-09-11)** — **Erase Moe from this Mac removes CuaDriver
  too**, the tool Moe uses to work your screen: Moe installed it, so it goes
  with Moe, along with its screen permissions. The warnings say so. Claude
  Code is still left exactly as it was, and the developer build still leaves
  CuaDriver alone.
- **unreleased (2026-09-11)** — **Saying yes is a real step now, and only you
  can take it.** *Get Away* shows **Before you start Away** — what you get,
  what moves, and how to leave — and only **Agree and continue** records a yes
  and opens the payment page; the copy starts moving when the payment goes
  through, not at the tap, and **Not now** sends nothing. The switch *Keep my
  conversations in sync across devices* is gone; the Away checklist is three
  lines. Every Google sign-in button says that signing in is agreeing to the
  Terms and Privacy Policy, and records it. A new page, **Settings ›
  Privacy**: problem reports that wait for your yes (a report asked for while
  it is off is kept and sent the moment you turn it on), *Keep a copy in the
  cloud*, *Cloud voice*, the documents you agreed to and when, and **Delete my
  account** and **Erase Moe from this Mac**. A cancelled plan's cloud copy is deleted 120 days after the plan ends, after
an email at 90. The Agree buttons,
  the Privacy switches and the delete buttons answer only to your own click or
  key press — anything else asks for Touch ID or your password — and every yes
  is signed by a key only the Moe app on your Mac can use; replacing that key
  sends you an email.
- **unreleased (2026-09-11)** — **The download's own Node and Python work
  after the build signs them.** The signed 0.3.17 build stripped the
  permissions its bundled Node needs to run at all, so anything Moe reaches
  through Node — the WhatsApp bridge, the browser's own Chromium, `npm` and
  `npx` — was dead on a fresh download, and its Python refused any package
  installed after the build. Both now keep what they need when the app is
  signed, and `npm`/`npx` are the real launchers again instead of broken
  copies.
- **unreleased (2026-09-10)** — **The browser stops asking before every
  click.** Setting a date on a booking site used to put thirteen sheets in
  front of you in seven minutes, one per click, and none of them was a
  question worth asking. Moe now asks in a browser only at the moments that
  matter — paying or booking, sending, deleting, entering a password or a
  card, letting an app into an account — and one yes covers that kind of
  moment for the rest of the conversation. The docs also now say which
  browser that is: Moe's own, signed out, for most web work; a copy of your
  Chrome profile, only if you switch that on, for pages where you must be
  signed in. Until now Moe was working inside your running Chrome after a
  one-time "Allow remote debugging?" box — that lane is gone. Looking a tool up no longer raises the "not a
  tool Moe recognises" sheet either.
- **unreleased (2026-09-10)** — **Reinstalling Moe no longer stops the work
  it does on a schedule.** macOS runs that work on a timer, and when Moe was
  removed macOS stopped the timer and never started it again — so after a
  reinstall the every-ten-minutes catch-up silently never ran, until the Mac
  was restarted. Moe now checks that timer each time it opens and sets it up
  again when macOS has stopped it.
- **unreleased (2026-09-11)** — **The developer build keeps to its own home,
  and Moe's background pass talks only about your life.** Two things the
  first real end-to-end run found in the same hour. A developer build of
  Moe installed beside yours was running its ten-minute look at your
  calendar and reminders against *your* Moe's files, with its own
  permissions (none), and so kept deleting your calendar and tasks copies;
  a development build now hands its own home to everything it runs. And
  when that left a hole in your brief, Moe's background pass told you to
  "check your brief display configuration" — it now never mentions its own
  plumbing; a section it could not read is its business, not yours.
- **unreleased (2026-09-11)** — **A reminder never asks your permission to
  exist.** "Check in on me in five minutes" put up the "Moe wants to run
  this — read it first" sheet for a `cronjob_manage` call, because the
  gate's list of Moe's own local work named the scheduling tool by an old
  name. Setting, changing or removing a reminder is Moe's own clock and
  sends nothing; what the reminder does when it fires is still checked
  then. Seen on the owner's Mac during the first end-to-end run.
- **unreleased (2026-09-11)** — **"Keep an eye on this page" costs nothing,
  and a schedule you ask for is yours.** Three more things the first real
  end-to-end run found. Asked to watch a page, Moe set up an hourly job
  that ran a model every hour to look at a page that had not changed, and
  asked how often and where; now it opens a watch that checks the page
  itself and only thinks when something moves. Asked for a weekday
  briefing, Moe asked where it should land (it lands wherever your
  reminders do), named the job as one of its own so it never travelled to
  your cloud machine, and dropped half of what you asked for in favour of
  the template's wording; now your words ride with the job, it is yours,
  and it travels.
- **unreleased (2026-09-11)** — **Follow-ups actually get written down.**
  Found on the first real end-to-end run: when you said "I'll call Dan
  tomorrow, chase me if I forget", Moe set the reminder but its own
  follow-up tracker rejected every entry and Moe told you so. The tool was
  reading its arguments in a shape Hermes never sends. Fixed; the tests now
  call it exactly the way Hermes does.
- **unreleased (2026-09-11)** — **Background work on any brain.** If your
  brain is an API key — Anthropic, OpenRouter, OpenAI, DeepSeek, your own
  endpoint — Moe's scheduled work (the half-hourly pass, the daily learning
  pass, your reminders) was asking that provider for a model called `haiku`,
  a name only Claude's own app understands, and failing every time. It now
  follows the model you chose; on Claude's app it still uses the cheap one.
  And the budget check that pauses background work past half your plan's
  window now reads a ChatGPT plan too, not only Claude's; an API key has no
  window, so it is never paused for one. The weekly window pauses it only
  past four fifths — the first real run found a half-used week silencing
  every follow-up for a day and a half. Seeing the screen on an OpenAI,
  Gemini, Anthropic, xAI or OpenRouter key uses that same brain — Moe no
  longer puts a second vision service (and a second bill) in front of it
  just because another key was lying in your settings. The Usage page says
  "your plan" rather than "your Claude plan" for sessions a subscription
  covered. Also, installing the developer build no longer quits your real
  Moe.
- **unreleased (2026-09-10)** — **Your reminders travel with you.** A
  reminder set on the Mac exists on your machine in the cloud too, and the
  two take turns: the Mac runs it while awake; the machine covers only when
  no Mac is there, asking the edge first for each occurrence. Deleting it on
  the Mac deletes it there. Needs the edge deployed to be live.
- **unreleased (2026-09-10)** — **Quiet hours, and Moe knows where you are
  in time.** Ten at night to eight in the morning, in your Mac's own zone,
  Moe's own nudges wait for the morning before reaching your phone. The
  Mac tells Moe in the cloud your zone whenever it changes, so a scheduled
  job there runs at your seven, not London's. Also: every follow-up keeps
  its own history and Moe re-checks a page before saying a price moved;
  the background pass pauses past half of your plan's five-hour window;
  and a conversation is read back once, at its end, for loops Moe missed.
- **unreleased (2026-09-10)** — **Moe comes back to things.** Open loops of
  five kinds — what you said you'd do, what Moe started, people waiting on
  you, deadlines, and prices or pages you looked at — noted during the
  conversation and raised later with an offer to do the next thing. A
  watched page is checked without a model. Follow-ups reach you where you
  are: the notch at the Mac, your chats when you are not. A new **Background
  thinking** switch in Settings › Background turns the model work off to
  save your plan, while free checks and your reminders keep running. Two
  cost bugs fixed on the way: background jobs no longer ask ChatGPT for a
  Claude model, and the daily learning pass respects the switch.
- **unreleased (2026-09-10)** — **Who Moe is, and where.** Moe's character
  is written down: colleague and friend, honest about what it could not
  verify (it no longer guesses a number), with opinions it gives once and
  then leaves to you. The Mac copy knows it has the whole Mac; the cloud copy
  knows it answers while the Mac sleeps and cannot reach its files. And the
  chat rules now reach every chat app Moe can be on — Slack, Teams via
  Mattermost, Matrix, SMS, email, iMessage and the rest — not just the six
  they used to name.
- **unreleased (2026-09-10)** — **Away asks for what it needs before it
  starts, and then tells you how it is going.** Settings › Away now shows one
  of three screens. Before your machine is set up: four lines saying what is
  still yours to do — signed in, conversations allowed to travel, something
  to think with, a way to reach you — each with the button that fixes it, and
  **the setting-up button stays off until all four are done**. A line Moe
  could not check shows a question mark and keeps the button off, because a
  check that did not run is not a check that passed. While it is being set
  up: a short list in plain words — *Making Moe a home in the cloud*,
  *Moving your memories* — with no percentage bar, and a page that stops and
  says so rather than animating over something that will never finish. Four
  of those lines are read off what actually happened and two are timed, and
  the page never claims otherwise. When something is wrong on **our** side it
  says exactly that, and says plainly that nobody has been told
  automatically, because nothing reports these yet. And once your machine is
  set up the screen is four short lines — Away, your machine (running, read
  off who is actually reachable), connections, memory — with only the ones
  you can do something about carrying any words, and everything technical one
  link away under *Show the details…*. Settings › Away also no longer says
  *"nothing sets a machine up when you pay"*: that stopped being true when
  the machines started being made, and the status page is the honest answer
  now.
- **unreleased (2026-09-10)** — **Choose how much Moe says.** Settings ›
  Replies has a **Reply length**: Short, Balanced (Moe as it was) or
  Detailed. It applies to what you ask out loud, what you type, and your
  Telegram and WhatsApp chats; asking for more always gets more.
- **unreleased (2026-09-10)** — **Moe knows when it is waiting on you to
  press Send.** The confirmation sheet now tells Moe when it is up, so Moe
  says "press Send when it looks right, or change the words first" instead
  of "still getting that ready to send" for as long as the sheet waited. The
  island shows *Waiting for you to press Send*, Moe reminds you once if you
  take a while, and it no longer says "sending" before you have answered.
- **unreleased (2026-09-10)** — **Moe does it, rather than telling you how.**
  Asked about a website rejecting a photo, Moe used to reply with a list of
  steps to fix it yourself. Now, when its tools can do the job, it does it —
  or offers to in a line — and gives steps only for what needs your hands.
  Sending, posting, buying and deleting still wait for your yes.
- **unreleased (2026-09-10)** — **Long talk-key turns are heard to the end.**
  Holding the key and talking for a minute or more could send Moe only the
  first few seconds: the rest was still being written down when Moe stopped
  waiting for it. Moe now waits for all of it, and if that part never comes
  back it re-reads the whole recording on your Mac rather than acting on a
  fragment.
- **unreleased (2026-09-10)** — **We find out about some of our own failures
  without you telling us.** If you have paid and no always-on machine came
  out (after about fifteen minutes), if your machine will not stay up (within
  minutes), if nothing has synced between your devices for a day (after 24
  hours), or if we are running out of machines or have stopped managing them
  (within minutes), somebody here is told. The alarm never carries anything
  of yours. See *When Moe itself breaks*.
- **unreleased (2026-09-10)** — **The best voice is called Premium.** It was
  "Cloud", which says where it runs rather than what it is. Settings ›
  Permissions no longer lists Speech Recognition: Moe hears with its own
  models and never asks macOS for it, so the row pointed at a switch that
  was never there for Moe. And a freshly downloaded Moe answers its first
  question: it no longer tries to start its thinking part while that is
  still being unpacked, and it no longer answers "Moe couldn't unlock its
  own thinking" until something else restarts it.
- **unreleased (2026-09-10)** — **A fresh download gets its brain, and a dead
  talk key says why.** A Mac that once had Moe, deleted it and downloaded it
  again could keep a leftover launcher for the old thinking part; Moe took
  that as installed, never set up the one inside the app, and every question
  ended in *the part of Moe that thinks kept stopping*. Moe now checks the
  launcher can actually run. The same Mac can hold an Accessibility switch
  from the old copy that System Settings shows as on while macOS refuses the
  new one — onboarding and Settings › Permissions now offer **Reset and ask
  again**, the island and chat say when right ⌥ cannot work, and the key
  starts working the moment the switch is on, without reopening Moe.
  Connections now leads with what most people use — Gmail, Google Calendar
  and Drive, Outlook, Spotify, WhatsApp — with the popular work services
  under them, then everything else. And the installer window no longer
  mentions Apple. **Signing in to ChatGPT no longer opens Terminal**: Moe
  shows the code and the link itself, opens the page, and copies the code
  for you; the Claude sign-in shows its link to copy too. The ChatGPT model
  list no longer offers gpt-5.3-codex, which ChatGPT refuses on a
  subscription — and once you are signed in, Settings › Brain shows exactly
  the models your ChatGPT plan offers, read from OpenAI for your account,
  and says so if the one you had chosen is not among them. A failed brain check now says what the provider said
  instead of "Moe couldn't finish the check".
- **unreleased (2026-09-10)** — **The machine in the cloud belongs to the
  plan that pays for it.** On the free plan Moe now refuses to pair a machine
  at all, and says why, instead of accepting one that could never answer.
  And if a plan lapses, the conversation goes back to your Mac by rule rather
  than by luck: Moe stops choosing the machine the moment the plan does, even
  when the machine is still switched on, even if you ask for it by name, and
  for messages that were already waiting as well as new ones. If your Mac is
  shut just then, Moe says so in the chat instead of going quiet. Your own Mac
  is never affected by any of this.

  Two smaller things went with it. Setting up a machine no longer takes your
  Mac's word for what kind of computer is joining — we know, because we made
  it — so nothing you or anything else runs can point your conversations at a
  computer you did not mean. And a refusal that used to read *"Moe couldn't
  reach your other devices just then, it will try again on its own"* now says
  what actually happened, so you are not left waiting for something that
  cannot happen.

- **unreleased (2026-09-10)** — **Giving your away machine your Claude plan is
  a button now.** It used to say: open a terminal, run `claude setup-token`,
  and paste what it prints. Moe had been able to do that whole thing without a
  terminal since the day the Brain pane learned it — same browser page, same
  code box if the page asks for one — and the away screen simply never offered
  it. It does: **Sign in with Claude**, approve in the browser, done. (The
  button needs Claude Code on your Mac; without it the row says so and tells
  you what to paste.) Your machine is given **a token of its own** rather than
  a copy of your Mac's, so that ending one at Anthropic is something you can
  do without ending the other. And if a sign-in fails *after* the token has
  been created, Moe now says that a sign-in exists and it cannot take it
  back — where before it said only "that didn't work" and offered a Try again
  that quietly made another one.

- **unreleased (2026-09-10)** — **You can choose which of your computers
  answers, and choosing the machine now starts it.** Settings › Away › *Which
  one answers*: your Mac while it is awake, with your machine in the cloud
  taking over when it is not, or always your machine. The setting existed and
  was obeyed; the only thing that could change it was a person at our end, so
  nobody could express a preference for themselves.

  It also did less than it looked like doing, and that is fixed in the same
  change: a sleeping machine cannot be handed a message, so *always my
  machine* used to mean "the Mac answers, exactly as before" for as long as
  the machine stayed asleep — which is precisely when you would choose it.
  Now a message arriving for an account set that way **starts the machine**,
  your Mac answers that one while it comes up, and the next one goes to the
  machine.

  Whichever you choose, a computer that is not reachable does not get the
  message, so the choice cannot leave you waiting. The screen never draws one
  of the two answers before it has been told which is yours: while it is
  asking it says *Checking…*, and if it cannot ask it says that, in amber,
  with a *Try again*. It re-reads every time you open it, and tapping the
  choice already showing asks us again.

- **unreleased (2026-09-09)** — **A tap of the hold key is a pause button, and
  a long dictation can no longer vanish.** Tapping the key while Moe was
  talking always stopped the sound — before anything can know whether a press
  is a brush, a tap or a hold — and then started it again half a second later,
  so the gesture existed, made a stutter, and could not be made to stick. It
  now holds the reply where it is, the island says *paused — tap again to carry
  on*, and the next tap picks up from the same word. Holding the key is
  unchanged: it is still "let me say something", and a double-tap still stops
  everything.

  Separately: a spoken request longer than about half a minute could disappear
  entirely — the words appeared on the island as you spoke, and then no reply,
  no transcript, nothing. Moe gives its careful second read of what you said a
  time limit, in case the model wedges; that limit was a flat thirty seconds
  and did not grow with how long you had spoken, so on a minute of dictation it
  ran out while the transcription was still on its way, and the turn was thrown
  away ten seconds before the correct text arrived. The limit now grows with
  what you said, and if that read ever does fail, Moe falls back on the words
  it already heard and showed you rather than losing the turn.
- **unreleased (2026-09-09)** — **Setting up your machine in the cloud is one
  button, and there is nothing to carry.** It could not be done at all
  before: pairing meant carrying a twelve-character code to the machine, and
  a machine in the cloud has no screen, no chat of its own and nothing to
  type into. Your machine now asks us whether you have offered it a place,
  and we say yes only if you pressed *Set up my machine in the cloud* on a
  Mac that is already one of your devices, in the last fifteen minutes.
  Nobody else's machine can answer your invitation, and a machine whose owner
  has pressed nothing is told there is nothing for it. The fingerprint of the
  pairing is shown on your Mac so you can see it happen; where there really
  is a second screen to read a code off, Moe still shows both and refuses a
  mismatch.

- **unreleased (2026-09-09)** — **A machine can be enrolled before it can
  think.** Enrolling an away machine used to be done by Moe reading your
  pairing code out of a message, which meant the machine had to be able to
  think — and it cannot think until you have given it a brain, which you
  cannot do until it is enrolled. The machine now claims the ticket and
  checks the code with a small program of its own at start-up, with no model
  in the loop; the code is still compared on the machine and never by the
  model, and a mismatch still enrols nothing.

- **unreleased (2026-09-09)** — **WhatsApp is one QR code in Moe, the
  Telegram bot is called Moe, and Email asks for the server it reads from.**
  Linking WhatsApp no longer needs a Terminal, a developer toolchain or
  anything downloaded from a stranger: Moe shows the code on screen and shows
  a new one when it expires. The Telegram bot Moe makes for you is renamed to
  Moe rather than left named after the engine, and a link that has gone stale
  says so and is replaced instead of leaving you waiting on one that can
  never work again. Email now asks for the incoming (IMAP) server as well as
  the outgoing one — without it the connection saved happily and could never
  receive a message. SMS now asks for the public address Twilio posts to, for
  the same reason. And the chat apps you have connected move to the cloud by
  themselves when your machine is set up — Moe holds each bot's key from when
  you connected it, so there is nothing to find and nothing to type.

- **unreleased (2026-09-09)** — **Moe is signed with a Developer ID and
  notarized by Apple.** Opening a copy you downloaded is one dialog and one
  click: macOS says it checked the app and found nothing wrong, and you click
  Open. There is no trip to System Settings and no Privacy & Security step.

- **unreleased (2026-09-08)** — **A top-up block is never sold unless all of
  it can be added to your month, and if one ever gets through you are told.**
  Moe asks what the block costs before offering it, and says the top-up is
  unavailable rather than taking a payment it cannot credit in full. Before
  this, such a block could be paid for and then not credited at all, with
  nothing telling anybody. And if a payment does arrive for more than
  a single block may credit, it is credited up to that limit rather than
  refused outright, what you paid is recorded beside what was credited, your
  usage shows both, and a support ticket is opened about the difference — so
  the shortfall is a number somebody can act on rather than a line in a log
  nobody reads. The ticket is raised for us to see; it does not write to you.


- **unreleased (2026-09-08)** — **The Terms cover the things you can pay for,
  and the Privacy policy covers signing in and Stripe.** The Terms described a
  free-only product — "Moe is provided free of charge" — while the site sold two
  monthly subscriptions, so they were silent on everything a subscription needs
  and contradicted themselves on the one point they did mention. There is now a
  section 3, **Paid subscriptions**: who takes the money (Stripe, and your card
  number never reaches us), that it renews monthly until cancelled, that
  cancelling leaves you the rest of the month you bought, that part-months are
  not refunded but a statutory right still stands, that a failed card keeps
  working while Stripe retries, that a price change takes 30 days' notice and
  only bites at renewal, and that **a subscription cannot bill you more than its
  monthly price**. The Privacy policy stopped claiming "no accounts" — you still
  need none, but signing in with Google and paying both exist, and each now has
  its own paragraph saying exactly what leaves your Mac and to whom.

- **unreleased (2026-09-08)** — **Moe says it is in beta, and says who makes
  it.** Moe has been early all along and nowhere said so. Now it does, quietly
  and once per surface: a **Beta** chip beside the version in Settings › About
  & Licences with a line on what that means and how to report a problem; a line
  on the first screen of the welcome; a paragraph in the website's download
  sheet, said before you download rather than after; and a note in the footer
  of every page and at the top of Privacy and Terms. All of it points at the
  same thing to do — tell Moe, out loud or typed, and it writes the report
  itself. The Terms also stop saying `[COMPANY LEGAL NAME]` and
  `[JURISDICTION — set before launch]`: the agreement is with **Yisrael
  Gottlieb**, a sole proprietor, under the law of **New Jersey**, and section 6
  now says in as many words that beta software may break or change between
  versions.

- **unreleased (2026-09-09)** — **A machine that cannot rewrite its own
  settings now says so instead of reporting success.** Taking a brain away, or
  giving one, writes your machine's settings file — and if that file could not
  be read or rewritten, your machine used to report that everything had worked.
  One unusual character in it was enough. Now it says it cannot be used, on the
  channel an operator reads, and a removal that did not go through is tried
  again on the next sync rather than being marked done. If a model sign-in
  reappears on your machine after you have taken your brain away, that is
  reported too — it was invisible before.
- **unreleased (2026-09-09)** — **Taking a brain away never throws away a
  sign-in, and a machine that is fine stops saying it is broken.** If your
  machine had signed in to another model service, removing your brain moves
  that sign-in aside — and doing it several times in a row now keeps every one
  of them, where before the second could quietly replace the first. Your
  machine also stopped reporting "cannot think" for ever afterwards: it was
  counting the set-aside file as a fault, so a machine with a perfectly good
  brain kept raising the alarm and the real one got lost in it. Facts your
  machine notices are now reported as facts, and only a real problem is a
  problem.
- **unreleased (2026-09-08)** — **A machine that cannot think says so, and a
  revocation no longer throws away a sign-in it cannot give back.** Your
  machine's configuration is now kept by rule rather than by list: only
  settings we can name a reason for survive, so a leftover block cannot be a
  second brain under a name nobody thought of. If your machine was signed in to
  another model service, removing your brain moves that sign-in aside instead
  of deleting it. And a machine that comes up unable to think now says so where
  an operator will see it, rather than starting quietly and failing at you in
  the middle of a question.
- **unreleased (2026-09-08)** — **Your machine thinks with your own model
  account, and only yours.** It is also the *only* model account on it: when
  your machine takes yours on, it clears every other model key it can see,
  including ones an earlier setup may have left there, so nothing of ours or
  anybody else's is quietly still in play. If your machine ever loses the key
  you gave it, it now says so and asks for it again rather than reporting
  everything is fine. Under *Moe Away*, a new *What it thinks with*:
  give your machine a key you pay for, your Claude plan (through
  `claude setup-token`, which you run yourself), or your ChatGPT sign-in.
  Whatever you give it is sealed on your Mac and only your machine can open
  it — the service in between carries it and cannot read it. Until you give it
  one your machine cannot think and says so on the channel you read; it does
  not fall back to anybody else's account, ours included. Changing it removes
  the old one rather than leaving it there working, and *Remove…* takes it
  away entirely (which does not cancel the key at your provider — do that
  there too, if that is what you want). "Every other model key it can see" now
  includes the settings that decide *where* a key is sent, not only the keys
  themselves: a leftover address pointing your provider's traffic somewhere
  else is cleared the same way, because a key aimed at the wrong place is as
  much a leak as a key left behind. And if you paste a key into the Model or
  Address box by mistake — one line above or below the box that hides what you
  type — Moe says so and refuses to send it, rather than putting it somewhere
  it would be readable. "Every other model key" also now covers the ones your
  machine can be told to read under a name nobody chose in advance, all four of
  the settings that decide which certificate it will trust on the way out, and
  **whole blocks of second-choice providers** — a machine that has been given a
  fallback is a machine that keeps thinking after you take its brain away, and
  it did, until this was found.
  machine can be told to read under a name nobody chose in advance, and the
  settings that decide which certificate it will trust on the way out — a key
  sent to the right address over the wrong connection is no safer than one sent
  to the wrong address.
  it would be readable.
- **unreleased (2026-09-08)** — **Meetings: knowing who is talking, and
  saying so when Moe can't.** Moe records the call's audio separately from
  your microphone, and that is what tells your voice from everyone else's. It
  could stop carrying sound without anything noticing — the recording went on,
  the panel looked normal, and at the end everybody in the room had been
  written down as you, along with a to-do list that had each task twice. Moe
  now watches for it, repairs it while the meeting is still running, and if
  nothing works says so in the panel rather than finding out in the notes an
  hour later. The panel itself is quieter: the transcript opens first, only
  Stop is in front of you (the rest is behind **⋯**, and unfolds by itself
  whenever something it controls is running), and under the transcript is the
  one number that would have caught this — **"331 lines · 4 voices"**. **When
  the call ends**, Moe now stops, saves and writes the notes without asking;
  it is its own switch, because starting a recording is your decision and
  stopping one you already started is not. Action items no longer arrive
  twice under two owners, talk about the recording itself is no longer a task,
  and if the notes fail your AI gets a second attempt before Moe gives up.
- **unreleased (2026-09-08)** — **Fixes to the part that thinks now reach a
  Mac that already has Moe.** Every version of Moe names the exact version of
  its agent it was built against, and until now that name only ever changed
  anything on a Mac where the agent had been installed from a checkout — which
  is almost nobody. On a Mac that got its agent inside the download, Moe wrote
  "I cannot update this" to a log and did nothing, so a fix could land, be
  released, and reach no one, with nothing anywhere saying so. Moe now brings
  across the files that changed between the two versions and leaves the rest —
  in particular the agent's ~250 MB Python environment, which it never
  rebuilds. When it cannot do that safely it stops and says which question it
  stopped on: an update that would change what that environment contains, a
  file edited on your Mac since the copy was laid down, or a copy that carries
  no record of which version it is. Nothing is ever replaced wholesale, and
  "move it aside and start again" — which used to be the printed advice, and
  would have deleted a working agent — is gone.
- **unreleased (2026-09-08)** — **One browser, not two.** For web work Moe now
  uses a browser of its own — reading pages as text and clicking exactly what
  it found, with nothing appearing on your screen — and it is the same browser
  whether Moe is on your Mac or working away from it. A short-lived second way
  of reading Chrome, added yesterday, is gone: it could only ever read a
  browser Moe had opened, which is what the main one already does, and having
  two made Moe worse at both. Your own open tabs are unchanged: Moe looks at
  those on screen, as it does any other app.
- **unreleased (2026-09-08)** — **Scheduled work on the away machine still
  happens while it sleeps.** A machine that is asleep has no clock, so anything
  timed on it would have quietly stopped the moment it started sleeping between
  messages. Now the machine tells us when its next scheduled thing is due and we
  wake it a couple of minutes beforehand; it does the thing and goes back to
  sleep. Nothing to switch on. Three things worth knowing: a repeating thing
  missed while everything was off happens **once** when the machine next comes
  up, not once for each time it was missed; a one-off at an exact minute is
  tight, because the machine has about two minutes to be working after the
  moment you named and past that the engine lets it go rather than doing it
  late; and this does **not** move the reminders you set up in *Settings ›
  Reminders* — those still run on your Mac. See *Moe Away — when your Mac is
  shut*.
- **unreleased (2026-09-07)** — **Chat apps in the cloud: the whole path,
  written down before the screen exists.** Moe can now, in principle, take a
  message from Telegram, Slack, Discord, WhatsApp or LINE at the service your
  devices meet at, route it to whichever of your Macs or machines is awake,
  and answer from there — one bot, one conversation, failing over on its own.
  A chat Moe does not know waits for you to say yes rather than being answered
  or ignored. **None of this is reachable yet**: there is no screen for it and
  the receiving half is not switched on for real accounts, which is why the
  section above says Coming rather than describing something you can find. It
  is documented now so the shape is settled before the screen is drawn.
- **unreleased (2026-09-07)** — **We do not run out of machines because
  somebody forgot to top us up.** The stock your machine is handed out of now
  refills itself, sized on how many people subscribed in the last week, with
  ceilings on how many are prepared and how fast. An unprepared machine costs
  nothing to keep, so we keep plenty. If preparing one fails for a reason that
  will not improve on its own — our cloud account is out of room, or our
  credential has stopped working — it stops and tells us instead of retrying
  quietly; an ordinary hiccup is retried a few times and then left for a
  person. We also keep a deliberate cap on how many we will prepare, set low
  while this is new and raised as more people arrive. Nothing changes for you
  except that "we have run out" should stop happening by accident. See
  *Moe Away — when your Mac is shut*.
- **unreleased (2026-09-07)** — **Your Away machine now sleeps when you are
  not using it, and starts back up when you write.** About half an hour
  after its last word to you it is put to sleep; the next message starts
  it again, so **the first message after a quiet spell is slower than the
  rest** — we have not measured by how much yet, and would rather say so
  than invent a figure. Nothing is lost: a message that arrives while it is
  asleep is kept and handed over when it is back. **It is never put to sleep
  in the middle of answering you**, including a long piece of research that
  says "let me look into that" and then thinks for twenty minutes — the
  first part of an answer does not end the answer. Only a message genuinely
  meant for you can start it; nothing on the internet can, and neither a
  cancelled subscription nor a machine that has been deliberately held off is
  restarted by one. Before this the machine ran around the clock whether or
  not you ever spoke to it. See *Moe Away — when your Mac is shut*.

- **unreleased (2026-09-07)** — **Paying for Away is what will make your
  machine, with nobody at our end pressing anything.** *(Corrected
  2026-09-09 — the earlier version of this entry is retired: the code landed; the
  service it runs on holds no credential to make one with, so paying still
  sets your plan and stops there. The rest of this entry describes what
  happens once it is switched on.)* Subscribe and it is made for
  you; it has no address on the internet, so nothing out there can reach it or
  wake it — and, the other side of the same fact, it cannot reach you until
  you enrol it from your Mac. If it cannot be made — we are down, or we have
  run out — the payment is never lost and never refused for that reason, and
  we can see that you are owed one and finish it. Your machine is made
  **switched off** and starting to enrol it is what turns it on, so a
  subscription you have not set up yet costs you nothing but the storage.
  Cancelling **stops** the machine and
  deletes nothing: its copy of your conversations and what Moe learned while
  you were away stay where they are, and subscribing again starts the same
  machine back up. Kept for 90 days, then one email, then deleted 30 days
  after that if we hear nothing — and never automatically. See
  *Moe Away — when your Mac is shut*.

- **unreleased (2026-09-08)** — **Superseded the same week it was written:
  there is no monthly thinking allowance.** This entry described one, and it
  was true while the machine thought on our credential. It does not any more:
  every machine runs on your own Claude subscription, Codex subscription or
  API key, so we pay for none of the thinking and cap none of it. What a plan
  buys is the machine — somewhere for Moe to keep running when your Mac is
  shut. The counting still happens and is still honest about what it does not
  cover; nothing stops for it. A limit on **your own** spending, that you set
  and can switch off, is a fair thing to want and is not built yet. See *What
  your plan covers away from your Mac, and what happens when you reach it*.

- **unreleased (2026-09-07)** — **Your account writes to you when something
  happens to it.** There was one email in a whole life with Moe — the welcome
  — so you could pay, be charged, have a card declined, cancel, watch the plan
  end and hear nothing at all. A plan ending in silence looks like something
  broke. There are now nine, listed under *Emails about your account*: paying,
  changing plan, a declined card (once, not on all four retries), cancelling,
  un-cancelling, the plan actually ending, and an account being put on hold or
  taken off it. Cancelling reads the same whether you did it or we did. A
  renewal still gets nothing, because Stripe sends its own receipt. And the
  welcome no longer says a plan gives you "Moe that keeps going while your Mac
  is closed" — it does not keep going yet, whatever else has changed. Paying
  does now make you a machine (see the entry above), so the mail about
  starting a plan says that instead, along with the part that is still yours:
  it arrives switched off and setting it up from your Mac is what turns it on.

- **unreleased (2026-09-07)** — *Internal.* The admin at admin.moebot.app has
  a **Cloud** page: for each person, what happened to them end to end as a
  timeline, whether they have a cloud machine, what it costs, and what is
  wrong. Its one rule is that nothing it could not check is ever drawn as
  nought — a number it does not have is a dash and the reason beside it. When
  it was written the honest answer on every row was that nobody had a machine,
  because nothing made one; paying makes one now (see the entry above), and
  the page's rule is unchanged — it still draws only what it can check. It asks Fly
  nothing and needs no new key: every machine state is what we last told Fly
  to do, said so on the page, and the things that can therefore go unseen are
  listed rather than left to be found. Prices carry their region ($5.70 a
  month in `iad`), and what nothing measures — model spend above all — is
  named on the cost card instead of being left off it. See `docs/ADMIN.md` §10.

- **unreleased (2026-09-07)** — **Moe knows what you just connected.**
  Connect a mailbox and ask, in the same breath, "are you connected to my
  Gmail?" and Moe now says yes. It used to say *"no mailbox is added yet,
  so I can't see your Gmail at all — want me to walk you through connecting
  it?"*, because the list it answers from was rebuilt on a ten-minute timer
  and the copy in front of the model was fixed when the conversation
  started. Both are fixed: the list is rewritten the instant anything is
  connected, renamed or removed — however you did it — and a conversation
  already under way picks it up on your next message. Two mailboxes on one
  service are now both named, where only the first used to be. See *How Moe
  knows what is connected*.

- **unreleased (2026-09-07)** — **Not every one of the five hundred is
  one-click, and now we can say how many.** A new check walks the whole
  services list against the broker's own record of each one and reports
  which rows promise a sign-in the service does not offer. First run:
  1,246 of 1,378 want an API key the screen never asks for, and 13 need no
  sign-in at all. The count is a ceiling that may only go down, and the
  check says out loud what it did not prove — that a sign-in completes or a
  tool call works, neither of which can be known without connecting an
  account. See *Google, and about five hundred other services*.

- **unreleased (2026-09-07)** — **Your own WhatsApp is back on the page.** It
  was never removed, but it was folded into the collapsed *Advanced* section
  at the foot of Connections, so the only row called WhatsApp was the broker's
  — which reaches WhatsApp *Business* accounts and cannot see a personal one.
  Moe's own row now sits with the rest, and the broker's is called *WhatsApp
  Business* and says so. See *Your own WhatsApp and Telegram, and the ones that
  only share a name*.

- **unreleased (2026-09-07)** — **Connecting your own Telegram no longer ends
  in a database error.** When Telegram refused a phone number, Moe tidied up
  and then tidied up again — and the second pass rebuilt the sign-in file it
  had just deleted and failed on it, so what reached you was
  `sqlite3.OperationalError: no such table: update_state` and some advice
  about api ids that had nothing to do with it. Moe's own sentence — which
  had been written correctly all along — is what you see now. A sign-in file
  left broken or empty by an interrupted attempt is thrown away and rebuilt
  rather than inherited, and no setup screen anywhere in Moe can show you the
  bottom of a crash again: if a step falls over without saying why, you get a
  plain sentence and "nothing was changed".

- **unreleased (2026-09-07)** — **Making a Telegram bot no longer costs you a
  second bot when it times out.** If nobody taps *Create Bot* before Moe stops
  waiting, Moe remembers the request and picks up the *same* bot next time you
  try, instead of asking Telegram for a new one and leaving the one you just
  made with nothing listening for it.

- **unreleased (2026-09-07)** — **The Upgrade tab knows you paid.** It is
  called *Away* the moment Moe hears about your plan rather than after the
  next restart — on a Mac with conversation syncing off, which is the
  default, it used to say *Upgrade* for ever. The two pricing cards no longer
  flash past on the way to your own screen. **Check plan** now says what it
  found, beside the button, instead of appearing to do nothing. And a
  renewal date shows up at all: Stripe had moved where it keeps one, so
  *Renews …* had never once been drawn for anybody. **Add a device** is gone,
  replaced by what is actually true — install Moe on the other Mac and sign
  in with the same Google account — because there was nowhere on a second Mac
  to type the code it used to give you. **Your Licence** is gone too: Moe is
  a subscription and that screen had nothing to say. The cloud machine is now
  described as what it is — designed, not built, and not something paying
  turns on. See *Settings › Upgrade / Away*.

- **unreleased (2026-09-07)** — **The cloud voice has something to ask.**
  Moe asked for a one-time token every time it opened a cloud voice or ears
  connection, and there was nothing on the other end to answer — so every
  request failed and every reply was spoken by the voice on the Mac. The
  two services are now there, they check that your plan includes the cloud
  voice before spending anything, and they count the month for the whole
  account rather than per Mac: **Away** 500,000 spoken characters and 6
  hours of listening, **Away+** 1,500,000 and 20 hours, resetting on the
  1st. The vendors' own keys stay on Moe's server and never reach your Mac.
  See *The cloud voice and ears, on paid plans*.

- **unreleased (2026-09-07)** — **A voice Moe could not use no longer
  pretends it worked.** Choosing Cloud and Clive and pressing "Use and
  preview" played a Kokoro voice with nothing on screen to say so — the
  picker still read Cloud and Clive, and the only trace was one line in a
  log file, written at most once however many times you pressed it. Moe
  still falls back to the voice on your Mac, because being left silent is
  worse, but it now says which engine it is using instead of the one you
  chose and why, and keeps your choice for when it can be used again. The
  same line appears when PocketTTS has not been downloaded. Cloud also now
  starts on **Clive** rather than the first name on the list, and PocketTTS
  on **Peter**. See *Moe's own voice*.

- **unreleased (2026-09-07)** — **The four moments around paying, which each
  said nothing or said the wrong thing.** Signing in with Google left you on
  `http://127.0.0.1:<a port>/?code=…` — an address that reads as a mistake at
  the exact moment you have handed over your Google account; the browser now
  ends on **memoe.app/signed-in**, and a sign-in that did not finish says so
  instead of congratulating you. Paying dropped you on the marketing homepage,
  because Stripe's "you paid" and "you cancelled" pages were the same string;
  paying now lands on **memoe.app/thanks**, which names the plan you bought
  and tells you what to do next, and cancelling still leaves you where you
  started. The first time Moe sees a plan, **Settings › Away opens with a
  welcome** rather than a renewal date: three buttons that go to the screen
  that does the thing, including one that lands you on the voice tab with
  **Cloud** in the engine list. And **Message Moe** told everybody, paid or
  free, that Moe answers only while the Mac is awake — true, but written as
  though a plan bought you nothing; both it and **Connections** now follow
  your plan. What none of it does is promise a Moe that runs while your Mac is
  shut, because that is not built: there is a plain paragraph about it above,
  and a test that fails if any of these screens starts claiming otherwise.

- **unreleased (2026-09-07)** — **What Moe knows about you, written down
  at last.** Memory has a chapter of its own: the Memory screen, where
  every fact Moe holds is listed with where it came from and when, and any
  one of them can be corrected or forgotten; which of the four ways in put
  it there — something you said, the daily pass, a meeting, or a note you
  wrote yourself; what Moe keeps and what it deliberately lets go, and the
  size it stops at; and where it lives on this Mac, what travels to your
  other devices, and what deleting a fact really destroys. The one thing
  that is not built yet is said plainly rather than left out: when Moe
  meets a fact you deleted, it sets it aside as a question, and nothing
  shows you that question yet. See *Memory — what Moe knows about you*.

- **unreleased (2026-09-07)** — **"Make it sound like me."** Moe ships the
  *humanizer* writing skill, on by default: ask for a draft, an email or a
  file to sound less like a chatbot and Moe strips the tells (not-X-but-Y,
  one-line closers, forced triads, dashes everywhere, bold labels, "I hope
  this helps") without changing a fact. It is under Settings › Brain › Skills as
  *humanizer* in *Writing*, needs nothing installed, and is only opened when
  you ask. See *Sounding like you, not like a chatbot*.

- **unreleased (2026-09-07)** — Connections no longer opens with 1,378
  brokered services in it. It lists the 119 where signing in is the whole job
  — the names you would recognise — each with that company's own logo, and
  finds the rest the moment you type a name. Anything you have already
  connected stays at the top under Yours regardless. See *Google, and about
  five hundred other services*.

- **unreleased (2026-09-07)** — "Quit and reopen Moe" on the welcome flow's
  key screen now reopens Moe and comes back to that screen. It used to quit
  and stay quit (the new copy was asked for while the old one was still
  closing), and reopening by hand skipped the last three screens.

- **unreleased (2026-09-07)** — Moe no longer keeps half its data in a second,
  empty `~/.moe` folder when one happens to exist before the first launch: a
  stray one holding nothing of yours is folded into the real home.

- **unreleased (2026-09-07)** — The download's disk image opens on a window
  with the way in drawn on it: Moe, an arrow, Applications, and the one thing
  to do — drag it across, then open it from there.

- **unreleased (2026-09-07)** — The voice engines: the system voice is gone
  (Kokoro, PocketTTS and Cloud remain), Cloud is on the list for everyone and
  takes the free plan to Upgrade, and the PocketTTS download says its size
  before you press Download, shows a percentage while it comes, and can be
  cancelled. "Use and preview" no longer starts a 939 MB download by itself.

- **unreleased (2026-09-07)** — Connections lists Gmail, Calendar, Drive and
  the rest of the brokered services on a Mac that has never signed in, each
  saying "Sign in with Google to connect", with the reason on the panel. They
  used to appear only after a sign-in nothing on the screen offered.

- **unreleased (2026-09-07)** — Signing in with Google works on a freshly
  downloaded Moe. It used to fail after Google had said yes, with a message
  about an edge address there was no field for. The first sign-in now also
  earns a short welcome email — what the account is for, what to do next,
  and that nothing has been charged. A second Mac joining gets no email.

- **unreleased (2026-09-07)** — PocketTTS can be downloaded from Settings ›
  Voice. The engine is not in the app, and until now the pane only said so:
  choosing it and pressing "Use and preview" fell back to Kokoro with no way
  to fetch it. The Download row has a button — 939 MB, once — with a bar that
  shows how far it is, and "Use and preview" fetches it first when it is not
  here. A download that was stopped half-way no longer counts as downloaded.

- **unreleased (2026-09-07)** — *Internal.* The admin at admin.moebot.app got
  Moe's own look, a Social page for what is drafted, scheduled and out, a
  Visitors page so the team's own browsers leave the numbers, and full
  control over an account: tier, routing, suspend, revoke a device, cancel
  through Stripe, email the person.

- **unreleased (2026-09-15)** — *Internal.* The admin's visitor and Download
  click numbers are now everybody **but** us. Marking a browser as ours — the
  "That's me" button, or opening memoe.app with `#im-staff` on that browser —
  takes every line it ever sent out of the numbers, past as well as future,
  where the site's own flag used to mark only what came after it; and a
  visitor is now something that says `Mozilla/` first, so a headless runner
  nobody has a name for is not counted as a person. On the day it was written
  half of everything the site had counted was the owner's own two Chrome
  profiles. See `docs/ADMIN.md` §9.

- **unreleased (2026-09-15)** — The Download sheet opens on the download. It
  used to open on a paragraph of introduction, a beta notice, the whole
  first-open explanation and a list of what is in the box, with the Download
  button under all of it — so on a laptop you scrolled a pop-up to reach the
  button the pop-up exists for. Now it is a line about what is in the app, the
  button, and one sentence about the first time you open it; the full
  first-open notice and the beta note are each one click away, unchanged. The
  panel that confirms the download has started now takes itself away after a
  few seconds, rather than sitting over the page until you close it.

- **unreleased (2026-09-15)** — The playground now tells you how to talk to
  it. "Hold space and talk" was a small pill under the notch that disappeared
  at the first interaction, so it was easy to read the whole page without
  realising there was anything to do. It starts large now, shrinks to that
  pill the first time you actually hold space — your browser remembers, so it
  only asks once — and stays as a small reminder afterwards instead of
  vanishing.

- **unreleased (2026-09-15)** — *Internal.* The rest of the admin's Overview
  is everybody but us too. **That's us** on an account takes it out of signed
  up, seen this week, live devices, paying, the tiers and the sign-up chart at
  once, and leaves it on every screen that helps a person. GitHub's "dmg
  fetches" is gone: it counted Moe updating itself on every Mac alongside a
  real download and could never be made true. And the Cloud page, which
  opened with the Overview's own cards and ran to eight headings, is one strip
  of figures and four folds — every caveat kept, each with its count on the
  outside. See `docs/ADMIN.md` §9 and §10.

- **unreleased (2026-09-07)** — **Moe no longer gives up on its own brain.**
  If the part of Moe that thinks kept stopping, Moe used to stop trying until
  you quit and reopened it. Now it says so once and keeps trying quietly, about
  once a minute, until it's back. And when something else on the Mac has
  started that part behind Moe's back and is holding it without answering —
  which is what left one Moe brainless for ten minutes on 2026-09-07 — Moe
  takes it back itself instead of counting the refusals as crashes. See
  *Getting started*.

- **unreleased (2026-09-07)** — **A breath is not the end of your turn.** When
  you pause after something that sounds finished, Moe begins on it at once but
  keeps listening until its first word would be heard; go on inside that
  window and both halves are joined into one request, the unheard half-answer
  dropped. Measured on ten days of one person's log: 64 of the 108 times Moe
  spoke over them, it had judged a complete-sounding clause finished (at
  94–99 % confidence, which no threshold separates from a real ending) and
  they went on one to three seconds later — well inside the two seconds Moe
  takes to start speaking. Words said in the follow-up window that the
  microphone's voice detector missed now get the same checks as any other
  turn rather than ending it on the spot.
- **unreleased (2026-09-07)** — **Moe can see your screen again, on your own
  Claude subscription.** Describing a screenshot was being sent to a separate
  paid service that Moe had been configured to use automatically. When that
  service's balance ran out, every attempt to look at the screen failed with
  a payment error about a company you never signed up with — so Moe could not
  see your Mac at all. It now uses the Claude subscription you already have,
  through the same connection it thinks with: no extra key, no second bill,
  and nothing to set up. If you have deliberately chosen a vision service of
  your own, that still wins; Moe only steps in when it cannot be reached.
- **unreleased (2026-09-08)** — **The send sheet stopped opening over things
  that are not sends.** Opening a reply on screen raised "Email — Moe wants
  to send this" over a script that opens a window and sends nothing; filing a
  support ticket *about* a Gmail problem raised a Gmail send sheet, because
  the ticket's own words were being read as the command. Moe now reads what a
  command does rather than the text it carries, and treats composing a draft
  as composing a draft. And when a sheet is up, Moe waits for you properly:
  it used to give up after thirty seconds, leaving the sheet on your screen
  with nothing behind it, telling itself the send had failed and blocking
  everything else it tried for the rest of the turn — which is why the sheet
  sometimes appeared twice. See *Before anything goes out*.
- **unreleased (2026-09-07)** — **Moe offers to report its own problems, and
  tells you on the island when there's news.** When something of Moe's
  fails, it says so and offers to report it — one sentence, your call. And
  a plan from the Moe team, or a fix, now reaches you on the island as an
  amber pulse, not only by email: Moe reads you the plan and you answer out
  loud. Someone who never signed in with an email is told the same way.

- **unreleased (2026-09-07)** — **The playground on memoe.app is a Mac Moe
  can actually work.** One world behind every window and every answer; real
  tools instead of a "DO:" line, with the confirm sheet before anything
  sends or buys; a pointer that drives Preview's export sheet; a shop with a
  basket and checkout; every dock icon opening a real window; FaceTime that
  triggers the meeting flow — the call-detected card, the consent sheet, the
  red ring, the live transcript, the notes. Its voice is Inworld TTS-2 Flash,
  gapless, capped per visitor and per day. `docs/PLAYGROUND-PLAN.md`.

- **unreleased (2026-09-07)** — **"Report this to the Moe team."** Say it and
  Moe files the report itself, from the conversation it was just in — what
  you asked, what it did, where it went wrong — or files one on its own when
  it sees something of its own failing. You get an email that it's being
  looked at, an email with the plan and a yes/no before anything changes for
  you, and an email when it's fixed. See *When Moe itself breaks*.
- **unreleased (2026-09-07)** — **Moe's own name, in Moe's own screens.** The
  Connect sheet showed lines written for a terminal — "Creating your Telegram
  bot through Hermes", "Message your bot once Hermes restarts" — naming the
  engine Moe is built on rather than Moe. Seventeen of those now say Moe, and
  anything a connection prints is renamed on its way to the screen, so the next
  one written cannot show through either.

- **unreleased (2026-09-07)** — **"Needs you" now means something.** Services
  reached through the broker that you had simply never connected were being
  listed at the top of Connections in amber, under a heading counting how many
  "need you" — with a line beneath each one saying, correctly, that it was not
  connected. Six Google services sat there, above the ones that really were
  connected, none of them anything you had done or needed to undo. They now sit
  in the ordinary list with everything else you have not connected. The amber
  section is what it always said it was: things you set up that have since
  stopped working — plus a sign-in you began and did not finish, which is the
  one kind of unconnected thing that really is waiting on you. Those rows also
  offered a **Disconnect** that could not work, because there was no sign-in on
  file to forget; it is gone, for the same reason.
- **unreleased (2026-09-06)** — **The turn is read back while you are still
  stopping.** The accurate recogniser now starts the moment the microphone
  hears you stop, and when nothing follows but quiet that read stands, taking
  its whole cost — 150 ms on a typical turn, 390 ms on a long one — out of
  the gap between your last word and the answer; anything said after it
  sends the whole turn back to be read again.
- **unreleased (2026-09-06/07)** — **Away and Moe Away, in one place.** Eight
  changes landed over the weekend. Each line says where it is for you: *on
  your Mac* means you already have it; *0.3.13* means it arrived in that
  update; *in the cloud* means live now with nothing to update; *next update*
  means it is built and waits for a release.
  - *On your Mac.* **Turning syncing on or off takes effect straight away** —
    Moe restarts the part that thinks for you, only when something that
    matters changed, instead of waiting for the next launch.
  - *On your Mac.* **Telegram and WhatsApp keep working alongside Away.**
    Turning Away on had switched off every chat app Moe talks to directly, and
    the Connections screen kept calling them connected. Both are fixed: the
    chat apps you set up stay on, and if one is ever switched off the row says
    *"Moe is not listening here — messages for this account are going to your
    other devices instead"* rather than claiming to work.
  - *In the cloud.* **A message that arrives while everything is off reaches
    the machine when it wakes** — oldest first, a few at a time, one per
    conversation until it is answered, each tried twice at most; only the
    machine can read it, so your Mac cannot pick it up, and if the machine
    never returns it waits. A second message no longer waits for the first,
    a long answer is no longer asked twice, and each reply is matched to the
    message it answers when the machine says which. The Away section says
    the rest, including what it costs when the machine cannot say.
  - *Next update (after 0.3.13).* **A Mac that holds your account only for Gmail or Drive —
    syncing off — is never handed your messages** to answer, and never opens
    the connection that would carry them. Nothing had gone wrong; the door was
    simply not locked. On a Mac from before 0.3.13 nothing is handed over
    either, but only because its thinking part cannot connect at all (below).
  - *In the cloud.* **A device you remove while it is offline is told so**, the
    first time it tries to come back. Whether it then stops asking depends on
    its thinking part: the new one does, after one try; the one inside 0.3.12
    keeps knocking, harmlessly, refused every time.
  - *In the cloud, half.* **An arriving message is also sealed to the one
    device that answers it**, so the edge holds it readable only for as long
    as it takes to pass it on. The machine can open it today; a Mac cannot yet,
    so the readable copy still travels beside it — deliberately — until every
    device can.
  - *0.3.13.* **The part that thinks follows Moe.** A new Moe used to name
    a newer thinking part and nobody who already had one ever received it. Moe
    now compares the two when it opens and brings an install *it made itself*
    up to date in the background, restarting it once, only ever forward; an
    install someone has been working in is left alone with the reason logged,
    and one that came inside the download is reported, not moved.
  - *0.3.13.* **A freshly downloaded Moe can take part in Away.** The thinking
    part inside 0.3.12 and earlier is older than Away's connection: turning
    syncing on is quietly refused, and nothing says so. A Mac that has never run
    Moe gets the right one from 0.3.13. **A Mac that already had Moe does
    not** — updating and reinstalling both leave the old one in place on
    purpose — and until we build a way to move it along, deleting the `.hermes`
    folder in your home folder and reopening Moe is the only thing that works.
    The Away section says so at the top.
- **unreleased (2026-09-06)** — **GitHub, which Moe could reach and nobody
  could find.** GitHub is now a row in Connections. It asks for a token rather
  than a sign-in page, because GitHub — unlike GitLab, Linear or Notion — gives
  apps no way to introduce themselves automatically, so a token is the only
  honest route; the scopes you give it decide what Moe can reach. Connected,
  Moe reads repositories, issues, pull requests, releases and code, and can
  open pull requests, push, merge and comment — GitHub marks which of its own
  tools write, so Moe asks first, every time. Separately, if you already use
  the `gh` command line, Moe uses that sign-in as it stands, read-only. That
  second path shipped long ago and was unreachable: Moe was never told the tool
  existed, so it never occurred to it to look. It also used to answer "you have
  no pull requests" when the real answer was "you are not signed in" — an empty
  list read as a fact. It now says which, and points at the Connections row
  rather than at a terminal command.

- **unreleased (2026-09-06)** — **The cloud voice and ears, on paid plans.**
  Away and Away+ can hear through AssemblyAI and speak through Inworld, on a
  monthly allowance, falling back to the voice and ears on your Mac at the cap
  or on any error; the free plan is untouched and sends nothing. The switch is
  in *Settings › Voice › Talking to Moe*, with a status line that says whether
  the cloud is on, not part of your plan, or how much of the month is used.
  Speaking: Settings › Voice offers "Cloud voice (Inworld)" on a Mac that may
  use it — sentences are rendered in the cloud over one kept-warm connection
  and streamed back as they are spoken, interrupting Moe stops the render at
  the server, and if the cloud is out of reach mid-reply Moe speaks that
  sentence with its own voice instead of dropping it.
  Hearing: on a paid plan, and in one of the eighteen languages the cloud
  recogniser knows (English, Spanish, French, German, Italian, Portuguese,
  Turkish, Dutch, Swedish, Norwegian, Danish, Finnish, Hindi, Vietnamese,
  Arabic, Hebrew, Japanese, Chinese), what you say streams to the cloud
  recogniser as you speak — it knows your names and vocabulary and what Moe
  just said — and the careful read arrives a fraction of a second after you
  stop; if it cannot answer for any reason, that utterance is read on your
  Mac as before and the cloud is rested for a minute.
  Later the same day: on a developer's Mac using vendor keys from the
  keychain, the credential for each cloud turn was taking five to six
  seconds to fetch — the key read, not the network — and now takes under a
  tenth of one; the log's "credential minted" line says how long the key
  read and the request each took.
- **unreleased (2026-09-06)** — **Fix the words before they go.** The sheet
  that asks before Moe sends anything now lets you rewrite the message — and
  a mail's subject — in place and send that, instead of cancelling and asking
  Moe to try again. Every route through the sheet sends what you typed:
  Moe's own mail, Telegram and WhatsApp connections, and everything that goes
  out through the thinking part's tools, Google via Composio included. The
  recipient stays as it was. If the words cannot be put back where they came
  from, nothing is sent and Moe says so, rather than sending the original.
- **unreleased (2026-09-06)** — **Reply on the amber card, and the dialogs
  that should not have been.** The card under the glow has a third button:
  **Reply** opens a field on the card, so "stop reminding me about that" is
  typed straight at the message it is about, and Moe acts on it. Doing so no
  longer raises a permission dialog headed "Hermes" over Moe's own follow-up
  tool — a bookkeeping tool of Moe's had been left out of the list of what
  Moe recognises. The send sheet for a Gmail reply no longer puts the
  thread's sixteen-character id on the To line ahead of the people; it
  names the people, and only them. And the Google route through Composio is
  judged by what is actually being done rather than by the one tool it all
  travels in: searching mail, finding events and reading files no longer
  ask; sending, replying, inviting guests and sharing a file bring up the
  send sheet headed by the right service; a spreadsheet edit or a new task
  asks once, with an *Always allow* that remembers that one action and no
  other. The section *Before anything goes out* is new and says which
  connectors ask, and which never do.
- **unreleased (2026-09-06)** — **"Hey Moe" waits for you to finish asking, and
  hears you properly again.** A morning change that saved a lot of idle CPU
  had also switched off the microphone's gain control and noise suppression
  whenever Moe was listening, which is why the name was missed and what you
  said after it came back as nonsense; that processing is back on for every
  moment Moe is listening or talking, and off only while it idles. Separately,
  Moe no longer treats the end of "Hey Moe" as the end of your request — it
  waits until you actually start speaking, or four seconds, before deciding.
  Interrupting is cheaper: talking over Moe or tapping the key drops the
  answer in progress without restarting Moe's train of thought, so the next
  reply comes in the usual few seconds rather than fifteen. A double-tap of
  right ⌥ stops cleanly, without the first tap flashing the notch, taking a
  screenshot and resuming for a third of a second first. And a cough while
  Moe is thinking no longer uses up your one chance to interrupt the reply
  that follows. And when you do talk over Moe and it turns out to be nothing —
  a cough, an "mm-hmm" — the reply now pauses and carries on from the exact
  word, instead of stopping and starting the sentence again. And if you talk
  fast without pausing, Moe no longer cuts you off three seconds after a
  clause that sounded unfinished — as long as words keep coming, it keeps
  listening. And when you pause right after a word that points forward
  ("go to those…", "and then…"), Moe holds the door for half a second
  before deciding you are done, so a breath mid-request is not the end of
  it. The full investigation is in `VOICE-DEEP-DIVE-2026-09-06.md`.
- **unreleased (2026-09-06)** — **A stop you can see and press, instead of one
  Moe guessed at.** When Moe is using your screen the notch now turns teal, and
  hovering it shows which app it is in and a stop button that ends the run
  outright. This replaces something that was quietly making Moe unusable: it
  used to watch the mouse and keyboard and stop by itself if it thought you had
  taken over, but the way it delivers typing is built to be indistinguishable
  from a real keyboard, so it kept catching *itself* — refusing to work and
  reporting that you had touched the mouse when you had not. One of those false
  stops sat there for thirty hours. All of that machinery is gone.

- **unreleased (2026-09-06)** — **Moe no longer says "yeah, on it" before it
  has been asked.** That opener was said from your Mac the moment you stopped
  talking, before the question had even reached the model — so it was the one
  thing Moe said that could not know anything about what you had asked. It is
  off now. You may notice a beat of silence where it used to be, and if that
  reads as Moe having crashed rather than Moe thinking, it is a single switch
  in Settings › Replies, "Say 'yeah, on it' straight away".

- **unreleased (2026-09-06)** — **Moe stops reading filenames and repeating
  itself.** While it worked it would sometimes say things no person would say
  out loud — "Reading multiagentsecurityreview.md L401 600", the same file
  four times with different line numbers, or a bare identifier read out digit
  by digit. It no longer says which file it is reading at all; if that is
  worth saying, Moe says it in its own words. And the short progress lines it
  falls back on now only cover the opening beat, so you should stop hearing
  "Running something on your Mac" over and over during one job — that one
  landed sixty-seven times in a single day's log.
- **unreleased (2026-09-06)** — **"Hey Moe" goes off five times less often when
  you did not say it.** The wake word was retrained on your own voice — the
  101 recordings you made, folded in with the generated ones — and the new
  model is both better at hearing you and much harder to set off by accident.
  Measured against recordings held back from the training, and against five
  and a half hours of other people's speech it had never heard:

  |  | before | now |
  |---|---|---|
  | heard you say "Hey Moe" | 59% | 63% |
  | woke when nobody said it | 0.93 an hour | **0.19 an hour** |

  About one accidental wake every five hours instead of one an hour. The same
  model can be tuned the other way — it will hear you 77% of the time if you
  are willing to accept a false wake every forty minutes — so if you would
  rather have that trade, it is one setting.

- **unreleased (2026-09-07)** — **Settings › Away had a facelift, and is
  called Upgrade until you have a plan.** It used to be an operator's screen —
  an address to type, a key to paste, device ids, a Sync button. Now it is
  written for the person paying: while you're free, two plan cards and what
  each does; once you have one, your plan and when it renews, the devices Moe
  is on, one switch for syncing your conversations, and Manage plan. The
  only code you will ever see there is the pairing code when you add a
  device, shown the way AirDrop shows one.

- **unreleased (2026-09-06)** — **Upgrading is a button now.** Settings › Away
  has a Plan section: what you are on, when it renews, and two buttons that
  open Stripe's checkout for Away ($20) or Away+ ($50). Paying there is what
  changes the plan; Moe never sees your card. *Manage plan* opens Stripe's own
  page to switch, update the card or cancel. Until the shop is switched on
  the buttons say so rather than pretending.

- **unreleased (2026-09-06)** — **Sign in with Google, the first time you
  connect a service.** Until now, connecting Gmail or Calendar through Moe on a
  fresh Mac could not work at all — the key that reaches those services was
  something only a developer could put in place. Now the first Connect asks
  you to sign in with Google (who you are, not access to your mail), gives
  this Mac its own place with us, and sets everything up behind the scenes in
  the same click. Nothing you say is sent anywhere by signing in; the switch
  for that is separate and stays off. Connect nothing and you are never asked.

- **unreleased (2026-09-06)** — **Moe now knows which plan you are on, and the
  ceiling on connected services goes up with it.** Until today it worked this
  out from a file on your Mac that meant something else entirely — whether Moe
  was syncing your conversations — which is a question about backup, not about
  billing. Someone paying, but keeping their conversations on their own Mac,
  read as free. Your plan now comes from your account, Moe checks it about once
  an hour, and it remembers the answer for up to a month so a few days offline
  costs you nothing. The number of requests Moe will make to Gmail, Calendar
  and the rest each hour and each day rises with the plan; if we cannot reach
  your account for a month, it settles back to the free ceiling rather than
  guessing.

- **unreleased (2026-09-06)** — **"Asking is free, watching is paid" is now
  something Moe does, not something we wrote down.** It had been written in
  five places and enforced in none: nothing stopped a background pass on a
  free Mac from reaching into Google on its own, and the first person to add
  a scheduled mail check would have walked straight past the rule without
  ever meeting it. Now a background pass that reaches for a connected service
  on a free Mac is stopped before the request is made, and Moe says once what
  it did not do rather than leaving you to notice a mailbox that stopped being
  watched. Asking for the same thing yourself is untouched — free is the same
  services without the clock, not a smaller set of them. Separately, and on
  every Moe including a paid one, there is now a ceiling on how many requests
  an hour and a day Moe will make to these services before it stops and says
  so. It sits far above a heavy day of asking questions; it is there so that
  something going wrong in the background cannot spend a month's worth of
  requests in an afternoon. That second half is the one that matters most,
  because it does not depend on Moe correctly telling a background pass from
  a question — whichever it decides, the ceiling still holds.

- **unreleased (2026-09-06)** — **Moe tidies up after itself, and warns itself
  before it writes something risky.** Two things Hermes ships and leaves off.
  The first tracks the throwaway files a session creates — test scripts, temp
  outputs, old job logs — and removes them, staying strictly inside Moe's own
  working directory and never touching your notes, your settings, your
  connections or a job's own records. The second watches what Moe writes into
  a file: if the content matches one of 25 known-dangerous patterns, a warning
  rides back to Moe on the next turn so it can correct itself. It never blocks
  the write, and neither of these has a screen — you should only notice the
  disk not filling up.

- **unreleased (2026-09-06)** — **When Moe can tell you are still thinking, it
  waits longer.** Moe asks a small model whether you have finished, and when
  that model says you have not, it holds the microphone open — but only for
  three seconds, after which it took the turn anyway. Twice in one evening
  that cut a sentence off in the middle: once right after the owner had said
  out loud "let me think about this a second", with the model as certain as it
  gets that he was still going. Now, when the model *and* your own words both
  say there is more coming — the sentence trails off on "and", "because",
  "um" — Moe waits twice as long before giving up on you. It only applies when
  both agree, so an ordinary pause still ends the turn as quickly as before.

- **unreleased (2026-09-05)** — **Moe talks you through a long job, and waits
  the right amount before answering.** Two corrections to the same evening's
  work. When Moe goes off to do something that takes a minute, it now says a
  plain sentence before *each* step rather than one line at the start — the
  old instruction genuinely said "before your first tool call", so going quiet
  after one sentence was Moe doing as it was told. Nothing it says there is
  written by us: it is Moe's own words about the thing it is actually doing,
  in everyday language. And the earlier fix for being cut off mid-sentence
  went too far the other way — it removed the whole pause before deciding, and
  the model that judges whether you have finished was trained expecting about
  a fifth of a second of it. Measured across 80 clips, removing it made *both*
  mistakes worse: cutting you off went 18% → 25%, and waiting too long after
  you had finished went 31% → 54%. The pause is now levelled off at three
  tenths of a second instead of removed, which is better than either.

- **unreleased (2026-09-05)** — **A mail question stops taking minutes, and a
  skill stops failing at six in the morning.** Composio's tools are written
  one at a time and many of them default to the biggest possible answer:
  asked for five messages, Gmail's fetch returns about 167 KB, and an answer
  that big is not handed to Moe at all — it is written to a file, and one such
  turn was measured at **103 seconds** before Moe said a word. Moe now fills
  in the two cheap settings on that listing itself, for a 5 KB answer with the
  same five messages, and says in the result that it did; name any of those
  settings yourself and it passes exactly what you asked instead. Reading a
  specific message is untouched — a listing is for finding, a fetch is for
  reading. Separately: skills that need a command installed were never
  actually checked, so seven were switched on for commands this Mac does not
  have. Settings › Brain › Skills says so, and a **scheduled** job on one of them now
  refuses and names the missing command rather than spending a request and
  dying at the shell.

- **unreleased (2026-09-05)** — **Moe waits for you to finish, and stops
  waiting on the room.** Two complaints, opposite in feel, one piece of
  machinery. Moe decides you have finished by asking a small model that
  listens to how your sentence ended — but it could not ask until the
  microphone had heard a quarter-second of quiet, and it was handed that
  quarter-second along with your words. Measured against that model on 80
  clips: with the pause included it called **38%** of sentences that stop
  mid-thought "finished"; with the pause trimmed off first, **20%**. That is
  the pausing-to-think-and-being-cut-off problem, and the pause is now trimmed
  before the question is asked. The line it answers against moved down with
  it, which costs nothing — at the old setting Moe interrupted just as often
  and dawdled nine points more. The other direction: if music or a television
  is playing, the microphone never goes quiet, so nothing ended your turn and
  it could sit there for **ninety seconds**. Moe now watches whether *words*
  are still arriving rather than whether sound is, so when you have finished
  and the room has not, your turn goes anyway.

- **unreleased (2026-09-05)** — **Fewer dead ends when Moe drives an app.**
  Two small things Moe kept walking into. A few menu items share a name with
  another item in the same menu — Finder has two called "Enclosing Folder",
  with different shortcuts — and Moe cannot invoke either by name, because
  there is no way to say which. Those are now marked when Moe reads an app's
  menus, along with what to do instead. And when Moe looks at a window it
  cannot read the controls of, the advice it gets back no longer suggests the
  thing it has just done.
- **unreleased (2026-09-05)** — **"Stay in the background" now covers menus
  too.** Moe can invoke a menu item by name instead of hunting for it on
  screen, which is usually the fastest and most reliable way to drive an app.
  But macOS only gives the menu bar to whichever app is in front, so invoking
  one brings that app forward — there is no background way to do it. If you
  have told Moe to stay in the background, it now says so and reaches for the
  item's keyboard shortcut instead, which it can send without disturbing you.
  Reading an app's menus is unaffected and never needed the app in front.
- **unreleased (2026-09-05)** — **Moe stops restarting itself while you talk
  to it.** Everything going on in your day — your mail, your calendar, your
  messages — was being written into the instructions Moe starts up with, and
  those instructions can only be changed by starting Moe's thinking over. The
  briefing is rebuilt every ten minutes and carries the time it was made, so
  that was happening all day, whether anything had actually changed or not.
  Measured over 1,387 real questions on one Mac: 151 of them — one in nine —
  had Moe restart underneath them mid-conversation, and those took half again
  as long to start answering. What is going on in your day now travels with
  your question instead, and only when it has changed, so Moe stays warm and
  answers sooner. Nothing about what Moe knows changes — if anything it is
  fresher, because it is read when you ask rather than when Moe last started.

- **unreleased (2026-09-04)** — **Eight guides for Google and Composio**, and
  the mechanism that ships them. A mail question was taking three to four
  minutes, and the cause was not Moe: Composio's tools default to the largest
  answer they can give, and an answer that arrives too big is written to a
  file rather than handed to Moe. The guides — one router plus Gmail,
  Calendar, Drive, Docs, Sheets, Tasks and Meet — say which tool answers which
  question and which settings to pass, every figure measured against a real
  account rather than taken from the tool's own description. Google Photos and
  Google Slides deliberately have no guide: everything true of them is already
  in the router, and a guide that says nothing still costs a look to open.
  Guides you edit yourself are never overwritten.
- **unreleased (2026-09-04)** — touching the trackpad really does stop Moe
  now. It always claimed to, and for one older way of clicking it did — but
  everything Moe actually does on screen went through a different path that
  nothing was watching. Grabbing the mouse mid-task felt like it should stop
  things and quietly did not. It does now, and if you take over, the next
  thing Moe was about to do is refused rather than added to what you
  interrupted.

- **unreleased (2026-09-04)** — Moe stops staring and says what is wrong. It
  could get into a state of looking at your screen over and over without
  doing anything — seventeen times in a row, in one real case, over ten
  minutes — which looks exactly like being stuck because it is. After a few
  fruitless looks it changes approach, and if that does not help it tells you
  what it can see and what is stopping it instead of taking another picture.

- **unreleased (2026-09-04)** — the background helper no longer calls itself
  "thinking" when it is not. It is a long-lived process and the name was
  fixed when it started, so it said "thinking" while sitting idle — which
  made a finished session look like a running one to anyone checking.

- **unreleased (2026-09-04)** — **Settings › Brain › Skills**: the ninety-odd pages
  of know-how Moe reads from, in one list with switches. Grouped by what
  they are for, with each skill's own description, where it came from and
  whether Moe has ever opened it. The banner at the top is the point: some
  skills tell Moe to run a command, nothing has ever checked whether that
  command is on your Mac, and Moe has been finding out the expensive way —
  by trying, mid-answer. On a typical Mac about seven switched-on skills are
  in that state, and they are now named and listed first. A switch here
  travels to Moe Away too.

- **unreleased (2026-09-04)** — **Settings › History › Usage**: what Moe has used, and
  what it actually cost. The rate-limit warning already existed; this is the
  page underneath it. Three things it is careful about. What you and Moe said
  is kept apart from the context Moe re-reads on every turn, which is fifty
  to a hundred times larger and would read like a bill if the two were added.
  Cost is split into what a plan already covers, what is genuinely billed per
  token, and what has no billing route at all. And it says plainly that it
  cannot tell you what a *tool* cost, because tokens are counted per
  conversation and never per tool — rather than showing a column of counts
  under a heading about money.
- **unreleased (2026-09-04)** — you choose whether Moe may take your screen.
  It works in the background — clicking and typing into a window without
  moving your pointer or changing what you are looking at — but a few things
  need the window brought forward, and on a full-screen app that moves you to
  another desktop while you are mid-sentence. There is a switch for it in
  Settings → Voice now. Off, Moe stays out of the way and says what it could
  not reach instead of taking the screen to do it.

- **unreleased (2026-09-04)** — Moe says what it is doing on your Mac. Every
  screen action used to be announced as "Working on your Mac", so a long job
  sounded exactly like a stuck one. Now it says which app it is looking at,
  which menu item it is choosing, and when it is checking that something
  worked. It never reads out what it typed or which keys it pressed.

- **unreleased (2026-09-04)** — **Moe runs on macOS 15 now, not just 26.**
  It had asked for macOS 26 since the beginning, and a Mac on 15 was told it
  could not run Moe at all — an M1 Air was turned away by it. Almost nothing
  needed 26: two stored properties named a type from Apple's on-device model,
  which is an optional tier, and Swift will not let a stored property be
  marked as maybe-unavailable, so those two declarations set the floor for
  the whole app. Everything that actually uses that model was already asking
  at runtime whether it was there. Nothing changes on a Mac running 26.

- **unreleased (2026-09-04)** — **Moe takes about a gigabyte less room.**
  Two things, both invisible. The download carried a second speech-to-text
  engine — a Python one, with its own inference runtime and a copy of ffmpeg,
  around 200 MB — that Moe never used: transcription runs on the Neural
  Engine and always has. It also carried five copies of the same Python
  interpreter, and a GUI toolkit for windows nothing draws. And on first
  launch Moe wrote out a second complete copy of its thinking part, 817 MB,
  beside the one already in the app; it now shares the storage instead, which
  on an Apple-silicon Mac costs nothing and takes no time. Same app, same
  features, roughly 200 MB less to download and about a gigabyte less on
  disk once installed.

- **unreleased (2026-09-04)** — Moe can read an app's menus and use them.
  It can now list an app's menu items with their keyboard shortcuts, and
  invoke one by name through the same accessibility machinery a screen reader
  uses — no screenshot, no clicking, and a clear answer when the item is not
  there. This is how Moe reaches software whose main window it cannot read at
  all, like music production, CAD and 3D apps: the canvas is opaque, the menus
  are not. Greyed-out items are reported as greyed out.

- **unreleased (2026-09-04)** — Moe checks that something worked instead of
  looking at a picture of it. After acting it can ask directly whether what it
  expected is now true — this button exists, that field holds this text, the
  window is gone — waiting a moment and asking twice, so a window still
  redrawing is not mistaken for a finished one. When it cannot tell, it says
  so rather than assuming success.

- **unreleased (2026-09-04)** — **Settings › About** now shows a customer
  their version and nothing else. The two "which Moe is this" lines,
  **Catch up…**, **Publish a release…** and the Moe menu's
  **Check for Updates…** appear only on a Mac with the project checked out.
  Auto-update is untouched — the daily check still runs everywhere and still
  offers a new version. And **Publish a release…** works, for the first
  time: it was handing the button a script that then looked for a second
  script beside itself, in a directory the button had put one file into, and
  reported the miss as "could not prepare a checkout of main" — which blamed
  a checkout that was fine.

- **unreleased (2026-09-04)** — **Settings › History › Activity** and
  **Settings › History › Chats**, the two screens for what already happened. Activity
  is one timeline of the conversations you had, the replies Moe sent from
  your other chats, everything that ran on a clock and everything that
  stopped, with Moe's own upkeep folded away — except its failures, which
  never are — and the raw log underneath, described as the incomplete,
  unfiltered thing it is. A row about a reply from elsewhere says when,
  where and how much, and never what was said, because that is not written
  down anywhere. Chats is every conversation with a search that goes
  through the words: it uses the thinking part's index to find them and
  Moe's own record to show them, and the list of conversations the search
  may look inside is fixed before it runs, so a conversation you deleted
  cannot come back through it.


- **unreleased (2026-09-04)** — **Settings › Running in the background › Reminders**: everything Moe
  does on a clock, in one list, with a way to set one up without asking.
  Yours can be paused, run now, or removed; Moe's own five upkeep jobs are
  shown but not editable, because what you change about those is what Moe
  may read, and that has always lived in Running in the background. New
  reminders start from one of the sixteen templates, and every question on
  the form starts blank — the templates carry suggested answers, and a form
  that arrives pre-filled is one you tap through into a reminder you never
  asked for. The next-run line says *why* when there is no next run: paused,
  finished, or nothing currently running the clock. Nothing is ever called
  scheduled that cannot happen, and no cron expression is ever shown.

- **unreleased (2026-09-04)** — the away machine no longer carries out the
  same instruction twice. Removing a connection, and setting one up, are
  instructions your Mac writes and the machine performs; another device on
  your account could copy one and re-send it later — quietly removing a
  connection you had since set up again, or putting an old sign-in back over
  the current one. The machine now keeps a note of what it has performed and
  refuses a repeat. A real second removal, or setting the connection up
  again, is a new instruction and lands normally. The note covers what the
  machine did rather than everything ever said to it, so an instruction it
  was switched off for is still new to it, and the *current* instruction is
  always accepted by design — both are written out where this is described.

- **unreleased (2026-09-04)** — setting up a connection on the away machine
  now checks the whole of it for a key written out in full, not eight header
  names. The question Moe asks before copying a key onto the machine — "this
  can act as you on that service" — could only fire on the headers it knew
  about, so the same key written into the address, into a query string, into
  a header nobody had listed, or into what a program is started with, went
  across without a word; and a service you sign into with a browser was
  never checked at all. All of those are checked now, in one place, and Moe
  names the field and never the key. Nothing had leaked: every connection on
  this Mac names its key rather than containing it.

- **unreleased (2026-09-04)** — when Moe checks before doing something, the
  question now names the thing being touched. It used to say "Composio" — the
  service Moe reaches Google through, which is plumbing and not something you
  should have to know — where it meant Google Drive. It now says Google Drive,
  with Drive's own mark. And it no longer asks permission to *read*: opening
  or downloading a file changes nothing, and a question you learn to click
  through is a question that costs you the ones that matter. Anything that
  sends, uploads or changes still asks, including a download that would mail
  the result somewhere.

- **unreleased (2026-09-04)** — asked to open a meeting link, Moe now reads
  it instead of hunting for it. The join URL was always on the calendar
  event; nothing surfaced it, so Moe searched mail for the link and then
  fell back to screenshotting Calendar and clicking — eleven steps to reach
  something that was sitting in a field. The calendar tools carry the link
  now, and the rule Moe works to is "prefer the data to the screen".

- **unreleased (2026-09-04)** — an app on another desktop is no longer
  mistaken for an app that is not running. Moe could only see windows on the
  desktop you are currently looking at, and when it looked for one that was a
  Space away it was told the app might be misspelled — so it tried other
  spellings, then tried to drag your desktop across to find it. It now lists
  every window, says which desktop each is on, reads the ones it cannot
  reach, and leaves your Spaces alone.

- **unreleased (2026-09-04)** — Moe stops repeating itself. A repeated
  action that keeps returning the same result now earns a change of approach
  and then a refusal, rather than running until you interrupt. Scrolling,
  arrow keys and undo are exempt, because repeating those is the point.

- **unreleased (2026-09-04)** — improvements to Moe's own instructions now
  reach Macs that already have Moe. That file is written once, on first run,
  and is yours to edit — so every later fix to it had quietly reached nobody.
  Moe now keeps one marked section of it up to date and leaves everything
  you have written alone.

- **unreleased (2026-09-04)** — the amber card reads as one thing. What
  the pulse opened was a single cramped strip: the timestamp glued onto the
  front of the sentence, "Play" as a bare word between two round buttons,
  and the panel's own ✕ and ⌃ sitting on top of it — so the corner had two
  ✕ four points apart meaning different things. It is a card now: when it
  was for on its own line, the sentence with room to wrap, and **Dismiss**
  and **Play** where you look for them, clear of the panel's own controls.

- **unreleased (2026-09-04)** — having an account and sending your
  conversations are now two separate things. Connecting a service like Gmail
  will shortly need Moe to hold an anonymous account for you — no email, no
  password, nothing to fill in — so that your connections are yours alone and
  reachable by nobody else's. That account is not Away: on its own it sends
  no conversation anywhere, and Away stays exactly as opt-in as it was. The
  Away screen now describes what is actually being synced rather than merely
  what you have an account for.

- **unreleased (2026-09-04)** — answering something Moe started now works.
  A reminder or a follow-up that reached you on Telegram was a one-way
  message: replying "i did" got "Did what, exactly?", and "stop reminding
  me about that" got "which reminder do you mean?" — Moe had never been
  told what it had just said, and had nothing it could change even if it
  had understood. Every proactive message is now written down with the
  thing that produced it, on every surface it goes to, and handed back
  with your reply. "I did" closes it, "not now" or "remind me tomorrow"
  moves it, "stop reminding me about that" ends it for good — and for a
  reminder you set yourself, the same words pause, move or delete the
  schedule. It is attached only to the message you have not answered yet,
  for about half a day, and never in a group chat.
- **unreleased (2026-09-04)** — the island panel has a way out. When Moe
  answers something you typed the panel opens itself, and the only control on
  it was a dim ✕ that meant "stop everything" — the right button while Moe is
  working and the wrong one once it has answered. There is now a fold button,
  and Esc closes it too; the ✕ appears only while there is something to stop.
- **unreleased (2026-09-04)** — no technical alerts, ever. A background job
  that did not finish used to arrive on the notch with the amber glow, in
  Hermes's words rather than Moe's: "⚠️ Cron 'moe-proactive' failed: claude
  exited unexpectedly (code 143)". Six different kinds of these were shown
  to a person over three days, each naming a job nobody outside the repo has
  heard of and none of them naming anything to do about it. They are now
  dropped on shape — any job notice at all, whatever the reason — on both
  the writing and the reading side, and written to
  `~/.moe/logs/job-failures.log` instead. A job with trouble says **needs a
  look** in Settings › Background, in words. A sweep of every other way words
  reach you found nine more of the same thing, all now said plainly: the
  Background pane quoted a job's raw error; a thinking part that would not
  start answered with an exit code and the name of a command to run; the
  voice said "See ~/.moe/logs/moe.log" to someone who wanted to talk;
  Settings › Away showed six raw failures from the sync and the enrolment
  handshake, one of them a standing line under **This Mac**; a meeting that
  could not record the call, a screenshot that failed and a clip that came
  back empty each quoted the system's own error text; and switching model
  pasted a log tail into the pane when it timed out. Also "1 tools ready"
  under the greeting, which now says "Ready". A review then found four more
  kinds of notice Moe's thinking part can send about itself — a stalled
  session, a recovered reply, a database it could not read, a background job
  it finished — read out of its source rather than waited for; all four are
  dropped on the same rule, and the nightly learning job no longer puts a
  script's error output on the notch.
- **unreleased (2026-09-03)** — typed in, text out. A question typed into the
  notch or the chat window used to be answered out loud, because every part of
  Moe that speaks read one switch and none of them knew a keyboard from a
  microphone. **Settings › Replies** now holds the lot: speaking on or off for
  talking and typing separately, whether a typed answer is written to be read
  rather than heard, when the panel opens itself and for how long, the instant
  "yeah, on it", spoken progress, a small sound for an answer nothing will
  say, and whether a question typed in the notch takes you to the Chat page.
  Typed answers may now use lists, formatting and clickable links and run to
  the length the question needs; spoken ones are unchanged. Bare addresses
  anywhere in an answer are clickable too, and are still never read aloud.
  "Speak replies out loud" left the Voice pane, where it sat under a heading
  reading "While you talk".
- **unreleased (2026-09-03)** — asking for a meeting in your own words works.
  "Begin taking notes", "take minutes", "record this call" — and the stops to
  match — used to be answered with an instruction to say "start a meeting"
  instead. Moe now recognises the ordinary wordings itself, and anything it
  does not recognise reaches the assistant, which asks Moe to start rather
  than telling you to rephrase. The consent sheet and the red ring are
  unchanged: it is still Moe that records, never the model.
- **unreleased (2026-09-03)** — web research comes back with links. The pages
  Moe opened are listed under the answer as **Sources** you can click, read
  off the steps it actually ran; links Moe writes into an answer are live in
  the chat window and in the panel. Nothing is read aloud — the spoken reply
  skips addresses and the sources list — so the links cost the listener
  nothing. Before this the "no URLs" rule for speech had removed links from
  everywhere, and asking for them got you the name of a site to type in.
- **unreleased (2026-09-03)** — Settings → About shows all three answers to
  "which Moe is this?" — this Mac, and what is published for everyone — and
  [memoe.app/status](https://memoe.app/status) shows them plus `main` from
  any browser. A release now records which commit is in it, so "is what
  everyone is running the same as what we have?" has a real answer instead of
  an inference from timestamps. **Publish a release…** cuts one from `main`.
- **unreleased (2026-09-03)** — the licences list no longer names PocketTTS
  or Supertonic-3. Neither has shipped for some time; listing them claimed
  code Moe does not carry, and passed on use restrictions that bind nobody.
- **unreleased (2026-09-03)** — Settings → About now says, in words, whether
  this build is what has landed on `main`, and a **Catch up…** button beside
  it brings the Mac to `main` in one step. It builds in its own checkout
  (`~/moe-catchup`), never the shared one, because a shared checkout is
  usually on someone's branch — which is how the same version number kept
  reappearing as an older app.

- **unreleased (2026-09-03)** — "Hey Moe" stopped working after the first
  conversation. Before letting the name wake it, Moe checks that the voice
  saying it is yours — but in standby it was reading a buffer nothing had
  written to since the last conversation ended, so it judged the same stale
  few seconds every time and gave the same answer every time. Once that
  answer was "not you", the name never worked again until Moe was restarted.
  The check now reads what the microphone is actually hearing. And if it ever
  refuses three wakes in a row, Moe decides its idea of your voice is the
  likelier thing to be wrong, says so, and stops using it — a check that
  cannot be wrong is worse than no check at all.

- **unreleased (2026-09-03)** — Background voices stop interrupting Moe.
  With "Interrupt Moe by talking" on, any sound the microphone took for
  speech stopped the answer instantly — so a room with other people in it cut
  Moe off again and again. It now goes quiet instead of stopping, spends a
  third of a second working out whether that voice is yours, and either stops
  or comes back up. Someone talking near you no longer interrupts anything,
  and when it is you the stop is a third of a second later than before, which
  is not something you can hear. Saying "Hey Moe" or pressing the shortcut
  still cuts it off immediately, with no wait at all.

- **unreleased (2026-09-03)** — Moe's voices sound like themselves again.
  Ava was described as "scratchy and slow", and both halves turned out to be
  things Moe was doing to her: a filter meant to remove clicks was cutting
  into the voice itself — measured at nearly 9% of its high-frequency
  content, 225 times in five seconds — and the pace had been set against a
  single test sentence and was too slow for most real ones. Both voices now
  run on their makers' own settings. A third voice, Supertonic, has been
  removed: nobody chose it, and its licence placed conditions on everyone
  who installed Moe. The download is 161 MB smaller.

- **unreleased (2026-09-03)** — Groundwork for connections that work while
  your Mac is asleep. When you connect a service that signs in through your
  browser, Moe can now give the away machine **its own** sign-in for that
  service rather than a copy of yours — so refreshing one never logs the
  other out, and you can cut the machine off without touching your Mac. The
  machine's half is built and tested, and so is the Mac's — one command per
  connection, which opens your browser the way connecting always does. It
  has now been done once for real, against Cloudflare: what the machine is
  given is a sign-in of its own, registered under the name *Moe Away*, and
  it is sealed under a key that cannot open your memory. Delivering it to
  the machine is the part still being finished. Two things said plainly. For services that offer no way to revoke a sign-in
  remotely (of the three tested, only Cloudflare does), cutting the machine
  off stops it getting a new sign-in but cannot cancel the one it holds
  until that expires. And the *registration* that lets Moe Away ask at all
  cannot be removed by Moe on any of the three — that one is a click in your
  own account at the service.

- **unreleased (2026-09-03)** — Moe answers within about three seconds of
  launching, instead of a minute. Starting up loaded everything before
  anything worked: the name, the key and the shortcut all waited on a 461 MB
  transcriber that is not needed until you stop talking, and on a voice that
  is not needed until there is something to say. Measured at 66 seconds, of
  which the part that hears you was ready at 6. Now Moe starts listening as
  soon as it can hear — 2.7 seconds — and the rest arrives while you are
  still talking. If you finish before the accurate transcriber is up, Moe
  uses what it heard live rather than making you wait for it, and an answer
  that arrives before the voice is ready waits instead of vanishing.

- **unreleased (2026-09-03)** — Talking to Moe was rebuilt from the turn
  outwards. Deciding when you have finished a sentence, whether what Moe
  heard was even meant for it, and when a conversation is over used to be
  scattered across the code that ran the microphone; it is now one small
  machine that those parts report to. What you notice: you can interrupt
  while Moe is still thinking, not only while it is speaking; saying you are
  done ends the conversation, in any language, because Moe judges what you
  meant rather than matching a list of English phrases; a quiet conversation
  offers to close itself instead of sitting there lit; and Moe no longer
  mistakes its own voice for yours. The follow-up window is now yours to set
  (8 to 30 seconds), and you can enrol your voice so "was that you?" is
  measured rather than guessed.

- **unreleased (2026-09-03)** — `Moe --wake-record`, ten minutes that make
  "Hey Moe" yours. The wake word ships trained on synthesised speech alone,
  which is why it can miss your name and answer to "hey Joe" — the missing
  ingredient is a recording of your voice in your room, and nobody had a
  practical way to make one. Now it reads you a script and records as you go.

- **unreleased (2026-09-03)** — Moe Away knows what your Mac can actually
  do. Your Mac now publishes a short, encrypted list of what is set up on it
  — which connections work, which need a sign-in, which are switched off —
  and the away machine reads it. Before this it was guessing, and it guessed
  wrong in both directions: it would say a service you had connected was not
  connected, and it would promise to queue something on a source you had
  never turned on. Now it says "I'll do that when your Mac wakes" only when
  that is true, and tells you what needs setting up when it doesn't. The
  list holds no addresses, keys or tokens, and only your Mac writes it.

- **unreleased (2026-09-03)** — **Heads-up before an event**, under Speaking
  up. "Tell me a couple of minutes before my schedule starts" is a promise
  about a clock, and the half-hourly pass could never keep it — it wakes on
  your brief *changing*, not on the time, so a meeting that had been in your
  calendar for days would never trigger it. Now it has its own job: set a
  number of minutes and Moe checks every two minutes what is about to start
  and says one sentence a few minutes before, once per event. No thinking is
  spent on it and no service is contacted — it reads the copy of your
  calendar Moe already keeps. It starts off, and stays off until you set a
  number.
- **unreleased (2026-09-03)** — **Tell me when something happens here**, one
  switch per connected thing under Speaking up. Moe once told someone about
  a WhatsApp message while their WhatsApp row was switched off — that row
  is "what it may read", it governs the daily learning pass, and speaking
  up had no per-source answer at all. Now it does, it is separate from
  keeping a source ready and from learning from it, and switching it off
  keeps that source out of the half-hourly pass entirely and stops any
  watch on it.
- **unreleased (2026-09-03)** — Moe writes for the channel it is on. The
  same Moe, with the same name, memory and manner, but on Telegram or
  WhatsApp it now writes to be *read* — short paragraphs, and a link when a
  link is the answer — instead of following the rules written for a voice
  that is spoken aloud through the widget. Those spoken rules stay on the
  widget, where they belong. This was most visible on Moe Away: the machine
  in the cloud had been given the Mac's persona verbatim, which told it it
  was running on a Mac and being listened to, neither of which was true. If
  you have written your own persona, it is left exactly as it is.
- **unreleased (2026-09-09)** — Moe Away can send messages again, and asks
  you on your phone first. Sending was withheld from the cloud machine
  entirely, because every send on a Mac is approved in a box on your screen
  and the machine has no screen — so rather than offer to send and then
  refuse, it did not offer. It now asks the same question on the channel you
  are talking to it on, showing the recipient and the message, and sends only
  if you press the button. You have about an hour to answer; nothing is sent
  if you do not. "Always allow" on that prompt remembers only the one message
  you approved, so the next send still asks.
- **unreleased (2026-09-03)** — Moe Away no longer offers to set up a
  connection it cannot set up. The away machine had been given tools that
  only work on a computer with a screen — including the one that connects a
  new service, which needs a browser it does not have — so asked about a
  service it could not reach, it offered to connect one and then could not.
  Those tools are no longer in front of it, and it says what is true
  instead.
- **unreleased (2026-09-03)** — Fixed: on a Mac part-way through an update,
  the background job that runs work queued by Moe Away could report a
  failure every five minutes, and those reports went out as messages —
  including to your phone if you have a reminder channel on. It now waits
  quietly for the update to finish. Nothing was ever lost: work queued while
  it waits is still there afterwards.

- **unreleased (2026-09-03)** — Open loops: when someone is waiting on you,
  Moe says so again if it is still waiting — about three hours later, then
  the next morning, then daily — checking your own replies first, saying
  one thing at a time, and letting go after four mentions or a week.
  Newsletters, receipts and things you are only cc'd on are never loops,
  only Moe's own background pass can open one, and the four-mentions-or-a-
  week limit is kept by Moe itself rather than left to judgement. Before
  this, anything Moe noticed was mentioned once and then never again,
  however long it went unanswered.
- **unreleased (2026-09-03)** — **Moe updates itself.** It checks once a
  day and offers a new version in a window you can accept or ignore, or you
  can ask any time with Check for Updates in the Moe menu; it installs and
  reopens on its own, usually a few kilobytes rather than the whole 1.3 GB,
  and your memories, notes, connections and settings are untouched. Every
  version up to 0.3.8 checked for updates and was always told there were
  none — the feed was withheld from any build Apple had not notarized, on
  the belief that self-updating needed a Developer ID. It never did. So one
  last update, from 0.3.8 or earlier, has to be downloaded by hand.

- **unreleased (2026-09-04)** — Memory now converges when a Mac that had
  been used on its own joins an account that already exists. It keeps
  reading everything it learned before, and what it remembers is written
  back under the shared lock so the other devices see it too — including
  the persona, the "who you are" note and the learned profile, which
  previously stopped at that Mac. A document that arrives before the lock
  that opens it now says so plainly instead of leaving a file silently
  frozen.
- **unreleased (2026-09-03)** — Moe Away can now hand work back: ask it for
  something that only your Mac can do — a note, a reminder, your calendar —
  and instead of failing it queues the job, says so without over-promising,
  and your Mac does it the next time it is awake and tells you in one
  message. Work waits at most three days, is reported rather than done late
  if it waits longer, and is never silently repeated if your Mac was
  interrupted part-way. Nothing that sends a message to anyone can be
  queued this way.
- **unreleased (2026-09-02, later)** — Moe Away remembers: memory, persona,
  the learned profile and your disabled skills travel between the Mac and
  the machine, sealed under one memory key only your devices hold; the
  machine rebuilds `MEMORY.md`/`USER.md` from the shared record after
  every sync and a fact saved on either side is known on the other after
  one. Hermes's memory on the Mac now writes to the same ledger chain as
  the app (one device per Mac; the old separate chain is folded in once,
  automatically). The machine gets its own `~/.moe` with the four
  connectors that can run there, the profile tool, and the turn log; a
  connector that is not connected there says so. Enrolling a device no
  longer waits for the first sync to finish.
- **unreleased (2026-09-02)** — Background, learning from a connection: turn
  a connection's learning switch on and Moe works out for itself what is safe
  to read there — the accounts, projects, metrics and structure that describe
  your work, never rows, messages, documents or anyone's personal data, and
  never anything that writes — and folds it into what it knows about you, on
  the same daily pass that reads your own mail and calendar. Nothing is set up
  per service; the calls it settled on are written to
  `~/.moe/gather/<connection>.reads.json` to read or trim, and the step that
  decides what to remember holds no tools.
- **unreleased (2026-09-02)** — Background: a reminder takes the amber
  glow (hover, Play, ×) instead of being read out the moment it lands; one
  waits at a time and it waits while Moe is talking. "What it may read" is
  one list of every connected thing, one switch each — a new connection
  appears, a disconnected one leaves, nothing is named in code. The list
  is on screen at once from the last known answers; switches move at once
  and a list still loading no longer undoes a fresh flip. Status checks of
  a signed-in connection read the thinking part's own files and its log
  instead of opening a sign-in session of their own. A job cut short by
  the thinking part restarting is no longer reported as a failure.
  Keeping up: every connected thing has a profile — keep today ready,
  read back once, catch up daily/weekly/monthly/never, watch — researched
  for the services Moe knows, inferred from the tools of one it does not,
  yours to override. The 10-minute pull and the daily pass read those
  profiles instead of treating every source the same: a source switched
  off loses its cached copy, the daily pass reads only what is new since
  it last looked where the source can be asked that (Mac things can; a
  connection's worked-out calls are re-read whole and compared, unless
  your own recipe says where the window goes), a docs search is never
  read, and any connection can be kept ready like a Mac thing — off
  unless you switch it on, and at most once an hour, not every ten
  minutes. A read that takes too long is cut off with everything it
  started, the last copy is kept, and it is not marked done.
- **0.3.x (2026-09-02)** — Moe Away: your Moe can live on a machine of its
  own in the cloud, asleep when quiet and awake within a second of a message.
  It is enrolled from the Mac through its Telegram bot (`enrol` with the
  ticket, compare the codes, `confirm` with the Mac's), and from then on a
  turn on Telegram and a turn at the notch are one conversation on both
  sides. Memory does not travel yet.
- **0.3.x (2026-09-02)** — Away, hardened after review: every entry is
  signed by the device that wrote it, so nothing can be slipped into a
  conversation or a key thrown away by anyone but its author; the machine's
  code reaches you directly, never through the model; only the founder — the
  first device — can revoke, and it can't be revoked; a revoked device stays
  revoked; deleting a conversation destroys its key everywhere; the machine
  has no shell and answers only you, in private.
- **0.3.7 (2026-09-02)** — Watches: one per connection, described by
  `~/.moe/watch/<connection>.json` (nothing ships pre-written); a fixed set
  of metadata reads on a schedule, judged only when the answer changes,
  worded as the kind of change and never a name, an identifier or a
  personal field — those are dropped at read time. Every connection Moe
  has is listed in Settings › Background with a switch.
- **0.3.6 (2026-09-02)** — Reminders reach you: a reminder set from a Moe
  conversation is delivered to this Mac (before, it ran and reached
  nobody), and can be sent to any chat app Moe is connected to, chosen in
  Settings › Background › Reminders. Speaking up: every half hour Moe looks
  at its brief of your day and, only when it changed, says a sentence if
  something matters, keeping what it learns in memory; this replaces an
  hourly digest that had never once run. One switch per source for the
  daily learning pass, and one for whether what it learns becomes Moe's
  memory. Moe no longer announces its own thinking part restarting.
- **0.3.x (2026-09-02)** — Away: this Mac becomes a device of your own cloud
  tenant. Settings › Away holds the edge address, the bootstrap that makes
  the first tenant, "Enrol another device" (ticket, then a code you compare
  on both screens), and the device list with revoke. Once enrolled, Moe
  pushes after every reply and pulls on launch, on wake, in the foreground
  and every five minutes; another device's turns appear in the window.
- **0.3.8 (2026-09-02)** — Your Mac connections showed as disconnected.
  Calendar, Contacts, Messages, Notes and Reminders all read "not connected"
  in the Connections pane after 0.3.5 moved where Moe keeps its data. They
  were working the whole time; only the pane was looking in the old place.
  A connection check that runs out of time now says so and is retried, and
  the Connections and Background panes hold their place while lists load.
- **0.3.5 (2026-09-02)** — Telegram works. It had never worked in any
  released version: the credentials that identify Moe to Telegram could only
  reach a build through an environment variable nobody had set, so every
  download from 0.1.0 onwards had that connector permanently dead.
- **0.3.5 (2026-09-02)** — Google Docs and Sheets work again. They were dead
  in 0.3.4 only, where the sign-in client was missing from the build.
- **0.3.5 (2026-09-02)** — Moe's data moved to
  `~/Library/Application Support/Moe`, from a hidden `.moe` folder at the top
  of your home directory. The move happens by itself on first launch, the old
  location keeps working, and nothing is copied or lost.
- **0.3.5 (2026-09-02)** — One background item instead of three. System
  Settings → Login Items listed Moe three times, because one job was three
  scheduled tasks. The switch for it in Moe's own Settings now tells the
  truth about whether it is running — before, it could show "off" while the
  job ran, with no way to stop it. Removing Moe now removes the background
  item too, instead of leaving one running every ten minutes forever.
  "Refresh now" no longer consumes the hour's memory digest.
- **0.3.5 (2026-09-02)** — The download carries the thinking part of Moe
  inside it. Setting Moe up used to fetch it from the internet at the moment
  you reached the brain step, which failed with no network and asked you to
  accept two downloads from places you had no reason to trust. Nothing is
  fetched now.
- **0.3.x (2026-09-02)** — Connections: Disconnect is offered for every
  connection Moe has on file, not only working ones, so a connection that
  needs a fresh sign-in can be removed and connected again from the app.
- **0.3.x (2026-09-02)** — Meetings: recording on the MacBook microphone
  no longer silences you on the call. Echo cancellation is left off while a
  call app has the microphone (and switched off if a call arrives
  mid-recording), because on macOS it changes the built-in microphone for
  every app and raw-input call apps then send silence.
- **0.3.x (2026-09-01)** — Getting started: the first-launch flow redrawn in
  the app's own design, one paragraph a screen; the bundled brain is laid
  down at launch so a downloaded copy never sees a download step; a
  rehearsal mode and per-screen snapshots for developers.
- **0.3.x (2026-09-01)** — Meeting capture: screenshots and screen recording
  during a meeting (on request, by asking the AI, or automatically on
  transcript cues), with vision captions the notes reason from. Automatic
  call detection by microphone and camera, with an offer popup (ask, or
  start-after-countdown), per-app "never", and a stop-when-the-call-ends
  offer. Settings moved to their own Meeting Capture tab. Full history in
  `MEETING-MODE.md` (Phases A–D.1).
- **0.3.x (2026-09-03)** — Google, and about five hundred other services,
  through Composio: connect Google Calendar, Gmail, Drive, Docs, Sheets,
  Tasks or Meet by signing in once, with no developer account, no project
  and no key to paste. The permission screen shows Composio's name rather
  than Moe's, which is the cost of the route; the local mail, calendar and
  Drive paths are unchanged and still never leave the Mac. Moe carries five
  tools rather than five hundred and finds the right one when asked.
- **0.3.x (2026-09-03)** — Voice: spoken email and web addresses are written
  the way they are typed ("jane three at jklumen dot ai" → `jane3@jklumen.ai`),
  in dictation and in what you say to Moe, which never had any cleanup before.
  Whoever opens a conversation owns it: Moe takes a reading of that voice from
  the words that opened the session and does not answer a different one in the
  same window unless it is named. Per-turn timings are measured from the moment
  the microphone opens rather than from the moment the turn was already decided,
  so "end of your sentence to Moe's first word" is now the number it says it is.
- **0.3.x (2026-09-04)** — Voice: Moe answers in the language you set it to
  and stops following a mishearing into another one, and a turn that does not
  look like your language counts against Moe answering it in the follow-up
  window (saying "Moe" always gets through).
- **0.3.x (2026-09-04)** — Voice: Moe no longer reads machine-generated
  filenames aloud mid-job ("Reading mcp hermes tools tool call
  1788546547356"), a turn the recogniser found nothing in is no longer
  overridden by the rougher live transcript, and an abandoned turn no longer
  leaves its words in the recogniser for the next one to be glued onto.
- **0.3.x (2026-09-04)** — Voice: interrupting Moe now amends what you asked
  for instead of replacing it, and the conversation handed back to a restarted
  brain carries eight real exchanges rather than eight slots mostly spent on
  the wreckage of earlier interruptions. Moe says "still on it" during a long
  step it has no words for, instead of going silent, and talks about its work
  the way a person would rather than the way a report does.
- **0.3.x (2026-09-04)** — Voice: a tap on the hold key no longer throws away
  the reply it stopped — the sound still stops at once, and Moe carries on if
  the press turns out to have been too short to say anything.
