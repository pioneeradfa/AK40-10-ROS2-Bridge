# Differential-drive rig — full terminal runbook

Rig as verified: Raspberry Pi 5 · Raspberry Pi OS Bookworm · ROS 2 Humble ·
MKS CANable V2.0 Pro (stock slcan firmware → `/dev/ttyACM0` → `slcan0`) ·
2 × AK40-10, **left = CAN ID 1, right = CAN ID 6** · workspace `~/diff_can_ak40_ros2`.

Copy-paste order below. `#>` marks expected output.

---

## Zero-juggling session (recommended)

```bash
cd ~/diff_can_ak40_ros2
./scripts/robot_up.sh        # CAN up -> launch in background -> enable (standstill)
./scripts/drive.sh forward   # ... drive words, or teleop:
ros2 run ak_motor_driver teleop_drive.py
./scripts/robot_down.sh      # stop -> disable -> kill launch; then cut 24 V
```

`robot_up.sh` logs the node to `/tmp/diff_drive.log` (`tail -f` it) and reuses a
running launch if present. Everything below is the same sequence spelled out
per terminal, for when you want the windows open.

---

## Terminal 1 — CAN interface (once per boot)

```bash
ls /dev/ttyACM*                      #> /dev/ttyACM0  (CANable stock firmware)
cd ~/diff_can_ak40_ros2
sudo ./scripts/setup_can_pi5.sh      #> found serial CAN adapter ... slcan0 is up
ip -details link show slcan0         #> state UP ... bitrate 1000000
```

If `slcan0` already exists (systemd unit installed), the script reuses it.

## Terminal 1 — launch the driver

```bash
source install/setup.bash            # skip if already in ~/.bashrc
ros2 launch ak_motor_driver diff_drive.launch.py can_interface:=slcan0
#> CAN interface 'slcan0' opened (left id=1, right id=6)
#> Sent exit-MIT-mode to both motors (motors safe)
```

Leave this terminal running.

## Terminal 2 — bus sanity (first time / after any wiring change)

```bash
candump slcan0                       # watch the bus; leave running
```

## Terminal 3 — raw motor check (optional, mirrors Terminal 2)

```bash
cansend slcan0 001#FFFFFFFFFFFFFFFC  #> Terminal 2 shows reply: 001 [8] 01 ...
cansend slcan0 001#FFFFFFFFFFFFFFFD
cansend slcan0 006#FFFFFFFFFFFFFFFC  #> reply: 006 [8] 06 ...   (right motor at ID 6)
cansend slcan0 006#FFFFFFFFFFFFFFFD
```

No reply on an ID → that motor is unpowered, mis-wired (H/L swap), or carries a
different ID (isolate it and re-flash the ID with CubeMarsTool).

## Terminal 3 — enable and drive

```bash
./scripts/drive.sh enable            #> 'Both motors enabled ... standstill until move_cmd'
                                     #   both driver-board LEDs green; robot holds still
./scripts/drive.sh forward           # robot rolls forward
./scripts/drive.sh stop              # zero-velocity hold
./scripts/drive.sh backward
./scripts/drive.sh stop
./scripts/drive.sh left              # pivot turn in place
./scripts/drive.sh stop
./scripts/drive.sh right
./scripts/drive.sh stop
./scripts/drive.sh disable           #> 'Both motors disabled' — LEDs off, wheels free
```

`move_cmd` is latched: each word keeps the robot moving until the next word.
Note each `drive.sh` invocation costs a few seconds (ros2 CLI startup on the Pi,
source-build Humble) — fine for scripted sequences; use `teleop_drive.py` for
reactive driving.

## Terminal 3 — keyboard teleop (alternative to drive.sh)

```bash
ros2 run ak_motor_driver teleop_drive.py
#  w forward · s backward · a left · d right · x stop · q quit
```

## Terminal 4 — monitoring (any time)

```bash
ros2 topic echo /diff_drive_node/joint_state    # wheel_left + wheel_right pos/vel/torque
ros2 topic echo /diff_drive_node/temperature    # [left, right] °C
ros2 topic echo /diff_drive_node/cmd_vel        # what teleop is sending
```

## One-time calibration

1. **Wheel directions:** `enable` → `forward`. Any wheel rolling backward →
   edit `config/diff_drive_params.yaml` (`invert_left: true` / `invert_right: true`),
   then `colcon build --packages-select ak_motor_driver` (re-installs the config)
   and relaunch.
2. **Geometry:** measure and set `wheel_radius` (m) and `track_width` (m, wheel
   centre-to-centre) in the same file; rebuild + relaunch. Turns are only true after this.
3. **Speeds:** `linear_speed` (m/s) and `turn_speed` (rad/s) set the drive.sh presets.

## Shutdown (always in this order)

```bash
./scripts/drive.sh stop
./scripts/drive.sh disable           # exit-MIT on both motors
# Terminal 3: q / Ctrl+C teleop if running
# Terminal 1: Ctrl+C the launch        #> process has finished cleanly
# then switch the 24 V motor supply off
```

