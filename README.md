# ak_motor_driver

ROS 2 driver for the CubeMars AK40-10 actuator over SocketCAN.

> **Running on a Raspberry Pi 5?** Start with **[PI5_QUICKSTART.md](PI5_QUICKSTART.md)** —
> the verified 10-minute path (wiring diagram, CAN bring-up for the MKS CANable V2.0 Pro,
> connection test, one-command motor run) on Pi OS Bookworm + ROS 2 Humble.
> Full-length guide: [`doc/raspberry_pi5_akcan40.md`](doc/raspberry_pi5_akcan40.md).

## Prerequisites

### 1. CAN setup (Raspberry Pi 5)

The Pi 5 has **no on-board CAN controller**, but the CubeMars AKCAN40 USB-CAN adapter (and any CANable / gs_usb-compatible dongle) works out of the box: the standard Pi kernel (Ubuntu 24.04 and Raspberry Pi OS) ships `gs_usb`, and the adapter claims `can0`. No kernel module build is needed.

> **MKS Makerbase CANable V2.0 / V2.0 Pro** ships with *slcan* (serial) firmware — it appears as `/dev/ttyACM0`, not `can0`. Either run it through `slcand` (interface `slcan0`, launch with `can_interface:=slcan0`) or flash candleLight firmware for native `can0`. The guide below covers both, plus a step-by-step connection test (loopback self-test → raw `cansend`/`candump` bus test → ROS 2 test).

Recommended stack: **Ubuntu Server 24.04 LTS (64-bit) + ROS 2 Jazzy** (Tier-1 apt binaries). **Raspberry Pi OS Bookworm with an existing ROS 2 install (e.g. Humble) is also supported** — the Pi OS kernel ships `gs_usb` too, the CAN steps are identical, and the package builds unmodified on Humble+. Full from-scratch guide — flashing the OS, ROS 2 install, wiring, termination, boot persistence, auto-start, Raspberry Pi OS / Humble quickstart, Docker, and troubleshooting — is in **[doc/raspberry_pi5_akcan40.md](doc/raspberry_pi5_akcan40.md)**.
The shortest verified path (wiring → CAN up → connection test → one-command run) is in
**[PI5_QUICKSTART.md](PI5_QUICKSTART.md)**.

**Every reboot — bring up can0 (recommended):**

```bash
sudo ./scripts/setup_can_pi5.sh
```

**One-time — auto-configure on every boot/hotplug (udev rule + module autoload):**

```bash
sudo ./scripts/setup_can_pi5.sh --persist
```

**Backup — manual commands:**

```bash
sudo modprobe gs_usb          # normally auto-loads when the dongle is plugged in
sudo ip link set can0 down
sudo ip link set can0 up type can bitrate 1000000
sudo ip link set can0 txqueuelen 1000
ip link show can0             # should show state UP, bitrate 1000000
```

### 2. Build and source the workspace

```bash
cd ~/<your_ros2_workspace_root>   # e.g. ~/dev_ws, ~/ros2_ws — differs per machine
colcon build --packages-select ak_motor_driver
source install/setup.bash
```

## Launch

### Step 1 — bring up the CAN interface (run once per reboot)

```bash
sudo ./scripts/setup_can_pi5.sh    # brings up can0 (gs_usb) or slcan0 (MKS CANable stock fw)
```

### Step 2 — launch the node

```bash
ros2 launch ak_motor_driver cable_control.launch.py can_interface:=can0   # or slcan0
```

**One-command alternative** (brings CAN up, launches, publishes `~/command`, enables;
Ctrl+C disables the motor first — run without sudo):

```bash
./scripts/run_motor.sh deg 90         # ANGLE control: hold at 90 degrees
./scripts/run_motor.sh pos 1.0        # position hold at 1.0 rad (green LED on)
./scripts/run_motor.sh speed 0.5      # velocity mode at 0.5 rad/s
./scripts/run_motor.sh speed -0.5 20  # timed: 20 s then auto-disable
```

Angles/positions are relative to the stored encoder zero
(`ros2 service call /ak_motor_cable_control_node/zero_position std_srvs/srv/Trigger`,
motor must be disabled). `deg` accepts −716…716° (the ±12.5 rad MIT range); values
outside are clamped by the node.

## Operating sequence

### 1. Set encoder zero position

