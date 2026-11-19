// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FLSStoreKit",
    platforms: [.iOS(.v17)],
    products: [.library(name: "FLSStoreKit", targets: ["FLSStoreKit"])],
    targets: [
        .target(name: "FLSStoreKit"),
        .testTarget(name: "FLSStoreKitTests", dependencies: ["FLSStoreKit"])
    ]
)
