// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MK750",
  platforms: [.macOS(.v14)],
  products: [.library(name: "MK750Kit", targets: ["MK750Kit"])],
  targets: [
    .target(name: "MK750Kit", linkerSettings: [.linkedFramework("IOKit")])
  ],
  swiftLanguageModes: [.v5]
)
