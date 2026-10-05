# MyComputerAgent (mca)

<p align="center">
  <a href="README.md"><b>English</b></a> •
  <a href="README.ja.md"><b>日本語</b></a> •
  <a href="README.ko.md"><b>한국어</b></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26.0%2B-black?logo=apple" alt="macOS" />
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
  <a href="SECURITY.md"><img src="https://img.shields.io/badge/Security-Zero--Trust%20Privacy-success" alt="Zero-Trust Privacy" /></a>
  <a href="https://github.com/buddypia/my-computer-agent/actions/workflows/ci.yml"><img src="https://github.com/buddypia/my-computer-agent/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
</p>

> **Official Trilingual Support**: English, 日本語 (Japanese), and 한국어 (Korean) are officially supported across the entire app — user interface, speech transcription engines, and AI response generation.

A local-first multimodal desktop copilot for macOS. It watches what is on your
screen, keeps a searchable history on your own machine, and speaks up only when
it has something worth saying. It can listen to both sides of your conversations
too, but only once you ask it to — the microphone is off at launch.

Native Swift, because the capabilities this needs — reading another app's
accessibility tree, tapping system audio output, hardware echo cancellation, a
click-through window that floats over full-screen apps — have no equivalent in
a browser or an Electron shell.

---

## What it does

| | |
|---|---|
| **Sees** | Reads the focused window's accessibility tree on OS events (focus change, window title change, typing pause). Falls back to on-device Vision OCR for canvas-drawn apps. Never polls at a frame rate. |
| **Acts** | Autonomous native GUI control (clicks, typing, key combinations, AppleScript execution) using CoreGraphics event synthesis coupled with accessibility inspection (`AXUIElement`). Ultra-low latency UI grounding powered by TypeSafe AI (Jev System One model, <200ms) with seamless offline/unkeyed semantic local fallback. Safe execution available from the built-in Copilot, CLI (`mca act`), and external MCP clients. |
| **Hears** | Captures your microphone with hardware AEC and the system audio output through a CoreAudio process tap — no virtual audio driver. Two separate channels, so "you" and "everyone else" stay distinct. **Nothing is captured at launch:** the microphone opens for a voice conversation (⌥⌘V) and closes when it ends. Continuous capture is a switch in ✨ ▸ Settings ▸ General ▸ Audio. |
| **Transcribes** | Dual-engine transcription: Apple's on-device `SpeechAnalyzer` for 100% private local recognition, or **Gemini Flash batch audio transcription** for state-of-the-art multilingual accuracy, homophone disambiguation, and verbal filler cleanup. Audio never leaves the machine when on the Apple engine. |
| **Talks** | Two buttons, not a mode picker. The microphone is **Dictation**: transcribed on this Mac, then handed to the same chat model a typed question goes to. The waveform beside it is **Live conversation**: Gemini hears you and answers out loud over one socket, and searches the web when it needs something current. Either way, what the microphone heard is drawn across the bottom of the screen you are working on, in type sized for that display. |
| **Remembers** | SQLite with FTS5, plus on-device query expansion so you can search by meaning rather than exact wording. |
| **Advises** | An on-device model screens every scan and stays silent by default; only what clears that gate reaches a cloud model. Switch **Watch my screen** on in the chat and it also looks at the screen itself on a timer — a picture, not just text — and speaks only when it sees a mistake, an error or a faster way. Off by default, and off again on every launch. |
| **Shows** | A chat window one click from the ✨ item or ⌥⌘Space, where answers and the agent's own observations land in one thread. Also a menu bar popover, and — when you ask for it — a floating `NSPanel` that is visible over full-screen apps, never steals focus from your editor, and can optionally let clicks pass straight through. |
| **Shares** | Exposes your context and GUI automation tool suite (`computer`, `click_element`, `run_applescript`, `inspect_ui_elements`, `typesafe_act`) to other agents (Claude Code, Codex, …) as an MCP server. Tools that act on your Mac or browser are refused over MCP unless you set `"mcpAllowDangerousTools": true` in `config.json`. |

---

## Requirements

- macOS 26 or later, Apple Silicon
- Xcode 26.6+ / Swift 6.2+
- Optional: a Gemini, Anthropic, OpenAI-compatible, or TypeSafe AI API key. Without one, recording, search, and local semantic GUI grounding operate normally.

