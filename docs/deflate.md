# Bounded raw DEFLATE decoding

`(import stdlib.compress.deflate)` provides the raw format in [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951.html). It supports stored, fixed-Huffman and dynamic-Huffman blocks, overlapping matches and history across blocks. It does not parse zlib or gzip framing, encode data, or supply generic reader/writer adapters.

[`examples/deflate_decode.tl`](../examples/deflate_decode.tl) decodes a stored member and preserves its trailing `TAIL` bytes. Both it and the conformance corpus run natively on Linux and Windows at optimization levels 0, 1 and 2.

## One-shot use

```typelisp
(import stdlib.compress.deflate)
(import stdlib.byte_buf)

(define (main) : i64
  (let
    [input : byte_buf.ByteBuf
      (byte_buf.push (byte_buf.push (byte_buf.new) (cast 3 : u8)) (cast 0 : u8))]
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    (match (deflate.decode (byte_buf.as-bytes (& input)) (& limits))
      [(deflate.DeflateDecodeOk decoded)
        (if (= decoded.consumed 2) 42 1)]
      [(deflate.DeflateDecodeErr _) 1])))
```

`DeflateDecoded.bytes` is an owned `byte_buf.ByteBuf`. `consumed` is the compressed member's byte length, including its last partially used byte but excluding any following container bytes. Output remains binary; text conversion is an explicit caller decision.

`decode` loops over the same engine as the incremental API. Its output backing capacity never exceeds `max-output`. Geometric growth can retain retired arrays until the owning arena is dropped; their combined capacity is less than three times that limit. The decoder's history backing (`window-bytes`, 32 KiB by default) also stays in the caller's arena until it is dropped. No decoded-size field controls an allocation.

## Incremental use

`decoder-new (& limits)` returns `DeflateNewOk Decoder` or `DeflateNewErr DeflateError`. Construct the decoder in the arena that should own its history and workspace. No chunk is retained.

`step! (&mut decoder) input output eof` takes immutable borrowed `bytes` and a caller-owned mutable `bytes` view. Use `byte_buf.as-bytes`, `as-mut-bytes`, and their slice-view helpers. A buffer created with `byte_buf.from-array` has its whole array live, which is useful for a reusable output chunk. The returned `DeflateStep` contains per-call `consumed`, `produced` and `status`. Process only that output prefix; offer the unconsumed input suffix on the next call.

- `NeedInput`: another input byte is necessary. Supply a new chunk, retaining any unconsumed suffix.
- `NeedOutput`: a literal or match byte is pending. Drain the produced prefix and provide output space.
- `Done`: one complete member ended. Keep the unused input suffix for the container.
- `Error error`: decoding failed. Already produced output is partial and must not be treated as a successful member.

Set `eof` when no input follows the offered chunk. After `NeedOutput`, continue with its unconsumed suffix and the same final-chunk promise. A required byte missing at explicit EOF produces `Truncated`, never `NeedInput`. The flag does not force consumption of a trailing container suffix.

An empty call can progress using buffered bits or pending output. Otherwise it needs input. Zero output capacity can parse metadata and complete an empty member; a pending output byte gives `NeedOutput`. If that byte violates a limit, the typed limit failure takes precedence. Repeated terminal calls produce zero counts and repeat their terminal status. No automatic reset or next-member decoding occurs.

## Containers and preset history

`decoder-prime! (&mut decoder) prefix dictionary` prepares a fresh decoder, before its first `step!`, for a containing format such as [zlib](zlib.md):

- `prefix` counts container bytes already accepted, such as a header. They count toward `max-input`, ratio credit and work, so one budget covers the whole container member.
- The last `window-bytes` bytes of `dictionary` become history that references may reach, as for RFC 1950 preset dictionaries. A reference may reach back over emitted output plus that preset; anything earlier is `InvalidDistance`.
- Priming charges one work unit per prefix byte and per dictionary byte, before any copy.
- It returns false without change for a decoder that has already started. It also returns false, with a sticky `InputLimit` or `WorkLimit`, when a limit is exceeded.

