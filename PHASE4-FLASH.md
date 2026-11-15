# Phase 4 — Flash runbook (Nokia G-2425G-A → OpenWrt, LAN-only, no serial)

Status: DRAFT — do not execute without explicit go-ahead.

## Strategy

Flash OpenWrt into the **inactive slot**, never the running one, using the two-slot
dual-image mechanism. All work happens over telnet/LAN with `fwtool`
(static MIPS flasher, already on the ONT at `/tmp/fwtool`, md5-verified, CRC read-back
verified against local dumps).

Slots (from `/proc/mtd`, 128 KiB erasesize):

| Partition | Flash offset | Size | Contents |
|---|---|---|---|
| `bootloader` (mtd0) | 0x0 | 0x40000 | CFE (LZMA main body) |
| `romfile` (mtd1) | 0x40000 | 0x40000 | factory defaults |
| `image0` (mtd2) | 0x80000 | 0x2200000 | stock 3FE49362IJHK46 full TRX (CRC-valid) |
| `linux` (mtd3) | 0x2280000 | 0x2200000 | **active** slot, stock 3FE49362JJIJ50 full TRX |
| `rootfs` (mtd4) | 0x4480000 | 0x1e20000 | stock squashfs — stock `/dev/root`, NEVER TOUCH |
| `image_oflt` (mtd9) | 0x6260000 | 0xf00000 | factory OFLT image |
| `flag` (mtd13) / `flagback` (mtd14) | 0x8ba0000 | 0x40000 | boot flags |

OpenWrt image = upstream `tclinux` format, whole-file write to `linux` (mtd3):

```
0x000000  HDR2 header (256 B)
0x000100  kernel, FF-padded
0x400000  UBI blob ("UBI#" magic verified at this offset)
0x960000  end of file (~10 MB); mtd3 remainder erased to FF
```

UBI lands at flash 0x2680000 = DTS `ubi` partition start. The DTS `ubi` partition is
exactly the linux-slot rootfs area (0x2680000..0x4480000, 30 MB) and does NOT include
the stock `rootfs` partition — image0 stays a genuine recovery slot.

## Safety chain (in order of preference)

1. **image0 stock slot** — untouched, CRC-valid, boots via `oflt change_boot_flag`.
   Telnet in IJHK46: telnetd is off by default but the web UI exposes
   `webs/telnet.sh` CGI (`?` — verify CGI path from IJHK46 web pages after booting it);
   `usr/sbin/utelnetd` and dropbear init script both present in the image0 squashfs.
2. **image_oflt** — third factory image, untouched.
3. **CFE recovery** — bootloader has full slot logic (`boot_fail_num`,
   `switch to image 0/1`, dual-image check with red LED) and a built-in HTTP
   upgrade server (`httpd` / `StartMultiUpgrade`) accepting `tclinux.bin`,
   `fits_tclinux.trx`, `tcboot.bin` with CRC validation.
4. Serial console (CH340) — CFE console commands `switchImage`, `flash`, `httpd`.

## Steps

### Phase A — rehearsal (no flashing)

1. From current JJIJ50 telnet: `oflt change_boot_flag` → ONT reboots into image0 (IJHK46).
2. Verify image0: web UI up, telnet obtainable (web CGI), `oflt change_boot_flag` present.
3. Confirmed recovery path in hand before any flash byte is written.

### Phase B — flash (from image0, mtd3 inactive)

1. Laptop: `cd /tmp/opencode/ghimg/econet/en7528 && python3 -m http.server 8000`
   (bind 192.168.1.3, wired to ONT).
2. ONT: `curl -o /tmp/openwrt.trx http://192.168.1.3:8000/openwrt-econet-en7528-nokia_g-2425g-a-squashfs-tclinux.trx`
3. Verify size + md5 vs local.
4. Erase whole slot (kills stale stock UBI data beyond our UBI blob):
   `/tmp/fwtool erase /dev/mtd3 0 0x2200000`
5. Write: `/tmp/fwtool write /dev/mtd3 0 /tmp/openwrt.trx`
6. Verify: `/tmp/fwtool verify /dev/mtd3 0 <file size> /tmp/openwrt.trx`
7. Spot-check CRC32 of first 0x40000 vs local computation.
8. `sync`

### Phase C — switch

1. From image0 telnet: `oflt change_boot_flag` → boots `linux` slot (OpenWrt).
2. OpenWrt first boot: LAN up (eth0-3 bridged LAN, 192.168.1.1), LEDs, `uci` state.
3. If OpenWrt fails to boot: CFE boot_fail mechanism / change_boot_flag back to
   image0 once any shell is reachable; CFE web recovery as last resort.

