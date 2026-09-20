;# Bounded client byte streams over one explicitly selected local endpoint.
;#
;# This internal substrate connects a client to a filesystem Unix-domain socket
;# or a local Windows named pipe through an injected adapter. It performs no OS
;# calls itself, reads no environment, probes no endpoints and exposes no server
;# surface. Platform adapters and the conformance fake implement
;# `LocalIpcAdapter`; everything a caller can observe is defined here, so both
;# platforms and the fake share one contract.
;#
;# Every operation makes finite progress. Primitive reads and writes make one
;# adapter attempt. Wait-capable helpers take an absolute monotonic deadline in
;# milliseconds, a `(-> bool)` cancellation probe and a work budget, wait in
;# slices of at most 100 ms, and never issue an unbounded host wait.
;#
;# Stable results never carry endpoint text, transferred bytes, native handles
;# or host strings: an error is a kind plus a bounded numeric host code.
;#
;# `connect` allocates one private state cell in the active arena; keep the
;# connection inside the arena that was active when it was created. No other
;# operation allocates. A connection is cleanup-owning, so bind it with `with`.
;#
;# ```lisp test=run name=local-ipc-endpoints exit=42 stdout=""
;# (import stdlib.local_ipc)
;#
;# (define (main) : i64
;#   (if (and
;#     (local_ipc.unix-path-valid? "/run/user/1000/agent.sock")
;#     (not (local_ipc.unix-path-valid? "agent.sock"))
;#     (local_ipc.windows-pipe-valid? "\\\\.\\pipe\\agent")
;#     (not (local_ipc.windows-pipe-valid? "\\\\fileserver\\pipe\\agent")))
;#     42
;#     1))
;# ```
(import stdlib.byte_buf)
(import stdlib.string)

;: Longest accepted Unix socket path in bytes (`sun_path` minus its NUL).
(define unix-path-max : i64
  107)

