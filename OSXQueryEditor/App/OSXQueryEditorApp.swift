import SwiftUI

@main
struct OSXQueryEditorApp: App {
    var body: some Scene {
        WindowGroup {
            WorkbenchView()
                .frame(minWidth: 1120, minHeight: 760)
        }
    }
}
