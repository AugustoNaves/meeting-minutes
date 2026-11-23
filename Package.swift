// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeetingMinutes",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MeetingMinutes",
            path: "Sources/MeetingMinutes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
