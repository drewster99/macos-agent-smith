import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `EgressPolicy` — the IP/host classifier behind web_fetch's redirect guard. Only the
/// pure literal-classification path is unit-tested (DNS resolution depends on the resolver).
@Suite("Egress policy")
struct EgressPolicyTests {

    @Test("IPv4 literals: loopback / private / link-local / CGNAT / unspecified are non-public")
    func ipv4NonPublic() {
        for host in [
            "127.0.0.1", "127.1.2.3",
            "10.0.0.1", "10.255.255.255",
            "172.16.0.1", "172.31.255.255",
            "192.168.0.1", "192.168.1.1",
            "169.254.169.254",            // cloud metadata / link-local
            "100.64.0.1", "100.127.255.255", // CGNAT
            "0.0.0.0"
        ] {
            #expect(EgressPolicy.classifyLiteral(host) == true, "\(host) should be non-public")
        }
    }

    @Test("IPv4 literals: public addresses (incl. just-outside-range) are public")
    func ipv4Public() {
        for host in [
            "8.8.8.8", "1.1.1.1", "93.184.216.34",
            "172.15.0.1", "172.32.0.1",   // just outside 172.16/12
            "100.63.0.1", "100.128.0.1",  // just outside 100.64/10
            "192.169.0.1", "11.0.0.1"
        ] {
            #expect(EgressPolicy.classifyLiteral(host) == false, "\(host) should be public")
        }
    }

    @Test("IPv6 literals: loopback / link-local / ULA / unspecified / IPv4-mapped-private are non-public")
    func ipv6NonPublic() {
        for host in [
            "::1",                         // loopback
            "::",                          // unspecified
            "fe80::1",                     // link-local
            "fc00::1", "fd12:3456:789a::1", // ULA
            "::ffff:127.0.0.1",            // IPv4-mapped loopback
            "::ffff:10.0.0.1"              // IPv4-mapped private
        ] {
            #expect(EgressPolicy.classifyLiteral(host) == true, "\(host) should be non-public")
        }
    }

    @Test("IPv6 literals: public addresses are public")
    func ipv6Public() {
        for host in ["2606:4700:4700::1111", "2001:4860:4860::8888", "::ffff:8.8.8.8"] {
            #expect(EgressPolicy.classifyLiteral(host) == false, "\(host) should be public")
        }
    }

    @Test("bracketed IPv6 literals are unwrapped before classification")
    func bracketedIPv6() {
        #expect(EgressPolicy.classifyLiteral("[::1]") == true)
        #expect(EgressPolicy.classifyLiteral("[2606:4700:4700::1111]") == false)
    }

    @Test("non-literals return nil (they require DNS resolution)")
    func nonLiterals() {
        #expect(EgressPolicy.classifyLiteral("example.com") == nil)
        #expect(EgressPolicy.classifyLiteral("not-an-ip") == nil)
        #expect(EgressPolicy.classifyLiteral("999.999.999.999") == nil)
    }

    @Test("destinationIsNonPublic: localhost names and literal private hosts are blocked; missing host blocked")
    func destinationChecks() async throws {
        let local = try #require(URL(string: "http://localhost:8080/admin"))
        #expect(await EgressPolicy.destinationIsNonPublic(local) == true)

        let dotLocal = try #require(URL(string: "http://printer.local/status"))
        #expect(await EgressPolicy.destinationIsNonPublic(dotLocal) == true)

        let loopbackLiteral = try #require(URL(string: "http://127.0.0.1/x"))
        #expect(await EgressPolicy.destinationIsNonPublic(loopbackLiteral) == true)

        let metadata = try #require(URL(string: "http://169.254.169.254/latest/meta-data/"))
        #expect(await EgressPolicy.destinationIsNonPublic(metadata) == true)
    }
}
