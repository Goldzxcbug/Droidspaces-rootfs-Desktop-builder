English | [中文](README.md) | [Back to project README](../README_english.md)

# scripts Directory

This directory contains installers used while building the RootFS, maintenance tools copied into the RootFS, and systemd service templates. Before running a file manually, check whether it belongs in the Linux container or the image build environment.

## File Overview

| File | Run in | Purpose |
| --- | --- | --- |
| `install-desktop.sh`, `desktops/*.sh` | RootFS build environment | Dispatches stable desktop profile slugs and owns package sets and desktop-specific environment variables. |
| `configure-desktop.sh` | RootFS build environment | Writes desktop/backend configuration, invokes profile environment setup, and optionally installs the common auto-start service. |
| `configure-chrome.sh` | RootFS build environment | Installs Chrome in all supported images, then configures hardware-acceleration flags and desktop launchers for Anland Wayland images. |
| `start-desktop-session.sh` | Linux container | Starts the selected session from `/etc/droidspaces-desktop.conf`. |
| `tui/droidspaces-tui.sh` | ARM64 Linux container | Provides a unified terminal menu for the Mesa, Hangover Wine, Wine fonts, and Anland installers. |
| `tui/install-mesa.sh` | ARM64 Linux container | Installs the latest Android-container Mesa build and MediaCodec VA-API driver, then locks Mesa packages. |
| `tui/install-hangover-wine.sh` | ARM64 Linux container | Installs the Hangover Wine Release packages matching the current distribution. |
| `tui/install-winefonts.sh` | Linux container | Installs the Wine font bundle and refreshes the fontconfig cache. |
| `tui/install-anland-kde.sh` | ARM64 Linux container | Installs Anland patched KWin/Xwayland Release packages and locks them. |
| `tui/install-anland-gnome.sh` | ARM64 Debian/Ubuntu/Fedora/Arch container | Installs Anland patched Mutter Release packages and locks them. |
| `tui/install-anland-next.sh` | ARM64 Debian/Ubuntu/Fedora/Arch container | Installs the Anland Next session package (mini-wm + patched Xwayland + patched bubblewrap). |
| `tui/install-anland-niri.sh` | ARM64 Debian 13, Ubuntu 26, Fedora 43/44, and Arch container | Installs Anland Niri and its shared patched Xwayland package. |
| `tui/install-anland-hyprland.sh`, `install-anland-mango.sh`, `install-anland-denial.sh` | ARM64 Debian 13, Ubuntu 26, Fedora 43/44, and Arch container | Installs the compositor and its patched Xwayland package. |
| `install-anland-desktop.sh` | RootFS build environment | Dispatches a desktop slug to KDE, GNOME, Niri, Hyprland, Mango, Denial, or Anland Next. |
| `lib/anland-build.sh` | RootFS build host | Resolves the Anland package family, Release tag, and revision for native/QEMU builds. |
| `install-usb-manager.sh` | Linux container | Installs Droidspaces USB Manager, distribution dependencies, launchers, and user permissions. |
| `install-usb-storage-access.sh` | RootFS build environment | Configures USB mass-storage access: device nodes, media revalidation, the exFAT permission group, and the polkit rule. |
| `droidspaces-usb-storage-fixup` | Linux container udev | Creates the missing nodes for USB block devices and revalidates late-attached media so udisks2/Dolphin can see the filesystem. |
| `droidspaces-usb-storage-cleanup` | Linux container udev | Releases the container-side mount on unplug so the kernel block device is not left claimed. |
| `systemd257.sh` | RootFS build environment | Installs a complete package-manager-owned systemd 257 family when required by an old Android kernel. |
| `download-firmware` | Debian/Ubuntu container | Installs `linux-firmware` and decompresses its `.zst` firmware. |
| `nosnap.sh` | Ubuntu RootFS build environment | Removes Snap, prevents reinstallation, and configures traditional deb sources. |
| `bashrc.sh` | Linux user shell | Adds Docker aliases, thermal helpers, and an SSH file-transfer helper. |
| `start/desktop-session.service` | Linux container systemd | Starts the selected desktop session through one common entry point. |
| `binfmt/*` | Linux container systemd/kernel | Checks and mounts `binfmt_misc` for QEMU cross-architecture execution. |

