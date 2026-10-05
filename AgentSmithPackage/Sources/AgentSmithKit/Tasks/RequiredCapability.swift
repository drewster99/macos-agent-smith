import Foundation

/// One ability a task's worker needs, stated in terms of what it must DO ("Compile the Xcode
/// project", "Read the user's calendar"), never as a tool name.
///
/// Its own field rather than prose at the bottom of the description (decided 2026-10-05, user):
/// the Security Agent's tool scoping is told to pay special attention to it, and when a running
/// worker turns out to lack something, Smith ADDS the unmet need here — with the reason — instead
/// of granting a tool. A later addition stays visibly marked as one everywhere the list is shown.
public struct RequiredCapability: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var text: String
    /// Who wrote this item.
    public let addedBy: TaskAuthorship
    public let addedAt: Date
    /// Whether this item was part of the task as written or was added after the task existed.
    public var origin: Origin
    /// Why this item was added. Smith always gives one for a later addition; nil when the author
    /// gave none (the items a task is written with, or one the user added in the editor).
    public let reason: String?

    public enum Origin: String, Codable, Sendable {
        /// Part of the task as written: `create_task`, the editor's Create, or carried into a
        /// template instance when it was created.
        case asWritten
        /// Added after the task existed — the unmet need of a running worker, typically.
        case addedLater

        /// Forward compatibility: an origin this build doesn't know is shown as a later addition,
        /// the reading that asks the most of a reader's attention, rather than failing the decode
        /// of the whole task.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Origin(rawValue: raw) ?? .addedLater
        }
    }

    public init(
        id: UUID = UUID(),
        text: String,
        addedBy: TaskAuthorship,
        addedAt: Date = Date(),
        origin: Origin,
        reason: String? = nil
    ) {
        self.id = id
        self.text = text
        self.addedBy = addedBy
        self.addedAt = addedAt
        self.origin = origin
        self.reason = reason
    }

    /// The item as every agent-facing reader shows it: the text, and for a later addition who
    /// added it, when, and why.
    public var renderedLine: String {
        switch origin {
        case .asWritten:
            return text
        case .addedLater:
            let why = reason.map { ": \($0)" } ?? ""
            return "\(text) [added later by \(addedBy.displayName), \(addedAt.formatted(.iso8601))\(why)]"
        }
    }

    /// The comparison key for "is this already listed": case- and whitespace-insensitive, so a
    /// re-sent addition doesn't stack a near-identical line.
    var normalizedText: String { Self.comparisonKey(for: text) }

    static func comparisonKey(for text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    /// Items of a task as written (`create_task`, `create_child_task`, the editor's Create): trimmed,
    /// blanks dropped, duplicates (by `comparisonKey`) dropped keeping the first spelling.
    public static func makeAsWritten(_ texts: [String], addedBy author: TaskAuthorship) -> [RequiredCapability] {
        var seen = Set<String>()
        return texts.compactMap { raw in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(comparisonKey(for: text)).inserted else { return nil }
            return RequiredCapability(text: text, addedBy: author, origin: .asWritten)
        }
    }
}

/// Why a task's required capabilities can't change now.
public enum RequiredCapabilitiesLockReason: Sendable, Equatable {
    /// A completed task's definition is history; follow-up work is a successor task.
    case completed
    /// Validators read this list as context while judging; changing it mid-round would judge
    /// criteria of one round against different lists (the description and step plan are frozen
    /// for the same reason).
    case validating
    /// Archived or deleted — outside the store's writable set.
    case notInActiveList

    public func refusal(taskTitle: String) -> String {
        switch self {
        case .completed:
            return "Task \"\(taskTitle)\" is completed; its definition is history. Create a successor task for follow-up work."
        case .validating:
            return "Task \"\(taskTitle)\" is being validated; its required capabilities can't change while validators judge the result. Add it after validation ends — if any criterion is rejected the task returns to running; if it completes, follow-up work is a successor task."
        case .notInActiveList:
            return "Task \"\(taskTitle)\" is archived or deleted; restore it first."
        }
    }
}

