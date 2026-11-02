#!/bin/sh
# Runs all tests: Go core (with the race detector) and Swift unit tests on a simulator.
set -e
cd "$(dirname "$0")"
SIM="${SIM:-iPhone 17}"

echo "== Go (yggkit) =="
(cd yggkit && go test -race ./...)

echo "== Swift (YggAppTests on $SIM) =="
[ -d Frameworks/Yggkit.xcframework ] || ./build-yggkit.sh
xcodegen generate --quiet
xcodebuild test -project YggApp.xcodeproj -scheme YggApp \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -vE '^\s*$|addPeer:\(NSString' || true
# xcodebuild's exit status is lost in the pipe; re-check the result bundle.
xcrun xcresulttool get test-results summary --path "$(ls -td build/Logs/Test/*.xcresult | head -1)" \
  | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s["passedTests"], "passed,", s["failedTests"], "failed"); sys.exit(s["result"] != "Passed")'
