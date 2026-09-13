#!/usr/bin/env bash
#
# bc250-monitoring — AMD BC-250 hardware monitoring setup
# (Nuvoton NCT6686D Super I/O: temps, voltages, fan RPM, PWM control)
#
# Distro support:
#   - Arch / Omarchy / EndeavourOS / CachyOS  (pacman)
#   - Debian / Ubuntu                          (apt)
#   - Fedora                                   (dnf)
#   - SteamOS                                  (immutable: manual build + insmod)
#   - anything else                            (manual steps printed, no changes made)
#
# Idempotent: safe to re-run.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="${SCRIPT_DIR}/50-nct6687-labels.patch"
REPO_URL="https://github.com/Fred78290/nct6687d.git"
DKMS_NAME="nct6687d"
DKMS_VERSION="1"
KERNEL="$(uname -r)"
KERNEL_BUILD_DIR="/usr/lib/modules/${KERNEL}/build"

if [ "$(id -u)" = 0 ]; then SUDO=""; else SUDO="sudo"; fi
PKG_MGR="unknown"
DISTRO_ID=""
DISTRO_LIKE=""
BC250_BUILD_DIR=""

step() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

# ---------------------------------------------------------------- detect
detect_distro() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-}"
        DISTRO_LIKE="${ID_LIKE:-}"
    fi
    case "${DISTRO_ID}/${DISTRO_LIKE}" in
        *steamos*)          PKG_MGR="steamos" ;;
        *omarchy*|*cachyos*|*endeavour*|*arch*) PKG_MGR="pacman" ;;
        *debian*|*ubuntu*)  PKG_MGR="apt" ;;
        *fedora*|*rhel*|*centos*|*rocky*|*almalinux*|*nobara*) PKG_MGR="dnf" ;;
        *)                  PKG_MGR="unknown" ;;
    esac
}

# For Arch-like systems, return the headers package matching the RUNNING kernel.
arch_headers_pkg() {
    if [ -d "$KERNEL_BUILD_DIR" ]; then
        echo ""; return
    fi
    local pkgbase=""
    pkgbase="$(cat "/usr/lib/modules/${KERNEL}/pkgbase" 2>/dev/null || true)"
    if [ -n "$pkgbase" ]; then
        echo "${pkgbase}-headers"; return
    fi
    case "$DISTRO_ID" in
        *cachyos*) echo "linux-cachyos-headers" ;;
        *)         echo "linux-headers" ;;
    esac
}

# -------------------------------------------------------------- prereqs
install_prereqs() {
    case "$PKG_MGR" in
        pacman)
            "$SUDO" pacman -S --needed --noconfirm \
                base-devel git dkms lm_sensors nvtop
            local hdr=""
            hdr="$(arch_headers_pkg)"
            if [ -n "$hdr" ]; then
                step "Installing kernel headers for $KERNEL ($hdr)"
                "$SUDO" pacman -S --needed --noconfirm "$hdr"
            fi
            ;;
        apt)
            "$SUDO" apt-get update
            "$SUDO" apt-get install -y build-essential git dkms lm-sensors \
                nvtop "linux-headers-$(uname -r)"
            ;;
        dnf)
            "$SUDO" dnf install -y git gcc make kernel-headers kernel-devel \
                dkms lm_sensors nvtop
            ;;
        steamos|unknown)
            : # immutable / unsupported: no package install
            ;;
    esac
}

# ------------------------------------------------- build via DKMS
install_via_dkms() {
    BC250_BUILD_DIR="$(mktemp -d)"
    trap 'rm -rf "${BC250_BUILD_DIR:-}"' EXIT

    step "Cloning nct6687d driver"
    git clone --depth 1 "$REPO_URL" "$BC250_BUILD_DIR"
    if ! git -C "$BC250_BUILD_DIR" apply --check "$PATCH" 2>/dev/null; then
        echo "Patch rejected — upstream driver changed. Re-generate" >&2
        echo "50-nct6687-labels.patch before re-running (see README)." >&2
        exit 1
    fi
    git -C "$BC250_BUILD_DIR" apply "$PATCH"

    step "Registering with DKMS (auto-rebuilds on kernel updates)"
    "$SUDO" dkms remove "$DKMS_NAME/$DKMS_VERSION" --all 2>/dev/null || true
    "$SUDO" rm -rf "/usr/src/${DKMS_NAME}-${DKMS_VERSION}"
    "$SUDO" dkms add "$BC250_BUILD_DIR"
    "$SUDO" dkms build "$DKMS_NAME/$DKMS_VERSION"
    "$SUDO" dkms install "$DKMS_NAME/$DKMS_VERSION" --force
}

