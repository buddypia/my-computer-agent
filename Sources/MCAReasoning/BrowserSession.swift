import Foundation
import MCACore
import MCASensing
import OSLog

/// The agent's hold on a browser: which driver is live, the last snapshot's
/// refs, and the observe → act pipeline built on top of the driver.
///
/// Ref discipline is the whole contract: refs come
/// from a snapshot, every snapshot replaces the ref table, and an id that is
/// not in the current table is an error that tells the model to snapshot
/// again. Nothing here guesses.
public actor BrowserSession {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "BrowserSession")

    /// Candidate drivers in preference order. The first that connects wins
    /// and is kept until it fails.
    private let candidates: [any BrowserDriving]
    private var active: (any BrowserDriving)?
    private var activeScopeID: UInt32?
    private let inference: BrowserInference?
    /// The accessibility fallback drives the user's own browser with global
    /// key events, so what it types or presses is approved like any other
    /// keystroke (see ``KeystrokeApproval``). The DevTools driver types into
    /// the agent's own tab and is not asked. The default refuses.
    private let keystrokeApprover: any ToolApproving

    public private(set) var lastSnapshot: BrowserSnapshot?
    private var lastSnapshotOptions = BrowserSnapshotOptions()
    private var lastSnapshotTabID: String?
    /// Maximum outline characters handed to the model in one call.
    public var outlineBudget = 60_000

    public init(
        drivers: [any BrowserDriving], inference: BrowserInference?,
        keystrokeApprover: any ToolApproving = DenyAllToolApprover()
    ) {
        self.candidates = drivers
        self.inference = inference
        self.keystrokeApprover = keystrokeApprover
    }

    // MARK: - Driver

    public func driver() async throws -> any BrowserDriving {
        let requestedScope = ActionAuthorization.current?.targetWindow
        if let requestedScope,
           PrivacyFilter.isWindowExcluded(bundleID: requestedScope.bundleID, windowTitle: requestedScope.windowTitle) {
            resetConnection()
            throw BrowserError.notConnected("Selected browser window is excluded from inspection")
        }
        if ActionAuthorization.current?.requiresWindowScope == true && requestedScope == nil {
            throw BrowserError.notConnected("select a browser window before controlling it")
        }
        if activeScopeID != requestedScope?.id { resetConnection() }
        if let active {
            if let requestedScope { try await active.scope(to: requestedScope) }
            try await validatePrivacy(of: active, target: requestedScope)
            return active
        }
        var failures: [String] = []
        for candidate in candidates {
            do {
                if let requestedScope { try await candidate.scope(to: requestedScope) }
                try await candidate.connect()
                try await validatePrivacy(of: candidate, target: requestedScope)
                active = candidate
                activeScopeID = requestedScope?.id
                log.info("Browser driver ready: \(candidate.kind.rawValue, privacy: .public)")
                return candidate
            } catch {
                failures.append("\(candidate.kind.rawValue): \(describe(error))")
            }
        }
        throw BrowserError.notConnected(failures.joined(separator: "; "))
    }

    private func validatePrivacy(of driver: any BrowserDriving, target: PinnedWindow?) async throws {
        let page = try await driver.currentPage()
        guard !PrivacyFilter.isWindowExcluded(bundleID: target?.bundleID, windowTitle: page.title) else {
            resetConnection()
            throw BrowserError.notConnected("Current browser page is excluded from inspection")
        }
    }

    public func currentPage() async throws -> (url: String, title: String) {
        let driver = try await driver()
        let page = try await driver.currentPage()
        guard !PrivacyFilter.isWindowExcluded(bundleID: ActionAuthorization.current?.targetWindow?.bundleID,
                                              windowTitle: page.title) else {
            resetConnection()
            throw BrowserError.notConnected("Current browser page is excluded from inspection")
        }
        return page
    }

    public func validateNavigationScope() async throws {
        let driver = try await driver()
        if driver.kind == .accessibility,
           ActionAuthorization.current?.targetWindow != nil || ActionAuthorization.current?.requiresWindowScope == true {
            throw BrowserError.unsupportedAction("opening a URL cannot be confined to the selected window with Accessibility")
        }
        try Task.checkCancellation()
    }

    public func tabs() async throws -> [BrowserTab] {
        let driver = try await driver()
        let tabs = try await driver.tabs()
        _ = try await currentPage()
        try Task.checkCancellation()
        let target = ActionAuthorization.current?.targetWindow
        return tabs.filter {
            (target == nil || $0.isActive)
                && !PrivacyFilter.isWindowExcluded(bundleID: target?.bundleID, windowTitle: $0.title)
        }
    }

    public func switchTab(id: String) async throws {
        guard ActionAuthorization.current?.targetWindow == nil,
              ActionAuthorization.current?.requiresWindowScope != true else {
            throw BrowserError.unsupportedAction("switching away from the selected window is refused")
        }
        let driver = try await driver()
        guard let destination = try await tabs().first(where: { $0.id == id }) else {
            throw BrowserError.unsupportedAction("the requested tab is unavailable or excluded")
        }
        try await authorizeCurrentPage(operation: "Switch tab",
            details: "Tab ID: \(id)\nDestination: \(destination.title) — \(destination.url)")
        guard let fresh = try await tabs().first(where: { $0.id == id }),
              fresh.url == destination.url, fresh.title == destination.title else {
            throw ActionAuthorizationError.staleTarget
        }
        try Task.checkCancellation()
        try await driver.switchTab(id: id)
        lastSnapshot = nil
        lastSnapshotTabID = nil
    }

    /// Forgets the live driver so the next call reconnects. Called when a
    /// driver reports its connection is gone.
    public func resetConnection() {
        active = nil
        lastSnapshot = nil
    }

    public func describeConnection() async -> String {
        guard let active else { return "no browser connected yet" }
        return await active.describeConnection()
    }

    // MARK: - Snapshot & refs

    @discardableResult
    public func snapshot(options: BrowserSnapshotOptions = BrowserSnapshotOptions()) async throws -> BrowserSnapshot {
        var options = options
        options.maxCharacters = min(options.maxCharacters, outlineBudget)
        let driver = try await driver()
        do {
            let snapshot = try await driver.snapshot(options: options)
            try await validatePrivacy(of: driver, target: ActionAuthorization.current?.targetWindow)
            guard !PrivacyFilter.isWindowExcluded(bundleID: ActionAuthorization.current?.targetWindow?.bundleID,
                                                  windowTitle: snapshot.title) else {
                resetConnection()
                throw BrowserError.notConnected("Current browser page is excluded from inspection")
            }
            lastSnapshot = snapshot
            lastSnapshotOptions = options
            lastSnapshotTabID = try await driver.tabs().first(where: \.isActive)?.id
            return snapshot
        } catch let error as BrowserError {
            if case .notConnected = error { resetConnection() }
            throw error
        }
    }

    /// Accepts `0-12`, `@0-12`, `[0-12]` and `ref=0-12`.
    public static func normalizeRef(_ raw: String) -> String {
        var ref = raw.trimmingCharacters(in: .whitespaces)
        if ref.hasPrefix("ref=") { ref = String(ref.dropFirst(4)) }
        if ref.hasPrefix("@") { ref = String(ref.dropFirst()) }
        if ref.hasPrefix("["), ref.hasSuffix("]") { ref = String(ref.dropFirst().dropLast()) }
        return ref
    }

    public func resolve(_ raw: String) throws -> BrowserElementRef {
        let id = Self.normalizeRef(raw)
        guard let snapshot = lastSnapshot else {
            throw BrowserError.staleRef(id, available: 0)
        }
        guard let ref = snapshot.refs[id] else {
            throw BrowserError.staleRef(id, available: snapshot.refs.count)
        }
        return ref
    }

    // MARK: - Deterministic actions

    /// Runs one action against the current ref table.
    public func perform(_ action: BrowserAction, variables: [String: String] = [:]) async throws -> String {
        let driver = try await driver()
        let resolvedAction = Self.substitute(variables, in: action)
        var ref: BrowserElementRef?
        if let elementID = resolvedAction.elementID, !elementID.isEmpty {
            ref = try resolve(elementID)
        } else if resolvedAction.method.requiresElement {
            throw BrowserError.elementNotInteractable("\(resolvedAction.method.rawValue) needs a ref")
        }
        var target: BrowserElementRef?
        if resolvedAction.method == .dragAndDrop {
            guard let targetID = resolvedAction.arguments.first else {
                throw BrowserError.elementNotInteractable("dragAndDrop needs the target ref as its first argument")
            }
            target = try resolve(targetID)
        }
        let readOnly = [.scrollTo, .nextChunk, .prevChunk, .hover].contains(resolvedAction.method)
        if readOnly {
            if let authorization = ActionAuthorization.current { try await authorization.consumeAction() }
            guard let expected = lastSnapshot else { throw BrowserError.staleRef("page", available: 0) }
            guard try await pageMatches(driver, expected: expected, options: lastSnapshotOptions, tabID: lastSnapshotTabID) else {
                throw ActionAuthorizationError.staleTarget
            }
        } else if driver.kind == .accessibility, [.fill, .type, .press].contains(resolvedAction.method) {
            guard let expected = lastSnapshot else { throw BrowserError.staleRef("page", available: 0) }
            let text = resolvedAction.method == .press
                ? "Key: \(resolvedAction.arguments.first ?? "Enter")"
                : resolvedAction.arguments.first ?? ""
            let keyRequest = KeystrokeApproval.request(
                tool: "browser_act",
                title: resolvedAction.method == .press ? "Press a key in the browser" : "Type in the browser",
                keystrokes: text,
                app: KeystrokeApproval.frontmostAppName())
            let detail = keyRequest.detail
                + "\nPage: \(ApprovalText.visible(expected.title))"
                + "\nURL: \(ApprovalText.visible(expected.url))"
                + "\nElement: \(ApprovalText.visible(ref?.name ?? ref?.id ?? "unknown"))"
            if ActionAuthorization.current != nil {
                try await authorizeCurrentPage(operation: resolvedAction.method.rawValue, details: detail)
            } else {
                let request = ToolApprovalRequest(toolName: keyRequest.toolName, title: keyRequest.title,
                                                  detail: detail, warning: keyRequest.warning)
                if let refusal = await keystrokeApprover.gate(request) { return refusal }
                guard try await pageMatches(driver, expected: expected, options: lastSnapshotOptions, tabID: lastSnapshotTabID) else {
                    throw ActionAuthorizationError.staleTarget
                }
            }
        } else {
            let detail: String
            if driver.kind == .accessibility, [.fill, .type, .press].contains(resolvedAction.method) {
                let text = resolvedAction.method == .press
                    ? "Key: \(resolvedAction.arguments.first ?? "Enter")"
                    : resolvedAction.arguments.first ?? ""
                let keyRequest = KeystrokeApproval.request(
                    tool: "browser_act",
                    title: resolvedAction.method == .press ? "Press a key in the browser" : "Type in the browser",
                    keystrokes: text,
                    app: KeystrokeApproval.frontmostAppName())
                detail = keyRequest.detail
                    + "\nPage: \(ApprovalText.visible(lastSnapshot?.title ?? "unknown"))"
                    + "\nURL: \(ApprovalText.visible(lastSnapshot?.url ?? "unknown"))"
                    + "\nElement: \(ApprovalText.visible(ref?.name ?? ref?.id ?? "unknown"))"
            } else {
                detail = "Element: \(ref?.name ?? ref?.id ?? "focused element")\nArguments: \(resolvedAction.arguments)"
            }
            try await authorizeCurrentPage(operation: resolvedAction.method.rawValue,
                details: detail)
        }
        try Task.checkCancellation()
        guard resolvedAction.method != .press else {
            throw BrowserError.elementNotInteractable("Keyboard focus cannot be bound to this page snapshot; use a referenced element action instead.")
        }
        return try await driver.perform(resolvedAction, ref: ref, target: target)
    }

    private func pageMatches(_ driver: any BrowserDriving, expected: BrowserSnapshot,
                             options: BrowserSnapshotOptions, tabID: String?) async throws -> Bool {
        let tab = try await driver.tabs().first(where: \.isActive)?.id
        let fresh = try await driver.snapshot(options: options)
        return tab == tabID && fresh.url == expected.url && fresh.title == expected.title
            && fresh.refs == expected.refs && fresh.outline == expected.outline
    }

    public func authorizeCurrentPage(operation: String, details: String) async throws {
        let driver = try await driver()
        let expected: BrowserSnapshot
        if let known = lastSnapshot { expected = known }
        else { expected = try await snapshot() }
        let options = lastSnapshotOptions
        let tabID = lastSnapshotTabID
        try await ActionAuthorization.requireApproval(operation: "Browser: " + operation,
            target: "\(expected.title) — \(expected.url) (tab \(tabID ?? "unknown"))", details: details,
            revalidate: {
                try await self.pageMatches(driver, expected: expected, options: options, tabID: tabID)
            })
    }

    // MARK: - observe / act / extract pipeline

    public func observe(instruction: String?) async throws -> [BrowserInference.ObservedElement] {
        let inference = try requireInference()
        let snapshot = try await snapshot()
        let found = try await inference.observe(instruction: instruction, outline: snapshot.outline)
        // Only report ids that resolve — the model occasionally invents one.
        return found.filter { snapshot.refs[$0.elementID] != nil }
    }

    /// Natural-language action with two safety nets: a second
    /// inference on the diff when the first step opened something (custom
    /// dropdowns), and a self-heal re-inference when the chosen element
    /// cannot be acted on.
    public func act(instruction: String, variables: [String: String] = [:], selfHeal: Bool = true) async throws -> BrowserActionOutcome {
        let inference = try requireInference()
        let snapshot = try await snapshot()
        let decision = try await inference.act(instruction: Self.mentionVariables(variables, in: instruction), outline: snapshot.outline)

        guard let first = decision.action else {
            return BrowserActionOutcome(success: false, message: "No element on the page matches \"\(instruction)\". Take a snapshot to see what is available.")
        }

        var healed = false
        var message: String
        var performed: [BrowserAction] = [first]
        do {
            message = try await perform(first, variables: variables)
        } catch {
            if error is ActionAuthorizationError || error is CancellationError { throw error }
            guard selfHeal else { throw error }
            log.info("Action failed (\(self.describe(error), privacy: .public)); re-observing the page")
            let fresh = try await self.snapshot()
            let retryInstruction = first.description.isEmpty ? instruction : "\(first.method.rawValue) \(first.description)"
            let retry = try await inference.act(instruction: retryInstruction, outline: fresh.outline)
            guard let healedAction = retry.action else {
                return BrowserActionOutcome(success: false, message: "Failed to perform \"\(instruction)\": \(describe(error)); the element could not be found again after the page changed.")
            }
            message = try await perform(healedAction, variables: variables)
            performed = [healedAction]
            healed = true
        }

        guard decision.twoStep else {
            return BrowserActionOutcome(success: true, message: message, actions: performed, selfHealed: healed)
        }

        // Step two: show the model only what the first step revealed.
        let after = try await self.snapshot()
        let changed = AccessibilityOutline.diff(previous: snapshot.outline, next: after.outline)
        let secondDecision = try await inference.act(
            instruction: instruction,
            outline: changed.isEmpty ? after.outline : changed,
            secondStepAfter: first,
            originalInstruction: instruction)
        guard let second = secondDecision.action else {
            return BrowserActionOutcome(success: true, message: "\(message) (no second step found)", actions: performed, selfHealed: healed)
        }
        let secondMessage = try await perform(second, variables: variables)
        return BrowserActionOutcome(success: true, message: "\(message) → \(secondMessage)", actions: performed + [second], selfHealed: healed)
    }

    public func extract(instruction: String, schema: Data?) async throws -> String {
        let inference = try requireInference()
        let snapshot = try await snapshot()
        return try await inference.extract(instruction: instruction, outline: snapshot.outline, schema: schema)
    }

    // MARK: - Helpers

    private func requireInference() throws -> BrowserInference {
        guard let inference else {
            throw BrowserError.unsupportedAction("natural-language browser actions need a language model; use browser_snapshot and browser_element instead")
        }
        return inference
    }

    /// Replaces `%name%` placeholders so secret values never enter a prompt.
    static func substitute(_ variables: [String: String], in action: BrowserAction) -> BrowserAction {
        guard !variables.isEmpty else { return action }
        var copy = action
        copy.arguments = action.arguments.map { argument in
            var output = argument
            for (key, value) in variables {
                output = output.replacingOccurrences(of: "%\(key)%", with: value)
            }
            return output
        }
        return copy
    }

    static func mentionVariables(_ variables: [String: String], in instruction: String) -> String {
        guard !variables.isEmpty else { return instruction }
        let names = variables.keys.sorted().map { "%\($0)%" }.joined(separator: ", ")
        return """
            \(instruction)
            The user has provided the following variables to be used in the action: \(names). \
            These are variable names, not values. To use one, put the name wrapped in percent signs \
            (e.g. %variableNameHere%) in the arguments array and it will be replaced before the action runs.
            """
    }

    private func describe(_ error: Error) -> String {
        if let browserError = error as? BrowserError { return browserError.description }
        if let cdpError = error as? CDPError { return cdpError.description }
        return error.localizedDescription
    }
}
