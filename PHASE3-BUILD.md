# Phase 3 — Port plan & build (Nokia G-2425G-A → OpenWrt)

Status: in progress. OpenWrt master cloned to `openwrt/`, device files added.

## What was added to the OpenWrt tree
1. `target/linux/econet/dts/en7528_nokia_g2425g-a.dts` — board DTS:
   - Same SoC include (`en7528.dtsi`) as DASAN H660GM-A (same hardware family)
   - PCIe slot0 = MT7603 (2.4G), slot1 = MT7663 (5G); mt76 reads OTP eFuse directly
     (stock firmware also uses eFuse/OTP — verified in `mt7603eap.ko` strings)
   - MAC: `macaddr_ri` nvmem cell = offset 0x3e of `ri` partition (dump-verified),
     +1 alias for 5G radio; gmac0 uses it too
   - Partition map = live NAND dump (PHASE2-FINDINGS.md):
     linux_kernel 0x2280000 (4 MiB TRX), UBI root = concat(tclinux_rootfs
     0x2680000 + stock "rootfs" 0x4480000) ≈ 60 MiB
   - LED GPIOs NOT confirmed (stock uses proprietary tcledctrl); only a
     placeholder power LED kept. Refine after first boot.
2. `target/linux/econet/image/en7528.mk` — `Device/nokia_g-2425g-a`:
   - `$(call Device/tclinux-ubi)` image type (kernel TRX 4 MiB + UBI rootfs)
   - `TRX_LOADADDR := 0x80002000` + `tclinux-free-bootbase-jump` — matches the
     stock image's HDR2 loadaddr field (verified from dump)
   - `FACTORY_SIZE := 34m` (size of the linux slot the image is written to)
   - packages: kmod-usb2 kmod-mt7603 kmod-mt7615e kmod-mt7663-firmware-ap
3. `platform.sh` — board added with `CI_KERNPART="linux_kernel"`
4. `board.d/02_network` — lan1..lan4 bridged

## Image format reasoning (from stock dump analysis)
- Stock image = TCLinux TRX little-endian ("HDR2"), 280-byte header, payload =
  raw LZMA kernel (4 MiB-ish) + squashfs rootfs, loadaddr 0x80002000
- CRC-32 (JAMCRC) verified against payload → **no encryption in the image**;
  the "decrypt bootram" strings are about the bootloader's own 2nd stage only
- Bootloader boots the `linux` partition (running version matches it, image0
  holds a stale different version)
- OpenWrt `tclinux-trx.sh` writes a 256-byte header variant vs stock 280; the
  bootloader is expected to honor the header-length field (same family works
  for DASAN H660GM-A and JioFiber JCOW40x). RISK: unverified on this Nokia
  bootloader — see open questions.

## Build
```
cd openwrt && make -j2   # download phase done first (make -j4 download)
```
Output: `bin/targets/econet/en7528/openwrt-econet-en7528-nokia_g-2425g-a-tclinux.trx`
(+ sysupgrade.bin). The `.trx` is the full image for the linux slot.

## Flash plan (NOT EXECUTED YET — needs confirmation before any write)
Telnet route (no serial needed for the write itself, but serial is strongly
recommended as the only recovery path):
1. Backup already complete (dumps/, 2 copies).
2. Write OpenWrt TRX to the **linux slot** (mtd3, offset 0x2280000, size
   0x2200000): dd to /dev/mtd3 char device (raw NAND write) — needs image size
   < 34 MB ✓ (~13-15 MB expected)
3. Concern: stock bootloader may version-check linux slot against `flag`
   (which lists both HK46/JJIJ50). Mitigations ready: set the TRX version
   string to `3FE49362JJIJ50`, and/or patch flag bytes.
4. If bootloader refuses the 256-byte header, rebuild with a 280-byte header
   (local patch to tclinux-trx.sh HDRLEN=280 + 24 zero bytes reserved).
5. image0 (stale HK46) + image_oflt (3FE49107) both still hold stock images →
   possible fallback slots if the bootloader has slot selection.

## Open questions (before flashing)
- Does the bootloader boot linux slot without version/flag validation?
- 256 vs 280 byte TRX header acceptance
- LED/button GPIO numbers
- First-boot check list: serial console is the only reliable debug channel
  (laptop has USB drivers; recommend ordering a CH340/CP2102 USB-TTL adapter
  ~2 € before the first flash attempt)
