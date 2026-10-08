# Surface Pro 9 Linux Setup

Debian/Ubuntu setup script for the **Intel Surface Pro 9**, including the
linux-surface kernel, firmware, touchscreen, rotation, power, and tablet settings.
Debian 12 (bookworm) and Debian 13 (trixie), amd64, are the compatibility targets.

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

On Debian, required firmware packages are `firmware-iwlwifi`,
`firmware-sof-signed`, `intel-microcode`, and `firmware-intel-graphics`
(or `firmware-misc-nonfree` on bookworm). Ubuntu uses `linux-firmware` and
`intel-microcode`. Package availability is checked using APT's candidate version.

All package installs use `--no-remove`. The optional `libwacom-surface` package
can conflict with Debian's libwacom packages; it is skipped if installing it
would require removals. The distribution's existing packages remain installed.
Upstream also [warns against this replacement on Debian testing/sid and Ubuntu
26.04](https://github.com/linux-surface/linux-surface/wiki/Installation-and-Setup#debian--ubuntu).

The script also applies Surface Pro 9 desktop and boot tweaks:

- Enables services such as `thermald` when installed and starts static services
  such as `iio-sensor-proxy`. Modern `iptsd@.service` instances are started by
  udev when the touchscreen appears; the template is not enabled manually.
- Enables GNOME tablet settings for auto-rotation and the built-in on-screen
  keyboard.
- Installs a GNOME user auto-rotation helper for systems where GNOME does not
  rotate the internal display correctly.
- Installs `surface-toggle-rotation-lock` to pause or resume auto-rotation from
  a terminal or custom keyboard shortcut.
- Binds `surface-toggle-rotation-lock` to `Super+O` in GNOME when a desktop
  session is active.
- Adds Surface input modules to initramfs so hardware input has a better chance
  of working at encrypted-disk unlock prompts.
- Applies GRUB parameters for known Surface Pro 9 display/ACPI quirks.
- Installs touchscreen calibration where applicable.

## Supported System

Run on an installed, booted Debian 12/13 system with systemd and APT. The boot
setup supports GRUB and initramfs-tools (or dracut). Other bootloaders require
manual kernel selection and kernel command-line configuration. The desktop
settings and rotation helper require GNOME; GNOME Wayland is recommended for
touch input. Other desktops can use the kernel/firmware setup, with their own
desktop-specific tablet configuration.

Ubuntu/Debian derivatives remain accepted, but the automated compatibility
matrix covers Debian 12 and 13 only. Debian 11 and older are rejected; newer
releases and testing/sid report an unvalidated-release warning.

The script checks for `amd64` and exits if the machine does not identify itself
as a Surface Pro 9. To run on unsupported hardware anyway, set
`SURFACE_ALLOW_UNSUPPORTED=1`.
This only bypasses the model check; it does not enable ARM/SQ3 support.

Compatibility checks cover shell behavior and live APT dependency resolution in
Debian containers. They do **not** prove boot, Secure Boot enrollment, or hardware
operation on a physical Surface. See the post-reboot checks below.

### Hardware limitations

The [linux-surface feature matrix](https://github.com/linux-surface/linux-surface/wiki/Supported-Devices-and-Features)
currently lists the Intel Surface Pro 9 cameras as unsupported. Installing
libcamera utilities does not enable them. Suspend/hibernate and standby power
also have [device-specific caveats](https://github.com/linux-surface/linux-surface/wiki/Surface-Pro-9).

## Important Changes

This script installs packages and writes system configuration as root. It also
updates GRUB and initramfs settings so the linux-surface kernel and Surface
input modules are available on boot. Keep a backup boot option or recovery USB
available before running it on a machine you depend on.

## Usage

On Debian, enable `non-free-firmware` in your existing Debian APT sources before
running. For deb822 files such as `/etc/apt/sources.list.d/debian.sources`, the
component field should include:

```text
Components: main non-free-firmware
```

Keep any existing `contrib`/`non-free` components. For traditional
`/etc/apt/sources.list` or `.list` entries, append `non-free-firmware` to the
Debian `deb` lines. The installer refreshes APT and reports missing firmware
candidates; it does not rewrite your Debian sources. Debian package references:
[bookworm graphics firmware](https://packages.debian.org/bookworm/firmware-misc-nonfree),
[trixie graphics firmware](https://packages.debian.org/trixie/firmware-intel-graphics),
[Wi-Fi firmware](https://packages.debian.org/trixie/firmware-iwlwifi),
[audio firmware](https://packages.debian.org/trixie/firmware-sof-signed).

Run from a terminal in your GNOME session as your normal user, with sudo access:

```bash
chmod +x install-surface-pro-9.sh
./install-surface-pro-9.sh
```

Debian installations without sudo can run the script from a root shell obtained
with `su -`. Specify the existing desktop account explicitly (replace `alice`
and the checkout path):

```bash
SURFACE_DESKTOP_USER=alice bash /path/to/surface-pro-9-linux-setup/install-surface-pro-9.sh
```

GNOME settings and shortcut registration require that account to have an active
session. A root-only invocation skips per-user configuration if no non-root
desktop account can be identified. Helpers are installed as independent copies
in the account's home directory and do not require the checkout afterwards.

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
systemctl status 'iptsd*'
journalctl -b -u 'iptsd*'
```

Current packages use instances such as `iptsd@dev-hidraw0.service`; the actual
hidraw number varies. Older packages may use `iptsd.service`.

For auto-rotation, verify sensor events:

```bash
monitor-sensor
```

For GNOME's additional rotation helper:

```bash
systemctl --user status surface-auto-rotate.service
```

It uses Debian's `/usr/bin/python3` and `python3-gi`, so a Python virtual
environment or a Python installation in `/usr/local` cannot hide PyGObject.
The service only starts when GNOME's Mutter display service is available.

If the Surface rotates too eagerly, toggle GNOME's rotation lock:

```bash
surface-toggle-rotation-lock
```

The source file is `surface-toggle-rotation-lock.sh`, but the installer places
it in `~/.local/bin` as `surface-toggle-rotation-lock`. The helper prints the
new state and shows a desktop notification when `notify-send` is available, and
the installer binds it to `Super+O` when a GNOME session is active. Override the
binding while installing with:

```bash
SURFACE_ROTATION_LOCK_BINDING='<Super><Shift>o' ./install-surface-pro-9.sh
```

For the login screen and GNOME desktop on-screen keyboard, use GNOME's built-in
screen keyboard. Maliit Keyboard is installed when available for post-login
experimentation, but GDM still uses GNOME Shell's keyboard.

If your system uses full-disk encryption, keep a USB keyboard available as a
fallback until you have verified input at the unlock prompt after reboot. Most
distributions do not provide an on-screen keyboard that early in boot.

GRUB tweaks live in `/etc/default/grub.d/99-surface-pro-9.cfg`, preserving the
existing `/etc/default/grub` command line. The installer regenerates the menu
before saving the selected Surface kernel entry. Rerun after a Surface kernel
upgrade to select the latest installed version. Keep Debian's stock kernel as
a fallback. After reboot, also check touch/pen, display rotation, Wi-Fi,
Bluetooth, speakers, power/volume buttons, suspend/resume, and encrypted-disk
keyboard input if applicable.

## Development checks

Local checks do not install packages or change system configuration:

```bash
bash -n install-surface-pro-9.sh surface-toggle-rotation-lock.sh tests/debian-packages.sh
shellcheck install-surface-pro-9.sh surface-toggle-rotation-lock.sh tests/debian-packages.sh
python3 -m unittest discover -s tests -v
```

Run live package dependency checks in disposable Docker containers:

```bash
for release in bookworm trixie; do
  docker run --rm --platform linux/amd64 \
    --mount "type=bind,src=$PWD,dst=/work,readonly" --workdir /work \
    "debian:${release}-slim" bash tests/debian-packages.sh
done
```

The container check installs test tools and userspace support packages,
configures the signed linux-surface repository, runs regression checks, and
checks the installed iptsd unit and GNOME helper installation. It then simulates
package installation alongside Debian's GNOME desktop and signed bootloader.
It does not install or boot a Surface kernel. GitHub Actions runs this matrix
on pushes and pull requests.

## License

MIT License. See [`LICENSE`](./LICENSE).