Move the shaft to the desired zero angle, then call the service. The motor must be **disabled** — the service will reject the request if the motor is enabled.

```bash
# If motor is currently enabled, disable first
ros2 service call /ak_motor_node/disable std_srvs/srv/Trigger

# Set current shaft position as zero
ros2 service call /ak_motor_node/zero_position std_srvs/srv/Trigger
```

The zero position is stored **persistently in the motor's flash memory**. It survives power cycles and only needs to be set once per physical setup. After setting, position `0.0 rad` in `~/command` will correspond to this angle.

### 2. Set gains

```bash
ros2 param set /ak_motor_node kp 1.0   # Nm/rad, position stiffness
ros2 param set /ak_motor_node kd 0.3   # Nms/rad, damping
```

### 3. Start publishing commands before enabling

```bash
ros2 topic pub --rate 50 /ak_motor_node/command sensor_msgs/msg/JointState \
  "{name: ['ak40_10'], position: [0.0], velocity: [0.0], effort: [0.0]}"
```

### 4. Enable the motor

```bash
ros2 service call /ak_motor_node/enable std_srvs/srv/Trigger
```

### 5. Change target position

Update the position field (radians). The motor moves immediately — no need to disable.

```bash
ros2 topic pub --rate 50 /ak_motor_node/command sensor_msgs/msg/JointState \
  "{name: ['ak40_10'], position: [1.57], velocity: [0.0], effort: [0.0]}"
```

### 6. Shutdown procedure

Always disable the motor **before** stopping the node. If the node is killed first, the motor stays in MIT mode and will respond to the next command frame it receives.

```bash
# Step 1 — disable the motor (sends exit-MIT-mode frame)
ros2 service call /ak_motor_node/disable std_srvs/srv/Trigger

# Step 2 — stop the node
Ctrl+C in the launch terminal
```

## Monitoring

| Topic | Type | Content |
|---|---|---|
| `~/joint_state` | `sensor_msgs/JointState` | position (rad), velocity (rad/s), torque (Nm) |
| `~/temperature` | `std_msgs/Float32` | motor temperature (°C) |
| `~/mode` | `std_msgs/Int8` | operating mode enum |
| `~/error_flags` | `std_msgs/UInt8` | raw error byte from motor |

```bash
ros2 topic echo /ak_motor_node/joint_state --field position
ros2 topic echo /ak_motor_node/temperature
ros2 topic hz /ak_motor_node/joint_state
```

## Safety

- **Auto-disable:** the node automatically sends exit-MIT-mode and stops if motor temperature reaches `temp_limit_c` (default 75°C).
- **Watchdog:** if no `~/command` message is received within `command_timeout_ms` (default 500 ms), gains are dropped to `kp=0, kd=kd_watchdog` — the motor becomes a pure damper and stops tracking position.
- **Zero position lock:** `~/zero_position` is rejected while the motor is enabled.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `can_interface` | `can0` | Linux CAN interface name |
| `motor_id` | `1` | Motor CAN node ID |
| `motor_name` | `ak40_10` | Name used in JointState messages |
| `poll_rate_hz` | `100.0` | Timer rate for CAN polling and command sending |
| `kp` | `1.0` | Position gain (Nm/rad) |
| `kd` | `0.3` | Velocity gain (Nms/rad) |
| `kp_max` | `500.0` | Maximum allowed kp |
| `kd_max` | `5.0` | Maximum allowed kd |
| `command_timeout_ms` | `500.0` | Watchdog timeout (ms) |
| `kd_watchdog` | `0.05` | Damping applied on watchdog activation |
| `temp_limit_c` | `75.0` | Auto-disable temperature threshold (°C) |
| `p_min` / `p_max` | `-12.5` / `12.5` | Position limits (rad) |
| `v_min` / `v_max` | `-45.5` / `45.5` | Velocity limits (rad/s) — AK40-10 spec |
| `t_min` / `t_max` | `-5.0` / `5.0` | Torque limits (Nm) — AK40-10 spec |

## Cable control node

### Topics

