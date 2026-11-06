# X6 Control

macOS utility for configuring the Attack Shark X6 mouse. See the source tree and release workflow for build and packaging instructions.

> The project targets macOS 13+ on Intel and Apple Silicon. Connect the mouse over USB or its 2.4 GHz receiver.

## Build

Requires Xcode Command Line Tools.

```sh
scripts/build-macos.sh native
scripts/build-macos.sh universal
scripts/package-macos-release.sh
```

Tag a release as `v1.0.0` to trigger the GitHub Actions workflow, which builds a universal app and publishes ZIP/DMG assets.

See the MIT license in [LICENSE](LICENSE).