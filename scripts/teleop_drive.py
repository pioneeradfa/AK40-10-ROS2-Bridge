#!/usr/bin/env python3
# MIT License
# Copyright (c) 2025 FSC Lab
"""Keyboard teleop for diff_drive_node — no extra packages needed (rclpy + termios).

Keys:  w = forward   s = backward   a = turn left   d = turn right
       x = stop      q (or Ctrl+C) = quit (publishes stop on exit)

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

LINEAR_SPEED = 0.5    # m/s   (w/s)
ANGULAR_SPEED = 1.0   # rad/s (a/d)

KEYS = {
    'w': (LINEAR_SPEED, 0.0),
    's': (-LINEAR_SPEED, 0.0),
    'a': (0.0, ANGULAR_SPEED),
    'd': (0.0, -ANGULAR_SPEED),
    'x': (0.0, 0.0),
}

HELP = """
---------------------------
Moving around:
   w        forward
   s        backward
   a        turn left      d        turn right
   x        stop
   q        quit
---------------------------
"""


def main():
    rclpy.init(args=None)
    node = Node('teleop_drive')
    pub = node.create_publisher(Twist, '/diff_drive_node/cmd_vel', 10)

    settings = termios.tcgetattr(sys.stdin)
    tty.setcbreak(sys.stdin.fileno())
    print(HELP)

    lin, ang = 0.0, 0.0
    try:
        while rclpy.ok():
            if select.select([sys.stdin], [], [], 0.05)[0]:
                key = sys.stdin.read(1)
                if key in ('q', '\x03'):
                    break
                if key in KEYS:
                    lin, ang = KEYS[key]
                    print(f'\rlinear={lin:+.2f} m/s  angular={ang:+.2f} rad/s   ')
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
