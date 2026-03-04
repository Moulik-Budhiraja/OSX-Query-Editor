import SwiftUI

struct WorkbenchView: View {
    @StateObject private var model = WorkbenchViewModel()
    private static let referenceSkeletonToken = "000000000"

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            HSplitView {
                leftPane
                    .frame(minWidth: 560)

                rightPane
                    .frame(minWidth: 360, idealWidth: 420)
            }

            Divider()
            statusBar
        }
        .onAppear {
            model.refreshPermissions()
            model.refreshRunningApps()
            model.handleAppIdentifierChanged()
        }
        .onDisappear {
            model.setOverlayVisibility(false)
        }
        .onChange(of: model.appIdentifier) { _, _ in
            model.handleAppIdentifierChanged()
        }
        .onChange(of: model.editorMode) { _, _ in
            model.handleEditorModeChanged()
        }
        .onChange(of: model.selectorQuery) { _, _ in
            model.handleSelectorQueryChanged()
        }
        .onChange(of: model.selectedRowID) { _, _ in
            model.handleSelectedRowChanged()
        }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("App")
                    .font(.headline)
                TextField("bundle id, app name, PID, or focused", text: $model.appIdentifier)
                    .textFieldStyle(.roundedBorder)

                Menu("Running Apps") {
                    Button("Use Frontmost") {
                        model.useFrontmostApp()
                    }

                    Divider()

                    ForEach(model.runningApps) { app in
                        Button(app.displayName) {
                            model.chooseRunningApp(app)
                        }
                    }
                }

                Button("Refresh Apps") {
                    model.refreshRunningApps()
                }
            }

            HStack(spacing: 10) {
                Text("Max Depth")
                TextField("empty = unlimited", text: $model.maxDepthText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Spacer(minLength: 16)

                HStack(spacing: 6) {
                    Circle()
                        .fill(model.hasAXPermission ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(model.hasAXPermission ? "Accessibility Granted" : "Accessibility Required")
                        .foregroundStyle(model.hasAXPermission ? .green : .orange)
                }

                Button("Request") {
                    model.requestPermission()
                }
                Button("Refresh") {
                    model.refreshPermissions()
                }
            }
        }
        .padding(14)
    }

    private var leftPane: some View {
        VStack(spacing: 0) {
            queryEditor
            Divider()
            resultsPane
        }
    }

    private var queryEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Mode", selection: $model.editorMode) {
                    Text("Query").tag(WorkbenchEditorMode.query)
                    Text("Action").tag(WorkbenchEditorMode.action)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Button {
                    model.toggleEditorMode()
                } label: {
                    Text("⌘I")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("i", modifiers: [.command])
                .help("Toggle Query/Action mode")

                Spacer()
                Button(model.editorMode == .query ? "Run Query" : "Run Action") {
                    model.runActiveEditorProgram()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.isRunning)

                Text("⌘↩")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule(style: .continuous))
                    .help("Run with Command-Return")
            }

            if model.editorMode == .query {
                Text("Selector Query")
                    .font(.headline)
                OXQHighlightedEditor(
                    text: $model.selectorQuery,
                    fontSize: 16,
                    focusRequestID: model.editorFocusRequestID,
                    onRunQuery: { model.runActiveEditorProgram() },
                    onToggleMode: { model.toggleEditorMode() })
                    .frame(minHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Text("Action Program")
                    .font(.headline)
                OXAHighlightedEditor(
                    text: $model.actionProgram,
                    fontSize: 16,
                    focusRequestID: model.editorFocusRequestID,
                    onRunAction: { model.runActiveEditorProgram() },
                    onToggleMode: { model.toggleEditorMode() })
                    .frame(minHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
    }

    private var resultsPane: some View {
        let showReferenceSkeleton = model.stats?.usedWarmCache == true

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Results")
                    .font(.headline)
                Toggle(
                    "Show Overlays",
                    isOn: Binding(
                        get: { model.showResultOverlays },
                        set: { model.setOverlayVisibility($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Text("\(model.filteredRows.count) shown")
                    .foregroundStyle(.secondary)
            }

            TextField("Filter results", text: $model.searchText)
                .textFieldStyle(.roundedBorder)

            List(selection: $model.selectedRowID) {
                ForEach(model.filteredRows) { row in
                    HStack(spacing: 10) {
                        Text(String(format: "%4d", row.index))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)

                        if showReferenceSkeleton {
                            Text(Self.referenceSkeletonToken)
                                .redacted(reason: .placeholder)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .leading)
                        } else if let reference = row.reference {
                            Button(reference) {
                                model.copyReferenceToClipboard(reference)
                            }
                            .buttonStyle(.plain)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 76, alignment: .leading)
                        } else {
                            Text("-")
                                .foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .leading)
                        }

                        Text(row.role)
                            .foregroundStyle(
                                row.id == model.selectedRowID
                                    ? Color.primary
                                    : OXQColorTheme.swiftUIColor(forRole: row.role))
                            .frame(width: 130, alignment: .leading)

                        Text(row.resultsDisplayName)
                            .frame(minWidth: 160, maxWidth: 220, alignment: .leading)

                        Text(row.value ?? "")
                            .frame(minWidth: 120, maxWidth: 200, alignment: .leading)

                        Text(row.identifier ?? "")
                            .frame(minWidth: 120, maxWidth: 180, alignment: .leading)

                        Text(row.focused == true ? "F" : "")
                            .frame(width: 18, alignment: .center)

                        Text(row.enabled == true ? "E" : (row.enabled == false ? "D" : ""))
                            .frame(width: 18, alignment: .center)
                    }
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .tag(row.id)
                    .onHover { inside in
                        model.setListHoveredRowID(inside ? row.id : nil)
                    }
                    .listRowBackground(
                        row.id == model.hoveredRowID
                            ? OXQColorTheme.swiftUIColor(forRole: row.role).opacity(0.20)
                            : Color.clear)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .padding(14)
    }

    private var rightPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statsPanel
                selectedElementPanel
            }
            .padding(14)
        }
    }

    private var statsPanel: some View {
        GroupBox("Query Stats") {
            if let stats = model.stats {
                VStack(alignment: .leading, spacing: 6) {
                    statLine("App", stats.appIdentifier)
                    statLine("Selector", stats.selector)
                    elapsedStatLine(stats)
                    statLine("Traversed", "\(stats.traversedCount)")
                    statLine("Matched", "\(stats.matchedCount)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Run a query to see metrics.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedElementPanel: some View {
        GroupBox("Selected Result") {
            if let row = model.selectedRow {
                VStack(alignment: .leading, spacing: 6) {
                    statLine("Index", "\(row.index)")
                    if model.stats?.usedWarmCache == true {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ref")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(Self.referenceSkeletonToken)
                                .redacted(reason: .placeholder)
                                .font(.system(.body, design: .monospaced))
                        }
                    } else {
                        statLine("Ref", row.reference ?? "")
                    }
                    statLine("Role", row.role)
                    statLine("Name", row.name)
                    statLine("Name Source", row.nameSource ?? "")
                    statLine("Title", row.title ?? "")
                    statLine("Value", row.value ?? "")
                    statLine("Identifier", row.identifier ?? "")
                    statLine("Description", row.descriptionText ?? "")
                    statLine("Children", row.childCount.map(String.init) ?? "")
                    statLine("Focused", row.focused.map { $0 ? "true" : "false" } ?? "")
                    statLine("Enabled", row.enabled.map { $0 ? "true" : "false" } ?? "")

                    if let path = row.path, !path.isEmpty {
                        Text("Path")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    HStack {
                        Text("All Properties")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.isLoadingSelectedAttributes {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("\(model.selectedAttributeDetails.count)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let detailError = model.selectedAttributesError {
                        Text(detailError)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                    } else if model.selectedAttributeDetails.isEmpty {
                        Text("No readable AX properties.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(model.selectedAttributeDetails) { detail in
                                HStack(alignment: .top, spacing: 8) {
                                    Button(detail.name) {
                                        model.copyPropertyNameToClipboard(detail.name)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 170, alignment: .leading)

                                    Text(detail.value)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Select a result to inspect details.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusBar: some View {
        HStack {
            if let error = model.errorMessage {
                Text("Error: \(error)")
                    .foregroundStyle(.red)
            } else {
                Text(model.statusMessage)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func statLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func elapsedStatLine(_ stats: QueryStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Elapsed")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(String(format: "%.2f ms", stats.elapsedMilliseconds))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)

                Text(stats.usedWarmCache ? "CACHED" : "LIVE")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(stats.usedWarmCache ? Color.orange : Color.green)
                    .background(
                        (stats.usedWarmCache ? Color.orange : Color.green)
                            .opacity(0.14))
                    .clipShape(Capsule(style: .continuous))
            }
        }
    }
}
