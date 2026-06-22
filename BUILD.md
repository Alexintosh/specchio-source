# Build Specchio 2026060902

This tag contains the source corresponding to Specchio build `2026060902`.

## Build Metadata

- Specchio app commit:
  `5e2f3fa1e9b29d3234375d46075087ffa36e136b`
- Original app commit date:
  `2026-06-09 21:08:24 +0100`
- WebDriverAgent submodule commit:
  `e363ccc0b6eb7de57b04515cedcf2587b0f494fc`
- Bundled AirPlay FairPlay provider architecture:
  `arm64`
- Bundled AirPlay FairPlay provider SHA-256:
  `2bfbccd3a8c4aa172663893bc8a39030d6b025e6fcd9981063e18cd56e2d5c35`
- AirPlay FairPlay provider source import commit:
  `f6cc20c96bb4e7f60a60ed3b1886d2deb20bc57b`
- UxPlay upstream commit:
  `510d55ed6ca11b07d25ab75eb32a327f0b56bf73`

## Prerequisites

- Xcode with the macOS and iOS platforms installed
- Command Line Tools available through `xcrun`
- Sparkle and Swift package dependencies resolved by Xcode
- WebDriverAgent submodule initialized
- Optional USB tools installed through Homebrew or rebuilt from upstream

## Build

Initialize the submodule:

```sh
git submodule update --init --recursive
```

Build the FairPlay provider for this build:

```sh
SPECCHIO_FAIRPLAY_ARCHS="arm64" scripts/build-airplay-fairplay-provider.sh
```

Build the macOS app:

```sh
xcodebuild \
  -project Specchio.xcodeproj \
  -scheme Specchio \
  -configuration Release \
  build
```

The original commercial release was signed and notarized by the developer.
Local builds require your own Apple signing configuration.
