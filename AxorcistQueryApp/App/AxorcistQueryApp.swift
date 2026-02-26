import SwiftUI

@main
struct AxorcistQueryApp: App {
    var body: some Scene {
        WindowGroup {
            WorkbenchView()
                .frame(minWidth: 1120, minHeight: 760)
        }
        .windowToolbarStyle(.unifiedCompact)
    }
}
