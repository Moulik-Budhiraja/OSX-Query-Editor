import SwiftUI

struct WorkbenchView: View {
    @StateObject private var model = WorkbenchViewModel()

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
        }
        .onDisappear {
            model.setOverlayVisibility(false)
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
                Text("Selector Query")
                    .font(.headline)
                Spacer()
                Button("Run Query") {
                    model.runQuery()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.isRunning)
            }

            OXQHighlightedEditor(text: $model.selectorQuery, fontSize: 16)
                .frame(minHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
    }

    private var resultsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                interactionPanel
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
                    statLine("Elapsed", String(format: "%.2f ms", stats.elapsedMilliseconds))
                    statLine("Traversed", "\(stats.traversedCount)")
                    statLine("Matched", "\(stats.matchedCount)")
                }
            } else {
                Text("Run a query to see metrics.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedElementPanel: some View {
        GroupBox("Selected Result") {
            if let row = model.selectedRow {
                VStack(alignment: .leading, spacing: 6) {
                    statLine("Index", "\(row.index)")
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
                }
            } else {
                Text("Select a result to inspect details.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var interactionPanel: some View {
        GroupBox("Interactions") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Value for set-value / submit actions", text: $model.interactionValue)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.selectedRow == nil)

                HStack {
                    Button("Click") {
                        model.performInteraction(.click)
                    }
                    Button("Press") {
                        model.performInteraction(.press)
                    }
                    Button("Focus") {
                        model.performInteraction(.focus)
                    }
                }
                .disabled(model.selectedRow == nil || model.isRunning)

                HStack {
                    Button("Set Value") {
                        model.performInteraction(.setValue)
                    }
                    Button("Set Value + Return") {
                        model.performInteraction(.setValueSubmit)
                    }
                }
                .disabled(model.selectedRow == nil || model.isRunning)

                Button("Send Keystrokes + Cmd+Return") {
                    model.performInteraction(.sendKeystrokesSubmit)
                }
                .disabled(model.selectedRow == nil || model.isRunning)
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
}
