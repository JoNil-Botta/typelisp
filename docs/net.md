# Socket ownership and byte I/O

`stdlib.net` defines a synchronous, target-independent socket surface. This
module makes no networking host calls. A caller supplies a checked `NetAdapter`;
Linux and Windows host implementations are separate platform leaves. The
`stdlib.net_fake` adapter and `stdlib.tests.net_conformance` fixture interface
exercise the contract without network access, sleeps or external programs.

`TcpStream`, `TcpListener` and `UdpSocket` are move-only cleanup owners. Use
`with` and the corresponding `cleanup-tcp-stream`, `cleanup-tcp-listener` or
`cleanup-udp-socket` function. Explicit `*-close!` poisons the private state
before one close attempt. An interrupted close is reported and never retried.
Lexical cleanup after explicit close makes no second call. Cleanup does not
perform shutdown. A private state pointer plus an atomic generation claim
allows only one effective owner; reconstructing a wrapper from existing owner
words makes one of the two values stale as soon as either operates. Private
socket kind and adapter identity are checked independently of the wrapper.

Each duplicate is a distinct cleanup owner over the same kernel socket. Closing
one does not invalidate the other. Byte/datagram/accept queues, connection and
half-shutdown state, options and consuming pending errors are shared. Serialize
protocol operations when ordering matters: reads/accepts may divide queues and
writes may interleave. Serialize UDP connect/reconnect and option mutation
against operations through duplicates. Reconnect can discard queued datagrams;
there is no portable preservation guarantee and no v1 disconnect operation.

## Endpoints and errors

`socket-addr-v4` and `socket-addr-v6` return a checked `SocketAddrResult`.
Endpoints retain the canonical `net.ip` address bytes, a port in `0..65535` and,
for IPv6, a scope ID in `0..4294967295`. Constructors accept wide integers to
reject narrowing. Records are revalidated before dispatch, including records a
caller built directly. Accessors return the IP, port and scope without text
conversion. Endpoint text codecs, public IPv6 flowinfo and name resolution are
omitted. Adapters encode flowinfo as zero and reject decoded nonzero flowinfo.
IPv6 constructors set v6-only before bind/connect. Listener construction requests
backlog 128; port zero is valid and local-address returns the assigned endpoint.

`NetError` has a portable `NetErrorKind` and optional raw code tagged
`LinuxErrno`, `WindowsWsa` or `WindowsKernel`. Code values outside the unsigned
32-bit range lose their raw provenance; a `NoHostCode` error always has code
zero. Portable comparisons do not depend on domain/code. Errors contain no
native descriptor, pointer or untrusted peer payload. `take-error!` consumes
shared pending error state; its query failure is distinct from the socket's
pending error. Delayed asynchronous errors do not identify a requested peer.

## Finite progress

All wait-capable calls take `NetLimits`: `NoDeadline` or `Deadline(ms)` in the
nonnegative `stdlib.time.monotonic-ms` domain, a `(-> bool)` cancellation probe,
and a finite work budget. Invalid explicit deadlines/work fail before dispatch.
Before each new host dispatch, cancellation precedes expiry, which precedes
work exhaustion. Deadline comparison uses `now >= deadline` before subtraction.
Wait slices reuse `local_ipc.wait-slice-ms`, at most 100 ms even without a caller
deadline, and are recomputed after wakes. An unavailable required monotonic
clock returns `UnsupportedTarget`, including a failure first observed while
computing the next wait slice. Expiry remains `TimedOut`; neither condition
dispatches a readiness wait. No host infinite-wait sentinel is generated.

Each adapter dispatch costs at least one work unit, or its reported host-call
count if larger. This includes construction, metadata preflight, interruption
and readiness waits. A validation-only adapter failure may report zero host
calls; it still consumes work. Mandatory cleanup of an abandoned construction
owner is outside the exhausted operation budget and occurs exactly once.
`default-limits` means no deadline, no cancellation and 1024 work units.

Primitive `try-*` calls perform one data-transfer/accept attempt with no wait or
interruption retry. UDP first checks the live connected state with a separately
counted metadata call; this is not a promise of one total syscall. The preflight
and data attempt share the budget and do not atomically serialize a concurrent
reconnect. Wait-capable operations retry only bounded interrupted, would-block
and spurious-readiness transitions. Native sockets are permanently nonblocking;
mutable per-socket nonblocking modes and read/write timeouts are omitted.

Duplicate, address, option and pending-error queries make one attempt. Their
ordinary `Interrupted` and `WouldBlock` results are returned in the appropriate
error result without being reclassified as adapter corruption or retried.

