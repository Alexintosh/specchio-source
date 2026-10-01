# Specchio

Specchio is a macOS application for mirroring and controlling iPhone screens
through CoreDevice Wi-Fi, USB, ReplayKit, and AirPlay paths.

This repository is a public source release for affected Specchio builds. It is
prepared from sanitized source snapshots and excludes private release
automation, experiments, logs, generated build products, and prebuilt binaries.

## License

Specchio is distributed under the GNU General Public License version 3. See
`LICENSE`.

Third-party components remain under their respective licenses. See
`THIRD_PARTY_NOTICES.md` and the license files under `ThirdParty/`.

## Build Tags

Each tag corresponds to a Specchio build number:

- `specchio-2026060701`
- `specchio-2026060702`
- `specchio-2026060902`
- `specchio-2026061101`
- `specchio-2026061201`
- `specchio-2026100101`

Check out the tag matching the build you received and read `BUILD.md`.

## WebDriverAgent

Specchio uses a modified WebDriverAgent fork as a Git submodule:

```sh
git submodule update --init --recursive
```

The submodule is pinned to the exact WebDriverAgent commit used by the
corresponding Specchio build.
