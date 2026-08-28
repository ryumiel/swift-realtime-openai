#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture="$root/Tests/ExternalNegativeConsumerPackage"
positive_fixture="$root/Tests/ExternalConsumerPackage"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
renamed_checkout="$scratch/renamed-realtime-fork"
ln -s "$root" "$renamed_checkout"

positive_output="$scratch/positive.log"
if ! WEBRTC_FORK_PATH="$renamed_checkout" swift build --package-path "$positive_fixture" --scratch-path "$scratch/build" -Xswiftc -warnings-as-errors >"$positive_output" 2>&1; then
	cat "$positive_output" >&2
	exit 1
fi

for pair in \
	"ForbiddenBacking:WebRTCConnectorPeerBacking" \
	"ForbiddenConnector:WebRTCConnector" \
	"ForbiddenSignaling:WebRTCSignalingRequest" \
	"ForbiddenDecoder:WebRTCInboundEventDecoder" \
	"ForbiddenLifecycle:WebRTCLifecycle" \
	"ForbiddenQualification:WebRTCConnectorQualificationPeerFactory"
do
	target=${pair%%:*}
	symbol=${pair#*:}
	output="$scratch/$target.log"
	if WEBRTC_FORK_PATH="$renamed_checkout" swift build --package-path "$fixture" --scratch-path "$scratch/build" --target "$target" -Xswiftc -warnings-as-errors >"$output" 2>&1; then
		echo "forbidden target unexpectedly compiled: $target" >&2
		exit 1
	fi
	expected="error: cannot find type '$symbol' in scope"
	if ! grep -Fq "$expected" "$output"; then
		cat "$output" >&2
		echo "forbidden target did not emit the exact visibility diagnostic: $target" >&2
		exit 1
	fi
	if grep 'error:' "$output" | grep -Fv "$expected" | grep -Fv 'error: emit-module command failed' >/dev/null; then
		cat "$output" >&2
		echo "forbidden target had an unrelated compile or resolution failure: $target" >&2
		exit 1
	fi
done

echo "external production surface verification passed"
