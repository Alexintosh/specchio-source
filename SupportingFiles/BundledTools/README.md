# Bundled USB Tools

The commercial binary builds bundled `iproxy` and related libimobiledevice
dynamic libraries in this directory.

Those prebuilt binaries are intentionally not committed to this source release.
For local builds, install compatible tools with Homebrew or rebuild them from
the upstream libimobiledevice projects. At runtime, Specchio also looks for
`iproxy` in `PATH`.

See `../../ThirdParty/USBTools/SOURCE.md` for source locations and license
texts.