Positive committed byte progress is returned even if cancellation/expiry is
observable immediately afterward. `read-exact!` and `write-all!` share the
original budget across uncompleted suffixes, re-check completion after every
positive count, and retain the completed count on every error. Early stream EOF
is `UnexpectedEof`; nonempty zero send is `ZeroProgress`. Neither is retried.

## Transfer results and mutation

`NetIoResult` reports count, truncation, EOF, status and an optional complete
peer. The entire borrowed `start/count` range is checked before dispatch using
subtraction, avoiding overflow. One TCP attempt moves at most 16384 bytes, also
below Winsock's signed `INT_MAX`. A longer valid view, including one longer than
`INT_MAX`, is accepted and returns partial progress. Whole-buffer helpers
advance through that view without narrowing its total length.

| Operation | Progress and output mutation |
| --- | --- |
| TCP read/peek | Zero-capacity view succeeds with count zero, no EOF and no host call. Only a zero host receive on a positive-capacity view is EOF. Positive count changes exactly that destination prefix. Peek leaves queued bytes unconsumed. |
| TCP write | Empty input succeeds without a host call. Positive partial count commits exactly that prefix. Adapters suppress broken-pipe process signals. |
| UDP send/send-to | Exactly one datagram; empty input still makes a transfer call. Success requires the complete length. Any short count, including zero for nonempty input, is `PartialDatagram` with its committed count and is never retried. The receive-only `truncated?` flag is always false. |
| UDP receive/peek | Exactly one datagram; count zero is never EOF. Host metadata alone sets truncation. Exact-capacity packets are not truncated. Zero capacity plus truncation identifies a nonempty datagram. Receive discards excess bytes; peek retains the packet. |
| UDP from-operations | Publish one whole validated peer. If payload copied but metadata fails, `CommittedMetadata` preserves count/truncation and copied destination bytes, with no peer. Receive consumed the packet; peek retained it. |
| Connect/bind/accept | No public half-constructed handle. Failed construction closes its native owner. Accept publishes stream and peer together; bad peer metadata closes the new stream while the listener remains usable. |
| Address/option queries | Publish only validated complete values; an ordinary failure changes no borrowed payload. |
| Shutdown | Read/write/both halves are explicit, shared across duplicates, and repeated already-effective shutdown succeeds. It never revives a half. |

Set-option, UDP reconnect and shutdown errors do not promise rollback after a
host transition or corrupt completion reply. Query errors publish no new value;
`take-error!` may have consumed the pending error before malformed output is
detected. All owner operations can advance the private generation even on a
pre-dispatch failure, invalidating reconstructed aliases without changing socket
state. Borrowed payload mutation occurs only as specified in the table.

The UDP payload and receive-view maximum is 65507 bytes. Connected
send/receive/peek require a connected socket; send-to/receive-from/peek-from
require an unconnected socket. IPv4-only broadcast, family-aware unicast hop
limit `1..255`, TCP nodelay and consuming pending errors are the selected options.
Input family/option/range errors make no host call. Adapter-corrupt counts or
buffers are never copied outside a validated destination. Ordinary host errors
carry no committed payload; `CommittedMetadata` and `PartialDatagram` explicitly
record the exceptional committed state.

## Safe capability boundary and allocation

`NetAdapter` carries integer context and generation-checked token values,
`NetRequest`/`NetReply`, and an owned `ByteBuf` handed back by every call. It
never receives a pointer, descriptor or borrowed byte view. Its ordinary safe
function values must be memory-safe for every argument, independently validating
context, token generation, kind, ranges, endpoint metadata, option widths and
operation availability before host dispatch. Integer tokens must never be
interpreted as addresses. Each target owns its checked token registry. Malformed
metadata is decoded into scratch and never published partially. No callback
retains a buffer after returning. The native adapter owns and validates all
construction resources until it returns a cleanup token. Create, accept and
duplicate make native handles non-inheritable before publication.

A resource-shaped reply in an operation that cannot publish that resource is
`AdapterCorrupt`. The contract abandons its independent token with one cleanup
attempt; a malformed reply cannot cause it to close the active owner's token.

Every request carries the original deadline and cancellation probe together
with remaining work. A compound create/bind/listen/duplicate operation checks
those limits before each internal host call, and reports their complete count;
it cannot treat one callback invocation as permission for unbounded host work.
Cleanup close uses its own mandatory one-close request without cancellation.

