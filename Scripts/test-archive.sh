#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/clang-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swiftc -module-cache-path .build/clang-cache \
  Sources/OCIBastion/Models.swift \
  Sources/OCIBastion/CommandRunner.swift \
  Sources/OCIBastion/ProxyResolver.swift \
  Sources/OCIBastion/OwnedTunnel.swift \
  Sources/OCIBastion/SSHCommands.swift \
  Tests/ArchiveTunnelTests.swift \
  -o .build/archive-tunnel-tests
.build/archive-tunnel-tests