| Topic | Direction | Type | Purpose |
|---|---|---|---|
| `~/command` | GUI → node | `sensor_msgs/JointState` | Speed (velocity), torque (effort), or position setpoint |
| `~/mode_cmd` | GUI → node | `std_msgs/String` | Switch mode: `"speed"`, `"torque"`, `"pos"` |
| `~/heartbeat` | GUI → node | `std_msgs/Empty` | Primary GUI heartbeat |
| `~/heartbeat_external` | backup → node | `std_msgs/Empty` | Backup heartbeat source |
| `~/node_heartbeat` | node → GUI | `std_msgs/Empty` | Node liveness signal (100 Hz) |
| `~/enabled` | node → GUI | `std_msgs/Bool` | Motor enable state |
| `~/control_mode` | node → GUI | `std_msgs/String` | Current active mode |
| `~/joint_state` | node → GUI | `sensor_msgs/JointState` | Motor feedback |
| `~/temperature` | node → GUI | `std_msgs/Float32` | Motor temperature (°C) |
| `~/mode` | node → GUI | `std_msgs/Int8` | Motor mode enum |
| `~/error_flags` | node → GUI | `std_msgs/UInt8` | Raw error byte |

### Gains

Gains are loaded from the parameter file at startup and refreshed each time a mode switch is received on `~/mode_cmd`. The GUI never needs to call `ros2 param set`.

| Mode | Active gains | Parameter |
|---|---|---|
| `speed` | `kp=0`, `kd=kd_speed` | `kd_speed` (default 0.5) |
| `torque` | `kp=0`, `kd=0` | — |
| `pos` | `kp=kp_pos`, `kd=kd_pos` | `kp_pos` (default 1.0), `kd_pos` (default 0.3) |

If `~/command` contains non-zero fields that don't belong to the current mode, the node logs a `[WARN]` and ignores those fields.

### Timeouts

| Parameter | Default | Effect when exceeded |
|---|---|---|
| `command_timeout_ms` | 500 ms | Drops to `kp=0, kd=kd_watchdog` (pure damping) |
| `heartbeat_timeout_ms` | 1000 ms | Disables motor if **both** heartbeat sources are stale |

### Services

```bash
ros2 service call /ak_motor_cable_control_node/enable std_srvs/srv/Trigger
ros2 service call /ak_motor_cable_control_node/disable std_srvs/srv/Trigger

# Reset encoder zero position (motor must be disabled first)
ros2 service call /ak_motor_cable_control_node/disable std_srvs/srv/Trigger
ros2 service call /ak_motor_cable_control_node/zero_position std_srvs/srv/Trigger
```

### Switch control mode

```bash
ros2 topic pub --once /ak_motor_cable_control_node/mode_cmd std_msgs/msg/String "{data: 'speed'}"
ros2 topic pub --once /ak_motor_cable_control_node/mode_cmd std_msgs/msg/String "{data: 'torque'}"
ros2 topic pub --once /ak_motor_cable_control_node/mode_cmd std_msgs/msg/String "{data: 'pos'}"
```

### Send speed command (rad/s)

```bash
ros2 topic pub --rate 50 /ak_motor_cable_control_node/command sensor_msgs/msg/JointState \
  "{name: ['ak40_10'], position: [0.0], velocity: [1.0], effort: [0.0]}"
```

### External mode

External mode allows a separate ROS node to drive the motor with direct torque commands. The cable control node acts as the authority gate — only it can open and close external mode.

**State machine:** `off → standby → running`

| Topic / Service | Type | Direction | Purpose |
|---|---|---|---|
| `~/enable_external_mode` | `Trigger` | service | `off → standby`; zeros encoder; rejects if already active |
| `~/ext_torque_enable` | `std_msgs/Bool` | sub | `true`: `standby → running`; `false`: `running → standby` (holds zero velocity) |
| `~/ext_torque_cmd` | `std_msgs/Float32` (N.m) | sub | Torque command; ignored unless `running`; clamped to `[torque_limit_lower, torque_limit_upper]` |
| `~/ext_mode_cmd` | `std_msgs/String` | sub | `"off"`: exit external mode, restore previous control mode |
| `~/ext_mode_state` | `std_msgs/String` | pub | Publishes `"off"` / `"standby"` / `"running"` at 100 Hz |
| `~/cable_state` | `std_msgs/Float32MultiArray` | pub | `data[0]` = cable length (m), `data[1]` = cable velocity (m/s); active in any mode |

**Manual activation sequence:**

