import AXorcist
import AppKit
import Foundation

@MainActor
final class WorkbenchViewModel: ObservableObject {
    @Published var appIdentifier = "focused"
    @Published var selectorQuery = "AXButton[AXTitle*=\"Run\"]"
    @Published var maxDepthText = ""
    @Published var searchText = ""
    @Published var interactionValue = ""
    @Published var showResultOverlays = false
    @Published private(set) var hoveredRowID: QueryResultRow.ID?

    @Published private(set) var runningApps: [RunningAppOption] = []
    @Published private(set) var allRows: [QueryResultRow] = []
    @Published var selectedRowID: QueryResultRow.ID?

    @Published private(set) var stats: QueryStats?
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false
    @Published private(set) var hasAXPermission = AXPermissionHelpers.hasAccessibilityPermissions()

    private let service = SelectorQueryService()
    private let overlayManager = QueryOverlayManager()
    private var listHoveredRowID: QueryResultRow.ID?
    private var overlayHoveredRowID: QueryResultRow.ID?

    init() {
        self.overlayManager.onOverlayHoverChanged = { [weak self] rowID in
            self?.setOverlayHoveredRowID(rowID)
        }
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

    func setListHover(rowID: QueryResultRow.ID, inside: Bool) {
        if inside {
            guard self.listHoveredRowID != rowID else { return }
            self.listHoveredRowID = rowID
        } else {
            // Ignore stale leave events from rows that are no longer the active hover target.
            guard self.listHoveredRowID == rowID else { return }
            self.listHoveredRowID = nil
        }
        self.updateHoveredRowID()
        self.overlayManager.setExternalHighlightedRowID(self.listHoveredRowID)
    }

    func clearListHover() {
        guard self.listHoveredRowID != nil else { return }
        self.listHoveredRowID = nil
        self.updateHoveredRowID()
        self.overlayManager.setExternalHighlightedRowID(nil)
    }

    func runQuery() {
        do {
            let request = try self.makeRequest()
            self.errorMessage = nil
            self.isRunning = true
            let result = try service.run(request: request)
            self.apply(result: result)
            self.statusMessage = "Query complete. \(result.stats.matchedCount) matches."
            self.isRunning = false
        } catch {
            self.isRunning = false
            self.errorMessage = error.localizedDescription
            self.statusMessage = "Query failed"
        }
    }

    func performInteraction(_ action: SelectorInteractionKind) {
        guard let selected = self.selectedRow else {
            self.errorMessage = "Select a result first."
            return
        }

        do {
            let request = try self.makeRequest()
            let rawValue = interactionValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let interaction = QueryInteractionRequest(
                resultIndex: selected.index,
                action: action,
                value: action.requiresValue ? rawValue : nil)

            self.errorMessage = nil
            self.isRunning = true

            let result = try service.run(request: request, interaction: interaction)
            self.apply(result: result)
            self.selectedRowID = selected.id
            self.statusMessage = "Interaction '\(action.rawValue)' succeeded on result \(selected.index)."
            self.isRunning = false
        } catch {
            self.isRunning = false
            self.errorMessage = error.localizedDescription
            self.statusMessage = "Interaction failed"
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

    private func apply(result: QueryExecutionResult) {
        self.stats = result.stats
        self.allRows = result.rows
        self.syncOverlays()

        let filtered = self.filteredRows
        if let selectedRowID,
           filtered.contains(where: { $0.id == selectedRowID })
        {
            self.ensureHoveredRowExists()
            return
        }
        self.selectedRowID = filtered.first?.id
        self.ensureHoveredRowExists()
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

    private static func displayName(for app: NSRunningApplication) -> String {
        let name = app.localizedName ?? "Unknown App"
        let bundle = app.bundleIdentifier ?? "no-bundle"
        return "\(name) (\(bundle))"
    }
}
