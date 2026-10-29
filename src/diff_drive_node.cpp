// MIT License
// Copyright (c) 2025 FSC Lab
//
// Differential-drive controller for a two-wheel robot built with AK40-10
// actuators (left = motor_id_left, right = motor_id_right) on ONE CAN bus.
// Both motors are driven in velocity mode (kp=0, kd=kd_drive) from either:
//   ~/cmd_vel   geometry_msgs/Twist  (linear.x m/s, angular.z rad/s; watchdog stops on staleness)
//   ~/move_cmd  std_msgs/String      ("forward" | "backward" | "left" | "right" | "stop"; latched)
// Fresh cmd_vel overrides the latched move_cmd; when cmd_vel goes stale the
// latched move_cmd takes over again (publish "stop" to park the robot).

#include <memory>
#include <string>

#include <rclcpp/rclcpp.hpp>
#include <geometry_msgs/msg/twist.hpp>
#include <sensor_msgs/msg/joint_state.hpp>
#include <std_msgs/msg/float32_multi_array.hpp>
#include <std_msgs/msg/string.hpp>
#include <std_srvs/srv/trigger.hpp>

#include "ak_motor_driver/ak40_codec.hpp"
#include "ak_motor_driver/can_socket.hpp"

namespace ak_motor_driver {

class DiffDriveNode : public rclcpp::Node {
 public:
  DiffDriveNode() : Node("diff_drive_node") {
    declare_parameter("can_interface", "can0");
    declare_parameter("motor_id_left", 1);
    declare_parameter("motor_id_right", 2);
    declare_parameter("poll_rate_hz", 100.0);
    declare_parameter("kd_drive", 0.5);
    declare_parameter("wheel_radius", 0.1);    // m
    declare_parameter("track_width", 0.4);     // m, wheel centre to wheel centre
    declare_parameter("gear_ratio", 10.0);     // motor rad/s per wheel rad/s
    declare_parameter("linear_speed", 0.5);    // m/s preset for forward/backward
    declare_parameter("turn_speed", 1.0);      // rad/s preset for left/right (pivot turn)
    declare_parameter("invert_left", false);   // flip if a motor is mounted mirrored
    declare_parameter("invert_right", false);
    declare_parameter("command_timeout_ms", 500.0);
    declare_parameter("temp_limit_c", 75.0);
    declare_parameter("p_min", -12.5);
    declare_parameter("p_max", 12.5);
    declare_parameter("v_min", -45.5);
    declare_parameter("v_max", 45.5);
    declare_parameter("t_min", -5.0);
    declare_parameter("t_max", 5.0);
    declare_parameter("kp_max", 500.0);
    declare_parameter("kd_max", 5.0);

    const std::string can_iface = get_parameter("can_interface").as_string();
    const uint8_t id_l = static_cast<uint8_t>(get_parameter("motor_id_left").as_int());
    const uint8_t id_r = static_cast<uint8_t>(get_parameter("motor_id_right").as_int());
    const double rate_hz = get_parameter("poll_rate_hz").as_double();

    kd_drive_     = get_parameter("kd_drive").as_double();
    wheel_radius_ = get_parameter("wheel_radius").as_double();
    track_width_  = get_parameter("track_width").as_double();
    gear_ratio_   = get_parameter("gear_ratio").as_double();
    linear_speed_ = get_parameter("linear_speed").as_double();
    turn_speed_   = get_parameter("turn_speed").as_double();
    invert_left_  = get_parameter("invert_left").as_bool();
    invert_right_ = get_parameter("invert_right").as_bool();
    command_timeout_ms_ = get_parameter("command_timeout_ms").as_double();
    temp_limit_c_       = get_parameter("temp_limit_c").as_double();

    Ak40Limits limits;
    limits.p_min  = get_parameter("p_min").as_double();
    limits.p_max  = get_parameter("p_max").as_double();
    limits.v_min  = get_parameter("v_min").as_double();
    limits.v_max  = get_parameter("v_max").as_double();
    limits.t_min  = get_parameter("t_min").as_double();
    limits.t_max  = get_parameter("t_max").as_double();
    limits.kp_max = get_parameter("kp_max").as_double();
    limits.kd_max = get_parameter("kd_max").as_double();

    can_socket_ = std::make_unique<CanSocket>(can_iface);
    codec_l_ = std::make_unique<Ak40Codec>(id_l, limits);
    codec_r_ = std::make_unique<Ak40Codec>(id_r, limits);

    if (!can_socket_->open()) {
      RCLCPP_ERROR(get_logger(), "Failed to open CAN interface '%s'", can_iface.c_str());
      throw std::runtime_error("CAN socket open failed");
    }
    RCLCPP_INFO(get_logger(), "CAN interface '%s' opened (left id=%u, right id=%u)",
                can_iface.c_str(), id_l, id_r);

    // Clear any armed state from a previous crashed session on BOTH motors.
    can_socket_->write(codec_l_->exit_mit_mode());
    can_socket_->write(codec_r_->exit_mit_mode());
    RCLCPP_INFO(get_logger(), "Sent exit-MIT-mode to both motors (motors safe)");

    joint_state_pub_ = create_publisher<sensor_msgs::msg::JointState>("~/joint_state", 10);
    temp_pub_ = create_publisher<std_msgs::msg::Float32MultiArray>("~/temperature", 10);

    cmd_vel_sub_ = create_subscription<geometry_msgs::msg::Twist>(
        "~/cmd_vel", 10,
        [this](const geometry_msgs::msg::Twist::SharedPtr msg) { on_cmd_vel(msg); });

    move_cmd_sub_ = create_subscription<std_msgs::msg::String>(
        "~/move_cmd", 10,
        [this](const std_msgs::msg::String::SharedPtr msg) { on_move_cmd(msg); });

    enable_srv_ = create_service<std_srvs::srv::Trigger>(
        "~/enable",
        [this](const std_srvs::srv::Trigger::Request::SharedPtr,
               std_srvs::srv::Trigger::Response::SharedPtr resp) {
          can_socket_->write(codec_l_->enter_mit_mode());
          can_socket_->write(codec_r_->enter_mit_mode());
          enabled_ = true;
          resp->success = true;
          resp->message = "Both motors enabled (MIT mode)";
          RCLCPP_INFO(get_logger(), "Both motors enabled");
        });

    disable_srv_ = create_service<std_srvs::srv::Trigger>(
        "~/disable",
        [this](const std_srvs::srv::Trigger::Request::SharedPtr,
               std_srvs::srv::Trigger::Response::SharedPtr resp) {
          send_exit_mit();
          resp->success = true;
          resp->message = "Both motors disabled";
          RCLCPP_INFO(get_logger(), "Both motors disabled");
        });

    using namespace std::chrono_literals;
    const auto period = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::duration<double>(1.0 / rate_hz));
    poll_timer_ = create_wall_timer(period, [this]() { poll(); });
  }