## Droidspaces TUI

Built RootFS images provide the `droidspaces-tui` command with the shorter `dstui` and `ds-tui` aliases. It is a pure Bash terminal menu with no `dialog` dependency and works in a regular terminal or through `adb shell -t`:

```bash
droidspaces-tui
# These two commands are equivalent
dstui
ds-tui
```

Run it from a repository checkout with:

```bash
./scripts/tui/droidspaces-tui.sh
```

The main menu includes Mesa with MediaCodec VA-API, Hangover Wine, Wine fonts, and the desktop/session update entry for the current RootFS, and shows only `update available`, `up to date`, or `not installed` with matching colors. The desktop/session entry is selected by strictly parsing `/etc/droidspaces-desktop.conf`: KDE and KDE mobile show only Anland KDE, GNOME shows only Anland GNOME, Niri, Hyprland, Mango, or Denial show their matching compositor, and Anland Next shows only its session. `none` or an unknown desktop opens the component selector. Installed Anland state is used only as a fallback for old RootFS images that have no config file; if no component can be inferred, the selector is used. Selecting a component opens its version details and update, install, or uninstall actions. Version lookups run concurrently in the background, a dynamic Braille symbol indicates an active lookup, and a lookup that has no valid result after 10 seconds is shown as `timeout` without blocking menu input. Version detection runs when the TUI starts; entering or leaving menus and submitting invalid input do not restart it. After an install or uninstall actually starts, detection refreshes once upon returning to the main menu. Input is visible with backspace support, and Loading uses in-place redraws instead of repeatedly clearing the screen. Uninstalling patched Mesa, KWin, Mutter, or compositor packages restores distribution packages, while Hangover Wine and Wine fonts remove their own content. Chinese environments default to CNB, while other languages default to GitHub; the source can also be changed to automatic probing, GitHub, `gh-proxy.com`, or CNB. When CNB is explicitly selected, the TUI does not query the GitHub API: installers obtain asset names, SHA-256 values, and sizes from the synchronized manifest in the same CNB Release. Older releases with no digest provide a clear notice and retain archive-structure and package-metadata validation.

Press `C` in the main menu to open cache management. The Hangover Release manifest can be removed by itself to recover from a stale manifest after a rolling Release update, or all downloads under `/var/cache/hangover-wine` can be removed. Both actions require confirmation, and cleaning all downloads means the package archive must be downloaded again on the next installation.

Press `U` to open update management. It can check for updates, update only the TUI, update only managed installer scripts, or update everything. The TUI temporarily obtains the one-time installer from the fixed `Gold-bug-tui` tag. GitHub/proxy mode cross-checks the GitHub Release API and the release manifest; CNB mode reads only the synchronized CNB manifest for SHA-256 and size verification, backs up old files before replacement, and removes the temporary installer when finished.

An initial source can also be selected on startup:

```bash
droidspaces-tui --source cnb
droidspaces-tui --source github
```

## Mesa Installer

`install-mesa.sh` selects the ARM64 Mesa asset for the current distribution from the distribution Release in GitHub/proxy mode; CNB mode reads only `mesa-distribution-manifest` from the matching CNB Release. It then installs the synchronized `msm_drm_drv_video.so`. It supports Debian 13, Ubuntu 24.04/25.10/26.04, Fedora 43/44, and Arch Linux. The media decode driver is installed in each distribution's default libva driver directory: `/usr/lib/aarch64-linux-gnu/dri` on Debian/Ubuntu, `/usr/lib64/dri` on Fedora, and `/usr/lib/dri` on Arch Linux.

The installer strictly validates Release tags, asset names, and downloaded content. GitHub/proxy mode retains GitHub Release API SHA-256 cross-checks; CNB mode uses only the SHA-256 values and sizes in the CNB distribution manifest, then still verifies the synchronized media-driver `SHA256SUMS`. Downloads can resume, and temporary files are removed on exit.

Run interactively from the repository root:

```bash
sudo ./scripts/tui/install-mesa.sh
```

With no option, the script probes all three sources and prompts for a choice. Select a source directly for unattended builds:

```bash
sudo ./scripts/tui/install-mesa.sh --1  # GitHub
sudo ./scripts/tui/install-mesa.sh --2  # gh-proxy.com
sudo ./scripts/tui/install-mesa.sh --3  # ghproxy.net
```

