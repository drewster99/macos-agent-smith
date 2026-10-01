import SwiftUI
import AppKit
import Observation
import QuartzCore

// Realistic bursts: 3-6 separate main hops with 0-6ms gaps, every 30-90ms, 600 bursts.
// Each strategy decides WHEN the watched value is actually written.
let strategy = CommandLine.arguments.dropFirst().first ?? "direct"

@Observable @MainActor final class Model { var value: Int = 0 }
@MainActor var model: Model!

struct Watch: View {
    var body: some View { Text("x").onChange(of: model.value) { _, _ in } }
}

@MainActor final class Coalescer {
    var pending = 0
    var scheduled = false
    var link: CADisplayLink?
    func add(_ n: Int) {
        pending += n
        switch strategy {
        case "nextTurn":
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { self.flush() }
        case "timer16", "timer25busy":
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (strategy == "timer16" ? 0.016 : 0.025)) { self.flush() }
        case "displayLink", "displayLinkbusy":
            break // flushed by the display link
        default:
            flush()
        }
    }
    func flush() {
        scheduled = false
        guard pending != 0 else { return }
        model.value += pending
        pending = 0
    }
    @objc func tick(_ link: CADisplayLink) { flush() }
}
@MainActor var coalescer: Coalescer!

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = Model()
        coalescer = Coalescer()
        let view = NSHostingView(rootView: Watch())
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        w.orderFrontRegardless()
        window = w
        if strategy.hasSuffix("busy") {
            // A main thread that is intermittently busy for longer than a frame, as at app launch.
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in usleep(60_000) }
        }
        if strategy == "displayLink" || strategy == "displayLinkbusy" {
            let link = view.displayLink(target: coalescer!, selector: #selector(Coalescer.tick(_:)))
            link.add(to: .main, forMode: .common)
            coalescer.link = link
        }
        Task.detached {
            for _ in 0..<600 {
                let hops = Int.random(in: 3...6)
                for _ in 0..<hops {
                    await MainActor.run { coalescer.add(1) }
                    try? await Task.sleep(for: .microseconds(Int.random(in: 0...6000)))
                }
                try? await Task.sleep(for: .milliseconds(Int.random(in: 30...90)))
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
