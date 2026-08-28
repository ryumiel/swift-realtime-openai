#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture="$root/Tests/ExternalNegativeConsumerPackage"
positive_fixture="$root/Tests/ExternalConsumerPackage"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
renamed_checkout="$scratch/renamed-realtime-fork"
ln -s "$root" "$renamed_checkout"

WEBRTC_FORK_PATH="$renamed_checkout" swift build --package-path "$positive_fixture" --scratch-path "$scratch/build" -Xswiftc -warnings-as-errors

for pair in \
	"ForbiddenBacking:WebRTCConnectorPeerBacking" \
	"ForbiddenConnector:WebRTCConnector" \
	"ForbiddenSignaling:WebRTCSignalingRequest" \
	"ForbiddenDecoder:WebRTCInboundEventDecoder" \
	"ForbiddenQualification:WebRTCConnectorQualificationPeerFactory"
do
	target=${pair%%:*}
	symbol=${pair#*:}
	output="$scratch/$target.log"
	if WEBRTC_FORK_PATH="$renamed_checkout" swift build --package-path "$fixture" --scratch-path "$scratch/build" --target "$target" -Xswiftc -warnings-as-errors >"$output" 2>&1; then
		echo "forbidden target unexpectedly compiled: $target" >&2
		exit 1
	fi
	if ! grep -q "$symbol" "$output"; then
		cat "$output" >&2
		echo "forbidden target did not fail for intended symbol: $target" >&2
		exit 1
	fi
done
