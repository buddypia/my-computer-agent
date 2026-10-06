# MyComputerAgent (mca) User Manual

**English** | [日本語](MANUAL.ja.md) | [한국어](MANUAL.ko.md) | [README](../../README.md)

## Table of contents

1. [What it is](#1-what-it-is)
2. [Install and build](#2-install-and-build)
3. [Permissions](#3-permissions)
4. [First run](#4-first-run)
5. [API keys](#5-api-keys)
6. [Command line (mca)](#6-command-line-mca)
7. [Using it from Claude Code and Codex (MCP)](#7-using-it-from-claude-code-and-codex-mcp)
8. [The menu bar item and the panel](#8-the-menu-bar-item-and-the-panel)
9. [The chat window](#9-the-chat-window)
10. [Watching your screen and the screen picker](#10-watching-your-screen-and-the-screen-picker)
11. [Voice, language and speech settings](#11-voice-language-and-speech-settings)
12. [Keyboard shortcuts](#12-keyboard-shortcuts)
13. [Privacy model](#13-privacy-model)
14. [Where your data lives and how to delete it](#14-where-your-data-lives-and-how-to-delete-it)
15. [Troubleshooting](#15-troubleshooting)
16. [FAQ](#16-faq)

---

## 1. What it is

MyComputerAgent (command name `mca`) is a local-first desktop copilot for macOS. It reads the window you are working in, keeps a searchable history on your own Mac, answers questions about what is on your screen, and can speak up when it notices a mistake or a faster way. It can also listen to your microphone and to system audio, but only when you ask it to.

It lives in the menu bar (a sparkle icon) and has no Dock icon.

**Requirements**

- macOS 26 or later on an Apple Silicon Mac.
- To build from source: Xcode 26.6 or later (Swift 6.2 or later).
- API keys are optional. Without any key, recording, local search and local GUI grounding still work. Cloud answers, vision and Live conversation need a key (see [API keys](#5-api-keys)).

This manual describes what the app does today. For architecture and design notes, see the [README](../../README.md); for the security policy, see [SECURITY.md](../../SECURITY.md).

---

## 2. Install and build

There is no prebuilt installer. Build the app bundle from source:

```bash
git clone https://github.com/buddypia/my-computer-agent.git
cd my-computer-agent
./Scripts/bundle.sh
open build/MyComputerAgent.app
```

`Scripts/bundle.sh` builds a release binary, wraps it in `build/MyComputerAgent.app` with an `Info.plist` and entitlements, and signs it.

**Do not skip the bundle step.** macOS attributes permissions to a signed bundle identifier (`com.buddypia.mca`) and reads the permission prompt text from `Info.plist`. A bare binary built with `swift build` has neither. In particular, `AudioHardwareCreateProcessTap` fails on an unsigned binary without ever showing a prompt, which looks exactly like an app bug.

### Signing

`bundle.sh` picks a signing identity in this order: the identity you pass as the first argument, the `MCA_SIGN_IDENTITY` environment variable, a "Developer ID Application" certificate, an "Apple Development" certificate, and finally ad-hoc signing (`-`).

```bash
./Scripts/bundle.sh "Developer ID Application: Your Name (TEAMID)"
```

An ad-hoc signature is pinned to the binary hash. Every rebuild looks like a different app to macOS, so permissions are asked for again and stale entries may stop matching. Any real certificate (a free Apple Development certificate from Xcode ▸ Settings ▸ Accounts is enough) produces a stable identity and avoids this. After an ad-hoc rebuild, run `mca reset-permissions` and relaunch.

### Optional: put it in Applications

You can copy `build/MyComputerAgent.app` to `/Applications`. The command line tool is the binary inside the bundle (see [Command line](#6-command-line-mca)).

### Rebuilding while developing

```bash
./Scripts/run.sh
```

This rebuilds the bundle, stops the old process and relaunches. Plain `swift build` followed by `open` does not pick up your change: `swift build` does not update the bundle, and `open` on an already running menu bar app only re-opens Settings.

---

## 3. Permissions

| Permission | Why the app needs it | What breaks without it |
|---|---|---|
| **Accessibility** | Reads the text and structure of other apps' windows; sends clicks and keystrokes for actions. | The agent sees nothing. |
| **Screen Recording** | Screenshots for the OCR fallback, Explain, Snip, screen watch and the screen picker thumbnails. | No OCR fallback for apps that expose no accessibility tree; windows do not appear in the picker. |
| **Microphone** | Dictation and Live conversation. | Cannot hear you; only the other side of a call is transcribed. |
| **Audio Capture** | Captures system audio through a CoreAudio process tap (no virtual audio driver). | Cannot hear meeting participants. |

In System Settings ▸ Privacy & Security, Screen Recording and Audio Capture share the **Screen & System Audio Recording** pane. The Microphone grant is only needed when you start a voice session.

### Grant them from the running app, not from a terminal

macOS attributes a permission to the "responsible" process. For a binary started from a terminal, that is the terminal. A prompt answered from `mca doctor` therefore grants the permission to Terminal and leaves the agent with nothing.

1. Launch the app with `open build/MyComputerAgent.app` (or double-click it).
2. Click the sparkle icon in the menu bar, right-click for the menu, and choose **Permissions…** (this opens Settings ▸ Permissions).
3. Click **Ask macOS for everything**. macOS asks once per app identity. After that, use the buttons in the Permissions tab to jump to the right pane in System Settings. The tab refreshes as you flip each switch (**Recheck now** forces a refresh).
4. If macOS says a change needs a relaunch, quit the app from its menu (**Quit Copilot**) and open it again.

"My Computer Agent" only appears in the Screen Recording, Microphone and Audio Capture lists after the app has asked once. If it is missing, make sure the app is running and ask again from the Permissions tab.

The Permissions tab labels each item **Granted**, **Not granted**, or "Belongs to the terminal, not this app". It also warns when the app was started from a terminal, ad-hoc signed or unsigned.

`mca reset-permissions` clears this app's Microphone, Screen Recording, Accessibility and Speech Recognition grants (through `tccutil`) so that macOS prompts again.

---

## 4. First run

1. Open `MyComputerAgent.app`. There is no Dock icon and no window; a sparkle icon appears in the menu bar. On launch the app checks permissions and raises any prompts that are still needed.
2. Right-click the sparkle icon and choose **Settings…**. (Opening the app a second time also opens Settings.)
3. **Permissions** tab: grant the four permissions as described above.
4. **Models & Keys** tab: paste a Gemini key and click **Save** (optional but recommended; see [API keys](#5-api-keys)). It takes effect immediately; no relaunch.
5. Press `⌥Space` to open the chat and ask something about what is on your screen.
6. Optional check from a terminal: `build/MyComputerAgent.app/Contents/MacOS/mca doctor`.

Nothing that listens or looks at pictures is on after launch: the microphone is closed, and **Watch my screen** is off. See [Privacy model](#13-privacy-model).

---

## 5. API keys

Keys are optional. Which features need which key:

| Provider | Setting name (id) | Environment variable | Role |
|---|---|---|---|
| Google Gemini | `gemini` | `GEMINI_API_KEY` (or `GOOGLE_API_KEY`) | Primary route for classify, answers, vision and hard reasoning; Live conversation; Gemini Flash transcription. |
| Anthropic | `anthropic` | `ANTHROPIC_API_KEY` | Fallback for answers and vision. |
| OpenAI-compatible | `openai-compatible` | `OPENAI_API_KEY` | Fallback for answers and vision (talks to `https://api.openai.com/v1`). |
| TypeSafe AI (Jev) | `typesafe` | `TYPESAFE_API_KEY` | Low-latency GUI grounding for actions. Without it, a deterministic local semantic fallback is used. |

Default routing uses Apple's on-device model for the "is this worth interrupting you?" gate, and `gemini-3.8-flash` for classify, answer, vision and hard reasoning, with Anthropic and OpenAI-compatible models as fallbacks for answers and vision. `mca doctor` prints the routing table and marks routes that cannot run.

### Adding a key (recommended way)

Settings ▸ **Models & Keys** ▸ **API keys**: paste the key, click **Save**. The app writes the keychain item itself, so it can read it back later without an "allow access?" dialog. The field never shows a stored key again; you can **Replace** or **Remove** it. Each provider shows where its key comes from: *In your keychain*, *From $VARIABLE*, or *No key*.

### How keys are stored (`SecretStore`)

Keys are not stored as plaintext. Each key is sealed with HPKE (RFC 9180, `P256_SHA256_AES_GCM_256`) to a P-256 key generated inside this Mac's Secure Enclave, and only the ciphertext goes into your login keychain. The provider name is bound as authenticated data, so a record cannot be moved from one provider's slot to another's.

- A key written by an older build is re-sealed automatically the first time it is read.
- Erasing the Mac or resetting the Secure Enclave makes stored keys unreadable (they are device-bound by design). Paste them again; the app tells you so instead of reporting "no key".
- On a Mac without a Secure Enclave, a software wrapping key is used and Settings says so in orange.

### Environment variables

If the variable is set to a non-empty value, it takes precedence over the keychain and is never written anywhere. Useful for development and for `mca` commands started from a shell.

- A menu bar app opened from Finder or `open` does **not** inherit variables from your shell profile. Use Settings for the app, and environment variables for terminal-started commands (including `mca mcp` started by an MCP client).
- The app does not read a `.env` file. The repository's `.env.example` is only a list of variable names; export them in your shell or your MCP client's configuration.

### Command line

```bash
mca auth set gemini        # prompts on stdin, so the key stays out of shell history
mca auth delete gemini
```

Providers: `gemini`, `anthropic`, `openai-compatible`, `typesafe`. A key stored with the CLI belongs to the CLI binary, so macOS asks for permission the first time the app reads it, which is easy to miss and looks like "no key". Prefer Settings.

---

## 6. Command line (mca)

The executable is inside the app bundle. Define an alias for convenience:

```bash
alias mca="/path/to/MyComputerAgent.app/Contents/MacOS/mca"
```

Run with no command to start the app (`mca run`). Global option, placed before the command: `--debug` or `-d` enables verbose logging (same as `MCA_DEBUG=1`).

| Command | What it does |
|---|---|
| `mca run` | Start the copilot and its menu bar item (default). |
| `mca doctor` | Read-only report: permissions, code signing, Apple Intelligence availability, which provider keys exist, the history database path and how many observations it holds, and routing. |
| `mca listen [seconds]` | Capture and transcribe for N seconds (default 20) and print the microphone and system-audio channels separately. |
| `mca capture [seconds]` | Wait N seconds (default 0), then read the focused window once and print what was extracted. Says when the window is excluded by the privacy filter. |
| `mca ask "question"` | One-shot question with current desktop context; the answer streams to stdout. |
| `mca search "terms"` | Search recorded history (with on-device query expansion). Prints up to 20 matches. |
| `mca act …` | Perform screen actions (see below). |
| `mca browser …` | Drive a Chromium browser by element references (see below). |
| `mca mcp` | Serve context and tools over MCP on stdio (see [section 7](#7-using-it-from-claude-code-and-codex-mcp)). |
| `mca auth set\|delete <provider>` | Store or remove a provider API key. |
| `mca setup` | Open the guided permission walkthrough (prefer Settings ▸ Permissions in the running app). |
| `mca reset-permissions` | Clear this app's TCC grants so macOS prompts again. |
| `mca help` | Show usage. |

Commands that run from a terminal (`doctor`, `listen`, `capture`, `ask`, `act`) report the **terminal's** permissions, not the app's. `mca doctor` prints a warning when it detects this.

### `mca act`

```text
mca act [options] [<goal>]
  --goal, -g <text>        Natural-language goal (implies --autonomous)
  --autonomous, -a         Plan subgoals and loop until done
  --max-steps, -s <n>      Step limit (default 20)
  --confidence, -c <0-1>   Minimum confidence (default 0.80)
  --dry-run, -n            Plan and decide without sending any clicks or keys
```

```bash
mca act "click the Search button"                                   # single step
mca act --goal "Open Safari and search for Tokyo weather" --dry-run # preview only
mca act --autonomous --max-steps 15 "Fill in the registration form"
```

This really moves the mouse and types. Start with `--dry-run`. Press Ctrl+C to halt an autonomous run. Non-dry runs need Accessibility permission for the terminal.

### `mca browser`

Drives a browser through its DevTools endpoint on `127.0.0.1` (ports 9222 and 9333 are probed), falling back to macOS Accessibility on the frontmost browser window. It opens its own tab and does not navigate your tabs.

```text
navigate <url> | snapshot [--filter T] [--max-depth N] | click <ref> | fill <ref> <text>
type [<ref>] <text> | press <key> | select <ref> <option> | scroll <ref> <percent>
act "<instruction>" | observe ["<instruction>"] | extract "<instruction>"   (these need a model)
text | url | title | tabs | tab new|switch|close | wait … | eval "<js>" | screenshot [path]
back | forward | reload
```

Run `mca browser help` for the full list.

---

## 7. Using it from Claude Code and Codex (MCP)

`mca mcp` runs a Model Context Protocol server over **standard input/output**. It opens no network port. The client starts it as a subprocess.

**Tools exposed**

| Tool | Purpose |
|---|---|
| `search_context` | Search what the user has seen and heard (query, last N minutes, app, limit). |
| `recent_activity` | What the user has been doing recently. |
| `conversation_history` | Recent transcribed conversation (`me`, `others` or `all`). |
| `computer` | Mouse and keyboard actions at coordinates. |
| `click_element` | Click a UI element by title or label. |
| `run_applescript` | Run AppleScript. |
| `inspect_ui_elements` | List actionable elements of the focused window. |
| `typesafe_act` | One GUI action from a natural-language goal. |
| `autonomous_act` | Multi-step goal with a step limit, confidence threshold and dry-run. |
| `browser_*` | Browser tools (navigate, snapshot, element, act, observe, extract, read, tabs, wait, evaluate), included unless browser automation is disabled in `config.json`. |

**Claude Code**

```bash
claude mcp add my-computer-agent -- /path/to/MyComputerAgent.app/Contents/MacOS/mca mcp
```

**Codex CLI** (`~/.codex/config.toml`)

```toml
[mcp_servers.my-computer-agent]
command = "/path/to/MyComputerAgent.app/Contents/MacOS/mca"
args = ["mcp"]
```

Notes:

- The server reads the same history database as the app, so run the app (or have run it) first for there to be anything to search.
- Permissions are attributed to the program that launched the server (your terminal or editor). The computer-control tools need Accessibility for that program. Searching history needs no special permission.
- **Dangerous tools are refused over MCP by default.** An MCP client has no way to show you a confirmation, so `run_applescript`, `computer`, `click_element`, `typesafe_act`, `autonomous_act` (when not a dry run), the browser tools that act on a page (`browser_navigate`, `browser_element`, `browser_act`, `browser_tabs` when it opens, switches or closes a tab, and `browser_read` when given a `path`) and `browser_evaluate` return an error. Reading tools (search, history, `inspect_ui_elements`, `browser_snapshot`, `browser_observe`, `browser_extract`, `browser_wait`, and `browser_read` / `browser_tabs` in their reading forms) work as usual. To allow the gated tools for a client you trust, set `"mcpAllowDangerousTools": true` in `config.json` and restart the client. See [SECURITY.md](../../SECURITY.md) section 5.
- `computer`, `click_element`, `run_applescript` and the act tools let the connected agent operate your Mac. Only connect clients you trust, and prefer `dry_run` for experiments.
- Provider keys are resolved the same way as in the app: environment variable first (for example `GEMINI_API_KEY`, inherited from the client's environment), then the keychain.

---

## 8. The menu bar item and the panel

The sparkle icon is the app.

- **Left click** opens the copilot panel as a popover: cards, the question field and anything that is broken. Click elsewhere and it closes. Hover over a card to show a ✕ that dismisses it (the text stays in the chat).
- **Right click** (or Control-click) opens the menu.
- The icon shows a number when cards arrive while the panel is closed, and changes to a cursor-with-slash symbol while click-through is on. The tooltip describes the current state. A failed subsystem is listed at the top of the menu with a warning mark.

**Menu items**

| Item | Meaning |
|---|---|
| Show the Panel on the Desktop | Off (default): the panel is the popover. On: it becomes a floating window in a screen corner. |
| Collapse to a Bar / Restore the Panel | Shrinks the floating panel to a thin title bar. |
| Keep in Front of Other Windows | On: stays in front on every Space and over full-screen apps. Off: behaves like an ordinary window. |
| Let Clicks Pass Through | On: every click on the panel goes to the app behind it, including clicks aimed at its own buttons. Turn it off with `⌥⌘X` or this menu. |
| Position | Top or bottom, left or right. Dragging the panel (with click-through off) also works, and the dragged position is remembered. |
| Open the Chat… | Opens the chat window (`⌥Space`). |
| Snip Screen & Explain… | Drag to select an area of the screen and have it explained. Esc cancels. |
| Clear Chat… | Deletes all messages after confirmation. |
| Choose a Screen to Watch… | Opens the screen picker. The title changes to show what is being watched. |
| Start a Live Conversation / Start Dictation | The two voice modes (see [section 11](#11-voice-language-and-speech-settings)). |
| Settings… | `⌘,` while the menu is open. |
| Permissions… | Opens Settings ▸ Permissions. |
| Quit Copilot | `⌘Q` while the menu is open. |

The window-related items (collapse, front, click-through, position) apply to the floating panel and are dimmed while it is off. All of these choices persist across launches. Settings ▸ **Panel** has the same switches plus **Let the panel appear in screenshots** (off by default; see [Privacy model](#13-privacy-model)).

---

## 9. The chat window

Open it with `⌥Space`, the **Chat** button on the panel, or **Open the Chat…** in the menu. It opens centered and in front with the cursor already in the field. It is deliberately not modal: everything else keeps working. Press Esc to close it.

Answers and the agent's own observations land in one thread. Press Return to send. Right-click a message to **Copy**, **Delete this message**, or **Delete this and everything above**. The trash icon (or **Clear Chat…** in the menu) starts a new conversation after confirmation. The thread is held in memory for the session.

**Toolbar**

| Control | What it does |
|---|---|
| **Explain** | One-shot: looks at what the picker is pointed at and explains it in the chat. With nothing pinned it uses the display the pointer is on. Works on canvas-drawn apps (diagrams, PDFs, video calls) because it uses a picture. |
| **Snip** | Drag to select part of the screen and explain it. |
| **Continuous Watch** | Turns the screen watch on or off (see next section). Shows *Watching* or *Looking…* while active. |
| Pin button | Opens the screen picker. Shows the pinned window or display, or the number of watched screens. |
| Interval menu | How often to look: every 15 seconds, 45 seconds or 2 minutes. |
| Microphone | **Dictation**. |
| Waveform | **Live conversation**. |
| Trash | Start a new conversation. |

A bar of **Quick Presets** sits next to the message field, showing the current target. A preset runs once against the current target ("Execute Once"); its menu can also set it as the objective of the continuous watch, edit it, or delete it.

---

## 10. Watching your screen and the screen picker

### Continuous Watch

Off by default and off again at every launch. When on, the agent looks at the target on a timer and speaks only if it sees a mistake, an error, a risk or a faster way. The line under the thread says what it last did, so a quiet watch can be told apart from a broken one.

Nothing is sent for a screen that has not changed since the last look, for an app on the exclusion list, for this app's own windows, or while an answer you asked for is still streaming. Three failed looks in a row stop the watch and tell you why (for example a missing API key).

A pinned subject is compared as a coarse picture (a small greyscale reduction), so a blinking cursor is not a change but a finished build is. If a pinned window is closed or a pinned monitor is unplugged, the watch stops instead of moving somewhere else. While something is pinned, focus-driven captures are paused so that the pinned subject stays the newest thing in the history.

### The screen picker

Open it with the pin button in the chat, the **Screen** button on the panel, or **Choose a Screen to Watch…** in the menu. It shows live thumbnails (refreshed every three seconds while it is open) in two groups: **Windows** and **Entire screen**.

- Click a tile to select it. Double-click it, or press **Watch this** (Return), to apply. Applying also turns the watch on if it was off. Esc or **Cancel** closes the picker.
- **Focused window** follows whichever window is in front. A pinned **window** follows its content wherever you drag it. A pinned **display** holds a region of the desk and watches whatever is on it.
- The circle at the corner of a tile adds it to a multi-target selection; the button then reads **Watch N targets**. Each target has its own **purpose** menu (built-in purposes such as general advice, error diagnosis, summary and minutes, action items, code review, meeting support, AI CLI development monitoring, and spec/design checking, plus **Custom System Prompt…** for your own). The built-in purposes are written in Japanese.
- Excluded apps have no tile, and excluded windows are left out of a display's tile and out of what is sent. The picker's own window is hidden from screen capture.
- If the list is empty, Screen Recording is probably not granted.

`⌥⌘W` pins the window you are in without opening the picker (and starts the watch); pressing it again lets go.

### Snip

**Snip** (chat toolbar, panel, or menu) dims the screen so you can drag a rectangle. The selected area is sent to the model for an explanation. Esc cancels.

---

## 11. Voice, language and speech settings

### Two voice buttons

- **Dictation** (microphone): what you say is transcribed, then goes to the same chat model as a typed question, with screen context and tools. Whether audio stays on your Mac depends on the speech engine (below).
- **Live conversation** (waveform): Gemini hears you and answers out loud over one connection, and searches the web for current information. **Your microphone audio is streamed to Google for as long as the conversation is open.** It needs a Gemini key.

Press a button to start, press it again to end, press the other one mid-session to switch. `⌃⌥V` starts whichever mode you used last, and ends it. What the microphone heard is drawn as large type across the bottom of the screen you are working on, shown in the voice bar of the chat, and added to the conversation as a normal user message when the turn ends. Settled text and the engine's current guess are drawn at different strengths. You can turn the large caption off in Settings ▸ General ▸ **Voice**.

The microphone is not open at launch. It opens when a voice session starts and closes when it ends. To keep it (and the system-audio tap) open all the time, turn on **Listen continuously** in Settings ▸ General ▸ **Audio** (off by default; may raise a microphone prompt and download a speech model).

### Language (Settings ▸ General ▸ Language)

- **Interface**: English, 日本語, 한국어, or **Match macOS** (default). This sets the language of the menus, Settings and permission screens, and the language the agent writes its answers and advice in. It applies immediately.
- **Engine**: **Gemini Flash (Cloud / High Accuracy)** or **macOS (On-Device / Private)**. The default is Gemini Flash, which sends audio to Gemini for transcription; if no Gemini key is stored, the app uses the on-device engine instead. Choose **macOS (On-Device / Private)** if audio must never leave your Mac.
- **Speech Language**: Automatic (default), English, 日本語 or 한국어. **Automatic follows the interface language**; it does not detect which language you are speaking. Settings shows the resolved language (for example "Automatic → 한국어 (ko-KR)") and whether that language's on-device model is installed, still downloadable or unsupported. A first dictation that stalls for a while is usually a model download. If the language is unsupported on your Mac, Dictation will not start but Live conversation still works.

Changing the speech locale restarts transcription, so a few seconds of audio are lost at the switch. Error text from macOS and from model providers is shown as received, in its original language, and the `mca` command line is English only.

---

## 12. Keyboard shortcuts

Defaults (all global, all rebindable):

| Shortcut | Action |
|---|---|
| `⌥Space` | Ask a Question: open the chat with the cursor in the field |
| `⌥⌘H` | Show / Hide the Panel (the agent keeps watching) |
| `⌥⌘J` | Collapse / Restore the Panel |
| `⌥⌘X` | Let Clicks Pass Through (toggle) |
| `⌃⌥V` | Start / End a Conversation (the voice mode used last) |
| `⌥⌘W` | Watch This Window (pin; press again to release) |

Other keys: `Esc` closes the chat window and cancels Snip and the screen picker; `Return` sends a message and applies the picker's selection; `⌘,` and `⌘Q` work in the menu bar menu while it is open. `⌘W` still closes windows as usual, because the whole chord including Option is what is registered.

**Settings ▸ Shortcuts** lets you record a new chord, clear a shortcut (the menu bar still works), or **Restore Defaults**. macOS gives a global chord to whichever app registered it first and tells nobody else, so the tab marks chords another app has taken, refuses a chord already bound to another action, and refuses chords macOS reserves for text editing (such as `⌘V`).

---

## 13. Privacy model

**Off at launch.** The microphone and the system-audio tap are closed until you start a voice session (or turn on Listen continuously). **Watch my screen**, which sends pictures of the screen, is off and starts off at every launch.

**What the app records by default.** While Accessibility is granted, it reads the focused window's text on OS events (focus change, window title change, typing pause), falling back to on-device OCR when an app exposes no accessibility tree, and stores it in a local SQLite database. Spoken transcripts are stored when audio is captured. Observations older than 30 days are deleted automatically. Nothing is polled at a frame rate.

**What is never read or is filtered**

- Excluded apps and windows. By default these bundle IDs are skipped before anything is stored: 1Password, Bitwarden, Keychain Access, LastPass, Dashlane and Apple Passwords. Windows whose title contains `private browsing`, `incognito`, `シークレット`, `password`, `パスワード`, `sign in`, `2fa` or `one-time code` (case-insensitive) are skipped too. You can change both lists in `config.json` (see [section 14](#14-where-your-data-lives-and-how-to-delete-it)).
- Automation is hard-blocked in password managers (1Password, Bitwarden, Apple Keychain Access and Passwords, KeePassXC): the agent will not inspect or click in them.
- Password fields (`AXSecureTextField`) are skipped when reading windows and removed from the UI elements the automation tools see.
- On the automation path, UI labels and values are scrubbed with pattern matching before they reach a model: strings that look like API keys, bearer tokens or secrets, `sk-…`, `ghp_…` and `AKIA…` tokens, and 16-digit card numbers.
- On a pinned display, excluded windows are removed inside the capture itself, so they are absent from the picture rather than blurred.
- The app's own windows are hidden from screen capture so the agent does not read its own answers back. The floating panel can be made visible to capture with **Let the panel appear in screenshots** (off by default).

**What stays on the Mac and what can leave**

| Data | Where it goes |
|---|---|
| Captured window text, OCR, history, search index | Stays in the local database on your Mac. |
| On-device "worth interrupting?" gate | Apple's on-device model. Only items that pass it reach a cloud model. Without Apple Intelligence the gate falls back to a cloud model. |
| Questions you ask, with context and tool results | Sent to the model provider that answers (Gemini by default, then Anthropic or OpenAI-compatible fallbacks). |
| Pictures from Explain, Snip and Continuous Watch | Sent to a cloud vision model. |
| Dictation audio | On-device engine: stays on the Mac and only text is sent. Gemini Flash engine: audio is sent to Gemini for transcription. |
| Live conversation audio | Streamed to Google while the conversation is open. |
| API keys | Sealed to the Secure Enclave; ciphertext only in your login keychain. |

All cloud calls use TLS (HTTPS or WSS). The MCP server uses standard input/output only and opens no listening port. To report a vulnerability, see [SECURITY.md](../../SECURITY.md).

---

## 14. Where your data lives and how to delete it

| What | Location |
|---|---|
| History database (observations and search index) | `~/Library/Application Support/MyComputerAgent/context.sqlite3` (plus `-wal` and `-shm` files) |
| Optional settings file | `~/Library/Application Support/MyComputerAgent/config.json` |
| `mca browser` state | `~/Library/Application Support/MyComputerAgent/browser-cli.json` (and `chrome-profile/` only if the app launched its own Chrome) |
| Panel, shortcut, language, voice and watch preferences | Preferences domain `com.buddypia.mca` |
| API keys (ciphertext) and the wrapping record | Login keychain, services `com.buddypia.mca.providers` and `com.buddypia.mca.wrapping-key` |
| Permission grants | macOS privacy database (TCC), under System Settings ▸ Privacy & Security |

`config.json` is optional and is created when the app saves a setting. Any key you leave out keeps its default, and changes apply on the next launch. Useful keys: `retentionDays` (default 30), `excludedBundleIDs` (prefix match on bundle ID; setting it **replaces** the default list, so copy the defaults you still want), `excludedWindowPatterns`, `mcpAllowDangerousTools` (default `false`; `true` lets MCP clients run the tools that act on your Mac and browser without asking, see [section 7](#7-using-it-from-claude-code-and-codex-mcp)), `proactiveEnabled`, `typingPauseSeconds`, `minSecondsBetweenProactiveAlerts` and `browser`.

### Delete your data

Quit the app first (menu ▸ **Quit Copilot**). Deleting is permanent.

```bash
# History and settings file (delete the whole folder, or only context.sqlite3*)
rm -rf ~/Library/Application\ Support/MyComputerAgent

# Preferences
defaults delete com.buddypia.mca

# API keys
mca auth delete gemini        # repeat for anthropic, openai-compatible, typesafe

# Permission grants
mca reset-permissions
```

You can also remove each key in Settings ▸ Models & Keys (**Remove**). To remove the wrapping record, open Keychain Access, search for `com.buddypia.mca` and delete the items. Finally delete `MyComputerAgent.app`. You can clear the chat thread at any time with **Clear Chat…**.

---

## 15. Troubleshooting

Start with `mca doctor`. It reports permissions, signing, Apple Intelligence, keys, storage and routing. When run from a terminal it describes the terminal's permissions, so also check Settings ▸ Permissions in the running app.

**I see no window and no Dock icon.** That is normal. Look for the sparkle icon in the menu bar (it can hide behind the notch or in a crowded menu bar). Opening the app again opens Settings.

**A permission is switched on but still shows red, or says "Belongs to the terminal, not this app".** The app was started from a terminal, so macOS attributes the grant to the terminal. Quit it and launch with `open build/MyComputerAgent.app`. After toggling a permission, relaunch the app.

**Permissions are asked for again after a rebuild, or the switch looks on but the permission still fails.** An ad-hoc signature changes with every build. Run `mca reset-permissions`, relaunch, grant again, or sign with a real certificate (see [Install and build](#2-install-and-build)).

**"My Computer Agent" is missing from the Screen Recording, Microphone or Audio Capture list.** It appears only after the app has asked once. Make sure the app is running and click **Ask macOS for everything** in Settings ▸ Permissions.

**System audio capture fails without any prompt (unsigned binary).** `AudioHardwareCreateProcessTap` fails on an unsigned binary and macOS shows no dialog. `mca doctor` reports "unsigned", and `mca listen` prints that the binary is unsigned. Build with `./Scripts/bundle.sh`, run the bundle, and use a real signing identity.

**Apple Intelligence is not enabled.** `mca doctor` shows "on-device gate" with one of: this Mac does not support Apple Intelligence; Apple Intelligence is turned off in System Settings; the on-device model is still downloading. Turn it on in System Settings ▸ Apple Intelligence & Siri; Settings ▸ Models & Keys ▸ **On-device** has an **Open Apple Intelligence Settings** button when the problem is fixable. Without it, triage falls back to a cloud model and running cost rises. A Mac that is not eligible cannot use the on-device gate at all.

**"No API key — the agent cannot answer anything".** Add a key in Settings ▸ Models & Keys. An environment variable only reaches the app if the app was started from that environment. If a key was added with `mca auth set`, macOS may be waiting on an "allow access?" dialog; add it in Settings instead. If your Mac was erased or the Secure Enclave was reset, stored keys are unreadable and must be entered again.

**Dictation does not start.** Check Settings ▸ General ▸ Language: the speech model for the language may be downloading (wait) or unsupported on this Mac (use Live conversation, or change **Speech Language**). Check the Microphone permission. With the Gemini Flash engine and no Gemini key, the app uses the on-device engine.

**A shortcut does nothing.** Another app probably owns that chord. Open Settings ▸ Shortcuts; a taken chord is marked. Record a different one.

**The watch stopped by itself.** Three failed looks in a row stop it (a missing API key is the common cause), as does closing a pinned window or unplugging a pinned monitor. The line under the chat thread says why.

**An app or page is never read.** It may match the exclusion list. Windows titled with `sign in` or `password`, private-browsing windows, and password managers are skipped by design. `mca capture` says "EXCLUDED by the privacy filter" when this is the cause.

**The panel ignores my clicks.** Click-through is on. Press `⌥⌘X` (the icon shows a cursor with a slash).

**`mca act` says Accessibility permission is not granted.** Grant it to the terminal you run it from (System Settings ▸ Privacy & Security ▸ Accessibility), or use `--dry-run`.

---

## 16. FAQ

**Does it work without any API key?** Yes, for recording, local search and local GUI grounding. Questions, vision, advice and Live conversation need at least a Gemini key (or another provider's key for answers).

**Does it upload my screen?** Window text and OCR stay in a local database. Text and pictures are sent to a cloud model only when you ask a question, when you use Explain, Snip or Continuous Watch, or when an item passes the on-device gate. See the table in [Privacy model](#13-privacy-model).

**Can I use it fully offline?** Recording, search, the on-device gate (with Apple Intelligence), on-device transcription (choose the macOS engine) and local GUI grounding work offline. Answers need a cloud model.

**How do I pause it?** Turn off Continuous Watch, end any voice session, or quit with **Quit Copilot**. `⌥⌘H` only hides the panel; the agent keeps watching.

**What is the difference between Dictation and Live conversation?** Dictation turns speech into text and asks the normal chat model. Live conversation streams your voice to Gemini and answers aloud. See [section 11](#11-voice-language-and-speech-settings).

**Can the agent click and type for me?** Yes, through `mca act`, the chat agent's tools and the MCP tools. It can click, type, press keys, run AppleScript and write files. Use `--dry-run` to preview, and Ctrl+C to stop an autonomous run.

**Which languages are supported?** English, 日本語 and 한국어, for the interface, speech recognition and the agent's answers. Built-in screen-watch purposes are written in Japanese.

**Does it run on Intel Macs or older macOS?** No. It requires macOS 26 or later and Apple Silicon.

**Where do I report a security problem?** Privately, as described in [SECURITY.md](../../SECURITY.md). Do not open a public issue.
