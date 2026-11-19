English | [中文](README.md) | [Back to project README](../README_english.md)

# scripts Directory

This directory contains installers used while building the RootFS, maintenance tools copied into the RootFS, and systemd service templates. Before running a file manually, check whether it belongs in the Linux container or the image build environment.

## File Overview

| File | Run in | Purpose |
| --- | --- | --- |
| `install-rootfs-tools.sh` | RootFS build environment | Installs the image's commands, desktop profiles, TUI provenance record, and selected audio configuration. |
| `install-desktop.sh`, `desktops/*.sh` | RootFS build environment | Dispatches stable desktop profile slugs and owns package sets and desktop-specific environment variables. |
| `configure-desktop.sh` | RootFS build environment | Writes desktop/backend configuration, invokes profile environment setup, and optionally installs the common auto-start service. |
| `configure-chrome.sh` | RootFS build environment | Installs Chrome in all supported images, then configures hardware-acceleration flags and desktop launchers for Anland Wayland images. |
| `start-desktop-session.sh` | Linux container | Starts the selected session from `/etc/droidspaces-desktop.conf`. |
| `install-anland-desktop.sh` | RootFS build environment | Dispatches a desktop slug to KDE, GNOME, Niri, Hyprland, Mango, Denial, or Anland Next. |
| `lib/anland-build.sh` | RootFS build host | Resolves the Anland package family, Release tag, and revision for native/QEMU builds. |
| `sync-tui.sh` | Development and build environment | Downloads and extracts the TUI archive from the `Gold-bug-tui` Release and checks manifests, digests, sizes, archive structure, and script syntax. |
| `install-usb-manager.sh` | Linux container | Installs Droidspaces USB Manager, distribution dependencies, launchers, and user permissions. |
| `systemd257.sh` | RootFS build environment | Installs a complete package-manager-owned systemd 257 family when required by an old Android kernel. |
| `download-firmware` | Debian/Ubuntu container | Installs `linux-firmware` and decompresses its `.zst` firmware. |
| `nosnap.sh` | Ubuntu RootFS build environment | Removes Snap, prevents reinstallation, and configures traditional deb sources. |
| `bashrc.sh` | Linux user shell | Adds Docker aliases, thermal helpers, and an SSH file-transfer helper. |
| `start/desktop-session.service` | Linux container systemd | Starts the selected desktop session through one common entry point. |
| `binfmt/*` | Linux container systemd/kernel | Checks and mounts `binfmt_misc` for QEMU cross-architecture execution. |

The build entry points run `sync-tui.sh` to fetch and extract `Gold-bug-tui.tar.gz`, then pass the extracted directory and `scripts/` as read-only BuildKit mounts to `install-rootfs-tools.sh`. The seven Anland entry points are retained, with shared functions installed under `/usr/local/lib/droidspaces/tui/`. KDE/KDE Mobile images include the PipeWire configuration; Anland Wayland images include the WirePlumber configuration.

Images provide `droidspaces-tui`, `droidspaces-gpu`, `droidspaces-video.sh`, `install-mesa`, `install-hangover-wine`, `install-winefonts`, and the `install-anland-*` commands. Their features follow the release fetched during the build.

## Droidspaces TUI

Run `droidspaces-tui` in the container terminal or through `adb shell -t`. The aliases `dstui` and `ds-tui` are also available:

```bash
droidspaces-tui
# These two commands are equivalent
dstui
ds-tui
```

From a repository checkout, download the release files first:

```bash
bash scripts/sync-tui.sh --output .build/tui
bash .build/tui/droidspaces-tui.sh
```

The main menu provides the following entries. Enter a number or letter, then press Enter to confirm.

| Entry | Actions |
| --- | --- |
| `[1] Mesa + VA-API` | Install, update, or remove Mesa; select a previous version; configure OpenGL/Vulkan; manage video drivers. |
| `[2] Anland` | View desktop component versions and install, update, or remove the matching Anland component. |
| `[3] Hangover Wine` | Install, update, or remove Hangover Wine. |
| `[4] Wine fonts` | Install, update, or remove the font bundle. |
| `F` | Refresh component state and upstream versions. |
| `C` | Clear the Hangover manifest cache or all downloaded files. |
| `U` | Check for updates; update the TUI, managed installers, or everything. |

