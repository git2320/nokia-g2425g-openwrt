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
| `flag` (mtd10) / `flagback` (mtd11) | 0x8ba0000 / 0x8be0000 | 0x40000 each | boot flags |

(Correction 2026-11-17: an earlier revision of this table said flag = mtd13/mtd14;
the full dump of all 15 partitions shows `flag` = **mtd10** @0x8ba0000 and
`flagback` = **mtd11** @0x8be0000, 0x40000 each, mtd12/13/14 are `ri`/`riback`/`data`.)

OpenWrt image = upstream `tclinux` format, whole-file write to `linux` (mtd3):

```
0x000000  HDR2 header (280 B: 256 B of fields + 24 zero pad bytes)
0x000118  kernel, FF-padded
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

1. **Do NOT use `oflt change_boot_flag` to switch slots — it is a no-op on this
   firmware.** `lib/liboflt.so` `oflt_change_boot_flag` merely runs
   `system("swug --im inactive --activate"); system("reboot");` and **`swug`
   does not exist anywhere in the stock rootfs** (verified by a full
   unsquashfs listing of mtd4 plus a content grep). The command reboots
   without switching anything.
   To rehearse the switch instead, stage image0 with the flag script:
   `sh stage-openwrt-slot.sh` variant for bank 0 (or `Imagetool switch`, the
   stock path that `swdl_active` uses), then reboot into IJHK46.
2. Verify image0: web UI up, telnet obtainable (web CGI), `oflt change_boot_flag` present.
3. Confirmed recovery path in hand before any flash byte is written.

### Phase B — flash (from image0, mtd3 inactive)

0. Push `stage-openwrt-slot.sh` to the ONT while you still have shell
   (`curl -o /tmp/stage-openwrt-slot.sh http://192.168.1.3:8000/stage-openwrt-slot.sh`);
1. Laptop: `cd /tmp/opencode/ghimg/econet/en7528 && python3 -m http.server 8000`
   (bind 192.168.1.3, wired to ONT).
2. ONT: `curl -o /tmp/openwrt.trx http://192.168.1.3:8000/openwrt-econet-en7528-nokia_g-2425g-a-squashfs-tclinux.trx`
3. Verify size + md5 vs local.
4. Erase whole slot (kills stale stock UBI data beyond our UBI blob):
   `/tmp/fwtool erase /dev/mtd3 0 0x2200000`
5. Write: `/tmp/fwtool write /dev/mtd3 0 /tmp/openwrt.trx`
6. Verify: `/tmp/fwtool verify /dev/mtd3 0 <file size> /tmp/openwrt.trx`
7. Spot-check CRC32 of first 0x40000 vs local computation.
8. **Stage the flag (MANDATORY, replaces the old "switch" step):**
   `sh /tmp/stage-openwrt-slot.sh --patch-a`
   This writes `commit=0, next_active=1, image0_is_valid=1, image1_is_valid=1,
   boot_fail_num=0` into BOTH flag copies (mtd10 + mtd11, via `/dev/mtdblockN`
   since stock has no `mtd`/`flash_erase`/`nandwrite` applets), and — with
   `--patch-a` — raises slot A's `kernel_len` (mtd2 offset 0x50) from the stock
   `0x3ddbae` to `0x400000` (needs `/tmp/fwtool3`; plain MEMERASE returns
   EINVAL on image slots). The patch is optional insurance against the
   A-length bug (see below); the flag staging is not optional.
9. `sync`

### Phase C — switch

1. `reboot` → CFE boots the `linux` slot (OpenWrt) because `next_active=1`.
2. OpenWrt first boot: LAN up (eth0-3 bridged LAN, 192.168.1.1), LEDs, `uci` state.
3. If OpenWrt fails to boot: CFE boot_fail mechanism auto-reverts to stock
   (observed on hardware with v2); after ~N failed boots the flag returns to
   `commit=0, next_active=0, image0_is_valid=1, image1_is_valid=0` and stock
   comes back on its own. CFE web recovery as last resort.

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

## Update 2026-11-17 — dump-evidence fixes: 280-byte header, A-length cap, no-op switch