## Build

```bash
./Scripts/bundle.sh
open build/MyComputerAgent.app
```

The bundle is not optional. macOS attributes permissions to a signed bundle
identifier, reads the permission prompt text from `Info.plist`, and
`AudioHardwareCreateProcessTap` fails on an unsigned binary **without ever
prompting** — which looks exactly like a bug in the app.

For distribution, pass a Developer ID identity: `./Scripts/bundle.sh "Developer ID Application: …"`.

### Getting a change into the running app

```bash
./Scripts/run.sh          # rebuild the bundle, stop the old process, relaunch
```

Use this rather than `swift build` plus `open`, which silently does nothing for
two separate reasons:

- `swift build` writes `.build/<config>/mca`. Only `Scripts/bundle.sh` copies
  that into `build/MyComputerAgent.app`, and the quality gate does not run it —
  so the build and the tests stay green while the app keeps running code from
  whenever it was last bundled.
- The app is `LSUIElement` and stays resident. `open` on a resident app is a
  *reopen*, not a relaunch: it delivers `applicationShouldHandleReopen`, which
  shows the settings window, and leaves the old process in place. The old
  process has to be stopped first.

## First run

Open the app, then set it up from the ✨ menu bar item — **Settings…**. Both
steps below have to happen inside the running app, and neither works properly
from a terminal:

1. **Permissions** — Accessibility, Screen Recording, Microphone, Audio Capture.
   macOS attributes a grant to the process that is "responsible" for raising the
   prompt, and for a terminal-launched binary that is the *terminal*. A prompt
   answered from `mca doctor` grants the permission to Terminal.app and leaves
   the agent with nothing. macOS also only prompts once per app identity; after
   that it is System Settings ▸ Privacy & Security, and the Permissions tab
   deep-links to the right pane and updates live as you flick each switch.
2. **Models & Keys** — paste a Gemini key. It is encrypted before it is stored
   (see below), written by the app itself so the app owns the keychain item and
   reads it back without an "allow access?" dialog. Adding a key takes effect
   immediately; there is no need to relaunch.

`mca auth set gemini` still works, but the item then belongs to the CLI binary
and macOS interposes a permission dialog the first time the app reads it — easy
to miss from a background agent, and indistinguishable from having no key.

### How API keys are stored

Not as plaintext in the keychain. Each key is sealed with **HPKE** (RFC 9180,
`P256_SHA256_AES_GCM_256`) to a **P-256 key generated inside this Mac's Secure
Enclave**, and only the ciphertext goes into the login keychain.

The keychain alone would already encrypt the item, but it is encrypted to your
login password: a copied `login.keychain-db` plus that password yields the key.
The Secure Enclave's private half never leaves the chip, is not derived from any
password and cannot be exported, so the stored bytes are inert on any other Mac
regardless of what an attacker knows. The provider name is authenticated
additional data, so a record cannot be moved from one provider's slot to
another's.

Two consequences worth knowing:

- **A key written by an older build is migrated automatically** the first time
  it is read — returned as before, then re-sealed in place. Nothing to do.
- **Erasing the Mac, or resetting the Secure Enclave, makes stored keys
  unreadable.** They are device-bound by design. Re-paste them in Settings; the
  app says so rather than reporting "no key".

Apple's newer data protection keychain (`kSecUseDataProtectionKeychain`) is *not*
used, and not by oversight: it is entitlement-gated behind
`com.apple.application-identifier` / `keychain-access-groups`, which only a
provisioning profile grants. This app is deliberately unsandboxed and
profile-less, so `SecItemAdd` returns `-34018 errSecMissingEntitlement`.
CryptoKit's Secure Enclave keys have no such gate, because they are never stored
*in* a keychain — the app persists the opaque wrapped blob itself.

On a Mac with no Secure Enclave the store falls back to a software wrapping key
and says so in Settings, in orange, rather than quietly claiming hardware
protection it does not have.

Re-signing changes the binary's identity, so a rebuilt app is treated as a new
one and asks for permissions again. Signing with a real certificate rather than
ad-hoc avoids this; `Scripts/bundle.sh` picks one up automatically.

```bash
build/MyComputerAgent.app/Contents/MacOS/mca doctor   # same report, read-only
```

## Commands

