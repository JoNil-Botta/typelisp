# Thread and sync effect inventory

The raw integer-address and OS-handle APIs in `stdlib.thread` and
`stdlib.sync` require declaration-level `unsafe`. An `unsafe` block at an
internal call site is the local discharge of the stated proof, not permission
for a safe caller to pass an arbitrary address. The underlying seqcst atomic
externs, platform ABI symbols, allocation paths, and syscalls are unchanged.

## `stdlib.thread`

| Declaration set | Effect | Reason or safe proof |
| --- | --- | --- |
| `spawn-result-handle-or`, `spawn-result-clear-tid-addr-or`, `spawn-result-result-addr-or`, `spawn-result-thread-or` | unsafe | Project a native handle, raw cell address, or raw `Thread` from the spawn result. |
| `array-u8-addr`, `array-u64-addr`, `array-i64-addr`, `array-i32-addr`, `array-string-addr`, `array-i64-vec-addr` | unsafe | Erase a dynamic-array borrow's extent and lifetime into an integer. |
| `addr->mut-i32`, `addr->mut-i64`, `addr->mut-string`, `addr->mut-i64-vec`; `read-i32`, `write-i32!`, `read-i64`, `write-i64!`, `read-string`, `write-string!`, `read-i64-vec`, `write-i64-vec!` | unsafe | Reconstruct or dereference a pointer; caller proves type, extent, alignment, initialization, and lifetime. |
| `linux-futex-wait`, `linux-futex-wait-for`, `linux-futex-wake`, `linux-monotonic-ms`, `linux-child-main`, `linux-wait-i32-change`, `linux-spawn`; `thread-windows-wait-started`, `thread-windows-spawn` | unsafe | Kernel or child entry consumes borrowed integer addresses, raw contexts, or caller-owned unbounded timespec storage. |
| `spawn`, `wait-for`, `join`, `linux-wait-for`, `thread-windows-wait-for`, `linux-join`, `thread-windows-join`; `handle-spawn-i64`, `handle-spawn-bool`, `handle-spawn-unit` | unsafe | Raw context/result and native thread-handle lifecycle; caller proves publication and single join. |
| `semaphore-create-handle-or`, `semaphore-create`, `semaphore-wait`, `semaphore-post`, `semaphore-close` | unsafe | Expose, use, or release an OS handle; caller proves live resource and close authority. |
| `thread-linux-backtrace-stack-set`, `thread-windows-create-thread`, `thread-windows-wait-single`, `thread-windows-close-handle`, `thread-windows-create-semaphore`, `thread-windows-release-semaphore` | unsafe | Raw pointer or OS-handle foreign ABI. |
| Generated `(handle T).spawn`, `wait-for`, `join`; `spawn-string`, `spawn-i64-vec`, `spawn-box-i64`, `join-string`, `join-i64-vec`, `join-box-i64` | safe | Direct nullary closures are compiler-checked. Private result cells have a spanning atomic owner, worker publication precedes join, and typed handles are consumed once. The raw call is locally unsafe. |
| `spawn-result-ok?`, `join-result-value-or`, generated `join-value-or`, `i64-vec-copy`, `linux-clone-flags`, `linux-wait-retry?`, `count-byte-bits`, `count-affinity-bytes` | safe | Enum/scalar inspection, owned copying, or pure arithmetic; no raw resource is trusted. |
| `linux-default-worker-count`, `thread-windows-default-worker-count`, `default-worker-count`, `thread-windows-active-processor-count`, `thread-windows-switch-to-thread`, `thread-linux-runtime-init` | safe | Fixed OS query or TLS setup; raw scratch storage is private, bounded, and live for the call. |
| `linux-exit-current`, `test-fail`, `test-assert`, `test-assert-i64-eq`, `test-assert-semaphore-err` | safe | No caller-supplied address/handle is dereferenced; test assertions and termination are not memory-safety adapters. |

`thread-windows-entry` remains a plain backend-owned callable because the
checker currently forbids passing an unsafe callable as a foreign
function-pointer argument to `CreateThread`. This is the one outstanding
effect gap, tracked by #7742; callers must not invoke this backend symbol
directly.

## `stdlib.sync`

