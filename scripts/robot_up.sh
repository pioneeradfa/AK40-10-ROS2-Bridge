#!/bin/bash
# One-command bring-up for the two-wheel diff-drive robot:
#   CAN interface -> launch diff_drive_node in background -> enable both motors.
# Logs go to /tmp/diff_drive.log (tail -f it). Tear down with ./scripts/robot_down.sh.
# Run WITHOUT sudo (the script elevates only for CAN setup if needed).

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="/diff_drive_node"
LOG=/tmp/diff_drive.log
PIDFILE=/tmp/diff_drive.pid

# ── ROS 2 environment (no 'set -u': colcon setup.bash refs unbound vars) ──────
if [ -z "${ROS_DISTRO:-}" ]; then
  for f in /opt/ros/humble/setup.bash /opt/ros/jazzy/setup.bash /opt/ros/rolling/setup.bash \
           "$HOME"/ros2_*/install/setup.bash; do
    if [ -f "$f" ]; then source "$f"; break; fi
  done
fi
for ws in "$REPO/install/setup.bash" "$REPO/../install/setup.bash"; do
  if [ -f "$ws" ]; then source "$ws"; break; fi
done
if [ -z "${ROS_DISTRO:-}" ]; then
  echo "ERROR: no ROS 2 installation found." >&2
  exit 1
fi

# ── 1) CAN interface ─────────────────────────────────────────────────────────
if ip link show can0 >/dev/null 2>&1; then IFACE=can0
elif ip link show slcan0 >/dev/null 2>&1; then IFACE=slcan0
elif ip link show can1 >/dev/null 2>&1; then IFACE=can1
else
  sudo "$REPO/scripts/setup_can_pi5.sh" || exit 1
  if ip link show can0 >/dev/null 2>&1; then IFACE=can0
  elif ip link show slcan0 >/dev/null 2>&1; then IFACE=slcan0
  else echo "ERROR: no CAN interface after setup." >&2; exit 1; fi
fi
echo ">> CAN interface: $IFACE"

# ── 2) launch in background (skip if already running) ────────────────────────
if pgrep -f "diff_drive.launch.py" >/dev/null 2>&1; then
  echo ">> diff_drive launch already running - reusing it."
else
  nohup ros2 launch ak_motor_driver diff_drive.launch.py can_interface:="$IFACE" \
    > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  echo ">> launched in background (log: $LOG)"
fi

# ── 3) wait for the node, then enable (starts from standstill) ───────────────
echo ">> waiting for $NODE/enable ..."
LAUNCH_PID="$(cat "$PIDFILE" 2>/dev/null || true)"
for _ in $(seq 1 30); do
  ros2 service list 2>/dev/null | grep -q "$NODE/enable" && break
  if [ -n "$LAUNCH_PID" ] && ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
    echo "ERROR: launch process died - last lines of $LOG:" >&2
    tail -n 15 "$LOG" >&2
    exit 1
  fi
  sleep 0.5
done
ros2 service call "$NODE/enable" std_srvs/srv/Trigger

cat << 'EOF'
>> ROBOT UP. Both motors in MIT mode, standstill until commanded.

   drive:   ./scripts/drive.sh forward|backward|left|right|stop
   teleop:  ros2 run ak_motor_driver teleop_drive.py     (w s a d, x stop, q quit)
   watch:   ros2 topic echo /diff_drive_node/joint_state
   log:     tail -f /tmp/diff_drive.log
   down:    ./scripts/robot_down.sh        (stop -> disable -> kill launch)
EOF
