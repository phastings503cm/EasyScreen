// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EasyScreen",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "EasyScreen",
            path: "Sources/EasyScreen",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "EasyScreenTests",
            dependencies: ["EasyScreen"],
            path: "Tests/EasyScreenTests"
        ),
    ]
)
