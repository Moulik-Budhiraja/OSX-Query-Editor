import AppKit
import AXorcist
import Foundation

@MainActor
final class SelectorQueryService {
    private let setValueSubmitStepDelaySeconds: TimeInterval = 0.2
    private let sendKeystrokesSubmitStepDelaySeconds: TimeInterval = 0.3
    private let postActivationClickDelaySeconds: TimeInterval = 0.2
    private let textInputFocusRetryDelaySeconds: TimeInterval = 0.2
    private let textInputFocusRetryMaxAttempts = 7

    func run(
        request: QueryRequest,
        interaction: QueryInteractionRequest? = nil) throws -> QueryExecutionResult
    {
        let appIdentifier = request.appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let selector = request.selector.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !appIdentifier.isEmpty else {
            throw QueryWorkbenchError.missingAppIdentifier
        }
        guard !selector.isEmpty else {
            throw QueryWorkbenchError.missingSelector
        }
        guard request.maxDepth > 0 else {
            throw QueryWorkbenchError.invalidMaxDepth
        }

        guard let root = try self.resolveRootElement(appIdentifier: appIdentifier) else {
            throw QueryWorkbenchError.applicationNotFound(appIdentifier)
        }

        let childrenProvider: (Element) -> [Element] = { element in
            element.children(strict: false, includeApplicationExtras: element == root) ?? []
        }
        let roleProvider: (Element) -> String? = { element in
            element.role()
        }
        let attributeValueProvider: (Element, String) -> String? = { element, attributeName in
            Self.stringValue(for: element, attributeName: attributeName)
        }

        let selectorEngine = OXQSelectorEngine<Element>(
            children: childrenProvider,
            role: roleProvider,
            attributeValue: attributeValueProvider)

        let memoizationContext = OXQQueryMemoizationContext<Element>(
            childrenProvider: childrenProvider,
            roleProvider: roleProvider,
            attributeValueProvider: attributeValueProvider)

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let evaluation = try selectorEngine.findAllWithMetrics(
            matching: selector,
            from: root,
            maxDepth: request.maxDepth,
            memoizationContext: memoizationContext)

        if let interaction {
            try self.performInteraction(
                interaction,
                matchedElements: evaluation.matches)
        }

        let rows = evaluation.matches.enumerated().map { index, element in
            self.buildRow(
                element: element,
                index: index + 1,
                memoizationContext: memoizationContext)
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000.0

        return QueryExecutionResult(
            stats: QueryStats(
                elapsedMilliseconds: elapsedMs,
                traversedCount: evaluation.traversedNodeCount,
                matchedCount: evaluation.matches.count,
                appIdentifier: appIdentifier,
                selector: selector),
            rows: rows)
    }

    private func buildRow(
        element: Element,
        index: Int,
        memoizationContext: OXQQueryMemoizationContext<Element>) -> QueryResultRow
    {
        let computedNameDetails = element.computedNameDetails()
        let role = element.role() ?? "AXUnknown"

        let computedName = Self.normalize(computedNameDetails?.value)
        let computedNameSource = Self.normalize(computedNameDetails?.source)
        let title = Self.normalize(element.title())
        let value = Self.normalize(Self.preferredValueString(for: element))
        let identifier = Self.normalize(element.identifier())
        let descriptionText = Self.normalize(element.descriptionText())
        let path = Self.normalize(element.generatePathString())

        let resultName: String
        let resultNameSource: String?
        if role == AXRoleNames.kAXStaticTextRole, let value {
            resultName = value
            resultNameSource = value != computedName ? AXAttributeNames.kAXValueAttribute : computedNameSource
        } else {
            resultName = computedName ?? ""
            resultNameSource = computedNameSource
        }

        let resultValue: String?
        if value == resultName {
            resultValue = nil
        } else {
            resultValue = value
        }

        let enabled = Self.parseBool(
            memoizationContext.attributeValue(of: element, attributeName: AXAttributeNames.kAXEnabledAttribute))
        let focused = Self.parseBool(
            memoizationContext.attributeValue(of: element, attributeName: AXAttributeNames.kAXFocusedAttribute))

        return QueryResultRow(
            id: index,
            index: index,
            role: role,
            frame: Self.visibleFrame(for: element),
            name: resultName,
            nameSource: resultNameSource,
            title: title,
            value: resultValue,
            identifier: identifier,
            descriptionText: descriptionText,
            enabled: enabled,
            focused: focused,
            childCount: memoizationContext.children(of: element).count,
            path: path)
    }

    private static func visibleFrame(for element: Element) -> CGRect? {
        guard let frame = element.frame()?.standardized else {
            return nil
        }

        guard
            frame.origin.x.isFinite,
            frame.origin.y.isFinite,
            frame.size.width.isFinite,
            frame.size.height.isFinite,
            frame.size.width > 1,
            frame.size.height > 1
        else {
            return nil
        }

        return frame
    }

    private func performInteraction(
        _ interaction: QueryInteractionRequest,
        matchedElements: [Element]) throws
    {
        guard interaction.resultIndex > 0, interaction.resultIndex <= matchedElements.count else {
            throw QueryWorkbenchError.interactionTargetOutOfBounds(
                index: interaction.resultIndex,
                matchedCount: matchedElements.count)
        }

        let targetElement = matchedElements[interaction.resultIndex - 1]

        let succeeded: Bool
        switch interaction.action {
        case .click:
            succeeded = self.clickElement(targetElement)

        case .press:
            succeeded = targetElement.press()

        case .focus:
            succeeded = self.focusElement(targetElement)

        case .setValue:
            guard let value = interaction.value, !value.isEmpty else {
                throw QueryWorkbenchError.interactionValueRequired(.setValue)
            }
            succeeded = targetElement.setValue(value, forAttribute: AXAttributeNames.kAXValueAttribute)

        case .setValueSubmit:
            guard let value = interaction.value, !value.isEmpty else {
                throw QueryWorkbenchError.interactionValueRequired(.setValueSubmit)
            }

            guard self.clickForSetValueSubmit(targetElement) else {
                succeeded = false
                break
            }

            Thread.sleep(forTimeInterval: self.setValueSubmitStepDelaySeconds)
            guard targetElement.setValue(value, forAttribute: AXAttributeNames.kAXValueAttribute) else {
                succeeded = false
                break
            }

            Thread.sleep(forTimeInterval: self.setValueSubmitStepDelaySeconds)
            do {
                try Element.typeKey(.return)
                succeeded = true
            } catch {
                succeeded = false
            }

        case .sendKeystrokesSubmit:
            guard let value = interaction.value, !value.isEmpty else {
                throw QueryWorkbenchError.interactionValueRequired(.sendKeystrokesSubmit)
            }

            guard self.clickForSendKeystrokesSubmit(targetElement) else {
                succeeded = false
                break
            }

            Thread.sleep(forTimeInterval: self.sendKeystrokesSubmitStepDelaySeconds)
            do {
                try Element.typeText(value, delay: 0)
            } catch {
                succeeded = false
                break
            }

            Thread.sleep(forTimeInterval: self.sendKeystrokesSubmitStepDelaySeconds)
            do {
                try Element.typeKey(.return, modifiers: [.maskCommand])
                succeeded = true
            } catch {
                succeeded = false
            }
        }

        guard succeeded else {
            throw QueryWorkbenchError.interactionFailed(
                action: interaction.action.rawValue,
                index: interaction.resultIndex)
        }
    }

    private func resolveRootElement(appIdentifier: String) throws -> Element? {
        let normalizedIdentifier = appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPID = ProcessInfo.processInfo.processIdentifier

        if normalizedIdentifier.caseInsensitiveCompare("focused") == .orderedSame,
           let frontmost = RunningApplicationHelper.frontmostApplication
        {
            if frontmost.processIdentifier != currentPID {
                FocusedApplicationTracker.shared.remember(frontmost)
                return getApplicationElement(for: frontmost.processIdentifier)
            }

            if let priorExternal = FocusedApplicationTracker.shared.lastExternalApplication {
                return getApplicationElement(for: priorExternal.processIdentifier)
            }

            throw QueryWorkbenchError.focusedAppUnavailable
        }

        if let pid = pid_t(normalizedIdentifier) {
            return try self.getApplicationElementRejectingSelf(for: pid)
        }

        if let directBundleMatch = getApplicationElement(for: normalizedIdentifier) {
            if directBundleMatch.pid() == currentPID {
                throw QueryWorkbenchError.selfTargetUnsupported
            }
            return directBundleMatch
        }

        guard let app = self.findRunningApplication(matching: normalizedIdentifier) else {
            return nil
        }

        return try self.getApplicationElementRejectingSelf(for: app.processIdentifier)
    }

    private func findRunningApplication(matching identifier: String) -> NSRunningApplication? {
        let normalized = identifier.lowercased()

        return RunningApplicationHelper.allApplications().first { app in
            let bundleMatch = app.bundleIdentifier?.lowercased() == normalized
            let nameMatch = app.localizedName?.lowercased() == normalized
            return bundleMatch || nameMatch
        }
    }

    private func getApplicationElementRejectingSelf(for pid: pid_t) throws -> Element? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if pid == currentPID {
            throw QueryWorkbenchError.selfTargetUnsupported
        }
        return getApplicationElement(for: pid)
    }