extension AgentTask {
    /// Why this task's required capabilities can't change now; nil when they can. The ONE rule every
    /// writer (`TaskStore`) and every editing surface (Task Detail, the task editor) asks. Running
    /// and awaiting help stay editable on purpose: that is when a worker's unmet need is learned.
    public var requiredCapabilitiesLockReason: RequiredCapabilitiesLockReason? {
        guard disposition == .active else { return .notInActiveList }
        switch status {
        case .completed: return .completed
        case .validating: return .validating
        case .pending, .starting, .running, .failed, .paused, .awaitingReview, .awaitingHelp, .interrupted, .scheduled:
            return nil
        }
    }

    /// Whether the task editor / inline description edit may open: an editable status AND in the
    /// active list. An archived or deleted task is outside the store's writable sets, so every save
    /// there would be refused "Task not found".
    public var isDefinitionEditable: Bool { disposition == .active && status.isDescriptionEditable }
}

/// One change to an existing task's required capabilities.
public enum RequiredCapabilityEdit: Sendable, Equatable {
    case add(text: String, reason: String?)
    case reword(id: UUID, text: String)
    case remove(id: UUID)
}

/// One editor row: an existing item (its id) or a new one (nil).
public struct RequiredCapabilityDraft: Sendable, Equatable {
    public let existingID: UUID?
    public let text: String

    public init(existingID: UUID?, text: String) {
        self.existingID = existingID
        self.text = text
    }
}

extension RequiredCapabilityEdit {
    /// The edits turning `original` (the list the editor opened with) into `drafts` (its rows, in
    /// order). A blank row is no item: an existing item cleared to blank is a removal, a new blank row
    /// is nothing — the rule steps and criteria use. Removals come first so a reword or add may reuse
    /// a removed item's wording. Only ids from `original` are touched, so an item added meanwhile
    /// (Smith, the Task Detail field) survives the save.
    public static func edits(from original: [RequiredCapability], to drafts: [RequiredCapabilityDraft]) -> [RequiredCapabilityEdit] {
        let draftTextByID = Dictionary(
            drafts.compactMap { draft in draft.existingID.map { ($0, draft.text.trimmingCharacters(in: .whitespacesAndNewlines)) } },
            uniquingKeysWith: { first, _ in first }
        )
        var removals: [RequiredCapabilityEdit] = []
        var rewords: [RequiredCapabilityEdit] = []
        for item in original {
            guard let text = draftTextByID[item.id], !text.isEmpty else {
                removals.append(.remove(id: item.id))
                continue
            }
            if text != item.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                rewords.append(.reword(id: item.id, text: text))
            }
        }
        let additions = drafts.compactMap { draft -> RequiredCapabilityEdit? in
            guard draft.existingID == nil else { return nil }
            let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .add(text: text, reason: nil)
        }
        return removals + rewords + additions
    }
}

extension RequiredCapability {
    /// How a later addition is attributed for a PERSON (Task Detail, the editor, the PDF, the copy
    /// button, the creation banner): a localized date, where agents get `renderedLine`'s ISO stamp.
    /// Nil for an item that was part of the task as written.
    public var laterAdditionCaption: String? {
        guard origin == .addedLater else { return nil }
        return Self.laterAdditionCaption(addedBy: addedBy, addedAt: addedAt, reason: reason)
    }

    /// The one people-facing wording, shared by the list rendering and `RequiredCapabilityProvenanceLabel`.
    public static func laterAdditionCaption(addedBy: TaskAuthorship, addedAt: Date, reason: String?) -> String {
        let added = "Added later by \(addedBy.displayName), \(addedAt.formatted(date: .abbreviated, time: .shortened))"
        guard let reason else { return added }
        return "\(added) — \(reason)"
    }
}

extension TaskAuthorship {
    /// How an author is named where a later addition is attributed ("added later by Smith").
    public var displayName: String {
        switch self {
        case .user: return "the user"
        case .smith: return "Smith"
        case .worker: return "the worker"
        case .system: return "the system"
        }
    }
}

/// What `TaskStore.addRequiredCapability` did. "Already listed" is distinct from "added" because
/// only an addition changes what the worker's tools are scoped against.
public enum RequiredCapabilityAddition: Sendable, Equatable {
    case added(RequiredCapability)
    case alreadyListed(RequiredCapability)
    case refused(String)
}
