import SwiftUI

@main
struct RetexApp: App {
    @StateObject private var workspace = WorkspaceModel()

    var body: some Scene {
#if os(macOS)
        WindowGroup {
            root
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
#else
        WindowGroup {
            root
        }
#endif
    }

    private var root: some View {
        RootView()
            .environmentObject(workspace)
            .preferredColorScheme(.dark)
    }
}