```bash
# 1. Enable external mode (zeros encoder, enters STANDBY)
ros2 service call /ak_motor_cable_control_node/enable_external_mode std_srvs/srv/Trigger

# 2. Confirm STANDBY
ros2 topic echo /ak_motor_cable_control_node/ext_mode_state --once

# 3. Start torque control (STANDBY → RUNNING)
ros2 topic pub --once /ak_motor_cable_control_node/ext_torque_enable std_msgs/msg/Bool "{data: true}"

# 4. Send a torque command (N.m, clamped to ±1.5 N.m)
ros2 topic pub --rate 100 /ak_motor_cable_control_node/ext_torque_cmd std_msgs/msg/Float32 "{data: 0.5}"

# 5. Return to STANDBY (holds zero velocity)
ros2 topic pub --once /ak_motor_cable_control_node/ext_torque_enable std_msgs/msg/Bool "{data: false}"

# 6. Fully exit external mode
ros2 topic pub --once /ak_motor_cable_control_node/ext_mode_cmd std_msgs/msg/String "{data: 'off'}"
```

**Sign convention (positive motor velocity = retract):**
- Positive torque → retracts cable (payload up)
- Negative torque → extends cable (payload down)
- Gravity compensation requires positive torque: `τ = m × r × g`

**New parameters (cable control node):**

| Parameter | Default | Description |
|---|---|---|
| `torque_limit_upper` | `1.5` N.m | External torque clamp upper bound (AK40-10 peak: 1.9 N.m) |
| `torque_limit_lower` | `-1.5` N.m | External torque clamp lower bound |
| `drum_radius` | `0.0175` m | Cable drum radius for length calculation |

## Cable torque controller node

`cable_torque_ctrl_node` is a test and calibration node that drives the cable control node via external mode using a model-based torque control law with UDE disturbance compensation:

```
e_v       = v_c - v_c_star
e_p       = p_c - p_c_star
tau_ctrl  = mass × drum_radius × (acc_ref - kd_c × (e_v + kp_c × e_p))
tau_d_hat = UDE disturbance estimate                     (see UDE section below)
tau       = sat(tau_ctrl - tau_d_hat, sat_upper, sat_lower)
```

Where `v_c` and `p_c` are the actual cable velocity and length read from the cable control node.

**Default when no reference is received:** `acc_ref = 9.81 m/s²`, `v_c_star = 0`, `e_p = 0` — gravity hold (keeps a hanging payload stationary).

### UDE (Uncertainty and Disturbance Estimator)

Estimates unknown residual disturbance `tau_d` in gear/cable dynamics. Motor model:

```
J·dω/dt = tau_p + tau_d + tau
```

Where `tau_p = −mass × drum_radius × g` (known payload gravity torque, negative = extension direction) and `tau` is the final capped motor torque from the previous step.

Integral update (avoids computing dω/dt):

```
integrand      = tau_d_hat + tau_p + tau_applied_prev
integral_term += integrand × dt     (frozen when |λ × integral_term| > ude_integral_limit)
tau_d_hat      = λ × J × ω − λ × integral_term
```

At steady state with zero position error, `tau_p + tau_ctrl = 0` so the integrand settles to zero naturally — no steady-state position error. UDE state is reset to zero on `~/disarm`. Monitor via `~/ude_disturbance`.

### Topics

| Topic | Type | Direction | Purpose |
|---|---|---|---|
| `~/reference` | `std_msgs/Float64MultiArray` [acc_ref, v_c_star, p_c_star] | sub | Combined reference input |
| `~/cable_state` | `std_msgs/Float32MultiArray` [length, velocity] | sub | Cable length (m) and velocity (m/s) — remap to cable control node |
| `~/ext_torque_cmd` | `std_msgs/Float32` | pub | Computed torque — remap to cable control node |
| `~/ext_torque_enable` | `std_msgs/Bool` | pub | Arm/disarm signal — remap to cable control node |
| `~/debug` | `std_msgs/Float64MultiArray` [tau, e_v, e_p, v_c, p_c, acc_ref, 0.0, tau_d_hat] | pub | Live control variables (index 6 unused/reserved) |
| `~/ude_disturbance` | `std_msgs/Float64` | pub | UDE estimated disturbance `tau_d_hat` (N·m) |

### Services

