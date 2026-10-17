[Documentation index](README.md) · [Project home](../../README_english.md)

# Advanced Usage

## Droidspaces TUI

The RootFS includes a maintenance menu for installing or updating Mesa, Hangover Wine, Wine fonts, and Anland components:

```bash
droidspaces-tui
# aliases: dstui or ds-tui
```

See the [script guide](../../scripts/README_english.md#droidspaces-tui) for download sources, integrity checks, cache management, updates, and uninstall behavior.

## USB device management

All distributions include [Droidspaces USB Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager). Enable hardware access for the container in Droidspaces, then launch it from the application menu or run this in KDE:

```bash
usb-manager
```

The `usb-passthrough` and `usb-storage-passthrough` commands are also available. See the [script guide](../../scripts/README_english.md#usb-manager-installer) for installation and updates.

## Install hardware firmware

Debian 13 and Ubuntu 24/25/26 images include `download-firmware`. Run it manually in the container when needed:

```bash
sudo download-firmware
```

It does not run during build or container startup. Dependencies and processing details are in the [script guide](../../scripts/README_english.md#firmware-tool).

## Local builds

Local builds require Docker, Docker Buildx, and `xz`. Cross-architecture builds also need a working QEMU/binfmt environment.

Native architecture example:

```bash
chmod +x build_rootfs-native.sh
./build_rootfs-native.sh \
  -i Debian-13.Dockerfile -v local -K KDE -L true \
  -B x11 -P socket -g true -a false -b true -c true \
  -d false -e true -f false -h false -n false \
  -S false -t false -u Gold
```

QEMU ARM64 example:

```bash
chmod +x build_rootfs-qemu-aarch64.sh
./build_rootfs-qemu-aarch64.sh \
  -i Ubuntu-26.Dockerfile -v local -K KDE -L true \
  -B anland-wayland -P none -g true -a false -b true -c true \
  -d false -e true -f false -h true -n true \
  -S false -t false -u Gold
```

The output name resembles `Ubuntu-26-kde-Wayland-Droidspaces-rootfs-aarch64-local.tar.xz`. The scripts use short command-line options; see the beginning of `build_rootfs-native.sh` or `build_rootfs-qemu-aarch64.sh` for the option mapping.

## Limitations

- Anland Wayland is supported on Debian 13, Ubuntu 26, Fedora 43/44, and Arch; Arch KDE is Wayland-only, while Ubuntu 24/25 use X11.
- GNOME is available on Debian 13, Ubuntu 26, Fedora 43/44, and Arch Linux ARM with Anland Wayland.
- KDE Mobile and Anland Next are available only on supported Wayland targets.
- Niri, Hyprland, Mango, and Denial are available on Debian 13, Ubuntu 26, Fedora 43/44, and Arch Linux ARM with Anland Wayland.
- Fedora may need hardware access on some devices. Debian/Ubuntu may lag when `noseccomp` is disabled or the host kernel lacks `USER_NS`.
- This project's QEMU/binfmt cross-architecture path is not currently recommended for Arch.

Anland desktop packages are maintained in the separate [`droidspaces-package`](https://github.com/Goldzxcbug/droidspaces-package) repository. See the [project home](../../README_english.md#acknowledgements) for acknowledgements.
