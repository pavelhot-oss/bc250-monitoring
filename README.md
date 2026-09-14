# bc250-monitoring

Hardware monitoring (temp / voltage / fan RPM) for the **AMD BC-250** board, with PWM fan control support.

## Background

The BC-250 exposes CPU temperature (`k10temp`), GPU temperature/power (`amdgpu`) and NVMe temps to Linux,
but **not** the motherboard sensors. Those live behind the board's **Nuvoton NCT6686D** Super I/O chip, which:

- is **not auto-detected** — it needs `force=true`,
- is served by two competing drivers:
  - `nct6683` (in-kernel, read-only),
  - **`nct6687`** (out-of-tree, [Fred78290/nct6687d](https://github.com/Fred78290/nct6687d)) — full read + PWM fan control, and nicer labels.

This repo installs `nct6687` so the module is rebuilt automatically whenever your
package manager updates the kernel, and applies a small patch that swaps the
`CPU Fan` / `Pump Fan` labels (the physically-connected fan on BC-250 reads on
the channel the driver calls `Pump Fan`).

## Supported distributions

| Distro | Method | Notes |
|---|---|---|
| Arch / Omarchy / EndeavourOS | pacman + DKMS | native |
| CachyOS | pacman + DKMS | headers pulled for the running `linux-cachyos` kernel |
| Debian / Ubuntu | apt + DKMS | `linux-headers-$(uname -r)` |
| Fedora / RHEL-likes | dnf + DKMS | `kernel-devel` |
| SteamOS | manual build + `insmod` | immutable OS, see troubleshooting |
| anything else | prints manual steps, no changes | |

## Usage

```sh
./setup.sh
```

`setup.sh` detects the distro, installs prerequisites, builds the driver from
source (applying the label patch), registers it with DKMS, writes the kernel
module config, and loads the module. Idempotent — safe to re-run, and the
natural thing to run after a reinstall.

## What it installs

| Piece | Details |
|---|---|
| `nct6687d` driver | built from source + label patch, DKMS-registered, `force=true` |
| `/etc/modprobe.d/sensors.conf` | `blacklist nct6683`, `options nct6687 force=true` |
| `/etc/modules-load.d/99-sensors.conf` | autoload `nct6687` at boot |
| `/etc/sensors3.conf` | friendly fan/voltage labels (appended if missing) |
| packages | `lm_sensors`, `nvtop`, `dkms`, build tools, kernel headers matching the running kernel |

## Verify

```sh
sensors          # temps, voltages, CPU/Pump fan RPM
nvtop            # GPU temp, power, clocks
```

## Files

- `setup.sh` — full reproducible setup
- `50-nct6687-labels.patch` — label swap for the driver (default + msi_alt fan configs)
- `fancurve/bc250-fancurve` — temperature-based fan controller (needs a 4-pin PWM fan)
- `fancurve/bc250-fancurve.service` — systemd unit for it

## Fan curve (optional)

For software fan control you need a **4-pin PWM fan** on the CPU header — a 3-pin fan ignores PWM
entirely (see gotchas). With one in place:

```sh
sudo install -Dm755 fancurve/bc250-fancurve /usr/local/bin/bc250-fancurve
sudo install -Dm644 fancurve/bc250-fancurve.service /etc/systemd/system/bc250-fancurve.service
sudo systemctl daemon-reload
sudo systemctl enable --now bc250-fancurve
```

Developed and validated with an **Arctic P12 Pro PWM** (120 mm, 4-pin) on a BC-250: PWM control is
effective across its whole range (pwm 12 ≈ 480 RPM … pwm 255 ≈ 3070 RPM), so the default curve
(pwm 45 ≈ 810 RPM floor) has ample headroom.

How it works:

- controls the PWM channel labeled `CPU Fan` (`fan2`/`pwm2`), detected dynamically — handles hwmon
  renumbering between boots,
- drives the fan from the **hottest of CPU die (`k10temp`) and GPU edge (`amdgpu`)**, since the APU
  shares one heatsink,
- interpolates linearly between curve points (default `45->50->55->60->65->70 °C` →
  `45->60->90->130->180->230 PWM`), capped at 255,
- rate-limits changes (fast ramps, slow coasts) so it never oscillates around a threshold,
- floor of `MIN_PWM=45` (~810 RPM on the stock fan) keeps a safety margin above stall.

Edit the `TEMPS`/`PWMS` arrays at the top of `bc250-fancurve` to tune. Stopping the service
(`systemctl stop bc250-fancurve`) hands control back to the firmware auto-curve.

```sh
# watch it react
watch -n2 'cat /sys/class/hwmon/hwmon*/pwm2 /sys/class/hwmon/hwmon*/fan2_input'
```

## Notes & gotchas

- **3-pin fans ignore PWM.** The board's 4-pin header sends PWM, but a 3-pin fan is powered
  straight from 12V and runs at a constant speed no matter what — BIOS "fan settings" do not
  actually control it either. For software fan control, fit a **4-pin PWM fan**; the nct6687
  driver then works out of the box (`/sys/class/hwmon/hwmon*/pwm*N`).
- **No ACPI EC, no SMBus Super-I/O.** The chip is on ISA (port `0x2e:0xa20`); that is why
  `ec_sys`, `acpi_call` and `i2cdetect` all come up empty — only `force=true` works.
- The driver taints the kernel (out-of-tree); expected.
- Motorboard VRM voltages may read 0.00 V — the BC-250 shares rails with the VRM/PMIC that
  are not all wired to the Super I/O chip. Voltages +3.3V, AVSB and VBat are the useful ones.

## Troubleshooting

### SteamOS / immutable distros
SteamOS is Arch-derived but runs a read-only `/usr`: regular packages aren't installed via
`pacman`, the OS is updated with `steamos-update`, and every update wipes any modules you built.
`setup.sh` detects SteamOS and instead:
1. clones+builds the driver to `~/.bc250/nct6687d` and `insmod`s it,
2. writes a `~/.bc250/reload-nct6687.sh` helper — run it after every SteamOS update
   to rebuild and re-insert the module. The `/etc` config (`force=true`, labels) persists.

### CachyOS
Uses the `linux-cachyos` kernel, so the headers package is `linux-cachyos-headers`, not
`linux-headers`. `setup.sh` reads `/usr/lib/modules/$(uname -r)/pkgbase` to pick the right
package automatically. If it can't, install the matching headers manually and re-run.

### Patch no longer applies
The upstream `nct6687d` repo occasionally shifts line numbers. Fix by regenerating the patch:

```sh
git clone --depth 1 https://github.com/Fred78290/nct6687d.git /tmp/upstream
$EDITOR /tmp/upstream/nct6687.c   # swap the "CPU Fan"/"Pump Fan" .label strings
git -C /tmp/upstream diff > 50-nct6687-labels.patch
```

### Nothing shows up after a kernel update (non-SteamOS)
DKMS should rebuild automatically via pacman/apt/dnf hooks. If it didn't:

```sh
sudo dkms autoinstall
sudo modprobe nct6687 force=true
```

### Fan speed sticks at a constant RPM
Your fan is likely 3-pin (see the gotcha above) — it ignores the PWM line entirely.

## Related projects

- [**BC-250 Telemetry**](https://github.com/onlinermm/BC250-Telemetry) — telemetry daemon +
  web dashboards (V, A, W, temps per VRM/PMIC rail via PMBus, plus CPU/GPU/NVMe/fan),
  MangoHud & CoolerControl integration. Its `install.sh` auto-installs the same `nct6687`
  driver + label fix this repo provides when it finds none active, and falls back to the
  read-only `nct6683` otherwise. Use it together with `bc250-fancurve` for fan control on
  top of its dashboards. It can also report GDDR6 memory temps — `sudo ./install.sh --memory-temp`
  patches the GPU SMU at boot (stock P3.0 BIOS; keep other SMU tools like
  `cyan-skillfish-governor-smu` stopped while it runs): all 8 chips, average and hotspot
  on the v2 dashboard.