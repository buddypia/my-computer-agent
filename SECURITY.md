[English](SECURITY.md) • [日本語](SECURITY.ja.md) • [한국어](SECURITY.ko.md)

# Security and Privacy Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |

---

## Reporting Security Vulnerabilities

We take the security and privacy of **MyComputerAgent (MCA)** very seriously. If you believe you have discovered a security vulnerability or privacy flaw, please report it promptly.

### How to Report
- Please report vulnerabilities privately via **GitHub Private Vulnerability Reporting** (repository **Security** tab ▸ **Report a vulnerability**).
- Please include:
  - A description of the vulnerability and its potential impact.
  - Step-by-step reproduction instructions or proof-of-concept.
  - Environment details (macOS version, hardware model, app version).

Please **do not** report security vulnerabilities via public GitHub issues, discussions, or pull requests until they have been reviewed and addressed.

We acknowledge receipt of reports within 48 hours and provide estimated remediation timelines.

---

## Security and Privacy Architecture

`MyComputerAgent` is designed from the ground up as a **local-first, privacy-preserving desktop copilot**. It incorporates defense-in-depth architectural safeguards to protect user privacy and credentials:

### 1. Hardware-Backed Encrypted Key Storage (`SecretStore`)
- **Secure Enclave Binding**: Provider API keys entered in Settings are sealed using **HPKE (RFC 9180, `P256_SHA256_AES_GCM_256`)** against a P-256 key generated inside the Apple Silicon **Secure Enclave Processor (SEP)** (a software key is used, and flagged in Settings, on Macs without a Secure Enclave).
- **What this does and does not protect**: The wrapping key is non-exportable and device-bound (`ThisDeviceOnly`), so a copied keychain file, login-keychain backup, or the stored ciphertext cannot be decrypted on another device. It is **not** a defense against software running as the same user on the same Mac: the key is deliberately created without `userPresence` (no Touch ID prompt, so the agent can run in the background), and the keychain item is not bound to the app's code signature. A process that your user session allows to read the keychain item and use the Secure Enclave key may be able to unseal the API keys.
- **No Plaintext on Disk**: Plaintext credentials are never written to disk, SQLite databases, or unencrypted keychain items.
- **Provider Authentication Binding**: The vendor name (`gemini`, `anthropic`, `openai-compatible`, `typesafe`) is bound as **Authenticated Additional Data (AAD)**. A ciphertext record cannot be moved across providers.
- **Volatile Environment Precedence**: `GEMINI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and `TYPESAFE_API_KEY` can be provided via ephemeral environment variables for development, taking runtime precedence without persisting to storage.

### 2. Zero-Trust Pre-Capture & In-Flight Privacy Filtering (`PrivacyFilter`)
- **Credential Managers Excluded**: Windows belonging to password managers (including `1Password`, `Bitwarden`, `Apple Keychain Access`, `LastPass`, and `KeePassXC`) are strictly blocked from window capture and accessibility inspection.
- **Secure Text Fields Dropped**: UI elements marked as `AXSecureTextField` (password and secret input fields) are automatically pruned from candidate trees before model evaluation.
- **PII & Token Redaction**: In-flight UI labels and captured values pass through regex sanitizers to mask API keys, bearer tokens, authorization headers, and credit card numbers before any data reaches reasoning models.
- **Self-Inspection Exclusion**: The agent automatically identifies its own process identifier (PID) and refuses to inspect its own windows, preventing recursion or accidental reflection of assistant responses.

### 3. Local-First & User-Controlled Sensing
- **Microphone Off at Launch**: The microphone is never open at startup. It opens only during explicit voice sessions (e.g. ⌃⌥V) and immediately closes upon session termination.
- **Dual Independent Audio Channels**: Microphone input (hardware AEC) and system audio (CoreAudio process tap) are processed in isolated audio pipelines without third-party virtual audio drivers.
- **On-Device Speech & Vision**: On-device speech recognition (`SpeechAnalyzer`) and Vision OCR ensure audio and screen text remain entirely local on the Mac when on the Apple engine.
- **Audio Is Sent to Google When the Gemini Engine Is Used**: The default transcription engine is Gemini (cloud). With it, and in live voice sessions (`GeminiLiveSession`), captured microphone/system audio is streamed to Google Gemini for transcription. Select the Apple engine in Settings to keep audio on the Mac. Screenshots and recognized screen text are likewise sent to your configured model provider when you ask the agent about your screen.
- **Screen Watch Off at Launch**: Background screen observation is inactive on application launch and must be explicitly enabled per session.

### 4. IPC & Network Boundaries
- **Stdio-Only MCP Server**: The Model Context Protocol (MCP) server runs over standard I/O (stdio) for local agent communication (Claude Code, Codex CLI, etc.). It does not open unauthenticated listening TCP ports or web sockets on the local network.
- **Parameterized Database Queries**: Context memory is stored in an on-device SQLite database (`~/Library/Application Support/MyComputerAgent/context.sqlite3`) with WAL mode. All full-text search (FTS5) and vector metadata queries utilize strict parameterized bindings (`sqlite3_bind_*`), preventing injection attacks.
- **Encrypted Model Transport**: All cloud model interactions strictly enforce TLS/HTTPS and authenticated WebSockets (WSS).

### 5. Confirmation Before Dangerous Actions (`ToolApproving`)
- **Untrusted Content Is Data**: Text from the screen, OCR, accessibility labels, web pages and tool results is treated by the system prompts as untrusted data, never as instructions, because it can carry indirect prompt injection.
- **Approval Gate**: `run_applescript`, `write_file`, `open_file` and `browser_evaluate`, and `browser_read` when given a `path` (a screenshot written where the model chooses), pass a `ToolApproving` gate that shows the literal script, JavaScript, path or content. The app asks in a modal alert (default button: *Don't Allow*); `mca ask` asks y/N on a terminal and refuses when there is none. A tool with no approver wired refuses.
- **Keystrokes**: Typing into the app in front is how injected text becomes a command (`curl … | sh` and Return in a terminal), and which apps are terminals cannot be listed reliably, so the gate is per keystroke rather than per app. Text typed by `computer` (`type`), `typesafe_act`, `mca act` and the in-app autonomous loop, and every key press except a bare Escape, Tab, Left/Right, Home/End or Page Up/Down, is shown literally and approved first; line breaks are counted in the prompt, since each one presses Return. Up and Down are confirmed too, because in a terminal they recall history that a later Return would run. A refusal ends an autonomous run. The prompt also names the app in front and, after the alert closes, focus is given back to it; both are best effort, since focus can still move before the keys are sent — what the user approves is the text. Not confirmed: pointer actions (`click_element`, clicks, drags, scrolling), which cannot enter text but can press buttons already on screen, and the browser tools' keystrokes when they go through DevTools to the agent's own tab. When the browser tools fall back to Accessibility, which types into the real browser window, `browser_act` asks before `type`, `fill` and `press`.
- **File Write Policy**: `write_file` refuses shell startup files, dotfiles in the home folder, LaunchAgents/LaunchDaemons, system directories, any path inside a `.git` folder and the app's own configuration/data directory (`config.json`, the context database) outright (symlinks are resolved first), and flags paths outside the home folder in the prompt.
- **MCP Default-Deny**: A stdio MCP server has no UI to ask in, so `run_applescript`, `computer`, `click_element`, `typesafe_act`, live `autonomous_act`, the browser tools that act on a page (`browser_navigate`, `browser_element`, `browser_act`, and `browser_tabs` when it opens, switches or closes a tab) `browser_read` when given a `path`, and the browser tool that evaluates JavaScript are refused unless `"mcpAllowDangerousTools": true` is set in `config.json`.
- **Advice Cards**: A card's one-click action shows its payload, asks for confirmation, and presses Return only when the user picks that option. The app name and payload are escaped before they reach AppleScript.