  ~DiffDriveNode() override {
    if (can_socket_ && can_socket_->is_open()) { send_exit_mit(); }
  }

 private:
  void send_exit_mit() {
    can_socket_->write(codec_l_->exit_mit_mode());
    can_socket_->write(codec_r_->exit_mit_mode());
    enabled_ = false;
  }

  void on_cmd_vel(const geometry_msgs::msg::Twist::SharedPtr msg) {
    cmd_vel_x_ = msg->linear.x;
    cmd_vel_z_ = msg->angular.z;
    last_cmd_vel_time_ = now();
    has_cmd_vel_ = true;
  }

  void on_move_cmd(const std_msgs::msg::String::SharedPtr msg) {
    const std::string& c = msg->data;
    if (c == "forward")       { latched_x_ =  linear_speed_; latched_z_ = 0.0; }
    else if (c == "backward") { latched_x_ = -linear_speed_; latched_z_ = 0.0; }
    else if (c == "left")     { latched_x_ = 0.0; latched_z_ =  turn_speed_; }
    else if (c == "right")    { latched_x_ = 0.0; latched_z_ = -turn_speed_; }
    else if (c == "stop")     { latched_x_ = 0.0; latched_z_ = 0.0; }
    else {
      RCLCPP_WARN(get_logger(), "Unknown move_cmd '%s' (forward|backward|left|right|stop)",
                  c.c_str());
      return;
    }
    RCLCPP_INFO(get_logger(), "move_cmd '%s' (x=%.2f m/s, z=%.2f rad/s)",
                c.c_str(), latched_x_, latched_z_);
  }

