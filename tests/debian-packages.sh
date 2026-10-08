#!/usr/bin/env bash
# Run only in a disposable Debian container: this changes its APT sources/packages.
set -Eeuo pipefail

if [[ ! -f /.dockerenv || $EUID -ne 0 ]]; then
  printf 'Run this check as root inside a disposable Docker container.\n' >&2
  exit 1
fi

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
# shellcheck source=install-surface-pro-9.sh
source ./install-surface-pro-9.sh
detect_distribution /etc/os-release
[[ "$DISTRO_ID" == debian ]]

# Official Debian images use deb822 sources with only main enabled.
sed -i '/^Components:/ s/$/ non-free-firmware/' /etc/apt/sources.list.d/debian.sources
apt-get update -o APT::Update::Error-Mode=any
apt-get install -y --no-install-recommends ca-certificates curl gnupg python3 python3-gi shellcheck

bash -n install-surface-pro-9.sh surface-toggle-rotation-lock.sh tests/debian-packages.sh
shellcheck install-surface-pro-9.sh surface-toggle-rotation-lock.sh tests/debian-packages.sh
python3 -m unittest discover -s tests -v
install_linux_surface_repository

# Exercise the shipped userspace units and install independent desktop helpers.
# These packages do not install a kernel with Recommends disabled.
apt-get install -y --no-install-recommends iptsd iio-sensor-proxy \
  libglib2.0-bin gnome-settings-daemon-common dbus systemd
service_unit_exists iptsd@.service
if service_unit_exists surface-nonexistent.service; then
  error "A missing unit was treated as installed."
  exit 1
fi
useradd --create-home surface-test
SURFACE_DESKTOP_USER=surface-test
install_surface_auto_rotate
install_rotation_lock_toggle
test -x /home/surface-test/.local/bin/surface-auto-rotate
test -x /home/surface-test/.local/bin/surface-toggle-rotation-lock
runuser -u surface-test -- test -w /home/surface-test/.local
runuser -u surface-test -- test -w /home/surface-test/.config
runuser -u surface-test -- test -w /home/surface-test/.config/systemd

# The service condition must skip a non-GNOME bus with status 1, not fail with
# an unsupported gdbus command or option. No graphical session is needed.
condition_status=0
dbus-run-session -- /usr/bin/gdbus wait --session --timeout 1 \
  org.gnome.Mutter.DisplayConfig || condition_status=$?
[[ "$condition_status" -eq 1 ]]

mapfile -t firmware < <(firmware_packages)
packages=("${SURFACE_CORE_PACKAGES[@]}" "${firmware[@]}")
for package in "${SURFACE_SUPPORT_PACKAGES[@]}"; do
  # Surface libwacom replaces distro packages; it is intentionally optional.
  [[ "$package" == libwacom-surface ]] && continue
  if apt_package_exists "$package"; then
    packages+=("$package")
  else
    warn "Optional package unavailable: $package"
  fi
done

# Resolve dependencies together with the distro desktop and signed bootloader.
# No kernel/bootloader is actually installed or booted in this check.
apt-get --simulate install --no-remove "${packages[@]}" gnome-shell gdm3 grub-efi-amd64-signed shim-signed
ok "Debian package dependency simulation passed"
