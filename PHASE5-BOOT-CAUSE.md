# Phase 5 — Why the v2/v4 images never came up, and what changed

Status: root causes identified from the repository + stock dump, fixes committed
locally, **not built and not flashed**. Read this before the next flash.

## Symptom (as recorded in PHASE4-FLASH.md)

> v2 flashed fine (CRC-verified) but the system never became reachable on LAN:
> link came up (PHY negotiates) yet no ARP/DHCP/ICMP and all ports closed; WLAN
> LED flashed during boot then went out.

Two independent defects in the *build* recipe produce exactly this. Neither is a
device-tree problem, neither is a bootloader/TRX problem, and neither can be
found by decompiling the stock firmware — they are in this repository.

---

## Root cause 1 (fatal, boot): `config-minimal` disabled the NAND controller

`.github/workflows/build.yml` appends `files/target/linux/econet/config-minimal`
**after** `config.seed`, so every line in it overrides the target defaults from
`target/linux/econet/en7528/config-6.18`. It contained:

```
CONFIG_SPI=n
CONFIG_SPI_MASTER=n
```

The EN7528 NAND is an SPI-NAND host controller: the upstream EN7528 config
carries

```
CONFIG_SPI=y
CONFIG_SPI_MASTER=y
CONFIG_SPI_AIROHA_SNFI=y
CONFIG_MTD_SPI_NAND=y
```

`CONFIG_SPI_AIROHA_SNFI` lives in `drivers/spi/` and depends on `SPI_MASTER`,
which depends on `SPI`. Pinning `SPI=n` makes kconfig drop the SPI core, then
the host controller, then SPI-NAND: **no `/dev/mtd*`, no UBI attach, no rootfs**.
The kernel starts, the ethernet PHYs autonegotiate (hardware, no software
needed), the GPIO LEDs get a default state — and then the kernel cannot mount
init and panics. That is the "boots, link flashes, nothing else" screenshot.

The same file also disabled `CONFIG_IPV6`, and dnsmasq's Makefile carries
`DEPENDS+=@IPV6`; and it disabled `NF_CONNTRACK`/`NF_NAT`/netfilter targets,
without which `firewall4` cannot load.

`config-minimal` is now pruned down to subsystems this board provably never
uses, with the boot-critical symbols re-asserted explicitly, and the workflow
now **fails the build** if any of the required symbols is not `=y` after
`make defconfig` (see `Verify boot-critical config`).

## Root cause 2 (fatal, reachability): `config.seed` deleted the network stack

`config.seed` (v2/v4) contained:

```
CONFIG_PACKAGE_libubus=n
CONFIG_PACKAGE_ubus=n
CONFIG_PACKAGE_ubusd=n
CONFIG_PACKAGE_libuci=n
CONFIG_PACKAGE_libblobmsg-json=n
CONFIG_PACKAGE_libjson-c=n
```

Upstream dependency metadata (verified against `openwrt/openwrt@main`):

| Package | `DEPENDS` (excerpt) |
|---|---|
| `netifd` | `+libuci +libnl-tiny +libubus +ubus +ubusd +jshn +libubox …` |
| `dnsmasq` | `+libubus …`, plus `@IPV6` |

OpenWrt package dependencies are `depends on`, not `select`. With `ubus`,
`ubusd`, `libubus` and `libuci` pinned to `n`, kconfig cannot satisfy them, so
`netifd`, `firewall4`, `dnsmasq` (DHCP) and `odhcpd` are **silently dropped
from the image**. Nothing warns at build time beyond the usual unmet-dependency
line.

Result even with a working rootfs: `eth0` exists and its PHY links up, but there
is no bridge, no `br-lan`, no IPv4 address, no DHCP, no firewall — every packet
is dropped. The v4 DSA→dumb-switch rewrite was chasing the wrong layer.

### Secondary defect: the 5 GHz radio had no firmware

`Device/nokia_g-2425g-a` was missing `kmod-mt7663-firmware-ap` (the DASAN
definition has it). MT7663 cannot probe without it, so `radio1` never existed
and the `G2425G-Recovery-5G` lifeline from `99-wifi-recovery` could never come
up. Together with the missing netifd this left **zero** management paths.

### Tertiary defects

* `mtd` was not in `DEVICE_PACKAGES`, but `econet-bootlog` and `bootflag-commit`
  both call `/sbin/mtd`. The telemetry meant to explain the failure was never
  written; the writes failed silently.
* `econet-bootlog` ran `sleep 10` then `sleep 70` inside an rc `boot()`
  function, delaying every later boot script — including network setup — by
  80 s. Now backgrounded.
* `99-wifi-recovery` hardcoded `radio0`/`radio1`, but radio numbering follows
  PCIe probe order; the 5 GHz radio can be `radio0`. It now walks every radio
  UCI created and names the SSID from the band.
* No management login existed at all: LuCI/uhttpd are off and OpenWrt's stock
  `/etc/shadow` locks root, so dropbear refuses every login. A first-boot
  uci-default now sets `root`/`nokia2425` (change it after login).
* The DTS declared the stock `rootfs` partition as `0x1e20000` bytes at
  `0x4480000`, which runs to `0x62a0000` and **overlaps `image_oflt` at
  `0x6260000`**. The live mtd table reports a non-aligned `0x1e17400`; the
  correct erase-aligned size ending where `image_oflt` starts is `0x1de0000`.

---

## What is *not* wrong (verified — do not "fix" these)

