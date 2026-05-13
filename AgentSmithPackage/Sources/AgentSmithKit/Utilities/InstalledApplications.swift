import Foundation

/// AppleScript / Apple-Event scripting metadata extracted from an app's `.sdef`.
struct ScriptingDefinition: Sendable, Hashable {
    /// Path to the `.sdef` file inside the app bundle.
    let url: URL
    /// Suite names declared in the sdef.
    let suiteNames: [String]
    /// `true` when the app declares any suite whose code is not the Standard
    /// Suite sentinel (`????`) — i.e. exposes app-specific scripting beyond
    /// open/close/quit/count/etc.
    let exposesNonStandardSuite: Bool
    /// Compact, human-readable rendering of the schema (see `SdefRenderer`).
    let renderedSchema: String

    public init(url: URL, suiteNames: [String], exposesNonStandardSuite: Bool, renderedSchema: String) {
        self.url = url
        self.suiteNames = suiteNames
        self.exposesNonStandardSuite = exposesNonStandardSuite
        self.renderedSchema = renderedSchema
    }
}

/// Metadata for a single installed application discovered on disk.
struct InstalledApplication: Sendable, Hashable {
    /// File URL of the `.app` bundle.
    let url: URL
    /// `CFBundleShortVersionString`, falling back to `CFBundleVersion`. `nil` when the
    /// bundle exposes neither (rare — usually a malformed or partially-installed app).
    let version: String?
    /// Bundle identifier from `Info.plist`, when present.
    let bundleIdentifier: String?
    /// Scripting metadata, when the app ships an `.sdef` file. `nil` for apps
    /// that aren't AppleScript-scriptable.
    let scripting: ScriptingDefinition?

    public init(
        url: URL,
        version: String?,
        bundleIdentifier: String?,
        scripting: ScriptingDefinition?
    ) {
        self.url = url
        self.version = version
        self.bundleIdentifier = bundleIdentifier
        self.scripting = scripting
    }
}

/// Process-wide cache of the installed-application scan. Built lazily on first
/// access so multiple tools share a single scan instead of each triggering a
/// fresh disk walk.
actor InstalledApplicationsRegistry {
    static let shared = InstalledApplicationsRegistry()

    private let scanner = InstalledApplicationsScanner()
    private var cached: [InstalledApplication]?
    private var indexByBundleID: [String: InstalledApplication] = [:]

    public init() {}

    /// Returns the cached scan, performing a fresh scan on first access.
    public func all() async -> [InstalledApplication] {
        if let cached { return cached }
        let apps = await scanner.scan()
        cached = apps
        indexByBundleID = Dictionary(
            apps.compactMap { app in app.bundleIdentifier.map { ($0, app) } },
            uniquingKeysWith: { first, _ in first }
        )
        return apps
    }

    /// Look up an app by exact bundle identifier (case-insensitive).
    public func find(bundleID: String) async -> InstalledApplication? {
        _ = await all()
        if let exact = indexByBundleID[bundleID] { return exact }
        let lower = bundleID.lowercased()
        return indexByBundleID.first { $0.key.lowercased() == lower }?.value
    }

    /// Fuzzy match by bundle identifier or app filename. Substring, case-insensitive.
    /// Returned entries are ranked: exact bundle-ID match first, then prefix
    /// matches on app name, then any substring match.
    public func find(matching query: String) async -> [InstalledApplication] {
        let apps = await all()
        let q = query.lowercased()
        guard !q.isEmpty else { return apps }

        var exact: [InstalledApplication] = []
        var prefix: [InstalledApplication] = []
        var contains: [InstalledApplication] = []

        for app in apps {
            let name = app.url.deletingPathExtension().lastPathComponent.lowercased()
            let bid = app.bundleIdentifier?.lowercased() ?? ""
            if bid == q || name == q { exact.append(app) }
            else if name.hasPrefix(q) || bid.hasPrefix(q) { prefix.append(app) }
            else if name.contains(q) || bid.contains(q) { contains.append(app) }
        }
        return exact + prefix + contains
    }

    /// Force a fresh disk scan, replacing the cache.
    public func refresh() async {
        cached = nil
        indexByBundleID = [:]
        _ = await all()
    }
}

