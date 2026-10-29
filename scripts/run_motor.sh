#!/bin/bash
# One-command bring-up + run for the AK40-10 cable control node.
# Replaces the multi-terminal sequence: CAN setup -> launch -> publish -> enable.
# Ctrl+C (or the optional duration) always disables the motor before exiting.
#
# Usage:
#   ./scripts/run_motor.sh                  # position hold at 1.0 rad until Ctrl+C
#   ./scripts/run_motor.sh pos 1.5          # position hold at 1.5 rad
#   ./scripts/run_motor.sh speed 0.5        # velocity mode at 0.5 rad/s
#   ./scripts/run_motor.sh speed -0.5 20    # velocity mode for 20 s, then auto-disable
#
# Works on Raspberry Pi 5 (can0 or slcan0), Ubuntu laptop (can0) and Jetson Orin
# (can1 is picked up automatically if it is the only interface up).

set -u

MODE="${1:-pos}"
TARGET="${2:-1.0}"
DURATION="${3:-0}"        # seconds; 0 = run until Ctrl+C

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="/ak_motor_cable_control_node"

# ── ROS 2 environment ────────────────────────────────────────────────────────
if [ -z "${ROS_DISTRO:-}" ]; then
  for d in /opt/ros/humble /opt/ros/jazzy /opt/ros/rolling; do
    if [ -f "$d/setup.bash" ]; then source "$d/setup.bash"; break; fi
  done
fi
for ws in "$REPO/install/setup.bash" "$REPO/../install/setup.bash"; do
  if [ -f "$ws" ]; then source "$ws"; break; fi
done
if [ -z "${ROS_DISTRO:-}" ]; then
  echo "ERROR: no ROS 2 installation found (checked /opt/ros/* and workspace install/)." >&2
  exit 1
fi

# ── CAN interface ────────────────────────────────────────────────────────────
if ip link show can0 >/dev/null 2>&1; then
  IFACE=can0
elif ip link show slcan0 >/dev/null 2>&1; then
  IFACE=slcan0
elif ip link show can1 >/dev/null 2>&1; then
  IFACE=can1
else
  echo "No CAN interface up yet - running setup_can_pi5.sh (may ask for sudo)..."
  sudo "$REPO/scripts/setup_can_pi5.sh" || exit 1
  if ip link show can0 >/dev/null 2>&1; then IFACE=can0
  elif ip link show slcan0 >/dev/null 2>&1; then IFACE=slcan0
  else echo "ERROR: no CAN interface after setup." >&2; exit 1; fi
fi
echo ">> CAN interface: $IFACE"

# ── cleanup: disable motor FIRST, then stop publisher and node ───────────────
cleanup() {
  echo ""
  echo ">> Disabling motor (exit-MIT)..."
  timeout 5 ros2 service call "$NODE/disable" std_srvs/srv/Trigger >/dev/null 2>&1
  kill "${PUB_PID:-}" "${LAUNCH_PID:-}" 2>/dev/null
  wait 2>/dev/null
  echo ">> Motor disabled. Safe to power off."
}
trap cleanup INT TERM

# ── launch the node ──────────────────────────────────────────────────────────
ros2 launch ak_motor_driver cable_control.launch.py can_interface:="$IFACE" &
LAUNCH_PID=$!

echo ">> Waiting for node..."
for _ in $(seq 1 30); do
  ros2 service list 2>/dev/null | grep -q "$NODE/enable" && break
  sleep 0.5
done

# ── command publisher FIRST (command watchdog), then enable ──────────────────
case "$MODE" in
  pos)
    POS="$TARGET"; VEL=0.0
    ros2 topic pub --once "$NODE/mode_cmd" std_msgs/msg/String "{data: 'pos'}" >/dev/null 2>&1
    ;;
  speed)
    POS=0.0; VEL="$TARGET"
    ;;
  *)
    echo "ERROR: mode must be 'pos' or 'speed' (got '$MODE')." >&2
    cleanup; exit 1
    ;;
esac

ros2 topic pub --rate 50 "$NODE/command" sensor_msgs/msg/JointState \
  "{name: ['ak40_10'], position: [$POS], velocity: [$VEL], effort: [0.0]}" >/dev/null 2>&1 &
PUB_PID=$!
sleep 1

echo ">> Enabling motor..."
ros2 service call "$NODE/enable" std_srvs/srv/Trigger
echo ">> RUNNING: mode=$MODE target=$TARGET (green LED on). Ctrl+C stops & disables."

if [ "$DURATION" != "0" ]; then
  sleep "$DURATION"
  cleanup
  trap - INT TERM
  exit 0
fi

wait "$LAUNCH_PID"
