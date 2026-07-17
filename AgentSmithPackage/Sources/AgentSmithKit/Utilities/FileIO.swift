import Foundation

/// Off-actor bulk file I/O. Foundation has no efficient async equivalent of `Data(contentsOf:)` /
/// `Data.write(to:)` (the async file APIs are byte-streaming sequences), so a large read/write on an
/// actor's serial executor would both stall that actor and hold a cooperative-pool thread for the
/// whole transfer. These helpers run the synchronous call on a dedicated serial background queue and
/// bridge it back with a continuation, so the caller only suspends.
///
/// The queue is SERIAL on purpose: concurrent large writes don't compete for disk, and same-file
/// operations can't interleave. Use this only for large, independent snapshot reads / atomic
/// whole-file writes — NOT for read-modify-write sequences, whose atomicity must be guaranteed by
/// the caller's own isolation (e.g. `PersistenceManager.appendChannelMessages` stays synchronous).
public enum FileIO {
    private static let queue = DispatchQueue(label: "com.agentsmith.fileio", qos: .utility)

    /// Reads a file's full contents off the calling actor's executor.
    public static func read(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try Data(contentsOf: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Writes bytes to a file off the calling actor's executor. Defaults to an atomic (temp-file +
    /// rename) write so a crash mid-write can't leave a truncated file.
    public static func write(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try data.write(to: url, options: options)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Reads and JSON-decodes a file off the calling actor's executor. Both the read AND the decode
    /// run on the background queue — for a large snapshot (e.g. `inactive_tasks.json`) the decode of
    /// tens of thousands of objects is the expensive part, so leaving it on the actor would defeat
    /// the purpose. Uses a default `JSONDecoder` (constructed inside the closure to stay Sendable).
    public static func readJSON<T: Decodable & Sendable>(_ type: T.Type, from url: URL) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let data = try Data(contentsOf: url)
                    continuation.resume(returning: try JSONDecoder().decode(T.self, from: data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// JSON-encodes a value and writes it off the calling actor's executor (encode + write both on
    /// the background queue). Atomic by default. Uses a default `JSONEncoder`.
    public static func writeJSON<T: Encodable & Sendable>(_ value: T, to url: URL, options: Data.WritingOptions = .atomic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let data = try JSONEncoder().encode(value)
                    try data.write(to: url, options: options)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
