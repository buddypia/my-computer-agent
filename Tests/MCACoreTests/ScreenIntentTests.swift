import Foundation
import MCACore
import Testing

@Suite("Screen intent detection")
struct ScreenIntentTests {
    @Test("detects Japanese screen questions")
    func japaneseScreenQuestions() {
        #expect(ScreenIntent.isScreenQuestion("画面について質問…"))
        #expect(ScreenIntent.isScreenQuestion("画面について教えて"))
        #expect(ScreenIntent.isScreenQuestion("この画面は何？"))
        #expect(ScreenIntent.isScreenQuestion("いま画面に何が映ってる？"))
        #expect(ScreenIntent.isScreenQuestion("ウィンドウのエラーを見て"))
        #expect(ScreenIntent.isScreenQuestion("デスクトップの現在の表示はどうなってる？"))
    }

    @Test("detects English screen questions")
    func englishScreenQuestions() {
        #expect(ScreenIntent.isScreenQuestion("Ask about what you're seeing…"))
        #expect(ScreenIntent.isScreenQuestion("What's on my screen?"))
        #expect(ScreenIntent.isScreenQuestion("Explain what is on the screen"))
        #expect(ScreenIntent.isScreenQuestion("Look at this error in my window"))
        #expect(ScreenIntent.isScreenQuestion("What am I looking at right now?"))
    }

    @Test("detects Korean screen questions")
    func koreanScreenQuestions() {
        #expect(ScreenIntent.isScreenQuestion("화면에 대해 질문…"))
        #expect(ScreenIntent.isScreenQuestion("지금 화면에 보이는 것을 설명해줘"))
        #expect(ScreenIntent.isScreenQuestion("이 창에 무슨 오류가 있어?"))
    }

    @Test("ignores non-screen questions")
    func nonScreenQuestions() {
        #expect(!ScreenIntent.isScreenQuestion("What is 2 + 2?"))
        #expect(!ScreenIntent.isScreenQuestion("Swiftで構造体を宣言する方法は？"))
        #expect(!ScreenIntent.isScreenQuestion("Tell me a joke"))
        #expect(!ScreenIntent.isScreenQuestion(""))
        #expect(!ScreenIntent.isScreenQuestion("   "))
    }

    @Test("detects informational and summary requests requiring answer synthesis")
    func informationalRequests() {
        #expect(ScreenIntent.isInformationalRequest("FirefoxのXでビューが5K以上の投稿をスクロールしながら探して"))
        #expect(ScreenIntent.isInformationalRequest("Find posts with at least 5K views while scrolling"))
        #expect(!ScreenIntent.isInformationalRequest("Find and click the delete button"))
        // Japanese
        #expect(ScreenIntent.isInformationalRequest("Xでビューが5K以上のTweetをまとめて教えて。スクロールしながら収集して"))
        #expect(ScreenIntent.isInformationalRequest("画面の内容をまとめて教えて"))
        #expect(ScreenIntent.isInformationalRequest("タイムラインをスクロールして要約して"))
        #expect(ScreenIntent.isInformationalRequest("最新の投稿を収集してリストにして"))
        #expect(ScreenIntent.isInformationalRequest("このエラーの原因は何？"))
        #expect(ScreenIntent.isInformationalRequest("表示されている内容を説明して"))
        #expect(ScreenIntent.isInformationalRequest("画面のテキストを抽出して教えて"))

        // English
        #expect(ScreenIntent.isInformationalRequest("Summarize the top tweets with over 5K views while scrolling"))
        #expect(ScreenIntent.isInformationalRequest("Tell me what is on the screen"))
        #expect(ScreenIntent.isInformationalRequest("List the search results shown here"))
        #expect(ScreenIntent.isInformationalRequest("Explain this error"))

        // Korean
        #expect(ScreenIntent.isInformationalRequest("X에서 뷰 5K 이상 트윗 모아서 알려줘. 스크롤하면서 수집해줘"))
        #expect(ScreenIntent.isInformationalRequest("화면 내용 요약해서 정리해줘"))

        // Pure GUI manipulation / non-informational action requests should be false
        #expect(!ScreenIntent.isInformationalRequest("ボタンをクリックして"))
        #expect(!ScreenIntent.isInformationalRequest("次へを押して"))
        #expect(!ScreenIntent.isInformationalRequest("ブラウザを下にスクロールして"))
        #expect(!ScreenIntent.isInformationalRequest("Safariを開いて"))
        #expect(!ScreenIntent.isInformationalRequest("Click the Next button"))
        #expect(!ScreenIntent.isInformationalRequest("Scroll down the page"))
        #expect(!ScreenIntent.isInformationalRequest("/act click submit"))
        #expect(!ScreenIntent.isInformationalRequest("/goal scroll timeline"))
        #expect(!ScreenIntent.isInformationalRequest(""))
        #expect(!ScreenIntent.isInformationalRequest("   "))
    }
}