  void poll() {
    // Effective robot-space command: fresh cmd_vel wins, else latched move_cmd.
    double x = latched_x_;
    double z = latched_z_;
    if (has_cmd_vel_) {
      const double elapsed_ms = (now() - last_cmd_vel_time_).nanoseconds() / 1e6;
      if (elapsed_ms <= command_timeout_ms_) {
        x = cmd_vel_x_;
        z = cmd_vel_z_;
      } else {
        has_cmd_vel_ = false;
        RCLCPP_WARN_THROTTLE(get_logger(), *get_clock(), 2000,
                             "cmd_vel stale (%.0f ms) — falling back to latched move_cmd",
                             elapsed_ms);
      }
    }

    if (enabled_) {
      // Differential-drive kinematics: wheel rad/s -> motor rad/s via gear ratio.
      const double v_wheel_l = (x - z * track_width_ * 0.5) / wheel_radius_;
      const double v_wheel_r = (x + z * track_width_ * 0.5) / wheel_radius_;
      const double v_motor_l = v_wheel_l * gear_ratio_ * (invert_left_  ? -1.0 : 1.0);
      const double v_motor_r = v_wheel_r * gear_ratio_ * (invert_right_ ? -1.0 : 1.0);

      MitCommand cmd_l;
      cmd_l.velocity = v_motor_l;
      cmd_l.kp = 0.0;
      cmd_l.kd = kd_drive_;
      MitCommand cmd_r;
      cmd_r.velocity = v_motor_r;
      cmd_r.kp = 0.0;
      cmd_r.kd = kd_drive_;

      can_socket_->write(codec_l_->encode(cmd_l));
      can_socket_->write(codec_r_->encode(cmd_r));
    }

    // Drain feedback frames from both motors.
    while (can_socket_->is_open()) {
      auto frame_opt = can_socket_->read();
      if (!frame_opt) { break; }

      auto sl = codec_l_->decode(*frame_opt);
      if (sl) {
        state_l_ = *sl;
        check_temp("left", state_l_.temperature);
        continue;
      }
      auto sr = codec_r_->decode(*frame_opt);
      if (sr) {
        state_r_ = *sr;
        check_temp("right", state_r_.temperature);
      }
    }

    sensor_msgs::msg::JointState js;
    js.header.stamp = now();
    js.name.push_back("wheel_left");
    js.name.push_back("wheel_right");
    js.position.push_back(state_l_.position);
    js.position.push_back(state_r_.position);
    js.velocity.push_back(state_l_.velocity);
    js.velocity.push_back(state_r_.velocity);
    js.effort.push_back(state_l_.torque);
    js.effort.push_back(state_r_.torque);
    joint_state_pub_->publish(js);

    std_msgs::msg::Float32MultiArray temps;
    temps.data.push_back(static_cast<float>(state_l_.temperature));
    temps.data.push_back(static_cast<float>(state_r_.temperature));
    temp_pub_->publish(temps);
  }

  void check_temp(const char* side, int8_t temp_c) {
    if (enabled_ && temp_c >= static_cast<int8_t>(temp_limit_c_)) {
      RCLCPP_ERROR(get_logger(), "%s motor temperature %d C >= limit %.0f C — auto-disabled!",
                   side, temp_c, temp_limit_c_);
      send_exit_mit();
    }
  }

  std::unique_ptr<CanSocket>  can_socket_;
  std::unique_ptr<Ak40Codec>  codec_l_;
  std::unique_ptr<Ak40Codec>  codec_r_;

  rclcpp::Publisher<sensor_msgs::msg::JointState>::SharedPtr  joint_state_pub_;
  rclcpp::Publisher<std_msgs::msg::Float32MultiArray>::SharedPtr temp_pub_;

  rclcpp::Subscription<geometry_msgs::msg::Twist>::SharedPtr cmd_vel_sub_;
  rclcpp::Subscription<std_msgs::msg::String>::SharedPtr     move_cmd_sub_;

  rclcpp::Service<std_srvs::srv::Trigger>::SharedPtr enable_srv_;
  rclcpp::Service<std_srvs::srv::Trigger>::SharedPtr disable_srv_;

  rclcpp::TimerBase::SharedPtr poll_timer_;

  // Robot-space commands
  double cmd_vel_x_{0.0};
  double cmd_vel_z_{0.0};
  rclcpp::Time last_cmd_vel_time_{0, 0, RCL_ROS_TIME};
  bool has_cmd_vel_{false};
  double latched_x_{0.0};   // move_cmd preset, persists until next move_cmd
  double latched_z_{0.0};

  MotorState state_l_{};
  MotorState state_r_{};

  bool   enabled_{false};
  double kd_drive_{0.5};
  double wheel_radius_{0.1};
  double track_width_{0.4};
  double gear_ratio_{10.0};
  double linear_speed_{0.5};
  double turn_speed_{1.0};
  bool   invert_left_{false};
  bool   invert_right_{false};
  double command_timeout_ms_{500.0};
  double temp_limit_c_{75.0};
};

}  // namespace ak_motor_driver

int main(int argc, char** argv) {
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<ak_motor_driver::DiffDriveNode>());
  rclcpp::shutdown();
  return 0;
}
