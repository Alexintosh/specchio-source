# Build Specchio 2026100101

This source snapshot corresponds to Specchio build `2026100101`.

## Build metadata

- App source commit: `50bf26d6d44dc015ef921e3fae7dfade72e48ec0`
- App commit date: `2026-10-01 20:06:43 +0100`
- WebDriverAgent submodule: `e363ccc0b6eb7de57b04515cedcf2587b0f494fc`
- AirPlay FairPlay provider upstream: FDH2/UxPlay `510d55ed6ca11b07d25ab75eb32a327f0b56bf73`
- Original bundled FairPlay provider SHA-256: `a400108e40744d923e14dfa509d12b6f0e833a74183fa72302060bdb101323e9`
- Prebuilt FairPlay and USB binaries are excluded. Their source/build instructions and notices are included.
- Xcode dependency pins: `Specchio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- CoreDevice dependency pins: `scripts/coredevice/requirements.lock.txt`

## Prerequisites and build

Use Xcode with macOS and iOS platforms, its command-line tools, and your own Apple
signing configuration. This release was checked with Xcode's macOS 26.5 SDK.
CoreDevice's recorded runtime uses Python 3.13 on macOS arm64; other platforms
and Python versions have not been verified for this snapshot.

```sh
git submodule update --init --recursive
SPECCHIO_FAIRPLAY_ARCHS="arm64 x86_64" scripts/build-airplay-fairplay-provider.sh
bash scripts/coredevice/install-runtime.sh python3.13
xcodebuild -project Specchio.xcodeproj -scheme Specchio -configuration Release build
```

The CoreDevice installer creates a virtual environment under
`~/Library/Application Support/Specchio/CoreDevice/venv`. It installs pinned
public Python packages; it does not install a developer disk image or change
the iPhone's Developer Mode. Unlock/trust the iPhone and enable Developer Mode
before connecting. The app can establish or recover Wi-Fi pairing through an
already trusted USB connection.

Optional legacy USB tools can be installed with Homebrew or built from the
sources documented in `ThirdParty/USBTools/SOURCE.md`. The original release's
signing and notarization credentials are not part of this source release.

## Checks

```sh
"$HOME/Library/Application Support/Specchio/CoreDevice/venv/bin/python3" -m unittest discover -s scripts/coredevice -p 'test_*.py'
```

The source snapshot includes application/runtime code and relevant tests, but
excludes standalone experimental viewers, diagnostic capture scripts, local
pairing records, release automation, and generated binaries.
