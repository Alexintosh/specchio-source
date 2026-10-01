# Third-Party Notices

This source release includes or references the following third-party
components.

## AirPlay FairPlay Provider

- Upstream: `https://github.com/FDH2/UxPlay`
- Imported upstream commit:
  `510d55ed6ca11b07d25ab75eb32a327f0b56bf73`
- Included source:
  - `ThirdParty/AirPlayFairPlay/UxPlay/lib/fairplay.h`
  - `ThirdParty/AirPlayFairPlay/UxPlay/lib/fairplay_playfair.c`
  - `ThirdParty/AirPlayFairPlay/UxPlay/lib/logger.h`
  - `ThirdParty/AirPlayFairPlay/UxPlay/lib/playfair/*`

The `playfair` files are GPL-3.0 licensed. The FairPlay wrapper files carry
LGPL-2.1-or-later headers. License texts are in
`ThirdParty/AirPlayFairPlay/licenses/`.

## WebDriverAgent

Specchio references a modified WebDriverAgent fork as a Git submodule:
`https://github.com/Alexintosh/WebDriverAgent.git`.

The submodule is pinned in each build tag.

## USB Tunneling Tools

Affected binary builds bundled `iproxy` and related libimobiledevice libraries
for USB tunneling convenience:

- `iproxy`
- `libusbmuxd-2.0.7.dylib`
- `libimobiledevice-glue-1.0.0.dylib`
- `libplist-2.0.4.dylib`

This source release does not include those prebuilt binaries. Use Homebrew
packages or rebuild from the upstream libimobiledevice-family projects if you
need local USB tunneling tools.

Source locations and license texts are stored in `ThirdParty/USBTools/`.

Specchio can also discover `iproxy` from `PATH`.

## CoreDevice Python runtime

The app's helper sources and pinned dependency list are in `scripts/coredevice/`.
The runtime is installed separately; no Python interpreter, virtual environment,
device pairing secrets, or Apple developer disk image is included here.

- pymobiledevice3 11.13.1: GPL-3.0-or-later;
  https://github.com/doronz88/pymobiledevice3
- pmd-pytcp 0.3.7: GPL-3.0-or-later; PyTCP-derived userspace networking;
  https://github.com/ccie18643/PyTCP
- Exact transitive package versions: `scripts/coredevice/requirements.lock.txt`.
  Each dependency retains its own license and package notices.
- Copies of the two packages' distributed license texts are in
  `ThirdParty/CoreDevice/licenses/`.

The initial mirroring feasibility work referenced
https://github.com/daniellemky/omarchy-iphone-mirror. Specchio's helper uses the
pinned pymobiledevice3 userspace tunnel, display, input, and audio APIs.

## Swift packages

- Sparkle 2.9.1: MIT-style license and upstream bundled notices;
  https://github.com/sparkle-project/Sparkle
- BigInt 5.7.0: MIT license; https://github.com/attaswift/BigInt

Exact revisions are in
`Specchio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
