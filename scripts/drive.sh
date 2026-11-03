#!/bin/bash
# Simple motion commands for diff_drive_node (two AK40-10 wheels).
#
# Usage:
#   ./scripts/drive.sh forward     # drive forward  (linear_speed preset)
#   ./scripts/drive.sh backward    # drive backward
#   ./scripts/drive.sh left        # pivot turn left  (turn_speed preset)
#   ./scripts/drive.sh right       # pivot turn right
#   ./scripts/drive.sh stop        # hold zero velocity
#   ./scripts/drive.sh enable      # enter MIT mode on both motors
#   ./scripts/drive.sh disable     # exit MIT mode on both motors (do this last!)
#
# move_cmd is latched by the node: one publish keeps the robot moving until the
# next command. Run WITHOUT sudo.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="/diff_drive_node"
CMD="${1:-}"

if [ -z "${ROS_DISTRO:-}" ]; then
  for d in /opt/ros/humble /opt/ros/jazzy /opt/ros/rolling; do
    if [ -f "$d/setup.bash" ]; then source "$d/setup.bash"; break; fi
  done
fi
for ws in "$REPO/install/setup.bash" "$REPO/../install/setup.bash"; do
  if [ -f "$ws" ]; then source "$ws"; break; fi
done

case "$CMD" in
  enable)
    ros2 service call "$NODE/enable" std_srvs/srv/Trigger
    ;;
  disable)
    ros2 service call "$NODE/disable" std_srvs/srv/Trigger
    ;;
  forward|backward|left|right|stop)
    # Burst for ~4 s instead of --once: (a) a single message can be lost while DDS
    # discovery matches the new publisher to the node's subscription, and (b) on the
    # Pi a source-build Humble needs 1-3 s just to init the CLI node - a short
    # timeout kills it mid-init ("context is not valid"). The node latches move_cmd,
    # so one delivered message is enough. For reactive control use teleop_drive.py.
    timeout 4 ros2 topic pub --rate 5 "$NODE/move_cmd" std_msgs/msg/String "{data: '$CMD'}" >/dev/null 2>&1
    ;;
  *)
    echo "Usage: $0 forward|backward|left|right|stop|enable|disable" >&2
    exit 1
    ;;
esac
