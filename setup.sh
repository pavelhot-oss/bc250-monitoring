#!/usr/bin/env bash
#
# bc250-monitoring — AMD BC-250 hardware monitoring setup (Omarchy / Arch)
#
# What it does:
#   1. Installs prerequisites (lm_sensors, nvtop, linux-headers, dkms, ...)
#   2. Clones the out-of-tree nct6687d driver (full PWM + labeled sensors)
#      for the Nuvoton NCT6686D Super I/O chip, applies the label patch and
#      registers it with DKMS (so it auto-rebuilds on every kernel update)
#   3. Configures:
#        /etc/modprobe.d/sensors.conf      -> load nct6687 force=true, blacklist nct6683
#        /etc/modules-load.d/99-sensors.conf -> autoload on boot
#        /etc/sensors3.conf                -> friendly sensor labels
#   4. Loads the module immediately
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="${SCRIPT_DIR}/50-nct6687-labels.patch"
DKMS_NAME="nct6687d"
DKMS_VERSION="1"
REPO_URL="https://github.com/Fred78290/nct6687d.git"

step() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

step "Installing prerequisites"
sudo pacman -S --needed --noconfirm \
	git base-devel linux-headers dkms lm_sensors nvtop

step "Building nct6687d driver from source (with label patch)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
git clone --depth 1 "$REPO_URL" "$BUILD_DIR"
if ! git -C "$BUILD_DIR" apply --check "$PATCH" 2>/dev/null; then
	echo "Patch rejected. The upstream driver may have changed; re-generate" >&2
	echo "50-nct6687-labels.patch before re-running this script." >&2
	exit 1
fi
git -C "$BUILD_DIR" apply "$PATCH"

step "Registering with DKMS (auto-rebuilds on kernel updates)"
sudo dkms remove "$DKMS_NAME/$DKMS_VERSION" --all 2>/dev/null || true
rm -rf "/usr/src/${DKMS_NAME}-${DKMS_VERSION}"
sudo dkms add "$BUILD_DIR"
sudo dkms build "$DKMS_NAME/$DKMS_VERSION"
sudo dkms install "$DKMS_NAME/$DKMS_VERSION" --force

step "Writing kernel module config"
sudo tee /etc/modprobe.d/sensors.conf >/dev/null <<'EOF'
blacklist nct6683
options nct6687 force=true
EOF
sudo tee /etc/modules-load.d/99-sensors.conf >/dev/null <<'EOF'
nct6687
EOF
# Remove config from older nct6683-based setups
sudo rm -f /etc/modprobe.d/nct6683.conf /etc/modules-load.d/nct6683.conf \
	/etc/modules-load.d/nct6683-bc250.conf

step "Adding sensor labels to /etc/sensors3.conf (idempotent)"
if ! grep -q 'chip "nct6686-isa-\*"' /etc/sensors3.conf; then
	sudo tee -a /etc/sensors3.conf >/dev/null <<'EOF'

chip "nct6686-isa-*"
    label fan1 "Pump Fan"
    label fan2 "CPU Fan"
    label fan3 "System Fan #1"
    label fan4 "System Fan #2"
    label fan5 "System Fan #3"
    label fan6 "System Fan #4"
    label fan7 "System Fan #5"
    label fan8 "System Fan #6"
    label in1 "CPU VDDP"
EOF
fi

step "Loading module now"
sudo modprobe -r nct6683 2>/dev/null || true
sudo modprobe nct6687 force=true

echo
echo "Done. Verifying:"
sensors
echo
echo "GPU monitoring (temps, power, clocks): nvtop"