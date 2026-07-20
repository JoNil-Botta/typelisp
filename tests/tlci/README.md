# TLCI format corpus

This directory is the executable stability artifact for the binary format
specified by `SPEC.md` section 5.17.1. The specification remains the only
normative format description.

The current container format is version 2: a 176-byte header plus an imports
section that binds GOT slots to host entry points by stable ABI id. Format
version 1 has been removed — there were no external consumers — so the parser
and emitter target v2 only.

The checked-in `.tlci` files pin the current format. `valid-metadata-only.tlci`
pins the minimal container, while `valid-sections.tlci` pins page-aligned
rodata/code and one fixup, entry, and symbol record without executing its inert
code bytes. Malformed fixtures pin parser diagnostics for magic, truncation,
version, hash, layout, and metadata failures.
`scripts/verify-tlci-corpus.sh` passes these files to the public inspector on
Linux and Windows and compares exact stdout/stderr.

The gate also runs `corpus_emit.tl` and byte-compares its two outputs with the
checked-in valid images. A synchronized emitter/parser change therefore cannot
silently redefine the format.

## Regenerating the corpus

The fixtures are reproducible. `corpus_emit.tl` emits the two valid images; the
malformed fixtures are those images with a single documented corruption applied
(bad magic, truncation, an unsupported version field, a broken content hash, a
misaligned or overlapping metadata section, and corrupt metadata text). When a
deliberate format change lands, regenerate every fixture together with its
expected `stdout`/`stderr` and `SHA256SUMS`, and review the header fields,
offsets, records, and rolling content hash against `SPEC.md` section 5.17.1.

The valid fixture layout is summarized for review:

| Fixture | Build hash | Metadata | Rodata | Code | Fixups | Entries | Symbols |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| `valid-metadata-only.tlci` | `tlci-v1-corpus` | `corpus.empty` 1.0.0 | 0 | 0 | 0 | 0 | 0 |
| `valid-sections.tlci` | `tlci-v1-corpus` | `corpus.sections` 1.0.0 | 4 bytes at 4096 | 3 bytes at 8192 | 1 | 1 | 1 |
