Refs #7786 — zlib fixture provenance

Required tests use only the hexadecimal members checked into `stdlib/tests/zlib_api.tl`. No host zlib library or executable is a build or test dependency.

The members were generated offline by the script below with Python 3.14.8 standard-library zlib 1.3.2 (both `ZLIB_VERSION` and `ZLIB_RUNTIME_VERSION`), random seed 7786. The script asserts that zlib decodes every valid member to its expected output, with no unused data, and records zlib's verdict on each malformed input.

The handmade members are emitted from canonical RFC 1950/1951 fields:

- CINFO 0 with a stored body;
- a preset-dictionary member whose length-3 match reaches exactly the first byte of the three-byte dictionary `abc`, and its distance-4 variant, which zlib rejects as too far back;
- the ratio pin: one fixed-Huffman literal `A`, then length 258 at distance 1.

Valid members (compressed SHA256):

0. empty — aca503def43dc086a5aaa5c3d6f86bcbbc2aa6a80007ddea4a81bce2b376fceb — 8 compressed bytes
1. stored-hello — e00cc3a166153d6cf724f7214bc3280f2bbf620788732fe8aee3b65a7ad10afc — 16 compressed bytes
2. fixed — 84876341c1b28a05aeb9cff952b29af0fdc692a1eeecdd036be3aeddabfc2bbb — 20 compressed bytes
3. dynamic-level1 — ec8531cca7dd07c1a6a9ecba21e75b6009496c0dee21e6b829ef2048158805e0 — 378 compressed bytes
4. dynamic-level4 — 1566fa4a381b34ce88d22eb481f52399c48f41901aa93d74d756bc3c4d84826d — 378 compressed bytes
5. dynamic-level9 — 7e88c53d3dc69359f98da14798fafeb70856843698565aaccd2e4e97d104d664 — 378 compressed bytes
6. cinfo1 — 8c43d5d410c613e38eefa60befe3511f33b3d001141ee0b4845d111cd1c2510a — 81 compressed bytes
7. cinfo2 — b76d383306fc1299711d87c788b7e944060a1ab782b3fdd6f473bde640e2ed88 — 81 compressed bytes
8. cinfo3 — 8d2d40a419969aa76d9944e97978b856ff2de32228d01489d4f67d40fb8274f3 — 81 compressed bytes
9. cinfo4 — 7fcf6e7a9bc02202b6a0fb01301db39e9ec4c9c27ec68b7ea6f241b49e3ae69b — 81 compressed bytes
10. cinfo5 — dda13d7ff1c4599982cd36ba748ba4c7091b06f2776a9ff41583f51507f156a9 — 81 compressed bytes
11. cinfo6 — 8e9404c1257a0807e896e124f186130bb4c8d18d55e16a1ec225dd4700c191a8 — 81 compressed bytes
12. cinfo7 — b50e613911eafd2a0a4285eb8d5781442a6c83964f967e4e1b130d66a20d1d9f — 81 compressed bytes
13. cinfo0-handmade — 6e1891364ec0ade458f27d77d7c557bb853e662857e8836e6149b0497b4f6b73 — 14 compressed bytes
14. preset-dictionary — 343590217715634138c1010822771ef44314bdc3f287f07c3f3cf60fe9fcadb7 — 18 compressed bytes; dictionary `the quick brown fox jumps over the lazy dog`
15. dictionary-edge-handmade — e126fa96c2ce362d2da6131111364be8356b443e21314f8011e21cc29e963a69 — 13 compressed bytes; dictionary `abc`
16. ratio-pin-handmade — deb45e670c57cbdb2d4787cd40f62ef51d4f16d154f7fc48d648369d25d79710 — 10 compressed bytes

Malformed inputs (zlib verdict):

- method7 — 7709 — Error -3 while decompressing data: unknown compression method
- method15 — 7f07 — Error -3 while decompressing data: unknown compression method
- cinfo8 — 881c — Error -3 while decompressing data: invalid window size
- cinfo15 — f800 — Error -3 while decompressing data: invalid window size
- header-check — 789d — Error -3 while decompressing data: incorrect header check
- check-before-method — 7700 — Error -3 while decompressing data: incorrect header check
- dictionary-beyond-handmade — 7820024d012703620000000000 — Error -3 while decompressing data: invalid distance too far back

Adler-32 vectors (input length, first bytes, checksum):

- 0 — (empty) — 00000001
- 1 — 61 — 00620062
- 3 — 616263 — 024d0127
- 14 — 6d65737361676520646967657374 — 29750586
- 26 — 6162636465666768696a6b6c6d6e6f70 — 90860b20
- 62 — 4142434445464748494a4b4c4d4e4f50 — 8adb150c
- 80 — 31323334353637383930313233343536 — 97b61069
- 9 — 57696b697065646961 — 11e60398
- 1048576 — ffffffffffffffffffffffffffffffff — 8e88ef11

Regenerate in an empty directory with `python3 -I generate.py`, where `generate.py` is:

