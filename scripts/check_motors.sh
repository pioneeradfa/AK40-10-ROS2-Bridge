#!/bin/bash
# check_motors.sh — identify WHICH CAN ID is the left / right wheel, and verify
# forward + backward rotation of EACH motor individually, without ROS.
#
# Spins one motor at a time over raw CAN with a gentle ramp
# (motor ω* ±2 → ±4 → ±5 rad/s = wheel ±0.5 rad/s through the 10:1 gear).
# The ramp keeps torque demand kd×Δω ≈ 1 N·m — far below the AK40-10 peak
# (1.9 N·m), so drive protection never trips (no jerk / LED-off).
#
# After each spin the script asks which wheel turned and which way, then prints
# the exact config/diff_drive_params.yaml lines:
#   motor_id_left / motor_id_right / invert_left / invert_right
#
# Usage:  ./scripts/check_motors.sh          # IDs from config (default 1 and 6)
#         ./scripts/check_motors.sh 1 6      # or give the two IDs explicitly
#
# Run WITHOUT sudo. Refuses to run while a motor node is streaming.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$REPO/config/diff_drive_params.yaml"

# ── IDs to test: args win, else config file, else 1 / 6 ─────────────────────
idl=$(sed -n 's/^[[:space:]]*motor_id_left:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CFG" 2>/dev/null | head -1)
idr=$(sed -n 's/^[[:space:]]*motor_id_right:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CFG" 2>/dev/null | head -1)
ID1="${1:-${idl:-1}}"
ID2="${2:-${idr:-6}}"

# ── CAN interface ───────────────────────────────────────────────────────────
if   ip link show can0   >/dev/null 2>&1; then IFACE=can0
elif ip link show slcan0 >/dev/null 2>&1; then IFACE=slcan0
elif ip link show can1   >/dev/null 2>&1; then IFACE=can1
else
  echo ">> No CAN interface - running setup_can_pi5.sh (will ask for sudo)..."
  sudo "$REPO/scripts/setup_can_pi5.sh" || exit 1
  if   ip link show can0   >/dev/null 2>&1; then IFACE=can0
  elif ip link show slcan0 >/dev/null 2>&1; then IFACE=slcan0
  else echo "ERROR: still no CAN interface." >&2; exit 1
  fi
fi

# ── refuse to fight a running node (both would stream MIT frames) ───────────
if pgrep -f "diff_drive.launch.py" >/dev/null 2>&1 || pgrep -f "ak_motor_cable_control" >/dev/null 2>&1; then
  echo "ERROR: a motor node is running - it would fight this test." >&2
  echo "       Stop it first: ./scripts/robot_down.sh   (or Ctrl+C in its terminal)" >&2
  exit 1
fi

cleanup() {
  cansend "$IFACE" "$(printf '%03X' "$ID1")#FFFFFFFFFFFFFFFD" 2>/dev/null
  cansend "$IFACE" "$(printf '%03X' "$ID2")#FFFFFFFFFFFFFFFD" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ── MIT frames: p_des=0, kp=0, kd=0.5, t_ff=0; only the velocity field varies ──
burst() { local i; for ((i = 0; i < $2; i++)); do cansend "$IFACE" "$1"; sleep "$3"; done; }

spin_fwd() {  # $1 = 3-hex-digit ID
  burst "${1}#7FFF8590001997FF" 6  0.1   # ω* +2 rad/s  (ramp step)
  burst "${1}#7FFF8B30001997FF" 6  0.1   # ω* +4 rad/s
  burst "${1}#7FFF8E00001997FF" 25 0.1   # ω* +5 rad/s  (~2.5 s hold)
  burst "${1}#7FFF7FF0001997FF" 5  0.1   # ω*  0        (stop)
}
spin_rev() {
  burst "${1}#7FFF7A50001997FF" 6  0.1   # ω* -2 rad/s
  burst "${1}#7FFF74B0001997FF" 6  0.1   # ω* -4 rad/s
  burst "${1}#7FFF71E0001997FF" 25 0.1   # ω* -5 rad/s  (~2.5 s hold)
  burst "${1}#7FFF7FF0001997FF" 5  0.1   # ω*  0        (stop)
}

ask() {  # prints the chosen option (1..5) on stdout; prompts on stderr
  local a
  while :; do
    read -r -p "  Which wheel turned, and which way?
    1) LEFT wheel rolled toward the robot FRONT   2) LEFT wheel rolled toward the robot BACK
    3) RIGHT wheel rolled toward the robot FRONT  4) RIGHT wheel rolled toward the robot BACK
    5) NOTHING turned
  Your answer [1-5]: " a
    case "$a" in
      1|2|3|4|5) echo "$a"; return ;;
      *) echo "  Please answer 1-5." >&2 ;;
    esac
  done
}

