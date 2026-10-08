#!/usr/bin/env bash
set -Eeuo pipefail

# Debian's regular users (and plain `su` sessions) may omit the sbin paths.
export PATH="${PATH}:/usr/sbin:/sbin"

if [[ -t 1 || -t 2 ]] && [[ "${NO_COLOR:-0}" != "1" ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_RED=""
  C_YELLOW=""
  C_GREEN=""
  C_CYAN=""
fi

info() { printf '%b[INFO]%b %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%b[OK]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%b[ERROR]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

on_error() {
  local exit_code="$?"
  local line_no="${BASH_LINENO[0]:-unknown}"
  error "${BASH_SOURCE[1]}:${line_no}: '${BASH_COMMAND}' exited with status ${exit_code}"
}
trap on_error ERR

SURFACE_APT_KEY_URL="${SURFACE_APT_KEY_URL:-https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc}"
SURFACE_APT_KEYRING="${SURFACE_APT_KEYRING:-/usr/share/keyrings/linux-surface.gpg}"
SURFACE_APT_SOURCE="${SURFACE_APT_SOURCE:-/etc/apt/sources.list.d/linux-surface.list}"
SURFACE_APT_REPO="${SURFACE_APT_REPO:-https://pkg.surfacelinux.com/debian}"
SURFACE_MOK_CERT="${SURFACE_MOK_CERT:-/usr/share/linux-surface-secureboot/surface.cer}"
SURFACE_ALLOW_UNSUPPORTED="${SURFACE_ALLOW_UNSUPPORTED:-0}"
SURFACE_ROTATION_LOCK_BINDING="${SURFACE_ROTATION_LOCK_BINDING:-<Super>o}"
SURFACE_DESKTOP_USER="${SURFACE_DESKTOP_USER:-}"

DISTRO_ID=""
DISTRO_ID_LIKE=""

SURFACE_CORE_PACKAGES=(
  linux-image-surface
  linux-headers-surface
  iptsd
  linux-surface-secureboot-mok
)

SURFACE_SUPPORT_PACKAGES=(
  libwacom-surface
  python3-gi
  thermald
  iio-sensor-proxy
  libnotify-bin
  surface-control
  libcamera-tools
  gstreamer1.0-libcamera
  pipewire-libcamera
  v4l-utils
  powertop
  maliit-keyboard
)

GNOME_TABLET_SETTINGS=(
  "org.gnome.desktop.a11y.applications screen-keyboard-enabled true"
  "org.gnome.settings-daemon.peripherals.touchscreen orientation-lock false"
)

SURFACE_INITRAMFS_MODULES=(
  pinctrl_tigerlake
  intel_lpss
  intel_lpss_pci
  8250_dw
  surface_aggregator
  surface_aggregator_registry
  surface_aggregator_hub
  surface_hid_core
  surface_hid
)

FAILURES=()

detect_distribution() {
  local release_file=${1:-/etc/os-release}
  local ID="" ID_LIKE="" VERSION_ID=""

  if [[ ! -r "$release_file" ]]; then
    error "Cannot identify this distribution: $release_file is missing."
    return 1
  fi
  # shellcheck disable=SC1090
  source "$release_file"
  DISTRO_ID=$ID
  DISTRO_ID_LIKE=$ID_LIKE

  case " $ID $ID_LIKE " in
    *" debian "*|*" ubuntu "*) ;;
    *) error "This installer requires Debian or an Ubuntu/Debian derivative."; return 1 ;;
  esac
  if [[ "$ID" == debian ]]; then
    case "$VERSION_ID" in
      12|13) ;;
      ''|*[!0-9]*) warn "Debian testing/unstable is not a validated target." ;;
      *)
        if ((VERSION_ID < 12)); then
          error "Use Debian 12 (bookworm) or Debian 13 (trixie); older releases are unsupported."
          return 1
        fi
        warn "This Debian release has not been validated; targets are Debian 12 and 13."
        ;;
    esac
  fi
  info "Detected ${PRETTY_NAME:-$ID}"
}

firmware_packages() {
  case " $DISTRO_ID $DISTRO_ID_LIKE " in
    *" ubuntu "*) printf '%s\n' linux-firmware intel-microcode ;;
    *)
      printf '%s\n' firmware-iwlwifi firmware-sof-signed intel-microcode
      if apt_package_exists firmware-intel-graphics; then
        printf '%s\n' firmware-intel-graphics
      else
        # Bookworm predates the split of Intel GPU firmware into its own package.
        printf '%s\n' firmware-misc-nonfree
      fi
      ;;
  esac
}