/// Enumerates `.app` bundles in every standard macOS Applications directory
/// (`/Applications`, `~/Applications`, `/System/Applications`, the Cryptexes
/// system-app paths, `Utilities`, etc.) by querying
/// `FileManager.urls(for: .allApplicationsDirectory, in: .allDomainsMask)`,
/// then recursively walking each directory (descending into non-bundle
/// subfolders, pruning at `.app` boundaries).
///
/// Filesystem and XML I/O are hopped to a background `DispatchQueue` so the
/// actor's executor isn't blocked while scanning.
actor InstalledApplicationsScanner {

    public init() {}

    /// Scan every standard application directory and return all valid `.app`
    /// bundles found, deduplicated by resolved path.
    public func scan() async -> [InstalledApplication] {
        let directories = FileManager.default.urls(
            for: .allApplicationsDirectory,
            in: .allDomainsMask
        )
        return await Self.scan(directories: directories)
    }

    /// Scan an arbitrary set of root directories. Exposed for tests and for
    /// callers that want to point the scanner at a custom location.
    public func scan(roots: [URL]) async -> [InstalledApplication] {
        await Self.scan(directories: roots)
    }

    private static func scan(directories: [URL]) async -> [InstalledApplication] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: enumerate(directories: directories))
            }
        }
    }

    private static func enumerate(directories: [URL]) -> [InstalledApplication] {
        let fm = FileManager.default
        var seen = Set<String>()
        var results: [InstalledApplication] = []

        for dir in directories {
            for appURL in findApps(in: dir, fm: fm) {
                let resolved = appURL.resolvingSymlinksInPath().standardizedFileURL
                guard seen.insert(resolved.path).inserted else { continue }

                let info = readInfoPlist(at: resolved)
                let version = (info?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (info?["CFBundleVersion"] as? String)
                let bundleID = info?["CFBundleIdentifier"] as? String
                let scripting = SdefLocator.locate(in: resolved, info: info).flatMap(SdefParser.parse(at:))

                results.append(InstalledApplication(
                    url: resolved,
                    version: version,
                    bundleIdentifier: bundleID,
                    scripting: scripting
                ))
            }
        }

        results.sort {
            $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
        }
        return results
    }

    /// Recursively find `.app` bundles under `root`, descending into ordinary
    /// subdirectories and pruning at bundle boundaries.
    private static func findApps(in root: URL, fm: FileManager) -> [URL] {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var apps: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "app" else { continue }
            if isValidAppBundle(url, fm: fm) {
                apps.append(url)
            }
            // .skipsPackageDescendants already prevents recursion into the .app's contents.
        }
        return apps
    }

    /// An `.app` is valid only if it has `Contents/Info.plist` as a regular file.
    private static func isValidAppBundle(_ url: URL, fm: FileManager) -> Bool {
        let infoPlist = url.appendingPathComponent("Contents/Info.plist")
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: infoPlist.path, isDirectory: &isDir) && !isDir.boolValue
    }

    private static func readInfoPlist(at appURL: URL) -> [String: Any]? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist
    }
}

// MARK: - sdef location

private enum SdefLocator {
    /// Resolve the `.sdef` URL for an app bundle. Honors `OSAScriptingDefinition`
    /// from `Info.plist` first; falls back to `<AppName>.sdef` and finally to
    /// any single `.sdef` in `Contents/Resources`.
    static func locate(in appURL: URL, info: [String: Any]?) -> URL? {
        let resources = appURL.appendingPathComponent("Contents/Resources")
        let fm = FileManager.default

        if let declared = info?["OSAScriptingDefinition"] as? String, !declared.isEmpty {
            let url = resources.appendingPathComponent(declared)
            if fm.fileExists(atPath: url.path) { return url }
        }

        let appName = appURL.deletingPathExtension().lastPathComponent
        let conventional = resources.appendingPathComponent("\(appName).sdef")
        if fm.fileExists(atPath: conventional.path) { return conventional }

        if let entries = try? fm.contentsOfDirectory(atPath: resources.path) {
            let sdefs = entries.filter { $0.hasSuffix(".sdef") }
            if sdefs.count == 1 {
                return resources.appendingPathComponent(sdefs[0])
            }
        }
        return nil
    }
}

// MARK: - sdef parsing & rendering

