import AXorcist
import AppKit
import Foundation

@MainActor
final class WorkbenchViewModel: ObservableObject {
    private enum QueryRunTrigger {
        case manual
        case typingCached
        case typingLiveRefresh
        case modeSwitchToAction
    }

    private struct QueryIdentity: Equatable {
        let appIdentifier: String
        let selector: String
        let maxDepth: Int

        init(request: QueryRequest) {
            self.appIdentifier = request.appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            self.selector = request.selector.trimmingCharacters(in: .whitespacesAndNewlines)
            self.maxDepth = request.maxDepth
        }
    }

    @Published var appIdentifier = "focused"
    @Published var editorMode: WorkbenchEditorMode = .query
    @Published var selectorQuery = "AXButton[AXTitle*=\"Run\"]"
    @Published var actionProgram = ""
    @Published private(set) var editorFocusRequestID: UInt64 = 0
    @Published var maxDepthText = ""
    @Published var searchText = ""
    @Published var showResultOverlays = false
    @Published private(set) var hoveredRowID: QueryResultRow.ID?

    @Published private(set) var runningApps: [RunningAppOption] = []
    @Published private(set) var allRows: [QueryResultRow] = []
    @Published var selectedRowID: QueryResultRow.ID?

    @Published private(set) var stats: QueryStats?
    @Published private(set) var selectedAttributeDetails: [QueryAttributeDetail] = []
    @Published private(set) var selectedAttributesError: String?
    @Published private(set) var isLoadingSelectedAttributes = false
    @Published private(set) var actionBundleIdentifiers: [String] = []
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false
    @Published private(set) var hasAXPermission = AXPermissionHelpers.hasAccessibilityPermissions()

    private let service = SelectorQueryService()
    private let overlayManager = QueryOverlayManager()
    private var listHoveredRowID: QueryResultRow.ID?
    private var overlayHoveredRowID: QueryResultRow.ID?
    private let typingLiveRefreshDebounceNanoseconds: UInt64 = 3_000_000_000
    private let appWarmDebounceNanoseconds: UInt64 = 300_000_000
    private var typingDebounceTask: Task<Void, Never>?
    private var appWarmDebounceTask: Task<Void, Never>?
    private var queryRunToken: UInt64 = 0
    private var appWarmToken: UInt64 = 0
    private var lastLiveRefreshIdentity: QueryIdentity?

    init() {
        self.overlayManager.onOverlayHoverChanged = { [weak self] rowID in
            self?.setOverlayHoveredRowID(rowID)
        }

        Task {
            let identifiers = await OXAAppBundleIndex.shared.preload()
            self.actionBundleIdentifiers = identifiers
        }
    }

    deinit {
        self.typingDebounceTask?.cancel()
        self.appWarmDebounceTask?.cancel()
    }

    var filteredRows: [QueryResultRow] {
        allRows.filter { $0.matches(search: searchText) }
    }

    var selectedRow: QueryResultRow? {
        guard let selectedRowID else { return nil }
        return allRows.first(where: { $0.id == selectedRowID })
    }

    func refreshPermissions() {
        hasAXPermission = AXPermissionHelpers.hasAccessibilityPermissions()
    }

    func requestPermission() {
        Task {
            _ = await AXPermissionHelpers.requestPermissions()
            await MainActor.run {
                self.hasAXPermission = AXPermissionHelpers.hasAccessibilityPermissions()
            }
        }
    }

