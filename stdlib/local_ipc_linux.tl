;# Linux x86-64 adapter for `stdlib.local_ipc`: the client end of one
;# filesystem Unix-domain stream socket, reached through raw syscalls without
;# libc.
;#
;# `adapter` returns the `LocalIpcAdapter` to hand to `local_ipc.connect`. It
;# enforces the caller's pathname policy; `local_ipc.connect` applies the peer
;# policy to the SO_PEERCRED facts this adapter reports.
;#
;# Every connect attempt is one whole construction transaction:
;# `newfstatat(AT_SYMLINK_NOFOLLOW)` must find a socket whose owner, group and
;# permission bits pass the pathname policy, then one
;# `socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC)` and one
;# `connect`. Only `connect == 0` is a connection. When the listener's backlog
;# is full a nonblocking AF_UNIX connect fails with EAGAIN and leaves the
;# socket unconnected, even though that socket then polls writable with
;# SO_ERROR 0, so readiness and SO_ERROR never complete a connect here. The
;# attempt closes its descriptor and reports `RetryConnect`; the contract
;# pauses with a zero-descriptor `poll` and a fresh transaction starts. EINTR
;# is handled the same way, since a descriptor whose connect failed is never
;# reused.
;#
;# Pathname facts and peer facts are untrusted policy inputs, not server
;# authentication. `newfstatat` examines only the final component (parent
;# components may be symlinks) and races any replacement of the path.
;# SO_PEERCRED reports the credentials the listener had when it called
;# `listen`; a listener can be inherited or passed on, and a PID can exit and be
;# reused. A server running as the same user passes a user-id policy.
;#
;# A connected descriptor lives in a process-wide table of `slot-capacity`
;# slots. The contract sees only a token encoding a slot and that slot's
;# generation. Every operation validates the token and holds a lease on the
;# slot across its host call, so a stale or forged token never reaches a
;# descriptor, a closed descriptor is never used, and every descriptor is
;# closed exactly once even when a forged token races the owner's close.
;# Tokens are not secrets: authority is the `LocalIpcConnection` owning one.
;#
;# Writes use `sendto(MSG_NOSIGNAL)`, so a peer that has gone away yields
;# EPIPE rather than a SIGPIPE that would end the process. A read or write is
;# one nonblocking attempt on the handed buffer's own storage, so nothing is
;# ever pending. A readiness wait polls one descriptor for at most
;# `local_ipc.wait-slice-ms`. Native structures live on the stack and are
;# zeroed before each host call; apart from the closures `adapter` builds,
;# nothing here allocates.
;#
;# On other targets every host call reports ENOSYS, which is
;# `UnsupportedTarget`.
(import stdlib.byte_buf)
(import stdlib.local_ipc)
(import stdlib.time)

;: Linux x86-64 syscall numbers.
(define syscall-read : i64
  0)

;: See `syscall-read`.
(define syscall-close : i64
  3)

;: See `syscall-read`.
(define syscall-poll : i64
  7)

;: See `syscall-read`.
(define syscall-socket : i64
  41)

;: See `syscall-read`.
(define syscall-connect : i64
  42)

;: See `syscall-read`.
(define syscall-sendto : i64
  44)

;: See `syscall-read`.
(define syscall-getsockopt : i64
  55)

;: See `syscall-read`.
(define syscall-newfstatat : i64
  262)

;: `AF_UNIX`.
(define af-unix : i64
  1)

;: `SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC`: the only socket type this
;: adapter creates, atomically nonblocking and close-on-exec.
(define socket-type : i64
  526337)

;: `struct sockaddr_un`: 110 bytes, `sun_family` at 0, `sun_path[108]` at 2.
;: The adapter's zeroed storage is 112 bytes, 8-aligned.
(define sockaddr-path-offset : i64
  2)

;: `SOL_SOCKET`.
(define sol-socket : i64
  1)

;: `SO_PEERCRED`.
(define so-peercred : i64
  17)

;: `AT_FDCWD`.
(define at-fdcwd : i64
  -100)

;: `AT_SYMLINK_NOFOLLOW`.
(define at-symlink-nofollow : i64
  256)

;: `struct stat` is 144 bytes; these are the byte offsets of the u32 fields
;: `st_mode`, `st_uid` and `st_gid`.
(define stat-mode-offset : i64
  24)

;: See `stat-mode-offset`.
(define stat-uid-offset : i64
  28)

;: See `stat-mode-offset`.
(define stat-gid-offset : i64
  32)

;: `S_IFMT`, `S_IFSOCK` and `S_IFLNK`.
(define s-ifmt : i64
  61440)

;: See `s-ifmt`.
(define s-ifsock : i64
  49152)

;: See `s-ifmt`.
(define s-iflnk : i64
  40960)

;: `MSG_NOSIGNAL`.
(define msg-nosignal : i64
  16384)

;: `poll` event bits.
(define pollin : i64
  1)

;: See `pollin`.
(define pollout : i64
  4)

;: See `pollin`.
(define pollerr : i64
  8)

;: See `pollin`.
(define pollhup : i64
  16)

;: See `pollin`.
(define pollnval : i64
  32)

;: Linux errno values this adapter distinguishes.
(define eperm : i64
  1)

;: See `eperm`.
(define enoent : i64
  2)

;: See `eperm`.
(define eintr : i64
  4)

;: See `eperm`.
(define ebadf : i64
  9)

;: See `eperm`. Also `EWOULDBLOCK`.
(define eagain : i64
  11)

;: See `eperm`.
(define enomem : i64
  12)

;: See `eperm`.
(define eacces : i64
  13)

;: See `eperm`.
(define enotdir : i64
  20)

;: See `eperm`.
(define einval : i64
  22)

;: See `eperm`.
(define enfile : i64
  23)

;: See `eperm`.
(define emfile : i64
  24)

;: See `eperm`.
(define epipe : i64
  32)

;: See `eperm`.
(define enametoolong : i64
  36)

;: See `eperm`.
(define enosys : i64
  38)

;: See `eperm`.
(define eloop : i64
  40)

;: See `eperm`.
(define enotsock : i64
  88)

;: See `eperm`.
(define eprototype : i64
  91)

;: See `eperm`.
(define eprotonosupport : i64
  93)

