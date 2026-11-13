# Phase 2 — Hardware findings (Nokia G-2425G-A, Airtel)

Collected 2026-11-13 via root telnet (ONTUSER) + NAND dump over `nc`.

## SoC / board
- `EcoNet EN7528 SOC`, machine `econet,en751221` (same dtsi family as DASAN H660GM-A)
- 4x MIPS 1004Kc (MT/MIPS16 ASE), ~592 BogoMIPS
- RAM: 231,628 kB total (~226 MiB), kernel at boot had ~18 MB free
- Kernel 3.18.21 #7 SMP Mon Jun 20 19:34:46 CST 2022, mips LE

**The Nokia G-2425G-A is the Airtel-branded DASAN H660GM-A hardware** (community-confirmed;
TechEnclave thread "Unlocking Airtel Xstream Fiber (Dasan H660GM-A)" is used by G-2425G-A
owners). OpenWrt master already has `dasan/h660gm-a-airtel` (EN7528, MT7603+MT7663) but
with a *different flash layout* than our unit.

## WiFi (PCIe)
| Slot | Device | Chip | Band | Driver (stock) |
|---|---|---|---|---|
| 0000:00:00.0 → 01:00.0 | 14c3:7603 | MT7603 | 2.4G | `mt7603eap` (MediaTek SDK, module) |
| 0000:00:01.0 → 02:00.0 | 14c3:7663 | MT7663 | 5G | built-in SDK driver |

Both supported by OpenWrt `mt76`: `kmod-mt7603` + `kmod-mt7615e`/`kmod-mt7663-firmware-ap`
(same package set as H660GM-A).

**WiFi calibration = chip-internal OTP/eFuse**, NOT a flash EEPROM:
- stock `mt7603eap.ko` strings: `efuse_probe`, `rtmp_ee_efuse_read16`, `eFuseReadRegisters`
- no EEPROM/ART blob anywhere on flash; `extfs` partition has empty
  `WIFI_2GCAL`/`WIFI_5GCAL` record headers (payloads all 0xFF)
- mt76 will read OTP directly → **no eeprom file needed** (verify at first boot)

## Flash: 256 MB NAND, erase 128 KiB, 15 partitions
Computed physical offsets (cumulative, erase-aligned where relevant):

| mtd | offset | size | name | content |
|---|---|---|---|---|
| 0 | 0x0000000 | 0x40000 | bootloader | EcoNet boot (2nd stage encrypted "bootram") |
| 1 | 0x0040000 | 0x40000 | romfile | text/ASCII NVRAM |
| 2 | 0x0080000 | 0x2200000 | image0 | **full TRX image ver 3FE49362IJHK46 (stale/other)** |
| 3 | 0x2280000 | 0x2200000 | linux | **full TRX image ver 3FE49362JJIJ50 = RUNNING** |
| 4 | 0x4480000 | ~0x1e20000 | rootfs | same squashfs as inside linux (plain) |
| 5 | 0x6260000 | 0xf00000 | image_oflt | full TRX image ver 3FE49107HJHK03 (older) |
| 6 | 0x7160000 | 0x800000 | config | UBI (→ /configs) |
| 7 | 0x7960000 | 0xc00000 | log | UBI (→ /logs) |
| 8 | 0x8560000 | 0x600000 | extfs | custom "extfs" records: RI, SECURITY, WIFI_2GCAL(empty), WIFI_5GCAL(empty) |
| 9 | 0x8b60000 | 0x40000 | bosa | |
| 10 | 0x8ba0000 | 0x40000 | flag | version/state tracking |
| 11 | 0x8be0000 | 0x40000 | flagback | mirror of flag |
| 12 | 0x8c20000 | 0x40000 | ri | **reserve info: MAC @ 0x3e, serial, model** |
| 13 | 0x8c60000 | 0x40000 | riback | mirror of ri |
| 14 | 0x8ca0000 | 0x6e00000 | data | UBI (→ /flash) |

Boot conclusion: the **bootloader boots the `linux` partition (mtd3)** — the running
firmware version (JJIJ50) is there, image0 holds a different version (HK46), so image0
is the staging slot and linux is the active boot slot.

## Stock image format = plain TCLinux TRX (HDR2), NO encryption
Verified against OpenWrt's `target/linux/econet/image/tclinux-trx.sh`:

```
HDR2, hdr_len=280 (OpenWrt uses 256 — payload starts at 0x118 here),
total_len, crc32 (JAMCRC) — VERIFIED MATCHES payload bytes [hdr_len..total],
version "3FE49362IJHK46", 32B cust version = 0,
kernel_len, rootfs_len, romfile_len=0, 32B model = 0,
loadaddr = 0x80002000   <-- free-bootbase loader (same as JioFiber JCOW407!)
then: raw LZMA kernel (props 5d, dict 0x800000, ~11.1 MB uncomp) + squashfs rootfs
```

- mtd3 payload: kernel_len 4,098,754 + squashfs 24,147,231 (= exact mtd4 content)
- LZMA kernel decompresses fine with FORMAT_ALONE; stock rootfs = plain squashfs 4.0
- So an OpenWrt image in this format can be written straight into the linux partition

## MAC
`ri` partition (and its mirror `riback`): offset 0x3e = MAC `5c:8c:30:xx:xx:xx`
(header `01ALCL02 3FE48299XXXXXX ... G-2425G-220604`).

## Dump artifacts (2 copies)
- `/home/ram/nokia-g2425g-openwrt/dumps/mtd{0..14}.bin` (raw)
- `/home/ram/nokia-g2425g-openwrt/dumps/mtdblock{0..14}.bin.gz` (gz originals)
- `/home/ram/nokia-g2425g-openwrt/dumps/rootfs-extract/` (unsquashed stock rootfs)
- `/home/ram/nokia-g2425g-openwrt/dumps/stock-kernel.bin` (decompressed 11.1 MB stock kernel)

## Unknowns still open
- LED GPIO map (stock uses proprietary `tcledctrl`/`led_drv`, not gpio-leds)
- Button GPIOs
- UART console for recovery is ttyS0 @ 0x1fbf0000 (standard, from en7528.dtsi)
- Whether bootloader version-checks the linux slot against `flag` (mitigation: reuse
  version string `3FE49362JJIJ50` in our TRX and/or patch flag partition)
- 280 vs 256 byte TRX header (bootloader may use hdr_len field → 256 fine; or fixed → use 280)
