Refs #7785 — raw DEFLATE fixture provenance

Required tests use only checked-in TypeLisp byte literals and generators. The optional development oracle was Python standard-library zlib 1.3.2; it is not a build or test dependency. Random fixture seed: 7785. Handwritten streams were emitted from canonical RFC 1951 codes; expected output follows their explicit literal/match sequence.

The HDIST=32 fixture is intentionally RFC-derived: its reserved distance slots are unused. zlib rejects the header before decoding it, so it is not an oracle for this case. This difference is retained explicitly rather than changing the RFC contract.

Valid cases (compressed SHA256):

0. empty-fixed — 9b4fb24edd6d1d8830e272398263cdbf026b97392cc35387b991dc0248a628f9 — RFC fixed EOB, final padding 0
1. empty-fixed-padding-ones — 338b670f2f97e2c25b7345cf670fba827360a3a0e053e2912e392aa7d545b7c5 — RFC fixed EOB, final padding 1
2. empty-stored — f067985d352d2da6dfaef4844a66d06c5371ecbd9530a4d195ac599fef8b3427 — RFC stored LEN0
3. stored-padding-ones — 0fe02497a2d2ad79f8f00d67b596d4a647f792b2f816ea56f49b22bdea632729 — RFC stored alignment padding 1
4. overlap-258 — f6d3edd5d7a24b2e2a8ef366c633bb4013a7e89773f60af93b23e056fe4dbb9f — handwritten fixed length258/distance1
5. cross-block-overlap — 64b1eda649b741e162c2a56db4960f1b4e9936aeaa12ac4974cf2a30f38cdfb3 — two fixed blocks; history crosses block
6. dynamic-eob-only-empty-distance — cfa639a93873ee1a021b5da2a30691dbfabae7e75d7fd1589d1b9cd8a30d2f43 — one-bit EOB and empty distance alphabet
7. dynamic-literals-empty-distance — d17911ad7a81e25ab48790cd407ec2b8b838ef41c80700ac879a370b67eac691 — literal-only dynamic block
8. all-repeat-codes — eaadd5905d71c5a5b14356aaab5e90ddf1bdd994f6075c926b3d389665f72bdc — codes16/17/18; zero and nonzero repeats
9. repeat-across-alphabets-hdist32 — 0753879e9a1a8fbc3cb14c74f3c290076bc4fb109c6e3099c0a3948e8d7e1f10 — repeat16 crosses EOB into distances; reserved slots unused; RFC HDIST32 case; zlib rejects header: Error -3 while decompressing data: too many length or distance symbols
10. random-fixed-0 — 4b284d922e56b678ec1dfc563840d51639958766ff873cd4795fb1996f06cde0 — Python zlib 1.3.2 Random7785 sequential, Z_FIXED
11. random-fixed-1 — be1abec583caffabb817a5729312d32443c1dd923b32af02990b1039f9ae0705 — Python zlib 1.3.2 Random7785 sequential, Z_FIXED
12. random-fixed-2 — 0f2630e07e7231c2a41d1c718f56b8e9009631a196861b2161094dd63a1d7b34 — Python zlib 1.3.2 Random7785 sequential, Z_FIXED
13. random-fixed-3 — 69468a9e71267bf76d3b7fffbbfad7a597d085b8f2e54c70d4a57b02fa42ad6b — Python zlib 1.3.2 Random7785 sequential, Z_FIXED
14. random-fixed-4 — 2c5c17aa92d1565b143dfd491108f3e82bb019128c349365c369a07635aeb833 — Python zlib 1.3.2 Random7785 sequential, Z_FIXED
15. random-fixed-5 — 692ecbc55478f7bc11ab37fac9faeed0dbfca489c6e25ee5dc5f15b812fa7861 — Python zlib 1.3.2 Random7785 sequential, Z_FIXED
16. random-fixed-6 — 79b01d4ed63a9da344322f08978c54716ad1194133489386217513f7db6fffe4 — Python zlib 1.3.2 Random7785 sequential, Z_FIXED
17. random-fixed-7 — fb09719ab2bd799d308168eb0b80dedfb650e867d4bdefcdef622f78059f3bb8 — Python zlib 1.3.2 Random7785 sequential, Z_FIXED
18. zlib-dynamic-text — 70043b77cd751bab933e58f6050dbf7e9eb894a33b10ff3afaa0d57b1c4cdda5 — Python zlib 1.3.2 level6; seeded weighted alphabet
19. distance32768-window-wrap — ef0fc41036c8534bf3948fd2c40057a19f13dd14be0c29f0e6d6d13ee205e5d4 — fixed distance32768 after exactly32768 bytes

Malformed cases:

reserved-block — ReservedEncoding — 07 — BTYPE3
bad-stored-complement — MalformedBlock — 010100ffff41 — LEN1/NLEN65535
reserved-literal286 — ReservedEncoding — 1b03 — fixed reserved286
reserved-literal287 — ReservedEncoding — 1b07 — fixed reserved287
reserved-distance30 — ReservedEncoding — 73043e — fixed reserved distance
reserved-distance31 — ReservedEncoding — 73047e — fixed reserved distance
distance-before-output — InvalidDistance — 030200 — distance1 with empty history
reserved-hlit30 — ReservedEncoding — f5 — HLIT beyond286
reserved-hlit31 — ReservedEncoding — fd — HLIT beyond286
oversubscribed-clen — MalformedTree — 05009200 — code-length alphabet invalid
incomplete-clen — MalformedTree — 05000200 — code-length alphabet invalid
repeat16-first — MalformedTree — 05000224 — repeat16 without predecessor
repeat-overflow — MalformedTree — 050080e4ff1f — repeat over combined length count
missing-eob — MalformedTree — 050080e47f1b — all lengths zero, no EOB
unused-singleton-code — InvalidCode — 05c0810800000000207feb0b0000 — unused half of one-bit literal alphabet

All-code boundary corpus: 429 compressed bytes, 36321 repeated A bytes, 191 field-boundary split positions; compressed SHA256 220496387a8f1cd22e807d8775ef16b80bb18140f14bf2dceda132d0a6b4e6bd. Each length/distance code is exercised at both ends of its extra-bit range (code284 capped at length257); the complete stream agrees with the optional zlib oracle.
