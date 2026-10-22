// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

#if os(macOS)
let coreTraits: Set<Trait> = [.default(enabledTraits: ["Zenzai"]), "Zenzai", "ZenzaiCPU"]
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = [
    .trait(name: "Zenzai", condition: .when(traits: ["Zenzai"])),
    .trait(name: "ZenzaiCPU", condition: .when(traits: ["ZenzaiCPU"]))
]
#else
let coreTraits: Set<Trait> = ["ZenzaiCPU"]
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = [
    .trait(name: "ZenzaiCPU", condition: .when(traits: ["ZenzaiCPU"]))
]
#endif

#if os(Windows)
// SwiftPM 6.2 on Windows waits for the plugin tool as "<name>" while it links
// "<name>-tool.exe", so the build never starts. Version info comes from the
// Windows frontend's own resources instead.
let corePlugins: [Target.PluginUsage] = []
let coreSwiftSettings: [SwiftSetting] = [.interoperabilityMode(.Cxx), .define("AZOOKEY_GIT_INFO_UNAVAILABLE")]
#else
let corePlugins: [Target.PluginUsage] = [.plugin(name: "GitInfoPlugin")]
let coreSwiftSettings: [SwiftSetting] = [.interoperabilityMode(.Cxx)]
#endif

let products: [Product] = [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
        name: "Core",
        targets: ["Core"]
    ),
    .executable(name: "azookey-desktop-bridge", targets: ["DesktopBridge"])
]

let targets: [Target] = [
    .executableTarget(name: "DesktopBridge", dependencies: ["Core"], swiftSettings: [.interoperabilityMode(.Cxx)]),
    .testTarget(name: "DesktopBridgeTests", dependencies: ["DesktopBridge"], swiftSettings: [.interoperabilityMode(.Cxx)]),
    .executableTarget(
        name: "git-info-generator"
    ),
    .plugin(
        name: "GitInfoPlugin",
        capability: .buildTool(),
        dependencies: [.target(name: "git-info-generator")]
    ),
    .target(
        name: "Core",
        dependencies: [
            .product(name: "SwiftUtils", package: "AzooKeyKanaKanjiConverter"),
            .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter"),
            .product(name: "Crypto", package: "swift-crypto"),
            // ZIPFoundation needs system zlib headers, which the Windows SDK does not ship.
            .product(name: "ZIPFoundation", package: "ZIPFoundation", condition: .when(platforms: [.macOS, .linux]))
        ],
        resources: [.process("Resources")],
        swiftSettings: coreSwiftSettings,
        plugins: corePlugins
    ),
    .testTarget(
        name: "CoreTests",
        dependencies: ["Core", "DictionaryLockProbe"],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    ),
    // Only the test target launches this helper; the bridge and library do not depend on it.
    .executableTarget(
        name: "DictionaryLockProbe",
        path: "Tests/DictionaryLockProbe"
    )
]

let package = Package(
    name: "Core",
    defaultLocalization: "ja",
    platforms: [.macOS(.v13)],
    products: products,
    traits: coreTraits,
    dependencies: [
        .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", revision: "04ce2ec3afe2bd6f92fcae1dc15a2357d332c27a", traits: kanaKanjiConverterTraits),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0")
    ],
    targets: targets
)
