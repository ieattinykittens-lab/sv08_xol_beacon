#!/bin/sh
# POSIX-safe: dash compatible
set -eu

# =========================
# Helper: privilege + apt utils
# =========================
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "This script needs root privileges for apt. Install sudo or run as root." >&2
    exit 1
  fi
fi
export DEBIAN_FRONTEND=noninteractive

need_apt_update=0
MISSING_PKGS=""

is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}
want_pkg() {
  p="$1"
  if is_installed "$p"; then
    echo "$p is already installed."
  else
    echo "$p is missing; will install."
    MISSING_PKGS="$MISSING_PKGS $p"
    need_apt_update=1
  fi
}

# =========================
# PRE-REQS: numpy + timelapse install
# =========================
echo "Checking required Debian packages..."
want_pkg "python3-numpy"
want_pkg "python3-matplotlib"
want_pkg "libatlas-base-dev"
want_pkg "libopenblas-dev"

if [ "$need_apt_update" -eq 1 ]; then
  echo "Updating apt cache and installing missing packages:$MISSING_PKGS"
  $SUDO apt-get -yq update
  # shellcheck disable=SC2086
  $SUDO apt-get -yq install $MISSING_PKGS
else
  echo "All required packages are already installed."
fi

echo "Installing numpy into ~/klippy-env (if not already present)..."
if [ -x "$HOME/klippy-env/bin/pip" ]; then
  if "$HOME/klippy-env/bin/pip" show numpy >/dev/null 2>&1; then
    echo "numpy already present in ~/klippy-env."
  else
    "$HOME/klippy-env/bin/pip" install -v numpy || echo "Warning: pip install numpy failed in ~/klippy-env" >&2
  fi
else
  echo "Note: ~/klippy-env/bin/pip not found; skipping venv numpy install."
fi

echo "Installing moonraker-timelapse..."
cd "$HOME"
if [ ! -d "$HOME/moonraker-timelapse/.git" ]; then
  git clone https://github.com/mainsail-crew/moonraker-timelapse.git
else
  echo "moonraker-timelapse repo already exists; skipping clone."
fi
if [ -d "$HOME/moonraker-timelapse" ]; then
  cd "$HOME/moonraker-timelapse"
  if command -v make >/dev/null 2>&1; then
    printf 'Y\n' | make install || echo "Warning: 'make install' for moonraker-timelapse failed." >&2
  else
    echo "Warning: 'make' not found; cannot run 'make install' for moonraker-timelapse." >&2
  fi
fi

# =========================
# Timelapse config blocks in moonraker.conf (idempotent)
# =========================
MOONRAKER_CONF="$HOME/printer_data/config/moonraker.conf"
mkdir -p "$(dirname "$MOONRAKER_CONF")"
[ -f "$MOONRAKER_CONF" ] || : > "$MOONRAKER_CONF"
cp -p "$MOONRAKER_CONF" "$MOONRAKER_CONF.$(date +%Y%m%d%H%M%S).bak"

append_if_missing_moonraker() {
  sect="$1"  # e.g., "update_manager timelapse" or "timelapse"
  label="$2"
  if grep -E "^[[:space:]]*\\[$sect\\][[:space:]]*(#.*)?$" "$MOONRAKER_CONF" >/dev/null 2>&1; then
    echo "moonraker.conf already has [$sect]; skipping append."
    return 0
  fi
  if [ -s "$MOONRAKER_CONF" ]; then
    tail -c1 "$MOONRAKER_CONF" 2>/dev/null | od -An -t x1 | grep -q . && printf '\n' >> "$MOONRAKER_CONF" || true
  fi
  case "$label" in
    TIMELAPSE_UPDATE_MANAGER)
      cat >> "$MOONRAKER_CONF" <<'EOF'
# --- BEGIN: timelapse update_manager (added by script) ---
[update_manager timelapse]
type: git_repo
primary_branch: main
path: ~/moonraker-timelapse
origin: https://github.com/mainsail-crew/moonraker-timelapse.git
managed_services: klipper moonraker
# --- END: timelapse update_manager ---
EOF
      ;;
    TIMELAPSE_SECTION)
      cat >> "$MOONRAKER_CONF" <<'EOF'
