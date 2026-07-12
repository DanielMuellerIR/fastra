// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Fastra",
    defaultLocalization: "de",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Fastra", targets: ["Fastra"])
    ],
    dependencies: [
        .package(url: "https://github.com/CodeEditApp/CodeEditSourceEditor", from: "0.15.0"),
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages",   from: "0.1.20"),
        // Transitive Abhängigkeit von CodeEditSourceEditor — hier explizit
        // deklariert, damit der Selbsttest `--selftest-jump` die echte
        // Editor-Selektion (`TextView.selectedRange()`) typsicher zurücklesen
        // kann. Version an den bereits resolveten Stand gepinnt (0.12.1), die
        // Auflösung bleibt dadurch ein No-op.
        .package(url: "https://github.com/CodeEditApp/CodeEditTextView",     from: "0.12.1"),
        // RegEx-Token-Highlighting (Phase 3): die offizielle tree-sitter-
        // Grammatik für reguläre Ausdrücke. Exakt gepinnt — die Grammatik
        // definiert unsere Token-Typen (node-types.json), ein stiller Bump
        // könnte das Mapping in RegexTokenizer brechen. Achtung Tag-Falle:
        // v1.0.0 ist ein ALTES Tag von 2023 OHNE Swift-Binding; die aktuelle
        // Release-Linie ist 0.2x (v0.25.0 = 2025-09, mit Package.swift).
        .package(url: "https://github.com/tree-sitter/tree-sitter-regex", exact: "0.25.0"),
        // Transitiv schon via CodeEditSourceEditor im Graph (ChimeHQ, 0.25.0
        // resolved) — hier explizit, damit unser RegexTokenizer die
        // Parser-/Node-API typsicher nutzen kann.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.25.0"),
        // Markdown-Vorschau (Phase 5, v0.8): GFM-Rendering (Tabellen,
        // Task-Listen, Code-Blöcke) als SwiftUI-View. Entscheidung siehe
        // ROADMAP H — hohe Priorität (Daniel-Präferenz).
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "Fastra",
            dependencies: [
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
                .product(name: "CodeEditLanguages",    package: "CodeEditLanguages"),
                .product(name: "CodeEditTextView",     package: "CodeEditTextView"),
                .product(name: "TreeSitterRegex",      package: "tree-sitter-regex"),
                .product(name: "SwiftTreeSitter",      package: "SwiftTreeSitter"),
                .product(name: "MarkdownUI",           package: "swift-markdown-ui"),
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "FastraTests",
            dependencies: ["Fastra"]
        ),
    ]
)
