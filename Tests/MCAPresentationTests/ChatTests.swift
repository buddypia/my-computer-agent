import Foundation
import MCACore
import Testing

@testable import MCAPresentation

/// The chat window, the panel and the popover are three views of one thread,
/// and these cover the places they could disagree — a question with no answer
/// under it, an answer said twice, a turn counted unread while it is being read.
@Suite("Chat")
@MainActor
struct ChatTests {
    @Test("asking a question records it before the answer arrives")
    func questionAppearsImmediately() {
        let state = HUDState()
        state.beginStreaming(question: "なぜ落ちる？")

        #expect(state.messages.count == 1)
        #expect(state.messages.first?.role == .user)
        #expect(state.isStreaming)
    }

    /// Once. It used to land twice — a bubble in the thread and a card in the
    /// ring the panel drew — so the panel and the chat window disagreed about
    /// how many times the agent had answered.
    @Test("the answer lands under the question that asked it, once")
    func answerFollowsTheQuestion() {
        let state = HUDState()
        state.beginStreaming(question: "なぜ落ちる？")
        state.endStreaming(text: "nil を unwrap しています。")

        #expect(state.messages.map(\.role) == [.user, .assistant])
        #expect(state.messages.last?.text == "nil を unwrap しています。")
    }

    /// The voice path has no typed question — what was said is in
    /// `voiceTranscript`. An empty user bubble above the reply would be worse
    /// than none.
    @Test("an answer with no typed question adds no user turn")
    func voiceAnswersHaveNoUserBubble() {
        let state = HUDState()
        state.beginStreaming()
        state.endStreaming(text: "はい、聞こえています。")

        #expect(state.messages.map(\.role) == [.assistant])
    }

    /// A thread of answers with no questions above them is readable while the
    /// words are still in the caption and meaningless an hour later. The spoken
    /// turn has to land in the conversation, above its reply.
    @Test("a spoken turn is written into the conversation before its answer")
    func spokenTurnsAreRecorded() {
        let state = HUDState()
        state.appendUserSpeech("what is ")
        state.appendUserSpeech("on my screen")
        state.beginStreaming()
        state.endVoiceTurn()
        state.endStreaming(text: "Xcode です。")

        #expect(state.messages.map(\.role) == [.user, .assistant])
        #expect(state.messages.first?.text == "what is on my screen")
    }

    /// `endVoiceTurn` runs once per turn, but a session that ends on the same
    /// beat must not record the utterance twice.
    @Test("a turn that ends twice is only recorded once")
    func spokenTurnsAreNotDoubled() {
        let state = HUDState()
        state.appendUserSpeech("hello")
        state.endVoiceTurn()
        state.endVoiceTurn()

        #expect(state.messages.count == 1)
    }

    /// Vanishing is the one outcome the user cannot act on: the question is
    /// sitting right above it with nothing underneath.
    @Test("an empty answer is recorded as a failure rather than dropped")
    func emptyAnswersAreRecorded() {
        let state = HUDState()
        state.beginStreaming(question: "これは？")
        state.endStreaming()

        #expect(state.messages.map(\.role) == [.user, .failure])
    }

    /// The watch is the whole point of the feature and its output has to be
    /// distinguishable from a reply: one was asked for, the other was not.
    @Test("advice from the watch is marked as such and counted unread")
    func adviceIsMarkedAndCounted() {
        let state = HUDState()
        state.presentAdvice(title: "テストが落ちています", body: "`swift test` の 3 件が赤です。")

        #expect(state.messages.first?.role == .watch)
        #expect(state.messages.first?.title == "テストが落ちています")
        // Nothing is on screen, so the menu bar has to say something arrived.
        #expect(state.unseenMessages == 1)
    }

    /// The chat window is a surface like the popover. Counting advice the user
    /// is looking at as unread would badge the menu bar for something read.
    @Test("advice that arrives with the chat open is not counted unread")
    func openChatCountsAsOnScreen() {
        let state = HUDState()
        state.isChatOpen = true
        state.presentAdvice(title: "見出し", body: "本文")

        #expect(state.unseenMessages == 0)
        #expect(state.isOnScreen)
    }

    /// Starting over is starting over on every surface. With the panel drawing
    /// its own list, a cleared conversation left the same advice sitting in the
    /// popover, which reads as the clear having half worked.
    @Test("clearing the conversation empties every surface")
    func clearingChatEmptiesEverything() {
        let state = HUDState()
        state.presentAdvice(title: "見出し", body: "本文")
        state.clearChat()

        #expect(state.messages.isEmpty)
        #expect(state.unseenMessages == 0)
    }

    /// Clearing mid-answer is the case that made the old single trash button
    /// look broken: the thread emptied, and a second later the reply to the
    /// question that had just been thrown away dropped into it.
    @Test("an answer disowned by a cleared thread does not refill it")
    func clearingMidAnswerDiscardsIt() {
        let state = HUDState()
        state.beginStreaming(question: "なぜ落ちる？")
        state.clearChat()
        state.endStreaming(text: "nil を unwrap しています。")

        #expect(state.messages.isEmpty)
    }

