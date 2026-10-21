English | [中文](README.md)

# Droidspaces RootFS Builder

Build ARM64 Linux RootFS images for Droidspaces on Android with GitHub Actions. Choose Debian, Ubuntu, Fedora, or Arch Linux, select KDE, KDE Mobile, GNOME, Anland Next, Niri, Hyprland, Mango, Denial, or command-line mode, then import the generated `.tar.xz` archive into Droidspaces.

![Debian 13 KDE running with Anland Wayland](docs/images/debian-kde-wayland.jpg)

**Quick start:** Fork this repository → open `Actions` → run “Build and Release Droidspaces RootFS” → download the RootFS from `Releases`.

Subscribe to the rolling desktop feed in Droidspaces: [Chinese RootFS (GitHub)](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder/releases/download/droidspaces-rootfs-all-wayland/rootfs_zh.json), [Chinese RootFS (CNB)](https://cnb.cool/goldzxcbug/droidspaces-package/-/releases/download/droidspaces-rootfs-all-wayland/rootfs_zh.json), or [English RootFS (GitHub)](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder/releases/download/droidspaces-rootfs-all-wayland/rootfs_en.json).

## What it provides

- Seven distribution targets, with X11 and Anland Wayland support depending on the selected profile and distribution.
- Optional Chinese locale, Fcitx5, Snapdragon GPU support, audio forwarding, development tools, and Docker.
- Automatic GitHub Release publishing, desktop session startup, USB management, and in-container maintenance tools.

## Documentation

- [Documentation index and desktop screenshots](docs/en/README.md)
- [Build with Actions and import into Droidspaces](docs/en/quick-start.md)
- [Supported distributions and build options](docs/en/build-options.md)
- [Desktop startup and Anland Wayland setup](docs/en/desktop-and-anland.md)
- [TUI, USB, firmware, and local builds](docs/en/advanced-usage.md)
- [Script maintenance guide](scripts/README_english.md)

## Targets

`Debian-13`, `Ubuntu-24`, `Ubuntu-25`, `Ubuntu-26`, `Fedora-43`, `Fedora-44`, and `Arch`. GNOME, Niri, Hyprland, Mango, and Denial are available on Debian 13, Ubuntu 26, Fedora 43/44, and Arch Linux ARM. See the [build options guide](docs/en/build-options.md) for desktop and display-backend compatibility.

## Acknowledgements

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS/): runtime foundation.
- [mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container): Snapdragon GPU driver support.
- [droidspaces-media-decode](https://github.com/Re-s/droidspaces-media-decode): Android MediaCodec hardware decoding for containers.
- [Anland](https://github.com/superturtlee/anland): Wayland display backend and related work.
- [Droidspaces USB Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager): USB storage and ADB device management.
- [ObsidianArc](https://github.com/OnyxAxisOwO/ObsidianArc): self-hosted multi-model chat gateway; thanks for providing public-benefit AI services.

---

[All desktop screenshots](docs/en/README.md#screenshots) · [中文 README](README.md)
