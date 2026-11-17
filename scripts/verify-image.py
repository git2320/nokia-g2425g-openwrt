#!/usr/bin/env python3
"""Verify that a built Nokia G-2425G-A TRX image is bootable, without the ONT.

Checks only what the stock CFE actually enforces (or what we measured on the
stock dump), so a pass means "the bootloader will accept this file", not just
"the file looks nice":

  * "HDR2" little-endian TRX header, 280 bytes (vendor struct), total length
    consistent;
  * CRC accepted the way CFE accepts it (JAMCRC, as zytrx writes it; the plain
    CRC-32 is also tolerated because tcboot accepts both);
  * kernel length padded so that hdr_len + kernel_len == 4 MiB, which is where
    the DTS puts the UBI partition;
  * load address 0x80002000 ("free bootbase" loader, decompresses there);
  * kernel payload is LZMA1 with the properties byte 0x5d, an 8 MiB dictionary,
    and a *recorded* uncompressed size (the stock kernel records it, and the
    vendor decompressor uses it to stop before the 0xFF padding);
  * the decompressed kernel starts with the jump to 0x80020000 that
    tclinux-free-bootbase-jump inserts;
  * the decompressed kernel is no larger than the stock one, which is proven to
    fit the loader's decompression window;
  * the appended DTB really is ours (partition labels + model string);
  * "UBI#" starts at exactly 0x400000.

Usage:
  scripts/verify-image.py out/*tclinux.trx
  scripts/verify-image.py --self-test
"""

import argparse
import lzma
import struct
import sys
import zlib

HDR_LEN = 280                      # vendor struct size (stock images + libupgradeimpl.so)
ROOTFS_OFFSET = 0x400000           # UBI partition offset inside the slot
KERNEL_PAD = ROOTFS_OFFSET - HDR_LEN
FACTORY_SIZE = 0x2200000           # "linux"/"image0" slot size
LOADADDR = 0x80002000
FDT_MAGIC = b"\xd0\x0d\xfe\xed"
JUMP_WORD = 0x08008000             # j 0x80020000, little endian
# Decompressed size of the stock 3FE49362JJIJ50 kernel, i.e. a value the loader
# is known to handle on this board.
STOCK_KERNEL_SIZE = 11155392
# Compressed-stream bound that WOULD apply while slot A ("image0") still
# holds stock IF this bootloader has the A-length bug documented for the
# EN751221 GPL variant (reads kernel_len from slot A before choosing the
# slot). Counter-evidence on this board: stock slot B's stream is 4,098,754
# bytes > this cap and stock boots from slot B anyway, so the bug probably
# does not apply here. Reported only as a warning; --patch-a in
# scripts/stage-openwrt-slot.sh is harmless insurance either way.
SLOT_A_FEED = 0x3ddbae - 0x18


def jamcrc(data):
    return (~zlib.crc32(data)) & 0xFFFFFFFF


