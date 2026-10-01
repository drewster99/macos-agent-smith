import SwiftUI
import AppKit
import Observation

// Variant chosen by argv[1]. Each variant drives a model and a view with ONE onChange watcher, then
// the log stream counts "tried to update multiple times per frame" faults.
let variant = CommandLine.arguments.dropFirst().first ?? "A"

@Observable @MainActor final class Model {
    var dict: [Int: Int] = [1: 0, 2: 0]
    var list: [Int] = []
}
@Observable @MainActor final class Slot { var value: Int = 0 }

@MainActor var model: Model!
@MainActor var slot1: Slot!

struct WatchDictKey: View {
    var body: some View {
        Text("x").onChange(of: model.dict[1]) { _, _ in }
    }
}
struct WatchList: View {
    var body: some View {
        Text("x").onChange(of: model.list) { _, _ in }
    }
}
struct WatchSlot: View {
    var body: some View {
        Text("x").onChange(of: slot1.value) { _, _ in }
    }
}

@MainActor func drive() {
    Task.detached {
        for round in 0..<200 {
            switch variant {
            case "A": // watched key, 4 separate main hops in a burst
                for _ in 0..<4 { await MainActor.run { model.dict[1, default: 0] += 1 } }
            case "B": // watched key, 4 changes in ONE hop
                await MainActor.run { for _ in 0..<4 { model.dict[1, default: 0] += 1 } }
            case "C": // only the OTHER key changes, 4 hops
                for _ in 0..<4 { await MainActor.run { model.dict[2, default: 0] += 1 } }
            case "D": // list, 4 hops
                for _ in 0..<4 { await MainActor.run { model.list.append(round) } }
            case "E": // per-key object, 4 hops
                for _ in 0..<4 { await MainActor.run { slot1.value += 1 } }
            case "F": // watched key, ONE hop per 50ms (one change per frame)
                await MainActor.run { model.dict[1, default: 0] += 1 }
            default: break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await MainActor.run { NSApp.terminate(nil) }
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = Model()
        slot1 = Slot()
        let root: AnyView
        switch variant {
        case "D": root = AnyView(WatchList())
        case "E": root = AnyView(WatchSlot())
        default: root = AnyView(WatchDictKey())
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: root)
        w.orderFrontRegardless()
        window = w
        drive()
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
