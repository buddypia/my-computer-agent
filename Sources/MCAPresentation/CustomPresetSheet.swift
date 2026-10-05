import MCACore
import SwiftUI

/// Modal sheet to create or edit a custom prompt preset / role.
public struct CustomPresetSheet: View {
    public var role: WatchRole?
    public var onSave: (WatchRole) -> Void
    public var onDismiss: () -> Void

    @State private var name: String = ""
    @State private var icon: String = "sparkles"
    @State private var taskPrompt: String = ""
    @State private var systemPrompt: String = ""

    private let availableIcons = [
        "sparkles", "exclamationmark.triangle.fill", "doc.text.magnifyingglass",
        "checklist", "curlybraces", "ruler.fill", "terminal.fill",
        "person.wave.2.fill", "lightbulb.fill", "bolt.fill", "magnifyingglass",
        "arrow.triangle.2.circlepath", "wrench.and.screwdriver.fill"
    ]

    public init(
        role: WatchRole? = nil,
        onSave: @escaping (WatchRole) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.role = role
        self.onSave = onSave
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(role == nil
                ? localized("Create Custom Prompt Preset", "カスタムプロンプト・プリセット作成", "사용자 지정 프리셋 생성")
                : localized("Edit Prompt Preset", "プロンプト・プリセット編集", "프리셋 편집"))
                .font(.headline)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("Preset Name", "プリセット名", "프리셋 이름"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(localized("e.g. Code Review, Translation", "例: コードレビュー, 翻訳＆要約", "예: 코드 리뷰, 번역 및 요약"), text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("Icon", "アイコン", "아이콘"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Menu {
                        ForEach(availableIcons, id: \.self) { sym in
                            Button {
                                icon = sym
                            } label: {
                                Label(sym, systemImage: sym)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: icon)
                                .font(.system(size: 13))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(localized("Execution Prompt (Task Prompt)", "実行プロンプト (即座に遂行する指示)", "실행 프롬프트 (즉시 수행 지시)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(localized("Sent when clicking the preset", "プリセット選択時に送信されます", "프리셋 클릭 시 전송됨"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                TextEditor(text: $taskPrompt)
                    .font(.system(size: 11))
                    .frame(height: 100)
                    .padding(4)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(localized("Continuous Watch Instructions (System Prompt)", "常時監視時のシステム指示 (任意)", "상시 감시 시스템 지시 (선택)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(localized("Used when set as watch objective", "監視設定時に使用されます", "감시 설정 시 사용됨"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                TextEditor(text: $systemPrompt)
                    .font(.system(size: 11))
                    .frame(height: 70)
                    .padding(4)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    }
            }

            HStack {
                Button(localized("Cancel", "キャンセル", "취소")) {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(localized("Save Preset", "プリセットを保存", "프리셋 저장")) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || taskPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let role {
                name = role.name
                icon = role.icon
                taskPrompt = role.taskPrompt ?? role.systemPrompt
                systemPrompt = role.systemPrompt
            } else {
                taskPrompt = localized(
                    "Analyze the content on this screen and provide concrete advice.",
                    "この画面に表示されている内容を分析し、具体的な改善点やアドバイスを提示してください。",
                    "이 화면에 표시된 내용을 분석하고 구체적인 조언을 제시해 주세요."
                )
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedTask = taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        let targetId = role?.id ?? "custom.\(UUID().uuidString.prefix(8))"
        let effectiveSystem = trimmedSystem.isEmpty ? trimmedTask : trimmedSystem

        let newRole = WatchRole(
            id: targetId,
            name: trimmedName,
            icon: icon,
            systemPrompt: effectiveSystem,
            taskPrompt: trimmedTask,
            triggerKind: role?.triggerKind ?? .screenDiff,
            defaultInterval: role?.defaultInterval ?? 30,
            isBuiltin: false
        )
        onSave(newRole)
        onDismiss()
    }
}