```python
import hashlib
import random
import zlib


def member(data, level=6, wbits=15, strategy=zlib.Z_DEFAULT_STRATEGY, zdict=None):
    if zdict is None:
        c = zlib.compressobj(level, zlib.DEFLATED, wbits, 8, strategy)
    else:
        c = zlib.compressobj(level, zlib.DEFLATED, wbits, 8, strategy, zdict)
    return c.compress(data) + c.flush()


def header(cinfo, flevel, fdict):
    cmf = (cinfo << 4) | 8
    flg = (flevel << 6) | (32 if fdict else 0)
    flg += (31 - ((cmf * 256 + flg) % 31)) % 31
    return bytes([cmf, flg])


def be32(value):
    return value.to_bytes(4, "big")


def stored(data):
    n = len(data)
    return bytes([1, n & 255, n >> 8, (~n) & 255, ((~n) >> 8) & 255]) + data


class Bits:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def put(self, value, width):
        self.acc |= value << self.n
        self.n += width
        while self.n >= 8:
            self.out.append(self.acc & 255)
            self.acc >>= 8
            self.n -= 8

    def huff(self, code, width):
        self.put(int(format(code, "0%db" % width)[::-1], 2), width)

    def done(self):
        if self.n:
            self.out.append(self.acc & 255)
        return bytes(self.out)


def fixed_match(length_symbol, distance_code, literals=b""):
    # One final fixed block: literals, one match without extra bits, EOB.
    b = Bits()
    b.put(1, 1)
    b.put(1, 2)
    for value in literals:
        b.huff(0x30 + value, 8)
    if length_symbol < 280:
        b.huff(length_symbol - 256, 7)
    else:
        b.huff(0xC0 + length_symbol - 280, 8)
    b.huff(distance_code, 5)
    b.huff(0, 7)
    return b.done()


rng = random.Random(7786)
text = bytes(rng.choice(b"abcdefgh  zlib\n") for _ in range(700))
valid = [
    ("empty", member(b""), b"", None),
    ("stored-hello", member(b"hello", 0), b"hello", None),
    ("fixed", member(b"hello hello hello zlib", 6, 15, zlib.Z_FIXED), b"hello hello hello zlib", None),
    ("dynamic-level1", member(text, 1), text, None),
    ("dynamic-level4", member(text, 4), text, None),
    ("dynamic-level9", member(text, 9), text, None),
]
for wbits in range(9, 16):
    data = b"window" * 40 + bytes(range(64))
    valid.append(("cinfo%d" % (wbits - 8), member(data, 6, wbits), data, None))
cinfo0 = header(0, 0, False) + stored(b"abc") + be32(zlib.adler32(b"abc"))
valid.append(("cinfo0-handmade", cinfo0, b"abc", None))
zdict = b"the quick brown fox jumps over the lazy dog"
data = b"the lazy dog jumps over the quick brown fox"
valid.append(("preset-dictionary", member(data, 9, 15, zlib.Z_DEFAULT_STRATEGY, zdict), data, zdict))
# Length 3 at distance 3 reaches exactly the first dictionary byte.
body = fixed_match(257, 2)
edge = header(7, 0, True) + be32(zlib.adler32(b"abc")) + body + be32(zlib.adler32(b"abc"))
valid.append(("dictionary-edge-handmade", edge, b"abc", b"abc"))
# The ratio pin: literal A, length 258 at distance 1.
ratio_body = fixed_match(285, 0, b"A")
ratio_data = b"A" * 259
ratio = header(7, 0, False) + ratio_body + be32(zlib.adler32(ratio_data))
valid.append(("ratio-pin-handmade", ratio, ratio_data, None))

for name, compressed, output, dictionary in valid:
    d = zlib.decompressobj(zdict=dictionary) if dictionary is not None else zlib.decompressobj()
    assert d.decompress(compressed) == output and d.eof and d.unused_data == b"", name
    print("valid", name, compressed.hex(), output.hex() if len(output) < 80 else "len%d" % len(output),
          dictionary.hex() if dictionary else "-", hashlib.sha256(compressed).hexdigest())

# Distance 4 reaches one byte before the three-byte dictionary.
beyond = header(7, 0, True) + be32(zlib.adler32(b"abc")) + fixed_match(257, 3) + be32(0)
malformed = [
    ("method7", bytes([0x77, (31 - (0x7700 % 31)) % 31])),
    ("method15", bytes([0x7F, (31 - (0x7F00 % 31)) % 31])),
    ("cinfo8", bytes([0x88, (31 - (0x8800 % 31)) % 31])),
    ("cinfo15", bytes([0xF8, (31 - (0xF800 % 31)) % 31])),
    ("header-check", bytes([0x78, 0x9D])),
    ("check-before-method", bytes([0x77, 0x00])),
    ("dictionary-beyond-handmade", beyond),
]
for name, compressed in malformed:
    try:
        zlib.decompressobj(zdict=b"abc").decompress(compressed + b"\0" * 8)
        verdict = "accepted"
    except zlib.error as error:
        verdict = str(error)
    print("malformed", name, compressed.hex(), verdict)

for vector in [b"", b"a", b"abc", b"message digest", b"abcdefghijklmnopqrstuvwxyz",
               b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
               b"1234567890" * 8, b"Wikipedia", b"\xff" * 1048576]:
    print("adler32", len(vector), vector[:16].hex(), "%08x" % zlib.adler32(vector))
print("zlib", zlib.ZLIB_VERSION, zlib.ZLIB_RUNTIME_VERSION)
```
