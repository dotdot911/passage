# Passage

Free, open-source HTTP/HTTPS debugging proxy that runs entirely on iPhone and iPad.

## Build

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`),
an Apple Developer Program team (Network Extension needs a paid team).

```bash
export PASSAGE_TEAM_ID=ABCDE12345   # your team ID
xcodegen generate
open Passage.xcodeproj
```

Run the `Passage` scheme on a real device (Network Extensions do not run in the Simulator).

## Core package tests (macOS)

```bash
cd Packages/ProxyCore
swift test --no-parallel   # lwIP has global state: tests must not run in parallel
```

## Third-party code

`Packages/ProxyCore/Sources/CLwIP/lwip` is lwIP 2.2.1 (BSD license, see its COPYING), vendored and
patched by `Packages/ProxyCore/scripts/vendor-lwip.sh`.
