# Phase 5 — Why the v2/v4 images never came up, and what changed

Status: root cause identified from the repository, fixes committed locally,
**not built and not flashed**. Read this before the next flash.

## Symptom (as recorded in PHASE4-FLASH.md)

> v2 flashed fine (CRC-verified) but the system never became reachable on LAN:
> link came up (PHY negotiates) yet no ARP/DHCP/ICMP and all ports closed; WLAN
> LED flashed during boot then went out.

The kernel boots and the switch PHYs autonegotiate in hardware. What is missing
is everything that configures the network and the services on top of it.

## Root cause: `config.seed` deleted the network stack

(Update 2026-11-17: the kernel coming up is only half the boot chain. Further
defects, pinned against the stock dumps, meant the *bootloader* may never even
have started our kernel — the "WLAN LED flashed" behaviour previously read as
a partial boot is at least as consistent with stock reverting. See
PHASE4-FLASH.md "Update 2026-11-17": (1) certain — our TRX header was 256
bytes where stock images and the vendor userspace use a 280-byte header with
the payload at 0x118; a 256-byte header makes CFE read the LZMA stream 24
bytes into a wrong position and die silently; (2) operational — `oflt
change_boot_flag` runs the nonexistent `swug` and reboots without switching;
the staged-flag script (`scripts/stage-openwrt-slot.sh`) replaces it; (3)
possible but countered — the EN751221-family "A-length bug" would truncate
our kernel stream, but stock slot B's stream already exceeds the would-be cap
and boots, so it likely does not apply here; `--patch-a` is harmless
insurance.)

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
`ubusd`, `libubus` and `libuci` pinned to `n`, kconfig cannot satisfy those
dependencies, so `netifd`, `firewall4`, `dnsmasq` (DHCP) and `odhcpd` are
**silently dropped from the image**. Nothing warns at build time beyond the
usual unmet-dependency line.

Result on the box: `eth0` exists and its PHY links up, but there is no bridge,
no `br-lan`, no IPv4 address, no DHCP, no firewall — every packet is dropped,
exactly as observed. The v4 DSA→dumb-switch rewrite was chasing the wrong layer.

### Secondary defect: the 5 GHz radio had no firmware

`Device/nokia_g-2425g-a` was missing `kmod-mt7663-firmware-ap` (the DASAN
definition has it). MT7663 cannot probe without it, so `radio1` never existed
and `G2425G-Recovery-5G` could never come up. Combined with the missing netifd
this left **zero** management paths.

Note: `config-minimal` did contain a line that *looked* like it added the
firmware (`CONFIG_PACKAGE_kmod_mt7663_firmware_ap=y`), but that symbol does not
exist — package symbols keep the real name and hyphens
(`CONFIG_PACKAGE_kmod-mt7663-firmware-ap`), so the line was inert. The device
package list is the correct place, and that is where the fix lives.

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

## Correction: the `config-minimal` kernel lines were never the problem

An earlier version of this document claimed `CONFIG_SPI=n` in
`config-minimal` disabled the NAND controller. **That was wrong**, and the
first version of the CI gate that checked `.config` for `CONFIG_SPI` proved it
by failing on every kernel symbol.

OpenWrt's top-level `.config` only holds symbols defined by its own Kconfig:
target selection, package selection (`CONFIG_PACKAGE_<name>`) and the
`CONFIG_KERNEL_*` allowlist from `config/Config-kernel.in`. Raw kernel symbols
are not in that namespace, so `make defconfig` drops them without a trace:

```
$ grep '^config SPI' config/Config-kernel.in      # no match
$ grep '^CONFIG_SPI=' .config                     # no match
```

Kernel options are merged from `target/linux/generic/config-<ver>` and
`target/linux/<target>/[<subtarget>/]config-<ver>` when the kernel is built.
`target/linux/econet/en7528/config-6.18` already sets:

```
CONFIG_SPI=y
CONFIG_SPI_MASTER=y
CONFIG_SPI_AIROHA_SNFI=y
CONFIG_MTD_SPI_NAND=y
CONFIG_MTD_UBI=y
CONFIG_UBIFS_FS=y
```

So the NAND controller was never disabled, and the earlier `=n` lines in
`config-minimal` did nothing at all (they neither helped nor hurt). The file now
contains only valid `.config` symbols, with a header explaining the split, and
the CI gate checks each layer in the file where it actually lives:

* kernel symbols → `target/linux/{generic,econet,econet/en7528}/config-*`
* package symbols → `.config`

Because of that split, `CONFIG_NF_CONNTRACK` is no longer asserted directly: it
is not listed in any target config file (it is selected by the nftables
dependencies), so asserting it at config time would always fail. The package
assertions (`firewall4`, `kmod-nft-*` via `firewall4`) cover the requirement.

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
| `config.seed` | keep ubus/ubusd/libubus/libuci/libblobmsg-json/libjson-c; only LuCI/uhttpd/rpcd stay disabled |
| `files/target/linux/econet/config-minimal` | rewritten with valid `.config` symbols only (hyphenated package names); no inert kernel lines |
| `.github/workflows/build.yml` | `Verify boot-critical config` checks kernel symbols in target config files and packages in `.config`; chmod for the new script |
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
* CI gate exercised locally against the real upstream
  `generic/config-6.18` + `econet/en7528/config-6.18` files and a synthetic
  `.config`: passes with a correct config, fails when a required package or
  kernel symbol is removed.

## Verification NOT performed (be honest about this)

* **No build.** A full OpenWrt build is not viable in this Android container;
  GitHub Actions remains the build path. The `config.seed`, `config-minimal`
  and `.mk` edits are reviewed and dependency-checked, but not compiled.
* **No flash.** The device is not reachable from here. The bootloader's
  auto-revert is unchanged, so an unproven image still falls back to stock.
* **No decompilation of the stock kernel/bootloader.** REA on this host has no
  Ghidra/IDA/rizin backend, and the bootloader second stage is encrypted. It is
  also beside the point: the failure is in the build recipe, and the stock
  binaries were only needed for the facts already extracted in PHASE2
  (partition map, TRX layout, MAC offset, boot-flag struct).

## Next steps

1. Push this commit; GitHub Actions must pass `Verify boot-critical config`.
2. Confirm the manifest/artifact contains `netifd`, `firewall4`, `dnsmasq`,
   `ubus`, `ubusd`, `kmod-mt7663-firmware-ap`, `mtd`.
3. Flash the inactive slot exactly as in PHASE4 (fwtool3, keep `commit=0`).
3a. **Stage the flag before rebooting** (`sh /tmp/stage-openwrt-slot.sh
   --patch-a`): the old `oflt change_boot_flag` switch step was a no-op
   (`swug` missing from the stock rootfs), and `--patch-a` is optional
   insurance against the A-length bug. See PHASE4-FLASH.md,
   "Update 2026-11-17" for the boot-chain root causes and their dump
   evidence (280-byte header, no-op switch, A-length counter-evidence).
4. First boot: `br-lan` on 192.168.1.1 with DHCP; `G2425G-Recovery` (2.4 GHz)
   and/or `G2425G-Recovery-5G` visible.
5. Log in (`root` / `nokia2425`, change it), then run `bootflag-commit` only
   once the box is genuinely usable, so CFE stops reverting.
6. If it still fails, read `log` (mtd7) from stock:
   `dd if=/dev/mtd7 bs=128k count=16 | strings`.
