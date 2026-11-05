#!/usr/bin/env bash
# Runs the test suite. With Xcode selected (CI), plain `swift test` is enough.
# With Command Line Tools only, swift-testing needs help:
#  - the TestingMacros plugin is in CLT's plugins/testing/ subdirectory, which the compiler does not load by default
#  - Testing.framework and lib_TestingInterop.dylib are not on the default rpath
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools
if [ "$(xcode-select -p)" != "$CLT" ]; then
  exec swift test "$@"
fi
exec swift test \
  -Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks" \
  -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" \
  "$@"