### Post-flash

- WiFi: MT7603 (2.4G) + MT7663 (5G) via mt76, OTP/eFuse calibration — no EEPROM file.
- Repurpose as repeater: `kmod-mt76`, relayd or WDS, GPON port stays dead.
- sysupgrade: `CI_KERNPART=linux_kernel`, `CI_UBIPART=ubi` (matches DTS).

## Current state

- v2 image (run 43450066303, sha256 `fbd80875d7bcd84ace9651d5773ce7322299a97fcfd01b4abf5ae613997bbeab`,
  md5 `cb82456b5ad0db0ba692290cda462c54`) staged at `/tmp/opencode/flash.trx`; layout
  verified: HDR2 256 B, kernel FF-padded to 0x400000, `UBI#` at 0x400000 (10 MB file);
  differs from v1 (DTS change compiled in). Manifest has kmod-mt7603/mt7615e/
  mt7663-firmware-ap + wpad.
- ONT `curl` → laptop HTTP transfer path validated end-to-end (fwtool round-trip md5 OK).
- `/tmp/fwtool` on ONT: md5 eb0bd1199c11879f2e8a22ae7da01ae8, CRC read-back
  (`40afec1a` for mtd3[0:0x40000]) matches local dump.
- mtd2 + mtd3 stock TRX CRCs both valid; full 15-partition dumps archived locally
  (2 copies), `dumps/` gitignored (contains credentials).
- image0 (IJHK46) squashfs inspected: telnetd off by default but web-toggleable
  (`webs/telnet.sh` CGI), `utelnetd` + dropbear init present, FTP on inetd —
  so switching to image0 is a safe, reversible rehearsal step.

## Update 2026-11-14 — post-flash findings (v2 flashed, CFE reverted)

### Image-slot writes need the stock ioctl sequence (fwtool3)

Plain `MEMERASE` fails with `EINVAL` on image slots (`mtd2`/`mtd3`/`mtd4`) under
BOTH stock kernels; it works on `flag`. The stock `mtd_write` in
`libupgradeimpl.so` wraps erase/write in two custom ioctls:

| ioctl | value | purpose |
|---|---|---|
| `_IOW('M',126,8)` | `0x80084d7e` | begin write/unlock (zeroed 8-byte arg) |
| `_IOW('M',125,8)` | `0x80084d7d` | end write |

`fwtool3` (source: `tmp/fwtool3.c` in the build dir) issues begin → MEMERASE →
pwrite → verify → end. With it, full-slot erase + write + verify works
(10 MB image, whole-file CRC32 on flash verified == local `0dfd64e9`).

### ASB flag layout and CFE boot-fail failover (IMPORTANT)

`flag` struct (64 B at offset 0 of `flag` mtd, both copies `flag`/`flagback`):

| word | name | original value |
|---|---|---|
| 0 | `commit` (committed slot index) | 1 |
| 1 | `next_active` | 1 |
| 2 | `image0_valid` | 1 |
| 3 | `image1_valid` | 1 |
| 4 | `boot_fail_num` | 0 |
| 5 | `active` | 1 |

Followed by two 16-byte version strings (`image0`: `3FE49362IJHK46`,
`image1`: `3FE49362JJIJ50`). `Imagetool show` prints these fields.

CFE boots an uncommitted image a limited number of times; if userspace never
commits it (stock calls `swdl_commit` → `mtk_swdl_write_flags`), the loader
**marks the image invalid and reverts to the committed slot**. Observed on
hardware: after the v2 OpenWrt flash, the ONT boot-looped for hours and then
came back up in stock IJHK46 on its own:

```
commit =[0]  next_active =[0]  image0_is_valid =[1]
image1_is_valid =[0]  boot_fail_num =[0]
image0_version =3FE49362IJHK46
image1_version =OpenWrt-r0-24c   <- parsed from our TRX header
```

Consequences:
- We have a **safe iterate loop**: a bad OpenWrt boot auto-reverts to stock
  after N attempts, no serial needed. Recovery is no longer a blocker.
- OpenWrt must **commit the flag itself** or even a working image reverts.
  v3 adds `/etc/init.d/econet-commit` (sets `commit=1`, `next_active=1`,
  `image1_valid=1`, `boot_fail_num=0` on both flag copies once booted).
- Flashing procedure keeps `commit=0` while testing so the auto-revert safety
  net stays armed; the init script commits only after a successful boot.

### Post-flash symptom and v3 changes