The Anland entry follows `/etc/droidspaces-desktop.conf`. A `none` or unknown desktop opens the component selector. Older images without this configuration use installed components to identify the desktop. Removing patched Mesa, KWin, Mutter, or compositor packages restores distribution packages; Hangover Wine and Wine fonts remove their own content.

Component states include missing, up to date, update available, locally newer, unknown version, and installation-record drift. Upstream checks run in the background and show progress or specific errors. Expired cache entries refresh automatically; offline results include their check time. Installing, removing, or changing the download source refreshes the state.

### Download sources and updates

On first use, Chinese environments default to CNB and other languages to GitHub. Sources include automatic probing, GitHub, `gh-proxy.com`, and CNB. Select one at startup with:

```bash
droidspaces-tui --source cnb
droidspaces-tui --source github
```

Source preferences are stored in the current user's configuration directory. GitHub/proxy mode cross-checks the GitHub Release API and release manifest; CNB mode uses SHA-256 values and sizes from its synchronized manifest. Older releases without digests show a notice and undergo archive and package-metadata checks.

`U` fetches updates from the `Gold-bug-tui` Release, verifies them, then backs up and replaces files. `C` can clear downloads under `/var/cache/hangover-wine`; the next installation downloads those packages again.

### GPU and video codecs

The GPU menu has overview, OpenGL, and Vulkan pages with paginated driver manifests.

The Mesa page's `[5] Video codecs` submenu installs, updates, removes, and monitors the video driver. Video-only operations use `--media-only`; `[4] Select Mesa version` uses `--mesa-only`. The video version and file digest are recorded in `/var/lib/droidspaces-tui/components/video.version`. Restart affected applications after an update or removal.

Live monitoring reads driver sessions accessible to the current user. Rows are grouped by application and UID and show direction, codec, processing size, output FPS, and hardware status. Green means the driver has confirmed completed hardware work, yellow means pending or unknown, and red marks errors. Readable mpv, VLC, and OBS processes also appear; missing driver telemetry is shown as unknown.

Output FPS measures driver output between samples. The first sample shows `--`; paused sessions show 0. This differs from screen presentation FPS. Processing sizes may include hardware alignment, such as 1920×1088. Older drivers, other APIs, or process permissions may hide sessions. Press `q`, `Esc`, or `Ctrl+C` to return to the menu.

Run the monitor separately with:

```bash
droidspaces-video.sh --once
droidspaces-video.sh --json
droidspaces-video.sh --interval 2
```

Monitoring uses Bash, awk, jq, and GNU coreutils/findutils, included in the built images. `--no-color` disables colored output.

### Logs and recovery

Installers and GPU configuration share a modification lock. Logs and stage records are stored in `/var/lib/droidspaces-tui/operations/transactions`; non-root pre-download logs use `~/.local/state/droidspaces-tui/logs`.

Failed or interrupted operations restore backed-up configuration. An unfinished TUI file update recovers on the next run. Package transactions may already have completed; restoring configuration cannot undo the entire installation. Use the log to verify or repair package state with the relevant installer.

Print diagnostic status with:

```bash
droidspaces-tui --status
droidspaces-tui --json
```

## Mesa Installer

`install-mesa` selects the ARM64 Mesa asset for the current distribution from the distribution Release in GitHub/proxy mode; CNB mode reads only `mesa-distribution-manifest` from the matching CNB Release. It then installs the synchronized `msm_drm_drv_video.so`. It supports Debian 13, Ubuntu 24.04/25.10/26.04, Fedora 43/44/45, and Arch Linux. The video codec driver is installed in each distribution's default libva driver directory: `/usr/lib/aarch64-linux-gnu/dri` on Debian/Ubuntu, `/usr/lib64/dri` on Fedora, and `/usr/lib/dri` on Arch Linux.

