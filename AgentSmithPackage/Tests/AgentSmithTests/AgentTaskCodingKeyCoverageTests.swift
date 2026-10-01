import Testing
@testable import AgentSmithKit

/// `AgentTask` has hand-written Codable, so its key list is not synthesized. A stored property with a
/// default and no `CodingKeys` case is silently never persisted — and a round-trip test cannot see
/// it, because the field decodes back to the same default it started with. Reflection can.
@Suite("AgentTask Codable coverage")
struct AgentTaskCodingKeyCoverageTests {

    @Test("Every stored property has a CodingKeys case, by reflection")
    func everyStoredPropertyHasACodingKey() {
        let properties = Set(Mirror(reflecting: AgentTask(title: "t", description: "d")).children.compactMap(\.label))
        let keys = Set(AgentTask.CodingKeys.allCases.map(\.stringValue))
        let uncovered = properties.subtracting(keys).sorted()
        #expect(uncovered.isEmpty, """
            \(uncovered.joined(separator: ", ")) is a stored property of AgentTask with no CodingKeys \
            case, so it is never persisted. Add the case, and handle it in init(from:) and encode(to:).
            """)
        let stale = keys.subtracting(properties).sorted()
        #expect(stale.isEmpty, "CodingKeys cases with no stored property: \(stale.joined(separator: ", "))")
    }
}
