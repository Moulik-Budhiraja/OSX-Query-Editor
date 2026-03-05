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
        let frameByElement: [Element: CGRect]
        let attributeValuesByElement: [Element: [String: String]]
        let prefetchedAttributeNames: Set<String>
        let elementsByReference: [String: Element]
    }

    private struct SnapshotReferenceMetadata {
        let frameByReference: [String: CGRect]
        let parentReferenceByReference: [String: String]
        let roleByReference: [String: String]
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

    private struct BatchFetchResult {
        let stringValues: [String: String]
        let frame: CGRect?
    }

    private static let cacheReferenceAttributeName = "__axorc_ref"
    private var warmCacheState: WarmCacheState?

    func run(
        request: QueryRequest,
        mode: QueryExecutionMode = .liveRefresh) throws -> QueryExecutionResult
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

        let context: QueryExecutionContext
        if mode == .useWarmCache,
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

        let rows = evaluation.matches.enumerated().map { index, element in
            self.buildRow(
                element: element,
                index: index + 1,
                memoizationContext: context.memoizationContext,
                snapshot: context.snapshot,
                useLiveFrame: !context.isWarmCached)
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000.0

        if !context.isWarmCached {
            self.warmCacheState = WarmCacheState(
                appIdentifier: Self.cacheKey(for: appIdentifier),
                snapshot: context.snapshot)
        }

        let referenceMetadata = Self.referenceMetadata(from: context.snapshot)
        SelectorActionRefStore.replace(
            with: context.snapshot.elementsByReference,
            appPID: context.snapshot.appPID,
            frameByReference: referenceMetadata.frameByReference,
            parentReferenceByReference: referenceMetadata.parentReferenceByReference,
            roleByReference: referenceMetadata.roleByReference)

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
        SelectorActionRefStore.clear()
    }

    func inspectElementAttributes(reference: String) throws -> [QueryAttributeDetail] {
        guard let element = SelectorActionRefStore.element(for: reference) else {
            throw QueryWorkbenchError.elementReferenceUnavailable(reference)
        }

        let names = (element.attributeNames() ?? []).sorted()
        var details: [QueryAttributeDetail] = names.map { name in
            QueryAttributeDetail(
                name: name,
                value: Self.inspectedAttributeValueString(for: element, attributeName: name))
        }

        if let actions = element.supportedActions(), !actions.isEmpty {
            details.append(QueryAttributeDetail(
                name: "SupportedActions",
                value: actions.sorted().joined(separator: ", ")))
        }

        if let parameterized = Self.parameterizedAttributeNames(for: element), !parameterized.isEmpty {
            details.append(QueryAttributeDetail(
                name: "ParameterizedAttributes",
                value: parameterized.sorted().joined(separator: ", ")))
        }

        if let computedName = element.computedName(), !computedName.isEmpty {
            details.append(QueryAttributeDetail(
                name: AXMiscConstants.computedNameAttributeKey,
                value: computedName))
        }

        details.append(QueryAttributeDetail(
            name: AXMiscConstants.isIgnoredAttributeKey,
            value: element.isIgnored() ? "true" : "false"))

        return details.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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
            frame: useLiveFrame ? Self.visibleFrame(for: element) : snapshot.frameByElement[element],
            name: resultName,
            nameSource: resultNameSource,
            title: title,
            value: resultValue,
            identifier: identifier,
            descriptionText: descriptionText,
            reference: Self.referenceForElement(element, snapshot: snapshot),
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
        var frameByElement: [Element: CGRect] = [:]
        var attributeValuesByElement: [Element: [String: String]] = [:]
        var bestDepthByElement: [Element: Int] = [:]
        var elementsByReference: [String: Element] = [:]
        var generatedReferences: Set<String> = []
        var stack: [(element: Element, depth: Int, parent: Element?)] = [(root, 0, nil)]

        while let entry = stack.popLast() {
            let element = entry.element
            let depth = entry.depth
            let reference = Self.ensureSnapshotReference(
                for: element,
                attributeValuesByElement: &attributeValuesByElement,
                elementsByReference: &elementsByReference,
                generatedReferences: &generatedReferences)

            if let bestDepth = bestDepthByElement[element], depth >= bestDepth {
                continue
            }

            bestDepthByElement[element] = depth

            if let parent = entry.parent {
                parentByElement[element] = parent
            } else {
                parentByElement.removeValue(forKey: element)
            }

            let prefetched = Self.batchFetchAttributeValues(
                for: element,
                attributeNames: orderedAttributeNames)
            let prefetchedAttributes = prefetched.stringValues
            var attributes = attributeValuesByElement[element] ?? [:]
            if !prefetchedAttributes.isEmpty {
                attributes.merge(prefetchedAttributes) { _, new in new }
            }
            attributes[Self.cacheReferenceAttributeName] = reference
            attributeValuesByElement[element] = attributes

            if let frame = prefetched.frame {
                frameByElement[element] = frame
            }

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
            frameByElement: frameByElement,
            attributeValuesByElement: attributeValuesByElement,
            prefetchedAttributeNames: attributeNames,
            elementsByReference: elementsByReference)
    }

    private static func batchFetchAttributeValues(
        for element: Element,
        attributeNames: [String]) -> BatchFetchResult
    {
        guard !attributeNames.isEmpty else {
            return BatchFetchResult(stringValues: [:], frame: nil)
        }

        let positionIndex = attributeNames.firstIndex(of: AXAttributeNames.kAXPositionAttribute)
        let sizeIndex = attributeNames.firstIndex(of: AXAttributeNames.kAXSizeAttribute)

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
            return BatchFetchResult(stringValues: fallbackValues, frame: element.frame())
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

        let origin = positionIndex
            .flatMap { $0 < rawValues.count ? Self.extractPoint(from: rawValues[$0]) : nil }
        let size = sizeIndex
            .flatMap { $0 < rawValues.count ? Self.extractSize(from: rawValues[$0]) : nil }
        let frame = origin.flatMap { origin in
            size.map { size in CGRect(origin: origin, size: size) }
        } ?? element.frame()

        return BatchFetchResult(stringValues: result, frame: frame)
    }

    private static func extractPoint(from value: Any) -> CGPoint? {
        let object = value as AnyObject
        let typeRef = object as CFTypeRef
        guard CFGetTypeID(typeRef) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(object, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func extractSize(from value: Any) -> CGSize? {
        let object = value as AnyObject
        let typeRef = object as CFTypeRef
        guard CFGetTypeID(typeRef) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(object, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private static func referenceMetadata(from snapshot: SelectorPrefetchSnapshot) -> SnapshotReferenceMetadata {
        var frameByReference: [String: CGRect] = [:]
        var parentReferenceByReference: [String: String] = [:]
        var roleByReference: [String: String] = [:]

        for (reference, element) in snapshot.elementsByReference {
            let normalizedReference = reference.lowercased()

            if let frame = snapshot.frameByElement[element] {
                frameByReference[normalizedReference] = frame
            }

            if let parent = snapshot.parentByElement[element],
               let parentReference = snapshot.attributeValuesByElement[parent]?[Self.cacheReferenceAttributeName]
            {
                parentReferenceByReference[normalizedReference] = parentReference.lowercased()
            }

            if let role = snapshot.roleByElement[element] ??
                snapshot.attributeValuesByElement[element]?[AXAttributeNames.kAXRoleAttribute]
            {
                roleByReference[normalizedReference] = role
            }
        }

        return SnapshotReferenceMetadata(
            frameByReference: frameByReference,
            parentReferenceByReference: parentReferenceByReference,
            roleByReference: roleByReference)
    }

    private static func referenceForElement(_ element: Element, snapshot: SelectorPrefetchSnapshot) -> String? {
        snapshot.attributeValuesByElement[element]?[Self.cacheReferenceAttributeName]
    }

    private static func generateUniqueReference(existing: inout Set<String>) -> String {
        while true {
            let raw = UInt64.random(in: 0..<(1 << 36))
            let candidate = String(format: "%09llx", raw)
            if existing.insert(candidate).inserted {
                return candidate
            }
        }
    }

    private static func ensureSnapshotReference(
        for element: Element,
        attributeValuesByElement: inout [Element: [String: String]],
        elementsByReference: inout [String: Element],
        generatedReferences: inout Set<String>) -> String
    {
        var attributes = attributeValuesByElement[element] ?? [:]
        if let existing = attributes[Self.cacheReferenceAttributeName] {
            elementsByReference[existing] = element
            return existing
        }

        let reference = Self.generateUniqueReference(existing: &generatedReferences)
        attributes[Self.cacheReferenceAttributeName] = reference
        attributeValuesByElement[element] = attributes
        elementsByReference[reference] = element
        return reference
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
            AXAttributeNames.kAXPositionAttribute,
            AXAttributeNames.kAXSizeAttribute,
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

    private static func inspectedAttributeValueString(for element: Element, attributeName: String) -> String {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element.underlyingElement,
            attributeName as CFString,
            &rawValue)

        switch status {
        case .success:
            guard let rawValue else {
                return "nil"
            }
            if CFGetTypeID(rawValue) == AXUIElementGetTypeID() {
                let axElement = unsafeDowncast(rawValue, to: AXUIElement.self)
                return Element(axElement).briefDescription(option: .raw)
            }
            if let elements = rawValue as? [AXUIElement] {
                return "[\(elements.count) elements]"
            }
            return Self.stringify(rawValue) ?? String(describing: rawValue)

        case .noValue:
            return "nil"

        default:
            return "<\(Self.axErrorToken(status))>"
        }
    }

    private static func parameterizedAttributeNames(for element: Element) -> [String]? {
        var names: CFArray?
        let status = AXUIElementCopyParameterizedAttributeNames(element.underlyingElement, &names)
        guard status == .success else {
            return nil
        }
        return names as? [String]
    }

    private static func axErrorToken(_ status: AXError) -> String {
        switch status {
        case .success:
            return "AXSuccess"
        case .failure:
            return "AXFailure"
        case .illegalArgument:
            return "AXIllegalArgument"
        case .invalidUIElement:
            return "AXInvalidUIElement"
        case .invalidUIElementObserver:
            return "AXInvalidUIElementObserver"
        case .cannotComplete:
            return "AXCannotComplete"
        case .attributeUnsupported:
            return "AXAttributeUnsupported"
        case .actionUnsupported:
            return "AXActionUnsupported"
        case .notificationUnsupported:
            return "AXNotificationUnsupported"
        case .notImplemented:
            return "AXNotImplemented"
        case .notificationAlreadyRegistered:
            return "AXNotificationAlreadyRegistered"
        case .notificationNotRegistered:
            return "AXNotificationNotRegistered"
        case .apiDisabled:
            return "AXAPIDisabled"
        case .noValue:
            return "AXNoValue"
        case .parameterizedAttributeUnsupported:
            return "AXParameterizedAttributeUnsupported"
        case .notEnoughPrecision:
            return "AXNotEnoughPrecision"
        @unknown default:
            return "AXError(\(status.rawValue))"
        }
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