```
mca run       Start the copilot and floating overlay (default)
mca doctor    Check permissions, models, storage and routing
mca listen    Capture and transcribe for N seconds, printing both channels
mca capture   Read the focused window once and print what was extracted
mca ask       Ask a one-shot question with current desktop context
mca act       Perform screen actions using TypeSafe Jev / local grounding
mca search    Search recorded history
mca mcp       Serve recorded context and GUI tools over MCP on stdio
mca auth      Store a provider API key (gemini, anthropic, openai-compatible, typesafe) in the keychain
mca setup     Open the permission walkthrough (prefer ✨ ▸ Permissions)
mca reset-permissions
              Clear this app's TCC grants so macOS prompts again
```

## The chat window

`⌥⌘Space`, the **Chat** button on either surface, or ✨ ▸ **Open the Chat…**. It
opens centred, in front, with the caret already in the field.

It is deliberately not an application-modal window. `NSApp.runModal` would give
the dimmed must-answer-this feel, and it would also stop the run loop the agent
lives in — the proactive scan, the screen watch, the menu bar and every global
hot key are all on the main actor — while locking you out of the very windows
you are asking about. Escape closes it; everything else stays usable.

- **Watch my screen** — off by default. On, the agent looks at the focused window
  on a timer (15s / 45s / 2min) and says something only when it spots a mistake,
  an error, a risk, or a faster way. The line under the thread says what it last
  did, so a watch that is quiet is distinguishable from one that is broken.
- **What to watch** (📌) — opens the screen picker described below: follow the
  focused window, pin one specific window, or pin a whole display. A pinned
  subject is watched wherever it is in the stacking order, so it keeps reading
  the build you walked away from while you work in something else — and it does
  not stand down when you come here to ask a question, which the focus-following
  watch has to. `⌥⌘W` pins the window you are in without opening the picker, and
  pressing it again lets go.

  A window and a display hold still in different senses. A pinned *window*
  follows its own content wherever you drag it; a pinned *display* holds a
  region of the desk and lets whatever is on it come and go — which is the one
  to use when the interesting half of the work is on the monitor you are not
  typing into.
- **Explain** — a one-off version of the same thing: photographs whatever the
  picker is pointed at and explains it. With nothing pinned that is the display
  the pointer is on; pin a window and it is that window, because someone who has
  just chosen one and then asks about "my screen" means the thing they chose.
  The picture is what makes this work on canvas-drawn apps — diagrams, PDFs,
  video calls — where there is no accessibility tree to read.

Nothing is sent for a screen that has not changed since the last look, for an
app on the exclusion list, for one of this app's own windows, or while an answer
you asked for is still streaming. Three failed looks in a row stop the watch and
say why, rather than retrying a missing API key every 45 seconds.

A pinned subject is compared by picture rather than by text — there is no
accessibility tree to read for a window that is not focused — so an unchanged
one costs a screenshot and a hash, with no OCR and no request. The comparison is
deliberately coarse (a 32×32 greyscale reduction, quantised to eight levels), so
a blinking cursor is not a change and a finished build is. Pinning refuses this
app's own windows and anything on the exclusion list, and a pinned subject that
goes away — a window closed, a monitor unplugged — stops the watch rather than
quietly moving it somewhere else.

While something is pinned, moving around the desk records nothing: the
focus-driven captures stop, so the newest thing in the store is the subject and
not the window you passed through on the way to asking about it. The watch writes
what it reads, so the subject stays the freshest thing on file even when it has
been behind other windows for ten minutes. The pin is also stated in the
question rather than left to be inferred — "this screen" is answered with the
name of what you pinned — because a model handed a pile of observations will
otherwise reasonably assume the latest one is what you meant.

A display is a region of the desk rather than an application, so the exclusion
list cannot be applied to it by skipping the capture. It is applied *inside* the
capture instead: excluded windows are handed to `SCContentFilter` and are never
composited into the frame, so a password manager sitting on a pinned monitor is
absent from the picture rather than photographed and hoped about. Those windows
are also left out of the picker, since offering something that would be refused
is not a choice.

## The screen picker

A grid of live thumbnails — one per window, one per display — in the shape every
screen-sharing dialog uses, because the question is the same one: *which of these
am I handing over?* Open it from the **Screen** button on the panel or the
popover, the 📌 button in the chat toolbar, or ✨ ▸ **Choose a Screen to
Watch…**. Click a tile to select, double-click or press **Watch this** to apply,
and the choice starts the watch if it was off — "keep an eye on this" is one
intention, not two.

