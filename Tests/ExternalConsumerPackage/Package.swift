// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "ExternalConsumerProof",
	platforms: [.macOS(.v14)],
	dependencies: [.package(path: "../..")],
	targets: [
		.executableTarget(
			name: "ExternalConsumerProof",
			dependencies: [.product(name: "RealtimeWebRTC", package: "airbridge-80-production-session-api")]
		),
	]
)