side_of() { case "$1" in 1|2) echo left ;; 3|4) echo right ;; *) echo none ;; esac; }
dir_of()  { case "$1" in 1|3) echo front ;; 2|4) echo rear ;; *) echo none ;; esac; }

test_motor() {  # $1 = decimal ID; sets RES_FWD / RES_REV
  local hex; hex=$(printf '%03X' "$1")
  echo
  echo "=================== MOTOR CAN ID $1 ==================="
  echo "Wheel will turn SLOWLY (0.5 rad/s ≈ 5 rpm). Watch BOTH wheels;"
  echo "lift the chassis off the ground if you can. 'FRONT' = the direction"
  echo "the robot should drive when 'drive.sh forward' works."
  cansend "$IFACE" "${hex}#FFFFFFFFFFFFFFFC"     # enter MIT (LED goes green)
  sleep 0.5
  read -r -p ">> [ID $1] Press Enter to spin POSITIVE (robot 'forward' command)..."
  spin_fwd "$hex"
  RES_FWD=$(ask)
  read -r -p ">> [ID $1] Press Enter to spin NEGATIVE (robot 'backward' command)..."
  spin_rev "$hex"
  RES_REV=$(ask)
  cansend "$IFACE" "${hex}#FFFFFFFFFFFFFFFD"     # exit MIT (LED off)
  echo ">> [ID $1] done - exited MIT mode."
}

echo "AK40-10 motor identification test"
echo ">> CAN interface: $IFACE   IDs to test: $ID1 and $ID2"

test_motor "$ID1"; F1=$RES_FWD; R1=$RES_REV
test_motor "$ID2"; F2=$RES_FWD; R2=$RES_REV

# ── evaluate ────────────────────────────────────────────────────────────────
S1=$(side_of "$F1"); D1=$(dir_of "$F1")
S2=$(side_of "$F2"); D2=$(dir_of "$F2")

echo
echo "==================== RESULTS ===================="
if [ "$S1" != none ]; then
  echo "ID $ID1: wheel on the $S1 side; positive cmd rolls it to the $D1, negative to the $(dir_of "$R1")."
  if [ "$(side_of "$R1")" != "$S1" ] || [ "$(dir_of "$R1")" = "$D1" ]; then
    echo "       note: the negative-spin answer does not mirror the positive one - repeat if unsure."
  fi
else
  echo "ID $ID1: NOTHING turned - no ACK on this ID: check 24 V power, CAN H/L,"
  echo "         termination, and the ID itself (try others: $0 2 3)."
fi
if [ "$S2" != none ]; then
  echo "ID $ID2: wheel on the $S2 side; positive cmd rolls it to the $D2, negative to the $(dir_of "$R2")."
  if [ "$(side_of "$R2")" != "$S2" ] || [ "$(dir_of "$R2")" = "$D2" ]; then
    echo "       note: the negative-spin answer does not mirror the positive one - repeat if unsure."
  fi
else
  echo "ID $ID2: NOTHING turned - no ACK on this ID: check 24 V power, CAN H/L,"
  echo "         termination, and the ID itself (try others: $0 3 2)."
fi

if [ "$S1" != none ] && [ "$S2" != none ] && [ "$S1" != "$S2" ]; then
  if [ "$S1" = left ]; then
    LID=$ID1; RID=$ID2
    [ "$D1" = rear ] && LINV=true || LINV=false
    [ "$D2" = rear ] && RINV=true || RINV=false
  else
    LID=$ID2; RID=$ID1
    [ "$D2" = rear ] && LINV=true || LINV=false
    [ "$D1" = rear ] && RINV=true || RINV=false
  fi
  cat <<EOF

Put these lines in config/diff_drive_params.yaml:

    motor_id_left: $LID
    motor_id_right: $RID
    invert_left: $LINV
    invert_right: $RINV

(invert: true = that wheel rolled toward the BACK on a positive command,
 i.e. the motor is mounted mirrored.)

Then apply and verify the whole robot:

    colcon build --packages-select ak_motor_driver
    ./scripts/robot_up.sh
    ./scripts/drive.sh forward     # BOTH wheels must now roll toward the FRONT
    ./scripts/drive.sh stop
    ./scripts/robot_down.sh
EOF
elif [ "$S1" != none ] && [ "$S1" = "$S2" ]; then
  echo
  echo "WARNING: both IDs reported the SAME ($S1) wheel - watch more carefully and repeat:"
  echo "         $0 $ID1 $ID2"
else
  echo
  echo "Once BOTH IDs turn their own wheel, repeat this test to get the config lines."
fi
