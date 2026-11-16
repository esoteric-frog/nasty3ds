// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nasty3DS",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CN3Host",
            cSettings: [.headerSearchPath("."), .unsafeFlags(["-I/opt/homebrew/include"])],
            linkerSettings: [.unsafeFlags(["-L/opt/homebrew/lib", "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib"]), .linkedLibrary("MoltenVK")]
        ),
        .target(name: "Nasty3DSKit"),
        .executableTarget(
            name: "Nasty3DS",
            dependencies: ["CN3Host", "Nasty3DSKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "Nasty3DSKitTests", dependencies: ["Nasty3DSKit"]),
    ]
)
