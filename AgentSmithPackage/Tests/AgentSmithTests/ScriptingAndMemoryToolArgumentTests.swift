import Testing
import Foundation
@testable import AgentSmithKit

/// `run_applescript`, `list_scriptable_apps`, `get_app_scripting_schema` and `search_memory` (#30).
/// Only what is deterministic on any machine: argument validation and the refusals that come
/// before AppleScript runs or the embedding model loads.
@Suite("Scripting and memory tool arguments")
struct ScriptingAndMemoryToolArgumentTests {


    @Test("run_applescript: available to the worker only")
    func appleScriptAvailability() {
        #expect(RunAppleScriptTool().isAvailable(in: ToolAvailabilityContext(agentRole: .brown)))
        #expect(!RunAppleScriptTool().isAvailable(in: ToolAvailabilityContext(agentRole: .smith)))
    }

    @Test("run_applescript: a missing, empty or non-string script is refused")
    func appleScriptMissing() async {
        for arguments: [String: AnyCodable] in [[:], ["script": .string("")], ["script": .string("   \n")], ["script": .int(1)]] {
            await expectMissingArgument("script") { try await RunAppleScriptTool().execute(arguments: arguments, context: TestToolContext.make()) }
        }
    }

    @Test("list_scriptable_apps: a malformed flag is refused, not read as its default")
    func listAppsMalformedFlag() async throws {
        for key in ["scriptable_only", "non_standard_only"] {
            let result = try await ListScriptableAppsTool().execute(arguments: [key: .string("sometimes")], context: TestToolContext.make())
            #expect(!result.succeeded, "\(key)")
            #expect(result.output.contains(key))
        }
    }

    @Test("list_scriptable_apps: a query nothing matches is an empty success")
    func listAppsNoMatch() async throws {
        let result = try await ListScriptableAppsTool().execute(
            arguments: ["query": .string("zz-no-app-is-named-this-\(UUID().uuidString)"), "scriptable_only": .string("false")],
            context: TestToolContext.make()
        )
        #expect(result.succeeded)
    }

    @Test("get_app_scripting_schema: neither identifier (or only blank ones) is refused")
    func schemaNeedsAnIdentifier() async throws {
        for arguments: [String: AnyCodable] in [[:], ["bundle_id": .string(""), "app_name": .string("  ")], ["bundle_id": .null]] {
            let result = try await GetAppScriptingSchemaTool().execute(arguments: arguments, context: TestToolContext.make())
            #expect(!result.succeeded, "\(arguments)")
        }
    }

    @Test("get_app_scripting_schema: an app that isn't installed is refused")
    func schemaUnknownApp() async throws {
        let result = try await GetAppScriptingSchemaTool().execute(
            arguments: ["bundle_id": .string("com.example.not-installed.\(UUID().uuidString)")],
            context: TestToolContext.make()
        )
        #expect(!result.succeeded)
    }

    @Test("search_memory: a missing, blank or non-string query is refused before any search")
    func searchMemoryMissing() async {
        for arguments: [String: AnyCodable] in [[:], ["query": .string("")], ["query": .string(" \t\n")], ["query": .int(4)]] {
            await expectMissingArgument("query") { try await SearchMemoryTool().execute(arguments: arguments, context: TestToolContext.make()) }
        }
    }

    @Test("search_memory: a malformed limit is refused before any search")
    func searchMemoryMalformedLimit() async throws {
        for limit: AnyCodable in [.string("lots"), .string("2.5"), .double(2.5), .bool(true)] {
            let result = try await SearchMemoryTool().execute(arguments: ["query": .string("x"), "limit": limit], context: TestToolContext.make())
            #expect(!result.succeeded, "\(limit)")
            #expect(result.output.contains("limit"), "\(limit)")
        }
    }
}
