"""Regression tests: system mutations are replaced by shell functions or temp files."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install-surface-pro-9.sh"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)

    def bash(self, script, success=True):
        env = os.environ.copy()
        env.update(NO_COLOR="1", SURFACE_DESKTOP_USER="", SUDO_USER="", TEST_TMP=str(self.path))
        result = subprocess.run(
            ["bash", "-c", 'source "$1"\n' + script, "test", str(INSTALLER)],
            text=True, capture_output=True, env=env,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_distribution_and_firmware_selection(self):
        for distro, version, split, expected in (
            ("debian", "12", False, "firmware-misc-nonfree"),
            ("debian", "13", True, "firmware-intel-graphics"),
            ("ubuntu", "24.04", False, "linux-firmware"),
        ):
            with self.subTest(distro=distro, version=version):
                (self.path / "os-release").write_text(f'ID={distro}\nVERSION_ID="{version}"\n')
                result = self.bash(f'''
detect_distribution "$TEST_TMP/os-release"
apt_package_exists() {{ {str(split).lower()}; }}
firmware_packages
''')
                self.assertIn(expected, result.stdout)
                self.assertIn("intel-microcode", result.stdout)
                if distro == "debian":
                    self.assertIn("firmware-iwlwifi", result.stdout)
                    self.assertIn("firmware-sof-signed", result.stdout)

    def test_unsupported_distribution_fails(self):
        for content in ("ID=fedora\n", 'ID=debian\nVERSION_ID="11"\n'):
            (self.path / "os-release").write_text(content)
            self.bash('detect_distribution "$TEST_TMP/os-release"', success=False)

    def test_arm_rejected_even_with_hardware_override(self):
        result = self.bash('''
detect_distribution() { :; }
dpkg() { printf 'arm64\n'; }
SURFACE_ALLOW_UNSUPPORTED=1
main
''', success=False)
        self.assertIn("require amd64", result.stderr)

    def test_package_requires_candidate(self):
        for candidate, available in (("(none)", False), ("1.2.3-1", True), ("", False)):
            (self.path / "policy").write_text(f"example:\n  Candidate: {candidate}\n" if candidate else "")
            self.bash('''
apt-cache() { cat "$TEST_TMP/policy"; }
apt_package_exists example
''', success=available)

    def test_missing_firmware_stops_before_install(self):
        result = self.bash('''
DISTRO_ID=debian
apt_package_exists() { return 1; }
apt_install() { touch "$TEST_TMP/install-called"; }
install_firmware
''', success=False)
        self.assertIn("non-free-firmware", result.stderr)
        self.assertFalse((self.path / "install-called").exists())

    def test_failed_key_download_preserves_repository(self):
        for filename in ("surface.gpg", "surface.list"):
            (self.path / filename).write_text("existing configuration")
        self.bash('''
SURFACE_APT_KEYRING="$TEST_TMP/surface.gpg"
SURFACE_APT_SOURCE="$TEST_TMP/surface.list"
curl() { return 22; }
install_linux_surface_repository
''', success=False)
        for filename in ("surface.gpg", "surface.list"):
            self.assertEqual((self.path / filename).read_text(), "existing configuration")

    def test_missing_static_masked_and_enabled_services(self):
        for load, state, action in (
            ("not-found", "", ""),
            ("loaded", "static", "start"),
            ("loaded", "enabled", "enable --now"),
            ("masked", "masked", ""),
        ):
            with self.subTest(load=load, state=state):
                result = self.bash(f'''
systemctl() {{
  case "$*" in
    *LoadState*) printf '%s\\n' '{load}' ;;
    *UnitFileState*) printf '%s\\n' '{state}' ;;
    *) printf 'ACTION %s\\n' "$*" ;;
  esac
}}
as_root() {{ "$@"; }}
enable_service_if_present example.service
''')
                if action:
                    self.assertIn(f"ACTION {action} example.service", result.stdout)
                else:
                    self.assertNotIn("ACTION", result.stdout)

    def test_iptsd_template_is_left_to_udev(self):
        result = self.bash('''
systemctl() {
  [[ "$*" == 'list-unit-files --no-legend iptsd@.service' ]] || return 1
  printf 'iptsd@.service static -\n'
}
enable_service_if_present() { printf 'ENABLE %s\n' "$1"; }
configure_services
''')
        self.assertIn("udev", result.stdout)
        self.assertNotIn("ENABLE iptsd", result.stdout)
        self.assertIn("ENABLE thermald.service", result.stdout)

    def test_empty_unit_listing_is_not_present(self):
        self.bash('''
systemctl() { return 0; }
service_unit_exists missing.service
''', success=False)

    def test_mok_error_is_not_enrolled(self):
        for status in (0, 1, 2):
            with self.subTest(status=status):
                self.bash(f'''
as_root() {{ "$@"; }}
mokutil() {{ printf 'arbitrary or localized output\\n'; return {status}; }}
surface_mok_enrolled
''', success=status == 0)

    def test_root_login_is_not_used_as_desktop_user(self):
        result = self.bash('''
logname() { printf 'root\n'; }
if [[ "$EUID" -eq 0 ]]; then desktop_user; fi
''')
        self.assertNotIn("root", result.stdout)

    def test_non_gnome_skips_rotation_helper(self):
        result = self.bash('''
gsettings() { return 1; }
install_surface_auto_rotate
''')
        self.assertIn("skipping", result.stderr)
        self.assertNotIn("Installing Surface auto-rotate", result.stdout)

    def test_grub_fragment_preserves_settings_and_is_idempotent(self):
        self.bash('''
as_root() { "$@"; }
write_surface_grub_defaults "$TEST_TMP/surface.cfg"
''')
        for existing in ("", "quiet splash", "quiet i915.enable_psr=0", "foo='two words'"):
            result = subprocess.run(
                ["sh", "-c", 'GRUB_CMDLINE_LINUX_DEFAULT=$1; . "$2"; . "$2"; printf "%s" "$GRUB_CMDLINE_LINUX_DEFAULT"',
                 "test", existing, str(self.path / "surface.cfg")],
                text=True, capture_output=True, check=True,
            )
            self.assertTrue(result.stdout.startswith(existing))
            self.assertEqual(result.stdout.count("i915.enable_psr=0"), 1)
            self.assertEqual(result.stdout.count("pci=hpiosize=0"), 1)

    def test_grub_menu_read_uses_root(self):
        (self.path / "grub.cfg").write_text("""
