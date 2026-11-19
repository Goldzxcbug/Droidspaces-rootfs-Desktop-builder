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

### Fcitx5 input method

Enable `enable_srf` when building the RootFS to install Fcitx5. Chinese builds include Pinyin by default. In a text field, press `Ctrl+Space` to switch input methods. GTK3/4 and recent Qt6 apps prefer the native Wayland input protocol. XWayland apps use XIM or the GTK and Qt input modules with the same Fcitx5 instance. Native GTK and Qt apps on Anland Next use the Fcitx5 toolkit modules.

Chrome in Wayland images defaults to Wayland input. To check XWayland, quit any open Chrome windows, run `google-chrome --ozone-platform=x11`, and test Pinyin in the address bar. You can also launch GTK apps with `GDK_BACKEND=x11` and Qt apps with `QT_QPA_PLATFORM=xcb` to test their XWayland input.

### Install or update Anland desktop packages

The build fetches matching packages automatically. To install them separately in a running ARM64 RootFS, run inside the container:

```bash
sudo install-anland-kde
```

The GNOME installer runs on Debian 13, Ubuntu 26, Fedora 43/44, and Arch Linux ARM:

```bash
sudo install-anland-gnome
```

See the [script guide](../../scripts/README_english.md#anland-kde-installer) for installer options, download sources, and verification.
