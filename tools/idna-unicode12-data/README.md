# TypeLisp IDNA Unicode 12 data

This is the explicitly reviewed `typelisp-idna-unicode12-v1` protocol profile
for [#7269](https://github.com/JoNil-Botta/typelisp/issues/7269), using only
Unicode 12.0.0. It is independent of the Unicode 17 filename collision data
planned in #7208. IDNA2008 itself does not mandate Unicode 12: IANA's
[registry notice](https://www.iana.org/assignments/idna-tables-12.0.0/)
distinguishes its reviewed derived-property convenience snapshot from the
normative contextual rules that update RFC 5892.

`pins.tl` records the eight exact source URLs, sizes and SHA-256 digests. All
inputs are checked before parsing. `inputs/` preserves upstream bytes,
including the IANA CSV record endings. Unicode files retain their original
copyright notices; [UNICODE-LICENSE.txt](UNICODE-LICENSE.txt) accompanies both
the inputs and their derived tables. IANA protocol registry rights are
covered by the [IANA/IETF CC0 dedication](https://www.iana.org/help/licensing-terms)
and [CC0 text](IANA-CC0-LICENSE.txt).

Generate from the repository root:

```sh
typelisp run tools/idna-unicode12-data/generate.tl --stdlib-root stdlib -- tools/idna-unicode12-data/inputs stdlib/generated/idna_unicode12_data.tl
TYPELISP_BIN=/path/to/typelisp scripts/verify-idna-unicode12-data.sh
```

Generation and verification are offline. There is no fetch mode, host Unicode
query, locale-dependent operation, or package dependency. The verifier builds
native tools once, regenerates into temporary output, compares without
rewriting checked-in tables, exercises parser rejection, and runs exhaustive
scalar properties and all 18,819 normalization vectors on Linux and Windows.

The public module is `stdlib.idna_unicode12`. `lookup` accepts a scalar integer
and returns `InvalidScalar` or closed derived, script, joining, bidi, Mark,
combining-class and NFC quick-check properties. Non-scalars, including
surrogates, fail closed. `context` returns one of nine reviewed rule identities
and separate registration/lookup applicability. It does not evaluate rules.
`decomposition`, `decomposition-at`, and `composition` expose canonical data;
Hangul is represented by the standard constants. Missing decomposition and
invalid input are distinct. Checked spans cannot read beyond the pool.

The generated module stores fixed-width unsigned integers as uppercase ASCII
hex in static read-only string literals. Each IDNA range is `u24 first`,
`u24 last`, `u8 property`; support ranges are `u24 first`, `u24 last`, `u32
properties`; decomposition indexes are `u24 scalar`, `u32 pool offset`, `u8
count`; pool elements are `u24`; composition triples are three `u24` values.
Context ranges contain two `u24` endpoints, `u8 rule`, and `u8 flags`.
This encoding avoids startup allocation and large executable array constructors.
Binary searches inspect at most 12 rows per current table; pool reads are
direct. Scalar lookup has no whole-table scan or allocation.

Support bits contain CCC (0–7), Mark (8), contextual Script (9–11), Joining_Type
(12–14), Bidi_Class (15–19), and NFC_QC (20–21). Script values outside Greek,
Hebrew, Hiragana, Katakana and Han are explicitly `OtherScript`. Joining defaults
to NonJoining, bidi to L except where the pinned derived file explicitly supplies
another value, CCC to zero, Mark to false, and NFC_QC to Yes. JoinCausing and
all 23 bidi classes remain distinct. The source parsers verify assigned bidi
values against UnicodeData, property-group ordering, and cross-group overlap.

The test-only normalization consumer implements canonical decomposition,
ordering and composition and checks all five oracle columns' NFC/NFD relations.
It also covers every Hangul syllable and both range boundaries. No normalization,
UTF-8 decoding, mapping, Punycode, label validation or DNS behavior is shipped
by this data module. The property formats and normalization rules are documented
in [Unicode 12 UAX #44](https://www.unicode.org/reports/tr44/tr44-24.html),
[UAX #15](https://www.unicode.org/reports/tr15/), and
[RFC 5893](https://www.rfc-editor.org/rfc/rfc5893.html).

Any Unicode version or registry revision requires a new reviewed schema/data
change: update byte pins, licenses, closed vocabularies, rule identities and
independent conformance expectations together. Never replace these URLs with
`latest`, silently import Unicode 17 tables, or bypass pin failures.