| Service | Purpose |
|---|---|
| `~/arm` | Publishes `ext_torque_enable=true` (STANDBY → RUNNING); GUI must have already called `enable_external_mode` |
| `~/disarm` | Publishes `ext_torque_enable=false`, resets UDE state (RUNNING → STANDBY) |

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `drum_radius` | `0.0175` m | Must match cable control node |
| `mass` | `0.565` kg | Payload mass |
| `kp_c` | `8.0` 1/m | Cable position error gain |
| `kd_c` | `20.0` s/m | Cable velocity error gain |
| `sat_upper` | `1.5` N.m | Torque saturation upper bound |
| `sat_lower` | `-1.5` N.m | Torque saturation lower bound |
| `ude_lambda` | `10.0` rad/s | UDE bandwidth — higher = faster estimation, more noise |
| `ude_inertia` | `0.001` kg·m² | Motor moment of inertia J |
| `ude_integral_limit` | `0.06` N·m | Anti-windup clamp: frozen when `\|λ × integral_term\| > limit` |
| `poll_rate_hz` | `100.0` Hz | Control loop rate |
| `reference_timeout_ms` | `500.0` ms | Fall back to gravity hold if reference goes stale |

### How to run

**Terminal 1 — cable control node (already running):**

```bash
ros2 launch ak_motor_driver cable_control.launch.py
```

**Terminal 2 — torque controller node:**

```bash
# Default — connects to ak_motor_cable_control_node
ros2 launch ak_motor_driver cable_torque_ctrl.launch.py

# Custom cable control node name
ros2 launch ak_motor_driver cable_torque_ctrl.launch.py cable_ctrl_node:=my_cable_node
```

All topic remapping to the cable control node is handled inside the launch file.

**Terminal 3 — enable the motor (GUI or CLI):**

```bash
ros2 service call /ak_motor_cable_control_node/enable std_srvs/srv/Trigger
```

**Terminal 4 — GUI opens external mode (outer gate: OFF → STANDBY):**

The GUI calls `enable_external_mode`. Confirm STANDBY:
```bash
ros2 topic echo /ak_motor_cable_control_node/ext_mode_state --once
# expected: data: standby
```

**Terminal 5 — arm the torque controller (inner gate: STANDBY → RUNNING):**

```bash
ros2 service call /cable_torque_ctrl_node/arm std_srvs/srv/Trigger
```

Without a `~/reference` message the node outputs gravity hold: `tau = mass × drum_radius × g ≈ 0.052 N·m` (with default params).

**Check the controller is running:**

```bash
# Control mode should read "external"
ros2 topic echo /ak_motor_cable_control_node/control_mode --once

# Watch live control variables: [tau, e_v, e_p, v_c, p_c, acc_ref, 0.0, tau_d_hat]
ros2 topic echo /cable_torque_ctrl_node/debug

# Watch UDE disturbance estimate
ros2 topic echo /cable_torque_ctrl_node/ude_disturbance
```

**Send a reference** (acc_ref m/s², v_c_star m/s, p_c_star m — same sign as GUI `~/cable_state`):

```bash
# Position hold at zero
ros2 topic pub -r 50 /cable_torque_ctrl_node/reference \
  std_msgs/msg/Float64MultiArray "{data: [9.81, 0.0, 0.0]}"

# Hold 5 cm extended (cable longer, payload lower) — positive matches GUI
ros2 topic pub -r 50 /cable_torque_ctrl_node/reference \
  std_msgs/msg/Float64MultiArray "{data: [9.81, 0.0, 0.05]}"

# Hold 5 cm retracted (cable shorter, payload higher) — negative matches GUI
ros2 topic pub -r 50 /cable_torque_ctrl_node/reference \
  std_msgs/msg/Float64MultiArray "{data: [9.81, 0.0, -0.05]}"
```

> **Sign convention for `~/reference`:** `v_c_star` and `p_c_star` use the **same** sign as `~/cable_state` (cable-length convention: positive = extended/extending). The number you send matches what the GUI displays. The node converts to the internal retraction convention internally.

**Waveform reference nodes** (launch in a separate terminal while the torque controller is running and armed):

