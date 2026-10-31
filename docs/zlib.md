# Bounded zlib decoding and Adler-32

`(import stdlib.compress.zlib)` decodes the zlib format in [RFC 1950](https://www.rfc-editor.org/rfc/rfc1950.html):

- a two-byte header;
- an optional preset-dictionary identifier;
- a raw DEFLATE body, decoded by [`stdlib.compress.deflate`](deflate.md);
- a big-endian Adler-32 trailer.

It does not encode data, parse gzip, or supply reader/writer adapters.

`(import stdlib.compress.adler32)` is the canonical incremental Adler-32:

- `initial` is the checksum of empty input, 1;
- `update checksum bytes` folds in a borrowed chunk, and any chunking of the same bytes gives the same value;
- `checksum bytes` is `update` from `initial`.

Sums are reduced at least every 5552 bytes, so the signed 64-bit arithmetic cannot overflow. Adler-32 detects accidental corruption. It authenticates nothing.

[`examples/zlib_decode.tl`](../examples/zlib_decode.tl) decodes a stored member and preserves its trailing `TAIL` bytes. It and the conformance corpus run natively on Linux and Windows at optimization levels 0, 1 and 2.

## One-shot use

```typelisp
(import stdlib.compress.zlib)
(import stdlib.compress.deflate)
(import stdlib.byte_buf)

(define (main) : i64
  (let
    [input : byte_buf.ByteBuf (byte_buf.new)]
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    (set! input (byte_buf.push input (cast 120 : u8)))
    (set! input (byte_buf.push input (cast 156 : u8)))
    (set! input (byte_buf.push input (cast 3 : u8)))
    (set! input (byte_buf.push input (cast 0 : u8)))
    (set! input (byte_buf.push input (cast 0 : u8)))
    (set! input (byte_buf.push input (cast 0 : u8)))
    (set! input (byte_buf.push input (cast 0 : u8)))
    (set! input (byte_buf.push input (cast 1 : u8)))
    (match (zlib.decode
      (byte_buf.as-bytes (& input))
      (& limits)
      (& (zlib.ForbidDictionary)))
      [(zlib.ZlibDecodeOk decoded)
        (if (= decoded.consumed 8) 42 1)]
      [(zlib.ZlibDecodeErr _) 1])))
```

`decode input limits policy` returns `ZlibDecodeOk` with a `deflate.DeflateDecoded`. That value holds the owned bytes and the exact member length, including the trailer but excluding any following container bytes. Without a supplied dictionary, a member that names one fails:

- with `DictionaryForbidden` under `ForbidDictionary`;
- with `DictionaryRequired id` under `AllowDictionary`, where `id` is the member's dictionary identifier.

`decode-with-dictionary input limits dictionary` supplies a borrowed dictionary. It is checked against the identifier and preloaded when the member names one, and ignored otherwise.

Both wrappers loop over the incremental engine. They grow output exactly as `deflate.decode` does: the output capacity never exceeds `max-output`, and retired backing arrays total less than three times that limit until their arena is dropped.

## Incremental use

`decoder-new (& limits) (& policy)` returns `ZlibNewOk Decoder` or `ZlibNewErr ZlibError`.

- Its only allocation is the raw decoder's bounded history, at most 32 KiB of backing bytes. Construct the decoder in the arena that should own that history.
- The decoder value is 6160 bytes on Linux x86-64.
- Each later call allocates nothing and retains no chunk.

`step! (&mut decoder) input output eof` uses the same borrowed-chunk contract as `deflate.step!`. The returned `ZlibStep` reports per-call `consumed`, `produced` and `status`. Process the produced output prefix, and offer the unconsumed input suffix next time.

- `NeedInput`: another byte is necessary. With `eof` set, a missing byte is `Truncated` instead.
- `NeedOutput`: a decoded byte is pending; provide output space.
- `NeedDictionary id`: the member names a preset dictionary. Calls repeat this status with zero counts until `set-dictionary!` succeeds.
- `Done`: the trailer matched. The member is complete, and following input bytes are untouched.
- `Error error`: the member failed. This status is sticky.

`set-dictionary! (&mut decoder) dictionary` returns `DictionaryAccepted` or `DictionaryRejected error`.

- The dictionary is checked against the identifier.
- Its last `window-bytes` bytes become history through `deflate.decoder-prime!`, so references may reach into it.
- A mismatch is a sticky `DictionaryMismatch`.
- A call while the decoder is not awaiting a dictionary is rejected with `InvalidState` and changes nothing.
- Callers holding several candidates can compare `adler32.checksum` with the identifier first.
- No dictionary is ever found through I/O or global state.

Output is tentative until `Done`. A checksum or length failure never reports `Done` or one-shot success. A caller that streamed output earlier must discard or roll it back. Repeated terminal calls return their terminal status with zero counts. No next-member decoding occurs: call `decoder-new` again on the unconsumed suffix.

`input-total`, `output-total` and `work-total` report the cumulative member counts.

## Header policy

The header is validated once both bytes are present, in zlib's order:

1. `InvalidHeaderCheck`: `CMF * 256 + FLG` is not a multiple of 31.
2. `InvalidMethod`: CM is not 8.
3. `InvalidWindow`: CINFO is above 7.
4. `WindowLimit`: the declared window, `2^(CINFO + 8)` bytes, exceeds `window-bytes`. This is decided before any body byte, independently of the data.
5. `DictionaryForbidden`: FDICT is set under `ForbidDictionary`, as Git's object and pack containers require.

FLEVEL is informational and ignored. Within the configured history, a reference is accepted even when it lies beyond the declared window, as in zlib's default inflate.

## Limits and work

zlib reuses `deflate.DeflateLimits` and its defaults. One budget covers the whole member, and framing bytes are counted:

| Field | What zlib counts |
|---|---|
| `max-input` | Every member byte: header, dictionary identifier, DEFLATE body and trailer. |
| `max-output` | Decoded bytes only. Dictionary bytes are history, not output. |
| `window-bytes` | History capacity. It must cover the declared window. |
| `max-work` | Raw initialization, 1 unit per framing byte, 1 per dictionary byte, then the raw body charges. |
| `ratio`, `startup-bytes` | Output against every member byte accepted so far, header included. |

Each framing byte is checked when it is needed:

- a missing byte suspends;
- an available byte past `max-input` is `InputLimit`;
- an available byte past `max-work` is `WorkLimit`.

This is the raw decoder's precedence. Header bytes enter the raw counters when the body starts. Trailer bytes are counted after the body. The Adler-32 update is covered by the raw decoder's per-byte emission charge, so no unit is charged after output. Every decision depends only on cumulative counts and byte availability, so chunking cannot change it. The tests decode each limit case at every input split and require identical outcomes, positions and work.

The default ratio of 1024 is below DEFLATE's maximum expansion of about 1032:1, so extremely compressible members may need a larger ratio or startup allowance ([#9532](https://github.com/JoNil-Botta/typelisp/issues/9532)).

## Failures

`ZlibError.kind` includes every raw DEFLATE kind, mapped one to one. It adds `InvalidMethod`, `InvalidWindow`, `InvalidHeaderCheck`, `DictionaryForbidden`, `DictionaryRequired id` (one-shot only), `DictionaryMismatch` and `ChecksumMismatch`.

`input` and `output` are cumulative member-input and output counts at the failure. Raw body failures report member positions, header included. No payload bytes enter diagnostics.

Public state fields are implementation state. Safe calls validate them and return `InvalidState` for inconsistencies.

[Fixture provenance](../tests/fixtures/zlib/README.md) records the offline generator. Tests need no host zlib.