;: See `eperm`.
(define eafnosupport : i64
  97)

;: See `eperm`.
(define econnreset : i64
  104)

;: See `eperm`.
(define enobufs : i64
  105)

;: See `eperm`.
(define eisconn : i64
  106)

;: See `eperm`.
(define enotconn : i64
  107)

;: See `eperm`.
(define econnrefused : i64
  111)

;: See `eperm`.
(define ealready : i64
  114)

;: See `eperm`.
(define einprogress : i64
  115)

;: Largest descriptor a kernel returns; anything larger is adapter corruption.
(define fd-max : i64
  2147483647)

;: Linux `struct pollfd`: 8 bytes, 4-aligned.
(defstruct LinuxPollFd
  (:repr c)
  (fd i32)
  (events i16)
  (revents i16))

;: Linux `struct ucred`: 12 bytes, 4-aligned.
(defstruct LinuxUcred
  (:repr c)
  (pid i32)
  (uid u32)
  (gid u32))

;: A `socklen_t` value-result argument.
(defstruct LinuxSockLen
  (:repr c)
  (value u32))

;: The caller's requirements on the socket's pathname metadata, checked before
;: every attempt. `owner-id` and `group-id` are the required `st_uid` and
;: `st_gid` (0..4294967294), or -1 for any; `forbidden-mode` holds permission
;: bits within 0o7777 that must be clear. A policy with a field out of range
;: fails every connect with `PolicyRejected` and host code EINVAL.
(defstruct LocalIpcLinuxPathPolicy
  (owner-id i64)
  (group-id i64)
  (forbidden-mode i64))

;: Host codes of pathname-policy rejections: the errno a comparable kernel
;: refusal reports. The final component is a symlink.
(define rejected-symlink : i64
  eloop)

;: The final component is not a socket.
(define rejected-not-socket : i64
  enotsock)

;: The owner or group differs from the policy.
(define rejected-identity : i64
  eperm)

;: A permission bit the policy forbids is set.
(define rejected-mode : i64
  eacces)

;: True for -1 (any) or a real user or group id.
(define (id-or-any? [value : i64]) : bool
  (and (>= value -1) (<= value 4294967294)))

;: True when every field of `policy` is in range.
(define (path-policy-valid? [policy : LocalIpcLinuxPathPolicy]) : bool
  (and
    (id-or-any? policy.owner-id)
    (id-or-any? policy.group-id)
    (>= policy.forbidden-mode 0)
    (<= policy.forbidden-mode 4095)))

;: Check pathname facts against `policy`. A symlink or other non-socket final
;: component is rejected before owner, group and mode are looked at.
(define (path-facts-check
  [policy : LocalIpcLinuxPathPolicy]
  [mode : i64]
  [owner : i64]
  [group : i64]) : local_ipc.LocalIpcStatus
  (let
    [kind : i64 (bit-and mode s-ifmt)]
    [rejection : i64
      (cond
        [(= kind s-iflnk) rejected-symlink]
        [(not (= kind s-ifsock)) rejected-not-socket]
        [(and (>= policy.owner-id 0) (not (= owner policy.owner-id)))
          rejected-identity]
        [(and (>= policy.group-id 0) (not (= group policy.group-id)))
          rejected-identity]
        [(not (= (bit-and mode policy.forbidden-mode) 0)) rejected-mode]
        [else 0])]
    (if (= rejection 0)
      (local_ipc.LocalIpcStatus.Ok)
      (local_ipc.LocalIpcStatus.Err
        (local_ipc.make-error
          (local_ipc.LocalIpcErrorKind.PolicyRejected)
          rejection)))))

;: The errno of a raw syscall result, or 0 when it is not in -4095..-1.
(define (host-errno [result : i64]) : i64
  (if (and (< result 0) (>= result -4095))
    (- 0 result)
    0))

;: An adapter-corruption error.
(define (corrupt) : local_ipc.LocalIpcError
  (local_ipc.make-error (local_ipc.LocalIpcErrorKind.AdapterCorrupt) 0))

;: The error for errno `code` from `newfstatat`, `socket` or `connect`.
(define (construction-error [code : i64]) : local_ipc.LocalIpcError
  (local_ipc.make-error
    (cond
      [(or
          (= code enoent)
          (= code enotdir)
          (= code econnrefused)
          (= code eprototype))
        (local_ipc.LocalIpcErrorKind.Unavailable)]
      [(or (= code eacces) (= code eperm))
        (local_ipc.LocalIpcErrorKind.PermissionDenied)]
      [(or (= code emfile) (= code enfile) (= code enobufs) (= code enomem))
        (local_ipc.LocalIpcErrorKind.ResourceExhausted)]
      [(or (= code enametoolong) (= code eloop))
        (local_ipc.LocalIpcErrorKind.InvalidEndpoint)]
      [(or
          (= code enosys)
          (= code eafnosupport)
          (= code eprotonosupport)
          (= code einval))
        (local_ipc.LocalIpcErrorKind.UnsupportedTarget)]
      [(or (= code einprogress) (= code ealready) (= code eisconn))
        (local_ipc.LocalIpcErrorKind.AdapterCorrupt)]
      [else (local_ipc.LocalIpcErrorKind.HostFailure)])
    code))

;: The error for errno `code` from a data, peer or readiness call.
(define (connection-error [code : i64]) : local_ipc.LocalIpcError
  (local_ipc.make-error
    (cond
      [(or (= code epipe) (= code econnreset) (= code enotconn))
        (local_ipc.LocalIpcErrorKind.PeerClosed)]
      [(or (= code enobufs) (= code enomem))
        (local_ipc.LocalIpcErrorKind.ResourceExhausted)]
      [(= code ebadf) (local_ipc.LocalIpcErrorKind.AdapterCorrupt)]
      [(= code enosys) (local_ipc.LocalIpcErrorKind.UnsupportedTarget)]
      [else (local_ipc.LocalIpcErrorKind.HostFailure)])
    code))

;: One raw syscall. Other targets report ENOSYS. Under `typelisp test` it
;: passes through the injection hooks at the end of this module.
(unsafe
  (define (host
    [number : i64]
    [a : i64]
    [b : i64]
    [c : i64]
    [d : i64]
    [e : i64]
    [f : i64]) : i64
    (cfg
      test
      (unsafe
        (test-host number a b c d e f))
      (unsafe
        (host-raw number a b c d e f)))))