The source options are mutually exclusive and apply to both the Mesa and media decode driver downloads. `-1`, `-2`, and `-3` are equivalent short options; use `--help` for built-in help. Third-party sources still require access to `api.github.com` for trusted metadata, plus `jq` and `sha256sum`. Downloads use either `curl` or `wget`.

After installation, persistent package locks are written for each distribution:

| Distribution | Lock location and mechanism |
| --- | --- |
| Debian/Ubuntu | `/etc/apt/preferences.d/hold-anland-package` with `Pin-Priority: -1` |
| Fedora | Installer-managed `exclude` block in `/etc/dnf/dnf.conf` |
| Arch | Installer-managed `IgnorePkg` block in `/etc/pacman.conf` |

The lock list is generated only from Mesa packages present in the archive. KWin/Xwayland and Mutter/Xwayland are held separately by `install-anland-kde.sh` and `install-anland-gnome.sh`. Managed configuration is idempotent, and unrelated existing configuration is preserved.

## Adding a Desktop Profile

Desktop names, target capabilities, and backend compatibility live in `lib/desktop-config.sh`. To add a desktop:

1. Register its stable slug in `desktop_normalize`, `desktop_label`, and the support matrix.
2. Add an executable `desktops/<slug>.sh` whose default action installs packages according to `/etc/os-release` and whose `configure-environment <backend>` action configures desktop-specific environment variables.
3. Map its session command in `start-desktop-session.sh`; `install-desktop.sh` automatically discovers executable profiles for valid slugs.
4. Add its display label to the `desktop` choice in both workflow entry files.

All seven Dockerfiles and the reusable workflow already use the generic profile interface, so an ordinary X11 desktop does not require copied Dockerfiles. Profiles that require patched Wayland packages must also map to a package family in `lib/anland-build.sh` through `anland_package_family`.

## Anland KDE Installer

`install-anland-kde.sh` reads `anland-kde-manifest` from the fixed `anland-kde-packages` rolling Release in `Goldzxcbug/droidspaces-package` by default, then installs the matching patched KWin/Xwayland packages for Debian 13, Ubuntu 26.04, Fedora 43/44, or Arch Linux on ARM64.

```bash
sudo ./scripts/tui/install-anland-kde.sh
```

It also accepts `--1`, `--2`, or `--3` for GitHub, `gh-proxy.com`, or `ghproxy.net`; with no option, it probes the sources and prompts. Both the manifest and archive from a mirror are checked against GitHub API digests. Messages follow the system locale, and APT holds, DNF excludes, or Pacman `IgnorePkg` entries prevent upgrades from replacing the installed packages.

To install packages published by a public fork, override only the repository. The fork must provide the fixed `anland-kde-packages` tag:

```bash
sudo ANLAND_RELEASE_REPOSITORY=owner/repository \
  ./scripts/tui/install-anland-kde.sh --1
```

