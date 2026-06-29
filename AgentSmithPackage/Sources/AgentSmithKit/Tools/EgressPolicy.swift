import Foundation

/// Decides whether a URL's destination is a **non-public** address — loopback, link-local,
/// RFC1918 private, CGNAT (RFC 6598), IPv6 ULA, IPv4-mapped-private, or the unspecified address.
///
/// Used only by `web_fetch`'s redirect guard: a *direct* request is never gated here (the security
/// agent, Jones, evaluates the URL the model explicitly chose), but a silent 30x redirect into
/// private space bypasses that review entirely, so those hops are refused. Hostnames are resolved
/// before classification so a public name that points at a private IP is still caught.
enum EgressPolicy {

    /// An IP address as a family + raw network-order bytes (4 for IPv4, 16 for IPv6).
    struct IPAddress: Equatable, Sendable {
        enum Family: Sendable { case v4, v6 }
        let family: Family
        let bytes: [UInt8]
    }

    /// True if `url`'s host is, or resolves to, a non-public address. A missing host fails closed
    /// (blocked). Unresolvable hostnames return `false` — we let the request proceed and fail
    /// naturally rather than hard-blocking an unknown name.
    static func destinationIsNonPublic(_ url: URL) async -> Bool {
        guard let rawHost = url.host, !rawHost.isEmpty else { return true }
        let host = rawHost.lowercased()
        if host == "localhost" || host == "localhost."
            || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if let literal = classifyLiteral(host) { return literal }
        let resolved = await resolve(host)
        if resolved.isEmpty { return false }
        return resolved.contains { isNonPublic($0) }
    }

    /// Classifies a host that is an IP **literal**. Returns `nil` when `host` is not an IP literal
    /// (i.e. it's a name that must be resolved first).
    static func classifyLiteral(_ host: String) -> Bool? {
        let stripped = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        if let v4 = parseIPv4(stripped) { return isNonPublic(v4) }
        if let v6 = parseIPv6(stripped) { return isNonPublic(v6) }
        return nil
    }

    static func parseIPv4(_ s: String) -> IPAddress? {
        var addr = in_addr()
        guard s.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        var be = addr.s_addr
        let bytes = withUnsafeBytes(of: &be) { Array($0) }   // 4 bytes, network order
        return IPAddress(family: .v4, bytes: bytes)
    }

    static func parseIPv6(_ s: String) -> IPAddress? {
        var addr = in6_addr()
        guard s.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &addr) { Array($0) }  // 16 bytes, network order
        return IPAddress(family: .v6, bytes: bytes)
    }

    static func isNonPublic(_ ip: IPAddress) -> Bool {
        switch ip.family {
        case .v4: return isNonPublicV4(ip.bytes)
        case .v6: return isNonPublicV6(ip.bytes)
        }
    }

    /// IPv4 ranges treated as non-public. `b[0]` is the first octet.
    static func isNonPublicV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return true }   // malformed → fail closed
        switch b[0] {
        case 0:   return true                       // 0.0.0.0/8 (incl. unspecified)
        case 10:  return true                       // 10.0.0.0/8
        case 127: return true                       // 127.0.0.0/8 loopback
        case 169: return b[1] == 254                // 169.254.0.0/16 link-local
        case 172: return (16...31).contains(b[1])   // 172.16.0.0/12
        case 192: return b[1] == 168                // 192.168.0.0/16
        case 100: return (64...127).contains(b[1])  // 100.64.0.0/10 CGNAT (RFC 6598)
        default:  return false
        }
    }

    /// IPv6 ranges treated as non-public, including IPv4-mapped addresses (classified by the
    /// embedded v4) so `::ffff:127.0.0.1` can't slip through an IPv4-only check.
    static func isNonPublicV6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }
        if b.allSatisfy({ $0 == 0 }) { return true }                          // :: unspecified
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }    // ::1 loopback
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return isNonPublicV4(Array(b[12..<16]))                           // ::ffff:0:0/96
        }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }              // fe80::/10 link-local
        if (b[0] & 0xfe) == 0xfc { return true }                             // fc00::/7 ULA
        return false
    }

    /// Resolves a hostname to all of its A/AAAA addresses. Runs blocking `getaddrinfo` off the
    /// cooperative pool; returns `[]` on failure.
    static func resolve(_ host: String) async -> [IPAddress] {
        await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var info: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &info) == 0 else { return [] }
            defer { if info != nil { freeaddrinfo(info) } }

            var results: [IPAddress] = []
            var cursor = info
            while let node = cursor {
                let ai = node.pointee
                if let sa = ai.ai_addr {
                    if ai.ai_family == AF_INET {
                        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                            var be = p.pointee.sin_addr.s_addr
                            let bytes = withUnsafeBytes(of: &be) { Array($0) }
                            results.append(IPAddress(family: .v4, bytes: bytes))
                        }
                    } else if ai.ai_family == AF_INET6 {
                        sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                            var a = p.pointee.sin6_addr
                            let bytes = withUnsafeBytes(of: &a) { Array($0) }
                            results.append(IPAddress(family: .v6, bytes: bytes))
                        }
                    }
                }
                cursor = ai.ai_next
            }
            return results
        }.value
    }
}
