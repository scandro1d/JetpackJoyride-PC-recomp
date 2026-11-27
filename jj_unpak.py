#!/usr/bin/env python3
"""
Unpack jet.pak / sound.pak from Jetpack Joyride Deluxe (PS3, NPUB31615).
Run on the *decrypted* paks (see rpcs3 --decrypt).

Format (all big-endian):
  u32 count
  count * { u32 hash, u32 size, u32 stored_size, u32 offset }
  data blob; offset is relative to (4 + count*16)
  jet.pak   : stored data is raw LZMA1 (5-byte props/dict header, no length)
  sound.pak : stored data is uncompressed (size == stored_size)

Usage: jj_unpak.py <pak> <outdir>
"""
import lzma, os, struct, sys, json, collections

MAGICS = [
    (b"\x89PNG", "png"), (b"DDS ", "dds"), (b"MSFC", "msf"), (b"RIFF", "riff"),
    (b"OggS", "ogg"), (b"<?xml", "xml"), (b"\x7fELF", "elf"), (b"GIF8", "gif"),
    (b"\xff\xd8\xff", "jpg"), (b"\x1bLua", "luac"), (b"PK\x03\x04", "zip"),
]

def guess_ext(b):
    for m, e in MAGICS:
        if b.startswith(m):
            return e
    head = b[:256]
    if head and all(32 <= c < 127 or c in (9, 10, 13) for c in head):
        return "txt"
    return "bin"

def unlzma(blob, size):
    props, dict_sz = blob[0], struct.unpack("<I", blob[1:5])[0]
    hdr = bytes([props]) + struct.pack("<I", dict_sz) + struct.pack("<Q", size)
    d = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE)
    return d.decompress(hdr + blob[5:], max_length=size)

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    pak, out = sys.argv[1], sys.argv[2]
    data = open(pak, "rb").read()
    n = struct.unpack(">I", data[:4])[0]
    base = 4 + n * 16
    os.makedirs(out, exist_ok=True)
    manifest, stats, bad = [], collections.Counter(), 0
    for i in range(n):
        h, size, stored, off = struct.unpack(">IIII", data[4 + i * 16: 20 + i * 16])
        blob = data[base + off: base + off + stored]
        try:
            raw = blob if size == stored else unlzma(blob, size)
            if len(raw) != size:
                raise ValueError("size mismatch %d != %d" % (len(raw), size))
        except Exception as ex:
            bad += 1
            print("entry %d hash %08x failed: %s" % (i, h, ex))
            raw, ext = blob, "failed"
        else:
            ext = guess_ext(raw)
        stats[ext] += 1
        name = "%04d_%08x.%s" % (i, h, ext)
        with open(os.path.join(out, name), "wb") as f:
            f.write(raw)
        manifest.append({"index": i, "hash": "%08x" % h, "size": size,
                         "stored": stored, "type": ext, "file": name})
    json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1)
    print("%s: %d entries, %d failed" % (pak, n, bad))
    for k, v in stats.most_common():
        print("  %-6s %d" % (k, v))

if __name__ == "__main__":
    main()
