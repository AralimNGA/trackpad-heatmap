#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Compiling…"
swiftc -O -o trackpad-heatmap main.swift

echo
echo "Fertig. Starten mit:"
echo "  ./trackpad-heatmap"
