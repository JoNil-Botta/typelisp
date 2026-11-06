# TypeLisp Stdlib Source Tree

This directory is the canonical in-repo standard-library source tree for the
current explicit-root model. Files here are ordinary TypeLisp modules loaded by
the same `import` mechanism as project-local files.

This document describes the source-tree convention only. TypeLisp package
builds support local path dependencies declared in `typelisp.pkg`. Import a
dependency module by its dotted dependency-alias identity, for example
`(import math.src.lib)`; see [Packages](../docs/packages.md). The compiler-owned
stdlib is not a package dependency. TypeLisp still does not define registry or
version solving or default installed-root discovery.

Imports are qualified by default: `(import stdlib.string)` binds the module
alias `string`, and its members are accessed as `string.eq`, for example.
Use an explicit selected import such as `(import stdlib.string.eq)` or a
wildcard import such as `(import stdlib.string.*)` to bring items into the
local unqualified namespace. Legacy string-path imports have been removed;
use `(import stdlib.string)` instead of `(import "stdlib/string.tl")`.

The compiler injects `stdlib.runtime` and `stdlib.core_macros` as an implicit
prelude, so core macros such as `when`, `unless`, `and`, and `or` are available
without explicit imports. See the [language guide's module and import
rules](../docs/language-guide.md#modules-and-imports).

The in-tree private dynamic-buffer census lives in
[`DYNAMIC_ARRAY_CENSUS.md`](DYNAMIC_ARRAY_CENSUS.md). Check it before adding a
new public growable collection surface or changing compiler-private backing
storage.

## Source Conventions

Runtime stdlib code uses `str-cat` for fixed-arity string construction and
`text_buf` for incremental building. CI runs
`scripts/check-stdlib-concat-lint.sh` through `verify-stdlib.sh`; the helper
lints every git-tracked `stdlib/**/*.tl` file with
`--deprecated-string-concat` in deterministic bounded batches and includes a
rejection probe for an ordinary `string.append` call.

Only the low-level `stdlib.runtime/string-concat` compatibility primitive and
the `stdlib.comptime` `string-concat` / `string-append` declaration heads have
documented `lint-allow: deprecated-string-concat` suppressions. Qualified
`comptime.string-append` calls are compiler-recognized macro-CTFE operations,
not deprecated runtime concatenation.

## Public Mutator Names

A public stdlib operation that mutates caller-owned state through an `&mut`
receiver has a terminal `!`. The bang is an API naming contract: it signals
mutation, but it does not enable implicit mutable auto-borrowing. An ordinary
function call still passes an explicit mutable reference, as in
`(deque_i64.push-back-ref! (&mut pending) value)`.

A family may additionally provide a place-taking bang macro for convenience.
For example, `(deque_i64.push-back! pending value)` and the corresponding
hashmap/set `insert!` operations borrow their storage places through the normal
checked `&mut` rules and dispatch to explicit `*-ref!` helpers. Such a macro
must evaluate the place and every other operand exactly once; it is not a
general method-call or auto-borrow feature. `text_buf.append!` and
`text_buf.clear!` use the same place-taking convention, while
`byte_buf.bytes-set!` is an ordinary bang-named function over an already
explicit mutable byte view.

The rule follows effects, not spelling mechanics:

- Consuming or returning an owner does not by itself require `!`;
  `iterator.into-iterator`, for example, consumes its range without mutating a
  caller-owned receiver.
- A read or view operation is not a mutator merely because it accepts `&mut`.
  `byte_buf.bytes-mut-length` reads a mutable view, and
  `byte_buf.as-mut-bytes` yields one.
- Iterator protocol steps retain the established `next` / `next-mut` names even
  though they advance iterator state. Private construction and growth helpers
  are outside this public API convention.

Naming migrations update callers, documentation, tests, and generated surfaces
atomically. Do not preserve the pre-bang name as a compatibility alias. The
generated Vec family is still migrating under #4683: its currently shipped
reference-taking operations remain `set`, `push`, and `pop`, so do not present
Vec bang place macros as available yet.

## Current Modules

Every module opens with a `;#` overview and documents each public definition
with `;:` comments. [`tools/doc-site/doc_site.tl`](../tools/doc-site/doc_site.tl)
renders them into one reference page per module
(`typelisp run tools/doc-site/doc_site.tl --stdlib-root stdlib --stdlib-root src -- target/site`;
`scripts/verify-doc-site.sh` builds and link-checks the site the way CI does),
so this section only maps the modules by area. Import a module with
`(import stdlib.<name>)`, or a nested identity such as
`(import stdlib.net.ip)` or `(import stdlib.compress.deflate)`.

- Language support: `runtime`, `core_macros`, `comptime`, `clone`, `eq`,
  `hash`, `option`, `result`, `iterator`, `test`, `profile`, `ffi`, `cpu`.
- Text and formatting: `string`, `string_utf8`, `str_cat`, `str_cat_runtime`,
  `string_caller_result`, `text_buf`, `text_buf_borrowed`, `text_buf_family`,
  `format`, `format_writer_core`, `json`, `serialize`.
- Collections: `vector`, `dense_list`, `hashmap`, `set`, `queue`, `sort`,
  `byte_buf`, `byte_buf_core`, `checked_size` (checked storage-size
  arithmetic).
- Binary encoding: `byte_le` (little-endian integer fields), `byte_reader`
  (bounded cursor with a sticky error and a work limit), `leb128` (LEB128
  variable-length integers), `base64` (strict bounded RFC 4648 standard-alphabet
  bytes with length planning and caller-owned decode/encode forms).
  `asn1_der` validates bounded canonical certificate DER and preserves exact
  source ranges; `pem` extracts bounded RFC 7468 `CERTIFICATE` bundles through
  the shared base64 decoder.
- Compression: `compress/deflate` implements bounded incremental RFC 1951
  decoding over borrowed input and caller-owned output chunks, plus a bounded
  one-shot wrapper. Its default ratio 1024/startup 1024 deliberately rejects
  legitimate streams near DEFLATE's roughly 1032:1 maximum with typed
  `RatioLimit` and byte offsets. Trusted or highly compressible data, including
  native Git packs, requires an explicitly raised ratio limit. See
  [the API and bounds](../docs/deflate.md).
  `compress/zlib` composes it with RFC 1950 framing, preset-dictionary policy
  and the canonical incremental `compress/adler32` checksum. See
  [zlib decoding](../docs/zlib.md).
- Memory and concurrency: `arena`, `atomic`, `thread`, `sync`,
  `concurrency_registry`.
- Numbers, time and randomness: `math` (see
  [`MATH_LICENSES.md`](MATH_LICENSES.md)), `random`, `crypto_random`, `time`.
- Files, processes and the host: `io`, `io_core`, `io_caller_result`, `fs`,
  `fs_rooted_linux`, `env`, `args`, `process`, `process_borrowed`,
  `process_runtime`, `local_ipc`, `local_ipc_fake`, `local_ipc_linux`, `msvc`.
- Unicode protocol data: `idna_unicode12`, with immutable tables in
  `generated/idna_unicode12_data` ([offline generation and profile contract](../tools/idna-unicode12-data/README.md)).
- Networking and security: `net` (host-free socket ownership and finite-progress
  I/O contracts, [surface mapping and adapter contract](../docs/net.md)),
  `net_fake` (injected conformance support), `net/dns/wire`,
  `net/http_types`, `net/http_head_codec`,
  `net/http_trailer`, `net/http_trailer_policy`, `net/ip`, `net/tls_wire`,
  `net/dns_name`, `net/resolver_config`, `net/resolver_config_linux`,
  `net/tls_transcript`,
  `net/url`, `net_windows_winsock`, `ssh_known_hosts_parse`, `ssh_wire_core`,
  `crypto_sha1_git`,
  `crypto_sha256`, `crypto_sha512`, `crypto_rsa_core`, `crypto_rsa_verify`,
  `crypto_p256`, `crypto_secret`, `crypto_aes_core`, `crypto_hkdf_sha256`,
  `crypto_hmac_sha256`,
  `x509_time`, `x509` (owned certificate models,
  exact signed bytes and parsed extensions; no trust/signature decisions).
  See [certificate parsing](../docs/x509.md) for limits and the supported profile.

`x509.service-reference` classifies independently supplied strict IPv4/IPv6
text before DNS and returns `ServiceReference.Ip` or `Dns` over an opaque,
validated ASCII domain pointer. At most one terminal DNS root dot is omitted
from comparison. NR-LDH labels and syntactically valid `xn--` labels compare
as ASCII; apparent A-label prefixes and names are case-insensitive. V1 does
not decode or certify Punycode/IDNA symmetry, and rejects non-ASCII reference
bytes with `InternationalizedNameUnsupported`; #7269 owns full IDNA2008
conversion/validation and the later canonical-result constructor.

Build a caller-owned list with `service-references-new` and
`service-reference-add!`, then pass the parsed leaf certificate, list and
`ServiceIdentityLimits` to `service-identity`. Defaults allow 16 references
and 1024 SANs; configurable bounds are 0..64 and 0..4096. Both counts are
checked before traversal. The result returns the matched reference and SAN
indices (SAN order, then reference order), or stable typed errors for invalid
references/limits, empty references, no supported presented identifier and
identity mismatch. Diagnostics contain no certificate bodies or SAN text.

Only `dNSName` and typed `iPAddress` SANs participate. Invalid presented DNS
syntax is ignored while searching later entries; malformed SAN DER and wrong
IP widths are parser failures. DNS wildcards are one complete left-most label
and match exactly one nonempty reference label. `DisallowWildcards` is an
explicit caller policy. With `AllowWildcards`, `*.com` matches `example.com`
and `*.co.uk` matches `example.co.uk`: RFC matching provides no PSL enforcement.
No suffix list or label-count guess is shipped. IP families and exact network
octets remain distinct, including IPv4 versus IPv4-mapped IPv6. Brackets,
zones, ports and network prefixes are refused. Subject/Common Name/RDN, SNI
and certificate contents never create caller references. This API verifies
leaf identity only; path authorization, trust, signatures, validity and TLS
configuration remain separate responsibilities. All names/addresses are
public and comparisons are variable-time; no secrets or secret spill residue
are introduced.

`net/dns/wire` is the pure DNS codec for the future stub resolver (Refs #7472).
It encodes one IN/A or IN/AAAA question with caller ID/RD and optional EDNS0
advertising 1232 UDP bytes. `decode-response` returns `DnsComplete` only after
validating every declared section and consuming the whole input. `DnsTruncated`
contains only a validated header and exactly one complete question; no RR bytes
are inspected when TC is set, so a datagram ending inside a declared RR can
trigger transport fallback. Matching ID, QR/opcode, question, server and socket
identity remains the resolver's responsibility.

Canonical names retain lowercase ASCII length-prefixed wire bytes, preserving
label boundaries. Empty text and `.` mean root; one final dot is accepted.
Unicode and IDNA are unsupported. Limits are 63 bytes/label, 253 text bytes
excluding a final dot, 255 expanded wire bytes, 127 labels and 32 compression
hops/name; each message allows 65535 bytes, 256 RRs, 256 decoded names, 4096
total hops and 64 addresses. `DnsLimitExceeded` is distinct from `DnsMalformed`,
and each reports its first failure offset. Compression targets must be backward
label boundaries already validated in a question, owner or supported IN name
field. Skipped NS, MD/MF, MB/MG/MR, PTR, MINFO, MX and DNAME records validate
their name-field layouts and exact RDATA lengths under the same budgets; their
values are never returned. For systemd-resolved interoperability, the receiver
accepts compressed DNAME targets under the same boundary and budget checks;
RFC 6672's uncompressed-target rule constrains senders. This allows glue owners
to reference NS authority data and CNAMEs to reference DNAME targets. Other
opaque RDATA (including SRV and unknown types/classes) cannot supply compression
targets. Non-ASCII bytes in any decoded name reject
the message, including owners of unrelated records. Returned A/AAAA bytes,
CNAME, SOA and OPT metadata retain message order and section identity. OPT
tuples are checked and skipped; the resolver owns version/RCODE policy. The
codec performs no host or network calls and retains no input borrow. Only the
first `DnsMessage.len` slots in `records` are live; the backing array length is
capacity and its padding must never be treated as decoded records.

`net/dns_name` is the shared checked ASCII DNS-name value for resolver keys
and policy. `parse`/`parse-bytes` lowercase LDH labels, retain an optional final
dot as separate rooted identity, and report original byte offsets. Labels are
limited to 63 bytes, canonical text to 253 bytes and expanded wire names to
255 bytes/127 labels. Unicode, empty labels and boundary hyphens are rejected.

`net/resolver_config` builds complete immutable-by-API owned snapshots:
`parse-hosts` accepts bytes, `from-explicit` accepts checked nameserver values,
suffix text, hosts bytes and a timeout, and `parse-linux` accepts injected hosts
and resolv.conf bytes. Accessors borrow the published value; builder mutations
operate on a distinct construction type. As with other stdlib value records,
the public representation must not be forged or mutated by callers. No files,
environment, libc resolver, sockets or cache are consulted by these constructors.

`nameserver` checks ports 1..65535 and scope IDs 0..4294967295 (IPv4 requires
zero scope). Complete address/port/scope tuples deduplicate in first-occurrence
order. At most eight server inputs and six suffixes are accepted explicitly;
suffix wire lengths total at most 256 bytes. Linux parsing accepts `nameserver`
with canonical IP literals (port 53/scope 0), and the last `search` or `domain`
directive. Empty `search` clears the list. Suffix order and rooted identity are
preserved. No server or search suffix is inferred when none is supplied.
Timeouts are 1..30000 monotonic milliseconds, default 1000; Linux options,
`LOCALDOMAIN` and `RES_OPTIONS` cannot change them or search policy.

Each file is bounded to 1 MiB, each line to 8192 bytes excluding CRLF, hosts
input to 4096 records, 16 aliases per record and 16384 input name bindings
(including duplicates). Supported malformed input and exceeded bounds fail
the entire replacement with source path identity, one-based line, byte offset
and category. Unsupported resolv.conf directives/options are ignored, retaining
the first 64 location/category diagnostics plus a total count, without copying
input text. Comments (`#`, also `;` in resolv.conf), tabs, CRLF and missing final
newlines are accepted. Hosts lookup ignores rootedness, deduplicates exact IP
values and returns IPv6 then IPv4, each in network-byte order. `localhost?` and
`localhost-addresses` represent reserved loopback policy separately from hosts;
resolver consumers apply this policy before consulting hosts or DNS.

`net/resolver_config_linux.load-system` (Linux only) reads `/etc/hosts` and
`/etc/resolv.conf` with bounded streaming handles. Temporary read buffers are
limited to 8192 bytes and reclaimed after each read, so repeated short reads
retain only the fixed output buffer. Missing/unreadable files
return a structured error. `load-with-source` injects byte-source results for
hermetic adapters/tests; `read-source-path` permits filesystem fixtures and
reports the corresponding logical source path. A successful call returns one
complete replacement; any error leaves the caller's existing state untouched.
There is no watcher, resolver state swap or DNS exchange in these modules.

`crypto_hkdf_sha256` implements RFC 5869 Extract/Expand over HMAC-SHA-256.
Callers supply all six HKDF budgets and explicit HMAC key/message limits.
`extract` uses the absent 32-zero-byte salt; `extract-public` copies an exact
public salt into a temporary secret key; `extract-secret` borrows an exact
live secret salt. All three borrow the whole live secret IKM, including empty
values, and return a protected `HkdfSha256Prk`. `expand` borrows that reusable
PRK and exact public binary info, returning an exact-length `HkdfSha256Okm` for
0 through 8160 bytes. Both tokens point at HKDF-owned opaque cleanup storage;
close them with `close-prk` / `close-okm` or `with`. A copied storage pointer
identifies the same lifetime; closing either token invalidates every alias.
No safe byte view, generic-secret PRK constructor, serialization or formatting
is available. Crypto implementations have direct checked unsafe pointer access.
Expand streams previous block, info and one binary counter octet without a
concatenation, and preflights the complete external feed work before allocation.
For N=0 this work is zero; otherwise it is N*info_length + N + 32*(N-1).
Temporary keys, HMAC state, rolling blocks and partial output are wiped at their
cleanup boundaries. Wiped arena allocations remain retained until arena reset.
HKDF does not slow password guessing and supplies no TLS label/schedule policy.


## Backend Runtime Helper Ownership

The backend runtime plan is a compatibility boundary, not a place for new
stdlib APIs by default. The checked inventory in
`src/compiler_backend.tl` (`compiler-backend-runtime-helper-owner-id`) is the
authoritative ownership table for runtime symbols. `compiler-backend-plan-provides-id?`
rejects unclassified plan helper names, and the backend self-test also checks
the exact global-symbol allowlist emitted by the full runtime-helper assembly.

- **Core runtime:** the backend-owned allocator/arena substrate:
  `tl_alloc`, `tl_region_mark`, `tl_region_reset`, `tl_arena_make`,
  `tl_arena_make_atomic`, `tl_arena_current`, `tl_arena_set`, `tl_arena_destroy`,
  `tl_arena_poison_enable`, `tl_thread_init`, and `tl_thread_entry_ptr`. These
  helpers are irreducible backend runtime because they bootstrap ordinary
  TypeLisp allocation, own the single `tl_current_arena` slot, touch
  target-specific TLS (`%fs:tl_current_arena@tpoff` on Linux and `%gs:0x28` on
  Windows), and must stay import-free and allocation-free on allocation/reclaim
  paths. Their checked OS-call inventory is Linux `mmap`/`munmap` in
  `tl_alloc`, `tl_arena_make`, `tl_arena_make_atomic`, `tl_arena_destroy`, and
  `tl_region_reset(0)`, plus the current arena make fatal-exit syscalls;
  Windows uses kernel32 `VirtualAlloc`/`VirtualFree` in the corresponding page
  acquisition/release paths, captures `GetLastError` immediately on failure,
  and delegates to the allocation-free `tl_windows_allocation_abort` runtime
  prelude reporter. Nonzero `tl_region_reset(mark)` retires overflow
  chunks on the arena root instead of releasing them immediately, and reset-all
  or destroy releases those retained chunks. Revisit this classification after
  #3290 provides an allocation-free TLS access design.
- **Core ABI / entry / primitive helpers:** `tl_memcpy` is the backend block-copy
  primitive itself and remains core until source code can express an equal or
  better overlap-safe copy primitive. `tl_memchr` is the allocation-free byte
  search primitive used by borrowed string/byte scans until source code can
  express equally efficient raw byte search. `tl_tlci_call_image_entry` is the
  raw C-ABI bridge that lets the tlci loader call a mapped `tlci_image_entry`
  address with the host callback table and writable registration record;
  `tl_tlci_call_macro_entry` reshapes the loader's seven-argument raw bridge
  call into the registered macro entry's six-argument host ABI.
  Windows `__chkstk` is required by the MSVC ABI for large stack frames. Windows
  `tl_setup_argv` and `_tl_start` are the freestanding entry bootstrap: they
  build the initial argv block from `GetCommandLineA`, clear the TEB
  current-arena slot, call `main`, and exit via `ExitProcess`.
- **Stdlib FFI wrapper dependency:** backend shims still needed by stdlib
  wrappers around OS/profile surfaces: `tl_profile_alloc_total`,
  `tl_profile_alloc_live`, `tl_profile_alloc_peak`,
  `tl_profile_alloc_reset_peak`. The accessors are simple global reads/writes,
  but their counters are maintained inside the backend allocator core, so the
  accessor boundary travels with that allocator ownership for now.
- **Stdlib TypeLisp migration target:** compatibility runtime helpers whose
  preferred long-term owner is TypeLisp stdlib code or a narrower stdlib FFI
  boundary: `tl_substring`, `tl_string_concat`, `tl_string_concat3`,
  `tl_string_concat4`, `tl_string_concat5`, `tl_int_to_string`,
  `tl_atomic_i64_load_ptr`, `tl_atomic_i64_store_ptr`,
  `tl_atomic_i64_add_ptr`, `tl_atomic_i64_fetch_add_ptr`,
  `tl_atomic_i64_cas_ptr`, `tl_atomic_i32_load_ptr`,
  `tl_atomic_i32_store_ptr`, `tl_atomic_i32_add_ptr`,
  `tl_atomic_i32_fetch_add_ptr`, and `tl_atomic_i32_cas_ptr`. The string
  construction helpers are already exported from TypeLisp by #3291 while the
  runtime-plan names remain recognized for compatibility call-site tracking.
  Every raw atomic pointer helper is an unsafe declaration: callers must prove
  live, correctly aligned and initialized storage of the named width, retain it
  for the complete call, and permit every concurrent access. Their existing
  sequentially consistent ordering and exported machine ABI are unchanged;
  `stdlib.atomic` remains the safe owning-buffer interface.
  Atomic helper migration is tracked by #3292 now that #3289 supplies the
  underlying atomic memory-operation intrinsics. String equality, string
  parsing, and string hashing are implemented by TypeLisp stdlib code in
  `string.tl` and `hash.tl`. Bounds/division/shift/general/OOM abort handlers,
  file/IO/process/fs helpers, primary env implementations, random seed,
  profile time, and CPU feature helpers have moved to TypeLisp
  stdlib/runtime-prelude exports or direct platform bindings; only the env
  compatibility aliases below remain recognized by the plan table.
- **Compatibility alias:** legacy env spellings recognized by the runtime-plan
  ownership table: `tl_env_var_exists`, `tl_env_var_value`,
  `path-separator`. Their backend emitters are empty because
  `stdlib/env.tl` owns environment lookup in TypeLisp (#2142 follow-up), and
  source builds use the `env.tl` wrappers directly.
- **Deprecated/delete candidate:** no current runtime-plan symbols are in this
  category. Add symbols here only with a linked removal owner.

The broader runtime-core boundary tracker is #1897. New stdlib features should
prefer TypeLisp implementations or focused stdlib FFI wrappers; new backend
helpers need an explicit ownership entry and a focused migration or retention
issue when they are not core runtime.

## Arena Allocation Policy

The stdlib does not own an allocator API. Stdlib functions allocate only by
calling compiler/runtime primitives or stdlib wrappers such as `substring`,
`string-append`, `read-file`, `int->string`, and aggregate constructors. Those
allocations use the active arena: the default program-lifetime arena outside
any scoped arena, or the innermost scoped arena inside `(with-arena ...)`. The
arena model uses the term "scoped arena" for this behavior. Stdlib policy tests
use `(with-arena ...)` as the executable witness for active-arena semantics.

Use four standard scratch patterns:

- **Temporary scratch only:** put phase-local work in `(with-arena scratch ...)`
  and return only scalars or values allocated outside the scoped arena. This is
  the preferred safe path and uses no `stdlib/arena.tl` unsafe helpers.
- **Clone one result out:** allocate a reusable first-class arena with
  `arena.make`, then wrap each transient build in `(with-escape scratch ...)`.
  Supported body results are cloned into the enclosing active arena before the
  scratch arena is rewound.
- **One-shot clone-out:** use `(with-scratch body ...)` when a supported result
  should be cloned out of a fresh scratch arena and the caller does not need to
  reuse the arena handle.
- **Keep results in a first-class arena:** allocate or receive a typed `Arena`
  and wrap the build in `(in-arena arena ...)`. The result remains owned by that
  first-class arena.
- **Safe ordinary arena invalidation:** import `stdlib.arena`, record a phase
  token with `arena.phase`, allocate phase-local values through
  `(in-arena owner ...)`, then call `arena.rewind-safe!` when the checker can
  prove every value from that phase is dead. `arena.destroy-safe!` consumes a
  direct local owner or branded local aggregate owner place and invalidates all
  current-function values carrying its brand.
- **Manual unsafe arena:** import `stdlib.arena` and call `arena.set!`,
  `arena.rewind`, or `arena.destroy` only inside `(unsafe ...)` when the caller
  can prove every invalidated heap handle is dead. Prefer the safe patterns
  above for normal tool code.

Written reference and arena lifetime syntax exists, and stdlib APIs migrate
non-consuming text inputs to borrowed `(& lifetime str)` signatures as the
borrowed `str` frontend and string API work lands (#1453/#1454/#1082). The checker
conservatively tags aggregate results from stdlib calls made inside a scoped
arena as arena-owned, which prevents those values from escaping the scope. The
v1 `String`/`str` contract in `SPEC.md` classifies which future signatures
should take borrowed text and which should return owned active-arena strings.
`SPEC.md` also reserves the binary-storage family: `stdlib/byte_buf.tl` exposes
owned `ByteBuf` helpers for mutable binary data plus borrowed `bytes` views over
strings, buffers, and byte sub-slices, while `stdlib/byte_buf_core.tl` keeps a
narrow append-builder surface for hot internal code. `TextBuf` remains an
append/render text builder, while generated vectors expose native typed
`Slice T` views; neither is the raw byte-slice contract.
The `string_caller_result.tl`, `io_caller_result.tl`, and
`process_borrowed.tl` companion modules expose lifetime-preserving shapes.
`io_caller_result.tl` is an explicit binary-to-text materialization boundary;
borrowed process runtime wrappers likewise copy at their owned boundary.

| Functions | Allocation behavior |
|-----------|---------------------|
| `string_utf8.decode-at`, `decode-before`, `iterator`, `next`, `next-back`, `validate`, `count`, `boundary-at`, `slice-range`, `encode` | Checked Unicode scalar mechanics over borrowed byte strings, without allocation or replacement. Iterator errors are yielded once before stable exhaustion. Count/boundary/scalar-range checks validate the complete input. Encoding writes shortest-form UTF-8 into caller-provided mutable bytes and leaves them unchanged on invalid scalar or insufficient space. Ordinary `String`/`char` operations remain byte-oriented; runtime byte strings need not be valid UTF-8. |
| `string_utf8.slice` | Checks a half-open scalar-index range and returns an owner-borrowed `str` without copying its bytes. Like `string.substring-view`, it allocates a two-word header in the runtime's process-lifetime view arena; use `slice-range` to compute the same checked byte bounds without that allocation. |
| `string.is-char-whitespace`, `string.char-eq`, `string.index-of-byte`, `string.contains`, `string.contains-char`, `string.is-string-prefix-at` | Non-allocating string/char inspection; text parameters are borrowed `str` inputs. |
| `string.append`, `string.concat`, `string.copy`, `string.substring`, `string.slice`, `string.concat-all` | Copying string helpers allocate fresh active-arena `String` storage and copy bytes from borrowed `str` inputs. Owned `String` places auto-borrow at call sites, and stdlib code that already has `(& r str)` values calls the same public helpers directly. `string.concat-all` accepts a borrowed native `Slice String`; long `str-cat` expansions pass a live-prefix Slice over one compiler-private packed buffer. |
| `local_ipc.connect` | Allocates one private connection state cell in the active arena, including on failure; for a valid endpoint also one copy of the endpoint name, and for a connected handle one `transfer-max`-byte transfer array; nothing per retry. The connection must stay inside that arena (the checker enforces it for `with-arena`; `arena.destroy-safe!` does not yet invalidate `with`-bound owners, #7944). `close!`, the primitive and wait-capable reads and writes, the whole-buffer helpers and every accessor are non-allocating. |
| `local_ipc_linux.adapter` | Allocates the closure that carries its pathname policy in the active arena; keep the adapter inside that arena. Every adapter operation (connect attempts and retries, peer query, reads, writes, readiness waits, pauses and close) is non-allocating: native structures live on the stack and connected descriptors in a fixed process-wide table of `slot-capacity` slots. |
| `int->string` | Allocates fresh active-arena `String` storage, writes decimal bytes directly, and returns the zero, positive, negative, and signed edge-case spelling without calling the legacy runtime helper. Project callers should import the stdlib helper instead of relying on an unimported compiler default. |
| `format.args` | Parses the same literal plan once and returns a structural, borrow-checked Arguments package containing one capture-free renderer plus shared anchors. Supplied and captured expressions are evaluated exactly once; replay does not move caller-owned lvalues, nested Arguments replay directly, and lifetime checking prevents a package from escaping any borrowed source. Construction allocates only aggregate package storage, never the final rendered text. |
| `format.format` | Parses a deterministic literal plan and binds every selected value/count once. Display uses the shared decimal/radix/fixed/exponent converters and canonical owner hooks. Primitive `?`/`x?`/`X?` reuse those integer, exact-float, exponent-normalization, pointer, and byte-escape cores; quoted text ignores outer options and retained Arguments replay their stored plan. Nominal Debug remains independent from Display and unsupported until its hook layer lands. Each rendered scalar piece and any changed option-layout piece allocate exact active-arena Strings; finite floats additionally use the documented bignum scratch storage before final layout. Materializing the full result allocates its final String. |
| `format.write!`, `format.writeln!`, `io.print`, `io.println`, `io.eprint`, `io.eprintln` | Reuse the same literal scanner, selection rules, Display/Debug options, conversions, and canonical nominal Display hooks, but send each plan piece through one `Formatter` callback instead of materializing the final combined String. Stateful writer cells are registered behind generation-checked scalar capabilities; their raw address adapters require `unsafe`, while the safe first-class callback rejects forged, stale, wrong-writer, reentrant, and concurrent tokens. Retained Arguments under any outer Debug mode replay directly and ignore those outer options. Newline variants append exactly one newline after a successful body, and accept no template at all (`(io.println)`, `(io.eprintln)`, `(format.writeln! writer)`) to write exactly one LF through the same sink and error path; writer calls return `FormatOk` or the first `FormatErr status` and skip later pieces after failure. The optional exact `format-write` / `format-write-<NominalName>` owner hook handles default Display only; Debug never reuses it or `to-string`. `print-format` is a migration alias for `print`. |
| `string.trim-left`, `string.trim-right`, `string.trim` | Borrow the input text and return fresh `String` storage from `substring`, allocated in the active arena. |
| `string.replace` | Compatibility wrapper: returns fresh `String` storage from `substring`/`string-append` when a replacement is made; returns the caller-provided `s` when `old` is not present. `string_caller_result.tl` exposes the `string-replace-result` caller-result shape that preserves the no-match borrow until explicit materialization. |
| `read-file`, `try-read-file` | `read-file` returns an active-arena `ByteBuf`. The recoverable form returns `OkIoBytes ByteBuf` when the path is readable, or `ErrIoBytes` for empty paths, expected absence, permission failures, interrupted reads, and target status-code failures. Text consumers call `byte_buf.to-string` explicitly. |
| `write-file`, `try-write-file`, `write-file-status` | Take a borrowed `bytes` view and write it without a text-shaped intermediate. The recoverable form returns `OkIoUnit` on success or `ErrIoUnit` for empty paths, missing parents, permission failures, interrupted writes, and target status-code failures. |
| `try-file-exists?` | Returns `OkIoBool` for existing or expected missing paths; empty paths and hard probe failures return `ErrIoBool`. |
| `try-append-file` | Appends a borrowed `bytes` view through the recoverable stdlib status helper. It preserves existing contents, creates missing files, allocates no concatenated temporary, and uses best-effort host append semantics rather than truncating or rewriting the whole file. |
| `file-open`, `file-close` | `file-open` returns `ResultIoFile` with an opaque stdlib-managed `FileHandle` for `OpenRead`, `OpenWriteTruncate`, `OpenWriteAppend`, and exclusive `OpenWriteCreateNew`. The stdlib copies the path into active-arena storage for the host call and tracks handle state in a process-global table. Create-new never opens an existing path. `file-close` releases a valid handle and returns `IoUnsupported` for invalid or already-closed handles. |
| `file-read-chunk`, `file-read-bytes`, `file-read-eof?` | `file-read-chunk` reads up to the requested byte count from a read-mode `FileHandle` and returns `ResultIoRead` with an active-arena `ByteBuf` plus the sticky EOF flag. For a valid read-mode handle, a positive request allocates its full byte count before host I/O; a short read or host error does not reclaim that storage. Repeated readers should use the [bounded scratch pattern](#streaming-file-read-allocation). Negative counts return `IoInvalidPath`; closed, invalid, write-only, and unsupported handles return `IoUnsupported`. The accessors are non-allocating field reads on `FileRead`. |
| `file-write`, `file-flush` | `file-write` writes a borrowed `bytes` view to a write-mode handle, retrying host short writes until complete or an error is reported. `file-flush` calls `fsync` on Linux and `FlushFileBuffers` on Windows. Closed, invalid, read-only, and unsupported handles return `IoUnsupported`. Flushing a file does not flush its containing directory. |
| `read-file-or` | Returns a successful `ByteBuf` or the caller-provided `ByteBuf` fallback for every structured error. `io_caller_result.tl` provides an explicitly textual result shape for callers that deliberately materialize file bytes as `String`. |
| `append-file` | Panic-on-error borrowed-`bytes` wrapper over `try-append-file`; preserves existing contents and creates missing files through host append mode. |
| `file-nonempty?` | Convenience wrapper over `try-read-file`; allocates a temporary active-arena `ByteBuf` only when the path exists. |
| `stdin-read-line`, `stdin-read-bytes` | Return `StdinRead` aggregates containing an active-arena `ByteBuf` plus the post-read sticky EOF state. `stdin-read-buffer` accesses the owned bytes; text parsing requires explicit `byte_buf.to-string`. |
| `stdin-at-eof?`, `stdin-read-buffer`, `stdin-read-eof?`, `stdout-write`, `stderr-write`, `stdout-flush` | Non-allocating borrowed-byte wrappers/accessors around stdlib FFI stdio helpers and `StdinRead` values. The higher-level format macros are described separately above. |
| `stdout-write-line`, `stderr-write-line` | Write a borrowed `bytes` view followed by the static newline byte; they do not materialize a newline-appended `String`. |
| `get`, `set!`, `unset!`, `path-list`, `path-list-vec`, `path-split`, `path-split-vec`, `path-join`, `path-join-vec` | Lookup/mutation names and values, split inputs, and explicit join separators are borrowed `str` inputs. Environment values and split/join results allocate fresh active-arena Strings and either vector backing arrays or compatibility list spines when runtime values are read or string pieces are created; missing variables return explicit `EnvNo*` options. Linux `set!`/`unset!` retain replacement entry/array storage in a process-lifetime arena so later lookups and child `execve` calls remain valid; Windows mutation uses kernel32-owned process storage. |
| `path-join`, `path-join-owned-pair`, `path-join-many`, `dirname`, `basename`, `extension`, `path-absolute?`, `path-normalize`, `path-safe-relative?`, `try-current-dir`, `try-mkdir`, `try-mkdir-if-missing`, `try-remove-file`, `try-remove-dir`, `try-rename`, `try-atomic-replace`, `file-lock-acquire`, `file-lock-release`, `try-read-dir`, `try-read-dir-vec`, `try-file-kind`, `try-file-metadata`, `try-create-temp-dir`, `try-create-temp-dir-in` | Path joins allocate active-arena Strings when a separator is inserted or duplicate separator is removed. `path-join` remains the two-argument borrowed function; `path-join-owned-pair` accepts two owned `String` segments and delegates to it; `path-join-many` is the variadic macro alias for owned `String` segments, expanding zero segments to `""`, one segment to that segment, and two or more segments to pairwise joins that delegate to `path-join`. `dirname`/`basename`/`extension` are pure separator-agnostic string helpers (no allocation beyond the returned substring; `extension` operates on the basename and treats a leading-dot name as extensionless). `path-absolute?` is non-allocating and treats `/...`, `\\...`, `C:/...`, and `C:\\...` as absolute/rooted while leaving drive-relative `C:...` non-absolute. `path-normalize` is lexical only: it accepts `/` and `\\`, collapses repeated separators, removes `.`, resolves `..` against normal segments with a `StringVec` stack, preserves relative leading `..`, preserves roots and drive roots, renders `/` as the stable separator on every host, and returns `"."` for empty relative paths. `path-safe-relative?` allocates through normalization and returns true only for non-empty relative suffixes that remain below a caller-chosen root after lexical normalization; it rejects rooted, drive-qualified, empty/`.` and leading-parent paths. `try-current-dir` returns the host-reported cwd as an owned active-arena `String` on Linux and Windows through stdlib FFI, without symlink canonicalization. Recoverable filesystem helpers map host/runtime status codes into `IoError`; `try-file-kind` returns `FsFileRegular`, `FsFileDirectory`, or `FsFileOther` on Linux and Windows. `try-file-metadata` returns `FsMetadata` with coarse kind and regular-file byte size on Linux and Windows; directory and other node sizes are zero in this first slice. `try-mkdir` works on Linux and Windows, and `try-mkdir-if-missing` treats an already-existing path as success. `try-atomic-replace` uses `rename(2)` or MoveFileExA replacement without delete-then-rename and promises atomic reader visibility, but not power-loss durability without a directory flush. Advisory file locks block across processes, release automatically when a process exits, and require a stable coordination path that callers do not unlink. `try-read-dir` and `try-read-dir-vec` return entry names only in a `StringVec`, filter `.` and `..`, preserve host directory order without promising stable sorting, and allocate returned storage and entry strings in the active arena; Linux reads directories directly through syscalls, while Windows uses kernel32 `FindFirstFileA`/`FindNextFileA`. Linux temp directories are created under `$TMPDIR` or `/tmp` with process-id and retry suffixes. Windows temp directories are created under `%TEMP%`, `%TMP%`, or `.` with process-id and retry suffixes. `try-create-temp-dir-in` creates the same kind of directory under a caller-chosen existing root, for scratch space that must share the root's filesystem, such as an output staged for `try-atomic-replace`. |
| `ffi.c-bytes-*`, `ffi.cbytes`, `ffi.c-string-*`, `ffi.cstr` helpers | `ffi.c-bytes-required-bytes`, `ffi.c-bytes-interior-nul?`, and `ffi.c-bytes-copy!` inspect or copy borrowed `(& r bytes)` into caller-owned `(MutPtr u8)` storage without allocating. `ffi.c-bytes-copy!` validates interior NUL bytes and capacity before writing, appends the trailing NUL on success, and leaves raw-pointer validity/lifetime with the caller. `ffi.c-bytes-alloc` and `ffi.cbytes` allocate a NUL-terminated byte buffer in the active arena, return null for interior NUL input, and keep the returned `(Ptr u8)` valid only until the owning arena is rewound, reset, or destroyed. The `ffi.c-string-*` and `ffi.cstr` compatibility wrappers borrow `String` inputs as bytes and delegate to the same implementation. |
| `hash-*` helpers | Deterministic, non-cryptographic hash and key equality helpers are non-allocating; string hash/equality helpers borrow text inputs. Hashes are stable bucket hints only; collection users must still compare colliding candidate keys with the matching equality predicate. |
| `math.tl` helpers | Pure scalar arithmetic/comparison and IEEE-754 helpers are non-allocating and import no runtime or platform externs. Typed bit reinterpretation preserves every `f64`/`f32` bit, classification distinguishes finite/infinity/NaN/normal/subnormal/signed zero, copy-sign preserves zero and NaN signs, and `f64-scalbn` / `f32-scalbn` scale across normal/subnormal/overflow boundaries. `f64-sqrt`, `f32-sqrt`, and the type-preserving one-evaluation `sqrt` macro lower directly to scalar SSE2. `f64-mul-add`, `f32-mul-add`, and the one-evaluation `mul-add` macro return the IEEE 754 fused multiply-add (one rounding, ties to even, gradual underflow, signed infinities on overflow, NaN for NaN operands, infinity times zero and opposite infinities) through exact integer arithmetic; no target substitutes multiply-then-add. `f64-exp`/`f32-exp` and `f64-log`/`f32-log`, plus the one-evaluation `exp`/`log` macros, provide deterministic table/polynomial natural exponentials and logarithms within one ULP. Lookup constants live in per-field static integer arrays shared by the scalar routines, with exact payloads and unchanged arithmetic order. These paths have no allocation, runtime call, libm, or CRT dependency. The `abs` macro covers typed `f64` and `f32` expressions; `i64` uses `math.i64-abs`/`math.i64-abs-or` for explicit signed-min behavior. Remaining transcendental functions land as separate freestanding slices. |
| Fixed-array core forms | Import-free `make-array` initializes a fixed `(Array T N)` without heap allocation, `length` / `array-length` lower to constant `N`, `array-ref` performs a checked read/place projection, and element mutation uses `set!` on that place. Growable collections use generated vectors; compiler-private dynamic buffers retain their internal intrinsics. |
| Scalar `(hashmap K V)` module helpers in `hashmap.tl` | Map construction, growth, resize, and rehash allocate backing slot arrays in the active arena. `insert!`, `insert-or-update!`, `insert-if-absent!`, `remove!`, `remove-borrowed!`, and `entry-or-insert!` macros evaluate their arguments once and update `Map` through explicit `&mut` helpers. Lookup, containment, len/capacity/deleted accessors, and bucket-order cursor helpers are non-allocating aside from caller-provided owned keys or fallback values. String-key borrowed lookup/removal variants inspect borrowed key text without copying it. `get-value-borrowed` returns a lifetime-parameterized lookup whose found branch borrows the map-owned value; mutating, removing, or growing the map while that result is live is rejected by the checker. Mutable-entry helpers borrow the backing table uniquely and update existing entries in place; another mutable entry, a value borrow, or any structural mutation is rejected while the entry is live. Missing mutable entries are explicit no-ops. |
| `(set T)` generated modules in `set.tl` | Set constructors, `insert!`, `remove!`, growth, resize, and rehash allocate/mutate the backing open-addressed table through the same active-arena policy as `hashmap.tl`. Public bang mutators take a storage place and expand to explicit `&mut` `*-ref!` calls. Duplicate inserts keep `len` unchanged. Lookup, containment, len/capacity accessors, and bucket-order cursor helpers take `&` and are non-allocating aside from caller-provided owned keys. String-key borrowed contains/remove variants inspect borrowed key text without copying it. |
| `(vector T)` generated modules in `vector.tl` | Vector constructors, growth, `push`, map helpers, `from-slice`, and `push-owned` for cleanup-owning elements allocate compiler-private dynamic backing storage in the active arena. `view` and `view-mut` are non-allocating native `Slice T` views over only the live prefix; their owner borrow rejects vector growth or aliasing while the view is live. Native `slice-view` / `slice-mut-view`, range-disjoint `slice-split-at` / `slice-split-at-mut`, `array-length`, `array-ref`, and array-element place assignment provide sub-slicing, traversal, and mutation. A split mutable view keeps the vector owner borrowed while either half is live. Cleanup-owning specializations store only constructed values, track slot liveness, clean replaced values in `set`, make `IntoNext.Item` own its payload, and drain still-live unvisited slots if consuming iteration is abandoned; clone-dependent helpers are omitted. `map*` traverses borrowed `Vec` values and returns fresh owned vectors. `iterator` retains a shared vector borrow in `Iter source`; `next` is non-allocating and yields `IterNext.Item (& source T)` or stable `Done`, so moving or mutating the vector is rejected while iterator state or an item is live. `iterator-mut` retains an exclusive vector borrow in `IterMut source`; `next-mut` yields `IterMutNext.Item (&mut source T)` or stable `Done`, so a yielded item must be dead before the next call. `String` elements retain the language's immutable-text rule and yield `(& source str)` from element-borrowing iterators, while `view` retains the sized `String` element type. `set` and `reverse!` mutate through `&mut`; `get`, `last`, `len`, `capacity`, `is-empty?`, `contains?`, and `fold*` are non-allocating aside from caller-provided fallback/value/function storage. |
| `compiler-dense-list-operations` in `dense_list.tl` | The declaration macro itself runs at compile time. Generated `with-capacity`, `new`, and doubling `grow` allocate private dynamic backing storage in the active arena; `get`, `len`, `empty?`, `copy-range`, `push` without growth, and `append-from` without growth are otherwise non-allocating. Shared-zero policy reuses one process-lifetime empty backing value until the first push. |
| `(vec T)` generated `sort!` helpers and `string-less*` comparators in `sort.tl` | Stable hybrid merge-sort helpers extend the matching generated `(vector T)` module and mutate its live prefix through a mutable reference. Inputs of at most 16 elements use allocation-free insertion sort. Larger inputs allocate one `len`-element scratch array in the active arena, sort 16-element insertion runs, and merge them bottom-up in O(n log n) worst-case time. Scalar instantiations compare values directly with `<`; String and aggregate instantiations use the caller-supplied less-than function. Both paths preserve the relative order of equal elements. |
| `range`, `range-inclusive`, and canonical `into-*` helpers in `iterator.tl` | `range` constructs a half-open scalar iterable over `[start, end)`, and `range-inclusive` constructs an inclusive scalar iterable over `[start, end]` without computing `end + 1`. `into-iterator`/`into-next` implement the canonical owned protocol selected by scalar `for`; a single unannotated `for` clause over an owned range counts through its fields in place without them. Iterator construction and stepping are non-allocating, and exhaustion is stable. |
| `(channel i64)`, `ChannelI64PairChannel`, and `ChannelString` helpers in `sync.tl` | Channel creation allocates runtime-owned OS memory for the fixed ring buffer and head/tail state, plus three OS semaphore handles. Send/recv do not allocate TypeLisp heap storage; they block through the semaphore substrate and move one scalar `i64` message, one two-`i64` `ChannelI64Pair` aggregate, or one atomic-arena-owned `String` handle through the synchronized queue. `channel_i64.close`, `channel-i64-pair-close`, and `channel-string-close` release the OS memory and semaphore handles after all users are done. |
| `(mutex i64)` generated module in `sync.tl` | Mutex creation allocates one runtime-owned 16-byte cell (the protected scalar and the holder word), one OS semaphore handle and one `stdlib.concurrency_registry` row. A `mutex_i64.Mutex` is a move-only registry authority: `share` issues another handle for the same mutex, and dropping a handle revokes only that handle. `mutex_i64.lock` takes a registry lease that lasts through the wait and the guard, then issues the guard's grant token and records it as the holder. Guarded `get`/`set!`/`add!` do not allocate; each validates that its guard is the holder. `mutex_i64.unlock` releases the semaphore and the lease when the `with` scope exits. `mutex_i64.close` returns `false` while a lock attempt or guard holds a lease; otherwise it revokes every handle, closes the semaphore and frees the cell. A forged, stale or closed handle fails closed: lock and guard access abort before touching storage, and close and guard cleanup do nothing. |
| `byte_buf.tl` helpers | `ByteBuf` construction, copy-in, reserve, growth, and copy-out allocate in the active arena. `byte_buf.ref`, `byte_buf.get`, length/capacity inspection, clear, and in-place set are non-allocating. `byte_buf.as-bytes`, `byte_buf.as-mut-bytes`, `byte_buf.str-as-bytes`, `bytes-slice-view`, and `bytes-mut-slice-view` return fixed-length borrowed views; mutable views are exclusive and can update existing bytes without growing the owner. `byte_buf.bytes-to-string` and the `from-bytes*`/`append-bytes*` helpers are explicit copy boundaries; public binary APIs do not expose private dynamic buffers. |
| `byte-buf-builder-*` helpers in `byte_buf_core.tl` | `ByteBufBuilder` construction, reserve, growth, append from private dynamic-buffer storage or strings, and finish/copy boundaries allocate in the active arena. Length/capacity inspection is non-allocating, and `byte-buf-builder-push` mutates the existing builder through `&mut` unless growth replaces its backing storage. The module is an internal compiler/runtime core and spells that storage `__tl_dyn-array`; it intentionally omits borrowed `bytes` views and in-place indexed mutation. |
| `push-*!`, `set-*!`, and `read-*` helpers in `byte_le.tl` | `push-u16!`, `push-u32!`, and `push-u64!` append through `byte_buf_core.byte-buf-builder-push` and allocate only when the builder grows in the active arena. `set-*!` overwrites existing private dynamic-buffer bytes in place and `read-*` decodes them; neither allocates, and both use ordinary bounds-checked indexing. |
| `ByteReader` helpers in `byte_reader.tl` | `new` shares the caller's private dynamic-buffer storage without copying it. Reads, `consume!`, `skip!`, and `fail!` only update the reader's scalar cursor, work counter, and first-failure record; the reader's own failure messages are static strings, so nothing allocates. |
| `leb128.tl` | `decode-unsigned`, `decode-signed`, `unsigned-size`, and `signed-size` read the caller's private dynamic-buffer bytes or a scalar and allocate nothing. `push-unsigned!` and `push-signed!` append the minimal encoding through `byte_buf_core.byte-buf-builder-push` and allocate only when the builder grows in the active arena. |
| `asn1_der.tl`, `x509_time.tl` | DER validation and Gregorian conversion allocate no payload storage, using fixed stack arrays and scalar limits. Borrowed ranges keep the original owner alive. |
| `pem.tl`, `x509.tl` | Validated budgets bound active-arena payload/decoded buffers and metadata vectors before growth. Successful certificates own one exact DER copy; range views borrow it without copying. Errors expose no partial result, though internal arena allocations live until their arena is reset. |
| `x509.tl` service identity | Each accepted DNS reference allocates one fixed-size opaque value in the active arena; its pointer must stay within that arena's lifetime. IP construction and the fixed-capacity 64-element reference list allocate nothing. Matching allocates nothing and uses fixed-size public stack scratch, with at most SAN-count × reference-count × 253 byte comparisons. No attacker-sized lowercase strings are built. |
| `base64.tl` | Every planner and codec takes a nonnegative `max-output-bytes` as its last argument and rejects excess output before allocation or mutation. `encoded-length-count`, `encoded-length`, and `decoded-length` use checked scalar arithmetic without allocating; decoding rejects oversized input lengths before scanning, then validates canonical syntax and the exact output limit. `encode` and `decode` allocate one exact active-arena `ByteBuf`. `encode-into` and `decode-into` allocate nothing: after validating limits, syntax, destination capacity, and non-overlap, they write from offset zero into caller-owned backing storage. Every failure preserves its length and physical bytes. |
| `compress/deflate.tl` | `decoder-new` validates limits and initial work before initializing fixed inline tables and allocating at most 32 KiB of history backing bytes in the active arena. `step!` allocates nothing and retains no chunk borrow; it reuses that workspace across blocks and suspensions. `decode` uses the same engine and grows its output only within the caller's bound. Retired geometric backing arrays and the decoder's history backing remain in the owning arena until it is dropped; the retired arrays' combined capacity is less than three times `max-output`. |
| `compress/adler32.tl` and `compress/zlib.tl` | Adler-32 is scalar arithmetic over borrowed bytes and allocates nothing. `zlib.decoder-new` allocates only the raw decoder's bounded history; `step!` and `set-dictionary!` allocate nothing, retain no chunk or dictionary borrow, and copy at most `window-bytes` dictionary bytes into that history. `decode` and `decode-with-dictionary` grow output exactly as `deflate.decode` does, within the caller's bound. |
| `net/http_types.tl`, `net/http_head_codec.tl`, `net/http_trailer.tl`, and `net/http_trailer_policy.tl` | Checked protocol tokens, retained field bytes, ordered header/trailer-name storage, policy entries, incremental parser buffering, response-head/trailer results, and serialized request heads allocate in the active arena. Head parsing copies only the bounded head prefix; trailer parsing retains only approved name/value bytes plus reusable current-line scratch. Both stop before a coalesced suffix and never rescan completed lines. Field-line range validation, header lookup, syntax/framing inspection, trailer-policy lookup/list validation, sensitivity checks, and body-plan selection are otherwise non-allocating over retained bytes. Policy construction copies normalized approved names in deterministic insertion order. Request serialization validates all fields and the complete bounded output length before allocating its final `ByteBuf`; framing fields are emitted once in canonical form. |
| `net/ip.tl` | Address construction, byte access, equality, ordering, hashing, and strict borrowed-text parsing are non-allocating. IPv4 and IPv6 formatting use bounded stack scratch storage, then allocate exactly the returned active-arena `String` backing bytes and handle; no growable intermediate buffer is allocated. |
| `net.tl` | Each published socket/duplicate allocates one private state cell, generation word and reusable transfer buffer (16384 TCP bytes or 65507 UDP bytes). Ordinary I/O/retry/wait/close and queries allocate nothing in the contract layer. Sends copy the dispatched borrowed prefix into owned transfer storage; receives copy only the validated committed prefix back. Owned-read helpers explicitly allocate bounded output buffers. The platform adapter owns its allocation policy; keep owners inside their allocation arena. |
| `net_fake.tl` | One process-lifetime integer table holds bounded fake contexts, scripted traces, generation-checked tokens and shared socket groups; no simulated operation sleeps, calls a host API or allocates per retry. |
| `net/dns/wire.tl` | Names occupy fixed inline storage. Query encoding allocates one active-arena `ByteBuf` of at most 282 bytes. Response decoding checks the 65535-byte cap before allocating a 16384-byte compression-boundary table, then checks the RR cap before allocating at most 256 fixed-size record slots. TC allocates no record array. Parsing never allocates per hop or copies opaque RDATA; errors expose no partial records. Per-call scratch and returned arrays live in the caller's active arena. |
| `net/tls_wire.tl` | The record and handshake readers own their buffers and fill them in place: once they have grown to the largest record and message, reading records, reassembling messages and returning each message's exact bytes as a borrowed view allocate nothing. Record headers, handshake message headers, extension blocks and every list are checked against the protocol maximum and `TlsWireLimits` before anything is copied. Typed decoders validate a whole list before allocating its exact array and copy each opaque field into its own `ByteBuf`; encoders append to the caller's `ByteBuf`, filling length prefixes in place. |
| `net/tls_transcript.tl` | Public SHA-256 transcript construction, exact held-frame absorption, raw snapshots, finalization and closure allocate nothing. `snapshot-boundary` validates the last message kind and allocates one fixed-size opaque tagged hash in the active arena; its read-only pointer must remain within that arena's lifetime. Consumers accept only that handle and use `boundary-digest` with the expected tag. Frame-body and cumulative SHA-work budgets are checked before mutation. The single atomic HRR replacement allocates a 32-byte digest buffer and a 36-byte synthetic frame through `tls_wire.message-hash-frame`; it retains neither. All hashes are public values, with no secret storage, ordering policy or transport dependency. |
| `net/url.tl` | Parsing first checks the whole input against `UrlLimits.max-input` and each component against its own limit before copying it; each component is then normalized into one buffer of exactly its input length. Bracketed IPv6 text is copied only after its length is checked against the longest IPv6 spelling. Formatting and the origin, identity and complete keys allocate their returned `String`s and the intermediate component strings they concatenate. Nothing allocates in proportion to a length the input declares. |
| `ssh_wire_core.tl` | `SshDecoder` reads over the caller's borrowed view and allocates only the exact array of name spans for a `name-list`, after the whole list is validated; `string`, `mpint` and nested blob values are returned as spans into the view, never copied or converted to text. Every length prefix is checked against `SshWireLimits` before anything is taken. `SshIdentReader` and `SshPacketReader` own one buffer each and fill it in place, holding at most one line or one packet; a packet's buffer is reserved only after its length field passed the limit. Encoders append to the caller's `ByteBuf`; `encode-frame` copies the caller's payload and padding once. |
| `crypto_rsa_core.tl` | Key parsing rejects negative, noncanonical, undersized, oversized, or even public values before arithmetic allocation. Limb arrays allocate only at a selected 2048/3072/4096/8192-bit public capacity. Setup retains modulus and `R^2 mod n`; each public exponentiation allocates one exact-width result plus bounded 32-bit-limb results and 64-bit `2n+2` REDC scratch in the active arena. `public-exponentiation-retained-bytes-upper-bound` reports a conservative per-call bound from the checked public class, actual modulus limbs, and at-most-32-bit exponent. No routine accepts secret operands or claims constant-time behavior. |
| `crypto_rsa_verify.tl` | Both public message verifiers reuse `crypto_rsa_core`'s checked exact-width exponentiation and one SHA-256 digest. PKCS#1 compares the complete fixed DER encoding without another output buffer. PSS bounds its MGF1 mask to the RSA maximum of 1024 bytes before allocation, then retains one mask, one decoded DB, a 72-byte recomputation input, and at most one 36-byte seed/counter input per mask digest block in the active arena. Rejection never publishes a partial result. |
| `crypto_p256.tl` | Field, scalar and point arithmetic, `public-mul`, `public-double-mul`, inversion and point validation work on fixed eight-limb arrays and a ten-word Montgomery accumulator held by value, and allocate nothing. `field-to-bytes`, `scalar-to-bytes` and `public-point-to-bytes` each allocate one exact 32- or 65-byte `ByteBuf` in the active arena. Parsers reject a wrong length, a non-canonical coordinate or scalar, a wrong SEC1 prefix, an off-curve point and the identity before returning a value. `public-mul` and `public-double-mul` branch on their scalars, and the field and scalar helpers branch on operand values: they are public-input routines with no constant-time claim, and secret scalars must not reach them. |
| `crypto_random.fill-random!` | Fills an exact caller-owned mutable `bytes` view from the operating-system cryptographic source without allocating output storage. Zero-length views succeed without a host call. Linux uses direct x86-64 `getrandom` with flags zero in at most 256-byte requests and checks partial/interrupted results. Windows loads `bcrypt.dll` through kernel32, validates and calls `BCryptGenRandom(NULL, ..., BCRYPT_USE_SYSTEM_PREFERRED_RNG)` through a raw C function pointer while its DLL reference remains live, then unloads it. Every failure is structured and wipes the complete valid view; there is no PRNG, clock, identifier, file, or third-party fallback. `fill-random-with!` is the low-level checked adapter seam for deterministic tests and explicitly injected protocol providers. |
| `crypto_sha1_git.*` | `new`, `update!`, `finalize!`, `git-digest`, byte access/equality, the raw source seam, and the exact 20-byte consuming sink allocate nothing; a state retains one 64-byte partial block. `to-hex` allocates one exact 40-byte lowercase Git object-ID `String`. The byte counter admits exactly the FIPS SHA-1 domain below 2^64 bits and finalization clears and poisons the state. Compression scratch and explicit state/digest wipe hooks use volatile stores. This allocation behavior does not rehabilitate SHA-1: the API is compatibility-only and forbidden for new security uses. |
| `crypto_sha256.*` | `new`, `update!`, `finalize!`, `digest`, the unsafe scoped raw-source/exact-sink adapters, digest byte access/equality, and the checked length machinery allocate nothing; a state retains exactly one 64-byte partial block. `to-hex` allocates one exact 64-byte lowercase `String`. The byte counter admits exactly the FIPS SHA-256 domain below 2^64 bits. Compression scratch and explicit consuming state/digest wipe hooks use volatile stores. Digests are ordinary public values; the unsafe adapters preserve caller-owned lifetime, generation, and non-overlap checks, and the wipe hooks are a narrow secret-derived-caller seam rather than a side-channel or whole-machine erasure claim. |
| `crypto_hmac_sha256.*` | `new`/`new-fixed` borrow a live opaque secret key, validate nonnegative key/message budgets, and allocate one fixed-size opaque keyed state, retained until its arena is reset. No keyed state is cloned. Public and secret updates allocate nothing and share exact cumulative accounting, including SHA's 64-byte inner prefix. Source precondition refusals preserve the live state; cumulative length failure terminates and wipes before reading the chunk. Every finalization/verification terminates and wipes. Public tags are exactly 32 bytes; `finalize-secret!`/`authenticate-secret` instead write directly to one cleanup-owned `SecretFixed(Secret32)` allocation, movable into a KDF owner without copying bytes. Verification also uses one such temporary allocation and visits all 32 expected bytes through `crypto_secret.difference-bits`; wrong public lengths are rejected before comparison. `to-hex` allocates 64 public characters. Normalized keys, pads, intermediate digests and both keyed SHA states receive volatile wipes on success, terminal failure and lexical `with` cleanup. The unsafe SHA pointer-state adapters wipe their temporary copies. Empty/binary/short keys have exact RFC semantics; ordinary authentication policy should use suitably generated keys of at least 128 bits. RFC 4231 case 5 is truncated and rejected by the exact verifier. No truncation, HKDF, host crypto, generic hash interface or whole-machine erasure claim is provided. |
| `crypto_sha512.*` | `new`, `update!`, `finalize!`, `digest`, the unsafe scoped raw-source/exact-sink adapters, digest byte access/equality, and the checked high/low length machinery allocate nothing; a state retains exactly one 128-byte partial block. `to-hex` allocates one exact 128-byte lowercase `String`. Compression scratch and explicit consuming state/digest wipe hooks use volatile stores. Digests are ordinary public values; the unsafe adapters preserve caller-owned lifetime/generation checks, and the wipe hooks are a narrow secret-derived-caller seam rather than a side-channel or whole-machine erasure claim. |
| `crypto_secret.*` | `fixed-zero`, `fixed-from-bytes`, `bytes-new` and `bytes-from-bytes` allocate one word-backed storage block in the active arena: a 32-byte header and the capacity rounded up to whole words. Capacities are checked before allocation (fixed 16/20/32/48/64 bytes; variable 0..65,536). Comparison, the mask/select/swap helpers and the `unsafe` range accessors allocate nothing. Owners are cleanup-owning and move-only; closing, explicitly or by lexical cleanup, poisons the header, volatile-wipes every data word and marks the block closed, and closing again does nothing. Cleanup receives the storage pointer and generation together in `SecretHandle`; a null, non-live or mismatched handle returns `unit` without mutation or secret reads. Copying a same-generation handle does not create a new storage generation. The storage stays in its arena until the arena is reset. Fixed-work comparison and the select/swap helpers are pinned by the `secret-*` codegen rows; that is a regression boundary, not a side-channel review or certified erasure, and copies in registers, caches, dumps or swap are out of scope. `fixed-copy-range!` (with an exact expected fixed size) and `bytes-copy-range!` validate both live generations, subtraction-checked source/destination bounds and overlap before reading or writing secret bytes; failure preserves all destination bytes and length. Same-storage copies intentionally fail even for disjoint ranges or zero count. Success sets length to exactly `max(previous, destination-offset + count)`, including zero-count writes. These operations allocate nothing and expose no ordinary byte container or safe readable view. The unsafe consuming `transfer-fixed` macro moves one complete exact fixed allocation into `SecretNominal`, allocating only a 32-byte outer state and copying no secret bytes. The inner generation rotates, so pre-transfer handles become stale and their cleanup is a no-op. Failure consumes and cleans the source without allocating outer state. Consumer crypto implementations assert nominal meaning only inside an unsafe call and retain the result inside their own nominal owner. Its backing state is pointer-backed with `(:opaque)` metadata; pointer backing enforces safe construction authority independently of the unfinished provider-isolation work in #6999. Safe code cannot populate the backing allocation or turn an arbitrary fixed owner into live nominal state. `nominal-read-pointer` remains a direct unsafe immediate-call accessor; no raw pointer/context callback is added. Outer cleanup validates its generation, volatile-poisons outer state, invokes inner cleanup once, then marks outer closed. |
| `crypto_aes_core.*` | Internal shared forward AES-128/AES-256 primitive for GCM/CTR consumers. `new-128`/`new-256` consume exact live 16/32-byte `SecretFixed` keys through hygienic nominal owner-transfer macros. Each allocates one `SecretBytes` schedule (176/240 bytes plus the 32-byte storage header), expands in FIPS byte order, then immediately wipes/closes the raw key. Distinct schedule/result types own expanded-key cleanup. Borrowed `encrypt-128!`/`encrypt-256!` calls preflight live generations, exact 16-byte source/destination storage and disjoint backing before reading or mutation, allocate nothing and wipe local scratch with volatile word stores. The shared S-box uses eight masked GF multiplication steps and the fixed x^254 chain; secret bytes never select a branch or address. The `aes-*` both-target opt1/opt2 shape pins and paired source-work tests are regression checks, not a timing proof, certification or side-channel audit. Fatal OOM/panic/abort and registers/caches/dumps are outside the wipe guarantee. No ECB mode, decryption, AES-192, nonce/counter/tag policy or hardware/provider dependency is exposed. See [AES fixture provenance and shape review](../tests/fixtures/crypto-aes/README.md). |
| `arena.*` helpers in `arena.tl` | First-class arena control returns typed `Arena` / `ArenaMark` / `ArenaPhase` wrappers around raw runtime handles. `arena.make` creates an independent ordinary arena, `arena.make-atomic` creates an independent atomic arena, `arena.current` observes the active arena, and `arena.mark` observes the current bump mark. `arena.phase` / `arena.rewind-safe!` use checker-proven direct owners; `arena.destroy-safe!` also accepts branded local aggregate owner places and invalidates their same-function brand users. `arena.set!`, `arena.destroy`, and `arena.rewind` can invalidate live heap handles and require `(unsafe ...)`; raw `i64` values do not satisfy those public helper signatures. |
| `args-*` helpers in `args.tl` | Option specs, parse results, occurrence lists, positional `StringVec` storage, diagnostic payloads, and helper substrings allocate in the active arena. Token classification, option lookup, count/presence checks, and value accessors are non-allocating aside from caller-provided owned strings and existing result storage. |
| `json-*` helpers | Parser, lookup, escaping, and JSON number parsing helpers borrow source text or keys. Object lookup compares borrowed keys without allocating. Parsed JSON aggregates, decoded strings, escaped strings, stringified output, float number text, validation copies, vector-builder backing arrays, and final list/member spines allocate owned results in the active arena. Array/object parsing accumulates elements in JSON-local vector builders and converts once to the public list model, preserving source order and first-match duplicate-key lookup. Float conversion is deterministic, finite-only, host-locale independent, and currently accepts up to 300 non-zero significant decimal digits; longer non-zero number text is rejected rather than rounded through an unbounded scratch representation. Integer conversion (`number->i64`, `number->u64`, `u64->number`) is exact: unsigned text is compared with 2^64-1 before it is accumulated in `u64`, never through a signed or floating value. The owned-text forms allocate nothing; the borrowed forms allocate only their validation copy, and `u64->number` only its rendered text. |
| `(serialize format T)` generated modules in `serialize.tl` | The generic serializer macro itself allocates no runtime storage; it emits calls to the selected format module's hook macros. Generated `encode` allocation behavior is therefore format-owned, while generated `decode` initializes one output aggregate for struct and fixed-array roots/fields before returning `Result.Ok` or `Result.Err`. Compiler-private dynamic-buffer roots and fields allocate decoded backing storage at the decoded length. Nested struct serializers reuse generated modules and do not copy collection storage beyond decoded array storage and whatever the strategy hooks explicitly allocate. |
| `string-eq`, `string=?`, `string.>int` | Equality and integer parsing helpers inspect borrowed string bytes without allocating. Owned `String` places auto-borrow at call sites, and stdlib code that already has `(& r str)` values calls the same public helpers directly. `string.>int` keeps the legacy runtime parser rules, including `""`/`"-"` as zero and byte-minus-`'0'` arithmetic for non-digits. |
| `process-*` helpers in `process.tl` / `process_borrowed.tl` | Owned `process.tl` helpers construct process command/output/error aggregates in the active arena. Command builders keep owned `String` parameters because `ProcessCommand`, argv, env, cwd, and stdin fields store owned strings; validators use borrowed text inspection where they do not store inputs. Owned argv and environment lists derive their live counts from right-sized backing arrays, while `ProcessEnvVec` keeps parallel `StringVec` buffers with an equal-length invariant. Builders cap growth before allocation, and command validation rejects malformed parallel storage, oversized fields, and embedded NUL in every C-string-bound field. `process_borrowed.tl` exposes lifetime-parameterized `ProcessBorrowedCommand` storage using typed persistent argv/environment nodes, so safe construction cannot inject erased reference words. Borrowed `output`, `run`, and `start` validate borrowed storage and copy once to owned `ProcessCommand` before the unsafe runtime boundary. Borrowed argv and env lists are lifetime-homogeneous; use the owned conversion boundary to join independently scoped text. On Linux and Windows, owned and borrowed process-output/run/start paths execute through `process_runtime.tl`, honoring cwd and feeding length-delimited string stdin—including embedded NUL—where supported. A command's `ProcessEnvPolicy` selects the child environment. `ProcessEnvInherit`, chosen by `command`, `command-full` and every `command-with-env*` builder, preserves inherited entries and replaces those named by env overrides. `ProcessEnvExact`, chosen by `command-with-exact-env`, `command-with-exact-env-list` and `command-with-exact-env-vec`, gives the child exactly the validated rows and never reads the parent environment. Exact rows reject repeated names (byte-equal on Linux, ASCII case-insensitive on Windows) and more than `process-exact-env-max-bytes` of `NAME=VALUE` data; Linux passes them in row order and Windows in the case-folded name order `CreateProcess` requires, and zero rows give an empty environment rather than an inherited one. Borrowed commands use the inherited policy; apply `command-with-exact-env-list` to `command-owned` for exact mode. Unsupported targets return structured errors. |
| `thread.tl` helpers | Thread spawning allocates a small active-arena context, join/result cells, and on Linux a raw worker stack before the OS thread starts. Each worker initializes a fresh per-thread default arena before calling user code. `thread.spawn-string`, `thread.spawn-i64-vec`, and `thread.spawn-box-i64` also allocate a fresh atomic arena and one result cell so the joined aggregate storage can safely outlive the worker. The i64 Vec path copies the live prefix once into the spanning result owner; private result cells remain compiler-private. Semaphore handles are OS resources and do not allocate TypeLisp heap storage beyond result aggregates. The raw `i64` context/result surface still does not transfer ownership; callers that pass addresses through it remain responsible for synchronization in unsafe code. |
| `random-*` helpers | Construct deterministic RNG state, draw/result aggregates, and compatibility weight-list cons nodes in the active arena. Array and generated `(vector i64)` weighted-index helpers scan existing storage without cons nodes; the legacy list helper copies weights into an active-arena array wrapper before selection. Draws are deterministic from caller-provided seeds and do not read host entropy. `system-seed` reads a platform seed through FFI, normalizes it, and returns a `ResultSystemSeed` aggregate in the active arena; `from-system` constructs and returns a new deterministic `RandomState` aggregate in the active arena. Neither API is cryptographic or permitted for keys, nonces, challenges, blinding values, or protocol secrets; use `crypto_random.fill-random!` for those. |
| `assert-*` helpers in `test.tl` | Non-allocating checks on success; `assert-string-eq` borrows compared text inputs while assertion messages remain owned `String` values for the current `panic` API. |
| `text_buf.tl` / `text_buf_borrowed.tl` helpers | Owned `TextBuf` chunks and rendered strings allocate in the active arena. Append helpers avoid concatenating the accumulated prefix until `text_buf.render`; `text_buf.clear`/`text_buf.reset` return a fresh empty buffer value, and the `clear!`/`reset!` place macros clear a buffer in place. `TextBufBorrowed` carries one source lifetime, stores borrowed whole-text chunks, source slices, printable char chunks, and owned chunks without copying at append time. `text_buf_borrowed.append-copy` copies unrelated borrowed chunks into owned active-arena storage before appending, while `text_buf_borrowed.render` copies the ordered borrowed/owned chunks directly into one rendered string at the materialization boundary. |
| `msvc.*` helpers | Non-owning target/tool/version/path inputs are borrowed `str` values. Discovery results store owned executable, PATH, LIB, and INCLUDE strings. PATH, Visual Studio toolset, and Windows SDK candidate scans use `StringVec` storage internally. Some internal path probes copy borrowed paths until the lower-level `io/fs` APIs are fully borrowed. |

The recoverable I/O API maps the runtime's integer status codes into the public
`IoError` model. Common not-found, permission, invalid-path, interrupted, and
directory-read statuses get semantic variants; target-specific or unstable
codes remain available as `IoSystemCode`.

Only the companion modules currently return borrow-typed text inside
reference-typed aggregate results; the runnable stdlib compatibility wrappers
still expose owned `String`/aggregate APIs. Except for the explicit `stdlib/arena.tl`
manual-control surface, stdlib APIs do not manually reset arenas and should
prefer `with-arena` for scoped reclamation. Source-level `arena.set!`,
`arena.destroy`, and `arena.rewind` require `(unsafe ...)`. `str` is specified as
an immutable borrowed text referent, not a mutable buffer type; those policies
should remain explicit when borrowed strings and mutable buffers are added.

### File handles

`SPEC.md` §6.4 specifies the v1 file-handle surface; the table above lists its
helpers (`file-open`, `file-close`, `file-read-chunk`, `file-write`,
`file-flush`). v1 requires an explicit close. All handle helpers reuse the
`IoError` model: mode violations, closed or invalid handles, and unsupported
operations return structured `IoError` results rather than panicking.

### Streaming file read allocation

`file-read-chunk` allocates the full positive request in the active arena
before host I/O. A short read exposes only the returned prefix, without
shrinking its backing allocation; a host error also leaves that storage in
the arena. Dropping or replacing the result does not reclaim it. Repeatedly
requesting the remaining capacity can therefore retain nearly the whole
capacity on every one-byte read, until that arena ends.

For a reader with a total byte limit, use this bounded scratch pattern:

1. Allocate one output `ByteBuf` with the required fixed capacity outside the
   loop. Include one overflow-detection byte if the reader must distinguish
   an exact-limit file from an oversized file.
2. On each iteration, request at most `min(8192, remaining)` bytes inside
   `(with-arena scratch ...)`. The per-read cap must be independent of the
   total remaining capacity.
3. Copy only the returned live bytes into the already allocated outer slots,
   then update the outer live length. Check the available capacity first;
   never grow the outer buffer while scratch is active, since growth would
   allocate its replacement storage in scratch.
4. Let only scalar byte counts, EOF, and error facts leave scratch. Neither
   the read buffer nor a scratch-owned error message may escape it. Construct
   any retained error in the outer arena, with the consumed-byte offset when
   needed. Scratch ends before the next read, reclaiming the entire request.
5. Stop on error, EOF, or the total limit. A positive short read is progress,
   not EOF; reject zero progress without EOF. Do not retry a zero-count
   request, which preserves EOF. Close the handle on every exit path and
   return an error without publishing partial data on failure.

A fixed chunk size alone still retains one chunk allocation per iteration
when used in a long-lived arena. Both the cap and scratch lifetime matter.
The [caller audit](../docs/file-read-chunk-audit.md) records existing uses and
the resolver loader's tested implementation of this pattern.

## Importing Stdlib Modules

Stdlib modules are imported explicitly by their dotted identity (see
[Current Modules](#current-modules)).

For dotted imports under `stdlib.`, the loader first checks whether the
importing source tree provides that module identity locally. If not, configured
stdlib roots are searched by mapping the dotted suffix to a path below the
root. If no configured root provides the module, the compiler uses its
embedded copy of the checked-in stdlib as the final fallback.

That means local project modules take precedence over configured stdlib roots.
Configured stdlib roots take precedence over embedded modules. Configured and
embedded stdlib fallbacks only serve normal dotted suffixes below the root; path
traversal is not part of the dotted import model. When compiling or checking
sources outside the repository tree, prefer passing the repository stdlib
directory explicitly:

```sh
typelisp check path/to/main.tl --stdlib-root /path/to/typelisp/stdlib
typelisp compile path/to/main.tl --stdlib-root /path/to/typelisp/stdlib
typelisp run path/to/main.tl --stdlib-root /path/to/typelisp/stdlib
typelisp test path/to/main.tl --stdlib-root /path/to/typelisp/stdlib
```

For ad-hoc local commands, `TYPELISP_STDLIB_ROOT=/path/to/typelisp/stdlib`
provides an optional fallback root. Explicit `--stdlib-root` values are searched
before that environment fallback, and both are searched before the embedded
stdlib, so scripts and CI should keep passing `--stdlib-root` when they need
reproducible resolution.

Copying or staging `stdlib/` next to an entry source still works because the
loader can resolve dotted `stdlib.*` identities from the local source tree, but
`--stdlib-root` is the canonical way to verify root lookup and override
behavior.

The assertion helpers in `stdlib/test.tl` are also intended for inline
`(test ...)` items. They do not allocate on success; `assert-string-eq` takes
borrowed `str` comparison inputs (`assert-owned-string-eq` takes owned ones),
while messages remain owned `String` values so failures can render composed
diagnostics. In a generated `typelisp test`
harness, failures are recorded and execution continues through the remaining
assertions and tests. In any other program, a failed assertion still aborts.
Repository CI runs
`scripts/verify-inline-tests.sh`, so inline tests placed under stdlib modules or
fixtures are discovered without a manifest edit.

For stdlib work, inline `(test ...)` items are the default for runnable API
behavior that belongs to one module. Keep `stdlib/tests/` fixtures for
expected-rejection checks, multi-file/import-shape coverage, resolution and
embedded-stdlib behavior, host I/O cases with required stdin/stdout/stderr
contracts, and intentional panic/exit-status checks.

## Adding a Module

1. Add the module under `stdlib/`; a file such as `stdlib/name.tl` infers the
   canonical identity `stdlib.name`.
2. Keep the module self-contained except for explicit dotted import
   dependencies.
3. Include a short header comment with its purpose and required primitives.
4. Add the new top-level `.tl` file to `scripts/verify-stdlib.sh`'s module
   manifest and to the area list under [Current Modules](#current-modules).
5. Add new top-level modules needed by installed compilers to
   `src/compiler_embedded_stdlib_payload.tl`, including its explicit compressed
   build input and lookup arm. The
   compiler build compresses the source bytes directly, with each top-level
   inline test (`(test ...)`, one-body `(cfg test ...)`) blanked to its line
   breaks and each prose comment cut to its first `;`, so installed compilers
   carry no test code or comment prose. Doc comments and `name:` directives
   such as `lint-allow:` stay whole. Never add `stdlib/tests/*.tl` fixtures.
6. Add inline `(test ...)` items next to declarations for source-local runnable
   API behavior; `scripts/verify-inline-tests.sh` discovers them automatically.
7. Add focused fixtures under `stdlib/tests/` only for rejection, multi-file,
   resolution, host I/O stream, or intentional panic/exit-status coverage, and
   list them in `scripts/verify-stdlib.sh`'s runnable or check-only manifest.
   The stdlib verifier runs these fixtures with `--stdlib-root` and rejects
   attempts to add them to the embedded payload manifest.
8. Document the intended public API coverage in `stdlib/tests/README.md`.
9. Add `;#` module docs, attached `;:` item docs for every public top-level
   declaration, allocation-behavior notes for allocating APIs, an update to the
   arena allocation classification table above, and at least one checked doctest
   example that runs with `--stdlib-root`.
10. Run `scripts/verify-stdlib-docs.sh` to generate Markdown and run doctests
   for every stdlib module.
11. Run `scripts/verify-doc-tests.sh` to confirm the repository-wide doctest
   discovery gate picks up the new documented module without a manifest edit.
12. Run `scripts/verify-inline-tests.sh` if the module adds inline tests.
13. Link user-facing docs or tests to the new module when appropriate.

Run `scripts/verify-embedded-stdlib-payload.sh` to validate all explicit
build inputs, prove deterministic one-byte mutation propagation, and decode
every embedded module against its source with the inline tests blanked and
prose comments cut. It also re-lexes both texts and proves the blanking
removed exactly the top-level inline tests and left every other token at its
line and column. Every other line must be unchanged or a prose comment cut to
its first `;`.
`scripts/verify-stdlib.sh` includes this gate in CI.

The verifier intentionally fails when a new top-level `stdlib/*.tl` module or a
new `stdlib/tests/*.tl` fixture is not listed in its corresponding manifest.
That makes every new canonical module and stdlib test an explicit verification
decision.

The documentation verifier discovers every `stdlib/*.tl` file directly and
fails when module docs, item docs for top-level declarations, generated
Markdown, or doctests regress. The repository doctest verifier discovers
documented TypeLisp files under the source and test trees automatically, so new
doctest fences in stdlib modules do not require a separate doctest manifest
update.
