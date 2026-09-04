# Compiler-owned x86-64 executable templates

The compiler keeps a closed registry for handwritten executable code that it
adds outside ordinary function lowering. The registry is evidence for later
native-code policy. It does not report that a template is CET-compatible and
does not assign final linked ranges.

`compiler_x64_executable_template.tl` defines the closed IDs, targets, ABIs,
feature predicates, contribution kinds, terminal behavior, and typed
control/frame events. `compiler_x64_executable_template_catalog.tl` is the
reviewed catalog. Runtime and direct-object owners must pass through the
catalog render gates before their code is emitted.

The checked inventory has these bounds:

| Kind | Rows | Payload identity |
| --- | ---: | --- |
| Assembly | 49 | 45 fixed variants are size/hash pinned; 4 startup fragments are dynamically composed |
| Opaque direct-object bytes | 24 | Every byte string is size/hash pinned |
| Structured direct-object contributions | 9 | Exact instruction/byte encoding is supplied by the object producer |
| Total | 82 | Registry storage capacity is 96 rows |

Runtime selection uses a fixed capacity of 20 IDs. The full Linux and Windows
sets select 13 and 15 rows, respectively. Profile and arena-debug combinations
have separate IDs, so a feature change cannot reuse the identity of a
different rendered variant.

Each row records its producer and schema, target and ABI, feature gate,
entry/interior/end anchors, related data, terminal behavior, and an ordered
event transcript. The transcript contains 2,499 reviewed events in 15,042
bytes. Its closed event codes are:

| Code | Meaning |
| --- | --- |
| `C`, `I` | Direct and indirect hardware calls |
| `R` | Hardware return |
| `T`, `J` | Direct and indirect tail transfer |
| `B` | Local branch |
| `A`, `X` | Stack-pointer adjustment and rebase |
| `S`, `U` | Saved and restored register |
| `D`, `W` | Read and write relative to the incoming stack |
| `P` | Terminal process transfer |
| `F` | External context switch |
| `E` | Externally entered callback |
| `O` | Explicit unsupported operation with named provenance |

Unknown codes fail parsing. `O` without provenance also fails. The Windows
startup rows classify `SwitchToFiber` as an external context switch with its
abnormal return path, and classify the fiber procedure and unhandled-exception
filter as externally entered callbacks. The three Windows callback/startup
ranges carry explicit `.pdata` relations to `.L_tl_start_xdata`; the relation
also pins the shared eight-byte unwind record's hash.

Ordinary local branches use the compact `B` token because their exact target
and encoding are already covered by the rendered-payload identity; semantically
special fallthrough and abnormal-return paths keep named provenance in their
own contribution rows. Stack-relative events retain the affected stack slot
without repeating the full assembly instruction.

`compiler-x64-template-semantic-identity` serializes every semantic field and
the exact rendered executable with length delimiters. This full serialization,
rather than the drift hash, is the canonical identity. It is independent of
registry insertion order, hash-table order, checkout path, arena history, and
worker count. The fixed-payload size and `stdlib.hash.string-key` values are
fast review tripwires: they make an edited assembly or opaque byte template
fail at its emission gate until the catalog row is deliberately updated.

The structural check
`scripts/check-x64-executable-template-registry.sh` pins all runtime gates,
startup gates, target-owned opaque byte helpers, structured contribution
boundaries, and the single target-owned `Bytes`/`Raw` construction gate. The
Windows unwind and resource builders remain data-only. Registry tests cover
closed parsing, identity mutations, target/ABI and anchor rejection, duplicate
selection, all profile/debug runtime variants, Windows context/callback
semantics, and the fixed construction bounds.

Final executable ranges, generated-function frame facts, native-link evidence,
and compatibility decisions belong to the later certification layers. Those
consumers must bind this exact semantic identity to their final range facts and
invalidate the result whenever it changes.