The list this replaces named windows and nothing else, which is the one thing a
window is worst identified by: four Chrome windows are four rows reading "Google
Chrome", and the title of the one that matters is a truncated URL.

The thumbnails are re-photographed every three seconds while the window is open,
and not at all once it closes — a still from thirty seconds ago is not a preview,
and the interesting case ("which of these two terminals is the build running
in?") is exactly the one a stale frame gets wrong. They are taken at a fraction
of the size a watch capture uses, since a thumbnail only has to be recognisable.

A preview goes through the same privacy gate as a real capture: an excluded app
has no tile, and an excluded window is left out of a display's tile the same way
it is left out of what gets sent. The preview is an answer to "what would the
agent see here", so it must not show anything the agent would not get.

The picker window is itself `sharingType = .none`, like every window this app
owns — it is full of pictures of your other windows, and letting it into a frame
would hand the agent a hall of mirrors instead of a screen.

## The menu bar item

There is no Dock icon, so the ✨ status item is the app — and by default it is
also where the agent's output lives.

- **Left click** opens the copilot panel as a popover under the status item:
  cards, the question field, and whatever is currently broken. Click anywhere
  else and it closes. Nothing is left covering your work. Hovering a card shows
  a ✕ that dismisses it — the panel is a ring of six and used to have no way out
  of a card except waiting for five more to push it off. Dismissing is not
  deleting: the same text stays in the chat, which is the surface built for
  keeping things.
- **Right click** (or ⌃-click) opens the commands.

The button shows a count when cards arrive while the panel is closed, and puts a
failed subsystem at the top of the menu.

- **Keep Overlay On Screen** — off by default. On, the panel becomes a real
  floating window in a screen corner instead of a popover. An always-on-top
  window over someone else's work is something you ask for, not something you
  have to find the switch for.
- **Float Above Other Windows** — off, the overlay behaves like an ordinary
  window and the frontmost app covers it.
- **Collapse to Pill** — shrinks it to a small title bar.
- **Click-Through** — off by default. On, it is `ignoresMouseEvents` at the
  window level, which is genuinely whole-window: *every* click on the overlay
  goes to the app behind it, including the ones aimed at its own buttons and
  question field. That is the right behaviour for a read-only heads-up display
  and the wrong one for anything you want to click, so it is now opt-in.
- **Position** — top/bottom, left/right. Dragging the overlay works too, and the
  dragged position is what gets remembered.
- **Settings…** / **Permissions…** / **Quit Copilot**.

The last four apply to the floating overlay, so they are dimmed while it is off.
Every one of these persists across launches. Opening the app a second time
reopens Settings rather than doing nothing.

### Language and Speech Recognition

English, 日本語 (Japanese), and 한국어 (Korean) are officially supported across all layers of the application. Configure your preferences under **Settings ▸ General ▸ Language**.

**Interface** — English, 日本語, 한국어, or *Match macOS* (the default, resolved
from your system language list). One control for two things that would be absurd
to set separately:

- the interface — menu bar, settings, overlay, permission walkthrough;
- the language the agent writes its answers and advice cards in, as a directive
  appended to every system prompt rather than a translation pass, so code blocks
  survive and no second request is spent.

**Engine** — choose between two transcription engines:

- **Gemini Flash (Cloud / High Accuracy)**: Uses Google's Gemini Flash multimodal AI to transcribe audio in fast batches. It provides state-of-the-art accuracy, contextually resolves difficult homophones (especially in Japanese and Korean technical vocabulary), and cleans up verbal fillers and hesitations.
- **macOS (On-Device / Private)**: Apple's on-device `SpeechAnalyzer`. Audio never leaves your Mac, ensuring 100% offline privacy.

**Speech** — which language the microphone is transcribed as: *Automatic* (the
default), English, 日本語 or 한국어. Separate from the interface because reading
the app in one language and dictating in another is an ordinary thing to want,
and a single control makes one of the two wrong with no way to say so.

*Automatic* means "follow the interface language", **not** "work out what is
being spoken". `SpeechTranscriber` is built against exactly one locale and does
no language identification, so detection would mean running several recognisers
at once and guessing — continuous battery cost, still wrong on code-switched
speech. Instead the resolved language is stated wherever it matters: under the
picker (`Automatic → 한국어 (ko-KR)`), on the large caption, in the chat's voice
bar, and in the card that opens a dictation session. Settings also says whether
that language's model is installed, merely downloadable, or unsupported on this
Mac — a first dictation that stalls for a minute is a download, not a hang.

With both on automatic the speech locale stays `Locale.current`, so an en-GB Mac
keeps its own model rather than being moved to en-US.

Both apply immediately, no relaunch. A change that moves the speech locale
restarts transcription, so a couple of seconds of audio are lost at the swap; a
change that does not — switching the interface while speech is pinned — leaves
the running transcriber alone.

Two things stay English on purpose. Error text from macOS and from model
providers is shown exactly as it arrives — paraphrasing a message you may need to
paste into a search helps nobody — and the `mca` command line is a developer
surface with one language.

### Shortcuts

Defaults: `⌥⌘Space` ask · `⌥⌘H` overlay on/off · `⌥⌘J` collapse/expand ·
`⌥⌘X` click-through · `⌥⌘V` voice session · `⌥⌘W` watch this window.

`⌥⌘Space` opens the chat window with the caret in the field, whatever the
overlay is doing.

`⌥⌘W` pins the watch to the window you are in and starts watching if it was
off, so "keep an eye on this" is one keypress rather than a switch and a
button. `⌘W` still closes windows everywhere — the option key is part of the
chord, and `RegisterEventHotKey` matches the whole thing.

The two voice modes are two buttons — a microphone for **Dictation**, a waveform
for **Live conversation** — in the chat toolbar, on the panel and in the ✨
menu. Pressing one starts it, pressing it again ends it, and pressing the other
mid-session switches. There is no mode setting, because the button *is* the
mode; a picker in front of one button made starting to talk two decisions deep,
and left the interface claiming a mode while the user was looking for a
microphone. **Settings ▸ General ▸ Voice** describes the two rather than
choosing between them, since what actually differs is what leaves the machine:
live streams your microphone to Google, dictation transcribes here and sends
only the text.

`⌥⌘V` has no mode of its own — it starts whichever of the two you used last, and
ends it. The ✨ menu shows the chord on that one item, so it never advertises a
shortcut that would do something else.

All five are rebindable in **Settings ▸ Shortcuts**, and that tab exists because
the failure mode is invisible otherwise. `RegisterEventHotKey` claims a chord
system-wide for whichever application asked for it first and reports nothing to
anyone else — the key combination simply stops doing anything. The Shortcuts tab
marks a chord another app has taken, refuses one already bound to a different
action, and lets you clear a shortcut entirely (the menu bar still works).

`listen` and `capture` exist to test the risky layers on their own. If
`mca listen` shows your voice on one channel and the other participant on the
other with no echoed duplicates, the foundation is sound.

### Reading back what you said

Speech is the one input with no keystroke to check against, so what was heard is
shown in three places at once: the large caption across the bottom of the screen
you are working on, the chat's voice bar, and — once the turn ends — the
conversation itself, as an ordinary user message above the reply. That last one
is why a spoken session is still readable an hour later; before it, the thread
was a column of answers to questions that existed only in a caption that had
since been cleared.

Settled text and the engine's current guess are drawn differently — full
strength versus half — rather than concatenated. They are different claims
("this is what you said" versus "this is what you might be saying"), and drawing
them alike makes every mid-sentence revision look like the recogniser getting it
wrong. In **Speak, then chat** mode the recognition language sits next to the
words, so a transcript that comes out as plausible nonsense is traceable to the
setting rather than blamed on the microphone.

The caption can be switched off in **Settings ▸ General ▸ Voice**; the chat and
the panel still show the same text.

---

## Architecture

Seven SwiftPM targets, dependencies strictly one-directional:

```
mca (composition root)
 ├── MCAPresentation   NSPanel HUD, SwiftUI, global hot keys
 ├── MCAInterop        MCP server / client
 ├── MCARealtime       Gemini Live voice session, with server-side web search
 ├── MCAReasoning      provider abstraction, routing, tools, agent
 ├── MCAMemory         SQLite + FTS5, hybrid retrieval
 ├── MCAPerception     VAD, on-device STT, Vision OCR
 ├── MCASensing        ScreenCaptureKit, AXUIElement, CoreAudio tap, VPIO
 └── MCACore           value types, health registry, ring buffer
```

Three constraints drove the shape. See
[`docs/architecture_v2_design_proposals.md`](docs/architecture_v2_design_proposals.md)
for the alternatives that were considered and rejected.

**The audio path cannot cross a process boundary.** A CoreAudio I/O callback
runs on a realtime thread where allocation, locks and IPC are forbidden. That
rules out a Python or Node sidecar for capture, and it is why barge-in
(< 100 ms) lives in-process. `AudioRingBuffer` is the single sanctioned handoff
between the realtime thread and everything else.

**The LLM path is network-bound anyway.** 300–800 ms of time-to-first-token
makes a process boundary irrelevant, so that layer is chosen for extensibility
rather than speed.

**Always-on has to be nearly free.** Sending every five-second scan to a cloud
model costs roughly $390/month at current Gemini Flash pricing. An on-device
gate that escalates ~2% of scans brings that to about $8.

### Multi-provider

Every provider — Gemini, Anthropic, OpenAI-compatible (which also covers Ollama,
LM Studio, vLLM, Groq, OpenRouter) and Apple's on-device model — implements one
protocol:

```swift
protocol LanguageModelExecuting: Sendable {
    var identifier: String { get }
    var capabilities: ModelCapabilities { get }
    func respond(to: GenerationRequest, streamingInto: GenerationChannel) async throws
}
```

The transcript's six entry kinds (`instructions`, `prompt`, `toolCalls`,
`toolOutput`, `response`, `reasoning`) deliberately mirror Apple's Foundation
Models framework. When macOS 27's pluggable-provider API becomes the deployment
target, these executors conform to Apple's `LanguageModelExecutor` and this
abstraction is deleted rather than migrated.

