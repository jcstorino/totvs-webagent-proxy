// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "totvs-webagent-proxy",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "totvs-webagent-proxy", targets: ["WebAgentProxy"])],
    targets: [.executableTarget(name: "WebAgentProxy")]
)
