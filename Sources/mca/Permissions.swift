import AVFoundation
import AppKit
import Foundation
import MCACore
import MCASensing

/// One thing the agent needs macOS to let it do.
struct PermissionRequirement {
    enum State {
        case granted
        case notGranted
        /// Granted, but to the *parent* process rather than to this app. See
        /// `Permissions.isResponsibleProcess`.
        case inheritedFromParent
        case unknown

        var symbol: String {
            switch self {
            case .granted: return "✓"
            case .notGranted: return "✗"
            case .inheritedFromParent: return "~"
            case .unknown: return "?"
            }
        }
    }

    /// Every user-facing string here exists twice, because it has two
    /// audiences: `mca doctor` prints the English one to a terminal, and the
    /// setup window draws whichever one the user picked.
    typealias Text = LocalizedText

    var id: ComponentID
    var title: Text
    /// What breaks without it, in the user's terms.
    var consequence: Text
    /// Deep link that opens the exact System Settings pane.
    var settingsURL: String
    /// Where the app appears once macOS knows about it.
    var listName: Text
    var state: State
    /// Whether the app must be running for macOS to list it.
    var appearsOnlyAfterRequest: Bool

    @MainActor var localizedTitle: String { localized(title) }
    @MainActor var localizedConsequence: String { localized(consequence) }
    @MainActor var localizedListName: String { localized(listName) }
}

enum Permissions {
    struct Status {
        var requirements: [PermissionRequirement]
        /// False when this process is running under a parent that owns the
        /// TCC grants — i.e. launched from a terminal.
        var isResponsibleProcess: Bool
        var signing: SigningStatus

        var allGranted: Bool {
            requirements.allSatisfy { $0.state == .granted }
        }
    }

    struct SigningStatus {
        var isSigned: Bool
        var isAdHoc: Bool
        var designatedRequirement: String
        var identity: String?

        /// Ad-hoc grants are pinned to the binary hash and die on rebuild.
        var grantsSurviveRebuild: Bool { isSigned && !isAdHoc }
    }

    /// Whether TCC will attribute permissions to this app rather than to
    /// whatever launched it.
    ///
    /// This matters far more than it sounds. When the binary is started from a
    /// terminal, macOS designates the *terminal* as the responsible process,
    /// so `AVCaptureDevice.authorizationStatus` reports the terminal's grants.
    /// A diagnostic that ignores this reports a cheerful ✓ while the app itself
    /// has no permission at all and never appears in System Settings.
    static var isResponsibleProcess: Bool {
        // Launched by launchd (`open`, Finder, a login item) → PPID 1 and the
        // app owns its own TCC identity. Launched from a shell → the shell is
        // an ancestor and owns it.
        getppid() == 1
    }

    static func check() async -> Status {
        let responsible = isResponsibleProcess

        func resolve(_ granted: Bool) -> PermissionRequirement.State {
            switch (granted, responsible) {
            case (true, true): return .granted
            // Granted, but the reading came from the parent process — so it
            // says nothing about this app.
            case (true, false): return .inheritedFromParent
            case (false, _): return .notGranted
            }
        }

        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let screenGranted = await ScreenCapturer.hasPermission()
        let axGranted = AccessibilityReader.isTrusted
        let tapGranted = probeSystemAudio() ?? false

        return Status(
            requirements: [
                PermissionRequirement(
                    id: .accessibility,
                    title: ("Accessibility", "アクセシビリティ", "손쉬운 사용"),
                    consequence: (
                        "Cannot read text from other apps — the agent sees nothing.",
                        "他のアプリからテキストを読めません。エージェントは何も見えません。",
                        "다른 앱에서 텍스트를 읽을 수 없습니다. 에이전트는 아무것도 못 봅니다."),
                    settingsURL:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                    listName: (
                        "Privacy & Security ▸ Accessibility",
                        "プライバシーとセキュリティ ▸ アクセシビリティ",
                        "개인정보 보호 및 보안 ▸ 손쉬운 사용"),
                    state: resolve(axGranted),
                    appearsOnlyAfterRequest: false),
                PermissionRequirement(
                    id: .screenCapture,
                    title: ("Screen Recording", "画面収録", "화면 기록"),
                    consequence: (
                        "No OCR fallback for apps that expose no accessibility tree.",
                        "アクセシビリティ情報を公開しないアプリで OCR による代替が効きません。",
                        "손쉬운 사용 정보를 제공하지 않는 앱에서 OCR 대체가 동작하지 않습니다."),
                    settingsURL:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                    listName: (
                        "Privacy & Security ▸ Screen & System Audio Recording",
                        "プライバシーとセキュリティ ▸ 画面とシステムオーディオの収録",
                        "개인정보 보호 및 보안 ▸ 화면 및 시스템 오디오 기록"),
                    state: resolve(screenGranted),
                    appearsOnlyAfterRequest: true),
                PermissionRequirement(
                    id: .microphone,
                    title: ("Microphone", "マイク", "마이크"),
                    consequence: (
                        "Cannot hear you — only the other side of a call is transcribed.",
                        "あなたの声を拾えません。通話相手側しか文字起こしされません。",
                        "사용자의 목소리를 듣지 못합니다. 통화 상대 쪽만 문자로 변환됩니다."),
                    settingsURL:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                    listName: (
                        "Privacy & Security ▸ Microphone",
                        "プライバシーとセキュリティ ▸ マイク",
                        "개인정보 보호 및 보안 ▸ 마이크"),
                    state: resolve(micGranted),
                    appearsOnlyAfterRequest: true),
                PermissionRequirement(
                    id: .systemAudioTap,
                    title: ("Audio Capture", "オーディオ収録", "오디오 기록"),
                    consequence: (
                        "Cannot hear meeting participants.",
                        "会議の参加者の音声を拾えません。",
                        "회의 참가자의 음성을 듣지 못합니다."),
                    settingsURL:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                    listName: (
                        "Privacy & Security ▸ Screen & System Audio Recording",
                        "プライバシーとセキュリティ ▸ 画面とシステムオーディオの収録",
                        "개인정보 보호 및 보안 ▸ 화면 및 시스템 오디오 기록"),
                    state: resolve(tapGranted),
                    appearsOnlyAfterRequest: true),
            ],
            isResponsibleProcess: responsible,
            signing: signingStatus())
    }

