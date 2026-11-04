#!/bin/bash
# Safe teardown for the diff-drive robot, always in this order:
#   stop (latched command) -> disable (exit-MIT both motors) -> kill background launch.
# After this it is safe to switch off the 24 V motor supply.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="/diff_drive_node"
PIDFILE=/tmp/diff_drive.pid

if [ -z "${ROS_DISTRO:-}" ]; then
  for d in /opt/ros/humble /opt/ros/jazzy /opt/ros/rolling; do
    if [ -f "$d/setup.bash" ]; then source "$d/setup.bash"; break; fi
  done
fi
for ws in "$REPO/install/setup.bash" "$REPO/../install/setup.bash"; do
  if [ -f "$ws" ]; then source "$ws"; break; fi
done

echo ">> stop ..."
timeout 4 ros2 topic pub --rate 5 "$NODE/move_cmd" std_msgs/msg/String "{data: 'stop'}" >/dev/null 2>&1

echo ">> disable (exit-MIT both motors) ..."
timeout 10 ros2 service call "$NODE/disable" std_srvs/srv/Trigger

if [ -f "$PIDFILE" ]; then
  kill "$(cat "$PIDFILE")" 2>/dev/null
  rm -f "$PIDFILE"
fi
pkill -f "diff_drive.launch.py" 2>/dev/null
sleep 1
echo ">> ROBOT DOWN. Motors disabled (LEDs off, wheels free). Safe to cut 24 V."
