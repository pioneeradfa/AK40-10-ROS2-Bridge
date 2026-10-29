# Raspberry Pi 5 + MKS CANable V2.0 Pro + AK40-10 — verified quickstart

**Verified 2026-10-29** on: Raspberry Pi 5 · Raspberry Pi OS Bookworm (Debian 12, arm64) ·
ROS 2 **Humble** · MKS Makerbase **CANable V2.0 Pro** (stock *slcan* firmware,
`lsusb` = `16d0:117e MCS CANable2 b158aa7`) · CubeMars **AK40-10** in MIT mode, CAN ID 1.

Everything below was run end-to-end on that rig. The long-form guide (Ubuntu/Jazzy path,
candleLight flashing, systemd units, full troubleshooting) is
[`doc/raspberry_pi5_akcan40.md`](doc/raspberry_pi5_akcan40.md).

---

## 1. Wiring

![diagram](doc/media/connection_diagram_pi5_canable_ak40.svg)

| Wire | From → To |
|---|---|
| USB | Pi USB-A → CANable plug |
| CAN_H | CANable `CANH` → driver board CAN connector **pin 2** |
| CAN_L | CANable `CANL` → driver board CAN connector **pin 1** (pins 3/4 open) |
| 24 V+ | PSU V+ → XT30 **pin 2** |
| 24 V− | PSU V− → XT30 **pin 1** |
| GND | Pi GPIO pin 6 **+** CANable `GND` → PSU V− (one star point) |
| 120 Ω ×2 | CANable **120R DIP switch ON** + resistor across CAN_H–CAN_L at motor end |

Motor supply: 24 V, separate from the Pi's 5 V USB-C PSU. Power the motor **before**
any CAN traffic.

## 2. Install (Pi OS Bookworm + Humble, as verified)

```bash
sudo apt install -y git build-essential python3-colcon-common-extensions can-utils

mkdir -p ~/ros2_ws/src && cd ~/ros2_ws/src
git clone -b arena/280682f6-ak40-10-ros2-bridge \
  https://github.com/pioneeradfa/AK40-10-ROS2-Bridge.git ak_motor_driver
cd ~/ros2_ws
colcon build --packages-select ak_motor_driver
echo "source ~/ros2_ws/install/setup.bash" >> ~/.bashrc
source ~/.bashrc
```

The package builds unmodified on Humble (deps: `rclcpp`, `sensor_msgs`, `std_msgs`,
`std_srvs`). Ubuntu 24.04 + Jazzy works identically with apt binaries.

## 3. Bring up CAN (adapter stock firmware → `slcan0`)

```bash
cd ~/ros2_ws/src/ak_motor_driver
sudo ./scripts/setup_can_pi5.sh        # detects /dev/ttyACM0 → brings up slcan0 @ 1 Mbps
ip -details link show slcan0           # expect state UP
```

Manual equivalent: `sudo slcand -o -c -f -s8 /dev/ttyACM0 slcan0 && sudo ip link set slcan0 txqueuelen 1000 && sudo ip link set slcan0 up`.
Boot persistence: `slcan0.service` systemd unit — doc §10(a).
After flashing candleLight firmware the board becomes native `can0` and
`setup_can_pi5.sh --persist` covers it — doc §10(b).

## 4. Connection test (no ROS)

```bash
candump slcan0                        # terminal A
cansend slcan0 001#FFFFFFFFFFFFFFFC   # terminal B — enter MIT mode
```

**Pass:** terminal A shows a reply on ID `001` with `data[0] = 01`
(e.g. `001 [8] 01 7F E2 80 00 18 5A 00`; `data[6]−40` = motor °C). Then
`cansend slcan0 001#FFFFFFFFFFFFFFFD` to exit.
⚠️ Never send `…FE` as a test — it overwrites the encoder zero in motor flash.

## 5. Run the motor — one command

```bash
./scripts/run_motor.sh pos 1.0        # move to 1.0 rad & hold (green LED on)
./scripts/run_motor.sh speed 0.5      # spin at 0.5 rad/s
./scripts/run_motor.sh speed -0.5 20  # timed run: 20 s then auto-disable
```

The script: sources ROS 2 + workspace → picks `slcan0`/`can0`/`can1` (runs CAN setup
itself if none is up) → launches `cable_control.launch.py` → publishes `~/command` at
50 Hz **before** `~/enable` → prints the enable response. **Ctrl+C disables the motor
first**, then stops everything. Run it **without sudo**.

Manual multi-terminal sequence (equivalent): launch → publish `~/command` →
`ros2 service call /ak_motor_cable_control_node/enable std_srvs/srv/Trigger` →
drive → `.../disable` → Ctrl+C.

## 6. Signs of normal operation

| Observation | Meaning |
|---|---|
| Driver-board LED green while enabled | healthy, motor in MIT mode tracking commands |
| `ros2 topic hz .../joint_state` ≈ 100 Hz | feedback path OK (MIT = request/response) |
| `disable` → `success=True, 'Motor disabled'`, LED off, shaft free | exit-MIT sent; correct, not a fault |
| `joint_state` silent after disable | expected — no command frames, no replies |

## 7. If it misbehaves (top 5)

| Symptom | Fix |
|---|---|
| No `can0`/`slcan0` | `ls /dev/ttyACM*`; run `setup_can_pi5.sh`; check `lsusb` for `16d0:117e` |
| No reply to `…FC` | motor 24 V on? H/L swap? 2 × 120 Ω? common GND? |
| Error frames / bus-off | termination; `ip -details -statistics link show slcan0`; down/up to recover |
| `COLCON_TRACE: unbound variable` | old `run_motor.sh` — `git pull` (fixed in commit `6429714`) |
| Topics invisible from another machine | same `ROS_DOMAIN_ID`, same subnet; Wi-Fi power-save off |

Full table + slcan/candleLight details: [`doc/raspberry_pi5_akcan40.md` §10](doc/raspberry_pi5_akcan40.md).