def plaincrc(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def verify(buf, expect_strings=(), max_kernel=STOCK_KERNEL_SIZE):
    problems = []
    facts = []
    warnings = []

    if len(buf) < HDR_LEN:
        return ["file is shorter than a TRX header (280 bytes)"], facts, warnings
    if len(buf) > 265 and buf[257:262] == b"ustar":
        return ["this is a sysupgrade tar, not a raw TRX: write *tclinux.trx "
                "into the slot, sysupgrade.bin is for a running OpenWrt"], facts

    magic, hdr_len, total_len, crc = struct.unpack_from("<4sIII", buf, 0)
    version = buf[0x10:0x30].split(b"\x00")[0]
    klen, rlen, romlen = struct.unpack_from("<III", buf, 0x50)
    model = buf[0x5c:0x7c].split(b"\x00")[0]
    (loadaddr,) = struct.unpack_from("<I", buf, 0x7c)

    facts.append("hdr_len=%d total=0x%x kernel=0x%x rootfs=0x%x"
                 % (hdr_len, total_len, klen, rlen))
    facts.append("version=%r model=%r loadaddr=0x%08x"
                 % (version, model, loadaddr))

    if magic != b"HDR2":
        problems.append("magic is %r, expected b'HDR2' (this board is little "
                        "endian; b'2RDH' would be the big-endian twin)" % magic)
    if hdr_len != HDR_LEN:
        problems.append("hdr_len is %d, expected %d (vendor struct size: stock "
                        "images and libupgradeimpl.so both use 280)"
                        % (hdr_len, HDR_LEN))
    if klen != KERNEL_PAD:
        problems.append("kernel_len is 0x%x, expected 0x%x (4 MiB rootfs "
                        "offset minus the header); any other value moves the "
                        "UBI partition away from where the DTS and CFE expect it"
                        % (klen, KERNEL_PAD))
    if rlen == 0:
        problems.append("rootfs_len is 0: kernel-only image, not a sysupgrade")
    if romlen != 0:
        problems.append("romfile_len is %d, expected 0" % romlen)
    if total_len != hdr_len + klen + rlen:
        problems.append("total_len 0x%x != hdr_len 0x%x + kernel_len 0x%x + "
                        "rootfs_len 0x%x"
                        % (total_len, hdr_len, klen, rlen))
    if total_len > FACTORY_SIZE:
        problems.append("image is 0x%x bytes, larger than the 0x%x slot"
                        % (total_len, FACTORY_SIZE))
    if loadaddr != LOADADDR:
        problems.append("loadaddr is 0x%08x, expected 0x%08x (free-bootbase "
                        "loader decompresses there)" % (loadaddr, LOADADDR))
    if not version:
        problems.append("version string is empty")
    elif not all(32 <= c < 127 for c in version):
        problems.append("version string is not printable ASCII: %r" % version)
    if len(buf) < total_len:
        problems.append("file is truncated: %d bytes, header says 0x%x"
                        % (len(buf), total_len))
    elif len(buf) > total_len:
        tail = buf[total_len:]
        if any(b != 0xFF for b in tail):
            problems.append("%d trailing bytes that are not 0xFF padding"
                            % len(tail))

    end = min(total_len, len(buf))
    if hdr_len + klen <= end:
        payload = buf[hdr_len:end]
        if crc == jamcrc(payload):
            facts.append("CRC is JAMCRC (stock/zytrx convention)")
        elif crc == plaincrc(payload):
            facts.append("CRC is plain CRC-32 (tcboot accepts both)")
        else:
            problems.append("CRC mismatch: header 0x%08x, payload 0x%08x "
                            "(JAMCRC) / 0x%08x (plain)"
                            % (crc, jamcrc(payload), plaincrc(payload)))

    # Kernel: lzma(vmlinuz + DTB) with the free-bootbase jump in front.
    kend = hdr_len + klen
    if kend <= len(buf):
        raw = buf[hdr_len:kend].rstrip(b"\xff")
        kernel = b""
        try:
            kernel = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(raw)
        except Exception as exc:  # noqa: BLE001
            problems.append("kernel is not a valid LZMA stream: %s" % exc)

        if len(raw) >= 13:
            props = raw[0]
            dic = struct.unpack_from("<I", raw, 1)[0]
            size = struct.unpack_from("<Q", raw, 5)[0]
            facts.append("lzma props=0x%02x dict=%d size_field=%s"
                         % (props, dic,
                            "unknown" if size == 0xFFFFFFFFFFFFFFFF else size))
            if props != 0x5D:
                problems.append("LZMA properties byte is 0x%02x, CFE's image "
                                "parser recognises 0x5D (lc=3 lp=0 pb=2)" % props)
            if dic != 8 << 20:
                problems.append("LZMA dictionary is %d bytes, the stock image "
                                "uses 8 MiB; a larger one may not fit the "
                                "loader's window" % dic)
            if size == 0xFFFFFFFFFFFFFFFF:
                problems.append("LZMA header has no uncompressed size (0xFF...) "
                                "and no end marker: the vendor decompressor "
                                "cannot know where the payload ends")
            elif kernel and size != len(kernel):
                problems.append("LZMA size field is %d but the stream decodes to "
                                "%d bytes" % (size, len(kernel)))

        if len(raw) > SLOT_A_FEED:
            warnings.append("kernel stream is %d bytes > the A-length-bug cap of "
                            "%d (EN751221-family bug; stock evidence suggests it "
                            "does not apply on this board). Harmless insurance: "
                            "scripts/stage-openwrt-slot.sh --patch-a"
                            % (len(raw), SLOT_A_FEED))
        else:
            facts.append("kernel stream %d bytes under the A-length-bug cap "
                         "(%d)" % (len(raw), SLOT_A_FEED))

        pad = buf[256:min(280, len(buf))]
        if pad and pad != b"\x00" * len(pad):
            problems.append("header bytes 0x100..0x117 are not zero (%r): the "
                            "vendor 280-byte header ends with 24 zero pad bytes"
                            % pad[:8])

        if kernel:
            facts.append("kernel decompresses to %d bytes" % len(kernel))
            if len(kernel) > max_kernel:
                problems.append("kernel decompresses to %d bytes, more than the "
                                "stock %d that the loader is known to handle"
                                % (len(kernel), max_kernel))
            (first,) = struct.unpack_from("<I", kernel, 0)
            if first != JUMP_WORD:
                problems.append("kernel does not start with the "
                                "tclinux-free-bootbase-jump instruction "
                                "(0x%08x, got 0x%08x): the loader decompresses "
                                "to 0x80002000, the kernel is linked at "
                                "0x80020000" % (JUMP_WORD, first))
            idx = kernel.find(FDT_MAGIC)
            if idx < 0:
                problems.append("no FDT magic in the decompressed kernel: the "
                                "DTB was not appended")
            else:
                facts.append("DTB at kernel offset 0x%x" % idx)
                dtb = kernel[idx:]
                for needle in expect_strings:
                    if needle and needle.encode() not in dtb:
                        problems.append("DTB does not contain %r" % needle)

    ustart = hdr_len + klen
    if ustart + 4 <= len(buf):
        if buf[ustart:ustart + 4] != b"UBI#":
            problems.append("no UBI# magic at 0x%x (rootfs does not start "
                            "where the DTS says)" % ustart)
        else:
            facts.append("UBI image at 0x%x" % ustart)

    return problems, facts, warnings


def make_image(with_stub=True):
    """Synthetic but structurally bootable image, optionally without the jump."""
    stub = struct.pack("<I", JUMP_WORD) + b"\x00" * 122876 if with_stub else b""
    blob = stub + FDT_MAGIC + b"\x00" * 32 + \
        b"linux_kernel\x00ubi\x00Nokia G-2425G-A\x00"
    comp = bytearray(lzma.compress(blob, format=lzma.FORMAT_ALONE))
    comp[5:13] = struct.pack("<Q", len(blob))     # record the real size
    if len(comp) > KERNEL_PAD:
        raise ValueError("self-test payload too large")
    kernel = bytes(comp) + b"\xff" * (KERNEL_PAD - len(comp))
    ubi = b"UBI#" + b"\x00" * 4092
    total = HDR_LEN + KERNEL_PAD + len(ubi)
    payload = kernel + ubi
    hdr = struct.pack("<4sIII", b"HDR2", HDR_LEN, total, jamcrc(payload))
    hdr += b"OpenWrt-self-test".ljust(32, b"\x00")
    hdr += b"\x00" * 32
    hdr += struct.pack("<III", KERNEL_PAD, len(ubi), 0)
    hdr += b"G-2425G-A".ljust(32, b"\x00")
    hdr += struct.pack("<I", LOADADDR) + b"\x00" * 128
    hdr += b"\x00" * 24                            # 280-byte vendor header pad
    assert len(hdr) == HDR_LEN, len(hdr)
    return hdr + payload


def self_test():
    good = make_image()

    problems, facts, warnings = verify(good, expect_strings=("linux_kernel", "ubi"))
    if problems:
        print("self-test FAILED on a valid image:")
        for p in problems:
            print("  -", p)
        return 1
    for f in facts:
        print("  ok:", f)
    for w in warnings:
        print("  warn:", w)

    def expect(name, mutate, needle):
        broken = bytearray(good)
        mutate(broken)
        problems, _, _ = verify(bytes(broken), expect_strings=("linux_kernel",))
        if not any(needle in p for p in problems):
            print("self-test FAILED: %s was not detected" % name)
            return False
        return True

    ok = True
    ok &= expect("corrupt CRC", lambda b: b.__setitem__(0x0C, b[0x0C] ^ 0xFF),
                 "CRC mismatch")
    ok &= expect("missing UBI magic",
                 lambda b: b.__setitem__(HDR_LEN + KERNEL_PAD, 0), "UBI#")
    ok &= expect("unknown LZMA size",
                 lambda b: b.__setitem__(slice(HDR_LEN + 5, HDR_LEN + 13),
                                         b"\xff" * 8),
                 "no uncompressed size")
    no_stub = make_image(with_stub=False)
    problems, _, _ = verify(no_stub, expect_strings=("linux_kernel",))
    if not any("free-bootbase-jump" in p for p in problems):
        print("self-test FAILED: missing jump stub was not detected")
        ok = False
    if not ok:
        return 1

    print("self-test ok")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("image", nargs="?")
    ap.add_argument("--expect", default="linux_kernel,ubi")
    ap.add_argument("--max-kernel", type=lambda x: int(x, 0),
                    default=STOCK_KERNEL_SIZE,
                    help="largest decompressed kernel accepted "
                         "(default: the stock kernel's size)")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.image:
        ap.error("image path required (or --self-test)")

    with open(args.image, "rb") as fh:
        buf = fh.read()
    problems, facts, warnings = verify(
        buf,
        expect_strings=[s for s in args.expect.split(",") if s],
        max_kernel=args.max_kernel,
    )
    for f in facts:
        print("  .", f)
    for w in warnings:
        print("  WARN:", w)
    if problems:
        for p in problems:
            print("FAIL:", p)
        return 1
    print("OK: TRX layout, LZMA header, jump stub, DTB and UBI offset all match "
          "what CFE expects")
    return 0


if __name__ == "__main__":
    sys.exit(main())