    func refreshRunningApps() {
        let apps = RunningApplicationHelper.accessibleApplicationsWithOnScreenWindows()
            .map { app in
                RunningAppOption(
                    id: app.bundleIdentifier ?? "pid-\(app.processIdentifier)",
                    displayName: Self.displayName(for: app),
                    bundleIdentifier: app.bundleIdentifier,
                    pid: app.processIdentifier)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        runningApps = apps

        let runningBundleIdentifiers = apps.compactMap(\.bundleIdentifier)
        Task {
            let identifiers = await OXAAppBundleIndex.shared.absorbRunning(bundleIdentifiers: runningBundleIdentifiers)
            self.actionBundleIdentifiers = identifiers
        }
    }

    func useFrontmostApp() {
        guard let app = RunningApplicationHelper.frontmostApplication else { return }
        appIdentifier = app.bundleIdentifier ?? app.localizedName ?? String(app.processIdentifier)
    }

    func chooseRunningApp(_ option: RunningAppOption) {
        appIdentifier = option.selectorToken
    }

    func setOverlayVisibility(_ visible: Bool) {
        self.showResultOverlays = visible
        self.syncOverlays()
    }

    func setListHoveredRowID(_ rowID: QueryResultRow.ID?) {
        self.listHoveredRowID = rowID
        self.updateHoveredRowID()
        self.overlayManager.setExternalHighlightedRowID(rowID)
    }

    func copyReferenceToClipboard(_ reference: String) {
        self.copyStringToClipboard(reference)
        self.statusMessage = "Copied ref \(reference)."
    }

    func copyPropertyNameToClipboard(_ propertyName: String) {
        self.copyStringToClipboard(propertyName)
        self.statusMessage = "Copied property \(propertyName)."
    }

    private func copyStringToClipboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    func handleAppIdentifierChanged() {
        self.typingDebounceTask?.cancel()
        self.appWarmDebounceTask?.cancel()
        self.service.invalidateWarmCache()
        self.lastLiveRefreshIdentity = nil
        self.bumpQueryRunToken()
        self.clearSelectedAttributeDetails()

        let trimmedAppIdentifier = self.appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAppIdentifier.isEmpty else {
            return
        }

        let warmToken = self.bumpAppWarmToken()
        self.appWarmDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: self.appWarmDebounceNanoseconds)
            guard !Task.isCancelled, warmToken == self.appWarmToken else {
                return
            }
            do {
                let request = try self.makeRequest()
                try self.service.warmCache(request: request)
                if self.editorMode == .query {
                    self.queueTypingQueryRuns()
                }
            } catch {
                // Suppress warm-up errors during app id typing.
            }
        }
    }

    func handleEditorModeChanged() {
        self.typingDebounceTask?.cancel()
        self.bumpQueryRunToken()

        guard self.editorMode == .action else {
            return
        }
        self.runLiveRefreshForActionModeIfNeeded()
    }

    func handleSelectorQueryChanged() {
        guard self.editorMode == .query else {
            return
        }

        self.typingDebounceTask?.cancel()
        self.queueTypingQueryRuns()
    }

    func handleSelectedRowChanged() {
        self.refreshSelectedAttributeDetails()
    }

    func runActiveEditorProgram() {
        switch self.editorMode {
        case .query:
            self.runQuery()
        case .action:
            self.runActionProgram()
        }
    }

    func toggleEditorMode() {
        self.editorMode = (self.editorMode == .query) ? .action : .query
        self.requestEditorFocus()
    }

    func requestEditorFocus() {
        self.editorFocusRequestID &+= 1
    }

    func runQuery() {
        self.typingDebounceTask?.cancel()
        self.appWarmDebounceTask?.cancel()
        self.bumpAppWarmToken()
        let runToken = self.bumpQueryRunToken()
        self.executeQuery(
            mode: .liveRefresh,
            trigger: .manual,
            runToken: runToken)
    }

    func runActionProgram() {
        self.typingDebounceTask?.cancel()
        self.appWarmDebounceTask?.cancel()
        self.bumpAppWarmToken()
        self.bumpQueryRunToken()

        let trimmedProgram = self.actionProgram.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProgram.isEmpty else {
            self.errorMessage = "Action program is empty."
            self.statusMessage = "Action failed"
            return
        }

        self.errorMessage = nil
        self.isRunning = true
        defer {
            self.isRunning = false
        }

        do {
            let output = try OXAExecutor.execute(programSource: trimmedProgram)
            self.recordBundleIdentifierRecency(from: trimmedProgram)
            let firstLine = output.split(separator: "\n").first.map(String.init) ?? "Action complete."
            self.statusMessage = firstLine
        } catch {
            self.errorMessage = error.localizedDescription
            self.statusMessage = "Action failed"
        }
    }

    private func makeRequest() throws -> QueryRequest {
        let maxDepth: Int
        let trimmedDepth = maxDepthText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDepth.isEmpty {
            maxDepth = Int.max
        } else {
            guard let parsed = Int(trimmedDepth), parsed > 0 else {
                throw QueryWorkbenchError.invalidMaxDepth
            }
            maxDepth = parsed
        }

        return QueryRequest(
            appIdentifier: appIdentifier,
            selector: selectorQuery,
            maxDepth: maxDepth)
    }

    private func queueTypingQueryRuns() {
        let trimmedAppIdentifier = self.appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSelector = self.selectorQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAppIdentifier.isEmpty, !trimmedSelector.isEmpty else {
            return
        }

        let cachedRunToken = self.bumpQueryRunToken()
        self.executeQuery(
            mode: .useWarmCache,
            trigger: .typingCached,
            runToken: cachedRunToken)

        self.typingDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: self.typingLiveRefreshDebounceNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            let liveRunToken = self.bumpQueryRunToken()
            self.executeQuery(
                mode: .liveRefresh,
                trigger: .typingLiveRefresh,
                runToken: liveRunToken)
        }
    }

    private func executeQuery(
        mode: QueryExecutionMode,
        trigger: QueryRunTrigger,
        runToken: UInt64)
    {
        do {
            let request = try self.makeRequest()
            self.errorMessage = nil
            self.isRunning = true
            let result = try self.service.run(request: request, mode: mode)
            guard runToken == self.queryRunToken else {
                self.isRunning = false
                return
            }

            self.apply(result: result)
            if mode == .liveRefresh {
                self.lastLiveRefreshIdentity = QueryIdentity(request: request)
            }
            self.isRunning = false

            switch trigger {
            case .manual:
                self.statusMessage = "Query complete. \(result.stats.matchedCount) matches."
            case .typingCached:
                self.statusMessage = "Cached preview. \(result.stats.matchedCount) matches."
            case .typingLiveRefresh:
                self.statusMessage = "Live refresh complete. \(result.stats.matchedCount) matches."
            case .modeSwitchToAction:
                self.statusMessage = "Action mode ready. \(result.stats.matchedCount) matches."
            }
        } catch {
            guard runToken == self.queryRunToken else {
                self.isRunning = false
                return
            }

            self.isRunning = false

            switch trigger {
            case .typingCached:
                // Ignore transient typing parse and cache misses here.
                return
            case .manual:
                self.errorMessage = error.localizedDescription
                self.statusMessage = "Query failed"
            case .typingLiveRefresh:
                self.errorMessage = error.localizedDescription
                self.statusMessage = "Live refresh failed"
            case .modeSwitchToAction:
                self.errorMessage = error.localizedDescription
                self.statusMessage = "Action mode refresh failed"
            }
        }
    }

    @discardableResult
    private func bumpQueryRunToken() -> UInt64 {
        self.queryRunToken &+= 1
        return self.queryRunToken
    }

    @discardableResult
    private func bumpAppWarmToken() -> UInt64 {
        self.appWarmToken &+= 1
        return self.appWarmToken
    }

    private func apply(result: QueryExecutionResult) {
        self.stats = result.stats
        self.allRows = result.rows
        self.syncOverlays()

        let filtered = self.filteredRows
        if let selectedRowID,
           filtered.contains(where: { $0.id == selectedRowID })
        {
            self.ensureHoveredRowExists()
            self.refreshSelectedAttributeDetails()
            return
        }
        self.selectedRowID = filtered.first?.id
        self.ensureHoveredRowExists()
        self.refreshSelectedAttributeDetails()
    }

    private func setOverlayHoveredRowID(_ rowID: QueryResultRow.ID?) {
        self.overlayHoveredRowID = rowID
        self.updateHoveredRowID()
    }

    private func updateHoveredRowID() {
        self.hoveredRowID = self.overlayHoveredRowID ?? self.listHoveredRowID
    }

    private func ensureHoveredRowExists() {
        if let listHoveredRowID,
           !self.allRows.contains(where: { $0.id == listHoveredRowID })
        {
            self.listHoveredRowID = nil
        }

        if let overlayHoveredRowID,
           !self.allRows.contains(where: { $0.id == overlayHoveredRowID })
        {
            self.overlayHoveredRowID = nil
        }

        self.updateHoveredRowID()
    }

    private func syncOverlays() {
        self.overlayManager.setEnabled(self.showResultOverlays, rows: self.allRows)
        self.overlayManager.setExternalHighlightedRowID(self.listHoveredRowID)
    }

    private func runLiveRefreshForActionModeIfNeeded() {
        guard !self.isRunning else {
            return
        }

        guard let request = try? self.makeRequest() else {
            return
        }

        let currentIdentity = QueryIdentity(request: request)
        let hasCurrentLiveSnapshot = self.stats?.usedWarmCache == false
            && self.lastLiveRefreshIdentity == currentIdentity
        guard !hasCurrentLiveSnapshot else {
            return
        }

        self.typingDebounceTask?.cancel()
        self.appWarmDebounceTask?.cancel()
        self.bumpAppWarmToken()
        let runToken = self.bumpQueryRunToken()
        self.executeQuery(
            mode: .liveRefresh,
            trigger: .modeSwitchToAction,
            runToken: runToken)
    }

    private static func displayName(for app: NSRunningApplication) -> String {
        let name = app.localizedName ?? "Unknown App"
        let bundle = app.bundleIdentifier ?? "no-bundle"
        return "\(name) (\(bundle))"
    }

    private func clearSelectedAttributeDetails() {
        self.selectedAttributeDetails = []
        self.selectedAttributesError = nil
        self.isLoadingSelectedAttributes = false
    }

    private func refreshSelectedAttributeDetails() {
        guard let selected = self.selectedRow else {
            self.clearSelectedAttributeDetails()
            return
        }

        guard let reference = selected.reference else {
            self.clearSelectedAttributeDetails()
            return
        }

        self.isLoadingSelectedAttributes = true
        self.selectedAttributesError = nil

        do {
            let details = try self.service.inspectElementAttributes(reference: reference)
            guard self.selectedRowID == selected.id else {
                return
            }
            self.selectedAttributeDetails = details
            self.isLoadingSelectedAttributes = false
        } catch {
            guard self.selectedRowID == selected.id else {
                return
            }
            self.selectedAttributeDetails = []
            self.selectedAttributesError = error.localizedDescription
            self.isLoadingSelectedAttributes = false
        }
    }

    private func recordBundleIdentifierRecency(from actionProgram: String) {
        let bundleIdentifiers = Self.extractOpenCloseBundleIdentifiers(from: actionProgram)
        guard !bundleIdentifiers.isEmpty else {
            return
        }

        Task {
            let identifiers = await OXAAppBundleIndex.shared.markRecent(bundleIdentifiers: bundleIdentifiers)
            self.actionBundleIdentifiers = identifiers
        }
    }

    private static func extractOpenCloseBundleIdentifiers(from source: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "(?:^|;)\\s*(?:open|close)\\s+\"((?:\\\\.|[^\"\\\\])*)\"",
            options: [.caseInsensitive]) else
        {
            return []
        }

        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        let matches = regex.matches(in: source, options: [], range: fullRange)
        var bundleIdentifiers: [String] = []
        bundleIdentifiers.reserveCapacity(matches.count)

        for match in matches {
            guard match.numberOfRanges > 1 else {
                continue
            }
            let captured = nsSource.substring(with: match.range(at: 1))
            let unescaped = captured
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.looksLikeBundleIdentifier(unescaped) else {
                continue
            }
            bundleIdentifiers.append(unescaped)
        }
        return bundleIdentifiers
    }

    private static func looksLikeBundleIdentifier(_ value: String) -> Bool {
        guard value.contains("."), !value.contains(where: { $0.isWhitespace }) else {
            return false
        }
        return true
    }
}

