import AppKit
import AXorcist
import ApplicationServices
import Foundation

@MainActor
final class SelectorQueryService {
    private struct SelectorPrefetchSnapshot {
        let root: Element
        let appPID: pid_t?
        let maxDepth: Int
        let childrenByElement: [Element: [Element]]
        let parentByElement: [Element: Element]
        let roleByElement: [Element: String]
        let attributeValuesByElement: [Element: [String: String]]
        let prefetchedAttributeNames: Set<String>
    }

    private struct QueryExecutionContext {
        let root: Element
        let snapshot: SelectorPrefetchSnapshot
        let selectorEngine: OXQSelectorEngine<Element>
        let memoizationContext: OXQQueryMemoizationContext<Element>
        let isWarmCached: Bool
    }

    private struct WarmCacheState {
        let appIdentifier: String
        let snapshot: SelectorPrefetchSnapshot
    }

    private let setValueSubmitStepDelaySeconds: TimeInterval = 0.2
    private let sendKeystrokesSubmitStepDelaySeconds: TimeInterval = 0.3
    private let postActivationClickDelaySeconds: TimeInterval = 0.2
    private let textInputFocusRetryDelaySeconds: TimeInterval = 0.2
    private let textInputFocusRetryMaxAttempts = 7
    private var warmCacheState: WarmCacheState?