# ------------------------------------------------- SteamOS (manual)
install_steamos_module() {
    local src="$HOME/.bc250/nct6687d"
    mkdir -p "$(dirname "$src")"

    step "Building nct6687 driver (SteamOS: manual, in $src)"
    if [ -d "$src/.git" ]; then
        git -C "$src" pull --ff-only || true
    else
        git clone --depth 1 "$REPO_URL" "$src"
    fi
    if ! git -C "$src" apply --check "$PATCH" 2>/dev/null; then
        echo "Patch rejected — upstream driver changed. Re-generate" >&2
        echo "50-nct6687-labels.patch (see README)." >&2
        exit 1
    fi
    git -C "$src" apply "$PATCH"
    make -C "$src"

    "$SUDO" insmod "$src/nct6687.ko" force=1

    cat > "$HOME/.bc250/reload-nct6687.sh" <<EOF
#!/usr/bin/env bash
# Rebuild + reload nct6687 after a SteamOS update (modules are wiped by updates).
set -euo pipefail
cd "\$HOME/.bc250/nct6687d"
git pull --ff-only || true
make -C "\$HOME/.bc250/nct6687d"
${SUDO:-sudo} insmod "\$HOME/.bc250/nct6687d/nct6687.ko" force=1
echo "nct6687 loaded. Run: sensors"
EOF
    chmod +x "$HOME/.bc250/reload-nct6687.sh"
}

# ---------------------------------------------------------- config
write_config() {
    step "Writing kernel module config"
    "$SUDO" tee /etc/modprobe.d/sensors.conf >/dev/null <<'EOF'
blacklist nct6683
options nct6687 force=true
EOF
    # SteamOS reruns /etc/modules-load.d at boot; harmless on others too.
    "$SUDO" tee /etc/modules-load.d/99-sensors.conf >/dev/null <<'EOF'
nct6687
EOF
    # Remove config from legacy nct6683-based setups
    "$SUDO" rm -f /etc/modprobe.d/nct6683.conf /etc/modules-load.d/nct6683.conf \
        /etc/modules-load.d/nct6683-bc250.conf

    if ! grep -q 'chip "nct6686-isa-\*"' /etc/sensors3.conf 2>/dev/null; then
        step "Adding sensor labels to /etc/sensors3.conf"
        "$SUDO" tee -a /etc/sensors3.conf >/dev/null <<'EOF'

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
}

# ---------------------------------------------------------- load
load_module() {
    step "Loading module"
    case "$PKG_MGR" in
        steamos)
            "$HOME/.bc250/reload-nct6687.sh"
            ;;
        *)
            "$SUDO" modprobe -r nct6683 2>/dev/null || true
            "$SUDO" modprobe nct6687 force=true
            ;;
    esac
}

# ---------------------------------------------------------- main
main() {
    detect_distro
    echo "Detected: ${DISTRO_ID:-?} (${DISTRO_LIKE:-no ID_LIKE})  ->  ${PKG_MGR}"

    if [ "$PKG_MGR" = "unknown" ]; then
        step "No supported package manager detected — no changes made"
        cat <<EOF
You can still use the driver; do it manually:

  1. install git, dkms and the kernel headers for: $KERNEL
  2.   tmp=\$(mktemp -d)
      git clone --depth 1 $REPO_URL "\$tmp"
      git -C "\$tmp" apply "$PATCH"
      sudo dkms add "\$tmp"
      sudo dkms build "$DKMS_NAME/$DKMS_VERSION"
      sudo dkms install "$DKMS_NAME/$DKMS_VERSION" --force
  3. rerun: sudo $0
     (or apply the /etc config from the README manually)
EOF
        exit 1
    fi

    step "Installing prerequisites"
    install_prereqs

    if [ "$PKG_MGR" = "steamos" ]; then
        install_steamos_module
    else
        install_via_dkms
    fi

    write_config
    load_module

    echo
    echo "Done."
    if command -v sensors >/dev/null 2>&1; then
        sensors
    else
        echo "lm-sensors not found in PATH; run 'sensors' once it is installed."
    fi
    if command -v nvtop >/dev/null 2>&1; then
        echo; echo "GPU monitoring (temps, power, clocks): nvtop"
    fi
}

main "$@"