;: The syscall itself.
(unsafe
  (define (host-raw
    [number : i64]
    [a : i64]
    [b : i64]
    [c : i64]
    [d : i64]
    [e : i64]
    [f : i64]) : i64
    (cfg
      windows
      (- 0 enosys)
      (unsafe
        (syscall number a b c d e f)))))

;: A pointer as a syscall argument.
(unsafe
  (define (ptr-arg [address : (MutPtr u8)]) : i64
    (unsafe
      (cast (ptr->int address) : i64))))

;: Read the u32 at `offset` bytes into native storage.
(unsafe
  (define (native-u32 [base : (MutPtr u8)] [offset : i64]) : i64
    (cast
      (unsafe
        (ptr-read (ptr-cast (ptr-offset base offset) : (Ptr u32))))
      : i64)))

;: Slots in the descriptor table: the most connections a process holds at once.
(define slot-capacity : i64
  256)

;: Words per slot: the state word, the descriptor, the lease count, the poison.
(define slot-words : i64
  4)

;: Slot states, the low three bits of the state word; the other bits hold the
;: slot's generation. Free and reserved slots have no descriptor; a live slot
;: can be leased; a closing slot waits for its last lease; exactly one party
;: claims the close; a retired slot exhausted its generations.
(define state-free : i64
  0)

;: See `state-free`.
(define state-reserved : i64
  1)

;: See `state-free`.
(define state-live : i64
  2)

;: See `state-free`.
(define state-closing : i64
  3)

;: See `state-free`.
(define state-close-claimed : i64
  4)

;: See `state-free`.
(define state-retired : i64
  5)

;: Largest generation, so a token stays below 2^63.
(define generation-max : i64
  18014398509481984)

;: Poison: none; the descriptor is still ours but its results are corrupt; the
;: descriptor is not open any more (POLLNVAL, EBADF) and must never be closed.
(define poison-none : i64
  0)

;: See `poison-none`.
(define poison-corrupt : i64
  1)

;: See `poison-none`.
(define poison-lost : i64
  2)

;: Word storage of the descriptor table, allocated once for the process.
(define slot-table : (__tl_dyn-array i64)
  (__tl_make-array i64 (* slot-capacity slot-words)))

;: One word of one slot: 0 state, 1 descriptor, 2 leases, 3 poison.
(unsafe
  (define (slot-word [slot : i64] [field : i64]) : (MutPtr i64)
    (unsafe
      (ptr-offset (__tl_array-data slot-table) (+ (* slot slot-words) field)))))

;: The state word for `generation` and `state`.
(define (state-word [generation : i64] [state : i64]) : i64
  (+ (* generation 8) state))

;: Reserve a free slot for one construction attempt, or -1 when none is free.
(unsafe
  (define (slot-reserve!) : i64
    (let
      [slot : i64 0]
      [found : i64 -1]
      (begin
        (while (and (< found 0) (< slot slot-capacity))
          (let
            [word : i64
              (unsafe
                (atomic-load (slot-word slot 0)))]
            (begin
              (if (and
                (= (% word 8) state-free)
                (=
                  (unsafe
                    (atomic-cas!
                      (slot-word slot 0)
                      word
                      (+ (- word state-free) state-reserved)))
                  word))
                (set! found slot)
                unit)
              (set! slot (+ slot 1)))))
        found))))

;: Return a reserved slot that published nothing.
(unsafe
  (define (slot-unreserve! [slot : i64]) : unit
    (let
      [word : i64
        (unsafe
          (atomic-load (slot-word slot 0)))]
      (unsafe
        (atomic-store! (slot-word slot 0) (- word state-reserved))))))

;: Publish `fd` in a reserved slot under the slot's next generation and return
;: its token, or -1 after retiring a slot whose generations are exhausted.
(unsafe
  (define (slot-publish! [slot : i64] [fd : i64]) : i64
    (let
      [generation : i64
        (+
          (/
            (unsafe
              (atomic-load (slot-word slot 0)))
            8)
          1)]
      (if (> generation generation-max)
        (begin
          (unsafe
            (atomic-store!
              (slot-word slot 0)
              (state-word (- generation 1) state-retired)))
          -1)
        (begin
          (unsafe
            (atomic-store! (slot-word slot 1) fd))
          (unsafe
            (atomic-store! (slot-word slot 3) poison-none))
          (unsafe
            (atomic-store!
              (slot-word slot 0)
              (state-word generation state-live)))
          (+ (* generation slot-capacity) slot))))))

;: Slot of a token.
(define (token-slot [token : i64]) : i64
  (% token slot-capacity))

;: The live state word a token names, or -1 for a value no publish returns.
(define (token-word [token : i64]) : i64
  (if (or (< token slot-capacity) (> (/ token slot-capacity) generation-max))
    -1
    (state-word (/ token slot-capacity) state-live)))

;: `lease-acquire` result for a stale, closed or forged token.
(define lease-stale : i64
  -1)

;: `lease-acquire` result for a poisoned slot.
(define lease-poisoned : i64
  -2)

;: Lease the descriptor a token names. A result of at least 0 is the
;: descriptor, which stays open until `lease-release!`; otherwise no lease is
;: held. The lease count is raised before the state word is read and a close
;: moves the state before it reads the lease count, so either the close sees
;: this lease or this lease sees the close.
(unsafe
  (define (lease-acquire [token : i64]) : i64
    (let
      [expected : i64 (token-word token)]
      (if (< expected 0)
        lease-stale
        (let
          [slot : i64 (token-slot token)]
          [_lease : i64
            (unsafe
              (atomic-fetch-add! (slot-word slot 2) 1))]
          (cond
            [(not
                (=
                  (unsafe
                    (atomic-load (slot-word slot 0)))
                  expected))
              (begin
                (unsafe
                  (lease-release! slot))
                lease-stale)]
            [(not
                (=
                  (unsafe
                    (atomic-load (slot-word slot 3)))
                  poison-none))
              (begin
                (unsafe
                  (lease-release! slot))
                lease-poisoned)]
            [else
              (unsafe
                (atomic-load (slot-word slot 1)))]))))))

