#!/bin/zsh
# Builds and runs the self-check suite. Pass --live to include on-device Translation / AI checks.
cd "$(dirname "$0")/.." || exit 1
swift build --product LupeChecks 2>&1 | grep -E "error:" | sed -E 's/\x1b\[[0-9;]*m//g' | sort -u
swift run LupeChecks "$@" 2>&1 | grep -vE "^\[|Building|Build complete|Compiling|Write swift|Planning|Emitting"