Only a byte needed for the current field or Huffman symbol is accepted. Stored-block alignment and final-byte padding discard the remaining bits of the current byte, with no requirement that they be zero. No speculative look-ahead consumes a following container byte.

## Limits and work

`DeflateLimits` fields are all nonnegative signed 64-bit bounds:

| Field | Meaning |
|---|---|
| `max-input` | Total member bytes accepted, including the partially used final byte. |
| `max-output` | Total decoded bytes emitted. |
| `window-bytes` | Retained history capacity, from 0 through 32768. |
| `max-work` | Cumulative semantic work budget, including initialization. |
| `ratio` | Maximum additional output per accepted input byte. |
| `startup-bytes` | Output allowance before ratio accounting requires input credit. |

Defaults are 64 MiB input, 256 MiB output, 32768 history bytes, 2147483647 work units, ratio 1024 and startup allowance 1024. Applications should choose limits for their workload. A smaller history window can decode literals/stored bytes and nearby references; a valid reference outside it fails with `WindowLimit`. References before the beginning of decoded output fail with `InvalidDistance`.

Every emission must satisfy `total-output <= startup-bytes + ratio * total-input`. The implementation uses division and subtraction to avoid overflowing the multiplication. Accounting is cumulative across chunks and blocks. Ratio zero permits only the startup allowance.

Work charges are independent of input/output chunk splitting:

- Initialization: 721 fixed workspace cells plus `window-bytes`, charged before allocation.
- Priming: 1 unit per container prefix byte and per dictionary byte.
- Each accepted input byte: 1 unit; each consumed bit: 1 unit.
- Each emitted byte: 1 unit.
- Fixed table preparation: 1054 units per fixed block.
- Dynamic preparation: 19 units to clear the code-length workspace, 85 to build its tree, 1 per materialized combined alphabet length, and `94 + 2 * (literal-count + distance-count)` to build the final trees.

Charges precede the corresponding bounded action. A suspended attempt, repeated empty call or terminal call adds no semantic work. Empty blocks still consume charged header bits, so an empty-block chain cannot evade the limit. These units bound decoder actions, not elapsed time or machine instructions. Each call also has fixed bounded argument/state validation overhead.

The decoder embeds 721 fixed integer workspace slots and owns a `ByteBuf` history of at most 32768 bytes. Only the history backing storage requires an arena allocation; the fixed tables are part of the decoder value. On Linux x86-64, the full-window backing allocation measures 32784 bytes and the decoder value is 6072 bytes, totaling 38856 bytes of retained decoder storage. The streaming engine performs no further allocation, including table rebuilds and suspended symbols/matches. Drop the owning arena to release its history; caller chunk arenas may be dropped after each call. The conformance tests exercise this separately from dropping a partial decoder.

## Failures and state integrity

`DeflateError.kind` distinguishes `InvalidLimits`, `InvalidState`, `MalformedBlock`, `MalformedTree`, `InvalidCode`, `Truncated`, `ReservedEncoding`, `InvalidDistance`, `Overflow`, and the input/output/window/work/ratio limits. `input` and `output` record cumulative accepted/emitted byte counts at the failure. They are progress positions, not a promise to identify the first offending bit. No payload bytes enter diagnostics.

Tables reject oversubscription, missing end-of-block codes and invalid incomplete trees. Legal single-one-bit-symbol trees and literal-only blocks with an empty distance alphabet are accepted. Dynamic distance alphabets may describe 32 slots; reserved symbols 30/31 are rejected if decoded. The [fixture provenance](../tests/fixtures/deflate/README.md) records that zlib rejects HDIST=32 headers and therefore is not the oracle for that RFC-derived fixture.

Public state fields are implementation state, not a serialization format. Do not edit them. Safe calls nevertheless validate shapes/scalars and check table-derived indices before use. Forged state cannot introduce unchecked decoder memory access; detected inconsistencies return `InvalidState`. No unsafe decoder helper is exposed through a safe wrapper.