/// Parsed in-memory model of an sdef. Intentionally minimal — captures only
/// what we want to expose to LLM tool callers (suites, classes, properties,
/// elements, commands, enums) and discards the Cocoa keys, documentation
/// HTML, access groups, etc.
private struct SdefSchema: Sendable, Hashable {
    public struct Suite: Sendable, Hashable {
        public let name: String
        public let code: String
        public let description: String?
        public let classes: [Class]
        public let commands: [Command]
        public let enumerations: [Enumeration]
    }
    public struct Class: Sendable, Hashable {
        public let name: String
        public let extends: String?
        public let description: String?
        public let properties: [Property]
        public let elements: [String]
        public let respondsTo: [String]
    }
    public struct Property: Sendable, Hashable {
        public let name: String
        public let type: String?
        public let access: String?
        public let description: String?
    }
    public struct Command: Sendable, Hashable {
        public let name: String
        public let description: String?
        public let directParameter: String?
        public let parameters: [Parameter]
        public let resultType: String?
    }
    public struct Parameter: Sendable, Hashable {
        public let name: String
        public let type: String?
        public let optional: Bool
    }
    public struct Enumeration: Sendable, Hashable {
        public let name: String
        public let cases: [Case]
    }
    public struct Case: Sendable, Hashable {
        public let name: String
        public let description: String?
    }

    let suites: [Suite]
}

private enum SdefParser {
    /// Standard Suite always carries this code; suites with any other code
    /// expose app-specific scripting.
    private static let standardSuiteCode = "????"

    static func parse(at url: URL) -> ScriptingDefinition? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        let options: XMLNode.Options = [.nodeLoadExternalEntitiesNever]
        guard let doc = try? XMLDocument(data: data, options: options) else { return nil }

        let suiteNodes = (try? doc.nodes(forXPath: "//suite")) as? [XMLElement] ?? []
        guard !suiteNodes.isEmpty else { return nil }

        let suites = suiteNodes.compactMap(parseSuite)
        let names = suites.map { $0.name }
        let nonStandard = suiteNodes.contains { $0.attribute(forName: "code")?.stringValue != standardSuiteCode }

        let schema = SdefSchema(suites: suites)
        let rendered = SdefRenderer.render(schema)

