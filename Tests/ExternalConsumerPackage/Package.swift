// swift-tools-version: 6.0
import PackageDescription
import Foundation

let forkPath = ProcessInfo.processInfo.environment["WEBRTC_FORK_PATH"] ?? "../.."

let package = Package(
	name: "ExternalConsumerProof",
	platforms: [.macOS(.v14)],
	dependencies: [.package(name: "RealtimeWebRTCFork", path: forkPath)],
	targets: [
		.executableTarget(
			name: "ExternalConsumerProof",
			dependencies: [.product(name: "RealtimeWebRTC", package: "RealtimeWebRTCFork")]
		),
	]
)
