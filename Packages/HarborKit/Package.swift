// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarborCore", targets: ["HarborCore"]),
        .library(name: "HarborUI", targets: ["HarborUI"]),
        .executable(name: "harbor-mcp", targets: ["HarborMCPBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.8.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
    ],
    targets: [
        // Foundation-level models, settings, persistence and stream parsers.
        .target(name: "HarborCore"),
        .target(name: "HarborLogging", dependencies: ["HarborCore"]),

        // Pseudo-terminal spawning. The fork/exec path lives in C so the child only
        // runs async-signal-safe code.
        .target(name: "CHarborPTY"),
        .target(name: "HarborPTY", dependencies: ["CHarborPTY", "HarborCore", "HarborLogging"]),

        .target(
            name: "HarborShell",
            dependencies: ["HarborCore", "HarborLogging"],
            resources: [.copy("Resources/integration")]
        ),
        .target(name: "HarborSSH", dependencies: ["HarborCore", "HarborLogging", "HarborPTY"]),
        .target(name: "HarborFiles", dependencies: ["HarborCore", "HarborLogging", "HarborSSH"]),

        // The automation contract shared by MCP and the web remote.
        .target(name: "HarborControl", dependencies: ["HarborCore"]),
        .target(
            name: "HarborSessions",
            dependencies: ["HarborCore", "HarborLogging", "HarborPTY", "HarborShell", "HarborSSH", "HarborControl"]
        ),
        .target(name: "HarborMCP", dependencies: ["HarborCore", "HarborLogging", "HarborControl"]),
        .target(
            name: "HarborRemote",
            dependencies: [
                "HarborCore", "HarborLogging", "HarborControl",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            resources: [.copy("Resources/web")]
        ),
        .target(name: "HarborDoctor", dependencies: ["HarborCore", "HarborLogging", "HarborSSH", "HarborShell"]),
        // Provisioning on remote hosts (shell integration) over the shared SSH connection.
        .target(name: "HarborHostSetup", dependencies: ["HarborCore", "HarborLogging", "HarborSSH", "HarborShell", "HarborFiles"]),
        .target(
            name: "HarborUI",
            dependencies: [
                "HarborCore", "HarborLogging", "HarborPTY", "HarborShell", "HarborSSH", "HarborFiles",
                "HarborControl", "HarborSessions", "HarborMCP", "HarborRemote", "HarborDoctor", "HarborHostSetup",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(name: "HarborMCPBridge", dependencies: ["HarborCore"]),

        .testTarget(name: "HarborCoreTests", dependencies: ["HarborCore"]),
        .testTarget(name: "HarborPTYTests", dependencies: ["HarborPTY"]),
        .testTarget(name: "HarborShellTests", dependencies: ["HarborShell", "HarborPTY"]),
        .testTarget(name: "HarborSSHTests", dependencies: ["HarborSSH"]),
        .testTarget(name: "HarborFilesTests", dependencies: ["HarborFiles", "HarborSSH"]),
        .testTarget(name: "HarborControlTests", dependencies: ["HarborControl"]),
        .testTarget(name: "HarborSessionsTests", dependencies: ["HarborSessions", "HarborShell", "HarborControl", "HarborSSH"]),
        .testTarget(name: "HarborMCPTests", dependencies: ["HarborMCP", "HarborMCPBridge"]),
        .testTarget(name: "HarborRemoteTests", dependencies: ["HarborRemote"]),
        .testTarget(name: "HarborDoctorTests", dependencies: ["HarborDoctor"]),
        .testTarget(name: "HarborUITests", dependencies: ["HarborUI", "HarborCore", "HarborSessions", "HarborFiles", "HarborSSH"]),
        .testTarget(name: "HarborHostSetupTests", dependencies: ["HarborHostSetup", "HarborFiles", "HarborSSH", "HarborShell"]),
    ]
)
