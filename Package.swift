// swift-tools-version: 6.0
import Foundation
import PackageDescription

// With only the Command Line Tools active (no Xcode), SwiftPM 6.4's `swift test` omits Swift Testing's macro plugin
// directory, so `@Test`/`#expect` fail to expand ("plugin for module 'TestingMacros' not found"). Pass it explicitly
// in that setup only. Test target only: packages that depend on PokerEngine never see this flag.
let commandLineTools = "/Library/Developer/CommandLineTools"
let commandLineToolsTestingPlugins = commandLineTools + "/usr/lib/swift/host/plugins/testing"
let activeDeveloperDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
let testingPluginWorkaround: [SwiftSetting] =
    activeDeveloperDirectory?.hasPrefix(commandLineTools) == true
        && FileManager.default.fileExists(atPath: commandLineToolsTestingPlugins)
        ? [.unsafeFlags(["-plugin-path", commandLineToolsTestingPlugins])]
        : []

// PokerHandEvaluator's tables and helpers are C globals with generic names (`choose`, `dp`, `flush`, …) that could
// collide with symbols in an app linking PokerEngine. Prefix them at compile time; the vendored files stay unmodified.
let vendoredEvaluatorSymbols = [
    "bit_of_div_4", "bit_of_mod_4_x_3", "choose", "dp", "flush", "hash_quinary", "noflush5", "noflush6", "noflush7", "suits",
]

let package = Package(
    name: "PokerEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PokerEngine", targets: ["PokerEngine"]),
        .library(name: "PokerEngineObservation", targets: ["PokerEngineObservation"]),
    ],
    targets: [
        // Vendored, unmodified PokerHandEvaluator sources. No unsafeFlags here, so the package stays usable as a
        // dependency (`.define` is a safe setting).
        .target(
            name: "CHandEvaluator",
            exclude: ["LICENSE"],
            publicHeadersPath: "include",
            cSettings: vendoredEvaluatorSymbols.map { .define($0, to: "pokerengine_phe_\($0)") }
        ),
        .target(
            name: "PokerEngine",
            dependencies: ["CHandEvaluator"]
        ),
        .target(
            name: "PokerEngineObservation",
            dependencies: ["PokerEngine"]
        ),
        .testTarget(
            name: "PokerEngineTests",
            dependencies: ["PokerEngine", "PokerEngineObservation"],
            // Read through #filePath by the tests, not bundled as resources.
            exclude: ["Fixtures"],
            swiftSettings: testingPluginWorkaround
        ),
    ],
    swiftLanguageModes: [.v6]
)