| Node | Launch file | Config file | Trajectory |
|---|---|---|---|
| Sinusoidal | `cable_sine_ref.launch.py` | `config/cable_sine_ref_params.yaml` | `p = A·sin(2πft)`, with velocity + acc feedforward |
| Square wave | `cable_square_ref.launch.py` | `config/cable_square_ref_params.yaml` | `p = ±A` toggled at `f` Hz, adjustable duty cycle |
| Triangular | `cable_triangle_ref.launch.py` | `config/cable_triangle_ref_params.yaml` | `p` ramps linearly ±A each half period, velocity feedforward |

```bash
# Sine wave (default: 0.5 Hz, ±0.1 m)
ros2 launch ak_motor_driver cable_sine_ref.launch.py

# Square wave (default: 0.2 Hz, ±0.15 m, 50% duty)
ros2 launch ak_motor_driver cable_square_ref.launch.py

# Triangular wave (default: 0.3 Hz, ±0.15 m)
ros2 launch ak_motor_driver cable_triangle_ref.launch.py
```

Edit the corresponding config file to change frequency, amplitude, or duty cycle before launching. All nodes remap `~/reference` to `/cable_torque_ctrl_node/reference` automatically.

**Record a calibration bag** (run in a separate terminal while the controller is armed):

```bash
ros2 bag record \
  /ak_motor_cable_control_node/ext_torque_cmd \
  /ak_motor_cable_control_node/cable_state \
  /cable_torque_ctrl_node/ude_disturbance \
  /cable_torque_ctrl_node/reference \
  -o calibration_bag
```

| Topic | Type | Content |
|---|---|---|
| `ext_torque_cmd` | `Float32` | Commanded torque (N·m), positive = retract |
| `cable_state` | `Float32MultiArray` | `[length_m, velocity_m_s]`, cable-state convention |
| `ude_disturbance` | `Float64` | `tau_d_hat` (N·m) |
| `reference` | `Float64MultiArray` | `[acc_ref, v_c_star, p_c_star]`, cable-state convention |

Bags are saved to the current working directory as a folder named `calibration_bag/`. Use an absolute path (e.g. `-o ~/bags/calibration_bag`) to control the location.

**Disarm (inner gate: RUNNING → STANDBY):**

```bash
ros2 service call /cable_torque_ctrl_node/disarm std_srvs/srv/Trigger
```

**GUI then closes external mode (outer gate: STANDBY → OFF) via `ext_mode_cmd="off"`.**

## Differential drive wheeled robot (2 × AK40-10)

`diff_drive_node` drives **two motors on one CAN bus** (default left = ID 1, right = ID 2)
in velocity mode (`kp=0, kd=kd_drive`) from a single node — forward, backward, pivot
turns and stop for a two-wheel robot.

```bash
ros2 launch ak_motor_driver diff_drive.launch.py can_interface:=slcan0   # or can0
```

**Five motion commands** (latched — one publish keeps the robot moving until the next):

```bash
./scripts/drive.sh enable      # both motors → MIT mode (do once)
./scripts/drive.sh forward     # linear_speed preset (m/s)
./scripts/drive.sh backward
./scripts/drive.sh left        # pivot turn in place, turn_speed preset (rad/s)
./scripts/drive.sh right
./scripts/drive.sh stop        # zero-velocity hold
./scripts/drive.sh disable     # ALWAYS the last command
```

**Standard ROS interface** also works — `~/cmd_vel` (`geometry_msgs/Twist`,
`linear.x` m/s + `angular.z` rad/s). Keyboard teleop with **no extra packages**:

```bash
ros2 run ak_motor_driver teleop_drive.py     # w/s/a/d move, x stop, q quit
```

(Prefer the stock package? `sudo apt install ros-<distro>-teleop-twist-keyboard`, then
`ros2 run teleop_twist_keyboard teleop_twist_keyboard_node --ros-args -r cmd_vel:=/diff_drive_node/cmd_vel`.)

Fresh `cmd_vel` overrides the latched `move_cmd`; when `cmd_vel` goes stale
(`command_timeout_ms`, default 500 ms) the node falls back to the latched command —
publish `stop` (or `./scripts/drive.sh stop`) to park.

**Kinematics:** `v_wheel = (linear.x ∓ angular.z·track_width/2) / wheel_radius`,
motor speed = wheel speed × `gear_ratio` (AK40-10 = 10:1). Measure `wheel_radius`
and `track_width` on your chassis in `config/diff_drive_params.yaml`.

