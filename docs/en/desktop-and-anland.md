[Documentation index](README.md) · [Project home](../../README_english.md)

# Desktop Startup and Anland Wayland

## Desktop auto-start

When `desktop_autostart` is enabled, the RootFS installs `desktop-session.service`. It runs the session as UID 1000 and reads `/etc/droidspaces-desktop.conf` to select the desktop.

| Desktop and backend | Manual command |
| --- | --- |
| KDE + X11 (unsupported on Arch) | `DISPLAY=:5 startplasma-x11` |
| KDE + Anland Wayland | `startplasma-wayland` |
| KDE Mobile + Anland Wayland | `startplasmamobile` |
| GNOME + Anland Wayland | `gnome-session --session=gnome` |
| Anland Next | `/usr/bin/anland-session` |
| Niri | `/usr/bin/niri-anland` |
| Hyprland | `/usr/bin/hyprland-anland` |
| Mango | `/usr/bin/mango-anland` |
| Denial | `/usr/bin/denial-anland` |

After an unexpected exit, systemd retries after 2 seconds. More than 5 failures within 60 seconds pauses retries. A normal exit does not restart the session.

### X11

X11 uses `DISPLAY=:5`; install and start Termux:X11 on Android. If auto-start is disabled, run this in the container:

```bash
startplasma-x11
```

### Anland Wayland host setup

Anland Wayland supports Debian 13, Ubuntu 26, Fedora 43/44, and Arch. Arch KDE uses Anland Wayland only. KDE uses patched KWin/Xwayland; GNOME uses patched Mutter and installs a full desktop with common applications. Niri, Hyprland, Mango, and Denial include a lightweight session, terminal, XDG portal, audio, and fonts for users to extend. Their ARM64 packages are published by [`droidspaces-package`](https://github.com/Goldzxcbug/droidspaces-package) and installed from the matching Release during RootFS creation.

Each lightweight compositor has its own `desktops/<slug>.sh` profile; the profile writes the session and Anland/Mesa environment to `/etc/environment`, like the other desktop profiles. The shared desktop launcher runs each packaged compositor command directly without a session wrapper.

Prepare the Android device:

1. Download the device-matching `virtual-drm-daemon.zip` from [Anland Releases](https://github.com/superturtlee/anland/releases), install it as documented by that project, and reboot.
2. Download and install `app-debug.apk` from the same Release.
3. Enable hardware access in the Droidspaces container settings.
4. Use privileged mode and enable `nocaps` and `noseccomp`.
5. Configure SELinux for the device: use permissive mode or allow the Anland display service to access the required socket.
6. Add this bind mount in the advanced options:

   ```text
   /data/local/tmp/display_daemon.sock -> /run/display.sock
   ```

Start the container and log in as the normal user. For KDE run `startplasma-wayland`; KDE Mobile uses `startplasmamobile`; GNOME uses `gnome-session --session=gnome`.

### Install or update Anland desktop packages

The build fetches matching packages automatically. To install them separately in a running ARM64 RootFS, run from the repository root:

```bash
sudo ./scripts/tui/install-anland-kde.sh
```

The GNOME installer runs on Debian 13, Ubuntu 26, Fedora 43/44, and Arch Linux ARM:

```bash
sudo ./scripts/tui/install-anland-gnome.sh
```

The in-container installer supports Debian, Ubuntu, Fedora, and Arch packages and reads the matching target from the `anland-gnome-packages` Release manifest.

See the [script guide](../../scripts/README_english.md#anland-kde-installer) for installer options, download sources, and verification.
