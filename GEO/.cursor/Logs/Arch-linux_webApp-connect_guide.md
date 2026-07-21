# Arch Linux → MFCB Web App: One-Time Connect Guide

Non-persistent way to reach the MFCB board's web UI from an Arch Linux
laptop over Ethernet/PoE, without saving a NetworkManager profile (so it
doesn't interfere with connecting to other networks/devices later).

## Background

- Board factory network settings (`how_to_use_network_mechanism.txt`):
  - IP: `10.0.1.30`
  - Mask: `255.255.255.0` (`/24`)
  - Gateway: `10.0.1.1`
  - DNS: `8.8.8.8` / `9.9.9.9`
- Web UI is served by CM7 over LwIP after boot — allow ~20s after power-up.
- Connect to the board's **PoE+ in** Gigabit RJ45 port (there's also a
  PoE+ **out** port for daisy-chaining — don't confuse the two).

## Steps

### 1. Find your Ethernet interface
```bash
ip link
```
Look for the NIC with `UP,LOWER_UP` after plugging in (e.g. `enp198s0f0u2u4`
for a USB adapter, `eth0`/`enp3s0` for onboard).

### 2. Temporarily assign an IP on the board's subnet
```bash
sudo ip addr add 10.0.1.50/24 dev <iface>
```
Any host address in `10.0.1.0/24` other than `.30` (board) and `.1`
(gateway) works.

### 3. Verify connectivity
```bash
ping -c 3 10.0.1.30
```

### 4. Open the web app
```
http://10.0.1.30
```

### 5. Clean up when done
```bash
sudo ip addr del 10.0.1.50/24 dev <iface>
```
Unplugging the cable also clears it, but running this explicitly is cleanest.

## If NetworkManager fights the manual IP

If NetworkManager is actively managing the interface, it may also try to
pull a DHCP lease, resulting in two IPs / flaky connectivity. Hand the
interface off first:

```bash
sudo nmcli device set <iface> managed no
sudo ip addr add 10.0.1.50/24 dev <iface>
# ... use the web app ...
sudo ip addr del 10.0.1.50/24 dev <iface>
sudo nmcli device set <iface> managed yes
```

Fully reversible — nothing persists for the next time you plug into a
different network.
