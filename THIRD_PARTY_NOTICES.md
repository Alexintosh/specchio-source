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
