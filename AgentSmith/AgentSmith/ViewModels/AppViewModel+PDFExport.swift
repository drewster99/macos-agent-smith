import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentSmithKit

/// Task → PDF export entry points used by the task list context menu, the task-detail
/// "Save as PDF" sheet, and the in-transcript "Task Completed" banner.
extension AppViewModel {
    /// Renders `task` to PDF with the given field selection and opens it in the user's
    /// default viewer (Preview). Used by the non-configurable task-list "PDF" action.
    func exportTaskPDFAndOpen(_ task: AgentTask, options: TaskPDFFieldOptions) async {
        guard let (data, filename) = await buildTaskPDF(task, options: options) else {
            taskActionError = "Could not generate a PDF for this task."
            return
        }
        // Per-task subdirectory so two tasks with the same title don't overwrite each
        // other's temp file. Re-exporting the same task reuses (overwrites) its own file.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TaskPDFs", isDirectory: true)
            .appendingPathComponent(task.id.uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            taskActionError = "Could not write the PDF: \(error.localizedDescription)"
        }
    }

    /// Renders `task` to PDF with the user's chosen field selection and prompts for a save
    /// location. Used by the task-detail "Save as PDF" sheet.
    func saveTaskPDF(_ task: AgentTask, options: TaskPDFFieldOptions) async {
        guard let (data, filename) = await buildTaskPDF(task, options: options) else {
            taskActionError = "Could not generate a PDF for this task."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        // `begin` (vs `runModal`) suspends the Swift continuation without blocking the main
        // run loop, so other main-actor work keeps flowing while the panel is up.
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            taskActionError = "Could not save the PDF: \(error.localizedDescription)"
        }
    }

    /// Exports the transcript-preset PDF for a "Task Completed" banner. Resolves the full
    /// task by ID so the PDF carries the description and completion time; if the original
    /// task has been permanently deleted, falls back to the banner's own fields.
    func exportTaskCompletedBannerPDF(
        taskID: UUID,
        fallbackTitle: String,
        fallbackResult: String?,
        fallbackTimestamp: Date
    ) async {
        let task = tasks.first { $0.id == taskID } ?? AgentTask(
            id: taskID,
            title: fallbackTitle,
            description: "",
            status: .completed,
            result: fallbackResult,
            completedAt: fallbackTimestamp
        )
        await exportTaskPDFAndOpen(task, options: .transcript)
    }

    /// Computes token/cost totals (only when the matching option is enabled) directly from a
    /// fresh usage-record fetch, renders the document, and returns the PDF bytes plus a
    /// suggested filename.
    ///
    /// Computing directly — rather than via `loadTaskCost`/`loadTaskTokens` — avoids the
    /// in-flight-guarded cache, which can early-return before it's populated and would then
    /// silently drop the Cost row from the document.
    private func buildTaskPDF(
        _ task: AgentTask,
        options: TaskPDFFieldOptions
    ) async -> (data: Data, filename: String)? {
        var tokens: TaskTokenTotals?
        var cost: Double?
        if options.tokens || options.cost {
            let records = await shared.usageStore.records(for: task.id)
            if options.tokens { tokens = tokenTotals(from: records) }
            if options.cost { cost = estimatedCost(from: records) }
        }
        guard let data = TaskPDFExporter.makePDFData(
            for: task,
            options: options,
            tokens: tokens,
            cost: cost,
            generatedAt: Date()
        ) else { return nil }
        return (data, TaskPDFExporter.sanitizedFilename(for: task))
    }
}
