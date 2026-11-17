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

**The TRX header version field was parsed, but the image was not accepted.**
After the v2 flash the stock bootloader stored `image1_version =
OpenWrt-r0-24c…` because the version field sits at 0x10 in *both* the 256- and
280-byte layouts — that observation says nothing about the payload offset.
CFE's payload start is hardcoded at **0x118 (280)** (see "CFE boot-path
disassembly" below): with a 256-byte header CFE starts LZMA decoding 24 bytes
into the stream header and dies silently. 280 vs 256 bytes *is* what stopped
boot.

**The partition map matches the dump.** All 16 entries verified against
`mtd0..mtd14`: offsets, sizes, alignment; flash ends at `0xfaa0000` < 256 MiB.

## CFE boot-path decompilation (REA MCP + Ghidra, 2026-11-17)

The stock bootloader was decompressed and decompiled from the dumps to settle
the remaining format questions with code, not inference. `mtd0` is a 128 KiB
uncached first stage plus an LZMA-Alone stream at 0x20000 (props 0x5d, dict
8 MiB, 269,376 B uncompressed). The decompressed body loads at **0x83FB0000**
(base proven statistically: 544 in-image absolute references and 125 exact
string hits; neighbouring bases score ~0). The following offsets are file
offsets in that body.

| Address | Finding |
|---|---|
| `0x1b30`, `0x1bf8` | **`addiu …, 280 (0x118)`** — the LZMA source start passed to the range setter is `flash_base + partition_offset + 0x118`. Both the main and the alternate path hardcode the 280-byte skip. This is the definitive proof that the payload must begin at 0x118. |
| `0x18c8`, `0xa0f8` | `kernel_len` is read from **header+0x50** (`a0 = header+0x50`, then a 4-byte flash read) — the classic TRX field. |
| `0x19a8`–`0x19c4` | CFE computes the source end as `s2 = (kernel_len + 0x10100) & 0xffff0000`, i.e. kernel_len rounded up to 64 KiB. Our padded `kernel_len = 0x400000 - 280` yields `s2 = 0x400000`, matching the rootfs boundary. Stock A (0x3ddbae) → 0x3E0000, stock B (0x3e8ac2) → 0x3F0000. |
| `0x35680` | LZMA decoder wrapper: reads the 5-byte props/dict header and the 8-byte uncompressed size *from the stream itself*; source range from globals `0x83ff1c30`/`0x83ff1c34`; destination passed in `a0`, here **0x80020000**; allocator bounds printed as `free_mem_ptr=0x80e00000`, `free_mem_ptr_end=0x807b0000`. |
| `0x5528`–`0x5548` | Image-accept path: compares magic `HDR2` (`0x32524448`), computes CRC over **`[header+0x118, header+total_len)`** with `jal 0x83fb7ae0`, and compares it with the field at **header+0x0c**. Exactly our JAMCRC layout. |
| `0x690c`–`0x692c` | Second check accepts magic `0x32524448` (`HDR2`) or `0x33524448`, and rejects `total_len < 280 (0x118)`. |
| `0x17c4`–`0x1804` | "Jump to %X" then `jalr` to a function pointer — the jump is indirect; our free-bootbase stub at the load address remains the right mechanism. |
| `0x83fbb650` (0xb650) | The call after decompression is a **cache flush** (writes to `0xbc95xxxx`), not a decompressed-size check. No max-size rejection was found on the boot path. |

No model/part-number validation, no props/dict whitelist beyond the stream
fields, and no additional size gate exist on this path. Stock header fields at
0x04 (hdr_len = 0x118), 0x10 (version), 0x50/0x54 (lengths), 0x7c (loadaddr
0x80002000) and the 24-byte pad are all reproduced by `tclinux-trx.sh`; the
CRC algorithm was re-derived from both stock slots (JAMCRC over the payload).
**Conclusion: the committed fixes cover every bootloader requirement found;
no further image change is needed for CFE to accept and decompress the kernel.**

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
* `tclinux-trx.sh` reviewed: 280-byte header (payload at 0x118), kernel padded
  so `0x118 + kernel_len = 0x400000`, JAMCRC over the payload only. Verified
  against both stock slots and against CFE's own CRC-accept path (see above).
* `scripts/verify-image.py --self-test`: all boot-critical header fields pass
  (hdr_len 280, dict 8 MiB, loadaddr 0x80002000, JAMCRC, DTB and UBI offsets).
* Stock CFE (mtd0) decompressed from its LZMA stream and decompiled with
  REA MCP + Ghidra 12.1.4; boot path mapped as tabulated above.
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
* **No decompilation of the stock *kernel*.** CFE's boot path was fully
  decompiled with Ghidra 12.1.4 via REA MCP (the native decompiler was built
  locally for arm64 — official zips ship only x86_64). `FUN_83fb1820` shows the
  `+0x118` source start and `header+0x7c` destination in C; `FUN_83fb5208`
  shows the CRC call `FUN_83fb7ae0(0x80020118, total_len-0x118, 1)` compared
  against the header CRC; `FUN_83fe5680` reads props/size from the stream
  itself and decodes to the load address with no additional size gate. See the
  table above for addresses.
* **No build / no flash / no on-device verification** (see the rest of this
  section). Boot success can only be confirmed by flashing the next CI image.

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
