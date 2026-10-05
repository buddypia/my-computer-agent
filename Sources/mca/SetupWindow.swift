import AppKit
import Foundation
import MCACore
import SwiftUI

/// The guided permission walkthrough.
///
/// This exists because console instructions cannot work here. TCC attributes a
/// permission grant to the "responsible process", which for a terminal-launched
/// binary is the terminal — so a prompt raised from `mca doctor` grants the
/// permission to Terminal.app and the agent still has nothing. The walkthrough
/// runs inside the signed bundle so every prompt lands on the right identity,
/// and it polls live so the user sees a row flip to ✓ the moment they flick the
/// switch in System Settings.
@MainActor
final class SetupWindowController {
    private var window: NSWindow?
    private let model = SetupModel()

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 660),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = localized("My Computer Agent — Setup", "My Computer Agent — セットアップ",
            "My Computer Agent — 설정 마법사")
        window.center()
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 640)
        window.contentView = NSHostingView(rootView: SetupView(model: model))
        window.makeKeyAndOrderFront(nil)

        self.window = window
        model.start()
    }
}

@MainActor
@Observable
final class SetupModel {
    var status: Permissions.Status?
    var isRequesting = false
    var lastRefresh = Date()

    private var pollTask: Task<Void, Never>?

    func start() {
        // Idempotent: the settings window calls this every time it is shown,
        // and without the guard each reopen would leave another poll running.
        guard pollTask == nil else {
            refresh()
            return
        }
        refresh()
        // Polls rather than waiting for a notification, because macOS sends no
        // event when a privacy toggle changes. Two seconds is fast enough that
        // flipping a switch feels acknowledged.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() {
        Task {
            let fresh = await Permissions.check()
            self.status = fresh
            self.lastRefresh = Date()
        }
    }

    /// Raises every prompt macOS still allows. Each one only ever appears once
    /// per app identity; afterwards the user must use System Settings.
    func requestAll() {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            await Permissions.request()
            self.isRequesting = false
            self.refresh()
        }
    }

    func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

