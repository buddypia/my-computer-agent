import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import Testing

@Suite("Decision Engine Answer Robustness, Token Matching & Parameter Extraction Tests")
struct DecisionEngineRobustnessTests {

    private func makeFormCandidates() -> [UIElementCandidate] {
        [
            UIElementCandidate(
                id: "btn_submit",
                role: "AXButton",
                label: "Submit",
                bounds: CGRect(x: 100, y: 100, width: 80, height: 30)
            ),
            UIElementCandidate(
                id: "input_name",
                role: "AXTextField",
                label: "Full Name",
                value: "",
                bounds: CGRect(x: 100, y: 150, width: 200, height: 30)
            ),
            UIElementCandidate(
                id: "scroll_feed",
                role: "AXScrollArea",
                label: "News Feed",
                bounds: CGRect(x: 0, y: 200, width: 500, height: 400)
            )
        ]
    }

    private func makeCandidate(
        id: String,
        role: String = "AXButton",
        label: String = "Test Button",
        value: String? = nil,
        bounds: CGRect = CGRect(x: 100, y: 100, width: 80, height: 30),
        isActionable: Bool = true
    ) -> UIElementCandidate {
        UIElementCandidate(
            id: id,
            role: role,
            label: label,
            value: value,
            bounds: bounds,
            isActionable: isActionable
        )
    }

    // MARK: - 1. Escalation Threshold Semantics

    @Test("IEEE 754 float precision around default 0.80 threshold (0.799999 vs 0.800000 vs 0.800001)")
    func testConfidenceFloatPrecisionBoundaries() {
        let engine = TypeSafeDecisionEngine()

        let belowDecision = ComputerActionDecision(
            targetElementId: "btn_submit",
            action: .click,
            confidence: Float(0.799999),
            isCompleted: false
        )
        #expect(engine.shouldEscalate(decision: belowDecision) == true)

        let exactDecision = ComputerActionDecision(
            targetElementId: "btn_submit",
            action: .click,
            confidence: Float(0.800000),
            isCompleted: false
        )
        #expect(engine.shouldEscalate(decision: exactDecision) == false)

        let aboveDecision = ComputerActionDecision(
            targetElementId: "btn_submit",
            action: .click,
            confidence: Float(0.800001),
            isCompleted: false
        )
        #expect(engine.shouldEscalate(decision: aboveDecision) == false)
    }

    @Test("Custom threshold 0.85 boundary (0.849 vs 0.850 vs 0.851)")
    func testCustomConfidenceThresholdBoundaries() {
        let engine = TypeSafeDecisionEngine(confidenceThreshold: 0.85)

        let d849 = ComputerActionDecision(targetElementId: "btn_submit", action: .click, confidence: 0.849, isCompleted: false)
        let d850 = ComputerActionDecision(targetElementId: "btn_submit", action: .click, confidence: 0.850, isCompleted: false)
        let d851 = ComputerActionDecision(targetElementId: "btn_submit", action: .click, confidence: 0.851, isCompleted: false)

        #expect(engine.shouldEscalate(decision: d849) == true)
        #expect(engine.shouldEscalate(decision: d850) == false)
        #expect(engine.shouldEscalate(decision: d851) == false)
    }

    @Test("Action .none escalates even with high confidence when not completed")
    func testActionNoneEscalatesRegardlessOfHighConfidence() {
        let engine = TypeSafeDecisionEngine()
        let decision = ComputerActionDecision(
            targetElementId: nil,
            action: .none,
            confidence: 0.99,
            isCompleted: false,
            reasoning: "Action is none, cannot execute"
        )

        #expect(engine.shouldEscalate(decision: decision) == true)
    }

    // MARK: - 2. System One Model Answer Interpretation Robustness