;: Drop one lease. The last lease on a closing slot performs its close; that
;: result has no caller left to receive it.
(unsafe
  (define (lease-release! [slot : i64]) : unit
    (if (=
      (unsafe
        (atomic-fetch-add! (slot-word slot 2) -1))
      1)
      (let
        [word : i64
          (unsafe
            (atomic-load (slot-word slot 0)))]
        (if (= (% word 8) state-closing)
          (begin
            (unsafe
              (slot-claim-close! slot word))
            unit)
          unit))
      unit)))

;: Mark the leased slot poisoned. Poison only rises, so a racing forged lease
;: can never turn a lost descriptor back into one this adapter would close.
(unsafe
  (define (slot-poison! [slot : i64] [poison : i64]) : unit
    (let
      [current : i64
        (unsafe
          (atomic-load (slot-word slot 3)))]
      (while (> poison current)
        (let
          [seen : i64
            (unsafe
              (atomic-cas! (slot-word slot 3) current poison))]
          (set!
            current
            (if (= seen current)
              poison
              seen)))))))

;: Claim the close of a closing slot observed at `word`. The one party whose
;: claim succeeds closes the descriptor, unless it was lost, and frees the
;: slot; any other party gets `Closed`, meaning the close is not its to report.
(unsafe
  (define (slot-claim-close! [slot : i64] [word : i64]) : local_ipc.LocalIpcStatus
    (if (not
      (=
        (unsafe
          (atomic-cas!
            (slot-word slot 0)
            word
            (+ (- word state-closing) state-close-claimed)))
        word))
      (local_ipc.LocalIpcStatus.Err
        (local_ipc.make-error (local_ipc.LocalIpcErrorKind.Closed) 0))
      (let
        [fd : i64
          (unsafe
            (atomic-load (slot-word slot 1)))]
        [lost : bool
          (=
            (unsafe
              (atomic-load (slot-word slot 3)))
            poison-lost)]
        [result : i64
          (if lost
            0
            (unsafe
              (host syscall-close fd 0 0 0 0 0)))]
        (begin
          (unsafe
            (atomic-store! (slot-word slot 1) -1))
          (unsafe
            (atomic-store! (slot-word slot 3) poison-none))
          (unsafe
            (atomic-store!
              (slot-word slot 0)
              (+ (- word state-closing) state-free)))
          (cond
            [lost (local_ipc.LocalIpcStatus.Err (corrupt))]
            ;; Linux releases the descriptor even when close reports EINTR, so
            ;; it is never retried.
            [(or (= result 0) (= (host-errno result) eintr))
              (local_ipc.LocalIpcStatus.Ok)]
            [(= (host-errno result) 0) (local_ipc.LocalIpcStatus.Err (corrupt))]
            [else
              (local_ipc.LocalIpcStatus.Err
                (connection-error (host-errno result)))]))))))

;: Close the connection a token names. The slot stops accepting leases first;
;: the descriptor is closed now if no lease is held, else by the last lease,
;: and in that case this reports `Ok`.
(unsafe
  (define (token-close! [token : i64]) : local_ipc.LocalIpcStatus
    (let
      [live : i64 (token-word token)]
      [slot : i64 (token-slot token)]
      (if (or
        (< live 0)
        (not
          (=
            (unsafe
              (atomic-cas!
                (slot-word slot 0)
                live
                (+ (- live state-live) state-closing)))
            live)))
        (local_ipc.LocalIpcStatus.Err
          (local_ipc.make-error (local_ipc.LocalIpcErrorKind.Closed) 0))
        (if (=
          (unsafe
            (atomic-load (slot-word slot 2)))
          0)
          (match (unsafe
            (slot-claim-close! slot (+ (- live state-live) state-closing)))
            [(local_ipc.LocalIpcStatus.Err failure)
              (match failure.kind
                [(local_ipc.LocalIpcErrorKind.Closed)
                  (local_ipc.LocalIpcStatus.Ok)]
                [_ (local_ipc.LocalIpcStatus.Err failure)])]
            [(local_ipc.LocalIpcStatus.Ok) (local_ipc.LocalIpcStatus.Ok)])
          (local_ipc.LocalIpcStatus.Ok))))))

;: Close a construction descriptor exactly once. Its result is not reported:
;: the attempt's own outcome is.
(unsafe
  (define (close-construction [fd : i64]) : unit
    (begin
      (unsafe
        (host syscall-close fd 0 0 0 0 0))
      unit)))

;: Copy the validated name into zeroed `sockaddr_un` storage.
;:
;: Caller contract: `address` points at 112 writable zeroed bytes and `name`
;: holds at most `local_ipc.unix-path-max` bytes, so the NUL after it stays.
(unsafe
  (define (address-fill! [address : (MutPtr u8)] [name : (& name bytes)]) : unit
    (let
      [index : i64 0]
      [length : i64 (byte_buf.bytes-length name)]
      (begin
        (unsafe
          (ptr-write! address (cast af-unix : u8)))
        (while (< index length)
          (begin
            (unsafe
              (ptr-write!
                (ptr-offset address (+ sockaddr-path-offset index))
                (byte_buf.bytes-ref name index)))
            (set! index (+ index 1))))))))

;: The pathname check of one attempt, on the NUL-terminated path in `address`.
(unsafe
  (define (path-check
    [policy : LocalIpcLinuxPathPolicy]
    [address : (MutPtr u8)]
    [status : (MutPtr u8)]) : local_ipc.LocalIpcStatus
    (let
      [result : i64
        (unsafe
          (host
            syscall-newfstatat
            at-fdcwd
            (ptr-arg (ptr-offset address sockaddr-path-offset))
            (ptr-arg status)
            at-symlink-nofollow
            0
            0))]
      (cond
        [(= result 0)
          (path-facts-check
            policy
            (unsafe
              (native-u32 status stat-mode-offset))
            (unsafe
              (native-u32 status stat-uid-offset))
            (unsafe
              (native-u32 status stat-gid-offset)))]
        [(= (host-errno result) 0) (local_ipc.LocalIpcStatus.Err (corrupt))]
        [else
          (local_ipc.LocalIpcStatus.Err
            (construction-error (host-errno result)))]))))