struct SetupView: View {
    @Bindable var model: SetupModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let status = model.status {
                    if !status.isResponsibleProcess {
                        responsibleProcessWarning
                    }
                    if !status.signing.grantsSurviveRebuild {
                        signingWarning(status.signing)
                    }

                    ForEach(Array(status.requirements.enumerated()), id: \.offset) { index, item in
                        PermissionRow(index: index + 1, requirement: item, model: model)
                    }

                    footer(status)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(localized("Permissions", "アクセス権限", "접근 권한"))
                .font(.system(size: 22, weight: .semibold))
            Text(localized("""
                macOS grants these to one specific, signed application. Each \
                row below reflects what this app can actually do right now — \
                it updates automatically when you change a switch.
                """, """
                macOS はこれらを、署名された特定の 1 つのアプリケーションに対して付与します。\
                下の各行は、このアプリが「いま実際にできること」を表しています。スイッチを\
                切り替えると自動的に更新されます。
                """,
                """
                macOS는 이 권한들을 서명된 특정 앱 하나에 부여합니다. 아래 각 행은 \
                이 앱이 ‘지금 실제로 할 수 있는 일’을 나타내며, 스위치를 바꾸면 \
                자동으로 갱신됩니다.
                """))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var responsibleProcessWarning: some View {
        CalloutBox(tint: .orange, symbol: "terminal") {
            VStack(alignment: .leading, spacing: 6) {
                Text(localized(
                    "Launched from a terminal — permissions would go to the wrong app",
                    "ターミナルから起動されています。権限が別のアプリに付与されてしまいます",
                    "터미널에서 실행됨 — 권한이 엉뚱한 앱에 부여됩니다"))
                    .font(.system(size: 12, weight: .semibold))
                Text(localized("""
                    macOS designates whichever process started this one as \
                    "responsible" and attributes every permission to it. Right \
                    now that is your terminal, so any prompt you answer grants \
                    the permission to the terminal instead.
                    """, """
                    macOS は、このプロセスを起動したプロセスを「責任のあるプロセス」と定め、\
                    すべての権限をそちらに紐づけます。いまそれはあなたのターミナルなので、\
                    ダイアログに許可と答えても権限はターミナルに付与されます。
                    """,
                    """
                    macOS는 이 프로세스를 실행한 프로세스를 ‘책임 프로세스’로 정하고 \
                    모든 권한을 그쪽에 연결합니다. 지금은 그것이 사용자의 터미널이므로, \
                    대화상자에서 허용을 눌러도 권한은 터미널에 부여됩니다.
                    """))
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Button(localized("Relaunch as an app", "アプリとして起動し直す", "앱으로 다시 실행")) { model.relaunch() }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
    }

    private func signingWarning(_ signing: Permissions.SigningStatus) -> some View {
        CalloutBox(tint: .red, symbol: "signature") {
            VStack(alignment: .leading, spacing: 6) {
                Text(signing.isSigned
                     ? localized(
                        "Ad-hoc signed — permissions will not survive a rebuild",
                        "アドホック署名です。再ビルドすると権限が失われます",
                        "애드혹 서명 — 다시 빌드하면 권한이 사라집니다")
                     : localized(
                        "Unsigned — macOS will not prompt at all",
                        "未署名です。macOS はダイアログを一切出しません",
                        "서명 없음 — macOS가 대화상자를 전혀 띄우지 않습니다"))
                    .font(.system(size: 12, weight: .semibold))
                Text(localized("""
                    macOS stores a code-signing requirement next to each grant. \
                    For an ad-hoc signature that requirement is the binary's \
                    hash, which changes every build — so the grant stops \
                    matching and the app can vanish from the Privacy list.
                    """, """
                    macOS は付与した権限ごとにコード署名の要件を保存します。アドホック署名では\
                    その要件がバイナリのハッシュになり、ビルドのたびに変わります。そのため権限が\
                    一致しなくなり、プライバシーの一覧からアプリごと消えることがあります。
                    """,
                    """
                    macOS는 부여한 권한마다 코드 서명 요건을 함께 저장합니다. 애드혹 서명에서는 \
                    그 요건이 바이너리 해시가 되어 빌드할 때마다 달라집니다. 그래서 권한이 \
                    더 이상 일치하지 않고, 개인정보 보호 목록에서 앱이 사라지기도 합니다.
                    """))
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Text(signing.designatedRequirement)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private func footer(_ status: Permissions.Status) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 10) {
                Button {
                    model.requestAll()
                } label: {
                    Label(
                        model.isRequesting
                            ? localized("Requesting…", "要求中…", "요청 중…")
                            : localized("Ask macOS for everything", "macOS にすべて要求する",
                                "macOS에 전부 요청하기"),
                        systemImage: "hand.raised")
                }
                .disabled(model.isRequesting || status.allGranted)

                Button(localized("Recheck now", "いま再確認する", "지금 다시 확인")) { model.refresh() }

                Spacer()

                if status.allGranted {
                    Label(
                        localized("All set", "すべて設定済み", "모두 완료"),
                        systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            Text(localized("""
                A prompt only ever appears once per app. If a switch is missing \
                from System Settings, the app has not asked yet — press \
                “Ask macOS for everything”, then reopen the pane.
                """, """
                ダイアログはアプリごとに一度しか出ません。システム設定にスイッチが見当たらない\
                場合、そのアプリはまだ要求していません。「macOS にすべて要求する」を押してから\
                設定パネルを開き直してください。
                """,
                """
                대화상자는 앱당 한 번만 나타납니다. 시스템 설정에 스위치가 보이지 않는다면 \
                그 앱은 아직 요청하지 않은 것입니다. ‘macOS에 전부 요청하기’를 누른 뒤 \
                설정 패널을 다시 열어 보세요.
                """))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One permission, with a picture of where its switch lives.
struct PermissionRow: View {
    let index: Int
    let requirement: PermissionRequirement
    @Bindable var model: SetupModel

    private var tint: Color {
        switch requirement.state {
        case .granted: return .green
        case .notGranted: return .red
        case .inheritedFromParent: return .orange
        case .unknown: return .secondary
        }
    }

    private var stateLabel: String {
        switch requirement.state {
        case .granted: return localized("Granted", "許可済み", "허용됨")
        case .notGranted: return localized("Not granted", "未許可", "허용되지 않음")
        case .inheritedFromParent:
            return localized(
                "Belongs to the terminal, not this app",
                "このアプリではなくターミナルに付与されています",
                "이 앱이 아니라 터미널에 부여되어 있습니다")
        case .unknown: return localized("Unknown", "不明", "알 수 없음")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index).")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(requirement.localizedTitle)
                    .font(.system(size: 14, weight: .semibold))

                Label(stateLabel, systemImage: requirement.state == .granted
                      ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)

                Spacer()

                Button(localized("Open Settings", "設定を開く", "설정 열기")) {
                    model.open(requirement.settingsURL)
                }
                .controlSize(.small)
            }

            Text(requirement.localizedConsequence)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            SettingsPaneDiagram(
                paneName: requirement.localizedListName,
                highlighted: requirement.state != .granted)

            if requirement.appearsOnlyAfterRequest && requirement.state != .granted {
                Text(localized("""
                    “My Computer Agent” only appears in this list after the app \
                    has asked for it once. If you do not see it, keep the app \
                    running and reopen the pane.
                    """, """
                    「My Computer Agent」は、アプリが一度要求したあとでなければこの一覧に\
                    現れません。見当たらない場合はアプリを起動したまま、設定パネルを開き直して\
                    ください。
                    """,
                    """
                    ‘My Computer Agent’는 앱이 한 번 요청한 뒤에야 이 목록에 나타납니다. \
                    보이지 않는다면 앱을 실행해 둔 채로 설정 패널을 다시 열어 보세요.
                    """))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 10)
        }
    }
}

/// A drawn likeness of the System Settings pane the user is being sent to.
///
/// Drawn rather than screenshotted on purpose: a bundled screenshot goes stale
/// with the next macOS redesign and cannot show the user's own app name in the
/// row, which is exactly the thing they are hunting for.
struct SettingsPaneDiagram: View {
    let paneName: String
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack(spacing: 5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.8)).frame(width: 7, height: 7)
                }
                Text(paneName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.black.opacity(0.18))

            // Rows
            VStack(spacing: 0) {
                appRow(
                    name: localized("Some other app", "別のアプリ", "다른 앱"),
                    on: true, emphasised: false)
                Divider().opacity(0.3)
                appRow(name: "My Computer Agent", on: !highlighted, emphasised: true)
                Divider().opacity(0.3)
                appRow(
                    name: localized("Another app", "さらに別のアプリ", "또 다른 앱"),
                    on: false, emphasised: false)
            }
            .padding(.vertical, 3)
            .background(.black.opacity(0.10))
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .frame(maxWidth: 420)
    }

    private func appRow(name: String, on: Bool, emphasised: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(emphasised ? Color.accentColor.opacity(0.8) : .secondary.opacity(0.35))
                .frame(width: 13, height: 13)

            Text(name)
                .font(.system(size: 10, weight: emphasised ? .semibold : .regular))
                .foregroundStyle(emphasised ? .primary : .secondary)

            Spacer()

            // A toggle drawn at the size and shape of the real one, so the
            // target is recognisable at a glance.
            Capsule()
                .fill(on ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 26, height: 15)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .padding(1.5)
                }
                .overlay {
                    if emphasised && !on {
                        Capsule()
                            .strokeBorder(Color.orange, lineWidth: 1.5)
                            .frame(width: 30, height: 19)
                    }
                }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(emphasised ? Color.accentColor.opacity(0.10) : .clear)
    }
}

struct CalloutBox<Content: View>: View {
    let tint: Color
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 18)
            content
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(tint.opacity(0.35), lineWidth: 1)
        }
    }
}