    @Test("Missing target_element answer in click action falls back safely")
    func testMissingTargetElementPayload() async throws {
        let evaluator = MockTypeSafeEvaluator { _ in
            TypeSafeClient.EvaluationResponse(
                model: "jev-mock",
                answers: [
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "click", confidence: 0.95),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.0)
                ],
                usage: TypeSafeClient.UsagePayload(inputTokens: 0, outputTokens: 0)
            )
        }
        let engine = TypeSafeDecisionEngine(client: evaluator)
        let decision = try await engine.decideNextAction(goal: "Click submit", candidates: makeFormCandidates())

        #expect(decision.targetElementId == nil)
        #expect(decision.action == .none)
        #expect(decision.confidence == 0.0)
        #expect(engine.shouldEscalate(decision: decision) == true)
    }

    @Test("Missing action_type answer falls back safely to .none")
    func testMissingActionTypePayload() async throws {
        let evaluator = MockTypeSafeEvaluator { _ in
            TypeSafeClient.EvaluationResponse(
                model: "jev-mock",
                answers: [
                    "target_element": TypeSafeClient.AnswerPayload(type: "choice", choice: "btn_submit", confidence: 0.95),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.0)
                ],
                usage: TypeSafeClient.UsagePayload(inputTokens: 0, outputTokens: 0)
            )
        }
        let engine = TypeSafeDecisionEngine(client: evaluator)
        let decision = try await engine.decideNextAction(goal: "Click submit", candidates: makeFormCandidates())

        #expect(decision.action == .none)
        #expect(engine.shouldEscalate(decision: decision) == true)
    }

    @Test("Unknown or hallucinated action_type maps to .none")
    func testUnknownActionTypePayload() async throws {
        let evaluator = MockTypeSafeEvaluator { _ in
            TypeSafeClient.EvaluationResponse(
                model: "jev-mock",
                answers: [
                    "target_element": TypeSafeClient.AnswerPayload(type: "choice", choice: "btn_submit", confidence: 0.95),
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "teleport_to_url", confidence: 0.95),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.0)
                ],
                usage: TypeSafeClient.UsagePayload(inputTokens: 0, outputTokens: 0)
            )
        }
        let engine = TypeSafeDecisionEngine(client: evaluator)
        let decision = try await engine.decideNextAction(goal: "Click submit", candidates: makeFormCandidates())

        #expect(decision.action == .none)
        #expect(engine.shouldEscalate(decision: decision) == true)
    }

    @Test("target_element with hallucinated ID not in candidates escalates safely")
    func testHallucinatedTargetElementIdPayload() async throws {
        let mock = MockTypeSafeEvaluator.scripted(
            targetChoice: "ghost_element_9999",
            targetConfidence: 0.95,
            actionChoice: "click",
            actionConfidence: 0.95
        )
        let engine = TypeSafeDecisionEngine(client: mock)
        let decision = try await engine.decideNextAction(goal: "Click submit", candidates: makeFormCandidates())

        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
        #expect(decision.confidence == 0.0)
        #expect(engine.shouldEscalate(decision: decision) == true)
    }

    @Test("text_selection with negative span index ('span_-1') does not crash and falls back to extracted text")
    func testNegativeSpanIndexAdversarialPayload() async throws {
        let evaluator = MockTypeSafeEvaluator { _ in
            TypeSafeClient.EvaluationResponse(
                model: "jev-mock",
                answers: [
                    "target_element": TypeSafeClient.AnswerPayload(type: "choice", choice: "input_name", confidence: 0.95),
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "type", confidence: 0.95),
                    "text_selection": TypeSafeClient.AnswerPayload(type: "choice", choice: "span_-1", confidence: 0.95),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.0)
                ],
                usage: TypeSafeClient.UsagePayload(inputTokens: 0, outputTokens: 0)
            )
        }
        let engine = TypeSafeDecisionEngine(client: evaluator)
        let decision = try await engine.decideNextAction(
            goal: "Type \"Alice\" or \"Bob\" into Full Name",
            candidates: makeFormCandidates()
        )

        #expect(decision.action == .typeText)
        #expect(decision.targetElementId == "input_name")
    }

    @Test("Malformed scroll_direction payload defaults to downward scroll")
    func testMalformedScrollDirectionPayload() async throws {
        let evaluator = MockTypeSafeEvaluator { _ in
            TypeSafeClient.EvaluationResponse(
                model: "jev-mock",
                answers: [
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "scroll", confidence: 0.92),
                    "scroll_direction": TypeSafeClient.AnswerPayload(type: "choice", choice: "diagonal_inward", confidence: 0.90),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.0)
                ],
                usage: TypeSafeClient.UsagePayload(inputTokens: 0, outputTokens: 0)
            )
        }
        let engine = TypeSafeDecisionEngine(client: evaluator)
        let decision = try await engine.decideNextAction(goal: "Scroll the view", candidates: makeFormCandidates())

        #expect(decision.action == .scroll)
        #expect(decision.scrollDelta?.dy ?? 0 < 0)
    }

    @Test("Malformed key_target payload does not produce empty key combination array with high confidence")
    func testMalformedKeyTargetPayload() async throws {
        let evaluator = MockTypeSafeEvaluator { _ in
            TypeSafeClient.EvaluationResponse(
                model: "jev-mock",
                answers: [
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "key", confidence: 0.92),
                    "key_target": TypeSafeClient.AnswerPayload(type: "choice", choice: ",,,,", confidence: 0.90),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.0)
                ],
                usage: TypeSafeClient.UsagePayload(inputTokens: 0, outputTokens: 0)
            )
        }
        let engine = TypeSafeDecisionEngine(client: evaluator)
        let decision = try await engine.decideNextAction(goal: "Press key", candidates: makeFormCandidates())

        #expect(decision.action == .keyPress)
        #expect(decision.keyCombination != [])
        #expect(decision.confidence <= 0.50)
    }

    @Test("triageGoal interprets model answers and falls back on API error")
    func testTriageGoalModelInterpretationAndFallback() async {
        let modelMock = MockTypeSafeEvaluator { _ in
            TypeSafeClient.EvaluationResponse(
                model: "jev-mock",
                answers: [
                    "needs_action": TypeSafeClient.AnswerPayload(type: "choice", choice: "computer_action", confidence: 0.92),
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "browser_scroll_or_search", confidence: 0.92)
                ],
                usage: TypeSafeClient.UsagePayload(inputTokens: 0, outputTokens: 0)
            )
        }
        let modelEngine = TypeSafeDecisionEngine(client: modelMock)
        let modelTriage = await modelEngine.triageGoal(goal: "Scroll feed", activeApp: "Browser")
        #expect(modelTriage.needsComputerAction == true)
        #expect(modelTriage.intentCategory == "browser_scroll_or_search")

        let failingMock = MockTypeSafeEvaluator { _ in
            throw URLError(.timedOut)
        }
        let fallbackEngine = TypeSafeDecisionEngine(client: failingMock)
        let fallbackTriage = await fallbackEngine.triageGoal(goal: "FirefoxでTwitterをスクロールして探して", activeApp: "Firefox")
        #expect(fallbackTriage.needsComputerAction == true)
        #expect(fallbackTriage.intentCategory == "browser_scroll_or_search")
    }

    // MARK: - 3. Goal Parameter Extraction

    @Test("Nested quotes in user goal text are extracted as candidate text spans")
    func testNestedQuotesExtraction() {
        let text1 = "Type \"Hello 'World'\" into the search field"
        let spans1 = TypeSafeDecisionEngine.extractCandidateTextSpans(from: text1)
        #expect(spans1.contains("Hello 'World'"))

        let text2 = "「『重要』なタスク」を入力して"
        let spans2 = TypeSafeDecisionEngine.extractCandidateTextSpans(from: text2)
        #expect(spans2.contains("『重要』なタスク") || spans2.contains("重要"))
    }

    @Test("extractTextInput completes in linear time on long repeated tokens")
    func testRegexCatastrophicBacktrackingStress() {
        let longGoal = "type " + String(repeating: "a ", count: 2000) + "into search"
        let ms = threadCPUMilliseconds { _ = TypeSafeDecisionEngine.extractTextInput(from: longGoal) }

        #expect(ms < 1000, "extractTextInput took too long (\(ms)ms of CPU); possible catastrophic backtracking!")
    }

    @Test("Degenerate key combinations ('', '+', ',', ',,,') return nil or non-empty keys")
    func testDegenerateKeyCombinations() {
        #expect(TypeSafeDecisionEngine.extractKeyCombination(from: "test", jevChoice: "") == nil)
        let commaResult = TypeSafeDecisionEngine.extractKeyCombination(from: "test", jevChoice: ",,,")
        #expect(commaResult == nil || commaResult?.isEmpty == false)

        let plusResult = TypeSafeDecisionEngine.extractKeyCombination(from: "test", jevChoice: "+++")
        #expect(plusResult == nil || plusResult?.isEmpty == false)
    }

    @Test("extractScrollDelta handles non-numeric and NaN coordinates")
    func testScrollDeltaWithNonNumericOrNaN() {
        let delta1 = TypeSafeDecisionEngine.extractScrollDelta(from: "scroll", jevChoice: "NaN,NaN")
        #expect(!delta1.dx.isNaN && !delta1.dy.isNaN)

        let delta2 = TypeSafeDecisionEngine.extractScrollDelta(from: "scroll", jevChoice: "abc,def")
        #expect(!delta2.dx.isNaN && !delta2.dy.isNaN)

        let delta3 = TypeSafeDecisionEngine.extractScrollDelta(from: "scroll", jevChoice: "-100,500")
        #expect(delta3.dx == -100 && delta3.dy == 500)
    }

    // MARK: - 4. Offline Tokenization, Script Segmentation & Matching

    @Test("Katakana middle dot (U+30FB) and half-width middle dot (U+FF65) act as word delimiters")
    func testKatakanaMiddleDotSegmentation() {
        let tokensFull = TypeSafeDecisionEngine.extractTokens(from: "ユーザー・インターフェース")
        #expect(tokensFull.contains("ユーザー"))
        #expect(tokensFull.contains("インターフェース"))
        #expect(!tokensFull.contains("・"))

        let tokensHalf = TypeSafeDecisionEngine.extractTokens(from: "ユーザー･ガイド")
        #expect(tokensHalf.contains("ユーザー"))
        #expect(tokensHalf.contains("ガイド"))
    }

    @Test("Katakana prolonged sound mark (U+30FC 'ー') is preserved within tokens")
    func testKatakanaProlongedSoundMarkPreserved() {
        let tokens = TypeSafeDecisionEngine.extractTokens(from: "サーバーエラー")
        #expect(tokens.contains("サーバーエラー"))
    }

    @Test("Full-width digits (U+FF10...U+FF19 '０'-'９') normalize to ASCII digits")
    func testFullWidthDigitsNormalization() {
        let tokens = TypeSafeDecisionEngine.extractTokens(from: "タブ２の番号")
        #expect(tokens.contains("2"))
        #expect(tokens.contains("番号"))
        #expect(!tokens.contains("の"))
        #expect(!tokens.contains("タブ"))
    }

    @Test("Japanese particle stripping removes grammatical particles while preserving semantic tokens")
    func testJapaneseParticleStripping() {
        let sentence = "設定の画面を開いてアカウントを更新してください"
        let tokens = TypeSafeDecisionEngine.extractTokens(from: sentence)
        #expect(tokens.contains("設定"))
        #expect(tokens.contains("アカウント"))
        #expect(tokens.contains("更新"))
        #expect(!tokens.contains("の"))
        #expect(!tokens.contains("を"))
        #expect(!tokens.contains("して"))
        #expect(!tokens.contains("ください"))
    }

    @Test("Latin word boundary enforcement prevents interior substring false positive ('OK' inside 'Lookup', 'Token', 'Book')")
    func testLatinWordBoundaryStrictness() {
        let engine = TypeSafeDecisionEngine()
        let okButton = makeCandidate(id: "btn_ok", role: "AXButton", label: "OK", isActionable: true)

        let goals = [
            "Lookup catalog items",
            "Generate auth token",
            "Book flight reservation",
            "Smoke test the pipeline"
        ]

        for goal in goals {
            let decision = engine.fallbackLocalDecision(goal: goal, candidates: [okButton])
            #expect(decision.targetElementId == nil, "Goal '\(goal)' must NOT match button labeled 'OK'")
            #expect(decision.confidence < 0.80)
        }
    }

    @Test("Value attribute fallback when candidate label is empty or whitespace")
    func testValueAttributeFallbackWhenLabelEmpty() {
        let engine = TypeSafeDecisionEngine()
        let enCandidate = makeCandidate(
            id: "search_input",
            role: "AXTextField",
            label: "   ",
            value: "Search products or categories",
            isActionable: true
        )
        let enDecision = engine.fallbackLocalDecision(goal: "Search products", candidates: [enCandidate])
        #expect(enDecision.targetElementId == "search_input")
        #expect(enDecision.confidence >= 0.80)

        let jaCandidate = UIElementCandidate(
            id: "user_name_input",
            role: "AXTextField",
            label: "",
            value: "山田太郎",
            bounds: CGRect(x: 100, y: 100, width: 200, height: 30)
        )
        let jaDecision = engine.fallbackLocalDecision(goal: "山田太郎を入力して", candidates: [jaCandidate])
        #expect(jaDecision.targetElementId == "user_name_input")
        #expect(jaDecision.action == .click || jaDecision.action == .typeText)
        #expect(jaDecision.confidence >= 0.80)
    }

    @Test("Candidate ID component and exact matching when label and value are empty")
    func testIdComponentMatchingWhenLabelAndValueEmpty() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(
                id: "email_address_input_field",
                role: "AXTextField",
                label: "",
                value: "user@example.com",
                bounds: CGRect(x: 10, y: 10, width: 200, height: 30),
                isActionable: true
            ),
            UIElementCandidate(
                id: "btn_submit_checkout_v2",
                role: "AXButton",
                label: "",
                value: nil,
                bounds: CGRect(x: 10, y: 60, width: 100, height: 30),
                isActionable: true
            )
        ]

        let d1 = engine.fallbackLocalDecision(goal: "Type into user@example.com", candidates: candidates)
        #expect(d1.targetElementId == "email_address_input_field")
        #expect(d1.confidence >= 0.80)

        let d2 = engine.fallbackLocalDecision(goal: "Click the checkout button", candidates: candidates)
        #expect(d2.targetElementId == "btn_submit_checkout_v2")
        #expect(d2.confidence >= 0.80)

        let d3 = engine.fallbackLocalDecision(goal: "Click btn_submit_checkout_v2", candidates: candidates)
        #expect(d3.targetElementId == "btn_submit_checkout_v2")
        #expect(d3.confidence >= 0.80)
    }

    @Test("Strips planner retry prefix and matches underlying Japanese intent")
    func testStripsPlannerRetryPrefix() {
        let engine = TypeSafeDecisionEngine()
        let button = UIElementCandidate(
            id: "btn_save",
            role: "AXButton",
            label: "保存",
            bounds: CGRect(x: 300, y: 300, width: 100, height: 40)
        )

        let decision = engine.fallbackLocalDecision(
            goal: "Interact with alternative interactive element for: 保存をクリックして",
            candidates: [button]
        )

        #expect(decision.targetElementId == "btn_save")
        #expect(decision.action == .click)
        #expect(decision.confidence >= 0.80)
    }

    @Test("Japanese Kanji, Katakana, and quoted queries with particles")
    func testTokenMatchingJapaneseExtremeQueries() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "btn_order", role: "AXButton", label: "注文確定", bounds: CGRect(x: 10, y: 10, width: 100, height: 40), isActionable: true),
            UIElementCandidate(id: "btn_cart", role: "AXButton", label: "カートを見る", bounds: CGRect(x: 120, y: 10, width: 100, height: 40), isActionable: true),
            UIElementCandidate(id: "btn_save", role: "AXButton", label: "保存", bounds: CGRect(x: 230, y: 10, width: 80, height: 40), isActionable: true),
            UIElementCandidate(id: "txt_search", role: "AXTextField", label: "商品を検索", bounds: CGRect(x: 320, y: 10, width: 150, height: 40), isActionable: true)
        ]

        let d1 = engine.fallbackLocalDecision(goal: "変更を保存してください", candidates: candidates)
        #expect(d1.targetElementId == "btn_save")
        #expect(d1.confidence >= 0.80)

        let d2 = engine.fallbackLocalDecision(goal: "注文確定ボタンをクリックして", candidates: candidates)
        #expect(d2.targetElementId == "btn_order")
        #expect(d2.confidence >= 0.80)

        let d3 = engine.fallbackLocalDecision(goal: "カートの中身を確認して", candidates: candidates)
        #expect(d3.action == .none)
        #expect(d3.targetElementId == nil)
        #expect(engine.shouldEscalate(decision: d3))

        let d4 = engine.fallbackLocalDecision(goal: "「注文確定」を押す", candidates: candidates)
        #expect(d4.targetElementId == "btn_order")
        #expect(d4.confidence >= 0.80)
    }

    @Test("Heavy stop-word sentence matches multi-word target")
    func testTokenMatchingHeavyStopWordSentence() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "btn_submit_order", role: "AXButton", label: "Submit Order", bounds: CGRect(x: 50, y: 50, width: 120, height: 40), isActionable: true),
            UIElementCandidate(id: "btn_cancel", role: "AXButton", label: "Cancel and Return", bounds: CGRect(x: 200, y: 50, width: 140, height: 40), isActionable: true)
        ]

        let goal = "Please can you click on the button for submitting the order now"
        let decision = engine.fallbackLocalDecision(goal: goal, candidates: candidates)

        #expect(decision.targetElementId == "btn_submit_order")
        #expect(decision.action == .click)
        #expect(decision.confidence >= 0.80)
    }

    @Test("Numeric disambiguation between similarly named tabs")
    func testTokenMatchingNumericDisambiguation() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "tab_1", role: "AXTab", label: "Tab 1: Overview", bounds: CGRect(x: 0, y: 0, width: 100, height: 30), isActionable: true),
            UIElementCandidate(id: "tab_2", role: "AXTab", label: "Tab 2: Details", bounds: CGRect(x: 100, y: 0, width: 100, height: 30), isActionable: true),
            UIElementCandidate(id: "tab_3", role: "AXTab", label: "Tab 3: Settings", bounds: CGRect(x: 200, y: 0, width: 100, height: 30), isActionable: true)
        ]

        #expect(engine.fallbackLocalDecision(goal: "Select Tab 1", candidates: candidates).targetElementId == "tab_1")
        #expect(engine.fallbackLocalDecision(goal: "Select Tab 2", candidates: candidates).targetElementId == "tab_2")
        #expect(engine.fallbackLocalDecision(goal: "Select Tab 3", candidates: candidates).targetElementId == "tab_3")
    }

    @Test("Emoji and Japanese bracketed labels match in fallbackLocalDecision")
    func testTokenMatchingAdversarialUnicodeAndEmojis() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "btn_emoji", role: "AXButton", label: "🚀 Launch App", bounds: CGRect(x: 10, y: 10, width: 120, height: 40), isActionable: true),
            UIElementCandidate(id: "btn_brackets", role: "AXButton", label: "【重要】今すぐ確認", bounds: CGRect(x: 150, y: 10, width: 140, height: 40), isActionable: true)
        ]

        let d1 = engine.fallbackLocalDecision(goal: "Click 🚀 Launch App", candidates: candidates)
        #expect(d1.targetElementId == "btn_emoji")
        #expect(d1.confidence >= 0.80)

        let d2 = engine.fallbackLocalDecision(goal: "【重要】今すぐ確認をクリックして", candidates: candidates)
        #expect(d2.targetElementId == "btn_brackets")
        #expect(d2.confidence >= 0.80)
    }

    // MARK: - 5. Extreme Inputs & Scaling

    @Test("Empty and pure whitespace goals produce immediate .none decision with 0.0 confidence")
    func testEmptyAndWhitespaceGoals() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [makeCandidate(id: "btn", role: "AXButton", label: "Test")]

        let emptyDecision = engine.fallbackLocalDecision(goal: "", candidates: candidates)
        #expect(emptyDecision.action == .none)
        #expect(emptyDecision.confidence == 0.0)
        #expect(!emptyDecision.isCompleted)

        let wsDecision = engine.fallbackLocalDecision(goal: "  \n\t  ", candidates: candidates)
        #expect(wsDecision.action == .none)
        #expect(wsDecision.confidence == 0.0)
        #expect(!wsDecision.isCompleted)
    }

    @Test("Goals with null bytes and control characters still match semantic tokens")
    func testGoalsWithControlCharacters() {
        let engine = TypeSafeDecisionEngine()
        let candidate = makeCandidate(id: "btn_save", role: "AXButton", label: "Save")

        let malformed = "Save\0\u{0007}\u{001B} Document\r\n"
        let decision = engine.fallbackLocalDecision(goal: malformed, candidates: [candidate])
        #expect(decision.targetElementId == "btn_save")
        #expect(decision.confidence >= 0.80)
    }

    @Test("Pure punctuation and symbol goals return .none without matching symbol-labeled buttons")
    func testPurePunctuationGoals() {
        let engine = TypeSafeDecisionEngine()
        let candidate = makeCandidate(id: "btn_star", role: "AXButton", label: "***")

        let decision = engine.fallbackLocalDecision(goal: "!@#$%^&*()_+=-[]{}\\|;:'\",.<>/?", candidates: [candidate])
        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
    }

    @Test("Large candidate list (500 candidates) with mixed roles completes in <100ms CPU")
    func testCandidateListScalingEfficiency() {
        let engine = TypeSafeDecisionEngine()
        var candidates: [UIElementCandidate] = []
        for i in 0..<500 {
            candidates.append(
                makeCandidate(
                    id: "elem_\(i)",
                    role: i % 5 == 0 ? "AXScrollArea" : "AXButton",
                    label: "Element \(i)",
                    bounds: CGRect(x: Double(i % 10) * 80, y: Double(i / 10) * 30, width: 70, height: 25)
                )
            )
        }

        var decision: ComputerActionDecision!
        let ms = threadCPUMilliseconds {
            decision = engine.fallbackLocalDecision(goal: "Click Element 442", candidates: candidates)
        }

        #expect(decision.targetElementId == "elem_442")
        #expect(decision.confidence >= 0.80)
        #expect(ms < 100, "500 candidate evaluation took \(ms)ms of CPU; must be < 100ms")
    }

    // MARK: - Word Boundaries, Partial-Match Confidence & Explicit Keys

    @Test("Latin needles need a word boundary on the right too, and a single kanji matches only itself")
    func testWordBoundaryOnBothSidesAndSingleKanji() {
        #expect(!TypeSafeDecisionEngine.containsWordOrPhrase(in: "okay", needle: "ok"))
        #expect(!TypeSafeDecisionEngine.containsWordOrPhrase(in: "saved drafts", needle: "save"))
        #expect(TypeSafeDecisionEngine.containsWordOrPhrase(in: "save as", needle: "save"))
        #expect(!TypeSafeDecisionEngine.isDirectMatch(target: "okay", query: "ok"))

        #expect(!TypeSafeDecisionEngine.containsWordOrPhrase(in: "開発者ツール", needle: "開"))
        #expect(TypeSafeDecisionEngine.containsWordOrPhrase(in: "開", needle: "開"))
    }

    @Test("A target found through partial token overlap executes without escalating")
    func testPartialTokenMatchDoesNotEscalate() {
        let engine = TypeSafeDecisionEngine()
        // One of two goal tokens is a substring of the label and id (score 65, overlap 0.5).
        // A whole-token hit would score >= 100 and take the exact-match branch instead.
        let half = makeCandidate(id: "exporting_status", role: "AXStaticText", label: "Exporting")
        let d1 = engine.fallbackLocalDecision(goal: "expo report", candidates: [half])
        #expect(d1.targetElementId == "exporting_status")
        #expect(d1.confidence < 0.85, "fixture must reach the partial-overlap branch, not the exact-match one")
        #expect(!engine.shouldEscalate(decision: d1), "conf \(d1.confidence) must stay at or above the 0.80 threshold")

        // One of three goal tokens only prefixes the label (score < 60, overlap < 0.5).
        let prefix = makeCandidate(id: "lbl_1", role: "AXStaticText", label: "Exporting")
        let d2 = engine.fallbackLocalDecision(goal: "expo report data", candidates: [prefix])
        #expect(d2.targetElementId == "lbl_1")
        #expect(!engine.shouldEscalate(decision: d2), "conf \(d2.confidence) must stay at or above the 0.80 threshold")
    }

    @Test("A key named with a key verb is pressed even when the screen shows tabs")
    func testExplicitKeyIsPressedDespiteTabsOnScreen() {
        let engine = TypeSafeDecisionEngine()
        let browserTab = makeCandidate(id: "tab_1", role: "AXTab", label: "Inbox")
        let toc = makeCandidate(id: "toc", role: "AXButton", label: "Table of contents")
        let suggestion = makeCandidate(id: "suggestion", role: "AXMenuItem", label: "tokyo weather")

        let enter = engine.fallbackLocalDecision(goal: "Press Enter to select the suggestion", candidates: [browserTab, suggestion])
        #expect(enter.action == .keyPress)
        #expect(enter.keyCombination == ["Return"])

        let tab = engine.fallbackLocalDecision(goal: "Press Tab to select the next field", candidates: [toc])
        #expect(tab.action == .keyPress)
        #expect(tab.keyCombination == ["Tab"])

        // A loose key phrase still yields to the tab the goal names.
        let shortcutsTab = makeCandidate(id: "tab_shortcuts", role: "AXTab", label: "ショートカット")
        let select = engine.fallbackLocalDecision(goal: "ショートカットタブを選択", candidates: [shortcutsTab])
        #expect(select.action == .click)
        #expect(select.targetElementId == "tab_shortcuts")

        // A key word without a key verb names the tab, not the key.
        let escapeTab = makeCandidate(id: "tab_escape", role: "AXTab", label: "Escape")
        for goal in ["Select the Escape tab", "Select the Escape tab in the press settings"] {
            let escape = engine.fallbackLocalDecision(goal: goal, candidates: [escapeTab])
            #expect(escape.action == .click, "\(goal)")
            #expect(escape.targetElementId == "tab_escape")
        }
        let escapeKeyTab = makeCandidate(id: "tab_escape_key", role: "AXTab", label: "エスケープキー")
        let named = engine.fallbackLocalDecision(goal: "「エスケープキー」タブを選択", candidates: [escapeKeyTab])
        #expect(named.action == .click)
        #expect(named.targetElementId == "tab_escape_key")

        let jaEnter = engine.fallbackLocalDecision(goal: "エンターキーを押して候補を選択", candidates: [browserTab, suggestion])
        #expect(jaEnter.action == .keyPress)
        #expect(jaEnter.keyCombination == ["Return"])

        // So does a numbered tab, even after "press".
        let tab2 = makeCandidate(id: "tab_2", role: "AXTab", label: "Tab 2")
        let numbered = engine.fallbackLocalDecision(goal: "Press tab 2", candidates: [tab2])
        #expect(numbered.action == .click)
        #expect(numbered.targetElementId == "tab_2")
    }
}
