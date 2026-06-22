# AirPlay FairPlay Provider

This directory vendors the FairPlay provider code used to build
`SupportingFiles/AirPlayFairPlay/libfairplay.dylib`.

## Source

- Upstream: `https://github.com/FDH2/UxPlay`
- Imported commit: `510d55ed6ca11b07d25ab75eb32a327f0b56bf73`
- Imported files:
  - `UxPlay/lib/fairplay.h`
  - `UxPlay/lib/fairplay_playfair.c`
  - `UxPlay/lib/logger.h`
  - `UxPlay/lib/playfair/*`

`Specchio/specchio_fairplay_provider.c` is a local adapter that exposes
Specchio's stateless provider ABI, validates request and response sizes, logs
each decision branch, and delegates cryptographic work to the vendored UxPlay
implementation.

## Licenses

- `UxPlay/lib/fairplay.h`, `UxPlay/lib/fairplay_playfair.c`, and
  `UxPlay/lib/logger.h` include LGPL-2.1-or-later license headers.
- `UxPlay/lib/playfair/*` is GPL-3.0 licensed.
- License texts are stored in `licenses/` and `UxPlay/lib/playfair/LICENSE.md`.

## Build

Regenerate the bundled universal provider with:

```sh
scripts/build-airplay-fairplay-provider.sh
```

By default it builds both `arm64` and `x86_64` slices. To override the
architectures for local diagnostics:

```sh
SPECCHIO_FAIRPLAY_ARCHS="arm64 x86_64" scripts/build-airplay-fairplay-provider.sh
```
