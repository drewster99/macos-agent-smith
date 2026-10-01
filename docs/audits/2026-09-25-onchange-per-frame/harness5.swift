import SwiftUI
import AppKit
import Observation

// One turn every 60ms: change the watched value, force a synchronous layout of the hosting view,
// change it again. Variant "noforce" skips the forced layout.
let variant = CommandLine.arguments.dropFirst().first ?? "force"

@Observable @MainActor final class Model { var value = 0 }
@MainActor var model: Model!

struct Watch: View {
    var body: some View { Text("\(model.value)").onChange(of: model.value) { _, _ in } }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = Model()
        let host = NSHostingView(rootView: Watch())
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.orderFrontRegardless()
        window = w
        Task.detached {
            for _ in 0..<200 {
                await MainActor.run {
                    model.value += 1
                    switch variant {
                    case "force": host.layoutSubtreeIfNeeded()
                    case "display": w.displayIfNeeded()
                    default: break
                    }
                    model.value += 1
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
