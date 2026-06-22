# USB Tooling Source Information

Affected Specchio binary builds bundled prebuilt USB tunneling tools in
`SupportingFiles/BundledTools/`:

- `iproxy`
- `libusbmuxd-2.0.7.dylib`
- `libimobiledevice-glue-1.0.0.dylib`
- `libplist-2.0.4.dylib`

The prebuilt binaries are intentionally not committed to this source release.
For local builds, install compatible packages with Homebrew or rebuild them
from the upstream projects listed below.

## Upstream Sources

### libusbmuxd / iproxy

- Upstream project: `https://github.com/libimobiledevice/libusbmuxd`
- Release source:
  `https://github.com/libimobiledevice/libusbmuxd/releases/download/2.1.1/libusbmuxd-2.1.1.tar.bz2`
- Release SHA-256:
  `5546f1aba1c3d1812c2b47d976312d00547d1044b84b6a461323c621f396efce`
- License: GPL-2.0-or-later and LGPL-2.1-or-later

### libimobiledevice-glue

- Upstream project:
  `https://github.com/libimobiledevice/libimobiledevice-glue`
- Release source:
  `https://github.com/libimobiledevice/libimobiledevice-glue/releases/download/1.3.2/libimobiledevice-glue-1.3.2.tar.bz2`
- Release SHA-256:
  `6489a3411b874ecd81c87815d863603f518b264a976319725e0ed59935546774`
- License: LGPL-2.1-or-later

### libplist

- Upstream project: `https://github.com/libimobiledevice/libplist`
- Release source:
  `https://github.com/libimobiledevice/libplist/releases/download/2.7.0/libplist-2.7.0.tar.bz2`
- Release SHA-256:
  `7ac42301e896b1ebe3c654634780c82baa7cb70df8554e683ff89f7c2643eb8b`
- License: LGPL-2.1-or-later

## License Texts

- `licenses/GPL-2.0.txt`
- `licenses/LGPL-2.1.txt`