    private static func stringValue(for element: Element, attributeName: String) -> String? {
        let canonicalName = PathUtils.attributeKeyMappings[attributeName.lowercased()] ?? attributeName

        switch canonicalName {
        case AXAttributeNames.kAXRoleAttribute:
            return element.role()
        case AXAttributeNames.kAXSubroleAttribute:
            return element.subrole()
        case AXAttributeNames.kAXPIDAttribute:
            return element.pid().map(String.init)
        case AXAttributeNames.kAXTitleAttribute:
            return element.title()
        case AXAttributeNames.kAXDescriptionAttribute:
            return element.descriptionText()
        case AXAttributeNames.kAXHelpAttribute:
            return element.help()
        case AXAttributeNames.kAXIdentifierAttribute:
            return element.identifier()
        case AXAttributeNames.kAXRoleDescriptionAttribute:
            return element.roleDescription()
        case AXAttributeNames.kAXPlaceholderValueAttribute:
            return element.attribute(Attribute<String>(AXAttributeNames.kAXPlaceholderValueAttribute))
        case AXAttributeNames.kAXEnabledAttribute:
            return element.isEnabled().map { $0 ? "true" : "false" }
        case AXAttributeNames.kAXFocusedAttribute:
            return element.isFocused().map { $0 ? "true" : "false" }
        case AXAttributeNames.kAXValueAttribute:
            return Self.stringify(element.value())
        case AXMiscConstants.computedNameAttributeKey:
            return element.computedName()
        case AXMiscConstants.isIgnoredAttributeKey:
            return element.isIgnored() ? "true" : "false"
        default:
            break
        }

        guard let rawValue: Any = element.attribute(Attribute<Any>(canonicalName)) else {
            return nil
        }
        return Self.stringify(rawValue)
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return nil
        }
    }

    private func focusElement(_ element: Element) -> Bool {
        if element.setValue(true, forAttribute: AXAttributeNames.kAXFocusedAttribute) {
            return true
        }
        if element.press() {
            return true
        }
        return self.clickElement(element)
    }

    private func clickElement(_ element: Element) -> Bool {
        if self.activateOwningApplication(for: element) {
            Thread.sleep(forTimeInterval: self.postActivationClickDelaySeconds)
        }
        return ((try? element.click()) != nil)
    }

    private func activateOwningApplication(for element: Element) -> Bool {
        guard let pid = self.owningPID(for: element) else {
            return false
        }

        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return false
        }

        if app.isActive {
            return true
        }

        return app.activate(options: [.activateAllWindows])
    }

    private func owningPID(for element: Element) -> pid_t? {
        if let pid = element.pid(), pid > 0 {
            return pid
        }

        var current = element.parent()
        var depth = 0
        while let candidate = current, depth < 256 {
            if let pid = candidate.pid(), pid > 0 {
                return pid
            }
            current = candidate.parent()
            depth += 1
        }

        return nil
    }

    private func clickForSetValueSubmit(_ element: Element) -> Bool {
        if self.shouldRetryFocusClicks(for: element) {
            return self.clickUntilFocused(element)
        }
        return self.clickElement(element)
    }

    private func clickForSendKeystrokesSubmit(_ element: Element) -> Bool {
        if self.shouldRetryFocusClicks(for: element) {
            return self.clickUntilFocused(element)
        }

        guard self.clickElement(element) else {
            return false
        }
        Thread.sleep(forTimeInterval: self.sendKeystrokesSubmitStepDelaySeconds)
        return self.clickElement(element)
    }

    private func clickUntilFocused(_ element: Element) -> Bool {
        if self.activateOwningApplication(for: element) {
            Thread.sleep(forTimeInterval: self.postActivationClickDelaySeconds)
        }

        for attempt in 1...self.textInputFocusRetryMaxAttempts {
            guard ((try? element.click()) != nil) else {
                if attempt < self.textInputFocusRetryMaxAttempts {
                    Thread.sleep(forTimeInterval: self.textInputFocusRetryDelaySeconds)
                }
                continue
            }

            if element.isFocused() == true {
                return true
            }

            if attempt < self.textInputFocusRetryMaxAttempts {
                Thread.sleep(forTimeInterval: self.textInputFocusRetryDelaySeconds)
            }
        }

        return false
    }

    private func shouldRetryFocusClicks(for element: Element) -> Bool {
        guard let role = element.role() else {
            return false
        }

        switch role {
        case AXRoleNames.kAXComboBoxRole, AXRoleNames.kAXTextFieldRole, AXRoleNames.kAXTextAreaRole:
            return true
        default:
            return false
        }
    }

    private static func normalize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if Self.isNullLikeString(trimmed) {
            return nil
        }
        return trimmed
    }

    private static func stringify(_ value: Any?) -> String? {
        guard let value else { return nil }

        if let string = value as? String {
            return Self.isNullLikeString(string) ? nil : string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let strings = value as? [String] {
            return strings.joined(separator: ",")
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { Self.stringify($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ",")
        }

        let described = String(describing: value)
        return Self.isNullLikeString(described) ? nil : described
    }

    private static func preferredValueString(for element: Element) -> String? {
        if let directValue: String = element.attribute(Attribute<String>(AXAttributeNames.kAXValueAttribute)) {
            return directValue
        }

        if let normalizedValue = Self.stringify(element.value()) {
            return normalizedValue
        }

        if let selectedText = element.selectedText() {
            return selectedText
        }

        return nil
    }

    private static func isNullLikeString(_ value: String) -> Bool {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return token == "nil" ||
            token == "null" ||
            token == "(null)" ||
            token == "<null>" ||
            token == "optional(nil)"
    }
}

@MainActor
private final class FocusedApplicationTracker {
    static let shared = FocusedApplicationTracker()

    private var activationObserver: NSObjectProtocol?
    private(set) var lastExternalApplication: NSRunningApplication?

    private init() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = RunningApplicationHelper.frontmostApplication,
           frontmost.processIdentifier != selfPID
        {
            self.lastExternalApplication = frontmost
        }

        self.activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main)
        { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else {
                return
            }
            Task { @MainActor [weak self] in
                self?.remember(app)
            }
        }
    }

    func remember(_ app: NSRunningApplication) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard app.processIdentifier != selfPID, !app.isTerminated else {
            return
        }
        self.lastExternalApplication = app
    }
}