    @Test("a later answer lands normally after a clear")
    func clearingOnlyDiscardsTheAnswerInFlight() {
        let state = HUDState()
        state.beginStreaming(question: "古い質問")
        state.clearChat()
        state.beginStreaming(question: "新しい質問")
        state.endStreaming(text: "答え")

        #expect(state.messages.map(\.role) == [.user, .assistant])
    }

    @Test("one turn can be dropped without touching the rest")
    func removingOneMessage() {
        let state = HUDState()
        state.beginStreaming(question: "質問")
        state.endStreaming(text: "答え")
        state.removeMessage(state.messages[1].id)

        #expect(state.messages.map(\.role) == [.user])
    }

    @Test("a chosen set is dropped together")
    func removingASelection() {
        let state = HUDState()
        for index in 0..<4 {
            state.append(ChatMessage(role: .assistant, text: "\(index)"))
        }
        let chosen = Set([state.messages[0].id, state.messages[2].id])
        state.removeMessages(chosen)

        #expect(state.messages.map(\.text) == ["1", "3"])
    }

    /// The useful part of a long thread is its tail, and picking twenty stale
    /// turns out one at a time is not something anyone does twice.
    @Test("a turn and everything older go together")
    func removingUpThrough() {
        let state = HUDState()
        for index in 0..<4 {
            state.append(ChatMessage(role: .assistant, text: "\(index)"))
        }
        state.removeMessages(upThrough: state.messages[1].id)

        #expect(state.messages.map(\.text) == ["2", "3"])
    }

    /// The advice, the notices and the failures are what accumulate on their
    /// own, so they are what a user prunes without wanting to lose the
    /// conversation.
    @Test("notices can be pruned while the conversation stays")
    func removingNotices() {
        let state = HUDState()
        state.beginStreaming(question: "質問")
        state.endStreaming(text: "答え")
        state.presentAdvice(title: "見出し", body: "本文")
        state.present(HUDCard(title: "お知らせ", body: "本文"))
        state.presentFailure("失敗しました")
        state.removeMessages(ofRole: [.watch, .failure, .notice])

        #expect(state.messages.map(\.role) == [.user, .assistant])
    }

    /// A session left running all day must not grow without bound, and the
    /// oldest turn is the one worth losing.
    @Test("the thread is bounded")
    func threadIsBounded() {
        let state = HUDState()
        for index in 0..<260 {
            state.append(ChatMessage(role: .assistant, text: "\(index)"))
        }

        #expect(state.messages.count == 200)
        #expect(state.messages.last?.text == "259")
    }

    @Test("streaming state is tracked and guarded")
    func streamingStateGuarded() {
        let state = HUDState()
        #expect(!state.isStreaming)
        state.beginStreaming(question: "画面について教えて")
        #expect(state.isStreaming)
        state.endStreaming(text: "画面の解説です")
        #expect(!state.isStreaming)
    }

    @Test("appendToken buffers tokens and flushes them completely upon endStreaming")
    func tokenBufferingAndFlush() {
        let state = HUDState()
        state.beginStreaming(question: "テスト質問")
        state.appendToken("こんにちは")
        state.appendToken("、")
        state.appendToken("世界！")

        // Before manual flush, tokens are either buffered or flushed;
        // endStreaming must guarantee all buffered tokens are flushed and recorded.
        state.endStreaming()

        #expect(state.messages.map(\.role) == [.user, .assistant])
        #expect(state.messages.last?.text == "こんにちは、世界！")
    }

    @Test("appendToken with zero throttle interval flushes immediately")
    func immediateTokenStreaming() {
        let state = HUDState()
        state.tokenThrottleInterval = .zero
        state.beginStreaming(question: "即時反映テスト")
        state.appendToken("トークン1")
        #expect(state.streamingText == "トークン1")
        state.appendToken("トークン2")
        #expect(state.streamingText == "トークン1トークン2")
        state.endStreaming()
        #expect(state.messages.last?.text == "トークン1トークン2")
    }

    @Test("rapid token stream flushes without dropping any character")
    func rapidStreamingIntegrity() {
        let state = HUDState()
        state.beginStreaming(question: "高速ストリーミング")
        var expected = ""
        for i in 0..<500 {
            let token = "[\(i)]"
            expected += token
            state.appendToken(token)
        }
        state.flushTokens()
        #expect(state.streamingText == expected)
        state.endStreaming()
        #expect(state.messages.last?.text == expected)
    }

    @Test("recentConversationTurns extracts user and assistant turns for reasoning context")
    func testRecentConversationTurnsExtraction() {
        let state = HUDState()
        state.messages = [
            ChatMessage(role: .notice, text: "セッションが開始しました"),
            ChatMessage(role: .user, text: "ブラウザーをスクロールしてTwitterの3K以上を探して"),
            ChatMessage(role: .assistant, text: "次のアクションでスクロールを探すこと"),
            ChatMessage(role: .failure, text: "エラー発生"),
            ChatMessage(role: .user, text: "スクロールして"),
        ]

        let turns = state.recentConversationTurns(limit: 10)
        #expect(turns.count == 3)
        #expect(turns[0].role == .user)
        #expect(turns[0].text == "ブラウザーをスクロールしてTwitterの3K以上を探して")
        #expect(turns[1].role == .assistant)
        #expect(turns[1].text == "次のアクションでスクロールを探すこと")
        #expect(turns[2].role == .user)
        #expect(turns[2].text == "スクロールして")
    }
}