;: The socket and connect of one attempt, in reserved `slot`. The slot is
;: published or returned, and the descriptor is published or closed once; a
;: value no kernel returns as a descriptor is never closed.
(unsafe
  (define (socket-connect [slot : i64] [address : (MutPtr u8)] [length : i64]) : local_ipc.LocalIpcConnectStep
    (let
      [fd : i64
        (unsafe
          (host syscall-socket af-unix socket-type 0 0 0 0))]
      (if (or (< fd 0) (> fd fd-max))
        (begin
          (unsafe
            (slot-unreserve! slot))
          (local_ipc.LocalIpcConnectStep.ConnectFailed
            (if (> (host-errno fd) 0)
              (construction-error (host-errno fd))
              (corrupt))))
        (let
          [result : i64
            (unsafe
              (host syscall-connect fd (ptr-arg address) (+ length 3) 0 0 0))]
          (if (= result 0)
            (let
              [token : i64
                (unsafe
                  (slot-publish! slot fd))]
              (if (< token 0)
                (begin
                  (unsafe
                    (close-construction fd))
                  (local_ipc.LocalIpcConnectStep.ConnectFailed
                    (local_ipc.make-error
                      (local_ipc.LocalIpcErrorKind.ResourceExhausted)
                      0)))
                (local_ipc.LocalIpcConnectStep.Connected token)))
            (let
              [code : i64 (host-errno result)]
              (begin
                (unsafe
                  (close-construction fd))
                (unsafe
                  (slot-unreserve! slot))
                (cond
                  [(or (= code eagain) (= code eintr))
                    (local_ipc.LocalIpcConnectStep.RetryConnect)]
                  [(= code 0)
                    (local_ipc.LocalIpcConnectStep.ConnectFailed (corrupt))]
                  [else
                    (local_ipc.LocalIpcConnectStep.ConnectFailed
                      (construction-error code))])))))))))

;: True when a handed buffer's live length fits its storage.
(define (buffer-sound? [buffer : (& buffer byte_buf.ByteBuf)]) : bool
  (and (>= buffer.len 0) (<= buffer.len (array-length buffer.slots))))

;: One whole construction transaction for socket path `name` under `policy`.
;: The name and policy are checked here, before any native storage is
;: written, so this is sound for every argument.
(define (attempt [policy : LocalIpcLinuxPathPolicy] [name : (& name bytes)]) : local_ipc.LocalIpcConnectStep
  (let
    [address-storage : (Array u64 14) (init)]
    [status-storage : (Array u64 18) (init)]
    [address : (MutPtr u8)
      (unsafe
        (ptr-cast (ptr-addr-of address-storage) : (MutPtr u8)))]
    [status : (MutPtr u8)
      (unsafe
        (ptr-cast (ptr-addr-of status-storage) : (MutPtr u8)))]
    (cond
      [(not (path-policy-valid? policy))
        (local_ipc.LocalIpcConnectStep.ConnectFailed
          (local_ipc.make-error
            (local_ipc.LocalIpcErrorKind.PolicyRejected)
            einval))]
      [(not (local_ipc.unix-path-bytes-valid? name))
        (local_ipc.LocalIpcConnectStep.ConnectFailed
          (local_ipc.make-error (local_ipc.LocalIpcErrorKind.InvalidEndpoint) 0))]
      [else
        (begin
          (unsafe
            (address-fill! address name))
          (match (unsafe
            (path-check policy address status))
            [(local_ipc.LocalIpcStatus.Err failure)
              (local_ipc.LocalIpcConnectStep.ConnectFailed failure)]
            [(local_ipc.LocalIpcStatus.Ok)
              (let
                [slot : i64
                  (unsafe
                    (slot-reserve!))]
                (if (< slot 0)
                  (local_ipc.LocalIpcConnectStep.ConnectFailed
                    (local_ipc.make-error
                      (local_ipc.LocalIpcErrorKind.ResourceExhausted)
                      0))
                  (unsafe
                    (socket-connect slot address (byte_buf.bytes-length name)))))]))])))

;: Adapter `connect-attempt` under `policy`. Any code holding the adapter can
;: call this with any family and bytes.
(define (connect-attempt
  [policy : LocalIpcLinuxPathPolicy]
  [family : i64]
  [name : byte_buf.ByteBuf]) : local_ipc.LocalIpcConnectReply
  (let
    [step : local_ipc.LocalIpcConnectStep
      (cond
        [(not (= family local_ipc.family-unix-path))
          (local_ipc.LocalIpcConnectStep.ConnectFailed
            (local_ipc.make-error
              (local_ipc.LocalIpcErrorKind.UnsupportedTarget)
              0))]
        [(not (buffer-sound? (& name)))
          (local_ipc.LocalIpcConnectStep.ConnectFailed
            (local_ipc.make-error
              (local_ipc.LocalIpcErrorKind.InvalidEndpoint)
              0))]
        [else (attempt policy (byte_buf.as-bytes (& name)))])]
    (local_ipc.LocalIpcConnectReply step name)))

;: Peer facts from one `getsockopt(SO_PEERCRED)` result. Only a successful call
;: that returned exactly 12 bytes and a nonnegative PID yields facts; Linux has
;: no session id.
(define (peer-step
  [result : i64]
  [length : i64]
  [pid : i64]
  [uid : i64]
  [gid : i64]) : local_ipc.LocalIpcPeerStep
  (cond
    [(and
        (= result 0)
        (= length (comptime (size-of (type LinuxUcred))))
        (>= pid 0))
      (local_ipc.LocalIpcPeerStep.PeerKnown
        (local_ipc.LocalIpcPeer pid uid gid -1))]
    [(> (host-errno result) 0)
      (local_ipc.LocalIpcPeerStep.PeerFailed
        (connection-error (host-errno result)))]
    [else (local_ipc.LocalIpcPeerStep.PeerFailed (corrupt))]))