The installer strictly validates Release tags, asset names, and downloaded content. GitHub/proxy mode retains GitHub Release API SHA-256 cross-checks; CNB mode uses only the SHA-256 values and sizes in the CNB distribution manifest, then still verifies the synchronized media-driver `SHA256SUMS`. Downloads can resume, and temporary files are removed on exit.

Run interactively inside the container:

```bash
sudo install-mesa
```

With no option, the script probes all three sources and prompts for a choice. Select a source directly for unattended builds:

```bash
sudo install-mesa --1  # GitHub
sudo install-mesa --2  # gh-proxy.com
sudo install-mesa --3  # CNB
```

The source options are mutually exclusive and apply to both Mesa and video codec driver downloads. `-1`, `-2`, and `-3` are equivalent short options; use `--help` for built-in help.

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

Profiles that require patched Wayland packages must also map to a package family in `lib/anland-build.sh` through `anland_package_family`.

Dockerfiles configure desktop translation files: Fedora writes `%_install_langs all`, Debian/Ubuntu disable the dpkg locale `path-exclude`, and Arch removes `NoExtract`.

KDE/KDE Mobile profiles install `xdg-desktop-portal` and `xdg-desktop-portal-kde`, plus `etc/pipewire/client.conf.d/90-droidspaces-portal-rt-workaround.conf` under `/etc/pipewire/client.conf.d/`. This configuration sets `rtportal.enabled = false`. See [xdg-desktop-portal #2110](https://github.com/flatpak/xdg-desktop-portal/issues/2110) and [#2139](https://github.com/flatpak/xdg-desktop-portal/pull/2139) for related issues.

## Anland KDE Installer

`install-anland-kde` reads `anland-kde-manifest` from the fixed `anland-kde-packages` rolling Release in `Goldzxcbug/droidspaces-package` by default, then installs the matching patched KWin/Xwayland packages for Debian 13, Ubuntu 26.04, Fedora 43/44/45, or Arch Linux on ARM64.

```bash
sudo install-anland-kde
```

Use `--1`, `--2`, or `--3` for GitHub, `gh-proxy.com`, or CNB; with no option, the installer probes sources and prompts. GitHub/proxy mode uses GitHub API digest checks; CNB mode uses its synchronized manifest. Messages follow the system locale, and APT holds, DNF excludes, or Pacman `IgnorePkg` entries lock the related packages.

To install packages published by a public fork, override only the repository. The fork must provide the fixed `anland-kde-packages` tag:

```bash
sudo ANLAND_RELEASE_REPOSITORY=owner/repository \
  install-anland-kde --1
```

The Anland host module, app, SELinux policy, bind mount, and Droidspaces permissions must still be configured as described in the [Wayland and Anland setup guide](../docs/en/desktop-and-anland.md#anland-wayland-host-setup).

## Anland GNOME Installer

`install-anland-gnome` reads the matching archive from `anland-gnome-manifest` in the fixed `anland-gnome-packages` rolling Release. It installs patched Mutter runtime packages for Debian 13, Ubuntu 26.04, Fedora 43/44/45, or Arch Linux ARM64 and locks them with APT holds, DNF excludes, or Pacman `IgnorePkg`. Download sources and arguments match the KDE installer.

```bash
sudo install-anland-gnome
```

Override the repository variable when using packages from a public fork:

```bash
sudo ANLAND_RELEASE_REPOSITORY=owner/repository \
  install-anland-gnome --1
```

## Anland Next Installer

`install-anland-next` reads `anland-session-manifest` from the fixed `anland-session-packages` rolling Release and installs the `anland-session` package for Debian 13, Ubuntu 26.04, Fedora 43/44/45, or Arch Linux on ARM64. Its source selection, mirror digest checks, and arguments match the KDE installer.

```bash
sudo install-anland-next
```

The package contains `anland-miniwm`, patched Xwayland, and patched bubblewrap. The latter two live in `/usr/lib/anland/`, which the session adds to `PATH`.

The session entry is `/usr/bin/anland-session`, used with `/usr/lib/systemd/user/anland-session.service`.

The Anland Next profile defaults Qt 6 applications to native Wayland and installs the platform plugin. Interactive user shells import `~/.anlandx-env` while the session is running.

To use packages from a public fork, override the repository variable:

```bash
sudo ANLAND_NEXT_RELEASE_REPOSITORY=owner/repository \
  install-anland-next --1
```

## Anland Niri, Hyprland, Mango, and Denial Installers

Niri, Hyprland, Mango, and Denial installers fetch their compositor and patched `xorg-xwayland` packages from fixed rolling Releases on Debian 13, Ubuntu 26, Fedora 43/44/45, and Arch ARM64. Each desktop has its own profile at `scripts/desktops/<slug>.sh`; the profile provides a terminal, XDG portal, audio, and fonts, and Niri on Arch also includes common desktop utilities. These compositors share patched Xwayland, and their installers prevent conflicting replacement while preserving packages used by other installed components.

Choose the command for your desktop:

```bash
sudo install-anland-niri
sudo install-anland-hyprland
sudo install-anland-mango
sudo install-anland-denial
```

## USB Manager Installer

`install-usb-manager.sh` supports Debian/Ubuntu, Fedora, and Arch. It installs PyQt5, ADB, udev, NTFS, exFAT, and other matching dependencies, followed by the `usb-manager`, `usb-passthrough`, and `usb-storage-passthrough` commands.

```bash
sudo ./scripts/install-usb-manager.sh --user "$USER"
```

`--user USER` selects the user that receives USB management permissions and desktop launchers. When omitted, the installer tries `SUDO_USER`, the logged-in user, and then the first regular user. Development and offline tests can use a local Droidspaces-USB-Manager checkout through `--source DIR`; run `--help` for all options.

When `/etc/droidspaces-systemd257` exists on Arch, the installer preserves the systemd Pacman lock and installs the remaining dependencies.

Hardware access must be enabled when importing the RootFS into Droidspaces, or `/sys/bus/usb` and `/sys/bus/scsi` will not be visible inside the container.

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

## TUI Downloads and Maintenance

TUI source is maintained in [`droidspaces-package`](https://github.com/Goldzxcbug/droidspaces-package). RootFS builds fetch the current publication from that repository's `Gold-bug-tui` rolling Release.

Download it from this repository's root:

```bash
bash scripts/sync-tui.sh --output .build/tui
```

Use the CNB mirror with:

```bash
bash scripts/sync-tui.sh --output .build/tui --source cnb
```

The downloader uses Bash, curl, GNU tar/coreutils, gzip, and `flock` from util-linux. It verifies the release manifest and the SHA-256 and size of `Gold-bug-tui.tar.gz`, checks archive paths, file types, duplicate members, and expanded size, and rejects links and traversal. After extraction, `Gold-bug-tui-files` supplies the digest, size, and Shell syntax checks for each entry point and `lib/*.sh`. Limits are 32 MiB for the compressed archive, 64 MiB for all expanded files, 8 MiB per script, and 128 archive members. Changed release content or a failed check stops the build and preserves the previous download directory. Files are stored in `.build/tui` and are not committed to the repository.

The native/QEMU entry points download files into separate temporary directories, pass them to Docker, and clean up when finished. GitHub is the default; set `DROIDSPACES_TUI_SOURCE=cnb` to use CNB. Each build checks the current release; building the same RootFS commit at different times may include different TUI versions. Images save the release manifest `Gold-bug-tui-manifest` and file manifest `Gold-bug-tui-files` under `/usr/local/share/droidspaces-tui/`. Offline `--check` also verifies matching revisions, shared libraries, and entry-point digests.

Verify files that have already been downloaded:

```bash
bash scripts/sync-tui.sh --output .build/tui --check
```

## Development Checks

Run syntax and static checks from the repository root:

```bash
bash -n scripts/sync-tui.sh
bash -n scripts/install-rootfs-tools.sh
bash -n scripts/install-usb-manager.sh
shellcheck scripts/sync-tui.sh
shellcheck scripts/install-rootfs-tools.sh
```

TUI and Anland installers are maintained directly in the package repository, with syntax and static checks. Test package installation and lock changes in APT, DNF, and Pacman containers, and repeat installation to check idempotency.