v2 flashed fine (CRC-verified) but the system never became reachable on LAN:
link came up (PHY negotiates) yet no ARP/DHCP/ICMP and all ports closed; WLAN
LED flashed during boot then went out (WiFi disabled by default in OpenWrt).
Stock kernel analysis shows no external switch driver strings — the board uses
the internal EN7528 GSW like DASAN (MT7530-MMIO DSA driver, `NET_DSA_MT7530_MMIO=y`),
so the DTS approach is right; the failure is in init/config or the DTS details.

v3 changes (built on GitHub Actions only):
- `/etc/uci-defaults/99-wifi-recovery` — enable both radios with open recovery
  SSIDs (`G2425G-Recovery`, `G2425G-Recovery-5G`) as the lifeline if ethernet
  stays broken;
- `/etc/init.d/econet-commit` — boot-flag commit service (see above);
- `/etc/uci-defaults/99-commit-enable` — enable the service at first boot.

## Update 2026-11-14 (later) — v4: dumb-switch Ethernet + flash telemetry

### Why v4 abandons DSA for now

The v2 DTB was verified out of the flashed TRX (decompressed kernel, FDT at
the tail): `gmac0` okay with a 1G fixed-link, `ethernet-switch@1fb58000`
okay, ports 1-4 okay with PHYs 9-12 and CPU port 6 -> `gmac0`. Both drivers
were in the image (`kmod-econet-eth`, `CONFIG_NET_DSA_MT7530_MMIO=y`) and the
board compatible matches `02_network`, so the failure is at runtime, not DTS
or packaging.

The DSA path resets the switch and force-links every port down before it
verifies the switch (`mt7531_setup_common` -> `mt7530_fdb_cmd` with a timeout,
then `mt7530_setup_vlan0`). If any step fails, the switch is left
half-initialised with no forwarding, which matches the observed symptoms
exactly (PHY link up from hardware autoneg, zero L2 traffic).

The board now uses the econet-eth driver's **dumb-switch mode**: widen the
ethernet register window to cover the switch block (`reg = <0x1fb50000
0x10000>`) and leave `&switch` disabled. The driver then programs PMCR for
ports 5/6 and MFC (CPU port 6) and the on-die MT7530 bridges all four LAN
sockets to `gmac0` in hardware, with no DSA involvement. This is the path
from the original upstream "en7528: add basic ethernet support" commit,
which is what DASAN H660GM-A users actually used over Ethernet. The four
sockets appear as one `eth0`, which `02_network` puts in `br-lan`.

### Telemetry without a console

`/etc/init.d/econet-bootlog` writes two snapshots to the stock `log`
partition (mtd7, 0xC00000 @ 0x7960000; OpenWrt label `log`):

- ~10 s after boot: dmesg, cmdline, mtd table, `ip link`, per-netdev
  operstate/carrier/MAC/speed, rx/tx counters, qdma/gsw interrupts, lsmod;
- ~80 s after boot: the same plus `uci show network|wireless`, `iw dev`,
  `logread`. Both snapshots end up in flash (early first).

Read it back **from stock** (the bootloader reverts on its own because we do
not commit during testing):

```
dd if=/dev/mtd7 bs=128k count=16 2>/dev/null | strings | less
```

### Commit policy change (important)

v3 enabled `econet-commit` at boot. That is dangerous while the image is
unproven: committing on a boot that is unreachable would remove CFE's
auto-revert and strand the device (no serial). v4 therefore does **not**
enable the service. Once the box is reachable (Ethernet or the
`G2425G-Recovery` SSID), run:

```
bootflag-commit            # == /etc/init.d/econet-commit start
```

which writes `commit=1, next_active=1, image1_valid=1, boot_fail_num=0` to
both flag copies. Until then every bad boot self-reverts to stock.

### v4 image contents

- DTS: dumb-switch Ethernet (`reg = <0x1fb50000 0x10000>`, `&switch` stays
  disabled), `gmac0` enabled with MAC from `<&macaddr_ri 0>`;
- `02_network`: LAN = `eth0` (falls back to `lan1..lan4` if a DSA port
  ever shows up);
- WiFi recovery SSIDs (as in v3);
- boot-log telemetry service;
- `nand-utils` package (flash_erase/nanddump/nandwrite for field work);
- manual-only boot-flag commit.

### v5 — superseded by the root-cause analysis in PHASE5-BOOT-CAUSE.md

Do not reuse v4's `config.seed`: it deleted `ubus`/`ubusd`/`libubus`/`libuci`,
so the built image had no `netifd`, `firewall4` or `dnsmasq`. The "link up, no
traffic" symptom was missing userspace, not a broken DSA/dumb-switch DTS.
