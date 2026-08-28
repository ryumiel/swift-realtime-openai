#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture="$root/Tests/ExternalNegativeConsumerPackage"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

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
	if swift build --package-path "$fixture" --scratch-path "$scratch/build" --target "$target" -Xswiftc -warnings-as-errors >"$output" 2>&1; then
		echo "forbidden target unexpectedly compiled: $target" >&2
		exit 1
	fi
	if ! grep -q "$symbol" "$output"; then
		cat "$output" >&2
		echo "forbidden target did not fail for intended symbol: $target" >&2
		exit 1
	fi
done
