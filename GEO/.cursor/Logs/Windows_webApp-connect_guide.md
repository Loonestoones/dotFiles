# Windows 11 → MFCB Web App: One-Time Connect Guide

Windows counterpart of `Arch-linux_webApp-connect_guide.md`: reach the MFCB
board's web UI from a Windows 11 laptop over Ethernet/PoE using
PowerShell or cmd, and restore the adapter to DHCP afterwards.

Unlike Linux `ip addr add`, **Windows IP settings persist across reboots**,
so the cleanup step is not optional if you want the port back on normal
networks later.

## Background

- Board factory network settings (`how_to_use_network_mechanism.txt`):
  - IP: `10.0.1.30`
  - Mask: `255.255.255.0` (`/24`)
  - Gateway: `10.0.1.1`
  - DNS: `8.8.8.8` / `9.9.9.9`
- Web UI is served by CM7 over LwIP after boot — allow ~20s after power-up.
- Connect to the board's **PoE+ in** Gigabit RJ45 port (there's also a
  PoE+ **out** port for daisy-chaining — don't confuse the two).
- Changing adapter IPs normally requires elevation. See
  [One-time prep for working without admin rights](#one-time-prep-for-working-without-admin-rights)
  below — do it **now, while you still have admin**.

## Steps (PowerShell)

Run elevated ("Run as administrator"), or non-elevated if you did the
no-admin prep.

### 1. Find your Ethernet interface

```powershell
Get-NetAdapter
```

Plug in the cable and look for the adapter whose `Status` turns `Up`
(e.g. `Ethernet`, or `Ethernet 2` for a USB adapter). Use its `Name`
below; these examples assume `Ethernet`.

### 2. Assign an IP on the board's subnet

```powershell
Set-NetIPInterface -InterfaceAlias "Ethernet" -Dhcp Disabled
New-NetIPAddress  -InterfaceAlias "Ethernet" -IPAddress 10.0.1.50 -PrefixLength 24
```

Any host address in `10.0.1.0/24` other than `.30` (board) and `.1`
(gateway) works. Disabling DHCP first avoids the adapter holding two
conflicting configs.

### 3. Verify connectivity

```powershell
ping 10.0.1.30
Test-NetConnection 10.0.1.30 -Port 80   # also checks the web server itself
```

### 4. Open the web app

```
http://10.0.1.30
```

### 5. Clean up when done

```powershell
Remove-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 10.0.1.50 -Confirm:$false
Set-NetIPInterface  -InterfaceAlias "Ethernet" -Dhcp Enabled
ipconfig /renew
```

## Steps (cmd / netsh)

Same flow, works in a plain cmd window. This is also the variant that
works **non-elevated** for members of *Network Configuration Operators*.

```cmd
:: 1. find the interface name
netsh interface show interface

:: 2. set static IP (replace "Ethernet" with your interface name)
netsh interface ip set address "Ethernet" static 10.0.1.50 255.255.255.0

:: 3. verify
ping 10.0.1.30

:: 4. browse to http://10.0.1.30

:: 5. clean up — back to DHCP
netsh interface ip set address "Ethernet" dhcp
```

## One-time prep for working without admin rights

Admin rights on this laptop are temporary. Do one (or both) of these
while elevation is still available:

### Option A — Network Configuration Operators group (recommended)

```cmd
net localgroup "Network Configuration Operators" %USERNAME% /add
```

Log out and back in. Members of this built-in group may change TCP/IP
settings without admin — the `netsh` commands above then work in a
normal, non-elevated cmd/PowerShell window. (The classic adapter
properties GUI via `ncpa.cpl` works too.)

Caveat: on a domain-managed laptop, Group Policy can strip local group
memberships at policy refresh — verify it survives a few days/reboots.

### Option B — permanent secondary IP

If the Ethernet port is used for the board often, add `10.0.1.50/24` as
a *second* address so it coexists with DHCP and nothing ever needs
changing again:

`ncpa.cpl` → adapter → Properties → IPv4 → Advanced → IP addresses → Add
(requires the adapter to be on static config), or keep DHCP and use
Option A to add/remove the address on demand.

### Option C — NetSetMan

Install [NetSetMan](https://www.netsetman.com/) (freeware) **with its
service enabled** during setup. The service applies changes with system
rights, so profile switching ("MFCB 10.0.1.50" ↔ "DHCP office") works
later as a standard user from the tray.

## Troubleshooting

- **`New-NetIPAddress` / `netsh` says access denied** — you're neither
  elevated nor in Network Configuration Operators (re-login required
  after adding).
- **Ping fails right after power-up** — wait ~20s for CM7/LwIP to boot,
  and check you're on the PoE+ **in** port.
- **Two IPs / flaky connectivity** — DHCP was left enabled alongside the
  static address; run the cleanup step and start over.
- **Corporate firewall blocks it** — Windows Defender Firewall may treat
  the link as a Public network; ping (ICMP) can be blocked while
  `http://10.0.1.30` still works. Trust the browser test over ping.
