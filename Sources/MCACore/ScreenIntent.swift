import Foundation

/// Detects whether a user question is asking about the current screen or desktop state.
///
/// Kept pure in `MCACore` so the presentation layer, the reasoning layer, and the
/// composition root can all classify intent without depending on sensing or models.
public enum ScreenIntent: Sendable {
    /// Case-insensitive keyword markers in English, Japanese, and Korean indicating
    /// that the user's prompt is inquiring about visual or UI elements on screen.
    private static let japaneseKeywords: [String] = [
        "画面", "がめん", "ガメン", "ディスプレイ", "ウインドウ", "ウィンドウ",
        "映って", "見えて", "見て", "いまの表示", "今の表示", "現在の表示",
        "デスクトップ", "スクショ", "キャプチャ", "このエラー", "何が起きてる",
        "ここ見て", "これ見て", "何が映っ", "何が見え", "ダイアログ", "エラーメッセージ"
    ]

    private static let englishKeywords: [String] = [
        "screen", "display", "window", "seeing", "see here", "look at",
        "what's on", "what is on", "on my screen", "what am i looking",
        "what do you see", "desktop", "this error", "screenshot", "capture",
        "current view", "my screen", "dialog", "popup", "error message"
    ]

    private static let koreanKeywords: [String] = [
        "화면", "디스플레이", "윈도우", "보이는", "보고", "이 창",
        "이 에러", "데스크톱", "캡처", "스크린샷", "무엇이 보여", "다이얼로그", "팝업", "에러 메시지"
    ]

    /// Keywords indicating an informational request (question, summary, explanation, data extraction).
    private static let japaneseInformationalKeywords: [String] = [
        "教えて", "おしえて", "教えてください", "教えろ", "教えてほしい", "教えて欲しい",
        "まとめて", "まとめ", "要約", "概要", "集計", "集約",
        "リスト", "一覧", "抽出", "何？", "何?", "なに？", "なに?",
        "どうなってる", "どうなっている", "何がある", "何が起きてる",
        "説明して", "解説して", "報告して", "確認して教えて", "見せて"
    ]

    private static let englishInformationalKeywords: [String] = [
        "tell me", "show me", "explain", "summarize", "summary", "list",
        "what is", "what are", "what's", "which", "how many", "how much",
        "who", "why", "where", "find and tell", "collect and tell",
        "extract", "report"
    ]

    private static let koreanInformationalKeywords: [String] = [
        "알려줘", "알려주세요", "알려", "정리해", "요약해", "정리해줘", "요약해줘",
        "무엇", "어떤", "어떻게", "리스트", "추출해", "찾아서 알려", "모아서 알려", "설명해"
    ]

    /// Returns `true` if `text` expresses an intent to inspect or ask about what is on screen.
    public static func isScreenQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()

        for kw in englishKeywords {
            if lower.contains(kw) { return true }
        }
        for kw in japaneseKeywords {
            if lower.contains(kw) { return true }
        }
        for kw in koreanKeywords {
            if lower.contains(kw) { return true }
        }

        return false
    }

    /// Returns `true` if `text` asks for an informational answer, summary, explanation, or list,
    /// rather than pure direct GUI automation execution without synthesized feedback.
    public static func isInformationalRequest(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Explicit CLI-style act/goal commands are not considered conversational informational requests
        if trimmed.hasPrefix("/act ") || trimmed.hasPrefix("/goal ") {
            return false
        }

        let lower = trimmed.lowercased()
        let asksToFind = lower.contains("find posts") || lower.contains("find tweets")
            || ((trimmed.contains("投稿") || trimmed.contains("ツイート") || lower.contains("tweet"))
                && (trimmed.contains("探して") || trimmed.contains("収集して")))
        if asksToFind { return true }

        for kw in englishInformationalKeywords {
            if lower.contains(kw) { return true }
        }
        for kw in japaneseInformationalKeywords {
            if lower.contains(kw) { return true }
        }
        for kw in koreanInformationalKeywords {
            if lower.contains(kw) { return true }
        }

        return false
    }
}
