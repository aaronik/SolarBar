#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
swiftc -swift-version 6 -target "$(uname -m)-apple-macosx13.0" \
    Sources/SolarBar/{Telemetry,Modbus,InstantReadout,BluetoothMonitor,ChartLine,HistoryArchive}.swift Tests/Smoke.swift -o "$tmp/smoke"
python3 Tests/simulate.py "$tmp/smoke"
