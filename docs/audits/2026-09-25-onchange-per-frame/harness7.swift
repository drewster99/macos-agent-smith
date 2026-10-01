import SwiftUI
import AppKit
import Observation

// One change per 60ms. Variants: how the watcher is attached.
let variant = CommandLine.arguments.dropFirst().first ?? "plain"

@Observable @MainActor final class Model { var value = 0; var show = true }
@MainActor var model: Model!

struct Plain: View {
    var body: some View { Text("x").onChange(of: model.value) { _, _ in } }
}
/// Group with two children: the modifier is applied to each.
struct GroupTwo: View {
    var body: some View {
        Group { Text("a"); Text("b") }.onChange(of: model.value) { _, _ in }
    }
}
/// Group whose single child comes and goes.
struct GroupToggle: View {
    var body: some View {
        Group { if model.show { Text("a") } }.onChange(of: model.value) { _, _ in }
    }
}
/// Group whose child is a VStack with several rows (NowLiveSection's shape).
struct GroupVStack: View {
    var body: some View {
        Group { if model.show { VStack { Text("a"); Text("b"); Text("c") } } }.onChange(of: model.value) { _, _ in }
    }
}
/// The same with a stable container instead of Group.
struct StackToggle: View {
    var body: some View {
        VStack(spacing: 0) { if model.show { Text("a") } }.onChange(of: model.value) { _, _ in }
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = Model()
        let root: AnyView
        switch variant {
        case "groupTwo": root = AnyView(GroupTwo())
        case "groupToggle": root = AnyView(GroupToggle())
        case "groupVStack": root = AnyView(GroupVStack())
        case "stackToggle": root = AnyView(StackToggle())
        default: root = AnyView(Plain())
        }
        let origin: CGFloat = CommandLine.arguments.count > 2 ? -20000 : 0
        let w = NSWindow(contentRect: NSRect(x: origin, y: origin, width: 80, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: root)
        w.orderFrontRegardless()
        window = w
        Task.detached {
            for i in 0..<200 {
                await MainActor.run {
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
