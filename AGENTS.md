# Project instructions

This repository installs Surface Pro 9 support on Debian-family systems. It is
a Bash installer, not a Debian package. Debian 12 (bookworm) and Debian 13
(trixie), amd64, are the compatibility targets; preserve Ubuntu support.

- Never run the installer against the development host to test it: it installs
  kernels and changes boot configuration. Source its functions with mocked
  system commands for regression tests, or use disposable containers.
- Run `bash -n install-surface-pro-9.sh surface-toggle-rotation-lock.sh tests/debian-packages.sh`,
  `shellcheck install-surface-pro-9.sh surface-toggle-rotation-lock.sh tests/debian-packages.sh`,
  and `python3 -m unittest discover -s tests -v` after changing installer behavior.
- For package/source changes, run the Debian container matrix documented in
  README.md. `tests/debian-packages.sh` changes APT sources inside the container
  and simulates package installation; it does not validate hardware or booting.
- Keep helpers installed as independent copies outside the checkout. Preserve
  user configuration and the existing fallback kernel. Keep `--no-remove` on
  package installation, especially for optional `libwacom-surface` replacements.
- Document upstream hardware limitations and distinguish automated validation
  from a real Surface reboot test. No deployment step is needed; commit and push
  completed changes to this repository.