Each published owner allocates one active-arena state cell, one generation word
and reusable transfer backing: 16384 bytes for TCP, 65507 for UDP. Duplicates
have separate transfer storage. There is one payload copy from the caller's
borrowed source into transfer storage per send attempt, or from transfer storage
into the caller's destination per successful receive. Peeks also copy their
returned prefix. Thus each successfully transferred byte crosses one explicit
copy boundary in either direction, plus any copies inside the adapter. Retries
recopy send input because the adapter may replace/alter the returned buffer.
The contract layer allocates nothing during ordinary I/O, retry, wait, query or
close after publication; the adapter is responsible for its own allocation
policy. `tcp-stream-read-owned!` and `udp-receive-owned!` explicitly allocate a
bounded output buffer; `tcp-stream-write-buffer!` borrows an existing `ByteBuf`.
There is no implicit text encoding or String conversion. Keep owners and their
adapters inside the arena that allocated them, as with local IPC.

## Checked Rust surface mapping

The issue selects Rust 1.98's stable socket surface as a usability reference
([TCP stream](https://doc.rust-lang.org/1.98.0/std/net/struct.TcpStream.html),
[listener](https://doc.rust-lang.org/1.98.0/std/net/struct.TcpListener.html),
[UDP](https://doc.rust-lang.org/1.98.0/std/net/struct.UdpSocket.html)). The shared
`net_conformance.run` signature/runtime witness exercises the selected
operations; `net_owner_api` checks options, endpoint bounds and token reuse.
Platform leaves supply the same `Fixture` script/trace hooks over their injected
host boundary, then add loopback integration. These host-free tests do not claim
that either production platform adapter is implemented.

| Reference type/surface | TypeLisp selection or explicit omission |
| --- | --- |
| TcpStream connect/connect_timeout | `tcp-stream-connect`, one concrete endpoint and per-call `NetLimits`; no one-shot try-connect or public half-connected value. |
| TcpStream local_addr/peer_addr | `tcp-stream-local-address!` / `tcp-stream-peer-address!`. |
| Read, Write, peek, read_exact, write_all | `tcp-stream-{read,write,peek}!`, corresponding `try-*`, `tcp-stream-read-exact!`, `tcp-stream-write-all!`; byte views only. |
| TcpStream shutdown | `tcp-stream-shutdown!`, explicit `ShutdownRead`, `ShutdownWrite`, `ShutdownBoth`. |
| TcpStream nodelay/ttl and setters | `tcp-stream-{get,set}-option!` with `NoDelay` / `UnicastHopLimit`. |
| TcpStream try_clone/take_error | `tcp-stream-duplicate!` / `tcp-stream-take-error!`. |
| TcpListener bind/accept/local_addr | `tcp-listener-bind`, `tcp-listener-{try-accept,accept,local-address}!`; atomic bind/listen, backlog 128. |
| TcpListener try_clone/ttl/take_error | `tcp-listener-duplicate!`, `tcp-listener-{get,set}-option!` with `UnicastHopLimit`, `tcp-listener-take-error!`. |
| UdpSocket bind/connect/local_addr/peer_addr | `udp-bind`, `udp-connect!`, `udp-{local,peer}-address!`. |
| UDP send/recv/peek/send_to/recv_from/peek_from | `udp-{send,receive,peek,send-to,receive-from,peek-from}!` and each corresponding `try-*`; one datagram, explicit truncation/connected preconditions. |
| UDP try_clone/broadcast/ttl/take_error | `udp-duplicate!`, `udp-{get,set}-option!` with `Broadcast` / `UnicastHopLimit`, `udp-take-error!`. |
| All socket Drop/close | Move-only cleanup with `with`, plus explicit `*-close!`; no automatic cleanup insertion. |
| Nonblocking/read/write timeout setters/getters | Omitted; explicit try operations and per-call absolute deadlines replace mutable socket mode/timeouts. |
| only_v6/set_only_v6 | Omitted; fixed v6-only construction policy. |
| incoming/into_incoming | Omitted; bounded explicit accept operations replace iterator traits. |
| Raw/borrowed native-handle conversions | Omitted; no safe descriptor escape or adoption surface. |
| Address-list/string conversion traits | Omitted; canonical concrete endpoints, caller-owned resolution. |
| Vectored I/O, keepalive tuning, linger, OOB, reuse address/port | Explicit v1 omissions; no common required consumer in the selected integration. |
| UDP multicast membership/loop/hops | Explicit v1 omission; outside the accepted TCP/UDP/DNS integration. |
| Platform extension options, Debug/blanket traits | Omitted; no trait/impl system or platform-specific public policy. |

DNS, TLS, HTTP, async runtime design, public readiness sets, Unix sockets and
named pipes remain outside this API. Private bounded readiness waiting belongs
to the adapter contract for synchronous operations.