| Declaration set | Effect | Reason or safe proof |
| --- | --- | --- |
| `sync-windows-virtual-alloc`, `sync-windows-virtual-free`, `runtime-alloc`, `runtime-free`, `addr->mut-i64`, `addr->mut-string`, `addr-slot->mut-i64`, `addr-slot->i64` | unsafe | Allocate/free or reconstruct a raw pointer; callers prove byte extent, eight-byte slot alignment, and ownership. |
| `atomic-i64-load`, `atomic-i64-store!`, `atomic-i64-add!`, `atomic-i64-fetch-add!`, `atomic-i64-cas!`; `atomic-i64-load-ptr`, `atomic-i64-store-ptr!`, `atomic-i64-add-ptr!`, `atomic-i64-fetch-add-ptr!`, `atomic-i64-cas-ptr!`; `read-i64`, `write-i64!`, `read-string`, `write-string!` | unsafe | Dereference raw address/slot or pointer. Atomic externs remain seqcst; a raw integer supplies no alignment or live-cell proof. |
| `semaphore`, `semaphore-wait`, `semaphore-post`, `semaphore-close` | unsafe | Reconstruct or operate on a native handle. |
| `i64-mutex-unlock-handle`, `i64-mutex-untrack-user`, `i64-mutex-track-user`, `i64-mutex-closed?`, `i64-mutex-lock-abort`, `i64-mutex-create-semaphore`, `i64-mutex-guard-control-addr`, `i64-mutex-guard-mutex-handle`, `i64-mutex-guard-value-addr`, `i64-mutex-store-raw!`, `i64-mutex-load-raw` | unsafe | Consume/project/fabricate a raw mutex cell or semaphore handle. |
| `i64-channel-handle`, `i64-channel-create-semaphores`, `i64-channel-store-raw!`, `i64-channel-load-raw`; corresponding `channel-i64-pair-*` and `channel-string-*` handle, create-semaphores, store-raw!, load-raw declarations | unsafe | Consume/project/fabricate raw ring and native-handle state. |
| `i64-mutex-{create,lock,get,set!,add!,close}`, `i64-mutex-create-initial-or`; `i64-channel-{create,send,recv,close}`, `i64-channel-create-capacity-or`, `i64-channel-send-value-ok?`, `i64-channel-recv-or` | unsafe | These non-generated record families expose raw integer fields. Every operation that allocates, trusts, or returns one therefore keeps the caller obligation. |
| Generated `(channel i64).to-raw`, `store-raw!`, `load-raw`; generated `(mutex i64).to-raw`, `from-raw`, `store-raw!`, `load-raw`, `guard-control-addr`, `guard-mutex-handle`, `guard-value-addr`, `unlock-handle`, `untrack-user` | unsafe | Generated aliases cannot launder raw reconstruction, projection, or handle operations into safe calls. |
| Generated `create`, `send`, `recv`, `lock`, guard `get`/`set!`/`add!`, `close`; handwritten `channel-i64-pair-*` and `channel-string-*` create/send/recv/close, create-capacity-or, send-value-ok?, recv-or | safe | For handles produced by `create`: fixed runtime allocation and slot bounds, semaphore publication/acquire for rings, mutex guard exclusivity, and close protocol protecting live users. Unsafe calls are local to these proofs. Public record construction is not itself a capability check (#7718). |
| All `*-ok-result`/`*-err-result` constructors; `*-create-capacity-ok?`, `i64-mutex-create-initial-ok?`, `*-next-index`; generated `max-capacity`, `raw-field-count`, `empty`, `empty-raw`, `create-capacity-ok?`/`-or`, `send-value-ok?`, `recv-or`, `create-initial-ok?`/`-or` | safe | Pure result construction/inspection or a delegating typed operation; zero-valued sentinels do not dereference a resource. |
| `abort`, `sync-windows-exit-process`, `test-fail`, `test-assert` | safe | Termination/assertion does not trust a caller-supplied address or handle. |

Raw record constructors remain nameable. #7718 owns the checked-capability
repair before a forged generated `Channel`/`Mutex` or handwritten pair/String
channel can be safely passed to a typed operation. These effects make the
integer-address adapters and generated load/store/projection operations reject
safe callers, but do not claim that record fields are sealed.
