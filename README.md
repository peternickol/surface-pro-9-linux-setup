# Surface Pro 9 Linux Setup

Debian/Ubuntu setup script for running Linux on a Surface Pro 9, including the
linux-surface kernel, touchscreen, rotation, camera, power, and tablet-mode
fixes.

## What It Does

`install-surface-pro-9.sh` configures the linux-surface apt repository and
installs the Surface kernel packages:

- `linux-image-surface`
- `linux-headers-surface`
- `iptsd`
- `linux-surface-secureboot-mok`

It also installs useful support packages when they are available from your
configured apt repositories, including:

- `libwacom-surface`
- `thermald`
- `iio-sensor-proxy`
- `surface-control`
- camera and libcamera utilities
- `powertop`
- `maliit-keyboard`

The script also applies Surface Pro 9 desktop and boot tweaks:

- Enables Surface services such as `iptsd`, `thermald`, and
  `iio-sensor-proxy` when installed.
- Enables GNOME tablet settings for auto-rotation and the built-in on-screen
  keyboard.
- Installs a GNOME user auto-rotation helper for systems where GNOME does not
  rotate the internal display correctly.
- Installs `surface-toggle-rotation-lock.sh` to pause or resume auto-rotation from
  a terminal or custom keyboard shortcut.
- Binds `surface-toggle-rotation-lock.sh` to `Super+O` in GNOME when a desktop
  session is active.
- Adds Surface input modules to initramfs so hardware input has a better chance
  of working at encrypted-disk unlock prompts.
- Applies GRUB parameters for known Surface Pro 9 display/ACPI quirks.
- Installs touchscreen calibration where applicable.

## Supported System

This is intended for the Intel Surface Pro 9 on Debian/Ubuntu-based
distributions using `apt`.

The script checks for `amd64` and exits if the machine does not identify itself
as a Surface Pro 9. To run on unsupported hardware anyway, set
`SURFACE_ALLOW_UNSUPPORTED=1`.

## Important Changes

This script installs packages and writes system configuration as root. It also
updates GRUB and initramfs settings so the linux-surface kernel and Surface
input modules are available on boot. Keep a backup boot option or recovery USB
available before running it on a machine you depend on.

## Usage

Run:

```bash
chmod +x install-surface-pro-9.sh
./install-surface-pro-9.sh
```

Reboot afterwards.

To run on hardware that does not identify itself as a Surface Pro 9:

```bash
SURFACE_ALLOW_UNSUPPORTED=1 ./install-surface-pro-9.sh
```

If Secure Boot is enabled, enroll the linux-surface MOK key when prompted by the
blue MokManager screen. The linux-surface package uses this password:

```text
surface
```

After reboot, verify the running kernel:

```bash
uname -a
```

The kernel string should include `surface`.

## Notes

For touchscreen support, verify `iptsd` after reboot:

```bash
systemctl status iptsd.service
```

For auto-rotation, verify sensor events:

```bash
monitor-sensor
```

If the Surface rotates too eagerly, toggle GNOME's rotation lock:

```bash
surface-toggle-rotation-lock.sh
```

The helper prints the new state and shows a desktop notification when
`notify-send` is available. The installer places this helper in `~/.local/bin`
and binds it to `Super+O` when a GNOME session is active. Override the binding
while installing with:

```bash
SURFACE_ROTATION_LOCK_BINDING='<Super><Shift>o' ./install-surface-pro-9.sh
```

For the login screen and GNOME desktop on-screen keyboard, use GNOME's built-in
screen keyboard. Maliit Keyboard is installed when available for post-login
experimentation, but GDM still uses GNOME Shell's keyboard.

If your system uses full-disk encryption, keep a USB keyboard available as a
fallback until you have verified input at the unlock prompt after reboot. Most
distributions do not provide an on-screen keyboard that early in boot.

## License

MIT License. See [`LICENSE`](./LICENSE).
