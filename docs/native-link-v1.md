# Native-link v1 semantic contract

`native_link_manifest` is the pure admission API for #7037. Its owned records
are read through immutable borrows. Builders transfer ownership; validation is
repeated when a caller presents a changed record. No cached acceptance flag can
make a subsequent mutation trusted.

The next production consumers are #7421–#7424, #7368,
#7099/#7103, and #7266. This foundation does not migrate source/package/CLI
producers, discover tools, run an external adapter, read object files, resolve
symbols, or write an image. `build_run_core.SourceToolLinkInputs` is not imported.

## Semantic and operational ownership

`NativeLinkManifest` binds a target, ABI, output kind, logical artifact,
reproducibility policy and exact resolved-profile digest. Its single ordered
vector contains every input and control together with its provenance. Each event builder preallocates at most 65,536 slots and latches the first
capacity/type/budget error. Dependency section lowering preflights borrowed
requirements before cloning them; finishing preflights live data again. Ordinals
are dense from zero and event IDs are `e0`, `e1`, … . Equal payloads remain
separate events. Groups, whole-archive and preference scopes nest by kind and
ID; scopes cannot cross or reuse an active ID.

`NativePathRef` contains an ASCII logical root ID, nonempty relative bytes,
file kind and optional SHA-256 identity. Relative names use `/`, contain no
empty, `.` or `..` component, and contain no backslash, colon, NUL or control
byte. IDs use ASCII letters, digits, `.`, `_`, `:`, `-`. Symbols and declaration
names are nonempty control-free byte strings; they are not locale-folded or
assumed to be valid UTF-8. A package origin names a package-manifest file and an
object-directive origin names an object file. Source spans use checked u64
start/length arithmetic.

Host root bindings, output/tool paths and worker counts exist only in
`NativeLinkInvocation`, which the semantic codec does not accept. Presentation
options are separate. No environment, current directory, filesystem or process
API is consulted. Logical paths are shown without operational root expansion;
non-ASCII and control bytes in human output are escaped byte by byte.

PE image alignment follows the [Microsoft PE specification](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format):
file alignment is a power of two from 512 to 65,536; section alignment fits
u32, is no smaller, and matches file alignment below the v1 x64 4 KiB page.
Export ordinals are PE-only; ELF visibility requests reject on PE.

`NativeToolchainProfile` declares runtime/floor, target/ABI, output set, logical
roots and files, ordered startup/end/default/runtime file schedule, runtime
contracts, entry/startup/image/interpreter/debug policies, system-import map,
34 closed capability rows and nine hardening rows. Every capability must occur
exactly once. Unknown versions, schema/helper identities, duplicate set keys,
missing runtime contracts and incompatible target/output/debug/CRT policies
reject. Each runtime family must select its dedicated v1 runtime contract;
compiler freestanding profiles also select the platform contract. Resolved
profile entry names and interpreter paths validate independently of whether
the chosen output uses those defaults, and a profile interpreter cannot refer
to itself. A supported row uses the `Implemented` reason and a known selected
runtime contract. Unsupported rows have a stable non-Implemented reason.
Hardening states preserve the distinct `Required`, `Off`, `Forbidden` intent.
V1 has no admitted feature-specific hardening proof: required rows serialize,
but semantic admission rejects them. A generic runtime ID cannot certify CFG,
CET, `/GS` or another hardening property; consumers need a dedicated versioned
feature contract rather than inferring proof from runtime availability.

The profile file schedule is ordered. A profile input event must match its
selected file, content identity and position. A CRT startup identifies a file
in that schedule; `ProfileStartup` requires startup inputs. Executables require
an explicit entry policy. A freestanding executable requires the dedicated
`typelisp.compiler-startup.v1` contract; another selected runtime helper cannot
be relabeled as compiler startup. Non-freestanding
runtime files require exact content identities and a nonzero runtime floor.
V1 ordered file inputs admit object/archive/shared/import-library kinds. A
linker script needs a future typed contract rather than an opaque input option.

## API and classification

The modules have narrow responsibilities:

| Module | Responsibility |
| --- | --- |
| `native_link_manifest_types` | Closed v1 records and operational types |
| `native_link_manifest_builder` | Bounded event builder, explicit profile controls, dependency/artifact origins |
| `native_link_manifest_profiles` | Pure Linux/Windows freestanding constructors |
| `native_link_manifest_core` | Bounded semantic validation and backend representation decision |
| `native_link_manifest_budget` | Borrowed typed preflight before any owned codec clone |
| `native_link_manifest_wire` | `stdlib.serialize` strategy and byte-key order |
| `native_link_manifest_binary` | Bounded canonical framing and two-pass parser |
| `native_link_manifest_codec` | Typed records, declared-set normalization and profile digest |
| `native_link_manifest_render` | Bounded human tree renderer |
| `native_link_manifest` | Validated encode/decode/fingerprint/render boundary |

`encode`, `decode` and `fingerprint` require a complete valid semantic input.
The record codec primitives are lower-level shape/canonicality operations;
consumers use the public admission API before opening inputs or outputs.
`classify` returns a representation decision with stable diagnostics and a
separate content-closure requirement. Representation availability does not
certify a target writer or its output.

