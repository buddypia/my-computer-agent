import AppKit
import MCACore
import SwiftUI

/// A quick-action preset bar that allows users to select pre-configured or custom prompt
/// presets for the pinned screen (or active screen), executing them on demand with one click
/// or applying them as the active continuous watch objective.
public struct PresetBarView: View {
    @Bindable var state: HUDState

    var onExecutePreset: ((WatchRole, WatchTarget?) -> Void)?
    var onApplyRoleToWatch: ((WatchRole, WatchTarget?) -> Void)?
    var onChooseScreen: (() -> Void)?

    @State private var editingPreset: WatchRole? = nil
    @State private var showingCreateSheet = false

    public init(
        state: HUDState,
        onExecutePreset: ((WatchRole, WatchTarget?) -> Void)? = nil,
        onApplyRoleToWatch: ((WatchRole, WatchTarget?) -> Void)? = nil,
        onChooseScreen: (() -> Void)? = nil
    ) {
        self.state = state
        self.onExecutePreset = onExecutePreset
        self.onApplyRoleToWatch = onApplyRoleToWatch
        self.onChooseScreen = onChooseScreen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            targetHeader

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(state.availableRoles) { role in
                        presetChip(role)
                    }

                    addPresetButton
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .sheet(item: $editingPreset) { role in
            CustomPresetSheet(
                role: role,
                onSave: { updated in
                    state.addCustomRole(updated)
                },
                onDismiss: {
                    editingPreset = nil
                }
            )
        }
        .sheet(isPresented: $showingCreateSheet) {
            CustomPresetSheet(
                role: nil,
                onSave: { created in
                    state.addCustomRole(created)
                },
                onDismiss: {
                    showingCreateSheet = false
                }
            )
        }
    }

    // MARK: - Target Header

    private var targetHeader: some View {
        HStack(spacing: 6) {
            Button {
                onChooseScreen?()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: targetIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isPinned ? Color.mint : Color.secondary)
                    Text(targetTitle)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    isPinned ? Color.mint.opacity(0.16) : Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 5)
                )
            }
            .buttonStyle(.plain)
            .help(localized(
                "Click to change the target screen or window",
                "クリックして対象画面・ウインドウを変更",
                "클릭하여 대상 화면 또는 윈도우 변경"
            ))

            Spacer(minLength: 4)

            Text(localized("Quick Presets:", "プリセット選択で遂行:", "프리셋 실행:"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var isPinned: Bool {
        state.watchTarget.isPinned || !state.watchItems.isEmpty
    }

    private var targetIcon: String {
        if !state.watchItems.isEmpty {
            return "rectangle.split.2x1.fill"
        }
        switch state.watchTarget {
        case .focused:
            return "macwindow"
        case .pinned:
            return "pin.fill"
        case .display:
            return "display"
        }
    }

    private var targetTitle: String {
        if !state.watchItems.isEmpty {
            let count = state.watchItems.filter(\.isEnabled).count
            return localized("\(count) screens watched", "\(count) 画面を監視中", "\(count)개 화면 감시 중")
        }
        if let subject = state.watchTarget.subjectName {
            return subject
        }
        return localized("Focused Window", "前面のウインドウ", "앞쪽 윈도우")
    }

    // MARK: - Preset Chip

    private func presetChip(_ role: WatchRole) -> some View {
        let isSelected = state.selectedPreset?.id == role.id

        return HStack(spacing: 0) {
            Button {
                execute(role)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: role.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Color.white : Color.accentColor)

                    Text(role.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .help(localized(
                "\(role.effectiveTaskPrompt)\n\nClick to execute once on target (one-shot).",
                "\(role.effectiveTaskPrompt)\n\nクリックで対象画面に1回実行（一発）。",
                "\(role.effectiveTaskPrompt)\n\n클릭하여 대상 화면에 1회 실행 (단발)."
            ))

            Menu {
                Button {
                    execute(role)
                } label: {
                    Label(
                        localized("Execute Once (One-shot)", "今すぐ1回実行（一発）", "지금 1회 실행 (단발)"),
                        systemImage: "play.fill"
                    )
                }

                Button {
                    applyToWatch(role)
                } label: {
                    Label(
                        localized("Set as Continuous Watch Objective", "この目的で継続見守りに設定", "이 목적으로 지속 지켜보기 설정"),
                        systemImage: "eye.fill"
                    )
                }

                if !role.isBuiltin {
                    Divider()
                    Button {
                        editingPreset = role
                    } label: {
                        Label(localized("Edit Preset…", "プリセットを編集…", "프리셋 편집…"), systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        state.deleteCustomRole(id: role.id)
                    } label: {
                        Label(localized("Delete Preset", "プリセットを削除", "프리셋 삭제"), systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .padding(.trailing, 6)
                    .padding(.leading, 2)
                    .padding(.vertical, 4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            isSelected ? Color.accentColor : Color.secondary.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .disabled(state.isStreaming)
        .contextMenu {
            Button {
                execute(role)
            } label: {
                Label(
                    localized("Execute Once (One-shot)", "今すぐ1回実行（一発）", "지금 1회 실행 (단발)"),
                    systemImage: "play.fill"
                )
            }

            Button {
                applyToWatch(role)
            } label: {
                Label(
                    localized("Set as Continuous Watch Objective", "この目的で継続見守りに設定", "이 목적으로 지속 지켜보기 설정"),
                    systemImage: "eye.fill"
                )
            }

            if !role.isBuiltin {
                Divider()
                Button {
                    editingPreset = role
                } label: {
                    Label(localized("Edit Preset…", "プリセットを編集…", "프리셋 편집…"), systemImage: "pencil")
                }

                Button(role: .destructive) {
                    state.deleteCustomRole(id: role.id)
                } label: {
                    Label(localized("Delete Preset", "プリセットを削除", "프리셋 삭제"), systemImage: "trash")
                }
            }
        }
    }

    private var addPresetButton: some View {
        Button {
            showingCreateSheet = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text(localized("Custom…", "カスタム…", "사용자 지정…"))
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .foregroundStyle(.secondary)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(localized("Create a new custom prompt preset", "新しいカスタムプロンプト・プリセットを作成", "새 사용자 지정 프롬프트 프리셋 생성"))
    }

    // MARK: - Actions

    private func execute(_ role: WatchRole) {
        state.selectedPreset = role
        if let onExecutePreset {
            onExecutePreset(role, state.watchTarget)
        } else {
            state.onExecutePreset?(role, state.watchTarget)
        }
    }

    private func applyToWatch(_ role: WatchRole) {
        state.selectedPreset = role
        if let onApplyRoleToWatch {
            onApplyRoleToWatch(role, state.watchTarget)
        } else {
            state.onApplyRoleToWatch?(role, state.watchTarget)
        }
    }
}