        return ScriptingDefinition(
            url: url,
            suiteNames: names,
            exposesNonStandardSuite: nonStandard,
            renderedSchema: rendered
        )
    }

    private static func parseSuite(_ node: XMLElement) -> SdefSchema.Suite? {
        guard let name = node.attribute(forName: "name")?.stringValue else { return nil }
        let code = node.attribute(forName: "code")?.stringValue ?? ""
        let description = node.attribute(forName: "description")?.stringValue

        var classes: [SdefSchema.Class] = []
        var commands: [SdefSchema.Command] = []
        var enumerations: [SdefSchema.Enumeration] = []

        for child in node.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch child.name {
            case "class", "class-extension":
                if let parsed = parseClass(child) { classes.append(parsed) }
            case "command":
                if let parsed = parseCommand(child) { commands.append(parsed) }
            case "enumeration":
                if let parsed = parseEnumeration(child) { enumerations.append(parsed) }
            default:
                break
            }
        }

        return SdefSchema.Suite(
            name: name,
            code: code,
            description: description,
            classes: classes,
            commands: commands,
            enumerations: enumerations
        )
    }

    private static func parseClass(_ node: XMLElement) -> SdefSchema.Class? {
        let name = node.attribute(forName: "name")?.stringValue
            ?? node.attribute(forName: "extends")?.stringValue
        guard let resolvedName = name else { return nil }

        let extends = node.attribute(forName: "extends")?.stringValue
        let description = node.attribute(forName: "description")?.stringValue

        var properties: [SdefSchema.Property] = []
        var elements: [String] = []
        var respondsTo: [String] = []

        for child in node.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch child.name {
            case "property":
                if let n = child.attribute(forName: "name")?.stringValue {
                    properties.append(SdefSchema.Property(
                        name: n,
                        type: typeOf(child),
                        access: child.attribute(forName: "access")?.stringValue,
                        description: child.attribute(forName: "description")?.stringValue
                    ))
                }
            case "element":
                if let t = child.attribute(forName: "type")?.stringValue {
                    elements.append(t)
                }
            case "responds-to":
                if let c = child.attribute(forName: "command")?.stringValue
                    ?? child.attribute(forName: "name")?.stringValue {
                    respondsTo.append(c)
                }
            default:
                break
            }
        }

        return SdefSchema.Class(
            name: resolvedName,
            extends: extends,
            description: description,
            properties: properties,
            elements: elements,
            respondsTo: respondsTo
        )
    }

    private static func parseCommand(_ node: XMLElement) -> SdefSchema.Command? {
        guard let name = node.attribute(forName: "name")?.stringValue else { return nil }
        let description = node.attribute(forName: "description")?.stringValue

        var directParameter: String?
        var parameters: [SdefSchema.Parameter] = []
        var resultType: String?

        for child in node.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch child.name {
            case "direct-parameter":
                directParameter = typeOf(child) ?? child.attribute(forName: "description")?.stringValue
            case "parameter":
                if let n = child.attribute(forName: "name")?.stringValue {
                    parameters.append(SdefSchema.Parameter(
                        name: n,
                        type: typeOf(child),
                        optional: child.attribute(forName: "optional")?.stringValue == "yes"
                    ))
                }
            case "result":
                resultType = typeOf(child)
            default:
                break
            }
        }

        return SdefSchema.Command(
            name: name,
            description: description,
            directParameter: directParameter,
            parameters: parameters,
            resultType: resultType
        )
    }

    private static func parseEnumeration(_ node: XMLElement) -> SdefSchema.Enumeration? {
        guard let name = node.attribute(forName: "name")?.stringValue else { return nil }
        let cases: [SdefSchema.Case] = (node.children?.compactMap { $0 as? XMLElement } ?? [])
            .filter { $0.name == "enumerator" }
            .compactMap { e in
                guard let n = e.attribute(forName: "name")?.stringValue else { return nil }
                return SdefSchema.Case(name: n, description: e.attribute(forName: "description")?.stringValue)
            }
        return SdefSchema.Enumeration(name: name, cases: cases)
    }

    /// Resolve the type of a `<parameter>`, `<direct-parameter>`, or `<result>`.
    /// Either declared via a `type` attribute or one or more `<type>` child
    /// elements; the latter form may include `list="yes"` to mark an array.
    private static func typeOf(_ node: XMLElement) -> String? {
        if let attr = node.attribute(forName: "type")?.stringValue { return attr }

        let typeChildren = (node.children?.compactMap { $0 as? XMLElement } ?? [])
            .filter { $0.name == "type" }
        guard !typeChildren.isEmpty else { return nil }

        let parts: [String] = typeChildren.compactMap { t in
            guard let base = t.attribute(forName: "type")?.stringValue else { return nil }
            return t.attribute(forName: "list")?.stringValue == "yes" ? "[\(base)]" : base
        }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }
}

/// Compact text rendering of an `SdefSchema`, optimized for prompt-stuffing.
private enum SdefRenderer {
    public static func render(_ schema: SdefSchema) -> String {
        var lines: [String] = []
        for suite in schema.suites {
            lines.append("SUITE \(suite.name)")
            for e in suite.enumerations {
                lines.append("  ENUM \(e.name)")
                for c in e.cases {
                    if let d = c.description, !d.isEmpty {
                        lines.append("    \(c.name) — \(d)")
                    } else {
                        lines.append("    \(c.name)")
                    }
                }
            }
            for cls in suite.classes {
                let header = cls.extends.map { "CLASS \(cls.name) (extends \($0))" } ?? "CLASS \(cls.name)"
                lines.append("  \(header)")
                for p in cls.properties {
                    var line = "    PROP \(p.name)"
                    if let t = p.type { line += " : \(t)" }
                    if let a = p.access { line += " [\(a)]" }
                    if let d = p.description, !d.isEmpty { line += " — \(d)" }
                    lines.append(line)
                }
                for elem in cls.elements {
                    lines.append("    ELEM \(elem)")
                }
                if !cls.respondsTo.isEmpty {
                    lines.append("    RESPONDS \(cls.respondsTo.joined(separator: ", "))")
                }
            }
            for cmd in suite.commands {
                var head = "  CMD \(cmd.name)"
                if let dp = cmd.directParameter { head += "(\(dp))" }
                if let r = cmd.resultType { head += " → \(r)" }
                lines.append(head)
                for p in cmd.parameters {
                    let opt = p.optional ? "?" : ""
                    let type = p.type.map { ":\($0)" } ?? ""
                    lines.append("    \(p.name)\(opt)\(type)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