;: Longest accepted Windows pipe name in bytes, including the `\\.\pipe\` prefix.
(define windows-pipe-name-max : i64
  256)

;: Longest single host wait or retry delay in milliseconds.
(define wait-slice-ms : i64
  100)

;: Largest host code retained in an error; larger or negative codes become 0.
(define host-code-max : i64
  65535)

;: Largest peer identity value an adapter may report; -1 means unavailable.
(define peer-id-max : i64
  4294967295)

;: Pending-operation drain slices before the connection is force-closed.
(define pending-drain-slices : i64
  600)

;: Stable failure categories. They never depend on endpoint text or payload.
(defenum LocalIpcErrorKind
  (InvalidEndpoint)
  (Unavailable)
  (PermissionDenied)
  (Busy)
  (TimedOut)
  (Canceled)
  (PeerClosed)
  (ResourceExhausted)
  (UnsupportedTarget)
  (AdapterCorrupt)
  (Closed)
  (InvalidRange)
  (WorkExhausted)
  (PolicyRejected)
  (HostFailure))

;: One failure: a stable kind and a host code bounded to `0..host-code-max`.
(defstruct LocalIpcError
  (kind LocalIpcErrorKind)
  (host-code i64))

;: Build an error, discarding host codes outside the bounded range.
(define (make-error [kind : LocalIpcErrorKind] [host-code : i64]) : LocalIpcError
  (LocalIpcError
    kind
    (if (and (>= host-code 0) (<= host-code host-code-max))
      host-code
      0)))

;: Stable small integer for an error kind, for logs and conformance traces.
(define (error-kind-code [kind : LocalIpcErrorKind]) : i64
  (match kind
    [(LocalIpcErrorKind.InvalidEndpoint) 1]
    [(LocalIpcErrorKind.Unavailable) 2]
    [(LocalIpcErrorKind.PermissionDenied) 3]
    [(LocalIpcErrorKind.Busy) 4]
    [(LocalIpcErrorKind.TimedOut) 5]
    [(LocalIpcErrorKind.Canceled) 6]
    [(LocalIpcErrorKind.PeerClosed) 7]
    [(LocalIpcErrorKind.ResourceExhausted) 8]
    [(LocalIpcErrorKind.UnsupportedTarget) 9]
    [(LocalIpcErrorKind.AdapterCorrupt) 10]
    [(LocalIpcErrorKind.Closed) 11]
    [(LocalIpcErrorKind.InvalidRange) 12]
    [(LocalIpcErrorKind.WorkExhausted) 13]
    [(LocalIpcErrorKind.PolicyRejected) 14]
    [(LocalIpcErrorKind.HostFailure) 15]))

;: Stable text for an error kind. It names the category only.
(define (error-kind-name [kind : LocalIpcErrorKind]) : String
  (match kind
    [(LocalIpcErrorKind.InvalidEndpoint) "invalid-endpoint"]
    [(LocalIpcErrorKind.Unavailable) "unavailable"]
    [(LocalIpcErrorKind.PermissionDenied) "permission-denied"]
    [(LocalIpcErrorKind.Busy) "busy"]
    [(LocalIpcErrorKind.TimedOut) "timed-out"]
    [(LocalIpcErrorKind.Canceled) "canceled"]
    [(LocalIpcErrorKind.PeerClosed) "peer-closed"]
    [(LocalIpcErrorKind.ResourceExhausted) "resource-exhausted"]
    [(LocalIpcErrorKind.UnsupportedTarget) "unsupported-target"]
    [(LocalIpcErrorKind.AdapterCorrupt) "adapter-corrupt"]
    [(LocalIpcErrorKind.Closed) "closed"]
    [(LocalIpcErrorKind.InvalidRange) "invalid-range"]
    [(LocalIpcErrorKind.WorkExhausted) "work-exhausted"]
    [(LocalIpcErrorKind.PolicyRejected) "policy-rejected"]
    [(LocalIpcErrorKind.HostFailure) "host-failure"]))

;: Success or one failure.
(defenum LocalIpcStatus
  (Ok)
  (Err LocalIpcError))

;: Return true exactly for `LocalIpcStatus.Ok`.
(define (status-ok? [status : LocalIpcStatus]) : bool
  (match status
    [(LocalIpcStatus.Ok) true]
    [(LocalIpcStatus.Err _) false]))

;: Error kind code of a status, or 0 for success.
(define (status-kind-code [status : LocalIpcStatus]) : i64
  (match status
    [(LocalIpcStatus.Ok) 0]
    [(LocalIpcStatus.Err failure) (error-kind-code failure.kind)]))

;: The two explicit endpoint families. There is no default and no lookup.
(defenum LocalIpcEndpoint
  (UnixPath String)
  (WindowsPipe String))

;: Adapter family number for a Unix socket path.
(define family-unix-path : i64
  0)

;: Adapter family number for a Windows named pipe.
(define family-windows-pipe : i64
  1)

;: True when `text` holds a NUL byte.
(define (text-has-nul? [text : (& text str)]) : bool
  (let
    [length : i64 (string.string-length text)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index length))
        (begin
          (set! found (= (cast (string.string-ref text index) : i64) 0))
          (set! index (+ index 1))))
      found)))

;: A Unix endpoint is an absolute filesystem path of 1..`unix-path-max` bytes
;: without NUL. A leading NUL (the abstract namespace) is therefore rejected.
(define (unix-path-valid? [path : (& path str)]) : bool
  (let
    [length : i64 (string.string-length path)]
    (and
      (> length 0)
      (<= length unix-path-max)
      (= (cast (string.string-ref path 0) : i64) 47)
      (not (text-has-nul? path)))))

;: True when byte `index` of `text` equals `lower` ignoring ASCII case.
(define (text-byte-is-letter? [text : (& text str)] [index : i64] [lower : i64]) : bool
  (let
    [value : i64 (cast (string.string-ref text index) : i64)]
    (or (= value lower) (= value (- lower 32)))))

;: A Windows endpoint is `\\.\pipe\<name>`: the server is the local machine
;: `.`, `<name>` is non-empty and holds no backslash or NUL, and the whole text
;: is at most `windows-pipe-name-max` bytes. Remote server names are rejected.
(define (windows-pipe-valid? [name : (& name str)]) : bool
  (let
    [length : i64 (string.string-length name)]
    (if (or (< length 10) (> length windows-pipe-name-max))
      false
      (let
        [index : i64 9]
        [ok : bool
          (and
            (= (cast (string.string-ref name 0) : i64) 92)
            (= (cast (string.string-ref name 1) : i64) 92)
            (= (cast (string.string-ref name 2) : i64) 46)
            (= (cast (string.string-ref name 3) : i64) 92)
            (text-byte-is-letter? name 4 112)
            (text-byte-is-letter? name 5 105)
            (text-byte-is-letter? name 6 112)
            (text-byte-is-letter? name 7 101)
            (= (cast (string.string-ref name 8) : i64) 92))]
        (begin
          (while (and ok (< index length))
            (let
              [value : i64 (cast (string.string-ref name index) : i64)]
              (begin
                (set! ok (and (not (= value 92)) (not (= value 0))))
                (set! index (+ index 1)))))
          ok)))))

;: Validate an endpoint however it was constructed. `connect` always calls this
;: before the adapter is reached.
(define (endpoint-valid? [endpoint : (& endpoint LocalIpcEndpoint)]) : bool
  (match endpoint
    [(LocalIpcEndpoint.UnixPath path) (unix-path-valid? path)]
    [(LocalIpcEndpoint.WindowsPipe name) (windows-pipe-valid? name)]))

;: Peer facts reported by the platform. Each is -1 when unavailable. They are
;: untrusted policy inputs, never authentication claims.
(defstruct LocalIpcPeer
  (process-id i64)
  (user-id i64)
  (group-id i64)
  (session-id i64))

;: A peer value with every fact unavailable.
(define (peer-unknown) : LocalIpcPeer
  (LocalIpcPeer -1 -1 -1 -1))

;: True when one peer fact is -1 or within `0..peer-id-max`.
(define (peer-fact-valid? [value : i64]) : bool
  (and (>= value -1) (<= value peer-id-max)))

;: True when every peer fact is bounded.
(define (peer-valid? [peer : LocalIpcPeer]) : bool
  (and
    (peer-fact-valid? peer.process-id)
    (peer-fact-valid? peer.user-id)
    (peer-fact-valid? peer.group-id)
    (peer-fact-valid? peer.session-id)))

;: A policy that accepts every peer.
(define (accept-any-peer [_peer : LocalIpcPeer]) : bool
  true)

;: A cancellation probe for callers without cancellation state.
(define (never-canceled) : bool
  false)

;: One adapter connect attempt. `RetryConnect` means no connection exists and
;: the adapter holds no native resource from this attempt: it destroyed the
;: construction handle (full backlog, busy pipe, interrupted connect).
(defenum LocalIpcConnectStep
  (Connected i64)
  (RetryConnect)
  (ConnectFailed LocalIpcError))

;: Peer facts for a connected handle.
(defenum LocalIpcPeerStep
  (PeerKnown LocalIpcPeer)
  (PeerFailed LocalIpcError))

;: One adapter data attempt. `Pending` means the adapter issued an operation
;: that still owns the caller's buffer until `poll-pending` reports a terminal
;: step for it.
(defenum LocalIpcIoStep
  (Progress i64)
  (WouldBlock)
  (Interrupted)
  (PeerClosed)
  (Pending)
  (IoFailed LocalIpcError))

;: One bounded readiness wait.
(defenum LocalIpcWaitStep
  (Ready)
  (NotReady)
  (WaitInterrupted)
  (WaitFailed LocalIpcError))

;: Readiness interest for reads.
(define interest-read : i64
  0)

;: Readiness interest for writes.
(define interest-write : i64
  1)

;: The injected capability. Every function receives `context` first. Handles
;: are adapter-chosen non-negative integers; names and buffers cross as an
;: address and a byte count that this module has already validated.
;:
;: - `now-ms context`: monotonic milliseconds, negative when unavailable.
;: - `connect-attempt context family name-addr name-len`
;: - `peer context handle`
;: - `read-once` / `write-once context handle addr len`: one host attempt.
;: - `poll-pending context handle slice-ms`: wait at most `slice-ms` for the
;:   operation that returned `Pending`; `Pending` again means still running.
;: - `cancel-pending context handle`: request cancellation. It is not
;:   completion: the operation still owns its buffer until a terminal poll.
;: - `wait-ready context handle interest slice-ms`
;: - `delay context ms`: one bounded pause between connect attempts.
;: - `close context handle`: called exactly once per published handle.
(defstruct LocalIpcAdapter
  (context i64)
  (now-ms (-> i64 i64))
  (connect-attempt (-> i64 i64 i64 i64 LocalIpcConnectStep))
  (peer (-> i64 i64 LocalIpcPeerStep))
  (read-once (-> i64 i64 i64 i64 LocalIpcIoStep))
  (write-once (-> i64 i64 i64 i64 LocalIpcIoStep))
  (poll-pending (-> i64 i64 i64 LocalIpcIoStep))
  (cancel-pending (-> i64 i64 unit))
  (wait-ready (-> i64 i64 i64 i64 LocalIpcWaitStep))
  (delay (-> i64 i64 unit))
  (close (-> i64 i64 LocalIpcStatus)))

;: Private connection state. `handle` is -1 once closed or never connected;
;: `result` is the construction outcome and `closed` the explicit close result.
(defstruct LocalIpcConnectionState
  (handle i64)
  (adapter LocalIpcAdapter)
  (peer LocalIpcPeer)
  (result LocalIpcStatus)
  (closed LocalIpcStatus))

;: Allocate private state. Safe code cannot forge the pointer it returns.
(unsafe
  (define (state-new
    [handle : i64]
    [adapter : LocalIpcAdapter]
    [peer : LocalIpcPeer]
    [result : LocalIpcStatus]) : (MutPtr LocalIpcConnectionState)
    ;; The state holds function values, which have no zero initializer, so the
    ;; cell is raw 8-byte-aligned storage that is written before it is read.
    (let
      [words : (__tl_dyn-array u64)
        (__tl_make-array
          u64
          (/ (+ (comptime (size-of (type LocalIpcConnectionState))) 7) 8))]
      [state : (MutPtr LocalIpcConnectionState)
        (unsafe
          (ptr-cast (__tl_array-data words) : (MutPtr LocalIpcConnectionState)))]
      (begin
        (unsafe
          (ptr-write!
            state
            (LocalIpcConnectionState
              handle
              adapter
              peer
              result
              (LocalIpcStatus.Err (make-error (LocalIpcErrorKind.Closed) 0)))))
        state))))

;: Close one state exactly once. The handle is poisoned before the adapter is
;: called, so a second close, and lexical cleanup after an explicit close, find
;: nothing to do.
(unsafe
  (define (state-close [state : (MutPtr LocalIpcConnectionState)]) : LocalIpcStatus
    (if (ptr-null? state)
      (LocalIpcStatus.Err (make-error (LocalIpcErrorKind.Closed) 0))
      (let
        [current : LocalIpcConnectionState
          (unsafe
            (ptr-read state))]
        ;; Scalars are copied out before the cell is poisoned: a memory-class
        ;; `ptr-read` result still shares storage with its pointee (#7900), so
        ;; `current.handle` read after the write below would already be -1.
        [handle : i64 current.handle]
        [context : i64 current.adapter.context]
        [close-handle : (-> i64 i64 LocalIpcStatus) current.adapter.close]
        (if (< handle 0)
          (LocalIpcStatus.Err (make-error (LocalIpcErrorKind.Closed) 0))
          (begin
            (unsafe
              (ptr-write!
                state
                (LocalIpcConnectionState
                  -1
                  current.adapter
                  current.peer
                  current.result
                  current.closed)))
            (let
              [outcome : LocalIpcStatus (close-handle context handle)]
              (begin
                (unsafe
                  (ptr-write!
                    state
                    (LocalIpcConnectionState
                      -1
                      current.adapter
                      current.peer
                      current.result
                      outcome)))
                outcome))))))))

;: Cleanup-field adapter: lexical cleanup is idempotent and reports nothing.
(define (state-cleanup [state : (MutPtr LocalIpcConnectionState)]) : unit
  (begin
    (unsafe
      (state-close state))
    unit))

;: Move-only, cleanup-owning client connection. One operation at a time: every
;: operation takes `&mut`. It cannot be cloned.
(defstruct LocalIpcConnection
  (:cleanup cleanup-local-ipc-connection)
  (state (MutPtr LocalIpcConnectionState) (:cleanup state-cleanup)))

;: Snapshot private state; a null pointer reads as closed.
(unsafe
  (define (state-read
    [state : (MutPtr LocalIpcConnectionState)]
    [fallback : LocalIpcAdapter]) : LocalIpcConnectionState
    (if (ptr-null? state)
      (LocalIpcConnectionState
        -1
        fallback
        (peer-unknown)
        (LocalIpcStatus.Err (make-error (LocalIpcErrorKind.Closed) 0))
        (LocalIpcStatus.Err (make-error (LocalIpcErrorKind.Closed) 0)))
      (unsafe
        (ptr-read state)))))

;: Construction outcome: `Ok` for a usable connection, otherwise why `connect`
;: failed. It does not change when the connection is closed later.
(define (connection-result [connection : (& connection LocalIpcConnection)]) : LocalIpcStatus
  (if (ptr-null? connection.state)
    (LocalIpcStatus.Err (make-error (LocalIpcErrorKind.Closed) 0))
    (let
      [current : LocalIpcConnectionState
        (unsafe
          (ptr-read connection.state))]
      current.result)))

;: True while the connection holds an open handle.
(define (connection-open? [connection : (& connection LocalIpcConnection)]) : bool
  (if (ptr-null? connection.state)
    false
    (let
      [current : LocalIpcConnectionState
        (unsafe
          (ptr-read connection.state))]
      (>= current.handle 0))))

;: Peer facts captured at connect time, or all -1 for a failed connection.
(define (connection-peer [connection : (& connection LocalIpcConnection)]) : LocalIpcPeer
  (if (ptr-null? connection.state)
    (peer-unknown)
    (let
      [current : LocalIpcConnectionState
        (unsafe
          (ptr-read connection.state))]
      current.peer)))

;: Close explicitly. The handle is poisoned, the adapter's close runs exactly
;: once and its result is returned. Closing again reports `Closed`.
(define (close! [connection : (&mut connection LocalIpcConnection)]) : LocalIpcStatus
  (unsafe
    (state-close connection.state)))

;: A failed connection: no handle, `failure` as its construction result.
(define (failed-connection
  [adapter : LocalIpcAdapter]
  [failure : LocalIpcError]) : LocalIpcConnection
  (LocalIpcConnection
    (unsafe
      (state-new -1 adapter (peer-unknown) (LocalIpcStatus.Err failure)))))

;: Why a wait-capable helper must stop before another host attempt, checked in
;: the contract's precedence order: cancellation, then an expired or
;: unavailable deadline, then the work budget.
(define (stop-reason
  [adapter : (& adapter LocalIpcAdapter)]
  [deadline-ms : i64]
  [cancel-check : (-> bool)]
  [work-left : i64]) : LocalIpcStatus
  (if (cancel-check)
    (LocalIpcStatus.Err (make-error (LocalIpcErrorKind.Canceled) 0))
    (let
      [now : i64 (adapter.now-ms adapter.context)]
      (cond
        [(< now 0)
          (LocalIpcStatus.Err
            (make-error (LocalIpcErrorKind.UnsupportedTarget) 0))]
        [(>= now deadline-ms)
          (LocalIpcStatus.Err (make-error (LocalIpcErrorKind.TimedOut) 0))]
        [(<= work-left 0)
          (LocalIpcStatus.Err (make-error (LocalIpcErrorKind.WorkExhausted) 0))]
        [else (LocalIpcStatus.Ok)]))))

;: The next wait slice: the time left to the deadline, at most `wait-slice-ms`
;: and at least 1. Recomputed from the clock after every wake.
(define (next-slice-ms
  [adapter : (& adapter LocalIpcAdapter)]
  [deadline-ms : i64]) : i64
  (let
    [left : i64 (- deadline-ms (adapter.now-ms adapter.context))]
    (cond [(< left 1) 1] [(> left wait-slice-ms) wait-slice-ms] [else left])))

;: Connect to `endpoint`. The endpoint is validated first; an invalid one never
;: reaches the adapter. Each attempt consumes one unit of `work-budget`. After
;: `RetryConnect` the helper re-checks cancellation, deadline and budget, pauses
;: for one bounded slice and makes a fresh attempt. A connected handle is
;: published only after its bounded peer facts pass `policy`; otherwise it is
;: closed exactly once and the connection reports the failure.
;:
;: The result is always a connection value. Inspect `connection-result`.
(define (connect
  [adapter : LocalIpcAdapter]
  [endpoint : (& endpoint LocalIpcEndpoint)]
  [policy : (-> LocalIpcPeer bool)]
  [deadline-ms : i64]
  [cancel-check : (-> bool)]
  [work-budget : i64]) : LocalIpcConnection
  (if (not (endpoint-valid? endpoint))
    (failed-connection
      adapter
      (make-error (LocalIpcErrorKind.InvalidEndpoint) 0))
    (let
      [family : i64
        (match endpoint
          [(LocalIpcEndpoint.UnixPath _) family-unix-path]
          [(LocalIpcEndpoint.WindowsPipe _) family-windows-pipe])]
      [name : (& endpoint str)
        (match endpoint
          [(LocalIpcEndpoint.UnixPath path) path]
          [(LocalIpcEndpoint.WindowsPipe pipe) pipe])]
      [name-bytes : (& endpoint bytes) (byte_buf.str-as-bytes name)]
      [name-addr : i64
        (unsafe
          (cast (ptr->int (byte_buf.bytes-data name-bytes)) : i64))]
      [name-len : i64 (byte_buf.bytes-length name-bytes)]
      [work-left : i64 work-budget]
      [handle : i64 -1]
      [outcome : LocalIpcStatus (LocalIpcStatus.Ok)]
      [running : bool true]
      (begin
        (while running
          (let
            [stop : LocalIpcStatus
              (stop-reason (& adapter) deadline-ms cancel-check work-left)]
            (if (not (status-ok? stop))
              (begin
                (set! outcome stop)
                (set! running false))
              (begin
                (set! work-left (- work-left 1))
                (match (adapter.connect-attempt
                  adapter.context
                  family
                  name-addr
                  name-len)
                  [(LocalIpcConnectStep.Connected connected)
                    (begin
                      (if (< connected 0)
                        (set!
                          outcome
                          (LocalIpcStatus.Err
                            (make-error (LocalIpcErrorKind.AdapterCorrupt) 0)))
                        (set! handle connected))
                      (set! running false))]
                  [(LocalIpcConnectStep.RetryConnect)
                    (let
                      [again : LocalIpcStatus
                        (stop-reason
                          (& adapter)
                          deadline-ms
                          cancel-check
                          work-left)]
                      (if (status-ok? again)
                        (adapter.delay
                          adapter.context
                          (next-slice-ms (& adapter) deadline-ms))
                        (begin
                          (set! outcome again)
                          (set! running false))))]
                  [(LocalIpcConnectStep.ConnectFailed failure)
                    (begin
                      (set! outcome (LocalIpcStatus.Err failure))
                      (set! running false))])))))
        (if (< handle 0)
          (failed-connection
            adapter
            (match outcome
              [(LocalIpcStatus.Err failure) failure]
              [(LocalIpcStatus.Ok)
                (make-error (LocalIpcErrorKind.AdapterCorrupt) 0)]))
          (match (adapter.peer adapter.context handle)
            [(LocalIpcPeerStep.PeerFailed failure)
              (begin
                (adapter.close adapter.context handle)
                (failed-connection adapter failure))]
            [(LocalIpcPeerStep.PeerKnown peer)
              (cond
                [(not (peer-valid? peer))
                  (begin
                    (adapter.close adapter.context handle)
                    (failed-connection
                      adapter
                      (make-error (LocalIpcErrorKind.AdapterCorrupt) 0)))]
                [(not (policy peer))
                  (begin
                    (adapter.close adapter.context handle)
                    (failed-connection
                      adapter
                      (make-error (LocalIpcErrorKind.PolicyRejected) 0)))]
                [else
                  (LocalIpcConnection
                    (unsafe
                      (state-new handle adapter peer (LocalIpcStatus.Ok))))])]))))))

;: Result of one primitive read or write. `Done n` has `n >= 1`, except that a
;: zero-length view yields `Done 0` without a host call.
(defenum LocalIpcIoResult
  (Done i64)
  (WouldBlock)
  (Interrupted)
  (Eof)
  (Failed LocalIpcError))

;: Turn one terminal adapter step into a result. A count outside `1..requested`
;: is adapter corruption, never progress.
(define (io-result-from-step [step : LocalIpcIoStep] [requested : i64]) : LocalIpcIoResult
  (match step
    [(LocalIpcIoStep.Progress count)
      (if (and (>= count 1) (<= count requested))
        (LocalIpcIoResult.Done count)
        (LocalIpcIoResult.Failed
          (make-error (LocalIpcErrorKind.AdapterCorrupt) 0)))]
    [(LocalIpcIoStep.WouldBlock) (LocalIpcIoResult.WouldBlock)]
    [(LocalIpcIoStep.Interrupted) (LocalIpcIoResult.Interrupted)]
    [(LocalIpcIoStep.PeerClosed) (LocalIpcIoResult.Eof)]
    [(LocalIpcIoStep.Pending)
      (LocalIpcIoResult.Failed
        (make-error (LocalIpcErrorKind.AdapterCorrupt) 0))]
    [(LocalIpcIoStep.IoFailed failure) (LocalIpcIoResult.Failed failure)]))

;: Drain an operation the adapter reported `Pending` until it is terminal. The
;: buffer belongs to that operation until then, so this never returns early:
;: `cancel-first` requests cancellation (which is not completion), and each
;: poll waits one bounded slice. Positive progress that wins the race is kept.
;: If the adapter never completes within `pending-drain-slices` the connection
;: is closed, which ends the operation, and the adapter is reported corrupt.
(define (drain-pending
  [connection : (&mut connection LocalIpcConnection)]
  [adapter : (& adapter LocalIpcAdapter)]
  [handle : i64]
  [requested : i64]
  [cancel-first : bool]) : LocalIpcIoResult
  (let
    [slices : i64 0]
    [step : LocalIpcIoStep (LocalIpcIoStep.Pending)]
    [pending : bool true]
    (begin
      (if cancel-first
        (adapter.cancel-pending adapter.context handle)
        unit)
      (while (and pending (< slices pending-drain-slices))
        (begin
          (set!
            step
            (adapter.poll-pending adapter.context handle wait-slice-ms))
          (set! slices (+ slices 1))
          (set!
            pending
            (match step
              [(LocalIpcIoStep.Pending) true]
              [_ false]))))
      (if pending
        (begin
          (close! connection)
          (LocalIpcIoResult.Failed
            (make-error (LocalIpcErrorKind.AdapterCorrupt) 0)))
        (io-result-from-step step requested)))))

;: One raw adapter attempt on an open connection and a non-empty range.
(define (io-attempt
  [current : (& current LocalIpcConnectionState)]
  [writing : bool]
  [addr : i64]
  [length : i64]) : LocalIpcIoStep
  (if writing
    (current.adapter.write-once
      current.adapter.context
      current.handle
      addr
      length)
    (current.adapter.read-once
      current.adapter.context
      current.handle
      addr
      length)))

;: One primitive attempt on an address range that is already validated. A
;: primitive makes exactly one attempt, so an operation the adapter leaves
;: pending is canceled at once and drained to its terminal completion.
(define (io-once
  [connection : (&mut connection LocalIpcConnection)]
  [writing : bool]
  [addr : i64]
  [length : i64]) : LocalIpcIoResult
  (if (ptr-null? connection.state)
    (LocalIpcIoResult.Failed (make-error (LocalIpcErrorKind.Closed) 0))
    (let
      [current : LocalIpcConnectionState
        (unsafe
          (ptr-read connection.state))]
      (cond
        [(< current.handle 0)
          (LocalIpcIoResult.Failed (make-error (LocalIpcErrorKind.Closed) 0))]
        [(= length 0) (LocalIpcIoResult.Done 0)]
        [else
          (let
            [step : LocalIpcIoStep (io-attempt (& current) writing addr length)]
            (match step
              [(LocalIpcIoStep.Pending)
                (drain-pending
                  connection
                  (& current.adapter)
                  current.handle
                  length
                  true)]
              [_ (io-result-from-step step length)]))]))))

;: True when `start..start+count` lies inside a view of `length` bytes.
(define (range-valid? [length : i64] [start : i64] [count : i64]) : bool
  (and (>= start 0) (>= count 0) (<= start length) (<= count (- length start))))

;: Read once into `view[start..start+count]`. An invalid range, a closed
;: connection and a zero count are decided without a host call.
(define (read-some!
  [connection : (&mut connection LocalIpcConnection)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]) : LocalIpcIoResult
  (if (not (range-valid? (byte_buf.bytes-mut-length view) start count))
    (LocalIpcIoResult.Failed (make-error (LocalIpcErrorKind.InvalidRange) 0))
    (io-once
      connection
      false
      (+
        (unsafe
          (cast (ptr->int (byte_buf.bytes-mut-data view)) : i64))
        start)
      count)))

;: Write once from `view[start..start+count]`, with the same pre-dispatch checks
;: as `read-some!`.
(define (write-some!
  [connection : (&mut connection LocalIpcConnection)]
  [view : (& view bytes)]
  [start : i64]
  [count : i64]) : LocalIpcIoResult
  (if (not (range-valid? (byte_buf.bytes-length view) start count))
    (LocalIpcIoResult.Failed (make-error (LocalIpcErrorKind.InvalidRange) 0))
    (io-once
      connection
      true
      (+
        (unsafe
          (cast (ptr->int (byte_buf.bytes-data view)) : i64))
        start)
      count)))

;: Bytes completed by a whole-buffer helper and why it stopped. `status` is
;: `Ok` only when every requested byte was transferred.
(defstruct LocalIpcTransfer
  (count i64)
  (status LocalIpcStatus))

;: A wait-capable result together with the work budget it left unused.
(defstruct LocalIpcWaitOutcome
  (result LocalIpcIoResult)
  (work-left i64))

;: Wait for an operation the adapter reported `Pending`. While cancellation,
;: deadline and budget allow, it polls in bounded slices, each consuming one
;: unit of work. When a stop reason appears it issues no new data operation: it
;: requests cancellation and drains to the terminal completion, because the
;: operation owns the caller's buffer until then. The stop reason is the
;: result, unless positive progress won the race or the adapter proved corrupt
;: while draining.
(define (wait-pending
  [connection : (&mut connection LocalIpcConnection)]
  [adapter : (& adapter LocalIpcAdapter)]
  [handle : i64]
  [requested : i64]
  [deadline-ms : i64]
  [cancel-check : (-> bool)]
  [work-budget : i64]) : LocalIpcWaitOutcome
  (let
    [work-left : i64 work-budget]
    [result : LocalIpcIoResult (LocalIpcIoResult.WouldBlock)]
    [running : bool true]
    (begin
      (while running
        (match (stop-reason adapter deadline-ms cancel-check work-left)
          [(LocalIpcStatus.Err failure)
            (let
              [drained : LocalIpcIoResult
                (drain-pending connection adapter handle requested true)]
              (begin
                (set!
                  result
                  (match drained
                    [(LocalIpcIoResult.Done _) drained]
                    [(LocalIpcIoResult.Failed drain-failure)
                      (match drain-failure.kind
                        [(LocalIpcErrorKind.AdapterCorrupt) drained]
                        [_ (LocalIpcIoResult.Failed failure)])]
                    [_ (LocalIpcIoResult.Failed failure)]))
                (set! running false)))]
          [(LocalIpcStatus.Ok)
            (begin
              (set! work-left (- work-left 1))
              (let
                [step : LocalIpcIoStep
                  (adapter.poll-pending
                    adapter.context
                    handle
                    (next-slice-ms adapter deadline-ms))]
                (match step
                  [(LocalIpcIoStep.Pending) unit]
                  [_
                    (begin
                      (set! result (io-result-from-step step requested))
                      (set! running false))])))]))
      (LocalIpcWaitOutcome result work-left))))

;: One wait-capable transfer of at least one byte of an address range. It
;: retries only `WouldBlock` (after one bounded readiness wait) and
;: `Interrupted`. Before every host attempt it applies `stop-reason`, so
;: cancellation beats timeout and an expired deadline beats a new attempt.
;: Progress that an attempt already committed is returned even if cancellation
;: became visible meanwhile.
(define (io-wait
  [connection : (&mut connection LocalIpcConnection)]
  [writing : bool]
  [addr : i64]
  [length : i64]
  [deadline-ms : i64]
  [cancel-check : (-> bool)]
  [work-budget : i64]) : LocalIpcWaitOutcome
  (if (ptr-null? connection.state)
    (LocalIpcWaitOutcome
      (LocalIpcIoResult.Failed (make-error (LocalIpcErrorKind.Closed) 0))
      work-budget)
    (let
      [current : LocalIpcConnectionState
        (unsafe
          (ptr-read connection.state))]
      [work-left : i64 work-budget]
      [result : LocalIpcIoResult (LocalIpcIoResult.WouldBlock)]
      [running : bool true]
      (begin
        (cond
          [(< current.handle 0)
            (begin
              (set!
                result
                (LocalIpcIoResult.Failed
                  (make-error (LocalIpcErrorKind.Closed) 0)))
              (set! running false))]
          [(= length 0)
            (begin
              (set! result (LocalIpcIoResult.Done 0))
              (set! running false))]
          [else unit])
        (while running
          (match (stop-reason
            (& current.adapter)
            deadline-ms
            cancel-check
            work-left)
            [(LocalIpcStatus.Err failure)
              (begin
                (set! result (LocalIpcIoResult.Failed failure))
                (set! running false))]
            [(LocalIpcStatus.Ok)
              (begin
                (set! work-left (- work-left 1))
                (let
                  [step : LocalIpcIoStep
                    (io-attempt (& current) writing addr length)]
                  [attempt : LocalIpcIoResult
                    (match step
                      [(LocalIpcIoStep.Pending)
                        (let
                          [waited : LocalIpcWaitOutcome
                            (wait-pending
                              connection
                              (& current.adapter)
                              current.handle
                              length
                              deadline-ms
                              cancel-check
                              work-left)]
                          (begin
                            (set! work-left waited.work-left)
                            waited.result))]
                      [_ (io-result-from-step step length)])]
                  (match attempt
                    [(LocalIpcIoResult.Interrupted) unit]
                    [(LocalIpcIoResult.WouldBlock)
                      (match (stop-reason
                        (& current.adapter)
                        deadline-ms
                        cancel-check
                        work-left)
                        [(LocalIpcStatus.Err failure)
                          (begin
                            (set! result (LocalIpcIoResult.Failed failure))
                            (set! running false))]
                        [(LocalIpcStatus.Ok)
                          (begin
                            (set! work-left (- work-left 1))
                            (match (current.adapter.wait-ready
                              current.adapter.context
                              current.handle
                              (if writing
                                interest-write
                                interest-read)
                              (next-slice-ms (& current.adapter) deadline-ms))
                              [(LocalIpcWaitStep.WaitFailed failure)
                                (begin
                                  (set!
                                    result
                                    (LocalIpcIoResult.Failed failure))
                                  (set! running false))]
                              [_ unit]))])]
                    [_
                      (begin
                        (set! result attempt)
                        (set! running false))])))]))
        (LocalIpcWaitOutcome result work-left)))))

;: Wait-capable read of at least one byte into `view[start..start+count]`.
(define (read-wait!
  [connection : (&mut connection LocalIpcConnection)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]
  [deadline-ms : i64]
  [cancel-check : (-> bool)]
  [work-budget : i64]) : LocalIpcIoResult
  (if (not (range-valid? (byte_buf.bytes-mut-length view) start count))
    (LocalIpcIoResult.Failed (make-error (LocalIpcErrorKind.InvalidRange) 0))
    (let
      [outcome : LocalIpcWaitOutcome
        (io-wait
          connection
          false
          (+
            (unsafe
              (cast (ptr->int (byte_buf.bytes-mut-data view)) : i64))
            start)
          count
          deadline-ms
          cancel-check
          work-budget)]
      outcome.result)))

;: Wait-capable write of at least one byte from `view[start..start+count]`.
(define (write-wait!
  [connection : (&mut connection LocalIpcConnection)]
  [view : (& view bytes)]
  [start : i64]
  [count : i64]
  [deadline-ms : i64]
  [cancel-check : (-> bool)]
  [work-budget : i64]) : LocalIpcIoResult
  (if (not (range-valid? (byte_buf.bytes-length view) start count))
    (LocalIpcIoResult.Failed (make-error (LocalIpcErrorKind.InvalidRange) 0))
    (let
      [outcome : LocalIpcWaitOutcome
        (io-wait
          connection
          true
          (+
            (unsafe
              (cast (ptr->int (byte_buf.bytes-data view)) : i64))
            start)
          count
          deadline-ms
          cancel-check
          work-budget)]
      outcome.result)))

;: Transfer the whole range, keeping the completed count. One budget covers the
;: whole transfer: every host attempt and readiness wait consumes a unit, so it
;: terminates. It stops on cancellation, timeout, EOF, error and budget
;: exhaustion, and `status` is `Ok` only when every byte was transferred.
(define (io-all
  [connection : (&mut connection LocalIpcConnection)]
  [writing : bool]
  [addr : i64]
  [length : i64]
  [deadline-ms : i64]
  [cancel-check : (-> bool)]
  [work-budget : i64]) : LocalIpcTransfer
  (let
    [done : i64 0]
    [work-left : i64 work-budget]
    [status : LocalIpcStatus (LocalIpcStatus.Ok)]
    [running : bool (> length 0)]
    (begin
      (while running
        (let
          [outcome : LocalIpcWaitOutcome
            (io-wait
              connection
              writing
              (+ addr done)
              (- length done)
              deadline-ms
              cancel-check
              work-left)]
          (begin
            (set! work-left outcome.work-left)
            (match outcome.result
              [(LocalIpcIoResult.Done count)
                (begin
                  (set! done (+ done count))
                  (set! running (< done length)))]
              [(LocalIpcIoResult.Eof)
                (begin
                  (set!
                    status
                    (LocalIpcStatus.Err
                      (make-error (LocalIpcErrorKind.PeerClosed) 0)))
                  (set! running false))]
              [(LocalIpcIoResult.Failed failure)
                (begin
                  (set! status (LocalIpcStatus.Err failure))
                  (set! running false))]
              [_
                (begin
                  (set!
                    status
                    (LocalIpcStatus.Err
                      (make-error (LocalIpcErrorKind.AdapterCorrupt) 0)))
                  (set! running false))]))))
      (LocalIpcTransfer done status))))

;: Read exactly `count` bytes into `view[start..start+count]`.
(define (read-exact!
  [connection : (&mut connection LocalIpcConnection)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]
  [deadline-ms : i64]
  [cancel-check : (-> bool)]
  [work-budget : i64]) : LocalIpcTransfer
  (if (not (range-valid? (byte_buf.bytes-mut-length view) start count))
    (LocalIpcTransfer
      0
      (LocalIpcStatus.Err (make-error (LocalIpcErrorKind.InvalidRange) 0)))
    (io-all
      connection
      false
      (+
        (unsafe
          (cast (ptr->int (byte_buf.bytes-mut-data view)) : i64))
        start)
      count
      deadline-ms
      cancel-check
      work-budget)))

;: Write all `count` bytes of `view[start..start+count]`.
(define (write-all!
  [connection : (&mut connection LocalIpcConnection)]
  [view : (& view bytes)]
  [start : i64]
  [count : i64]
  [deadline-ms : i64]
  [cancel-check : (-> bool)]
  [work-budget : i64]) : LocalIpcTransfer
  (if (not (range-valid? (byte_buf.bytes-length view) start count))
    (LocalIpcTransfer
      0
      (LocalIpcStatus.Err (make-error (LocalIpcErrorKind.InvalidRange) 0)))
    (io-all
      connection
      true
      (+
        (unsafe
          (cast (ptr->int (byte_buf.bytes-data view)) : i64))
        start)
      count
      deadline-ms
      cancel-check
      work-budget)))