**First-run wheel direction check:** `enable` → `forward` → both wheels must roll
forward. If one rolls backward, set `invert_left: true` or `invert_right: true` in
`config/diff_drive_params.yaml` (mirrored motor mounts), rebuild-free — just relaunch.

| Parameter | Default | Meaning |
|---|---|---|
| `motor_id_left` / `motor_id_right` | `1` / `2` | CAN IDs of the two actuators |
| `wheel_radius` | `0.1` m | wheel radius |
| `track_width` | `0.4` m | wheel centre-to-centre |
| `gear_ratio` | `10.0` | motor rad/s per wheel rad/s |
| `linear_speed` / `turn_speed` | `0.5` / `1.0` | presets for move_cmd strings |
| `kd_drive` | `0.5` | velocity-mode damping on both wheels |
| `invert_left` / `invert_right` | `false` | flip mirrored motor mounts |
| `command_timeout_ms` | `500` | stale cmd_vel → fall back to latched move_cmd |
| `temp_limit_c` | `75` | either motor overtemp → **both** auto-disable |

Feedback: `~/joint_state` (names `wheel_left`, `wheel_right`: position rad,
velocity rad/s, torque Nm) and `~/temperature` (`[left, right]` °C). The node sends
exit-MIT to both motors on `disable` and on shutdown.

**If only one motor enables (one green LED):** test motor 2 directly on the bus:

```bash
./scripts/drive.sh disable
candump slcan0 &                       # watch the bus (terminal A)
cansend slcan0 002#FFFFFFFFFFFFFFFC    # ask motor 2 to enter MIT (terminal B)
```

- Reply `002 [8] 02 …` → motor 2 is alive at ID 2: re-enable and watch
  `ros2 topic echo /diff_drive_node/joint_state` (both wheels must appear).
- **No reply** → one of: (a) motor 2's CAN ID is not 2 — power motor 2 *alone* and
  `cansend slcan0 001#FFFFFFFFFFFFFFFC`; if it answers, it is still ID 1: re-flash the
  ID to 2 with CubeMarsTool/R-Link. (b) daisy-chain wiring — the bus must run
  adapter → motor 1 pins 1/2, then **motor 1 pins 3/4 → motor 2 pins 1/2**
  (pins 3/4 are the daisy-chain duplicates). (c) motor 2 power or CAN stub loose.
- Termination belongs only at the two physical ends of the chain (adapter DIP switch
  ON + 120 Ω at motor 2). The mid-bus motor 1 must **not** be terminated.

## Control modes

The MIT protocol computes output torque as:

```
tau = kp*(p_des - p) + kd*(v_des - v) + t_ff
```

Three modes are available by choosing `kp` and `kd`:

| Mode | kp | kd | Active field | Example use |
|---|---|---|---|---|
| Position hold | >0 | >0 | `position` | Go to angle, hold |
| Velocity tracking | 0 | >0 | `velocity` | Spin at constant speed |
| Torque direct | 0 | 0 | `effort` | Slung load force control |

**Important:** with `kp>0` (the default), publishing a non-zero `velocity` has little effect — the position error term dominates. Switch to velocity or torque mode by zeroing `kp` first:

```bash
# Switch to velocity mode
ros2 param set /ak_motor_node kp 0.0
ros2 param set /ak_motor_node kd 1.0
ros2 topic pub --rate 50 /ak_motor_node/command sensor_msgs/msg/JointState \
  "{name: ['ak40_10'], position: [0.0], velocity: [-0.1], effort: [0.0]}"

# Switch to torque-direct mode
ros2 param set /ak_motor_node kp 0.0
ros2 param set /ak_motor_node kd 0.0
ros2 topic pub --rate 50 /ak_motor_node/command sensor_msgs/msg/JointState \
  "{name: ['ak40_10'], position: [0.0], velocity: [0.0], effort: [1.0]}"
```

## Debugging

Verify raw CAN traffic:

```bash
candump can0      # gs_usb / candleLight firmware
candump slcan0    # MKS CANable stock slcan firmware
```

Verify node is subscribed to commands:

```bash
ros2 topic info /ak_motor_node/command   # Subscription count should be 1
```

Check current gains:

```bash
ros2 param get /ak_motor_node kp
ros2 param get /ak_motor_node kd
```
