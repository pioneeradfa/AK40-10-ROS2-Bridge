#!/usr/bin/env python3
# MIT License
# Copyright (c) 2025 FSC Lab
"""Keyboard teleop for diff_drive_node — no extra packages needed (rclpy + termios).

INCREMENTAL speed control (like teleop_twist_keyboard): every key press nudges
the target speed by one step; HOLDING a key keeps ramping it via the terminal's
key-repeat. The node additionally slew-limits the motor commands, so the robot
accelerates smoothly instead of jumping to full speed.

Keys:
   w / s   linear  + / −  0.05 m/s per press   (clamped ±0.5 m/s)
   a / d   angular + / −  0.1 rad/s per press  (clamped ±1.0 rad/s)
   W/S/A/D big steps (4×) for quick ramping
   x       stop now (zero both)
   q       quit (or Ctrl+C) — publishes stop on exit

Publishes /diff_drive_node/cmd_vel continuously at 20 Hz while running, so the
node's cmd_vel watchdog stays satisfied; on exit the watchdog falls back to the
latched move_cmd (publish 'stop' first if you want the robot parked).
"""

import select
import sys
import termios
import tty

import rclpy
from geometry_msgs.msg import Twist
from rclpy.node import Node

LIN_STEP = 0.05   # m/s   per w/s press
LIN_MAX = 0.5     # m/s   clamp
ANG_STEP = 0.1    # rad/s per a/d press
ANG_MAX = 1.0     # rad/s clamp
FAST = 4          # multiplier for uppercase W/S/A/D

HELP = """
---------------------------
Incremental speed control:
   w  linear  +0.05 m/s    s  linear  -0.05 m/s   (max ±0.5 m/s)
   a  angular +0.1 rad/s   d  angular -0.1 rad/s  (max ±1.0 rad/s)
   W/S/A/D  big step (4x)  -  hold a key to keep ramping
   x  stop now             q  quit
---------------------------
"""


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def main():
    rclpy.init(args=None)
    node = Node('teleop_drive')
    pub = node.create_publisher(Twist, '/diff_drive_node/cmd_vel', 10)

    settings = termios.tcgetattr(sys.stdin)
    tty.setcbreak(sys.stdin.fileno())
    print(HELP)

    lin, ang = 0.0, 0.0
    quit_now = False
    try:
        while rclpy.ok():
            # Drain ALL pending keys each tick so a held key ramps at full
            # key-repeat rate without building a backlog.
            readable = select.select([sys.stdin], [], [], 0.05)[0]
            while readable and not quit_now:
                key = sys.stdin.read(1)
                if key in ('q', '\x03'):
                    quit_now = True
                    break
                if key:
                    fast = FAST if key.isupper() else 1
                    k = key.lower()
                    if k == 'w':
                        lin = clamp(lin + LIN_STEP * fast, -LIN_MAX, LIN_MAX)
                    elif k == 's':
                        lin = clamp(lin - LIN_STEP * fast, -LIN_MAX, LIN_MAX)
                    elif k == 'a':
                        ang = clamp(ang + ANG_STEP * fast, -ANG_MAX, ANG_MAX)
                    elif k == 'd':
                        ang = clamp(ang - ANG_STEP * fast, -ANG_MAX, ANG_MAX)
                    elif k == 'x':
                        lin, ang = 0.0, 0.0
                    else:
                        key = ''  # unknown key: do not reprint the status line
                    if key:
                        print(f'\rlinear={lin:+.2f} m/s  angular={ang:+.2f} rad/s   ')
                readable = select.select([sys.stdin], [], [], 0.0)[0]
            if quit_now:
                break
            msg = Twist()
            msg.linear.x = lin
            msg.angular.z = ang
            pub.publish(msg)
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, settings)
        stop = Twist()
        for _ in range(5):
            pub.publish(stop)
        print('\nstop published, bye')
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
