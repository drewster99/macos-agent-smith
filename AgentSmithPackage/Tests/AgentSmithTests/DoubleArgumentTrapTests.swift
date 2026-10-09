import Testing
import Foundation
@testable import AgentSmithKit

/// A model-supplied number that doesn't fit in an `Int` must never reach `Int(_:)`, which TRAPS —
/// one `{"limit": 1e300}` used to take the whole app down. Each tool here clamps the value, so the
/// call only has to come back; a regression crashes the test run.
@Suite("Double arguments never trap")
struct DoubleArgumentTrapTests {

    static let hostile: [Double] = [1e300, -1e300, .infinity, -.infinity, .nan, 9.223372036854776e18]

    @Test("saturatingInt clamps at Int's bounds and refuses non-finite values")
    func saturatingInt() {
        #expect(ToolArguments.saturatingInt(1e300) == Int.max)
        #expect(ToolArguments.saturatingInt(9.223372036854776e18) == Int.max)
        #expect(ToolArguments.saturatingInt(-1e300) == Int.min)
        #expect(ToolArguments.saturatingInt(.infinity) == nil)
        #expect(ToolArguments.saturatingInt(.nan) == nil)
        #expect(ToolArguments.saturatingInt(41.9) == 41)
        #expect(ToolArguments.saturatingInt(-3.5) == -3)
    }

    @Test("glob: limit and timeout")
    func glob() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        for value in Self.hostile {
            for key in ["limit", "timeout"] {
                let result = try await GlobTool(useSpotlight: false).execute(
                    arguments: ["pattern": .string("*"), "path": .string(dir.path), key: .double(value)],
                    context: TestToolContext.make()
                )
                #expect(result.succeeded, "\(key)=\(value)")
            }
        }
    }

    @Test("list_directory: limit and offset; directory_tree: max_depth")
    func directoryTools() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        for value in Self.hostile {
            for key in ["limit", "offset"] {
                _ = try await DirectoryListingTool().execute(arguments: ["path": .string(dir.path), key: .double(value)], context: TestToolContext.make())
            }
            _ = try await DirectoryTreeTool().execute(arguments: ["path": .string(dir.path), "max_depth": .double(value)], context: TestToolContext.make())
        }
    }

    @Test("web_search: max_results")
    func webSearch() {
        for value in Self.hostile {
            let clamped = WebSearchTool.clampedMaxResults(.double(value))
            #expect(clamped >= 1, "\(value)")
        }
    }

    @Test("manage_steps: a non-finite position is refused, a huge one is clamped by the plan, neither traps")
    func manageStepsPosition() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)
        for value in Self.hostile {
            _ = try await ManageStepsTool().execute(
                arguments: ["task_id": .string(task.id.uuidString), "action": .string("add"),
                            "text": .string("step"), "position": .double(value)],
                context: context
            )
        }
    }
}
