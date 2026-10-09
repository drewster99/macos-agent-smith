import Foundation

/// What a run's fresh task was cloned from. A start never runs a template, nor a task that
/// belongs to another session (#15), in place: both are cloned, and the clone is what runs.
enum ClonedRunSource: Sendable, Equatable {
    case template(UUID)
    case taskFromAnotherSession(UUID)

    /// The `.taskCreated` banner's lineage entry, naming the task the clone came from.
    var bannerLineageMetadata: [String: AnyCodable] {
        switch self {
        case .template(let id): ["clonedFromTemplate": .string(id.uuidString)]
        case .taskFromAnotherSession(let id): ["clonedFromTask": .string(id.uuidString)]
        }
    }
}

/// The steps every cloned run shares between being cloned and being started, in the one order
/// both start paths (`run_task` and the runtime's start chokepoint) need.
enum ClonedRunAnnouncement {
    /// Applies the run's one-off `amendment` to the CLONE (never to its source, or every later
    /// clone would inherit it), attaches context relevant to this run — fetched now, so a source
    /// run repeatedly picks up memories accumulated since it was authored — and posts the
    /// clone's `.taskCreated` banner. Returns the clone as announced.
    ///
    /// The amendment's result is discarded on purpose: the clone is `isTemplate: false`, so the
    /// template-only placeholder check has nothing to refuse, and bailing here would orphan a
    /// `.pending` clone that auto-advance starts later regardless.
    static func announce(
        clone: AgentTask,
        source: ClonedRunSource,
        amendment: String?,
        taskStore: TaskStore,
        retrieveContext: @Sendable (String) async -> SemanticSearchResults,
        post: @Sendable (ChannelMessage) async -> Void
    ) async -> AgentTask {
        if let amendment, !amendment.isEmpty {
            _ = await taskStore.amendDescription(id: clone.id, amendment: amendment)
        }
        let announced = await taskStore.task(id: clone.id) ?? clone
        let retrieved = await retrieveContext(announced.title + " " + announced.renderedDescriptionWithTemplateInputs())
        await TaskContextRetrieval.attachRelevantContext(taskID: clone.id, results: retrieved, taskStore: taskStore)
        await post(ChannelMessage(
            sender: .system,
            content: announced.title,
            metadata: [
                "messageKind": .kind(.taskCreated),
                "taskID": .string(announced.id.uuidString),
                "taskDescription": .string(announced.renderedDescriptionWithTemplateInputs())
            ]
            .merging(source.bannerLineageMetadata) { current, _ in current }
            .merging(announced.taskCreatedBannerCapabilitiesMetadata()) { current, _ in current }
        ))
        return announced
    }
}
