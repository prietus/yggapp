#!/bin/sh
# Builds Frameworks/Yggkit.xcframework from ./yggkit for iOS device, simulator and macOS.
set -e
cd "$(dirname "$0")/yggkit"
export PATH="$PATH:$(go env GOPATH)/bin"
YGGVER=$(go list -m -f '{{.Version}}' github.com/yggdrasil-network/yggdrasil-go)
LDFLAGS="-s -w -X github.com/yggdrasil-network/yggdrasil-go/src/version.buildName=yggdrasil -X github.com/yggdrasil-network/yggdrasil-go/src/version.buildVersion=${YGGVER#v}"
mkdir -p ../Frameworks
gomobile bind -target ios,iossimulator,macos -iosversion 16.0 -tags mobile \
  -ldflags="$LDFLAGS" -o ../Frameworks/Yggkit.xcframework .
echo "Built Frameworks/Yggkit.xcframework (yggdrasil $YGGVER)"
