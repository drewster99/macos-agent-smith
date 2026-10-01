import SwiftUI
import AppKit
import Observation

// One hop per 60ms. Variants differ in how many onChange watchers one view has and what changes.
let variant = CommandLine.arguments.dropFirst().first ?? "two"

@Observable @MainActor final class Model {
    var a = 0
    var b = 0
    var c = 0
    var d = 0
}
@MainActor var model: Model!

struct Two: View {
    var body: some View {
        Text("x")
            .onChange(of: model.a) { _, _ in }
            .onChange(of: model.b) { _, _ in }
    }
}
struct Four: View {
    var body: some View {
        Text("x")
            .onChange(of: model.a) { _, _ in }
            .onChange(of: model.b) { _, _ in }
            .onChange(of: model.c) { _, _ in }
            .onChange(of: model.d) { _, _ in }
    }
}
/// Watchers whose action defers a @State write, like the inspector's caches.
struct FourWithState: View {
    @State private var cached = 0
    var body: some View {
        Text("\(cached)")
            .onChange(of: model.a) { _, _ in DispatchQueue.main.async { cached += 1 } }
            .onChange(of: model.b) { _, _ in DispatchQueue.main.async { cached += 1 } }
            .onChange(of: model.c) { _, _ in DispatchQueue.main.async { cached += 1 } }
            .onChange(of: model.d) { _, _ in DispatchQueue.main.async { cached += 1 } }
    }
}
/// A watcher whose action writes state the SAME view renders, synchronously.
struct SyncState: View {
    @State private var cached = 0
    var body: some View {
        Text("\(cached)")
            .onChange(of: model.a) { _, _ in cached += 1 }
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = Model()
        let root: AnyView
        switch variant {
        case "four": root = AnyView(Four())
        case "fourState": root = AnyView(FourWithState())
        case "syncState": root = AnyView(SyncState())
        default: root = AnyView(Two())
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: root)
        w.orderFrontRegardless()
        window = w
        Task.detached {
            for _ in 0..<300 {
                await MainActor.run {
                    model.a += 1; model.b += 1; model.c += 1; model.d += 1
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
    }
}
@main enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate()
        app.delegate = delegate
        app.run()
    }
}