Routing is per-task, not per-call-site, and lives in configuration:

| Task | Model | Notes |
|---|---|---|
| `triage` | Apple on-device | free, local, runs constantly |
| `classify` | `gemini-3.8-flash` | `thinkingLevel: minimal` |
| `answer` / `vision` | `gemini-3.8-flash` | |
| `hardReasoning` | `gemini-3.8-flash` | explicit request only, `thinkingLevel: high` |

Every cloud tier uses the same Gemini model (`gemini-3.8-flash`). Flash Lite is
not used: a second model ID costs a second set of quota, capability and
deprecation dates to track, and the on-device triage gate — not the price of the
fallback — is what keeps the constant path free. Cost is bounded by
`reasoningLevel` and `maxOutputTokens` per task instead.

Model IDs and budgets are in `~/Library/Application Support/MyComputerAgent/config.json`,
not compiled in — Gemini 3.8 Flash doubles in price on 2027-01-01 and preview
model IDs get retired.

### Security & Privacy

MyComputerAgent is built on a strict **Zero-Trust, Local-First** security and privacy architecture. For detailed security policy and reporting instructions, see [SECURITY.md](SECURITY.md).

- **Hardware-Backed Secret Storage**: API keys entered in Settings are sealed using **HPKE (RFC 9180, `P256_SHA256_AES_GCM_256`)** against a hardware P-256 key generated in the Apple Silicon **Secure Enclave Processor (SEP)**. Plaintext never touches disk or keychain.
- **Pre-Capture Credential Manager Exclusion**: Windows belonging to password managers (1Password, Bitwarden, Keychain Access, LastPass, KeePassXC) are completely excluded prior to capture and never enter memory or disk.
- **Secure Text Field Protection**: `AXSecureTextField` contents (passwords, PINs) are never read or processed.
- **In-Flight PII & Token Redaction**: In-flight UI text is automatically scrubbed with regex sanitizers to mask API keys, bearer tokens, and credit card numbers before any data reaches AI models.
- **Self-Inspection Guard**: The agent refuses to inspect its own PID or windows (`sharingType = .none`), preventing UI recursion or hallucination loops.
- **Microphone Off at Launch**: The microphone is never open at startup. It opens only during explicit voice sessions (⌥⌘V) and closes immediately when finished.
- **On-Device By Default**: All audio and screen observation paths transcribe locally on-device by default (`SpeechAnalyzer` / Vision OCR); data is never transmitted to cloud models without explicit user interaction.
- **Stdio-Only MCP Server**: The MCP server runs over standard I/O (stdio) for local tools; it never opens unauthenticated network ports on your machine.