    func run(
        request: QueryRequest,
        mode: QueryExecutionMode = .liveRefresh,
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

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let syntaxTree = try OXQParser().parse(selector)
        let requiredAttributeNames = Self.prefetchAttributeNames(for: syntaxTree)
        let executionMode: QueryExecutionMode = interaction == nil ? mode : .liveRefresh
        let context: QueryExecutionContext
        if executionMode == .useWarmCache,
           let warmSnapshot = self.usableWarmCache(
               for: appIdentifier,
               maxDepth: request.maxDepth,
               requiredAttributeNames: requiredAttributeNames)
        {
            context = self.makeExecutionContext(from: warmSnapshot, isWarmCached: true)
        } else {
            guard let root = try self.resolveRootElement(appIdentifier: appIdentifier) else {
                throw QueryWorkbenchError.applicationNotFound(appIdentifier)
            }

            let freshSnapshot = self.prefetchSnapshot(
                root: root,
                maxDepth: request.maxDepth,
                attributeNames: requiredAttributeNames)
            context = self.makeExecutionContext(from: freshSnapshot, isWarmCached: false)
        }

        let evaluation = context.selectorEngine.findAllWithMetrics(
            matching: syntaxTree,
            from: context.root,
            maxDepth: request.maxDepth,
            memoizationContext: context.memoizationContext)

        if let interaction {
            try self.performInteraction(
                interaction,
                matchedElements: evaluation.matches)
            self.invalidateWarmCache()
        }

        let rows = evaluation.matches.enumerated().map { index, element in
            self.buildRow(
                element: element,
                index: index + 1,
                memoizationContext: context.memoizationContext,
                snapshot: context.snapshot,
                useLiveFrame: !context.isWarmCached)
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000.0

        if interaction == nil, !context.isWarmCached {
            self.warmCacheState = WarmCacheState(
                appIdentifier: Self.cacheKey(for: appIdentifier),
                snapshot: context.snapshot)
        }

        return QueryExecutionResult(
            stats: QueryStats(
                elapsedMilliseconds: elapsedMs,
                usedWarmCache: context.isWarmCached,
                traversedCount: evaluation.traversedNodeCount,
                matchedCount: evaluation.matches.count,
                appIdentifier: appIdentifier,
                selector: selector),
            rows: rows)
    }

    func warmCache(request: QueryRequest) throws {
        let appIdentifier = request.appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appIdentifier.isEmpty else {
            throw QueryWorkbenchError.missingAppIdentifier
        }
        guard request.maxDepth > 0 else {
            throw QueryWorkbenchError.invalidMaxDepth
        }

        guard let root = try self.resolveRootElement(appIdentifier: appIdentifier) else {
            throw QueryWorkbenchError.applicationNotFound(appIdentifier)
        }

        let warmupSyntaxTree = try OXQParser().parse("*")
        let requiredAttributeNames = Self.prefetchAttributeNames(for: warmupSyntaxTree)
        let snapshot = self.prefetchSnapshot(
            root: root,
            maxDepth: request.maxDepth,
            attributeNames: requiredAttributeNames)
        self.warmCacheState = WarmCacheState(
            appIdentifier: Self.cacheKey(for: appIdentifier),
            snapshot: snapshot)
    }

    func invalidateWarmCache() {
        self.warmCacheState = nil
    }

    private func makeExecutionContext(
        from snapshot: SelectorPrefetchSnapshot,
        isWarmCached: Bool) -> QueryExecutionContext
    {
        let childrenProvider: (Element) -> [Element] = { element in
            snapshot.childrenByElement[element] ?? []
        }
        let roleProvider: (Element) -> String? = { element in
            snapshot.roleByElement[element] ??
                snapshot.attributeValuesByElement[element]?[AXAttributeNames.kAXRoleAttribute]
        }
        let attributeValueProvider: (Element, String) -> String? = { element, attributeName in
            let canonicalName = Self.canonicalAttributeName(attributeName)
            if let prefetched = snapshot.attributeValuesByElement[element]?[canonicalName] {
                return prefetched
            }
            if snapshot.prefetchedAttributeNames.contains(canonicalName) {
                return nil
            }
            return Self.stringValue(for: element, attributeName: canonicalName)
        }

        let selectorEngine = OXQSelectorEngine<Element>(
            children: childrenProvider,
            role: roleProvider,
            attributeValue: attributeValueProvider)

        let memoizationContext = OXQQueryMemoizationContext<Element>(
            childrenProvider: childrenProvider,
            roleProvider: roleProvider,
            attributeValueProvider: attributeValueProvider,
            preferDerivedComputedName: true)

        return QueryExecutionContext(
            root: snapshot.root,
            snapshot: snapshot,
            selectorEngine: selectorEngine,
            memoizationContext: memoizationContext,
            isWarmCached: isWarmCached)
    }

    private func usableWarmCache(
        for appIdentifier: String,
        maxDepth: Int,
        requiredAttributeNames: Set<String>) -> SelectorPrefetchSnapshot?
    {
        guard let warmCacheState else { return nil }
        guard warmCacheState.appIdentifier == Self.cacheKey(for: appIdentifier) else { return nil }
        guard warmCacheState.snapshot.maxDepth >= maxDepth else { return nil }
        guard warmCacheState.snapshot.prefetchedAttributeNames.isSuperset(of: requiredAttributeNames) else {
            return nil
        }

        if let currentPID = self.resolveCurrentAppPID(for: appIdentifier),
           let cachedPID = warmCacheState.snapshot.appPID,
           currentPID != cachedPID
        {
            return nil
        }

        return warmCacheState.snapshot
    }

    private func resolveCurrentAppPID(for appIdentifier: String) -> pid_t? {
        let normalizedIdentifier = appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPID = ProcessInfo.processInfo.processIdentifier

        if normalizedIdentifier.caseInsensitiveCompare("focused") == .orderedSame {
            if let frontmost = RunningApplicationHelper.frontmostApplication,
               frontmost.processIdentifier != currentPID
            {
                return frontmost.processIdentifier
            }
            return FocusedApplicationTracker.shared.lastExternalApplication?.processIdentifier
        }

        if let pid = pid_t(normalizedIdentifier) {
            return pid
        }

        return self.findRunningApplication(matching: normalizedIdentifier)?.processIdentifier
    }

    private static func cacheKey(for appIdentifier: String) -> String {
        appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func buildRow(
        element: Element,
        index: Int,
        memoizationContext: OXQQueryMemoizationContext<Element>,
        snapshot: SelectorPrefetchSnapshot,
        useLiveFrame: Bool) -> QueryResultRow
    {
        let computedNameDetails = memoizationContext.computedNameDetails(of: element)
        let role = memoizationContext.role(of: element) ?? "AXUnknown"

        let computedName = Self.normalize(computedNameDetails?.value)
        let computedNameSource = Self.normalize(computedNameDetails?.source)
        let title = Self.normalize(memoizationContext.attributeValue(of: element, attributeName: AXAttributeNames.kAXTitleAttribute))
        let value = Self.normalize(Self.preferredValueString(for: element, memoizationContext: memoizationContext))
        let identifier = Self.normalize(
            memoizationContext.attributeValue(of: element, attributeName: AXAttributeNames.kAXIdentifierAttribute))
        let descriptionText = Self.normalize(
            memoizationContext.attributeValue(of: element, attributeName: AXAttributeNames.kAXDescriptionAttribute))
        let path = Self.normalize(Self.cachedPathString(for: element, snapshot: snapshot))

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
            frame: useLiveFrame ? Self.visibleFrame(for: element) : nil,
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

    private static func cachedPathString(for element: Element, snapshot: SelectorPrefetchSnapshot) -> String {
        var chain: [Element] = []
        var visited = Set<Element>()
        var current: Element? = element

        while let node = current, visited.insert(node).inserted {
            chain.append(node)
            current = snapshot.parentByElement[node]
        }

        return chain.reversed().map { node in
            var parts: [String] = []
            let role = snapshot.roleByElement[node] ??
                snapshot.attributeValuesByElement[node]?[AXAttributeNames.kAXRoleAttribute] ??
                "AXUnknown"
            parts.append("Role: \(role)")

            if let title = snapshot.attributeValuesByElement[node]?[AXAttributeNames.kAXTitleAttribute], !title.isEmpty {
                parts.append("Title: '\(title)'")
            }

            if let identifier = snapshot.attributeValuesByElement[node]?[AXAttributeNames.kAXIdentifierAttribute],
               !identifier.isEmpty
            {
                parts.append("ID: '\(identifier)'")
            }

            return parts.joined(separator: ", ")
        }.joined(separator: " -> ")
    }

    private func prefetchSnapshot(
        root: Element,
        maxDepth: Int,
        attributeNames: Set<String>) -> SelectorPrefetchSnapshot
    {
        let safeMaxDepth = max(0, maxDepth)
        let orderedAttributeNames = Array(attributeNames).sorted()

        var childrenByElement: [Element: [Element]] = [:]
        var parentByElement: [Element: Element] = [:]
        var roleByElement: [Element: String] = [:]
        var attributeValuesByElement: [Element: [String: String]] = [:]
        var bestDepthByElement: [Element: Int] = [:]
        var stack: [(element: Element, depth: Int, parent: Element?)] = [(root, 0, nil)]

        while let entry = stack.popLast() {
            let element = entry.element
            let depth = entry.depth

            if let parent = entry.parent {
                parentByElement[element] = parent
            }

            if let bestDepth = bestDepthByElement[element], depth >= bestDepth {
                continue
            }

            bestDepthByElement[element] = depth

            let prefetchedAttributes = Self.batchFetchAttributeValues(
                for: element,
                attributeNames: orderedAttributeNames)
            var attributes = attributeValuesByElement[element] ?? [:]
            if !prefetchedAttributes.isEmpty {
                attributes.merge(prefetchedAttributes) { _, new in new }
            }
            attributeValuesByElement[element] = attributes

            if let role = prefetchedAttributes[AXAttributeNames.kAXRoleAttribute] ??
                Self.stringValue(for: element, attributeName: AXAttributeNames.kAXRoleAttribute)
            {
                roleByElement[element] = role
                var currentAttributes = attributeValuesByElement[element] ?? [:]
                currentAttributes[AXAttributeNames.kAXRoleAttribute] = role
                attributeValuesByElement[element] = currentAttributes
            }

            let children: [Element]
            if depth < safeMaxDepth {
                children = element.children(strict: false, includeApplicationExtras: element == root) ?? []
            } else {
                children = []
            }

            childrenByElement[element] = children
            for child in children.reversed() {
                stack.append((child, depth + 1, element))
            }
        }

        return SelectorPrefetchSnapshot(
            root: root,
            appPID: Self.axPid(for: root),
            maxDepth: safeMaxDepth,
            childrenByElement: childrenByElement,
            parentByElement: parentByElement,
            roleByElement: roleByElement,
            attributeValuesByElement: attributeValuesByElement,
            prefetchedAttributeNames: attributeNames)
    }

    private static func batchFetchAttributeValues(
        for element: Element,
        attributeNames: [String]) -> [String: String]
    {
        guard !attributeNames.isEmpty else {
            return [:]
        }

        let cfAttributeNames = attributeNames.map { $0 as CFString } as CFArray
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element.underlyingElement,
            cfAttributeNames,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values)

        guard status == .success, let rawValues = values as? [Any] else {
            var fallbackValues: [String: String] = [:]
            for name in attributeNames {
                if let value = Self.stringValue(for: element, attributeName: name) {
                    fallbackValues[name] = value
                }
            }
            return fallbackValues
        }

        var result: [String: String] = [:]
        let pairCount = min(attributeNames.count, rawValues.count)
        for index in 0..<pairCount {
            let name = attributeNames[index]
            if let value = Self.stringifyBatchAttributeValue(rawValues[index]) {
                result[name] = value
            }
        }

        if rawValues.count < attributeNames.count {
            for name in attributeNames[rawValues.count...] {
                if let value = Self.stringValue(for: element, attributeName: name) {
                    result[name] = value
                }
            }
        }

        return result
    }

    private static func stringifyBatchAttributeValue(_ value: Any) -> String? {
        if value is NSNull {
            return nil
        }

        let object = value as AnyObject
        let typeRef = object as CFTypeRef
        if CFGetTypeID(typeRef) == AXValueGetTypeID() {
            let axValue = unsafeDowncast(object, to: AXValue.self)
            if AXValueGetType(axValue) == .axError {
                return nil
            }
        }

        return Self.stringify(value)
    }

    private static func prefetchAttributeNames(for syntaxTree: OXQSyntaxTree) -> Set<String> {
        var names: Set<String> = [
            AXAttributeNames.kAXRoleAttribute,
            AXAttributeNames.kAXTitleAttribute,
            AXAttributeNames.kAXValueAttribute,
            AXAttributeNames.kAXIdentifierAttribute,
            AXAttributeNames.kAXDescriptionAttribute,
            AXAttributeNames.kAXHelpAttribute,
            AXAttributeNames.kAXPlaceholderValueAttribute,
            AXAttributeNames.kAXSelectedTextAttribute,
            AXAttributeNames.kAXEnabledAttribute,
            AXAttributeNames.kAXFocusedAttribute,
            AXAttributeNames.kAXSubroleAttribute,
            AXAttributeNames.kAXPIDAttribute,
            AXAttributeNames.kAXRoleDescriptionAttribute,
        ]

        for selector in syntaxTree.selectors {
            Self.collectAttributeNames(in: selector, into: &names)
        }

        return names
    }

    private static func collectAttributeNames(in selector: OXQSelector, into names: inout Set<String>) {
        Self.collectAttributeNames(in: selector.leading, into: &names)
        for link in selector.links {
            Self.collectAttributeNames(in: link.compound, into: &names)
        }
    }

    private static func collectAttributeNames(in compound: OXQCompound, into names: inout Set<String>) {
        for attribute in compound.attributes {
            Self.collectAttributeName(attribute.name, into: &names)
        }

        for pseudo in compound.pseudos {
            switch pseudo {
            case let .not(selectors):
                for selector in selectors {
                    Self.collectAttributeNames(in: selector, into: &names)
                }
            case let .has(argument):
                switch argument {
                case let .selectors(selectors):
                    for selector in selectors {
                        Self.collectAttributeNames(in: selector, into: &names)
                    }
                case let .relativeSelectors(relativeSelectors):
                    for relativeSelector in relativeSelectors {
                        Self.collectAttributeNames(in: relativeSelector.selector, into: &names)
                    }
                }
            }
        }
    }

    private static func collectAttributeName(_ rawName: String, into names: inout Set<String>) {
        let canonicalName = Self.canonicalAttributeName(rawName)
        if canonicalName == AXMiscConstants.computedNameAttributeKey {
            names.formUnion([
                AXAttributeNames.kAXRoleAttribute,
                AXAttributeNames.kAXTitleAttribute,
                AXAttributeNames.kAXValueAttribute,
                AXAttributeNames.kAXIdentifierAttribute,
                AXAttributeNames.kAXDescriptionAttribute,
                AXAttributeNames.kAXHelpAttribute,
                AXAttributeNames.kAXPlaceholderValueAttribute,
                AXAttributeNames.kAXSelectedTextAttribute,
            ])
            return
        }

        if canonicalName == AXMiscConstants.isIgnoredAttributeKey {
            return
        }

        names.insert(canonicalName)
    }

    private static func canonicalAttributeName(_ name: String) -> String {
        PathUtils.attributeKeyMappings[name.lowercased()] ?? name
    }

    private static func axPid(for element: Element) -> pid_t? {
        if let pid = element.pid(), pid > 0 {
            return pid
        }

        var pid: pid_t = 0
        let status = AXUIElementGetPid(element.underlyingElement, &pid)
        guard status == .success, pid > 0 else {
            return nil
        }

        return pid
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
        let canonicalName = Self.canonicalAttributeName(attributeName)

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

    private static func preferredValueString(
        for element: Element,
        memoizationContext: OXQQueryMemoizationContext<Element>) -> String?
    {
        if let directValue = memoizationContext.attributeValue(
            of: element,
            attributeName: AXAttributeNames.kAXValueAttribute)
        {
            return directValue
        }

        if let selectedText = memoizationContext.attributeValue(
            of: element,
            attributeName: AXAttributeNames.kAXSelectedTextAttribute)
        {
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
