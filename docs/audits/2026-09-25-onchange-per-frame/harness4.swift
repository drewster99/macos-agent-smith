import SwiftUI
import AppKit
import Observation

// Two sources changed in ONE main-actor turn every 60ms. Variants differ in how the watched value is
// derived from them.
let variant = CommandLine.arguments.dropFirst().first ?? "computed"

@Observable @MainActor final class Model {
    var messages: [Int] = []
    var processing = false
}
@MainActor var model: Model!

/// Parent buckets `model.messages` into @State (as InspectorView does) and passes a slice down.
struct Parent: View {
    @State private var slice: [Int] = []
    var body: some View {
        Child(slice: slice)
            .onChange(of: model.messages) { _, new in slice = new.filter { $0 % 2 == 0 } }
    }
}
/// Child watches the passed slice AND a live model value, like RoleAgentCardWatchers.
struct Child: View {
    let slice: [Int]
    var body: some View {
        Text("x")
            .onChange(of: slice) { _, _ in }
            .onChange(of: model.processing) { _, _ in }
    }
}
/// One watcher on a value computed from two observed sources.
struct Computed: View {
    var body: some View {
        Text("x").onChange(of: "\(model.messages.count)-\(model.processing)") { _, _ in }
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = Model()
        let root: AnyView = variant == "parent" ? AnyView(Parent()) : AnyView(Computed())
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: root)
        w.orderFrontRegardless()
        window = w
        Task.detached {
            for i in 0..<300 {
                await MainActor.run {
                    model.messages.append(i)
                    model.processing.toggle()
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