Three defects in the previous runbook/image, all pinned against the stock dumps
(mtd2/mtd3/mtd5 TRX images, mtd4 rootfs, mtd10/mtd11 flags) and the vendor
userspace from the rootfs squashfs:

### 1. The TRX header is 280 bytes, not 256

- All three stock images declare `hdr_len=280` and start the LZMA payload
  (props `0x5d`, recorded size) at offset **0x118**; bytes 0x100–0x117 are zero.
- Vendor userspace agrees: `lib/libupgradeimpl.so` `image_check` `fread()`s
  exactly `0x118` bytes as the header and fails otherwise — the vendor struct
  is 280 bytes, not the 256 of the classic 2010 `trx.h`.
- Stock boots with the payload at 0x118, so the bootloader must read it there.
  A 256-byte header would make CFE read the LZMA stream 24 bytes early
  (props byte 0x00, size 0) → silent decompression failure — which matches
  the "kernel does not boot at all" symptom of v2/v4.

`files/target/linux/econet/image/tclinux-trx.sh` now writes `HDRLEN=280`
(256 bytes of fields + 24 zero pad). `scripts/verify-image.py` checks it
(`HDR_LEN=280`, plus a zero-pad check for bytes 0x100–0x117).

### 2. A-length bug: documented for the family, with counter-evidence HERE

The GPL bootloader source (`cjdelisle/EN751221-Linux26`, `bootram/init/main.c`)
reads `kernel_len` from **slot A (image0)** *before* the flag decides which
slot to boot, and the econet-linux wiki documents this "A-length bug" for many
bootloaders of the family: a slot B stream longer than slot A's `kernel_len`
is truncated mid-flight and boot dies in the decompressor.

**Counter-evidence on this board:** stock slot B (mtd3, JJIJ50) declares a
4,098,754-byte kernel stream (`kernel_len=0x3e8ac2`, no FF padding — total =
hdr + kernel + rootfs exactly) while slot A (mtd2, HK46) declares
`kernel_len=0x3ddbae` (4,055,470). Under the bug, booting B would truncate
B's stream by ~43 KB and stock B could not boot — yet stock boots from B.
So this board's bootloader probably reads the length from the slot it
actually boots, and the cap likely does not apply.

Handling: `tclinux-trx.sh` prints a build **warning** (CI stays green) when
the stream exceeds the would-be cap, and `scripts/stage-openwrt-slot.sh
--patch-a` optionally raises slot A's `kernel_len` to `0x400000` as harmless
insurance (safe for stock A: the LZMA decoder stops at its recorded size, and
`checkimage`'s CRC covers `total_len`, which `kernel_len` does not touch).

### 3. `oflt change_boot_flag` is a no-op on this firmware

`lib/liboflt.so` `oflt_change_boot_flag` (`0x136c8`) runs
`system("swug --im inactive --activate"); system("reboot");` — and **`swug`
does not exist anywhere in the stock rootfs** (full unsquashfs listing of
mtd4 + content grep). The old "Phase C switch" step therefore only rebooted
into stock. The stock switching path is `Imagetool switch` / `swdl_active`
(sets `commit`, `next_active`, both `_is_valid=1`, `boot_fail_num=0`, writes
both flag copies via the vendor `ioctl _IOR('M',1,...)`).

`scripts/stage-openwrt-slot.sh` reproduces that state on-box without any
stock tools: it dd-reads the first 128 KiB of `flag` (mtd10) and `flagback`
(mtd11) through `/dev/mtdblockN`, patches words 0–4 to
`commit=0, next_active=1, image0_is_valid=1, image1_is_valid=1,
boot_fail_num=0` (word 5 "startready" and the version strings at 0x18/0x28
are preserved), writes the block back, and verifies through the char device
read-back. Run it **after flashing, before the first reboot**.

Stock-side housekeeping worth knowing: `usr/exe/autocommit.sh` commits the
running slot at boot (`Imagetool commit <n>`) and
`usr/exe/clean_boot_fail_counter.sh` resets the fail counter 70 s after boot
(`Imagetool update`) — stock's equivalents of our `econet-commit`.
