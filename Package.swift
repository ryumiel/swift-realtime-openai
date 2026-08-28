// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "RealtimeAPI",
	platforms: [
		.iOS(.v17),
		.tvOS(.v17),
		.macOS(.v14),
		.visionOS(.v1),
		.macCatalyst(.v17),
	],
	products: [
		.library(name: "RealtimeCore", targets: ["Core"]),
		.library(name: "RealtimeWebRTC", targets: ["WebRTC"]),
	],
	dependencies: [
		.package(
			url: "https://github.com/livekit/webrtc-xcframework.git",
			revision: "46f2af86f06b9a8a9158d37cadda5cb5a214e4c4"
		),
		.package(
			url: "https://github.com/SwiftyLab/MetaCodable.git",
			revision: "3d4bfeb949c0f31ef80fdc3af8f77c5b35ecaea4"
		),
	],
	targets: [
		.target(name: "Core", dependencies: [
			.product(name: "MetaCodable", package: "MetaCodable"),
			.product(name: "HelperCoders", package: "MetaCodable"),
		]),
		.target(name: "WebRTC", dependencies: ["Core", .product(name: "LiveKitWebRTC", package: "webrtc-xcframework")]),
		.testTarget(name: "WebRTCTests", dependencies: ["WebRTC"]),
		.testTarget(name: "ExternalProductionImportProof", dependencies: ["WebRTC"]),
	]
)
