import Foundation
import Testing
@testable import AgentSmithKit

/// `list_tasks`'s `is_template` / `has_parent_template` / `is_scheduled` filters are three-way
/// (`any` / `only` / `exclude`). As booleans, a model that fills in every optional argument sent
/// `false` on every call — which meant "exclude" — and every search silently dropped template
/// instances and scheduled tasks. On 2026-10-11 Smith missed 46 failed audit tasks that way.
@Suite("list_tasks property filters")
struct ListTasksPropertyFilterTests {

    private struct Fixture {
        let store: TaskStore
        let plain: AgentTask
        let instance: AgentTask
        let scheduled: AgentTask
        let template: AgentTask
    }

    private func makeFixture() async throws -> Fixture {
        let store = TaskStore()
        let template = await store.addTask(title: "Audit template", description: "d", isTemplate: true)
        let instance = try #require(await store.cloneTemplateInstance(templateID: template.id))
        let plain = await store.addTask(title: "Plain", description: "d")
        let scheduled = await store.addTask(title: "Later", description: "d", scheduledRunAt: Date().addingTimeInterval(3_600))
        return Fixture(store: store, plain: plain, instance: instance, scheduled: scheduled, template: template)
    }

    private func listedIDs(_ arguments: [String: AnyCodable], in store: TaskStore) async throws -> Set<String> {
        let result = try await ListTasksTool().execute(
            arguments: arguments,
            context: TestToolContext.make(agentRole: .smith, taskStore: store)
        )
        #expect(result.succeeded, "\(result.output)")
        let data = try #require(result.output.data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tasks = try #require(json["tasks"] as? [[String: Any]])
        return Set(tasks.compactMap { $0["id"] as? String })
    }

    @Test("the old boolean form is refused, never read as a filter — Smith's exact call no longer hides instances")
    func booleanFormIsRefused() async throws {
        let fixture = try await makeFixture()
        for key in ["is_template", "has_parent_template", "is_scheduled"] {
            var arguments: [String: AnyCodable] = [
                "is_template": .string("any"), "has_parent_template": .string("any"), "is_scheduled": .string("any")
            ]
            arguments[key] = .bool(false)
            let result = try await ListTasksTool().execute(
                arguments: arguments,
                context: TestToolContext.make(agentRole: .smith, taskStore: fixture.store)
            )
            #expect(result.succeeded == false, "\(key): a boolean must not be read as a filter")
            #expect(result.output.contains("any"), "\(key): the refusal must name the valid values: \(result.output)")
        }
    }

    @Test("any, absent and blank all mean no filter")
    func anyMeansNoFilter() async throws {
        let fixture = try await makeFixture()
        let everything = Set([fixture.plain, fixture.instance, fixture.scheduled, fixture.template].map(\.id.uuidString))
        let filled: [String: AnyCodable] = [
            "is_template": .string("any"), "has_parent_template": .string("any"), "is_scheduled": .string("any")
        ]
        let blank: [String: AnyCodable] = [
            "is_template": .string(""), "has_parent_template": .string(" "), "is_scheduled": .null
        ]
        #expect(try await listedIDs(filled, in: fixture.store) == everything)
        #expect(try await listedIDs([:], in: fixture.store) == everything)
        #expect(try await listedIDs(blank, in: fixture.store) == everything)
    }

    @Test("only and exclude narrow each property")
    func onlyAndExclude() async throws {
        let f = try await makeFixture()
        let id = { (task: AgentTask) in task.id.uuidString }

        #expect(try await listedIDs(["has_parent_template": .string("only")], in: f.store) == [id(f.instance)])
        #expect(try await listedIDs(["has_parent_template": .string("exclude")], in: f.store)
                == [id(f.plain), id(f.scheduled), id(f.template)])
        #expect(try await listedIDs(["is_template": .string("only")], in: f.store) == [id(f.template)])
        #expect(try await listedIDs(["is_template": .string("exclude")], in: f.store).contains(id(f.template)) == false)
        #expect(try await listedIDs(["is_scheduled": .string("only")], in: f.store) == [id(f.scheduled)])
        #expect(try await listedIDs(["is_scheduled": .string("exclude")], in: f.store).contains(id(f.scheduled)) == false)
    }

    @Test("an unknown value is refused with the valid ones")
    func unknownValueIsRefused() async throws {
        let fixture = try await makeFixture()
        let result = try await ListTasksTool().execute(
            arguments: ["is_scheduled": .string("yes")],
            context: TestToolContext.make(agentRole: .smith, taskStore: fixture.store)
        )
        #expect(result.succeeded == false)
        #expect(result.output.contains("any") && result.output.contains("only") && result.output.contains("exclude"))
    }

    @Test("the schema offers the three values with any first, as strings")
    func schemaShape() throws {
        guard case .dictionary(let properties)? = ListTasksTool().parameters["properties"] else {
            Issue.record("list_tasks has no properties")
            return
        }
        for key in ["is_template", "has_parent_template", "is_scheduled"] {
            guard case .dictionary(let property)? = properties[key] else {
                Issue.record("\(key) missing")
                continue
            }
            #expect(property["type"] == .string("string"), "\(key)")
            #expect(property["enum"] == .array([.string("any"), .string("only"), .string("exclude")]), "\(key)")
        }
    }

    @Test("a non-string value is echoed as the JSON the model sent, not as Swift enum cases",
          arguments: [
              (AnyCodable.bool(false), "false"),
              (AnyCodable.int(3), "3"),
              (AnyCodable.string("x") , "'x'"),
              (AnyCodable.array([.string("a\"b")]), #"["a\"b"]"#),
              (AnyCodable.dictionary(["k": .int(1), "a": .bool(true)]), #"{"a":true,"k":1}"#)
          ])
    func nonStringValueIsEchoedAsJSON(value: AnyCodable, expected: String) {
        guard case .failure(let error) = ListTasksPropertyFilter.read(["is_scheduled": value], "is_scheduled") else {
            Issue.record("expected a refusal for \(expected)")
            return
        }
        #expect(error.description.hasPrefix("Invalid is_scheduled: \(expected). "), "\(error.description)")
        #expect(!error.description.contains("AnyCodable") && !error.description.contains("bool("))
    }
}
