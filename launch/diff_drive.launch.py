from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node
from ament_index_python.packages import get_package_share_directory
import os


def generate_launch_description():
    pkg = get_package_share_directory("ak_motor_driver")
    params = os.path.join(pkg, "config", "diff_drive_params.yaml")

    can_arg = DeclareLaunchArgument(
        "can_interface", default_value="can0",
        description="Linux CAN interface name (e.g. can0, slcan0)"
    )
    id_left_arg = DeclareLaunchArgument(
        "motor_id_left", default_value="1",
        description="CAN ID of the left wheel actuator"
    )
    id_right_arg = DeclareLaunchArgument(
        "motor_id_right", default_value="6",
        description="CAN ID of the right wheel actuator (this rig: 6)"
    )

    return LaunchDescription([
        can_arg,
        id_left_arg,
        id_right_arg,
        Node(
            package="ak_motor_driver",
            executable="diff_drive_node",
            name="diff_drive_node",
            output="screen",
            parameters=[params, {
                "can_interface": LaunchConfiguration("can_interface"),
                "motor_id_left": LaunchConfiguration("motor_id_left"),
                "motor_id_right": LaunchConfiguration("motor_id_right"),
            }],
        ),
    ])