---

## Tests

```bash
swift test
```

**354 tests in 48 suites**, verifying every layer:

- **Contract tests.** `ExecutorContract` is one suite of assertions run against
  both the scripted fake *and*, when credentials are present, the live Gemini,
  Anthropic and Apple executors. A fake that drifts from the real thing fails
  the same test the real one does.
- **Wire formats.** Each provider's request encoding is asserted against its
  published shape — Gemini's `thinkingLevel` (not `thinkingBudget`), Anthropic's
  `tool_use`/`tool_result` pairing, OpenAI's arguments-as-string. No network.
- **Real SQLite.** The store tests run against actual files, actual FTS5
  triggers and actual fusion.
- **Concurrency.** The ring buffer is exercised with a concurrent producer and
  consumer over 100k frames.
- **Utterance boundaries.** Where a dictated question begins and ends is pure
  logic (`DictationBuffer`) and is tested as such — a boundary that fires early
  asks one sentence as three, and one that never fires is a microphone that
  listens and answers nothing.
- **The Live setup frame.** The whole negotiation with the Live API is one JSON
  frame, and the server's answer to a wrong one is a close code with no message.
  It is asserted field by field before it can ever reach Google.
- **Desktop Automation & Grounding.** Accessibility inspector and event synthesizer
  isolation, coordinate transformation, and TypeSafe Jev decision engine fallback.

