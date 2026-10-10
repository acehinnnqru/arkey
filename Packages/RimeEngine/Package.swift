// swift-tools-version: 6.0
import PackageDescription

// The engine layer is a plain SwiftPM package so that it can be developed and tested on
// macOS (swift test) against the same librime build the keyboard extension links.
let package = Package(
  name: "RimeEngine",
  defaultLocalization: "zh-Hans",
  platforms: [
    .macOS(.v13),
    .iOS(.v16),
  ],
  products: [
    .library(name: "RimeEngine", targets: ["RimeEngine"]),
    .executable(name: "rime-deploy", targets: ["rime-deploy"]),
    .executable(name: "rime-capture-check", targets: ["rime-capture-check"]),
  ],
  dependencies: [
    // Binary packaging of upstream librime. Pinned exactly: the prebuilt tables shipped in
    // RimeData/build are produced by this version and must match it at runtime.
    .package(url: "https://github.com/ghostflyby/librime-xcframework", exact: "1.17.0-pack.9.0.2"),
  ],
  targets: [
    .target(
      name: "RimeEngine",
      dependencies: [
        // Headers/module only. Wrapper libraries depend on Rime and choose a binary below.
        .product(name: "Rime", package: "librime-xcframework"),
        // Link-only stub: emits -framework RimeDynamic and no artifact, so the app embeds
        // exactly one copy and the keyboard extension resolves it through its runpath.
        .product(name: "RimeDynamicStub", package: "librime-xcframework"),
      ],
      resources: [.process("Resources")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "rime-release-check",
      dependencies: [
        "RimeEngine",
        // Same reason as rime-deploy: a standalone macOS executable carries the real framework,
        // because RimeEngine links against a stub that only emits -framework RimeDynamic.
        .product(name: "RimeDynamic", package: "librime-xcframework"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // S3 §2.3's measuring stick, so a device screenshot is one command rather than a Swift file.
    .executableTarget(
      name: "rime-capture-check",
      dependencies: [
        "RimeEngine",
        .product(name: "RimeDynamic", package: "librime-xcframework"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "rime-deploy",
      dependencies: [
        "RimeEngine",
        // The tool is a macOS executable that runs standalone, so it carries the real
        // framework instead of the stub.
        .product(name: "RimeDynamic", package: "librime-xcframework"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "RimeEngineTests",
      dependencies: [
        "RimeEngine",
        .product(name: "RimeDynamic", package: "librime-xcframework"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