`ExternalCompatibilityArg` owns exactly one argv element. It is byte-exact,
including spaces, quoting, `@`, option-like text and control bytes other than
NUL. It is never split, interpreted as GNU/MSVC options, expanded as a response
file or shell command. Its presence requires explicit external compatibility;
internal and auto selection reject it with its original event ordinal.
External selection returns `ExternalAdapterAdmissionRequired`, including an
opaque-closure requirement. This is not permission for a sealed adapter to
accept it; #7423 can reject every opaque element.

The canonical link/profile digest is one child projection for #7494/#7266,
not a complete cache key. Consumers separately admit file/tool contents and
closure observations. Equivalent physical bindings are interchangeable only
for the same admitted closure. Canonical bytes cannot discover dependencies
hidden in an opaque argv element.

## Canonical wire bytes

All multi-byte integers are little-endian. The 32-byte header is:

| Offset | Bytes | Meaning |
| --- | --- | --- |
| 0 | 12 | ASCII `TLNATIVELINK` |
| 12 | 2 | Wire version 1 |
| 14 | 2 | Document kind: manifest 1, profile 2, combined input 3 |
| 16 | 8 | Exact body length, including root node header |
| 24 | 8 | Exact total node count, including root |

Each node has a u8 tag and u64 payload length, followed by exactly that payload:

| Tag | Payload |
| --- | --- |
| 0 | Null, zero bytes |
| 1 | One Boolean byte, exactly 0 or 1 |
| 2 | Eight-byte negative signed integer |
| 3 | Eight-byte unsigned integer; also all nonnegative signed values |
| 4 | Raw string bytes |
| 5 | u32 element count followed by nodes |
| 6 | u32 field count; each field is u32 key length, key bytes, node |

Record keys are strictly increasing unsigned byte strings. Enum records use
`tag` plus an ordered `payload` sequence; names are closed by the typed schema.
Integer decoding checks the destination width. No floating-point or unknown
field/enum encoding is admitted. Re-encoding after typed decode must reproduce
the exact input bytes, rejecting unknown fields and noncanonical set order.

Only declared sets sort: manifest roots; profile outputs, roots, files, runtime
IDs, import symbols, capability kinds and hardening features. Keys are their
logical IDs or unqualified enum tag bytes. Events and profile input schedules
retain order and duplicates. A profile identity is SHA-256 over its kind-2
canonical frame; the profile contains no circular self-digest. A semantic
fingerprint hashes the complete validated kind-3 frame.

Schema version 1 accepts extension version 0 only. #8195's IFUNC contract,
final ELF loader policy, SFrame dialect and Windows fiber/CET runtime records
require an explicit version/extension design; no extra bytes or capability
proof are silently attached to v1.

## Bounds and diagnostics

Default wire limits are 32 MiB framed bytes, 262,144 nodes, depth 48, 16 MiB
aggregate strings, 64 fields per record, 256 MiB charged work and 512 MiB
charged retained storage. Typed preflight charges 4,096 per node and 256 per
string byte before cloning. Parser charges additionally cover framing and
container storage. These are conservative v1 operation budgets, not process
RSS or arena page-commit measurements. Hard process-tree caps remain necessary
for tests and compiler work.

Semantic limits add 16,384 events, nesting 64, 256 diagnostic slots and 16,384
bytes per opaque argv element. Invalid limits reject. Full binary preflight
precedes input-sized retained allocation, using subtraction for ranges and
checked counts; construction repeats the same scan over immutable input. The first pass reserves
the second pass's charged work before any input-sized construction.
Validation reserves work for identity cross-checks before quadratic scans.
The profile input/file join is built once after preflight and reused for all
events, bounding profile references without a repeated three-way search.
Diagnostics follow header/profile/event order. Profile-digest and reserved-built-in
identity checks remain independent of other semantic errors; only a resource
stop prevents further traversal. A zero diagnostic limit still
retains failure and truncation. `complete=false` marks a resource/limit stop;
ordinary semantic errors do not hide independent backend-selection reasons.

## Built-ins and tests

Both reserved built-in IDs require the exact normalized v1 profile record.
They support relocatable, static-archive and freestanding-static executable
outputs, compiler `_tl_start`, and explicit compiler runtime contracts. They
have no roots, startup/end/default files, C runtime archives or interpreter.

Linux identifies compiler startup, TypeLisp runtime and Linux syscalls. Windows
preserves console and 256 MiB stack reserve, with no CRT or SDK import archives.
Its exact map is `ConvertThreadToFiber`, `CreateFiberEx`, `ExitProcess`,
`GetCommandLineA`, `GetStdHandle`, `SetThreadStackGuarantee`,
`SetUnhandledExceptionFilter`, `SwitchToFiber`, `WriteFile`, `VirtualAlloc`,
`VirtualFree` in `kernel32.dll`, and only `NtCreateFile` in `ntdll.dll`.
`ws2_32`, unknown functions and different DLL mappings reject. The map does not
claim CFG, CET, `/GS`, delay-load or ASLR proof. Windows ASLR is explicitly
forbidden in this built-in; other unimplemented hardening remains off.

`src/tests/native_link_manifest_*` checks admission, scopes, all origin classes,
canonical sensitivity, exact bounds, declared-set equivalence and byte mutation
agreement with an independent bounded test decoder. Six byte-exact golden
frames in `tests/fixtures/native-link` are generated by an independent Python
reference implementation. Normal tests embed them and run no external tool,
SDK, registry, network or filesystem discovery. The generator is an offline
reference for intentional wire revisions, not an automatic golden updater.
