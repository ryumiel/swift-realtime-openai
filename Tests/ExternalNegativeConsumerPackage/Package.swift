// swift-tools-version: 6.0
import PackageDescription
import Foundation

let forbidden = ["Backing", "Connector", "Signaling", "Decoder", "Lifecycle", "Qualification"]
let forkPath = ProcessInfo.processInfo.environment["WEBRTC_FORK_PATH"] ?? "../.."
let package = Package(
	name: "ExternalNegativeConsumerProof",
	platforms: [.macOS(.v14)],
	dependencies: [.package(name: "RealtimeWebRTCFork", path: forkPath)],
	targets: forbidden.map {
		.executableTarget(name: "Forbidden\($0)", dependencies: [.product(name: "RealtimeWebRTC", package: "RealtimeWebRTCFork")])
	}
)