    /// Requests everything that can be requested programmatically.
    ///
    /// Only meaningful from the app bundle. Called from a shell, every prompt
    /// is attributed to the shell instead.
    static func request() async {
        AccessibilityReader.requestTrust()

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        // Screen recording and audio capture have no request API; touching the
        // relevant API is what raises the prompt and, crucially, what makes the
        // app appear in System Settings at all.
        _ = await ScreenCapturer.hasPermission()
        _ = probeSystemAudio()
    }

    /// Attempts to create and immediately destroy a process tap.
    ///
    /// There is no query API for audio-capture permission, so the only way to
    /// learn the answer is to try.
    private static func probeSystemAudio() -> Bool? {
        let tap = SystemAudioTap()
        do {
            try tap.start()
            try? tap.stop()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Signing

    static func signingStatus() -> SigningStatus {
        let path = Bundle.main.bundlePath

        func run(_ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(data: data, encoding: .utf8) ?? ""
            } catch {
                return ""
            }
        }

        let info = run(["-dv", "--verbose=4", path])
        let isSigned = info.contains("Signature") || info.contains("CodeDirectory")
        let isAdHoc = info.contains("adhoc")

        let requirement = run(["-dr", "-", path])
            .split(separator: "\n")
            .first { $0.hasPrefix("designated") }
            .map(String.init) ?? "unknown"

        let identity = info
            .split(separator: "\n")
            .first { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) }

        return SigningStatus(
            isSigned: isSigned,
            isAdHoc: isAdHoc,
            designatedRequirement: requirement,
            identity: identity)
    }

    // MARK: - Reporting

    static func describe(_ status: Status) -> String {
        var lines: [String] = []

        if !status.isResponsibleProcess {
            lines.append("""
                ⚠️  Running under a terminal, so these results describe the
                    TERMINAL's permissions, not this app's.

                    macOS designates the launching process as "responsible" and
                    attributes every TCC grant to it. A ✓ below may simply mean
                    your terminal has the permission.

                    For a true reading:  open \(Bundle.main.bundlePath)
                    then check the panel, or run:  mca setup

                """)
        }

        lines.append("Permissions")
        for requirement in status.requirements {
            lines.append("  \(requirement.state.symbol) \(requirement.title.english.padded(to: 18))"
                + "— \(requirement.consequence.english)")
        }

        lines.append("")
        lines.append("Code signing")
        if !status.signing.isSigned {
            lines.append("  ✗ unsigned — macOS will not prompt for audio capture at all")
        } else if status.signing.isAdHoc {
            lines.append("  ⚠ ad-hoc — permissions are pinned to the binary hash")
            lines.append("      \(status.signing.designatedRequirement)")
            lines.append("""
                      Every rebuild produces a new hash, so macOS treats it as a
                      different app: grants stop matching and the entry can drop
                      out of System Settings. Sign with a real certificate, or
                      run `mca reset-permissions` after each build.
                """)
        } else {
            lines.append("  ✓ \(status.signing.identity ?? "signed")")
            lines.append("      \(status.signing.designatedRequirement)")
            lines.append("      Identity-based requirement — grants survive rebuilds.")
        }

        return lines.joined(separator: "\n")
    }

    /// Step-by-step instructions for whatever is still missing.
    static func instructions(_ status: Status) -> String {
        let missing = status.requirements.filter { $0.state != .granted }
        guard !missing.isEmpty else {
            return "All permissions granted. Nothing to do."
        }

        var lines = ["To grant the remaining permissions:", ""]

        if !status.isResponsibleProcess {
            lines.append("""
                0. Launch the app itself first — permissions cannot be granted
                   to it while it only runs as a child of your terminal:

                       open \(Bundle.main.bundlePath)

                """)
        }

        for (index, requirement) in missing.enumerated() {
            lines.append("\(index + 1). \(requirement.title.english)")
            lines.append("   Where:  \(requirement.listName.english)")
            if requirement.appearsOnlyAfterRequest {
                lines.append("""
                       Note:   \"My Computer Agent\" only appears in this list
                               after the app has asked once. If it is missing,
                               make sure the app is running, then reopen the pane.
                    """)
            }
            lines.append("   Open:   open \"\(requirement.settingsURL)\"")
            lines.append("   Why:    \(requirement.consequence.english)")
            lines.append("")
        }

        lines.append("""
            After toggling a permission, macOS requires the app to relaunch:

                pkill -f MyComputerAgent && open \(Bundle.main.bundlePath)
            """)

        return lines.joined(separator: "\n")
    }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
