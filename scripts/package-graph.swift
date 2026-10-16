// The package graph, checked. Stoic is a framework of separately adoptable
// libraries (DESIGN.md, Architecture), and that only holds while the graph
// between them is the one written down here:
//
//   1. Every library's dependencies on the package's other targets are ones
//      the layering below allows. A new edge is an architecture change, made
//      here in the same diff, where a reviewer sees it.
//   2. A target imports only targets it declares as dependencies. SwiftPM
//      lets a target import a module some other target happened to build
//      first, so an undeclared import passes in this package's build and
//      fails in an app that adopts the library alone.
//   3. A target declares only dependencies it imports, so adopting a
//      library never builds one it does not use.
//
//   swift package dump-package > graph.json
//   swift scripts/package-graph.swift graph.json
//
// scripts/check.sh runs it.

import Foundation

/// What each library may depend on, among the package's own targets. The
/// layers: the core and the JSON layer stand alone; schemas sit on JSON;
/// persistence, observability, test support and Foundation's error table
/// sit on the core; settings and HTTP compose those; the Apple libraries sit
/// on the core and the Foundation table, and nothing portable ever depends
/// on one of them.
let layering: [String: Set<String>] = [
    "Stoic": [],
    "StoicJSON": [],
    "StoicSchema": ["StoicJSON"],
    "StoicSchemaTesting": ["StoicSchema", "StoicJSON"],
    "StoicTesting": ["Stoic"],
    "StoicStore": ["Stoic"],
    "StoicObservability": ["Stoic"],
    "StoicSettings": ["Stoic", "StoicSchema", "StoicStore", "StoicJSON"],
    "StoicFoundation": ["Stoic"],
    "StoicHTTP": ["Stoic", "StoicFoundation", "StoicSchema", "StoicJSON"],
    "StoicApple": ["Stoic", "StoicFoundation"],
    "StoicAppKit": ["Stoic"],
    "StoicUIKit": ["Stoic"],
    "StoicMacros": ["StoicSchema", "StoicMacrosPlugin"],
    "StoicMacrosPlugin": [],
    "StoicLintCore": [],
    "stoic-lint": ["StoicLintCore"],
    "StoicLint": ["stoic-lint"],
]

/// Dependencies a target needs without importing them: a macro's compiler
/// plugin, and the tool a build plugin runs.
let notImported: Set<String> = ["StoicMacrosPlugin", "stoic-lint"]

struct Target {
    var name: String
    var type: String
    var path: String?
    var dependencies: Set<String>
}

func loadTargets(_ path: String) throws -> [Target] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let package = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let targets = package["targets"] as? [[String: Any]]
    else { throw GraphError("\(path) is not the output of `swift package dump-package`") }
    return targets.compactMap { target in
        guard let name = target["name"] as? String, let type = target["type"] as? String else { return nil }
        var dependencies: Set<String> = []
        for dependency in target["dependencies"] as? [[String: Any]] ?? [] {
            // Only dependencies on this package's targets: `byName` and
            // `target`. Products of other packages are not part of the graph.
            for key in ["byName", "target"] {
                if let entry = dependency[key] as? [Any], let name = entry.first as? String {
                    dependencies.insert(name)
                }
            }
        }
        return Target(name: name, type: type, path: target["path"] as? String, dependencies: dependencies)
    }
}

struct GraphError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The modules a Swift file imports, whatever the access level or kind:
/// `import X`, `public import X`, `@preconcurrency internal import X`,
/// `import struct X.Y`. Imports under `#if` count: a conditional import is
/// still a dependency on the platforms where it is compiled.
func imports(in text: String) -> Set<String> {
    var modules: Set<String> = []
    let modifiers: Set<String> = ["public", "package", "internal", "private", "fileprivate", "@_exported", "@testable"]
    let kinds: Set<String> = ["struct", "class", "enum", "protocol", "typealias", "func", "let", "var"]
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let first = words.first, modifiers.contains(first) || first.hasPrefix("@") { words.removeFirst() }
        guard words.first == "import", words.count >= 2 else { continue }
        var module = words[1]
        if kinds.contains(module), words.count >= 3 { module = words[2] }
        if let dot = module.firstIndex(of: ".") { module = String(module[..<dot]) }
        modules.insert(module)
    }
    return modules
}

func swiftFiles(under directory: String) -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: directory) else { return [] }
    return walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.map { directory + "/" + $0 }
}

func directory(of target: Target) -> String {
    if let path = target.path { return path }
    switch target.type {
    case "test": return "Tests/\(target.name)"
    case "plugin": return "Plugins/\(target.name)"
    default: return "Sources/\(target.name)"
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard let graphPath = arguments.first else {
    print("usage: swift scripts/package-graph.swift <output of swift package dump-package>")
    exit(2)
}

var problems: [String] = []
let targets = try loadTargets(graphPath)
let names = Set(targets.map(\.name))
let byName = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) })

/// Every target `name` depends on, directly or not, itself included.
func closure(_ name: String) -> Set<String> {
    var seen: Set<String> = []
    var pending = [name]
    while let next = pending.popLast() {
        guard seen.insert(next).inserted else { continue }
        pending.append(contentsOf: byName[next]?.dependencies.intersection(names) ?? [])
    }
    return seen
}

for target in targets.sorted(by: { $0.name < $1.name }) {
    let declared = target.dependencies.intersection(names)

    // 1. The layering. Test targets may depend on whatever they test.
    if target.type != "test" {
        if let allowed = layering[target.name] {
            for edge in declared.subtracting(allowed).sorted() {
                problems.append(
                    "\(target.name) depends on \(edge), which the layering does not allow. If the architecture should change, change `layering` in scripts/package-graph.swift in the same diff."
                )
            }
        } else {
            problems.append(
                "\(target.name) is not in the layering. Add it to `layering` in scripts/package-graph.swift with the targets it may depend on."
            )
        }
    }

    // Plugins are not Swift modules that import their dependencies.
    guard target.type != "plugin" else { continue }

    var imported: Set<String> = []
    var importers: [String: String] = [:]
    for file in swiftFiles(under: directory(of: target)) {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            problems.append("\(file) could not be read")
            continue
        }
        for module in imports(in: text).intersection(names) where module != target.name {
            imported.insert(module)
            importers[module] = importers[module] ?? file
        }
    }

    // 2. Every import declared, directly: a module reached through another
    // dependency is lost the day that dependency stops needing it.
    for module in imported.subtracting(declared).sorted() {
        let file = importers[module] ?? target.name
        if let via = declared.sorted().first(where: { closure($0).contains(module) }) {
            problems.append(
                "\(file) imports \(module), which \(target.name) reaches only through \(via). Declare \(module) as a direct dependency of \(target.name)."
            )
        } else {
            problems.append(
                "\(file) imports \(module), but \(target.name) does not depend on it. It builds here only because another target built \(module) first; a build of \(target.name) alone fails. Declare the dependency."
            )
        }
    }
    // 3. Every declaration imported.
    for module in declared.subtracting(imported).subtracting(notImported).sorted() {
        problems.append(
            "\(target.name) declares a dependency on \(module) but never imports it, so adopting \(target.name) builds a library it does not use. Remove the dependency."
        )
    }
}

if problems.isEmpty {
    print("package graph: \(targets.count) targets, every edge allowed, declared and used")
} else {
    print("package graph: \(problems.count) problem(s)")
    for problem in problems { print("  error: \(problem)") }
    exit(1)
}