# --- BEGIN: timelapse (added by script) ---
[timelapse]
##   Following basic configuration is default to most images and don't need
##   to be changed in most scenarios. Only uncomment and change it if your
##   Image differ from standart installations. In most common scenarios 
##   a User only need [timelapse] in their configuration.
output_path: ~/timelapse/                ##   Directory where the generated video will be saved
frame_path: /tmp/timelapse/              ##   Directory where the temporary frames are saved
ffmpeg_binary_path: /usr/bin/ffmpeg      ##   Directory where ffmpeg is installed
# --- END: timelapse ---
EOF
      ;;
  esac
  echo "Appended [$sect] to moonraker.conf"
}
append_if_missing_moonraker "update_manager timelapse" "TIMELAPSE_UPDATE_MANAGER"
append_if_missing_moonraker "timelapse" "TIMELAPSE_SECTION"

# =========================
# NEW: Clone SV08 mainline repo and move configs
# =========================
GIT_ROOT="$HOME/git"
SV08_URL="https://github.com/Rappetor/Sovol-SV08-Mainline"
SV08_DIR="$GIT_ROOT/Sovol-SV08-Mainline"
SV08_CFG_SRC="$SV08_DIR/files-used/config"
PRINTER_CFG_DEST="$HOME/printer_data/config"

echo "Preparing Git workspace in $GIT_ROOT ..."
mkdir -p "$GIT_ROOT"

if [ ! -d "$SV08_DIR/.git" ]; then
  echo "Cloning SV08 mainline repo..."
  git clone "$SV08_URL" "$SV08_DIR"
else
  echo "SV08 mainline repo already exists; pulling latest..."
  (cd "$SV08_DIR" && git pull --rebase || true)
fi

