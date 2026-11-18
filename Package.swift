// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MK750",
  platforms: [
    .macOS("27.0")
  ],
  products: [
    .library(name: "MK750Kit", targets: ["MK750Kit"]),
    .executable(name: "MK750", targets: ["MK750"]),
  ],
  targets: [
    .target(
      name: "MK750Kit",
      linkerSettings: [
        .linkedFramework("IOKit")
      ]
    ),
    .executableTarget(
      name: "MK750",
      dependencies: ["MK750Kit"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("SwiftUI"),
      ]
    ),
    .testTarget(
      name: "MK750KitTests",
      dependencies: ["MK750Kit", "MK750"]
    ),
  ],
  // Swift 6 tools, Swift 5 language mode: IOKit's C API and its pointer
  // handling are not annotated for Swift 6 strict concurrency.
  swiftLanguageModes: [.v5]
)
