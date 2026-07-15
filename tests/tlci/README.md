# TLCI v1 compatibility corpus

This directory is the executable compatibility artifact for the binary format
specified by `SPEC.md` section 5.17.1. The specification remains the only
normative format description.

The checked-in `.tlci` files are immutable. `valid-metadata-only.tlci` pins the
minimal container, while `valid-sections.tlci` pins page-aligned rodata/code and
one fixup, entry, and symbol record without executing its inert code bytes.
Malformed fixtures pin parser diagnostics for magic, truncation, version, hash,
layout, and metadata failures. `scripts/verify-tlci-v1-corpus.sh` passes these
same files to the public inspector on Linux and Windows and compares exact
stdout/stderr.

The gate also runs `v1_corpus_emit.tl` and byte-compares its two outputs with
the checked-in valid images. A synchronized emitter/parser change therefore
cannot silently redefine v1. The emitter witness is not a fixture generator:
it writes only under `target/`, and the gate never modifies this directory.

## Review policy

- Never rewrite a v1 fixture to accommodate an emitter or parser change.
- Compatible parser fixes may add malformed fixtures and expected diagnostics.
- A deliberate incompatible format change requires a new format version and a
  separately named corpus; retain this v1 corpus unchanged.
- Review fixture header fields, offsets, records, and rolling content hash
  directly against `SPEC.md` section 5.17.1.

The valid fixture layout is summarized for review:

| Fixture | Build hash | Metadata | Rodata | Code | Fixups | Entries | Symbols |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| `valid-metadata-only.tlci` | `tlci-v1-corpus` | `corpus.empty` 1.0.0 | 0 | 0 | 0 | 0 | 0 |
| `valid-sections.tlci` | `tlci-v1-corpus` | `corpus.sections` 1.0.0 | 4 bytes at 4096 | 3 bytes at 8192 | 1 | 1 | 1 |
