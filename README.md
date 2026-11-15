# OpenWrt port for Nokia G-2425G-A (Airtel GPON ONT)

Community port of OpenWrt to the **Nokia G-2425G-A** — the Airtel-branded
DASAN H660GM-A family ONT (EcoNet EN7528 SoC, MT7603 2.4 GHz + MT7663 5 GHz,
256 MB NAND).

The GPON port will **not** work under OpenWrt (no PON driver in-tree). The
goal of this port is to use the device as a router / WiFi repeater / dumb AP.

## What's in this repo

| Path | Purpose |
|---|---|
| `files/` | Overlay files applied on top of upstream `openwrt/openwrt` master |
| `config.seed` | Device selection for `make defconfig` |
| `.github/workflows/build.yml` | Builds the image on GitHub Actions |
| `PHASE2-FINDINGS.md` | Hardware reverse-engineering notes (flash map, image format, OTP cal) |
| `PHASE3-BUILD.md` | Port/build notes and flash plan |
| `PHASE5-BOOT-CAUSE.md` | **Why v2/v4 never came up + what changed in this commit** |

Device files (already upstream-compatible structure):

- `files/target/linux/econet/dts/en7528_nokia_g2425g-a.dts` — board DTS
  (partition map from a live NAND dump, MAC from the `ri` partition @0x3e,
  WiFi via OTP eFuse)
- `files/target/linux/econet/image/en7528.mk` — `Device/nokia_g-2425g-a`
  (TCLinux TRX + UBI, free-bootbase loadaddr 0x80002000)
- `files/target/linux/econet/base-files/{etc/board.d,lib/upgrade}` — network
  setup + sysupgrade plumbing

## Build locally

```
git clone --depth 1 https://github.com/openwrt/openwrt.git openwrt
cp files/target/linux/econet/dts/en7528_nokia_g2425g-a.dts openwrt/target/linux/econet/dts/
cp files/target/linux/econet/image/en7528.mk openwrt/target/linux/econet/image/
cp files/target/linux/econet/base-files/etc/board.d/02_network openwrt/target/linux/econet/base-files/etc/board.d/
cp files/target/linux/econet/base-files/lib/upgrade/platform.sh openwrt/target/linux/econet/base-files/lib/upgrade/
cd openwrt
cp ../config.seed .config && make defconfig
make download -j$(nproc)
make -j$(nproc)
# output: bin/targets/econet/en7528/openwrt-*-nokia_g-2425g-a-tclinux.trx
```

## Build on GitHub

Just push — the workflow builds automatically and uploads the image as an
artifact (Actions tab → run → artifacts).

## Flashing / status

⚠️ **Do not flash anything you have not built yourself.** Read
`PHASE5-BOOT-CAUSE.md` first: the previous images booted but had no network
stack at all (their `config.seed` deleted `ubus`/`ubusd`/`libuci`, which makes
kconfig drop `netifd`, `firewall4` and `dnsmasq`). That is fixed here, but the
image is still unbuilt and unflashed. The stock bootloader's tolerance of
OpenWrt's 256-byte TRX header and its version/flag validation remain only
partly verified. Full NAND backup (15 partitions) is mandatory before any
write. A USB-TTL serial adapter is strongly recommended as the only real
recovery path.