**The dumb-switch DTS is correct.** The out-of-tree driver behind the econet
target's `kmod-econet-eth` (`cjdelisle/econet_eth@3ba0abe`) contains:

```c
/* Whether our register window covers the on-die switch, see probe. */
bool has_switch_regs;
...
eth->has_switch_regs = resource_size(regs_res) >= sizeof(struct en751221_regs);
...
/* Configure the MT7530 as a dumb switch, unless it is managed by DSA */
if (eth->has_switch_regs) {
    en75_wreg(EN75_PMCR_CONFIG, &regs->switch_regs[MT753X_PMCR_P(5) / 4]);
    en75_wreg(EN75_PMCR_CONFIG, &regs->switch_regs[MT753X_PMCR_P(6) / 4]);
    en75_wreg(EN75_MFC_CONFIG, &regs->switch_regs[MT753X_MFC / 4]);
```

`struct en751221_regs` is `0x10000` (0x8000 frame engine + 0x8000 switch block)
and the test is `resource_size()`. So `&ethernet { reg = <0x1fb50000 0x10000>; }`
with `&switch` disabled is exactly the documented way to get hardware bridging
to `gmac0`. Unchanged.

**The MAC nvmem cell is correct.** `mtd12` (`ri`) at offset `0x3e` holds
`5c:8c:30:be:cb:90`; the `macaddr@3e` / `mac-base` cell reads the right bytes.

**The TRX header is accepted.** After the v2 flash the stock bootloader stored
`image1_version = OpenWrt-r0-24c…`, i.e. it parsed our 256-byte `HDR2` header
and its version field. 280 vs 256 bytes is not what stopped boot.

**The partition map matches the dump.** All 16 entries verified against
`mtd0..mtd14`: offsets, sizes, alignment; flash ends at `0xfaa0000` < 256 MiB.

## Changes in this commit

| File | Change |
|---|---|
| `files/target/linux/econet/config-minimal` | stop disabling SPI/SPI_MASTER (NAND), IPv6 (dnsmasq), conntrack/NAT (firewall4); re-assert boot-critical symbols |
| `config.seed` | keep ubus/ubusd/libubus/libuci/libblobmsg-json/libjson-c; only LuCI/uhttpd/rpcd stay disabled |
| `.github/workflows/build.yml` | new `Verify boot-critical config` gate; chmod for the new script |
| `files/target/linux/econet/image/en7528.mk` | add `kmod-mt7663-firmware-ap`, `mtd` |
| `files/target/linux/econet/base-files/lib/upgrade/platform.sh` | explicit `CI_UBIPART="ubi"` |
| `files/target/linux/econet/dts/en7528_nokia_g2425g-a.dts` | `rootfs` size `0x1e20000` → `0x1de0000` (no overlap with `image_oflt`) |
| `files/root-overlay/etc/init.d/econet-bootlog` | snapshots backgrounded, no 80 s boot stall |
| `files/root-overlay/etc/uci-defaults/99-wifi-recovery` | band-aware, works with any radio numbering |
| `files/root-overlay/etc/uci-defaults/99-root-password` | new: documented first-boot password + enable dropbear |

## Verification performed locally

* Device tree compiles clean with `dtc 1.7.0` against current upstream
  `en7528.dtsi` (only upstream's own `avoid_unnecessary_addr_size` warning).
* Compiled DTB re-parsed: 16 partitions, all erase-block aligned, contiguous,
  non-overlapping, flash end `0xfaa0000`.
* `sh -n` clean on every shell script in the tree.
* Partition table compared field by field against the live `mtd0..mtd14` dumps.
* `tclinux-trx.sh` read from upstream: 256-byte header, kernel padded to
  `0x400000`, CRC over payload only — matches the layout PHASE4 verified on the
  flashed file.
* Driver source inspected to confirm the dumb-switch contract (above).
* Upstream dependency metadata read for `netifd`, `dnsmasq`, `firewall4`, and
  the EN7528 kernel config to confirm every symbol this commit stops pruning.

## Verification NOT performed (be honest about this)

* **No build.** A full OpenWrt build is not viable in this Android container;
  GitHub Actions remains the build path. The `config.seed`, `config-minimal`
  and `.mk` edits are reviewed and dependency-checked, but not compiled.
* **No flash.** The device is not reachable from here. The bootloader's
  auto-revert is unchanged, so an unproven image still falls back to stock.
* **No decompilation of the stock kernel/bootloader.** REA on this host has no
  Ghidra/IDA/rizin backend, and the bootloader second stage is encrypted. It is
  also beside the point: both failures are in the build recipe, and the stock
  binaries were only needed for facts already extracted in PHASE2 (partition
  map, TRX layout, MAC offset, boot-flag struct).

## Next steps

1. Push this commit; GitHub Actions must pass `Verify boot-critical config`.
2. Confirm the manifest/artifact contains `netifd`, `firewall4`, `dnsmasq`,
   `ubus`, `ubusd`, `kmod-mt7663-firmware-ap`, `mtd`.
3. Flash the inactive slot exactly as in PHASE4 (fwtool3, keep `commit=0`).
4. First boot: `br-lan` on 192.168.1.1 with DHCP; `G2425G-Recovery` (2.4 GHz)
   and/or `G2425G-Recovery-5G` visible.
5. Log in (`root` / `nokia2425`, change it), then run `bootflag-commit` only
   once the box is genuinely usable, so CFE stops reverting.
6. If it still fails, read `log` (mtd7) from stock:
   `dd if=/dev/mtd7 bs=128k count=16 | strings`.