echo "Moving SV08 config files into $PRINTER_CFG_DEST ..."
mkdir -p "$PRINTER_CFG_DEST"
if [ -d "$SV08_CFG_SRC" ]; then
  # Move each item, backing up destination if it exists
  for f in "$SV08_CFG_SRC"/* 2>/dev/null; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    dest="$PRINTER_CFG_DEST/$base"
    if [ -e "$dest" ]; then
      ts=$(date +%Y%m%d%H%M%S)
      echo "Destination $dest exists; backing up to $dest.bak.$ts"
      mv "$dest" "$dest.bak.$ts"
    fi
    mv "$f" "$dest"
    echo "Moved: $f -> $dest"
  done
else
  echo "Source config dir not found: $SV08_CFG_SRC (skipping move)"
fi

# =========================
# Move old probe configs (POSIX list, no bash arrays)
# =========================
DEST="$HOME/misc/old_config"
mkdir -p "$DEST"

FILES_TO_MOVE="
$HOME/printer_data/config/options/probe/eddy.cfg
$HOME/printer_data/config/options/probe/stock.cfg
"

for src in $FILES_TO_MOVE; do
  if [ -e "$src" ]; then
    base=$(basename "$src")
    dest="$DEST/$base"
    if [ -e "$dest" ]; then
      ts=$(date +%Y%m%d%H%M%S)
      dest="$dest.bak.$ts"
      echo "Destination exists; saving as: $dest"
    fi
    mv "$src" "$dest"
    echo "Moved: $src -> $dest"
  else
    echo "Not found (skip): $src"
  fi
done

# =========================
# Beacon install/config
# =========================
REPO_DIR="$HOME/beacon_klipper"
BEACON_CFG="$HOME/printer_data/config/options/probe/beacon.cfg"
PRINTER_CFG_ALL="$HOME/printer_data/config/printer.cfg"

repo_exists=false
[ -d "$REPO_DIR" ] && repo_exists=true

has_beacon_update_manager=false
if grep -E '^[[:space:]]*\[update_manager[[:space:]]+beacon\][[:space:]]*$' "$MOONRAKER_CONF" >/dev/null 2>&1; then
  has_beacon_update_manager=true
fi

cfg_exists=false
[ -f "$BEACON_CFG" ] && cfg_exists=true

printf '%s\n' \
  "Check 1: repo dir exists?          -> $repo_exists ($REPO_DIR)" \
  "Check 2: moonraker has section?    -> $has_beacon_update_manager ($MOONRAKER_CONF)" \
  "Check 3: beacon.cfg exists?        -> $cfg_exists ($BEACON_CFG)"

if [ "$repo_exists" = false ]; then
  echo "Beacon repo not found. Installing Beacon…"
  if ! command -v git >/dev/null 2>&1; then
    echo "Error: 'git' is not installed or not in PATH. Install git and re-run." >&2
    exit 1
  fi
  cd "$HOME"
  git clone https://github.com/beacon3d/beacon_klipper.git
  sh ./beacon_klipper/install.sh || ./beacon_klipper/install.sh
  echo "Beacon install script executed."
else
  echo "Beacon repo already exists; skipping install."
fi

if [ "$has_beacon_update_manager" = false ]; then
  echo "Adding [update_manager beacon] block to $MOONRAKER_CONF …"
  if [ -s "$MOONRAKER_CONF" ]; then
    tail -c1 "$MOONRAKER_CONF" 2>/dev/null | od -An -t x1 | grep -q . && printf '\n' >> "$MOONRAKER_CONF" || true
  fi
  cat >> "$MOONRAKER_CONF" <<'EOF'

# --- BEGIN: Beacon update_manager (added by script) ---
[update_manager beacon]
type: git_repo
channel: dev
path: ~/beacon_klipper
origin: https://github.com/beacon3d/beacon_klipper.git
env: ~/klippy-env/bin/python
requirements: requirements.txt
install_script: install.sh
is_system_service: False
managed_services: klipper
info_tags:
  desc=Beacon Surface Scanner
# --- END: Beacon update_manager ---
EOF
  echo "Appended Beacon update_manager to moonraker.conf"
fi

if [ "$cfg_exists" = false ]; then
  echo "Creating $BEACON_CFG …"
  mkdir -p "$(dirname "$BEACON_CFG")"
  cat > "$BEACON_CFG" <<'EOF'
[beacon]
serial: /dev/serial/by-id/usb-Beacon_Beacon_RevD_<..addyourserial..>-if00
x_offset: -20 # update with offset from nozzle on your machine
y_offset: 0   # update with offset from nozzle on your machine
mesh_main_direction: x
mesh_runs: 2
EOF
  echo "Wrote base Beacon probe config to $BEACON_CFG"
fi

ensure_beacon_cfg_section() {
  section="$1"
  label="$2"
  if grep -E "^[[:space:]]*\\[$section\\][[:space:]]*(#.*)?$" "$BEACON_CFG" >/dev/null 2>&1; then
    echo "beacon.cfg already has [$section]; skipping."
    return 0
  fi
  if [ -s "$BEACON_CFG" ]; then
    tail -c1 "$BEACON_CFG" 2>/dev/null | od -An -t x1 | grep -q . && printf '\n' >> "$BEACON_CFG" || true
  fi
  case "$label" in
    RESONANCE_TESTER)
      cat >> "$BEACON_CFG" <<'EOF'
# --- BEGIN: resonance_tester (added by script) ---
[resonance_tester]
accel_chip: beacon
probe_points: 90, 90, 20
# --- END: resonance_tester ---
EOF
      ;;
    BED_MESH)
      cat >> "$BEACON_CFG" <<'EOF'
# --- BEGIN: bed_mesh (added by script) ---
[bed_mesh]
speed: 500
zero_reference_position: 175,175
horizontal_move_z: 2.0
mesh_min: 40, 40
mesh_max: 319, 339
probe_count: 99, 99
algorithm: bicubic
# --- END: bed_mesh ---
EOF
      ;;
    QGL)
      cat >> "$BEACON_CFG" <<'EOF'
# --- BEGIN: quad_gantry_level (added by script) ---
[quad_gantry_level]
gantry_corners:
        -60, -10
        410, 420
points:
        50, 50
        50, 311
        309, 311
        309, 50
speed: 500
horizontal_move_z: 10
retry_tolerance: 0.01
retries: 10
max_adjust: 10
# --- END: quad_gantry_level ---
EOF
      ;;
    SAFE_Z_HOME)
      cat >> "$BEACON_CFG" <<'EOF'
# --- BEGIN: safe_z_home (added by script) ---
[safe_z_home]
home_xy_position: 175, 175
z_hop: 3
# --- END: safe_z_home ---
EOF
      ;;
  esac
  echo "Appended [$section] to beacon.cfg"
}
ensure_beacon_cfg_section "resonance_tester" "RESONANCE_TESTER"
ensure_beacon_cfg_section "bed_mesh" "BED_MESH"
ensure_beacon_cfg_section "quad_gantry_level" "QGL"
ensure_beacon_cfg_section "safe_z_home" "SAFE_Z_HOME"

# =========================
# PRINTER.CFG [stepper_z] fix-up (robust header match incl. trailing comments)
# =========================
PRINTER_CFG="$HOME/printer_data/config/printer.cfg"
mkdir -p "$(dirname "$PRINTER_CFG")"
[ -f "$PRINTER_CFG" ] || : > "$PRINTER_CFG"
cp -p "$PRINTER_CFG" "$PRINTER_CFG.$(date +%Y%m%d%H%M%S).bak"

if ! grep -E '^[[:space:]]*\[stepper_z\][[:space:]]*(#.*)?$' "$PRINTER_CFG" >/dev/null 2>&1; then
  echo "No [stepper_z] section found; appending minimal section."
  if [ -s "$PRINTER_CFG" ]; then
    tail -c1 "$PRINTER_CFG" 2>/dev/null | od -An -t x1 | grep -q . && printf '\n' >> "$PRINTER_CFG" || true
  fi
  cat >> "$PRINTER_CFG" <<'EOF'
# --- BEGIN: stepper_z (added by script) ---
[stepper_z]
endstop_pin: probe:z_virtual_endstop #
homing_retract_dist: 0
# --- END: stepper_z ---
EOF
else
  echo "Updating existing [stepper_z] block..."
  tmpf="$(mktemp)"
  awk '
    BEGIN { inblock=0; seen_end=0; seen_ret=0 }
    function print_desired_end(){ print "endstop_pin: probe:z_virtual_endstop #" }
    function print_desired_ret(){ print "homing_retract_dist: 0" }

    /^[[:space:]]*\[stepper_z\][[:space:]]*(#.*)?$/ {
      inblock=1; seen_end=0; seen_ret=0
      print $0
      next
    }

    {
      if (inblock==1) {
        if ($0 ~ /^[[:space:]]*\[/) {
          if (seen_end==0) print_desired_end()
          if (seen_ret==0) print_desired_ret()
          inblock=0
          print $0
          next
        }
        if ($0 ~ /^[[:space:]]*endstop_pin[[:space:]]*:/) {
          if (seen_end==0) { print_desired_end(); seen_end=1 }
          next
        }
        if ($0 ~ /^[[:space:]]*homing_retract_dist[[:space:]]*:/) {
          if (seen_ret==0) { print_desired_ret(); seen_ret=1 }
          next
        }
        print $0
        next
      }
      print $0
    }

    END {
      if (inblock==1) {
        if (seen_end==0) print_desired_end()
        if (seen_ret==0) print_desired_ret()
      }
    }
  ' "$PRINTER_CFG" > "$tmpf"
  mv "$tmpf" "$PRINTER_CFG"
fi

# Install better macros
cd ~
git clone https://github.com/ss1gohan13/SV08-Replacement-Macros.git
cd SV08-Replacement-Macros
./install-macros.sh

# Install klippain shaketune
wget -O - https://raw.githubusercontent.com/Frix-x/klippain-shaketune/main/install.sh | bash

echo "All done."

