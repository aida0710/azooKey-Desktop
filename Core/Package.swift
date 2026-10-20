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
            .product(name: "ZIPFoundation", package: "ZIPFoundation")
        ],
        resources: [.process("Resources")],
        swiftSettings: [.interoperabilityMode(.Cxx)],
        plugins: [
            .plugin(name: "GitInfoPlugin")
        ]
    ),
    .testTarget(
        name: "CoreTests",
        dependencies: ["Core"],
        swiftSettings: [.interoperabilityMode(.Cxx)]
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