private actor OXAAppBundleIndex {
    static let shared = OXAAppBundleIndex()

    private static let recencyDefaultsKey = "OXAAppBundleIdentifierRecency"
    private static let defaultSearchRoots: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices",
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
    ]

    private var knownBundleIdentifiers: Set<String> = []
    private var runningBundleIdentifiers: Set<String> = []
    private var recencyByBundleIdentifier: [String: TimeInterval]
    private var didPreload = false

    private init() {
        self.recencyByBundleIdentifier = Self.loadRecencyMap()
    }

    func preload() async -> [String] {
        if !self.didPreload {
            let scanned = await Task.detached(priority: .utility) {
                Self.scanInstalledBundleIdentifiers()
            }.value
            self.knownBundleIdentifiers.formUnion(scanned)
            self.didPreload = true
        }

        let running = await self.fetchRunningBundleIdentifiers()
        self.runningBundleIdentifiers = running
        self.knownBundleIdentifiers.formUnion(running)
        return self.sortedBundleIdentifiers()
    }

    func absorbRunning(bundleIdentifiers: [String]) -> [String] {
        let normalized = Self.normalizeBundleIdentifiers(bundleIdentifiers)
        self.runningBundleIdentifiers.formUnion(normalized)
        self.knownBundleIdentifiers.formUnion(normalized)
        return self.sortedBundleIdentifiers()
    }

    func markRecent(bundleIdentifiers: [String]) async -> [String] {
        var normalized = Self.normalizeBundleIdentifiers(bundleIdentifiers)
        guard !normalized.isEmpty else {
            return self.sortedBundleIdentifiers()
        }

        var allowed: Set<String> = []
        allowed.reserveCapacity(normalized.count)
        for identifier in normalized {
            if self.knownBundleIdentifiers.contains(identifier) {
                allowed.insert(identifier)
                continue
            }
            if await Self.isRegularAppBundleIdentifier(identifier) {
                self.knownBundleIdentifiers.insert(identifier)
                allowed.insert(identifier)
            }
        }
        normalized = allowed
        guard !normalized.isEmpty else {
            return self.sortedBundleIdentifiers()
        }

        let now = Date().timeIntervalSince1970
        for identifier in normalized {
            self.recencyByBundleIdentifier[identifier] = now
        }
        Self.persistRecencyMap(self.recencyByBundleIdentifier)

        return self.sortedBundleIdentifiers()
    }

    private func sortedBundleIdentifiers() -> [String] {
        self.knownBundleIdentifiers.sorted { lhs, rhs in
            let lhsRecency = self.recencyByBundleIdentifier[lhs] ?? 0
            let rhsRecency = self.recencyByBundleIdentifier[rhs] ?? 0
            if lhsRecency != rhsRecency {
                return lhsRecency > rhsRecency
            }

            let lhsRunning = self.runningBundleIdentifiers.contains(lhs)
            let rhsRunning = self.runningBundleIdentifiers.contains(rhs)
            if lhsRunning != rhsRunning {
                return lhsRunning && !rhsRunning
            }

            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private func fetchRunningBundleIdentifiers() async -> Set<String> {
        await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular else {
                    return nil
                }
                return Self.normalizeBundleIdentifier(app.bundleIdentifier)
            })
        }
    }

    private static func scanInstalledBundleIdentifiers() -> Set<String> {
        let manager = FileManager.default
        var identifiers = Set<String>()

        for rootPath in Self.defaultSearchRoots {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            guard let enumerator = manager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else {
                continue
            }

            for case let appURL as URL in enumerator {
                guard appURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }
                if let bundleIdentifier = Self.regularBundleIdentifier(forAppURL: appURL) {
                    identifiers.insert(bundleIdentifier)
                }
            }
        }

        return identifiers
    }

    private static func regularBundleIdentifier(forAppURL appURL: URL) -> String? {
        let infoURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard
            let data = try? Data(contentsOf: infoURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil) as? [String: Any],
            let raw = plist["CFBundleIdentifier"] as? String,
            Self.isRegularApplicationPlist(plist)
        else {
            return nil
        }
        return Self.normalizeBundleIdentifier(raw)
    }

    private static func isRegularApplicationPlist(_ plist: [String: Any]) -> Bool {
        let backgroundOnly = Self.plistBool(plist["LSBackgroundOnly"])
        let uiElement = Self.plistBool(plist["LSUIElement"])
        return !backgroundOnly && !uiElement
    }

    private static func plistBool(_ value: Any?) -> Bool {
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        if let stringValue = value as? String {
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes":
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func isRegularAppBundleIdentifier(_ bundleIdentifier: String) async -> Bool {
        let appURL: URL? = await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
        guard let appURL else {
            return false
        }
        return Self.regularBundleIdentifier(forAppURL: appURL) != nil
    }

    private static func normalizeBundleIdentifiers<S: Sequence>(_ bundleIdentifiers: S) -> Set<String> where S.Element == String {
        Set(bundleIdentifiers.compactMap { Self.normalizeBundleIdentifier($0) })
    }

    private static func normalizeBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else {
            return nil
        }
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    private static func loadRecencyMap() -> [String: TimeInterval] {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.recencyDefaultsKey) else {
            return [:]
        }

        var recency: [String: TimeInterval] = [:]
        recency.reserveCapacity(stored.count)
        for (key, value) in stored {
            guard let normalizedKey = Self.normalizeBundleIdentifier(key) else {
                continue
            }
            if let timestamp = value as? TimeInterval {
                recency[normalizedKey] = timestamp
            } else if let number = value as? NSNumber {
                recency[normalizedKey] = number.doubleValue
            }
        }
        return recency
    }

    private static func persistRecencyMap(_ recencyByBundleIdentifier: [String: TimeInterval]) {
        UserDefaults.standard.set(recencyByBundleIdentifier, forKey: Self.recencyDefaultsKey)
    }
}