;: Adapter `peer`.
(define (linux-peer [_context : i64] [handle : i64]) : local_ipc.LocalIpcPeerStep
  (let
    [fd : i64
      (unsafe
        (lease-acquire handle))]
    (cond
      [(= fd lease-stale)
        (local_ipc.LocalIpcPeerStep.PeerFailed
          (local_ipc.make-error (local_ipc.LocalIpcErrorKind.Closed) 0))]
      [(= fd lease-poisoned) (local_ipc.LocalIpcPeerStep.PeerFailed (corrupt))]
      [else
        (let
          [credentials : LinuxUcred
            (LinuxUcred (cast 0 : i32) (cast 0 : u32) (cast 0 : u32))]
          [length : LinuxSockLen
            (LinuxSockLen (cast (comptime (size-of (type LinuxUcred))) : u32))]
          [credentials-ptr : (MutPtr u8)
            (unsafe
              (ptr-cast (ptr-addr-of credentials) : (MutPtr u8)))]
          [length-ptr : (MutPtr u8)
            (unsafe
              (ptr-cast (ptr-addr-of length) : (MutPtr u8)))]
          [result : i64
            (unsafe
              (host
                syscall-getsockopt
                fd
                sol-socket
                so-peercred
                (ptr-arg credentials-ptr)
                (ptr-arg length-ptr)
                0))]
          [seen : LinuxUcred
            (unsafe
              (ptr-read (ptr-cast credentials-ptr : (Ptr LinuxUcred))))]
          [seen-length : LinuxSockLen
            (unsafe
              (ptr-read (ptr-cast length-ptr : (Ptr LinuxSockLen))))]
          (begin
            (unsafe
              (lease-release! (token-slot handle)))
            (peer-step
              result
              (cast seen-length.value : i64)
              (cast seen.pid : i64)
              (cast seen.uid : i64)
              (cast seen.gid : i64))))])))

;: A data or readiness step and the poison it leaves on the slot.
(defstruct LinuxIoOutcome
  (step local_ipc.LocalIpcIoStep)
  (poison i64))

;: Classify one raw `read` (or, when `writing`, `sendto`) result for a request
;: of `requested` bytes. Progress is 1..`requested`; zero is EOF for a read and
;: corruption for a write. Any other count is corruption and poisons the slot.
(define (transfer-outcome [result : i64] [requested : i64] [writing : bool]) : LinuxIoOutcome
  (let
    [code : i64 (host-errno result)]
    (cond
      [(and (>= result 1) (<= result requested))
        (LinuxIoOutcome (local_ipc.LocalIpcIoStep.Progress result) poison-none)]
      [(and (= result 0) (not writing))
        (LinuxIoOutcome (local_ipc.LocalIpcIoStep.PeerClosed) poison-none)]
      [(= code eagain)
        (LinuxIoOutcome (local_ipc.LocalIpcIoStep.WouldBlock) poison-none)]
      [(= code eintr)
        (LinuxIoOutcome (local_ipc.LocalIpcIoStep.Interrupted) poison-none)]
      [(= code 0)
        (LinuxIoOutcome
          (local_ipc.LocalIpcIoStep.IoFailed (corrupt))
          poison-corrupt)]
      [else
        (LinuxIoOutcome
          (local_ipc.LocalIpcIoStep.IoFailed (connection-error code))
          (if (= code ebadf)
            poison-lost
            poison-none))])))

;: One nonblocking transfer between the leased descriptor and the live bytes
;: of `buffer`.
(define (transfer
  [handle : i64]
  [buffer : (&mut buffer byte_buf.ByteBuf)]
  [writing : bool]) : local_ipc.LocalIpcIoStep
  (let
    [requested : i64 buffer.len]
    (if (or (< requested 1) (not (buffer-sound? (& (deref buffer)))))
      (local_ipc.LocalIpcIoStep.IoFailed
        (local_ipc.make-error (local_ipc.LocalIpcErrorKind.InvalidRange) 0))
      (let
        [fd : i64
          (unsafe
            (lease-acquire handle))]
        (cond
          [(= fd lease-stale)
            (local_ipc.LocalIpcIoStep.IoFailed
              (local_ipc.make-error (local_ipc.LocalIpcErrorKind.Closed) 0))]
          [(= fd lease-poisoned) (local_ipc.LocalIpcIoStep.IoFailed (corrupt))]
          [else
            (let
              [data : i64
                (unsafe
                  (cast (ptr->int (__tl_array-data buffer.slots)) : i64))]
              [result : i64
                (if writing
                  (unsafe
                    (host syscall-sendto fd data requested msg-nosignal 0 0))
                  (unsafe
                    (host syscall-read fd data requested 0 0 0)))]
              [outcome : LinuxIoOutcome
                (transfer-outcome result requested writing)]
              (begin
                (unsafe
                  (slot-poison! (token-slot handle) outcome.poison))
                (unsafe
                  (lease-release! (token-slot handle)))
                outcome.step))])))))

;: Adapter `read-once`: `read` into the front of `buffer`.
(define (linux-read-once
  [_context : i64]
  [handle : i64]
  [buffer : byte_buf.ByteBuf]) : local_ipc.LocalIpcIoReply
  (let
    [step : local_ipc.LocalIpcIoStep (transfer handle (&mut buffer) false)]
    (local_ipc.LocalIpcIoReply step buffer)))

;: Adapter `write-once`: `sendto(MSG_NOSIGNAL)` of a prefix of `buffer`.
(define (linux-write-once
  [_context : i64]
  [handle : i64]
  [buffer : byte_buf.ByteBuf]) : local_ipc.LocalIpcIoReply
  (let
    [step : local_ipc.LocalIpcIoStep (transfer handle (&mut buffer) true)]
    (local_ipc.LocalIpcIoReply step buffer)))

;: Adapter `poll-pending`. Nothing is ever pending here, so this call is a
;: contract violation.
(define (linux-poll-pending
  [_context : i64]
  [_handle : i64]
  [buffer : byte_buf.ByteBuf]
  [_slice-ms : i64]) : local_ipc.LocalIpcIoReply
  (local_ipc.LocalIpcIoReply
    (local_ipc.LocalIpcIoStep.IoFailed (corrupt))
    buffer))

;: Adapter `cancel-pending`: nothing is ever pending.
(define (linux-cancel-pending [_context : i64] [_handle : i64]) : unit
  unit)

;: `slice-ms` clamped to 1..`local_ipc.wait-slice-ms`, so no host wait is
;: unbounded or zero.
(define (bounded-slice [slice-ms : i64]) : i64
  (cond
    [(< slice-ms 1) 1]
    [(> slice-ms local_ipc.wait-slice-ms) local_ipc.wait-slice-ms]
    [else slice-ms]))