## After a reboot — minimum path

```bash
sudo ./scripts/setup_can_pi5.sh
ros2 launch ak_motor_driver diff_drive.launch.py can_interface:=slcan0
./scripts/drive.sh enable
```

(Install `slcan0.service` per guide §10(a) and the CAN step disappears entirely.)

## LEDs green but the robot does not move

A green LED only means "motor is in MIT mode" — it stays green even with the
node stopped (MIT latches until exit-MIT or power-off). Work the tree:

**1) Did `forward` reach the node?** The node logs every latched command.

```bash
# launch running in a terminal -> look for this line after drive.sh forward:
#> [INFO] [diff_drive_node]: move_cmd 'forward' (x=0.50 m/s, z=0.00 rad/s)
grep move_cmd /tmp/diff_drive.log        # if started via robot_up.sh
ros2 node list                           #> /diff_drive_node  (missing = node not running!)
echo $ROS_DOMAIN_ID                      # must match in BOTH terminals (launch + drive)
```

No log line → the message never arrived: relaunch the node
(`./scripts/robot_up.sh`), check domain IDs, don't run `drive.sh` under sudo.

**Never run `run_motor.sh` (or anything else streaming MIT frames) at the same
time as the diff-drive node.** Both write to motor 1: the cable-control node
holds it in position mode while diff-drive commands velocity — the commands
fight at 100 Hz each and the wheel can sit still. `Ctrl+C` the single-motor
test first (it exits MIT, LED off — normal), then start the diff-drive session.
After any `git pull`, rebuild first: `colcon build --packages-select ak_motor_driver`.

**2) Is the node putting non-zero velocity on the bus?** Watch while commanding:

```bash
candump slcan0 &                         # then, other terminal: ./scripts/drive.sh forward
```

| State | Frames from `001` and `006` (100 Hz stream) |
|---|---|
| standstill (enabled) | `7F FF 7F F0 00 19 97 FF`  (v = 0) |
| `forward` latched | `7F FF FF F0 00 19 97 FF`  (v = +45.5 rad/s, kd = 0.5) |
| `backward` latched | `7F FF 00 00 00 19 97 FF`  (v = −45.5 rad/s) |

Frames flip to `FF F0` but wheels stay still → motor power stage: check the
24 V supply under load (current limit?), `ros2 topic echo /diff_drive_node/joint_state`
feedback velocity stays 0 while commanded ≠ 0 confirms it. Go to step 3.

**3) Raw motor test — bypass ROS entirely.** Kill the node first (its shutdown
sends exit-MIT), then re-enter MIT and spin by hand. ⚠ Wheels off the ground:

```bash
cansend slcan0 001#FFFFFFFFFFFFFFFC      # enter MIT (LED green)
cansend slcan0 001#7FFFFFF0001997FF      # RUN at +45.5 rad/s target -> wheel spins up
cansend slcan0 001#7FFF7FF0001997FF      # stop (v = 0)
cansend slcan0 001#FFFFFFFFFFFFFFFD      # exit MIT when done
```

Spins raw but not via the node → ROS-side (steps 1–2). Does not spin raw →
power/wiring/motor state; each command must get a reply `001 [8] 01 ...` in
candump — no reply means the frame is not being ACKed (bus/termination/ID).

## Quick fault reference

| Symptom | First check |
|---|---|
| `slcan0` missing | `ls /dev/ttyACM*`, re-run setup script, `lsusb` for `16d0:117e` |
| One LED on enable | raw check on that motor's ID (§ Terminal 3); ID mismatch → CubeMarsTool |
| LEDs green, no movement | § LEDs green but the robot does not move — 3-step tree (node alive? frames non-zero? raw spin test?) |
| Single-motor test works, diff-drive doesn't | Don't run both at once (both stream MIT frames to motor 1 → fight); `Ctrl+C` run_motor.sh, `colcon build`, then `./scripts/robot_up.sh` |
| No reply on any ID | motor PSU on? H/L swap? daisy-chain = motor 1 pins 3/4 → motor 2 pins 1/2 |
| Error frames / bus-off | termination: adapter DIP ON + 120 Ω at far end only; `ip -details -statistics link show slcan0` |
| Robot drifts in "straight" | wheel directions, then `track_width`; unequal tyre wear also pulls |
| `drive.sh forward` does nothing | Node log shows no `move_cmd 'forward'` line → the message never arrived (DDS discovery race, or CLI killed mid-init: `error creating node: the given context is not valid` = timeout too short for source-build Humble on the Pi). Use the current `drive.sh` (4 s burst) or `timeout 5 ros2 topic pub --rate 5 /diff_drive_node/move_cmd std_msgs/msg/String "{data: 'forward'}"`. For reactive control use `teleop_drive.py` (persistent, no per-command startup). |
| Motor hot / stops itself | `temp_limit_c` auto-disable did its job; check `~/temperature`, reduce `kd_drive` load |