menuentry 'Debian GNU/Linux' {
}
submenu 'Advanced options for Debian GNU/Linux' {
    menuentry 'Debian GNU/Linux, with Linux 6.19.8-surface-3' {
    }
}
""")
        result = self.bash('''
as_root() { printf '%s\n' "$1" >>"$TEST_TMP/root-calls"; "$@"; }
grub_menuentry_for_kernel 6.19.8-surface-3 "$TEST_TMP/grub.cfg"
''')
        self.assertIn("Advanced options for Debian GNU/Linux>Debian GNU/Linux, with Linux 6.19.8-surface-3", result.stdout)
        self.assertEqual((self.path / "root-calls").read_text().splitlines(), ["test", "awk"])

    def test_grub_menu_is_generated_before_selecting_kernel(self):
        (self.path / "grub").touch()
        result = self.bash('''
need_cmd() { return 0; }
as_root() { "$@"; }
write_surface_grub_defaults() { printf 'STEP defaults\n'; }
update-grub() { printf 'STEP update\n'; }
prefer_surface_kernel_in_grub() { printf 'STEP select\n'; }
configure_grub "$TEST_TMP/grub"
''')
        self.assertEqual([line for line in result.stdout.splitlines() if line.startswith("STEP")],
                         ["STEP defaults", "STEP update", "STEP select"])

    def test_embedded_python_compiles(self):
        source = INSTALLER.read_text().split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        compile(source, "surface-auto-rotate", "exec")
        self.assertTrue(source.startswith("#!/usr/bin/python3\n"))


if __name__ == "__main__":
    unittest.main()