Live-provider tests skip without an API key rather than falling back to mocks,
because a mocked HTTP layer only proves our encoder matches our decoder.

---

## Known limitations

- Apple Intelligence must be enabled for the on-device triage gate. Without it,
  triage falls back to a cloud model and running cost rises substantially;
  `mca doctor` says so.
- Speaker separation is per-channel (you vs. everyone else). Distinguishing
  multiple remote speakers needs a diarization model; `AudioChannelPipeline` has
  the seam for it.
- Live-session audio output is decoded but not yet routed to an output device.
- `NLEmbedding` is implemented but not enabled: measured on this corpus it ranks
  irrelevant text above relevant text, so the semantic path uses on-device query
  expansion instead. `MCAMemoryTests` asserts that defect, so the decision gets
  revisited if a future OS fixes it.

---

## Documentation

- [User Manual](docs/manual/MANUAL.md) ([日本語](docs/manual/MANUAL.ja.md) • [한국어](docs/manual/MANUAL.ko.md))
- [Contributing](CONTRIBUTING.md) ([日本語](CONTRIBUTING.ja.md) • [한국어](CONTRIBUTING.ko.md))
- [Security Policy](SECURITY.md) ([日本語](SECURITY.ja.md) • [한국어](SECURITY.ko.md))
- [Code of Conduct](CODE_OF_CONDUCT.md) ([日本語](CODE_OF_CONDUCT.ja.md) • [한국어](CODE_OF_CONDUCT.ko.md))

---

## Contributing

Contributions are welcome! Please read our [Contributing Guidelines](CONTRIBUTING.md) and [Code of Conduct](CODE_OF_CONDUCT.md) before submitting pull requests.

1. Fork the repository and create a feature branch (`git checkout -b feature/my-feature`).
2. Adhere to the layered architecture (`Core` → `Sensing` → `Perception` → `Memory` → `Reasoning` → `Realtime` → `Interop` → `Presentation`) and zero-plaintext secrets rule (`SecretStore`).
3. Verify your changes pass the quality gate:
   ```bash
   ./Scripts/gate.sh
   ```
4. Open a Pull Request referencing the [PR Template](.github/PULL_REQUEST_TEMPLATE.md).

---

## License

- **Project License**: Released under the **MIT License** — see [LICENSE](LICENSE) for details.
- **Third-Party Notices**: Licenses and copyright notices for the open-source libraries this project uses (`swift-sdk`, `eventsource`, the Apple Swift packages) are in [NOTICES.md](NOTICES.md). Both `LICENSE` and `NOTICES.md` are copied into `MyComputerAgent.app/Contents/Resources/` by `Scripts/bundle.sh`.
- **Security Policy**: See [SECURITY.md](SECURITY.md) for vulnerability reporting and security guarantees.

Copyright (c) 2026 buddypia / MyComputerAgent Contributors.