install_firmware() {
  local package
  local packages=()
  local missing=()
  mapfile -t packages < <(firmware_packages)
  for package in "${packages[@]}"; do
    if ! apt_package_exists "$package"; then
      missing+=("$package")
    fi
  done
  if ((${#missing[@]})); then
    error "Required firmware packages have no APT candidate: ${missing[*]}"
    warn "On Debian 12/13, enable non-free-firmware for your Debian sources, run apt-get update, then rerun."
    warn "For deb822 .sources files, add it to Components:; for .list files, append it to the Debian deb lines."
    return 1
  fi
  apt_install "${packages[@]}"
}

record_failure() {
  local item=$1
  FAILURES+=("$item")
  error "FAILED: $item"
}

print_apt_update_errors() {
  local log_file=$1

  warn "apt-get update reported errors. Relevant lines:"
  grep -E '^(Err:|W:|E:)' "$log_file" >&2 || warn "No apt error lines were captured."

  if grep -Eq '401 Unauthorized' "$log_file" && grep -Eq 'pkg\.surfacelinux\.com' "$log_file"; then
    warn "If this is a linux-surface 401 error, see:"
    warn "https://github.com/linux-surface/linux-surface/wiki/Known-Issues-and-FAQ#apt-update-fails-on-ubuntudebian-based-distributions-with-error-401-unauthorized"
  fi
}

run_apt_update() {
  local label=$1
  local log_file

  info "Running apt-get update: $label"
  log_file="$(mktemp)"
  if as_root apt-get update -o Acquire::Retries=3 2>&1 | tee "$log_file"; then
    rm -f "$log_file"
    return 0
  fi

  print_apt_update_errors "$log_file"
  rm -f "$log_file"
  return 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

apt_install() {
  as_root apt-get install -y --no-remove "$@"
}

is_amd64() {
  [[ "$(dpkg --print-architecture)" == "amd64" ]]
}

is_surface_pro_9() {
  local product_name=""

  if [[ -r /sys/class/dmi/id/product_name ]]; then
    product_name="$(< /sys/class/dmi/id/product_name)"
  fi

  [[ "$product_name" == *"Surface Pro 9"* ]]
}

install_prerequisites() {
  info "Installing prerequisites"
  if ! run_apt_update "before linux-surface repo setup"; then
    warn "Continuing because the prerequisite packages may still be installable from existing apt indexes."
  fi
  apt_install ca-certificates curl gnupg
}

install_linux_surface_repository() {
  local key_tmp
  info "Configuring linux-surface apt repository"
  key_tmp="$(mktemp -d)"
  if ! curl -fsSL "$SURFACE_APT_KEY_URL" -o "$key_tmp/surface.asc" \
    || ! gpg --batch --dearmor -o "$key_tmp/surface.gpg" "$key_tmp/surface.asc"; then
    rm -rf "$key_tmp"
    error "Could not download/dearmor the linux-surface signing key; existing repository files were preserved."
    return 1
  fi
  as_root install -d -m 0755 "$(dirname "$SURFACE_APT_KEYRING")"
  as_root install -m 0644 "$key_tmp/surface.gpg" "$SURFACE_APT_KEYRING"
  rm -rf "$key_tmp"
  as_root install -d -m 0755 "$(dirname "$SURFACE_APT_SOURCE")"

  printf 'deb [arch=amd64 signed-by=%s] %s release main\n' "$SURFACE_APT_KEYRING" "$SURFACE_APT_REPO" \
    | as_root tee "$SURFACE_APT_SOURCE" >/dev/null

  if ! run_apt_update "after linux-surface repo setup"; then
    warn "apt-get update failed, but that may be caused by an unrelated apt source."
    warn "Checking whether the linux-surface kernel packages are available anyway."
  fi

  require_surface_packages_available || exit 1
}

apt_package_exists() {
  # `show` also succeeds for installed-only and pinned-out packages.
  LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '
    $1 == "Candidate:" && $2 != "(none)" { found = 1 }
    END { exit !found }
  '
}

require_surface_packages_available() {
  local missing=()
  local package

  for package in "${SURFACE_CORE_PACKAGES[@]}"; do
    if ! apt_package_exists "$package"; then
      missing+=("$package")
    fi
  done

  if ((${#missing[@]} == 0)); then
    return 0
  fi

  error "The linux-surface apt repository did not provide required package indexes."
  error "Missing packages: ${missing[*]}"
  warn "Run this for the exact apt error:"
  warn "sudo apt-get update -o Acquire::Retries=0"
  return 1
}

install_packages() {
  local package

  info "Installing linux-surface kernel and required Surface packages"
  for package in "${SURFACE_CORE_PACKAGES[@]}"; do
    if ! apt_install "$package"; then
      record_failure "Surface package: $package"
    fi
  done

  info "Installing useful Surface Pro 9 support packages where available"
  for package in "${SURFACE_SUPPORT_PACKAGES[@]}"; do
    if apt_package_exists "$package"; then
      if ! apt_install "$package"; then
        warn "Optional Surface support package failed; continuing: $package"
      fi
    else
      warn "Package unavailable in configured apt repositories; skipping: $package"
    fi
  done
}

service_unit_exists() {
  systemctl list-unit-files --no-legend "$1" | awk -v unit="$1" '
    $1 == unit { found = 1 }
    END { exit !found }
  '
}

enable_service_if_present() {
  local service=$1
  local load_state unit_state

  # list-unit-files can succeed with zero matches. Static units cannot be enabled.
  load_state="$(systemctl show -p LoadState --value "$service")" || return 1
  [[ "$load_state" == loaded ]] || return 0
  unit_state="$(systemctl show -p UnitFileState --value "$service")" || return 1
  case "$unit_state" in
    masked*) warn "Service is masked; leaving it unchanged: $service" ;;
    static|indirect) as_root systemctl start "$service" || record_failure "start service: $service" ;;
    *) as_root systemctl enable --now "$service" || record_failure "enable service: $service" ;;
  esac
}

configure_services() {
  info "Enabling Surface-related services when installed"
  # Templates have unit files but cannot be loaded without an instance name.
  if service_unit_exists iptsd@.service; then
    info "iptsd uses device instances; udev will start iptsd@*.service when the touchscreen appears after reboot."
  else
    enable_service_if_present iptsd.service
  fi
  enable_service_if_present thermald.service
  enable_service_if_present iio-sensor-proxy.service
}

desktop_user() {
  local user=""
  if [[ -n "$SURFACE_DESKTOP_USER" ]]; then
    user=$SURFACE_DESKTOP_USER
  elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    user=$SUDO_USER
  elif [[ "${EUID}" -ne 0 ]]; then
    user="$(id -un)"
  else
    user="$(logname 2>/dev/null || true)"
  fi
  if [[ -n "$user" && "$user" != root ]] && id "$user" >/dev/null 2>&1; then
    printf '%s\n' "$user"
  fi
}

run_gsettings_for_desktop_user() {
  local user=$1
  shift

  local uid
  local bus

  uid="$(id -u "$user" 2>/dev/null)" || return 1
  bus="/run/user/${uid}/bus"

  if [[ ! -S "$bus" ]]; then
    warn "No active D-Bus session found for $user; skipping GNOME setting: gsettings $*"
    warn "Log into GNOME and rerun this script, or set it manually in Settings."
    return 0
  fi

  if [[ "$(id -u)" -eq "$uid" ]]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" gsettings "$@"
  elif [[ "${EUID}" -eq 0 ]]; then
    runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" gsettings "$@"
  else
    sudo -u "$user" env DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" gsettings "$@"
  fi
}

gnome_key_exists() {
  local user=$1
  local schema=$2
  local key=$3

  run_gsettings_for_desktop_user "$user" list-keys "$schema" 2>/dev/null | grep -Fxq "$key"
}

gsettings_string() {
  local value=$1
  printf "'%s'" "${value//\'/\\\'}"
}

configure_gnome_tablet_settings() {
  local user
  local uid
  local bus
  local setting
  local schema
  local key
  local value

  if ! need_cmd gsettings; then
    warn "gsettings unavailable; skipping GNOME tablet settings."
    return 0
  fi

  user="$(desktop_user)"
  if [[ -z "$user" ]]; then
    warn "Could not determine the desktop user; skipping GNOME tablet settings."
    return 0
  fi

  uid="$(id -u "$user" 2>/dev/null)" || {
    warn "Could not determine uid for $user; skipping GNOME tablet settings."
    return 0
  }
  bus="/run/user/${uid}/bus"
  if [[ ! -S "$bus" ]]; then
    warn "No active D-Bus session found for $user; skipping GNOME tablet settings."
    warn "Log into GNOME and rerun this script, or set Screen Keyboard and rotation lock manually in Settings."
    return 0
  fi

  info "Configuring GNOME tablet settings for $user"
  for setting in "${GNOME_TABLET_SETTINGS[@]}"; do
    read -r schema key value <<<"$setting"
    if gnome_key_exists "$user" "$schema" "$key"; then
      run_gsettings_for_desktop_user "$user" set "$schema" "$key" "$value" \
        || record_failure "set GNOME tablet setting: $schema $key"
    else
      warn "GNOME setting unavailable; skipping: $schema $key"
    fi
  done
}

run_systemctl_for_desktop_user() {
  local user=$1
  shift

  local uid
  local bus

  uid="$(id -u "$user" 2>/dev/null)" || return 1
  bus="/run/user/${uid}/bus"

  if [[ ! -S "$bus" ]]; then
    warn "No active D-Bus session found for $user; skipping systemd user command: systemctl --user $*"
    return 0
  fi

  if [[ "$(id -u)" -eq "$uid" ]]; then
    XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" systemctl --user "$@"
  elif [[ "${EUID}" -eq 0 ]]; then
    runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" systemctl --user "$@"
  else
    sudo -u "$user" env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" systemctl --user "$@"
  fi
}

install_surface_auto_rotate() {
  local user
  local group
  local home
  local uid
  local bus
  local script_tmp
  local script_dir
  local script_file
  local service_tmp
  local service_dir
  local service_file

  if ! /usr/bin/python3 -c 'import gi; from gi.repository import Gio, GLib' >/dev/null 2>&1; then
    warn "python3 with PyGObject is unavailable; skipping Surface auto-rotate helper."
    return 0
  fi

  if ! need_cmd gsettings || ! gsettings list-keys org.gnome.settings-daemon.peripherals.touchscreen 2>/dev/null | grep -Fxq orientation-lock; then
    warn "GNOME touchscreen settings unavailable; skipping GNOME auto-rotate helper."
    return 0
  fi

  if ! need_cmd monitor-sensor; then
    warn "monitor-sensor unavailable; skipping Surface auto-rotate helper."
    return 0
  fi

  user="$(desktop_user)"
  if [[ -z "$user" ]]; then
    warn "Could not determine the desktop user; skipping Surface auto-rotate helper."
    return 0
  fi

  group="$(id -gn "$user" 2>/dev/null)" || {
    warn "Could not determine primary group for $user; skipping Surface auto-rotate helper."
    return 0
  }
  home="$(getent passwd "$user" | cut -d: -f6)"
  if [[ -z "$home" ]]; then
    warn "Could not determine home directory for $user; skipping Surface auto-rotate helper."
    return 0
  fi

  info "Installing Surface auto-rotate helper for $user"
  script_dir="$home/.local/bin"
  script_file="$script_dir/surface-auto-rotate"
  script_tmp="$(mktemp)"
  cat >"$script_tmp" <<'PY'
#!/usr/bin/python3
import os
import re
import subprocess
import sys
import time

import gi
from gi.repository import Gio, GLib

BUS_NAME = "org.gnome.Mutter.DisplayConfig"
OBJECT_PATH = "/org/gnome/Mutter/DisplayConfig"
INTERFACE = "org.gnome.Mutter.DisplayConfig"

ORIENTATION_TO_TRANSFORM = {
    "normal": int(os.environ.get("SURFACE_AUTO_ROTATE_NORMAL", "0")),
    "right-up": int(os.environ.get("SURFACE_AUTO_ROTATE_RIGHT_UP", "3")),
    "bottom-up": int(os.environ.get("SURFACE_AUTO_ROTATE_BOTTOM_UP", "2")),
    "left-up": int(os.environ.get("SURFACE_AUTO_ROTATE_LEFT_UP", "1")),
}


def orientation_locked():
    try:
        settings = Gio.Settings.new("org.gnome.settings-daemon.peripherals.touchscreen")
        return settings.get_boolean("orientation-lock")
    except Exception:
        return False


def display_proxy():
    return Gio.DBusProxy.new_for_bus_sync(
        Gio.BusType.SESSION,
        Gio.DBusProxyFlags.NONE,
        None,
        BUS_NAME,
        OBJECT_PATH,
        INTERFACE,
        None,
    )


def current_mode_by_connector(monitors):
    modes = {}
    for spec, available_modes, _props in monitors:
        connector = spec[0]
        preferred = None
        for mode in available_modes:
            mode_id = mode[0]
            mode_props = mode[6]
            if mode_props.get("is-current"):
                modes[connector] = mode_id
                break
            if mode_props.get("is-preferred"):
                preferred = mode_id
        else:
            modes[connector] = preferred or available_modes[0][0]
    return modes


def builtin_connectors(monitors):
    connectors = set()
    for spec, _available_modes, props in monitors:
        if props.get("is-builtin"):
            connectors.add(spec[0])
    return connectors


def apply_transform(transform):
    if orientation_locked():
        return

    proxy = display_proxy()
    serial, monitors, logical_monitors, _props = proxy.call_sync(
        "GetCurrentState", None, Gio.DBusCallFlags.NONE, -1, None
    ).unpack()

    builtins = builtin_connectors(monitors)
    if not builtins:
        print("surface-auto-rotate: no built-in display found", flush=True)
        return

    modes = current_mode_by_connector(monitors)
    configs = []
    changed = False

    for x, y, scale, current_transform, primary, monitor_specs, _logical_props in logical_monitors:
        monitor_configs = []
        has_builtin = False
        for connector, _vendor, _product, _serial in monitor_specs:
            monitor_configs.append((connector, modes[connector], {}))
            if connector in builtins:
                has_builtin = True

        next_transform = transform if has_builtin else current_transform
        if has_builtin and current_transform != next_transform:
            changed = True
        configs.append((x, y, scale, next_transform, primary, monitor_configs))

    if not changed:
        return

    variant = GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})", (serial, 1, configs, {}))
    proxy.call_sync("ApplyMonitorsConfig", variant, Gio.DBusCallFlags.NONE, -1, None)


def apply_orientation(orientation):
    transform = ORIENTATION_TO_TRANSFORM.get(orientation)
    if transform is None:
        return
    apply_transform(transform)
    print(f"surface-auto-rotate: {orientation} -> transform {transform}", flush=True)


def monitor_orientations():
    pattern = re.compile(r"orientation changed:\s+([a-z-]+)")
    last_orientation = None

    while True:
        with subprocess.Popen(
            ["monitor-sensor"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        ) as proc:
            assert proc.stdout is not None
            for line in proc.stdout:
                match = pattern.search(line)
                if not match:
                    continue
                orientation = match.group(1)
                if orientation == last_orientation:
                    continue
                last_orientation = orientation
                apply_orientation(orientation)

        time.sleep(2)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--once":
        apply_orientation(sys.argv[2])
        return
    monitor_orientations()


if __name__ == "__main__":
    main()
PY

  if [[ "${EUID}" -eq 0 ]]; then
    runuser -u "$user" -- mkdir -p "$script_dir"
    install -m 0755 -o "$user" -g "$group" "$script_tmp" "$script_file"
  else
    install -d -m 0755 "$script_dir"
    install -m 0755 "$script_tmp" "$script_file"
  fi
  rm -f "$script_tmp"

  service_dir="$home/.config/systemd/user"
  service_file="$service_dir/surface-auto-rotate.service"
  service_tmp="$(mktemp)"
  cat >"$service_tmp" <<'SERVICE'
[Unit]
Description=Surface automatic display rotation
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
# A user bus can exist in KDE, an SSH session, or before GNOME has started.
ExecCondition=/usr/bin/gdbus wait --session --timeout 1 org.gnome.Mutter.DisplayConfig
ExecStart=%h/.local/bin/surface-auto-rotate
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
SERVICE

  if [[ "${EUID}" -eq 0 ]]; then
    runuser -u "$user" -- mkdir -p "$service_dir"
    install -m 0644 -o "$user" -g "$group" "$service_tmp" "$service_file"
  else
    install -d -m 0755 "$service_dir"
    install -m 0644 "$service_tmp" "$service_file"
  fi
  rm -f "$service_tmp"

  uid="$(id -u "$user" 2>/dev/null)" || return 0
  bus="/run/user/${uid}/bus"
  if [[ -S "$bus" ]]; then
    if ! run_systemctl_for_desktop_user "$user" daemon-reload \
      || ! run_systemctl_for_desktop_user "$user" enable --now surface-auto-rotate.service; then
      record_failure "enable Surface auto-rotate user service"
    fi
  else
    warn "Log into GNOME and run: systemctl --user enable --now surface-auto-rotate.service"
  fi
}

install_rotation_lock_toggle() {
  local user
  local group
  local home
  local script_dir
  local script_file
  local source_file

  source_file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/surface-toggle-rotation-lock.sh"
  if [[ ! -r "$source_file" ]]; then
    warn "Rotation lock toggle script not found; skipping: $source_file"
    return 0
  fi

  user="$(desktop_user)"
  if [[ -z "$user" ]]; then
    warn "Could not determine the desktop user; skipping rotation lock toggle install."
    return 0
  fi

  group="$(id -gn "$user" 2>/dev/null)" || {
    warn "Could not determine primary group for $user; skipping rotation lock toggle install."
    return 0
  }
  home="$(getent passwd "$user" | cut -d: -f6)"
  if [[ -z "$home" ]]; then
    warn "Could not determine home directory for $user; skipping rotation lock toggle install."
    return 0
  fi

  info "Installing rotation lock toggle for $user"
  script_dir="$home/.local/bin"
  script_file="$script_dir/surface-toggle-rotation-lock"

  if [[ "${EUID}" -eq 0 ]]; then
    runuser -u "$user" -- mkdir -p "$script_dir"
    install -m 0755 -o "$user" -g "$group" "$source_file" "$script_file"
  else
    install -d -m 0755 "$script_dir"
    install -m 0755 "$source_file" "$script_file"
  fi
}

configure_rotation_lock_shortcut() {
  local user
  local uid
  local bus
  local home
  local media_schema="org.gnome.settings-daemon.plugins.media-keys"
  local shortcut_schema="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"
  local shortcut_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/surface-rotation-lock/"
  local current_shortcuts
  local updated_shortcuts
  local command

  if ! need_cmd gsettings; then
    warn "gsettings unavailable; skipping rotation lock shortcut."
    return 0
  fi

  user="$(desktop_user)"
  if [[ -z "$user" ]]; then
    warn "Could not determine the desktop user; skipping rotation lock shortcut."
    return 0
  fi

  uid="$(id -u "$user" 2>/dev/null)" || {
    warn "Could not determine uid for $user; skipping rotation lock shortcut."
    return 0
  }
  bus="/run/user/${uid}/bus"
  if [[ ! -S "$bus" ]]; then
    warn "No active D-Bus session found for $user; skipping rotation lock shortcut."
    warn "Log into GNOME and rerun this script, or bind surface-toggle-rotation-lock manually."
    return 0
  fi

  home="$(getent passwd "$user" | cut -d: -f6)"
  if [[ -z "$home" ]]; then
    warn "Could not determine home directory for $user; skipping rotation lock shortcut."
    return 0
  fi

  info "Configuring rotation lock shortcut for $user: $SURFACE_ROTATION_LOCK_BINDING"
  if ! gnome_key_exists "$user" "$media_schema" custom-keybindings; then
    warn "GNOME media-key settings unavailable; skipping rotation lock shortcut."
    return 0
  fi
  current_shortcuts="$(run_gsettings_for_desktop_user "$user" get "$media_schema" custom-keybindings)" || {
    record_failure "read GNOME custom keybindings"
    return
  }

  if [[ $current_shortcuts != *"'${shortcut_path}'"* && $current_shortcuts != *"\"${shortcut_path}\""* ]]; then
    if [[ $current_shortcuts == "[]" || $current_shortcuts == "@as []" ]]; then
      updated_shortcuts="['${shortcut_path}']"
    else
      updated_shortcuts="${current_shortcuts%]}"
      updated_shortcuts="${updated_shortcuts}, '${shortcut_path}']"
    fi

    run_gsettings_for_desktop_user "$user" set "$media_schema" custom-keybindings "$updated_shortcuts" || {
      record_failure "register rotation lock shortcut"
      return
    }
  fi

  command="${home}/.local/bin/surface-toggle-rotation-lock"
  run_gsettings_for_desktop_user "$user" set "${shortcut_schema}:${shortcut_path}" name "$(gsettings_string "Toggle Rotation Lock")" \
    || record_failure "set rotation lock shortcut name"
  run_gsettings_for_desktop_user "$user" set "${shortcut_schema}:${shortcut_path}" command "$(gsettings_string "$command")" \
    || record_failure "set rotation lock shortcut command"
  run_gsettings_for_desktop_user "$user" set "${shortcut_schema}:${shortcut_path}" binding "$(gsettings_string "$SURFACE_ROTATION_LOCK_BINDING")" \
    || record_failure "set rotation lock shortcut binding"
}

secure_boot_enabled() {
  need_cmd mokutil && mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'
}

surface_mok_enrolled() {
  as_root mokutil --test-key "$SURFACE_MOK_CERT" >/dev/null 2>&1
}

queue_surface_mok_enrollment() {
  local hashfile

  if ! secure_boot_enabled; then
    return 0
  fi

  if [[ ! -r "$SURFACE_MOK_CERT" ]]; then
    warn "Secure Boot is enabled, but the linux-surface MOK certificate was not found: $SURFACE_MOK_CERT"
    return 1
  fi

  if surface_mok_enrolled; then
    ok "linux-surface Secure Boot MOK is already enrolled"
    return 0
  fi

  info "Queueing linux-surface Secure Boot MOK enrollment"
  hashfile="$(mktemp)"
  if ! mokutil --generate-hash=surface >"$hashfile"; then
    rm -f "$hashfile"
    return 1
  fi
  if as_root mokutil --hash-file "$hashfile" --import "$SURFACE_MOK_CERT"; then
    rm -f "$hashfile"
    warn "On next boot, enroll the linux-surface MOK key when prompted; password: surface"
    return 0
  fi

  rm -f "$hashfile"
  warn "Run manually: sudo mokutil --import $SURFACE_MOK_CERT"
  warn "Then reboot and enroll the key when prompted; password: surface"
  return 1
}

write_surface_grub_defaults() {
  local file=${1:-/etc/default/grub.d/99-surface-pro-9.cfg}
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<'GRUB'
# Managed by install-surface-pro-9.sh. Preserve the distribution/user command line.
for surface_parameter in i915.enable_psr=0 pci=hpiosize=0; do
  case " ${GRUB_CMDLINE_LINUX_DEFAULT:-} " in
    *" $surface_parameter "*) ;;
    *) GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+$GRUB_CMDLINE_LINUX_DEFAULT }$surface_parameter" ;;
  esac
done
unset surface_parameter
GRUB_DEFAULT=saved
GRUB
  if ! as_root install -d -m 0755 "$(dirname "$file")" \
    || ! as_root install -m 0644 "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

latest_installed_surface_kernel() {
  as_root find /boot -maxdepth 1 -type f -name 'vmlinuz-*-surface*' -printf '%f\n' 2>/dev/null \
    | sed 's/^vmlinuz-//' \
    | sort -V \
    | tail -n 1
}

grub_menuentry_for_kernel() {
  local kernel=$1
  local grub_cfg=${2:-/boot/grub/grub.cfg}

  if ! as_root test -r "$grub_cfg"; then
    return 1
  fi

  # shellcheck disable=SC2016
  as_root awk -v kernel="$kernel" '
    /^submenu / {
      if (match($0, /'\''[^'\'']+'\''/)) {
        submenu = substr($0, RSTART + 1, RLENGTH - 2)
      }
    }
    /^[[:space:]]*menuentry / && index($0, "with Linux " kernel) {
      if (match($0, /'\''[^'\'']+'\''/)) {
        entry = substr($0, RSTART + 1, RLENGTH - 2)
        if (submenu != "") {
          print submenu ">" entry
        } else {
          print entry
        }
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  ' "$grub_cfg"
}

prefer_surface_kernel_in_grub() {
  local kernel
  local menuentry

  kernel="$(latest_installed_surface_kernel)"
  if [[ -z "$kernel" ]]; then
    warn "No installed linux-surface kernel found in /boot; leaving GRUB default unchanged."
    return 0
  fi

  info "Setting GRUB default to linux-surface kernel: $kernel"

  if need_cmd grub-set-default; then
    if menuentry="$(grub_menuentry_for_kernel "$kernel")"; then
      as_root grub-set-default "$menuentry" || return 1
    else
      warn "Could not find linux-surface kernel menu entry in /boot/grub/grub.cfg."
      warn "Select the linux-surface kernel manually from GRUB Advanced options after reboot."
    fi
  else
    warn "grub-set-default unavailable; select the linux-surface kernel manually from GRUB Advanced options."
  fi
}

configure_grub() {
  local defaults_file=${1:-/etc/default/grub}
  if ! need_cmd update-grub || [[ ! -f "$defaults_file" ]]; then
    warn "GRUB is not configured; configure your bootloader for the Surface kernel manually."
    warn "Surface Pro 9 kernel parameters: i915.enable_psr=0 pci=hpiosize=0"
    return 0
  fi

  info "Adding Surface Pro 9 kernel parameters in /etc/default/grub.d/99-surface-pro-9.cfg"
  write_surface_grub_defaults /etc/default/grub.d/99-surface-pro-9.cfg || { record_failure "write Surface GRUB defaults"; return; }
  # Generate the menu before looking up the newly installed kernel's entry.
  as_root update-grub || { record_failure "update GRUB"; return; }
  prefer_surface_kernel_in_grub || record_failure "set linux-surface kernel as GRUB default"
}

configure_iptsd_calibration() {
  info "Writing Surface Pro 9 touchscreen calibration"
  as_root install -d -m 0755 /etc/iptsd.d
  cat <<'CALIBRATION' | as_root tee /etc/iptsd.d/91-surface-pro-9-calibration.conf >/dev/null
[Contacts]
ActivationThreshold = 24
DeactivationThreshold = 20
OrientationThresholdMax = 5
CALIBRATION
}

configure_initramfs_modules() {
  local file="/etc/initramfs-tools/modules"
  local module
  local modules_string

  if need_cmd update-initramfs; then
    info "Ensuring Surface input modules are available in initramfs"
    as_root touch "$file"
    for module in "${SURFACE_INITRAMFS_MODULES[@]}"; do
      if ! grep -Fqx "$module" "$file"; then
        printf '%s\n' "$module" | as_root tee -a "$file" >/dev/null
      fi
    done

    as_root update-initramfs -u -k all || record_failure "update initramfs"
  elif need_cmd dracut; then
    info "Ensuring Surface input modules are available in dracut"
    as_root install -d -m 0755 /etc/dracut.conf.d
    modules_string="${SURFACE_INITRAMFS_MODULES[*]}"
    printf 'add_drivers+=" %s "\nforce_drivers+=" pinctrl_tigerlake "\n' "$modules_string" \
      | as_root tee /etc/dracut.conf.d/surface_pro_9_input.conf >/dev/null

    as_root dracut -f --regenerate-all || record_failure "regenerate dracut initramfs"
  else
    record_failure "No update-initramfs or dracut command found; rebuild the initramfs with Surface input drivers manually."
  fi
}

print_failure_summary() {
  if ((${#FAILURES[@]} == 0)); then
    return 0
  fi

  printf '\nFAILED SURFACE PRO 9 ITEMS:\n' >&2
  local item
  for item in "${FAILURES[@]}"; do
    printf '  - %s\n' "$item" >&2
  done
  return 1
}

main() {
  detect_distribution /etc/os-release || exit 1
  if ! need_cmd apt-get || ! need_cmd apt-cache || ! need_cmd dpkg; then
    error "This script expects apt-get and is intended for Debian/Ubuntu-based systems."
    exit 1
  fi

  if ! is_amd64; then
    error "Surface Pro 9 Intel linux-surface packages require amd64."
    exit 1
  fi

  if ! is_surface_pro_9; then
    if [[ "$SURFACE_ALLOW_UNSUPPORTED" == "1" ]]; then
      warn "This machine does not identify itself as a Surface Pro 9. Continuing because SURFACE_ALLOW_UNSUPPORTED=1."
    else
      error "This machine does not identify itself as a Surface Pro 9."
      error "Set SURFACE_ALLOW_UNSUPPORTED=1 to run anyway."
      exit 1
    fi
  fi

  if ! need_cmd systemctl || [[ ! -d /run/systemd/system ]]; then
    error "Run this installer on the booted system with systemd (not in a container/chroot)."
    exit 1
  fi
  if [[ "$EUID" -ne 0 ]]; then
    if ! need_cmd sudo; then
      error "sudo is not installed. Use su - to become root, then run this script with SURFACE_DESKTOP_USER set."
      exit 1
    fi
    sudo -v
  fi
  if [[ -n "$SURFACE_DESKTOP_USER" ]] && { [[ "$SURFACE_DESKTOP_USER" == root ]] || ! id "$SURFACE_DESKTOP_USER" >/dev/null 2>&1; }; then
    error "SURFACE_DESKTOP_USER must name an existing non-root account."
    exit 1
  fi

  install_prerequisites
  install_linux_surface_repository
  install_firmware
  install_packages
  print_failure_summary || exit 1
  queue_surface_mok_enrollment || record_failure "queue linux-surface Secure Boot MOK enrollment"
  configure_services
  configure_gnome_tablet_settings
  install_surface_auto_rotate
  install_rotation_lock_toggle
  configure_rotation_lock_shortcut
  configure_grub /etc/default/grub
  configure_iptsd_calibration
  configure_initramfs_modules

  if ! print_failure_summary; then
    exit 1
  fi

  ok "Surface Pro 9 support installed"
  printf 'Reboot now. If Secure Boot is enabled, enroll the linux-surface MOK key when prompted; the password is: surface\n'
  printf 'After reboot, verify the kernel with: uname -a\n'
  printf 'The running kernel should contain the string: surface\n'
  printf 'For touchscreen, verify iptsd after reboot with: systemctl status "iptsd*"\n'
  printf 'For auto-rotation, verify sensors after reboot with: monitor-sensor\n'
  printf 'For the on-screen keyboard, verify GNOME Settings > Accessibility > Screen Keyboard is enabled.\n'
  printf 'Maliit Keyboard is installed when available for post-login experimentation; GDM still uses GNOME Shell keyboard.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
