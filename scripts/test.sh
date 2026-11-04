#!/usr/bin/env bash
# CLT-only Fixed command for running swift-testing in a CLT-only environment (without Xcode, the macro plugin and rpath must be specified by hand):
#  - the TestingMacros plugin is in CLT's plugins/testing/ subdirectory, which the compiler does not load by default
#  - Testing.framework and lib_TestingInterop.dylib are not on the default rpath
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools
exec swift test \
  -Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks" \
  -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" \
  "$@"
