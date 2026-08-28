// swift-tools-version: 6.0
import PackageDescription

let forbidden = ["Backing", "Connector", "Signaling", "Decoder", "Qualification"]
let package = Package(
	name: "ExternalNegativeConsumerProof",
	platforms: [.macOS(.v14)],
	dependencies: [.package(path: "../..")],
	targets: forbidden.map {
		.executableTarget(name: "Forbidden\($0)", dependencies: [.product(name: "RealtimeWebRTC", package: "airbridge-80-production-session-api")])
	}
)
