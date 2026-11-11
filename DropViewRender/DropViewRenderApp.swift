import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RenderQueueModel?
    weak var bridge: BrowserBridge?

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isRendering || model.preparingBlenderJobID != nil else { return .terminateNow }
        model.stopForApplicationTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct DropViewRenderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RenderQueueModel()
    @StateObject private var bridge = BrowserBridge()

    var body: some Scene {
        Window("Drop & View Render", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(bridge)
                .frame(minWidth: 900, minHeight: 620)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.bridge = bridge
                    bridge.rendererStatus = { [weak queueModel = model] in
                        ["blenderAvailable": queueModel?.blender.executableURL != nil,
                         "rendering": queueModel?.isRendering ?? false]
                    }
                    bridge.submitJob = { [weak queueModel = model] url, manifest, destination, denoise, adaptive in
                        guard let queueModel else { throw CocoaError(.userCancelled) }
                        return try queueModel.acceptBrowserJob(at: url, manifest: manifest, outputDirectory: destination,
                                                               denoise: denoise, adaptive: adaptive)
                    }
                    bridge.jobStatus = { [weak queueModel = model] in queueModel?.browserJobStatus($0) }
                    bridge.cancelJob = { [weak queueModel = model] in queueModel?.cancelBrowserJob($0) ?? false }
                    bridge.revealJob = { [weak queueModel = model] in queueModel?.revealBrowserJob($0) ?? false }
                    bridge.start()
                }
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