;: A readiness step and the poison it leaves on the slot.
(defstruct LinuxWaitOutcome
  (step local_ipc.LocalIpcWaitStep)
  (poison i64))

;: Classify one `poll` of descriptor `fd` for `events`, given what the kernel
;: left in the `pollfd`. The kernel writes only `revents`, and only requested
;: events plus POLLERR, POLLHUP and POLLNVAL; anything else, a count other
;: than 0 or 1, or `revents` inconsistent with the count is corruption.
;: POLLNVAL means the descriptor is no longer open, so it is also lost.
(define (wait-outcome
  [result : i64]
  [fd : i64]
  [events : i64]
  [seen-fd : i64]
  [seen-events : i64]
  [revents : i64]) : LinuxWaitOutcome
  (let
    [known : i64 (bit-or events (bit-or pollerr (bit-or pollhup pollnval)))]
    [broken : LinuxWaitOutcome
      (LinuxWaitOutcome
        (local_ipc.LocalIpcWaitStep.WaitFailed (corrupt))
        poison-corrupt)]
    (cond
      [(or (not (= seen-fd fd)) (not (= seen-events events))) broken]
      [(= result 0)
        (if (= revents 0)
          (LinuxWaitOutcome (local_ipc.LocalIpcWaitStep.NotReady) poison-none)
          broken)]
      [(= result 1)
        (cond
          [(or (= revents 0) (not (= (bit-and revents (- 65535 known)) 0)))
            broken]
          [(not (= (bit-and revents pollnval) 0))
            (LinuxWaitOutcome
              (local_ipc.LocalIpcWaitStep.WaitFailed (corrupt))
              poison-lost)]
          [else
            (LinuxWaitOutcome (local_ipc.LocalIpcWaitStep.Ready) poison-none)])]
      [(= (host-errno result) eintr)
        (LinuxWaitOutcome
          (local_ipc.LocalIpcWaitStep.WaitInterrupted)
          poison-none)]
      [(= (host-errno result) 0) broken]
      [else
        (LinuxWaitOutcome
          (local_ipc.LocalIpcWaitStep.WaitFailed
            (connection-error (host-errno result)))
          poison-none)])))

;: Adapter `wait-ready`: one `poll` of the leased descriptor for at most one
;: bounded slice. Readable includes hang-up, so the next read returns queued
;: tail bytes before EOF; writable includes error and hang-up, so the next
;: write reports its exact error.
(define (linux-wait-ready
  [_context : i64]
  [handle : i64]
  [interest : i64]
  [slice-ms : i64]) : local_ipc.LocalIpcWaitStep
  (if (not
    (or
      (= interest local_ipc.interest-read)
      (= interest local_ipc.interest-write)))
    (local_ipc.LocalIpcWaitStep.WaitFailed
      (local_ipc.make-error (local_ipc.LocalIpcErrorKind.InvalidRange) 0))
    (let
      [fd : i64
        (unsafe
          (lease-acquire handle))]
      (cond
        [(= fd lease-stale)
          (local_ipc.LocalIpcWaitStep.WaitFailed
            (local_ipc.make-error (local_ipc.LocalIpcErrorKind.Closed) 0))]
        [(= fd lease-poisoned)
          (local_ipc.LocalIpcWaitStep.WaitFailed (corrupt))]
        [else
          (let
            [events : i64
              (if (= interest local_ipc.interest-read)
                pollin
                pollout)]
            [request : LinuxPollFd
              (LinuxPollFd (cast fd : i32) (cast events : i16) (cast 0 : i16))]
            [request-ptr : (MutPtr u8)
              (unsafe
                (ptr-cast (ptr-addr-of request) : (MutPtr u8)))]
            [result : i64
              (unsafe
                (host
                  syscall-poll
                  (ptr-arg request-ptr)
                  1
                  (bounded-slice slice-ms)
                  0
                  0
                  0))]
            [seen : LinuxPollFd
              (unsafe
                (ptr-read (ptr-cast request-ptr : (Ptr LinuxPollFd))))]
            [outcome : LinuxWaitOutcome
              (wait-outcome
                result
                fd
                events
                (cast seen.fd : i64)
                (bit-and (cast seen.events : i64) 65535)
                (bit-and (cast seen.revents : i64) 65535))]
            (begin
              (unsafe
                (slot-poison! (token-slot handle) outcome.poison))
              (unsafe
                (lease-release! (token-slot handle)))
              outcome.step))]))))

;: Adapter `delay`: `poll` with no descriptors for one bounded slice. It
;: returns 0 or EINTR; anything else is corruption.
(define (linux-delay [_context : i64] [ms : i64]) : local_ipc.LocalIpcStatus
  (let
    [result : i64
      (unsafe
        (host syscall-poll 0 0 (bounded-slice ms) 0 0 0))]
    (if (or (= result 0) (= (host-errno result) eintr))
      (local_ipc.LocalIpcStatus.Ok)
      (local_ipc.LocalIpcStatus.Err (corrupt)))))

;: Adapter `close`.
(define (linux-close [_context : i64] [handle : i64]) : local_ipc.LocalIpcStatus
  (unsafe
    (token-close! handle)))

;: Adapter `now-ms`: checked monotonic milliseconds, -1 when unavailable.
(define (linux-now-ms [_context : i64]) : i64
  (time.ms-or (time.monotonic-ms) -1))

;: The adapter for Unix-domain sockets whose pathname metadata passes
;: `policy`. Its connect function is a closure over the policy, allocated in
;: the active arena; keep the adapter inside that arena. Its context is unused.
(define (adapter [policy : LocalIpcLinuxPathPolicy]) : local_ipc.LocalIpcAdapter
  (let
    [owner : i64 policy.owner-id]
    [group : i64 policy.group-id]
    [forbidden : i64 policy.forbidden-mode]
    (local_ipc.LocalIpcAdapter
      0
      linux-now-ms
      (lambda ([_context : i64] [family : i64] [name : byte_buf.ByteBuf]) : local_ipc.LocalIpcConnectReply
        (connect-attempt
          (LocalIpcLinuxPathPolicy owner group forbidden)
          family
          name))
      linux-peer
      linux-read-once
      linux-write-once
      linux-poll-pending
      linux-cancel-pending
      linux-wait-ready
      linux-delay
      linux-close)))

