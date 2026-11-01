import SwiftUI

@main
struct DropViewRenderApp: App {
    @StateObject private var model = RenderQueueModel()

    var body: some Scene {
        WindowGroup("Drop & View Render") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Render Files…") {
                    model.openFiles()
                }
                .keyboardShortcut("o")
            }
        }
    }
}
