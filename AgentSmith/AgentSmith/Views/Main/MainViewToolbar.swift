import SwiftUI
import os

private let stopLogger = Logger(subsystem: "com.agentsmith", category: "Stop")

/// Primary-action toolbar for `MainView`. Renders the start/stop/reset run-control,
/// global mute, memory browser, clear-log, and inspector toggle. Pulled out of the
/// view body so the parent's modifier chain stays readable.
struct MainViewToolbar: ToolbarContent {
    @Bindable var viewModel: AppViewModel
    let shared: SharedAppState
    let onStart: () -> Void
    let onResetAndRestart: () -> Void
    let onOpenMemoryBrowser: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if viewModel.isRunning {
                // Cmd+Shift+K is bound on the "Emergency Stop" menu item in
                // AgentSmithApp's CommandGroup; binding it here too caused a SwiftUI
                // shortcut collision where neither responded. The toolbar button still
                // works on click — the shortcut routes through the menu.
                Button("Stop All", systemImage: "stop.circle.fill", role: .destructive) {
                    stopLogger.notice("UI.toolbar StopAll button clicked → dispatching stopAll")
                    Task {
                        stopLogger.notice("UI.toolbar StopAll Task body running")
                        await viewModel.stopAll()
                        stopLogger.notice("UI.toolbar StopAll Task body returned")
                    }
                }
                .foregroundStyle(.red)
            } else if viewModel.isAborted {
                Button("Reset & Restart", systemImage: "arrow.clockwise.circle.fill",
                       action: onResetAndRestart)
                    .foregroundStyle(.orange)
            } else {
                Button("Start", systemImage: "play.circle.fill", action: onStart)
                    .foregroundStyle(.green)
            }

            if shared.speechController.isGloballyEnabled {
                Button("Mute All", systemImage: "speaker.wave.2.fill") {
                    shared.speechController.setGloballyEnabled(false)
                }
            } else {
                Button("Unmute All", systemImage: "speaker.slash.fill") {
                    shared.speechController.setGloballyEnabled(true)
                }
                .foregroundStyle(.secondary)
            }

            Button("Memory Browser", systemImage: "brain", action: onOpenMemoryBrowser)

            Button("Clear Log", systemImage: "trash") {
                viewModel.clearLog()
            }
            .disabled(viewModel.messages.isEmpty)

            // Jones-visibility chip — surfaces the silent gatekeeper. Total reviews
            // and any flagged ones (denied / WARN that didn't auto-approve on retry).
            // Hidden until at least one review has happened so the toolbar doesn't
            // carry a "0" pre-first-task. Click opens the inspector where the full
            // evaluation log lives.
            let safetyTotal = viewModel.inspectorStore.evaluationRecords.count
            let safetyFlagged = viewModel.inspectorStore.flaggedEvaluationCount
            if safetyTotal > 0 {
                Button(action: { viewModel.showInspector = true }, label: {
                    Label(
                        safetyFlagged > 0 ? "\(safetyTotal) · \(safetyFlagged) flagged" : "\(safetyTotal)",
                        systemImage: safetyFlagged > 0 ? "shield.lefthalf.filled.trianglebadge.exclamationmark" : "shield.lefthalf.filled"
                    )
                })
                .foregroundStyle(safetyFlagged > 0 ? .orange : .secondary)
                .help(safetyFlagged > 0
                      ? "Jones safety reviews — \(safetyTotal) total, \(safetyFlagged) flagged. Click to open the inspector."
                      : "Jones safety reviews — \(safetyTotal) total. Click to open the inspector.")
            }

            Button(viewModel.showInspector ? "Hide Inspector" : "Show Inspector",
                   systemImage: "sidebar.right") {
                viewModel.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