;; Syscall injection for `typelisp test`, absent from every other build. Each
;; syscall number counts its calls. A scripted row replaces the `call`-th call
;; of `number` (1-based, since the last reset) with `result`, after writing up
;; to four output fields into that call's native storage; -1 leaves a field.
;; The fields are newfstatat mode/uid/gid, getsockopt length/pid/uid/gid and
;; poll fd/events/revents.
;: Syscall numbers the call counters cover.
(cfg
  test
  (define test-number-limit : i64
    300))

;: Scripted rows one test can hold.
(cfg
  test
  (define test-row-capacity : i64
    8))

;: Words per scripted row: number, call, result, four outputs, used.
(cfg
  test
  (define test-row-words : i64
    8))

;: Calls per syscall number.
(cfg
  test
  (define test-calls : (__tl_dyn-array i64)
    (__tl_make-array i64 test-number-limit)))

;: Scripted rows.
(cfg
  test
  (define test-rows : (__tl_dyn-array i64)
    (__tl_make-array i64 (* test-row-capacity test-row-words))))

;: Clear every counter and scripted row.
(cfg
  test
  (define (test-reset!) : unit
    (let
      [index : i64 0]
      (begin
        (while (< index test-number-limit)
          (begin
            (set! (array-ref test-calls index) 0)
            (set! index (+ index 1))))
        (set! index 0)
        (while (< index (* test-row-capacity test-row-words))
          (begin
            (set! (array-ref test-rows index) 0)
            (set! index (+ index 1))))))))

;: Calls of syscall `number` since the last reset.
(cfg
  test
  (define (test-call-count [number : i64]) : i64
    (array-ref test-calls number)))

;: Script the `call`-th call of `number`. A full script traps.
(cfg
  test
  (define (test-script!
    [number : i64]
    [call : i64]
    [result : i64]
    [out0 : i64]
    [out1 : i64]
    [out2 : i64]
    [out3 : i64]) : unit
    (let
      [row : i64 0]
      [placed : bool false]
      (begin
        (while (and (not placed) (< row test-row-capacity))
          (let
            [base : i64 (* row test-row-words)]
            (begin
              (if (= (array-ref test-rows (+ base 1)) 0)
                (begin
                  (set! (array-ref test-rows base) number)
                  (set! (array-ref test-rows (+ base 1)) call)
                  (set! (array-ref test-rows (+ base 2)) result)
                  (set! (array-ref test-rows (+ base 3)) out0)
                  (set! (array-ref test-rows (+ base 4)) out1)
                  (set! (array-ref test-rows (+ base 5)) out2)
                  (set! (array-ref test-rows (+ base 6)) out3)
                  (set! placed true))
                unit)
              (set! row (+ row 1)))))
        (if placed
          unit
          (begin
            (/ 1 0)
            unit))))))

;: Script only a result.
(cfg
  test
  (define (test-inject! [number : i64] [call : i64] [result : i64]) : unit
    (test-script! number call result -1 -1 -1 -1)))

;: Write `value` as a u32 at `offset` bytes past `address`, unless it is -1.
(cfg
  test
  (unsafe
    (define (test-put-u32! [address : i64] [offset : i64] [value : i64]) : unit
      (if (= value -1)
        unit
        (unsafe
          (ptr-write!
            (int->ptr (cast (+ address offset) : u64) : (MutPtr u32))
            (cast value : u32)))))))

;: Write `value` as an i16 at `offset` bytes past `address`, unless it is -1.
(cfg
  test
  (unsafe
    (define (test-put-i16! [address : i64] [offset : i64] [value : i64]) : unit
      (if (= value -1)
        unit
        (unsafe
          (ptr-write!
            (int->ptr (cast (+ address offset) : u64) : (MutPtr i16))
            (cast value : i16)))))))

;: Write a scripted row's outputs into the native storage of its call.
(cfg
  test
  (unsafe
    (define (test-write-outputs!
      [number : i64]
      [a : i64]
      [c : i64]
      [d : i64]
      [e : i64]
      [base : i64]) : unit
      (let
        [out0 : i64 (array-ref test-rows (+ base 3))]
        [out1 : i64 (array-ref test-rows (+ base 4))]
        [out2 : i64 (array-ref test-rows (+ base 5))]
        [out3 : i64 (array-ref test-rows (+ base 6))]
        (cond
          [(= number syscall-newfstatat)
            (begin
              (unsafe
                (test-put-u32! c stat-mode-offset out0))
              (unsafe
                (test-put-u32! c stat-uid-offset out1))
              (unsafe
                (test-put-u32! c stat-gid-offset out2)))]
          [(= number syscall-getsockopt)
            (begin
              (unsafe
                (test-put-u32! e 0 out0))
              (unsafe
                (test-put-u32! d 0 out1))
              (unsafe
                (test-put-u32! d 4 out2))
              (unsafe
                (test-put-u32! d 8 out3)))]
          [(and (= number syscall-poll) (not (= a 0)))
            (begin
              (unsafe
                (test-put-u32! a 0 out0))
              (unsafe
                (test-put-i16! a 4 out1))
              (unsafe
                (test-put-i16! a 6 out2)))]
          [else unit])))))

;: `host` under `typelisp test`.
(cfg
  test
  (unsafe
    (define (test-host
      [number : i64]
      [a : i64]
      [b : i64]
      [c : i64]
      [d : i64]
      [e : i64]
      [f : i64]) : i64
      (let
        [call : i64 (+ (array-ref test-calls number) 1)]
        [row : i64 0]
        [scripted : i64 -1]
        (begin
          (set! (array-ref test-calls number) call)
          (while (and (< scripted 0) (< row test-row-capacity))
            (let
              [base : i64 (* row test-row-words)]
              (begin
                (if (and
                  (= (array-ref test-rows base) number)
                  (= (array-ref test-rows (+ base 1)) call)
                  (= (array-ref test-rows (+ base 7)) 0))
                  (begin
                    (set! (array-ref test-rows (+ base 7)) 1)
                    (set! scripted base))
                  unit)
                (set! row (+ row 1)))))
          (if (< scripted 0)
            (unsafe
              (host-raw number a b c d e f))
            (begin
              (unsafe
                (test-write-outputs! number a c d e scripted))
              (array-ref test-rows (+ scripted 2)))))))))