The Anland host module, app, SELinux policy, bind mount, and Droidspaces permissions must still be configured as described in the [Wayland and Anland setup guide](../docs/en/desktop-and-anland.md#anland-wayland-host-setup).

## Anland GNOME Installer

`install-anland-gnome.sh` reads `anland-gnome-manifest` from the fixed `anland-gnome-packages` rolling Release and installs patched Mutter runtime packages for Debian 13, Ubuntu 26.04, or Arch Linux ARM64. On Arch it installs only the `mutter` runtime package and uses pacman `IgnorePkg`; Debian/Ubuntu use APT holds. Packages for all three targets are published by `droidspaces-package`; RootFS builds and later updates fetch the matching archive through the Release manifest. Its source selection, mirror digest checks, and arguments match the KDE installer.

```bash
sudo ./scripts/tui/install-anland-gnome.sh
```

Override the GNOME repository variable when using packages from a public fork:

```bash
sudo ANLAND_RELEASE_REPOSITORY=owner/repository \
  ./scripts/tui/install-anland-gnome.sh --1
```

## Anland Next Installer

`install-anland-next.sh` reads `anland-session-manifest` from the fixed `anland-session-packages` rolling Release and installs the `anland-session` package for Debian 13, Ubuntu 26.04, Fedora 43/44, or Arch Linux on ARM64. Its source selection, mirror digest checks, and arguments match the KDE installer.

```bash
sudo ./scripts/tui/install-anland-next.sh
```

The package carries three prebuilt components: `anland-miniwm`, a Xwayland patched for kgsl/turnip glamor, and a bubblewrap patched for the mountinfo index. The latter two live in `/usr/lib/anland/`, which the session puts first on `PATH`; the distribution binaries are never replaced, so unlike KDE/GNOME **no package locking is needed** — this package overwrites nothing.

The session itself is the packaged `/usr/bin/anland-session` (session D-Bus + wayland link + rootless Xwayland + mini-wm) together with `/usr/lib/systemd/user/anland-session.service`, and nothing is written into a user's home directory.

The Anland Next profile defaults Qt 6 applications to native Wayland and explicitly installs its platform plugin; an interactive user shell imports `~/.anlandx-env` while the session is running. Kate launchers consistently use `kate -b`, avoiding its no-window exit in a minimal session. Legacy X11/XCB applications remain compatible through the packaged Xwayland, without injecting additional Qt/X11 scaling variables.

To use packages from a public fork, override the repository variable:

```bash
sudo ANLAND_NEXT_RELEASE_REPOSITORY=owner/repository \
  ./scripts/tui/install-anland-next.sh --1
```

## Anland Niri Installer

Niri, Hyprland, Mango, and Denial installers fetch their compositor and patched `xorg-xwayland` packages from fixed rolling Releases on Debian 13, Ubuntu 26, Fedora 43/44, and Arch ARM64. The lightweight RootFS profile provides a terminal, XDG portal, audio, and fonts; Niri on Arch also includes common desktop utilities. These compositors share patched Xwayland, and their installers prevent conflicting replacement while preserving packages used by other installed components.

```bash
sudo ./scripts/tui/install-anland-niri.sh
```

## USB Manager Installer

`install-usb-manager.sh` supports Debian/Ubuntu, Fedora, and Arch. It installs PyQt5, ADB, udev, NTFS, exFAT, and other matching dependencies, followed by the `usb-manager`, `usb-passthrough`, and `usb-storage-passthrough` commands.

```bash
sudo ./scripts/install-usb-manager.sh --user "$USER"
```

`--user USER` selects the user that receives USB management permissions and desktop launchers. When omitted, the installer tries `SUDO_USER`, the logged-in user, and then the first regular user. Development and offline tests can use a local Droidspaces-USB-Manager checkout through `--source DIR`; run `--help` for all options.

On a regular Arch system, the installer continues to install `systemd` and the remaining dependencies normally. When `/etc/droidspaces-systemd257` exists, a repeated installation preserves Pacman's `IgnorePkg` lock and no longer names `systemd` as an explicit install target; the PyQt5, ADB, NTFS, exFAT, and other USB Manager dependencies are still installed as needed.

Hardware access must be enabled when importing the RootFS into Droidspaces, or `/sys/bus/usb` and `/sys/bus/scsi` will not be visible inside the container.

## USB Mass-Storage Access Configurator

`install-usb-storage-access.sh` runs automatically during the build and makes USB mass storage (USB sticks, camera internal storage, ...) actually usable by the desktop user.

```bash
sudo ./scripts/install-usb-storage-access.sh --user "$USER"
```

It installs and writes:

- the `droidspaces-usb-storage-fixup` and `droidspaces-usb-storage-cleanup` runtime scripts;
- `/etc/udev/rules.d/85-droidspaces-usb-storage.rules`: starts the helper on block-device `add` and releases the container-side mount on `remove`;
- `/etc/systemd/system/droidspaces-usb-storage-fixup.service`;
- `/etc/polkit-1/rules.d/49-droidspaces-udisks2.rules`: lets the local admin group mount removable media;
- the `external_storage` group (gid 1077, matching Android's `AID_EXTERNAL_STORAGE`) with the `--user` account as a member.

Three problems must be solved together before Dolphin works:

1. The container's `/dev` only contains the nodes that already existed at container start. Block devices that appear later use a dynamic dev_t (USB disks, `loop16..46`, ...), and neither devtmpfs nor systemd-udevd creates a node for them, so `/dev/sdX` does not exist and nothing can open, probe or mount it.
2. Devices such as cameras enumerate with no medium and attach the real storage only after the user confirms on the device; the kernel refreshes the reported capacity only when the device is opened (`sd_check_events() → revalidate_disk()`). With no node, nobody ever opens it, the capacity stays 0 and udev never sees a filesystem.
3. The Android GKI exFAT driver ignores `uid=`/`gid=`/`umask=` and hard-codes `gid=1077` (`AID_EXTERNAL_STORAGE`) with `fmask/dmask=0007`, so a regular user must be in that gid to read exFAT media (the same class of problem that `ntfsusb` gid 1023 solves for NTFS).

`droidspaces-usb-storage-fixup` only `mknod`s nodes and opens the device to read its capacity; it **never writes to any filesystem**, and it polls with a backoff capped at 10 minutes. The udev rule lets only `add` start the helper (the helper re-triggers udev with `change` itself, which would otherwise loop) and releases the container-side mount on `remove`.

Only `Fedora-44.Dockerfile` wires this in so far (three `COPY` lines, one `RUN` line, plus the build-time cleanup entry); other distributions can adopt it the same way when needed.

> A log-out/log-in (or container restart) is required after installation so the new group reaches the desktop processes.
>
> **⚠️ Never accept Android's "format" prompt.** The host Android `vold` runs `fsck` before mounting, and fsck needs exclusive access to the block device — as long as any kernel exFAT mount exists on the container side, vold's fsck fails, the volume is marked `unmountable`, and Android posts a notification that leads to formatting. The rules therefore arrange for **vold to mount first and the container to mount afterwards**, and release the block device on unplug. If that notification still appears, dismiss it.

## systemd 257 Compatibility Script

Dockerfiles call `systemd257.sh` when `enable_systemd257=true`. It checks the installed systemd major version: version 257 and older are skipped, while newer systems install their complete native package family from the frozen compatibility Release `systemd257-packages` in `Goldzxcbug/droidspaces-package`. Related systemd packages are then locked. New package sets are first published under an immutable tag containing the source version and repository commit; the RootFS updates the tag, per-platform SHA-256 values, expected package counts, and package-repository commit together only after that Release is complete.

```bash
sudo ./scripts/systemd257.sh
```

This is an experimental compatibility step for old Android kernels. Test systemd, D-Bus, udev, networking, and desktop sessions on the target device before distributing the resulting RootFS.

## Firmware Tool

`download-firmware` is copied to `/usr/local/bin/download-firmware` in Debian 13 and Ubuntu 24/25/26 RootFS images, but it is not run automatically. Run it inside the container when required:

```bash
sudo download-firmware
```

It installs `zstd` and `linux-firmware`, decompresses `.zst` files under `/lib/firmware`, and repairs symlinks that point to compressed files. A successful run creates `/var/lib/.fw-setup-completed`; this marker currently does not skip later runs.

## Other Build and Startup Files

- `nosnap.sh` is Ubuntu-only. It stops and removes Snap, cleans leftovers, writes APT pins that prevent reinstallation, and configures the traditional deb sources required by the project. It changes packages and APT configuration and must run as root in the target RootFS or build layer.
- `start/desktop-session.service` is the common service template. It calls `start-desktop-session.sh`, reads the desktop configuration, runs the selected session as RootFS UID 1000, and rate-limits restarts after abnormal exits.
- `binfmt/qemu-binfmt-register.sh` and its service verify kernel `binfmt_misc` support and mount it when needed; unsupported kernels are skipped safely. QEMU interpreters are still required for actual cross-architecture execution.
- `bashrc.sh` is shell configuration appended to a user environment, not a standalone installer.

## Development Checks

After changing a shell script, run at least a syntax check. Use ShellCheck when it is installed:

```bash
bash -n scripts/tui/install-mesa.sh
bash -n scripts/tui/droidspaces-tui.sh
bash -n scripts/tui/install-anland-kde.sh
bash -n scripts/tui/install-anland-gnome.sh
bash -n scripts/tui/install-anland-next.sh
bash -n scripts/install-usb-manager.sh
shellcheck scripts/tui/install-mesa.sh
shellcheck scripts/tui/droidspaces-tui.sh
```

Changes to package installation or lock handling should also be tested in APT, DNF, and Pacman containers. Run each installer twice to verify idempotency.
