# DEFLATE limit and mutation fixture derivations

All expectations below are independent RFC 1951 hand derivations. The optional
offline Python zlib 1.3.2 oracle also accepts each valid source and rejects each
negative mutation; it is not a test or build dependency.

- `050000240000`: BFINAL1/BTYPE2, HLIT257/HDIST1/HCLEN4; the four code-length
  lengths in order 16/17/18/0 are 0/0/0/1, making symbol 0 the singleton. The alphabet is
  incomplete, so `MalformedTree` occurs after 29 bits, at input 4/output 0. The
  one-bit singleton exception applies only to literal/distance alphabets.
- `731c0500`: fixed literal A, length258/distance1, EOB. The match has consumed
  24 bits, accepted 3 bytes and emitted 259 bytes. Ratio 2/startup 253 permits
  exactly 259; startup 252 rejects byte 259 with `RatioLimit` at input 3/output 258.
- Dynamic fixture 8 has HLIT 257/HDIST 1/HCLEN 12 and 122 significant bits in 16
  bytes. Its code-length tokens are 4,16x6,16x6,4,4,5,18x138,18x99,17x3,5,0,
  materializing 258 lengths. Payload literals 0/14/15 and EOB consume 18 bits.
  Work is 33489 initialization +16 accepted bytes +122 consumed bits +3 emitted
  bytes +19 clear +85 code-tree +258 materialization +(94+2*258) final-tree
  build =34602. Budget 34602 passes and 34601 fails at input 16/output 3. Charging
  each repeat only 1 loses 247 work units and is rejected by this absolute pin.
- The mixed fixed/dynamic/fixed pin is independently 33489+1054+14+112+19+85+258
  +(94+2*258)=35641; the fixed preparation charge 1054 occurs once.

The near-maximum-ratio member uses the dynamic header prefix
`edc0010900000080a0feafee8806`. The first 106 bits describe literal 0 length 2,
EOB length 2, length 285 length 1 and distance 0 length 1. Literal 0 is code 10, EOB 11,
length 285 code 0, distance 0 code 0. Literal 0 followed by 16384 length 258/distance 1
matches and EOB therefore uses 32878 bits (4110 bytes) and emits 4227073 zeros.
Its SHA256 is `29f5c4f3e92f820979e3fded134724b29df16e00ded2df921c0851d709248e26`.
After the 14-byte prefix, all bytes are zero except byte 4109 = 48; A5/5A is a
trailing container suffix. The n-th match accepts ceil((108+2*n)/8) input bytes
and attempts cumulative output `1 + 258*n`. The first match exceeding default credit
is n = 7426: input 1870 and output cap `1024 + 1024*1870 = 1915904`. `RatioLimit` has
those offsets. Explicit ratio 1032 decodes the whole member and leaves the suffix.

### Fixed-seed negative corpus

Seed 9532, LCG `(seed*1664525+1013904223) mod 2^32`, advanced once per row.
Three groups of 8 valid sources have n=1..8:

1. Stored members: data bytes are seed bytes cycling little-endian; flip bit
   `(seed>>16) mod 16` in NLEN. The complement mismatch is `MalformedBlock` at
   input 5/output 0.
2. Fixed n A literals, length 285/distance 1, EOB: replace length 285 by
   reserved literal/length `286 + (seed mod 2)`. Its 8-bit symbol ends at bit `11 + 8*n`,
   yielding `ReservedEncoding` at input n+2/output n.
3. Fixed n A literals, length 257/distance 1, EOB: replace the 5-bit distance 0
   by reserved distance `30 + (seed mod 2)`. It ends at bit `15 + 8*n`, yielding
   `ReservedEncoding` at input n+2/output n.

Every checked-in mutated member has A5/5A appended to pin unconsumed suffixes.
No case uses reserved BTYPE 3. Each runs one-shot and at every input split with
one-byte output; the first typed error, offsets and work repeat on terminal calls.
The table records valid base, mutated bytes (including suffix), and expected
(kind,input,output):

| Base | Mutation | Expected |
|---|---|---|
| `010100feff6b` | `010100faff6ba55a` | MalformedBlock,5,0 |
| `010200fdffce4d` | `010200fdfbce4da55a` | MalformedBlock,5,0 |
| `010300fcffd5fa72` | `010300f8ffd5fa72a55a` | MalformedBlock,5,0 |
| `010400fbff308e0382` | `010400f3ff308e0382a55a` | MalformedBlock,5,0 |
| `010500faffcf4bf423cf` | `010500eaffcf4bf423cfa55a` | MalformedBlock,5,0 |
| `010600f9ffe24642cde246` | `010600fdffe24642cde246a55a` | MalformedBlock,5,0 |
| `010700f8ffd9981cfdd9981c` | `010700f8efd9981cfdd9981ca55a` | MalformedBlock,5,0 |
| `010800f7ff642cfa68642cfa68` | `010800f7fb642cfa68642cfa68a55a` | MalformedBlock,5,0 |
| `731c0500` | `731c0700a55a` | ReservedEncoding,3,1 |
| `73741c0500` | `73741c0300a55a` | ReservedEncoding,4,2 |
| `7374741c0500` | `7374741c0700a55a` | ReservedEncoding,5,3 |
| `737474741c0500` | `737474741c0300a55a` | ReservedEncoding,6,4 |
| `73747474741c0500` | `73747474741c0700a55a` | ReservedEncoding,7,5 |
| `7374747474741c0500` | `7374747474741c0300a55a` | ReservedEncoding,8,6 |
| `737474747474741c0500` | `737474747474741c0700a55a` | ReservedEncoding,9,7 |
| `73747474747474741c0500` | `73747474747474741c0300a55a` | ReservedEncoding,10,8 |
| `73040200` | `73047e00a55a` | ReservedEncoding,3,1 |
| `7374040200` | `7374043e00a55a` | ReservedEncoding,4,2 |
| `737474040200` | `737474047e00a55a` | ReservedEncoding,5,3 |
| `73747474040200` | `73747474043e00a55a` | ReservedEncoding,6,4 |
| `7374747474040200` | `7374747474047e00a55a` | ReservedEncoding,7,5 |
| `737474747474040200` | `737474747474043e00a55a` | ReservedEncoding,8,6 |
| `73747474747474040200` | `73747474747474047e00a55a` | ReservedEncoding,9,7 |
| `7374747474747474040200` | `7374747474747474043e00a55a` | ReservedEncoding,10,8 |
