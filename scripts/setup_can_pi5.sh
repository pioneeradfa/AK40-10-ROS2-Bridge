#!/bin/bash
# Bring up the CubeMars AKCAN40 USB-CAN adapter on Raspberry Pi 5 (default can0).
# Run once after every reboot: sudo ./scripts/setup_can_pi5.sh
#
# The Raspberry Pi 5 has no on-board CAN controller. The AKCAN40 dongle
# enumerates through the in-kernel gs_usb driver as can0 -- no manual module
# build is needed (unlike Jetson Orin, whose Tegra kernel lacks gs_usb).
#
# Usage:
#   sudo ./scripts/setup_can_pi5.sh                  # bring up can0 now
#   sudo ./scripts/setup_can_pi5.sh can1             # bring up a specific interface
#   sudo ./scripts/setup_can_pi5.sh --persist        # also auto-configure on boot/hotplug
#   sudo ./scripts/setup_can_pi5.sh can0 --persist   # both
#
# Full guide: doc/raspberry_pi5_akcan40.md

set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run with sudo" >&2
  exit 1
fi

CAN_IF="can0"
PERSIST=0
for arg in "$@"; do
  case "$arg" in
    --persist) PERSIST=1 ;;
    can*)      CAN_IF="$arg" ;;
    *)         echo "ERROR: unknown argument '$arg' (expected canX interface name or --persist)" >&2
               exit 1 ;;
  esac
done

# Load gs_usb if not already present (ships with the Pi kernel and normally
# auto-loads when the dongle is plugged in)
if ! lsmod | grep -q '^gs_usb'; then
  echo "Loading gs_usb module..."
  modprobe gs_usb || echo "WARN: modprobe gs_usb failed -- your adapter may enumerate as a serial device; see the slcan fallback in doc/raspberry_pi5_akcan40.md" >&2
fi

# USB enumeration can lag module load / plug-in -- wait up to ~5 s
for _ in 1 2 3 4 5; do
  ip link show "$CAN_IF" >/dev/null 2>&1 && break
  sleep 1
done

if ! ip link show "$CAN_IF" >/dev/null 2>&1; then
  echo "ERROR: interface '$CAN_IF' not found." >&2
  echo "Hints:" >&2
  echo "  lsusb                          # is the adapter visible on USB?" >&2
  echo "  ls /dev/ttyACM* /dev/ttyUSB*   # serial-enumerating adapter? use the slcan fallback" >&2
  echo "  dmesg | tail -30               # kernel messages" >&2
  exit 1
fi

# Bring interface down cleanly before reconfiguring (ignore error if already down)
ip link set "$CAN_IF" down 2>/dev/null || true

ip link set "$CAN_IF" type can bitrate 1000000
ip link set "$CAN_IF" txqueuelen 1000   # kernel default (10) is small at 1 Mbps / 100 Hz
ip link set "$CAN_IF" up

if [ "$PERSIST" -eq 1 ]; then
  echo "Installing boot / hotplug persistence..."
  # Auto-load the driver on every boot
  echo "gs_usb" > /etc/modules-load.d/gs_usb.conf
  # Configure any can* interface at 1 Mbps the moment it appears (boot or hotplug)
  cat > /etc/udev/rules.d/99-akcan40-can.rules << 'EOF'
# AKCAN40 / gs_usb CAN adapters: configure at 1 Mbps whenever a can* interface appears
SUBSYSTEM=="net", ACTION=="add", KERNEL=="can*", RUN+="/usr/sbin/ip link set %k txqueuelen 1000", RUN+="/usr/sbin/ip link set %k type can bitrate 1000000", RUN+="/usr/sbin/ip link set %k up"
EOF
  udevadm control --reload-rules
  echo "  installed /etc/modules-load.d/gs_usb.conf"
  echo "  installed /etc/udev/rules.d/99-akcan40-can.rules"
fi

echo "$CAN_IF is up:"
ip link show "$CAN_IF"
