;# Target-independent synchronous socket contracts. No host calls live here.
;# Native adapters keep sockets nonblocking and validate every context/token.
;# The capability boundary carries values and owned bytes, never addresses.
;#
;# ```typelisp
;# (import stdlib.net)
;# (import stdlib.net.ip)
;# (define (main) : i64
;#   (match (net.socket-addr-v4 (ip.ipv4 127 0 0 1) 0)
;#     [(Address endpoint) (if (= (net.socket-addr-port endpoint) 0) 42 1)]
;#     [(AddressError _) 1]))
;# ```
(import stdlib.byte_buf)
(import stdlib.local_ipc)
(import stdlib.net.ip)
(import stdlib.string)

;: IPv4 endpoint. Ports are checked before dispatch, including forged records.
(defstruct SocketAddrV4
  (address ip.Ipv4Addr)
  (port i64))

;: IPv6 endpoint. Scope is a checked u32 value; flowinfo is always zero.
(defstruct SocketAddrV6
  (address ip.Ipv6Addr)
  (port i64)
  (scope-id i64))

;: One concrete endpoint; resolution and address-list iteration are caller policy.
(defenum SocketAddr
  (V4 SocketAddrV4)
  (V6 SocketAddrV6))

;: Portable categories; names shared with local IPC have the same meaning.
(defenum NetErrorKind
  (InvalidEndpoint)
  (InvalidRange)
  (InvalidOption)
  (Unavailable)
  (PermissionDenied)
  (Busy)
  (TimedOut)
  (Canceled)
  (PeerClosed)
  (ResourceExhausted)
  (UnsupportedTarget)
  (UnsupportedAddressFamily)
  (UnsupportedCapability)
  (AdapterCorrupt)
  (Closed)
  (WorkExhausted)
  (HostFailure)
  (WouldBlock)
  (Interrupted)
  (ZeroProgress)
  (UnexpectedEof)
  (PartialDatagram)
  (CommittedMetadata)
  (NotConnected)
  (AlreadyConnected)
  (ConnectionRefused)
  (ConnectionReset)
  (AddressInUse)
  (AddressNotAvailable)
  (NetworkUnreachable)
  (BrokenPipe))

;: Closed error-code domain. None means no raw code is available.
(defenum HostCodeDomain
  (NoHostCode)
  (LinuxErrno)
  (WindowsWsa)
  (WindowsKernel))

;: Bounded diagnostic code, never a descriptor, address or peer payload.
(defstruct NetError
  (kind NetErrorKind)
  (domain HostCodeDomain)
  (code i64))

;: Error without host provenance.
(define (error [kind : NetErrorKind]) : NetError
  (NetError kind (NoHostCode) 0))

;: Normalize untrusted adapter error codes to the unsigned 32-bit domain.
(define (checked-error [failure : NetError]) : NetError
  (if (or (< failure.code 0) (> failure.code 4294967295))
    (error failure.kind)
    (match failure.domain
      [(NoHostCode) (error failure.kind)]
      [_ failure])))

;: Operation status. Errors describe no payload progress unless its result says so.
(defenum NetStatus
  (Ok)
  (Err NetError))

;: Whether an operation succeeded.
(define (status-ok? [status : NetStatus]) : bool
  (match status
    [(Ok) true]
    [(Err _) false]))

;: Validate all endpoint widths before invoking a capability.
(define (validate-address [address : SocketAddr]) : NetStatus
  (let
    [port : i64
      (match address
        [(V4 a) a.port]
        [(V6 a) a.port])]
    [scope : i64
      (match address
        [(V4 _) 0]
        [(V6 a) a.scope-id])]
    (if (and (>= port 0) (<= port 65535) (>= scope 0) (<= scope 4294967295))
      (Ok)
      (Err (error (InvalidEndpoint))))))

;: Endpoint family: 4 or 6, independent of native AF_* numbers.
(define (address-family [address : SocketAddr]) : i64
  (match address
    [(V4 _) 4]
    [(V6 _) 6]))

;: Port accessor, after construction or adapter validation.
(define (socket-addr-port [address : SocketAddr]) : i64
  (match address
    [(V4 a) a.port]
    [(V6 a) a.port]))

;: IPv6 scope ID, or zero for IPv4.
(define (socket-addr-scope-id [address : SocketAddr]) : i64
  (match address
    [(V4 _) 0]
    [(V6 a) a.scope-id]))

;: Canonical IP value without endpoint text conversion.
(define (socket-addr-ip [address : SocketAddr]) : ip.IpAddr
  (match address
    [(V4 a) (ip.V4 a.address)]
    [(V6 a) (ip.V6 a.address)]))

;: Valid zero endpoint used only in request slots that do not carry an address.
(define (empty-address) : SocketAddr
  (V4 (SocketAddrV4 (ip.ipv4 0 0 0 0) 0)))

;: Checked endpoint or error.
(defenum SocketAddrResult
  (Address SocketAddr)
  (AddressError NetError))

;: Construct an endpoint without narrowing a caller's integer.
(define (socket-addr-v4 [address : ip.Ipv4Addr] [port : i64]) : SocketAddrResult
  (let
    [value : SocketAddr (V4 (SocketAddrV4 address port))]
    (match (validate-address value)
      [(Ok) (Address value)]
      [(Err failure) (AddressError failure)])))

;: Construct a scoped IPv6 endpoint; public flowinfo is intentionally omitted.
(define (socket-addr-v6 [address : ip.Ipv6Addr] [port : i64] [scope-id : i64]) : SocketAddrResult
  (let
    [value : SocketAddr (V6 (SocketAddrV6 address port scope-id))]
    (match (validate-address value)
      [(Ok) (Address value)]
      [(Err failure) (AddressError failure)])))

;: None, or an absolute nonnegative monotonic-millisecond deadline.
(defenum NetDeadline
  (NoDeadline)
  (Deadline i64))

;: Limits are shared by every dispatch/preflight/wait of one public operation.
(defstruct NetLimits
  (deadline NetDeadline)
  (canceled (-> bool))
  (work i64))

;: Cancellation probe for uncancelable callers.
(define (never-canceled) : bool
  false)

;: Explicit finite default: no deadline, no cancellation, at most 1024 calls.
(define (default-limits) : NetLimits
  (NetLimits (NoDeadline) never-canceled 1024))

;: Resource families, also checked against the private cell on every operation.
(defenum SocketKind
  (Stream)
  (Listener)
  (Datagram))

;: Half shutdown, shared by all duplicates. Repetition normalizes to success.
(defenum Shutdown
  (ShutdownRead)
  (ShutdownWrite)
  (ShutdownBoth))

;: Selected options. Broadcast is IPv4-only; hop limit is 1..255.
(defenum SocketOption
  (NoDelay)
  (UnicastHopLimit)
  (Broadcast)
  (TakeError))

;: Closed capability schema. Data requests make one transfer attempt. UDP
;: Preflight is separate, counts as work, and checks the live shared peer state.
;: Create performs fixed v6-only policy, backlog 128, permanent nonblocking;
;: a pending connect is completed with FinishConnect before publication.
;: Bind constructors and failures clean up unpublished native resources.
(defenum NetOperation
  (Create)
  (FinishConnect)
  (Accept)
  (Duplicate)
  (Close)
  (LocalAddress)
  (PeerAddress)
  (Read)
  (Peek)
  (Write)
  (Send)
  (Receive)
  (PeekDatagram)
  (SendTo)
  (ReceiveFrom)
  (PeekFrom)
  (ConnectDatagram)
  (Preflight)
  (WaitRead)
  (WaitWrite)
  (ShutdownOp)
  (GetOption)
  (SetOption))

;: Values only. `token` is a generation-checked registry ID, never native bits.
;: `value` carries wait milliseconds, option values or connected preconditions.
;: `limits` carries the original deadline/probe and remaining work, so compound
;: construction checks before each internal host call, not just each dispatch.
(defstruct NetRequest
  (operation NetOperation)
  (kind SocketKind)
  (token i64)
  (address SocketAddr)
  (value i64)
  (option SocketOption)
  (shutdown Shutdown)
  (limits NetLimits))

;: Adapter result. Created/PendingConnect/Accepted tokens already have an
;: independent cleanup obligation. Corrupt accept metadata must still return
;: that token so the contract can consume it. Address metadata is decoded in
;: scratch; malformed flowinfo/scope is reported with MetadataFailure.
;: PendingConnect and Accepted always own Stream tokens, even in invalid replies.
(defenum NetStep
  (Complete)
  (Created i64)
  (PendingConnect i64)
  (Accepted i64 SocketAddr)
  (Endpoint SocketAddr)
  (Data i64 bool)
  (DatagramFrom i64 bool SocketAddr)
  (MetadataFailure i64 bool)
  (OptionValue i64)
  (PendingError NetError)
  (Blocked)
  (Interrupt)
  (Failed NetError))

;: Reply hands the owned buffer back, reports all bounded host calls made.
;: Validation/unsupported failures can use zero calls; every dispatch still
;: costs at least one work unit, so zero-call retries cannot livelock.
;: An error leaves payload unchanged except Data/MetadataFailure/DatagramFrom.
;: UDP truncation comes from host metadata, never count == capacity.
(defstruct NetReply
  (step NetStep)
  (buffer byte_buf.ByteBuf)
  (calls i64))

;: Safe capability values must be memory-safe for every possible argument.
;: Validate context/token/generation/kind/ranges/capabilities before host calls.
;: Create, accept and duplicate make native handles non-inheritable before
;: publication, and close unpublished resources on every failure path.
;: Native sockets remain nonblocking; waits <= local_ipc.wait-slice-ms; stream
;: writes suppress SIGPIPE. No callback retains buffers after returning.
(defstruct NetAdapter
  (context i64)
  (now-ms (-> i64 i64))
  (dispatch (-> i64 NetRequest byte_buf.ByteBuf NetReply)))

;: TCP transfer chunk. Longer borrowed ranges are valid, including > INT_MAX.
(define stream-transfer-max : i64
  16384)

;: Portable UDP payload and receive-view maximum.
(define datagram-max : i64
  65507)

;: Fixed requested listener backlog; the host may cap it.
(define listener-backlog : i64
  128)

;: Portable dispatch prefix; never narrow or reject a long valid TCP view.
(define (stream-attempt-size [length : i64]) : i64
  (if (> length stream-transfer-max)
    stream-transfer-max
    length))

;: Private owner storage; kind and adapter identity never come from a wrapper.
(defstruct SocketState
  (token i64)
  (kind SocketKind)
  (family i64)
  (adapter NetAdapter)
  (buffer byte_buf.ByteBuf))

;: Generation lives after the state. Raw state access requires unsafe.
(define (state-words) : i64
  (/ (+ (comptime (size-of (type SocketState))) 7) 8))

(unsafe
  (define (generation-ptr [state : (MutPtr SocketState)]) : (MutPtr i64)
    (unsafe
      (ptr-offset (ptr-cast state : (MutPtr i64)) (state-words)))))

;: Unforgeable pointer and generation. Reconstructing one from an existing
;: public owner is harmless: only the first atomic claim remains effective.
(defstruct SocketOwner
  (state (MutPtr SocketState))
  (generation i64))

(unsafe
  (define (owner-claim [owner : SocketOwner]) : bool
    (and
      (not (ptr-null? owner.state))
      (>= owner.generation 0)
      (< owner.generation 9223372036854775807)
      (=
        (unsafe
          (atomic-cas!
            (generation-ptr owner.state)
            owner.generation
            (+ owner.generation 1)))
        owner.generation))))

;: Make a value-only request with safe defaults for unused slots.
(define (request [operation : NetOperation] [kind : SocketKind] [token : i64]) : NetRequest
  (NetRequest
    operation
    kind
    token
    (empty-address)
    0
    (TakeError)
    (ShutdownBoth)
    (NetLimits (NoDeadline) never-canceled 1)))

;: Claim before accessing the private state; poison before exactly one close.
;: Interrupted/ambiguous close is returned and never retried.
(unsafe
  (define (state-close [state : (MutPtr SocketState)]) : NetStatus
    (let
      [current : SocketState
        (unsafe
          (ptr-read state))]
      [token : i64 current.token]
      [kind : SocketKind current.kind]
      (if (< token 0)
        (Err (error (Closed)))
        (begin
          (unsafe
            (ptr-write!
              state
              (SocketState
                -1
                current.kind
                current.family
                current.adapter
                current.buffer)))
          (let
            [reply : NetReply
              (unsafe
                (dispatch-state state (request (Close) kind token)))]
            [step : NetStep reply.step]
            (unsafe
              (restore-buffer state reply.buffer))
            (match step
              [(Complete) (Ok)]
              [(Interrupt) (Err (error (Interrupted)))]
              [(Failed failure) (Err (checked-error failure))]
              [_
                (abandon-step current.adapter kind token step)
                (Err (error (AdapterCorrupt)))])))))))

;: Lexical cleanup is idempotent; stale values cannot close the active owner.
(define (owner-cleanup [owner : SocketOwner]) : unit
  (if (unsafe
    (owner-claim owner))
    (begin
      (unsafe
        (state-close owner.state))
      unit)
    unit))

;: Move-only TCP stream. Operations borrow mutably and validate private kind.
(defstruct TcpStream
  (:cleanup cleanup-tcp-stream)
  (owner SocketOwner (:cleanup owner-cleanup)))

;: Move-only bound/listening TCP socket.
(defstruct TcpListener
  (:cleanup cleanup-tcp-listener)
  (owner SocketOwner (:cleanup owner-cleanup)))

;: Move-only bound UDP socket, connected state is shared kernel state.
(defstruct UdpSocket
  (:cleanup cleanup-udp-socket)
  (owner SocketOwner (:cleanup owner-cleanup)))

;: Closed-kind equality avoids relying on target enum representation.
(define (kind-code [kind : SocketKind]) : i64
  (match kind
    [(Stream) 1]
    [(Listener) 2]
    [(Datagram) 3]))

;: Each operation advances the effective owner, including close and zero I/O.
(define (claim! [owner : (&mut owner SocketOwner)] [kind : SocketKind]) : NetStatus
  (if (not
    (unsafe
      (owner-claim (SocketOwner owner.state owner.generation))))
    (Err (error (Closed)))
    (begin
      (set! owner.generation (+ owner.generation 1))
      (let
        [current : SocketState
          (unsafe
            (ptr-read owner.state))]
        (cond
          [(< current.token 0) (Err (error (Closed)))]
          [(!= (kind-code kind) (kind-code current.kind))
            (Err (error (InvalidOption)))]
          [else (Ok)])))))

;: Allocate state at generation zero. Token ownership transfers here once.
(unsafe
  (define (publish
    [adapter : NetAdapter]
    [kind : SocketKind]
    [family : i64]
    [token : i64]) : SocketOwner
    (let
      [storage : (__tl_dyn-array u64) (__tl_make-array u64 (+ (state-words) 1))]
      [state : (MutPtr SocketState)
        (unsafe
          (ptr-cast (__tl_array-data storage) : (MutPtr SocketState)))]
      [capacity : i64
        (if (= (kind-code kind) 3)
          datagram-max
          stream-transfer-max)]
      (unsafe
        (ptr-write!
          state
          (SocketState
            token
            kind
            family
            adapter
            (byte_buf.ByteBuf (__tl_make-array u8 capacity) capacity))))
      (SocketOwner state 0))))

;: Shared stop precedence before every host dispatch: cancel, deadline, work.
;: Negative explicit deadlines/work are invalid before any adapter call.
(define (limits-valid? [limits : NetLimits]) : bool
  (and
    (>= limits.work 0)
    (match limits.deadline
      [(NoDeadline) true]
      [(Deadline ms) (>= ms 0)])))

;: Apply cancellation, expiration and work precedence in that order.
(define (stop-reason [adapter : NetAdapter] [limits : NetLimits] [work : i64]) : NetStatus
  (if (limits.canceled)
    (Err (error (Canceled)))
    (match limits.deadline
      [(Deadline deadline)
        (let
          [now : i64 (adapter.now-ms adapter.context)]
          (cond
            [(< now 0) (Err (error (UnsupportedTarget)))]
            [(>= now deadline) (Err (error (TimedOut)))]
            [(<= work 0) (Err (error (WorkExhausted)))]
            [else (Ok)]))]
      [(NoDeadline)
        (if (<= work 0)
          (Err (error (WorkExhausted)))
          (Ok))])))

;: A strictly positive bounded wait, or the exact reason no wait is allowed.
(defenum NetWaitSlice
  (SliceMs i64)
  (SliceError NetError))

;: Compare before subtraction; preserve clock failure independently of expiry.
;: No caller deadline still produces a bounded slice, never a host sentinel.
(define (wait-slice [adapter : NetAdapter] [limits : NetLimits]) : NetWaitSlice
  (match limits.deadline
    [(NoDeadline) (SliceMs local_ipc.wait-slice-ms)]
    [(Deadline deadline)
      (let
        [now : i64 (adapter.now-ms adapter.context)]
        (cond
          [(< now 0) (SliceError (error (UnsupportedTarget)))]
          [(>= now deadline) (SliceError (error (TimedOut)))]
          [else
            (let
              [left : i64 (- deadline now)]
              (SliceMs
                (if (> left local_ipc.wait-slice-ms)
                  local_ipc.wait-slice-ms
                  left)))]))]))

;: True for a data operation with read readiness interest.
(define (reading? [operation : NetOperation]) : bool
  (match operation
    [(Read) true]
    [(Peek) true]
    [(Receive) true]
    [(PeekDatagram) true]
    [(ReceiveFrom) true]
    [(PeekFrom) true]
    [(Accept) true]
    [_ false]))

;: Data operations have exactly one transfer call; peer preflight is separate.
(define (one-data-call? [operation : NetOperation]) : bool
  (match operation
    [(Read) true]
    [(Peek) true]
    [(Write) true]
    [(Send) true]
    [(Receive) true]
    [(PeekDatagram) true]
    [(SendTo) true]
    [(ReceiveFrom) true]
    [(PeekFrom) true]
    [_ false]))

;: A step plus remaining work; whole-buffer helpers reuse the same budget.
(defstruct NetAttempt
  (step NetStep)
  (work-left i64))

;: Dispatch through the private cell, temporarily transferring its ByteBuf.
;: Every returned byte/count is validated before copying into borrowed memory.
(unsafe
  (define (dispatch-state [state : (MutPtr SocketState)] [req : NetRequest]) : NetReply
    (let
      [current : SocketState
        (unsafe
          (ptr-read state))]
      [adapter : NetAdapter current.adapter]
      (adapter.dispatch adapter.context req current.buffer))))

;: Restore the buffer, even after errors or a corrupt reply. No raw address
;: escapes; a short replacement buffer is detected before the next copy.
(unsafe
  (define (restore-buffer
    [state : (MutPtr SocketState)]
    [buffer : byte_buf.ByteBuf]) : unit
    (let
      [current : SocketState
        (unsafe
          (ptr-read state))]
      (unsafe
        (ptr-write!
          state
          (SocketState
            current.token
            current.kind
            current.family
            current.adapter
            buffer))))))

;: Only duplication and accept may publish a resource after construction.
(define (resource-step-valid? [operation : NetOperation] [step : NetStep]) : bool
  (match step
    [(Created _)
      (match operation
        [(Duplicate) true]
        [_ false])]
    [(Accepted _ _)
      (match operation
        [(Accept) true]
        [_ false])]
    [(PendingConnect _) false]
    [_ true]))

;: Consume an independent token in an abandoned reply, never the active token.
(define (abandon-step
  [adapter : NetAdapter]
  [kind : SocketKind]
  [protected-token : i64]
  [step : NetStep]) : unit
  (match step
    [(Created token)
      (if (!= token protected-token)
        (abandon adapter kind token)
        unit)]
    [(PendingConnect token)
      (if (!= token protected-token)
        (abandon adapter (Stream) token)
        unit)]
    [(Accepted token _)
      (if (!= token protected-token)
        (abandon adapter (Stream) token)
        unit)]
    [_ unit]))

;: Execute one attempt or bounded wait/retry sequence. Interruptions and
;: spurious readiness consume work. Try operations return after one dispatch.
(unsafe
  (define (attempt
    [state : (MutPtr SocketState)]
    [req : NetRequest]
    [limits : NetLimits]
    [wait? : bool]
    [work : i64]) : NetAttempt
    (let
      [adapter : NetAdapter
        (unsafe
          (ptr-read state)).adapter]
      [left : i64 work]
      [done : bool false]
      [step : NetStep (Failed (error (WorkExhausted)))]
      [waiting : bool false]
      (while (not done)
        (match (if wait?
          (stop-reason adapter limits left)
          (if (> left 0)
            (Ok)
            (Err (error (WorkExhausted)))))
          [(Err failure)
            (set! step (Failed failure))
            (set! done true)]
          [(Ok)
            (let
              [call : NetRequest req]
              (set!
                call.limits
                (NetLimits limits.deadline limits.canceled left))
              (if waiting
                (begin
                  (set!
                    call.operation
                    (if (reading? req.operation)
                      (WaitRead)
                      (WaitWrite)))
                  (match (wait-slice adapter limits)
                    [(SliceMs ms) (set! call.value ms)]
                    [(SliceError failure)
                      (set! step (Failed failure))
                      (set! done true)]))
                unit)
              (if done
                unit
                (let
                  [reply : NetReply
                    (unsafe
                      (dispatch-state state call))]
                  [result : NetStep reply.step]
                  [calls : i64 reply.calls]
                  (unsafe
                    (restore-buffer state reply.buffer))
                  (if (or
                    (not (resource-step-valid? call.operation result))
                    (< calls 0)
                    (> calls left)
                    (and
                      (one-data-call? call.operation)
                      (match result
                        [(Data _ _) (!= calls 1)]
                        [(DatagramFrom _ _ _) (!= calls 1)]
                        [(MetadataFailure _ _) (!= calls 1)]
                        [_ false])))
                    (begin
                      (abandon-step adapter req.kind req.token result)
                      (set! step (Failed (error (AdapterCorrupt))))
                      (set! done true))
                    (begin
                      (set!
                        left
                        (-
                          left
                          (if (= calls 0)
                            1
                            calls)))
                      (match result
                        [(Interrupt)
                          (if wait?
                            unit
                            (begin
                              (set! step result)
                              (set! done true)))]
                        [(Blocked)
                          (if wait?
                            (set! waiting true)
                            (begin
                              (set! step result)
                              (set! done true)))]
                        [(Complete)
                          (if waiting
                            (set! waiting false)
                            (begin
                              (set! step result)
                              (set! done true)))]
                        [_
                          (if waiting
                            (match result
                              [(Failed failure)
                                (set! step (Failed (checked-error failure)))]
                              [_ (set! step (Failed (error (AdapterCorrupt))))])
                            (set! step result))
                          (set! done true)]))))))]))
      (NetAttempt step left))))

;: Normalize terminal errors and ordinary one-attempt retry conditions. A
;: success-shaped reply in an error position is adapter corruption.
(define (step-error [step : NetStep]) : NetError
  (match step
    [(Failed failure) (checked-error failure)]
    [(Blocked) (error (WouldBlock))]
    [(Interrupt) (error (Interrupted))]
    [_ (error (AdapterCorrupt))]))

;: Convert status-only capability results using the common error mapping.
(define (step-status [step : NetStep]) : NetStatus
  (match step
    [(Complete) (Ok)]
    [_ (Err (step-error step))]))

;: Internal construction result owns a token only on success.
(defenum OwnerResult
  (OwnerOk SocketOwner)
  (OwnerError NetError))

;: Close a construction-owned token once on every abandoned path.
(define (abandon [adapter : NetAdapter] [kind : SocketKind] [token : i64]) : unit
  (if (>= token 0)
    (begin
      (adapter.dispatch
        adapter.context
        (request (Close) kind token)
        (byte_buf.new))
      unit)
    unit))

;: Construction is atomic publicly. Pending streams remain construction-owned
;: through finish/wait and are closed on cancellation, timeout or any error.
(define (construct
  [adapter : NetAdapter]
  [kind : SocketKind]
  [address : SocketAddr]
  [limits : NetLimits]) : OwnerResult
  (cond
    [(not (limits-valid? limits)) (OwnerError (error (InvalidRange)))]
    [(not (status-ok? (validate-address address)))
      (OwnerError (error (InvalidEndpoint)))]
    [else
      (match (stop-reason adapter limits limits.work)
        [(Err failure) (OwnerError failure)]
        [(Ok)
          (let
            [req : NetRequest (request (Create) kind -1)]
            (set! req.address address)
            (set! req.value listener-backlog)
            (set! req.limits limits)
            (let
              [reply : NetReply
                (adapter.dispatch adapter.context req (byte_buf.new))]
              [step : NetStep reply.step]
              [valid-calls : bool
                (and (>= reply.calls 0) (<= reply.calls limits.work))]
              (match step
                [(Created token)
                  (if (and valid-calls (> reply.calls 0) (>= token 0))
                    (OwnerOk
                      (unsafe
                        (publish adapter kind (address-family address) token)))
                    (begin
                      (abandon adapter kind token)
                      (OwnerError (error (AdapterCorrupt)))))]
                [(PendingConnect token)
                  (if (or
                    (not valid-calls)
                    (<= reply.calls 0)
                    (< token 0)
                    (!= (kind-code kind) 1))
                    (begin
                      (abandon adapter (Stream) token)
                      (OwnerError (error (AdapterCorrupt))))
                    (let
                      [owner : SocketOwner
                        (unsafe
                          (publish adapter kind (address-family address) token))]
                      [finished : NetAttempt
                        (unsafe
                          (attempt
                            owner.state
                            (request (FinishConnect) kind token)
                            limits
                            true
                            (- limits.work reply.calls)))]
                      (match (step-status finished.step)
                        [(Ok) (OwnerOk owner)]
                        [(Err failure)
                          (owner-cleanup owner)
                          (OwnerError failure)])))]
                [(Failed failure)
                  (OwnerError
                    (if valid-calls
                      (checked-error failure)
                      (error (AdapterCorrupt))))]
                [(Interrupt) (OwnerError (error (Interrupted)))]
                [_
                  (abandon-step adapter kind -1 step)
                  (OwnerError (error (AdapterCorrupt)))])))])]))

;: Connected TCP stream or construction error; no half-connected public value.
(defenum TcpStreamResult
  (:cleanup cleanup-tcp-stream-result)
  (StreamOk TcpStream (:owned))
  (StreamError NetError))

;: Listening socket or construction error.
(defenum TcpListenerResult
  (:cleanup cleanup-tcp-listener-result)
  (ListenerOk TcpListener (:owned))
  (ListenerError NetError))

;: Bound datagram socket or construction error.
(defenum UdpSocketResult
  (:cleanup cleanup-udp-socket-result)
  (UdpOk UdpSocket (:owned))
  (UdpError NetError))

;: Connect one concrete endpoint with finite limits.
(define (tcp-stream-connect
  [adapter : NetAdapter]
  [address : SocketAddr]
  [limits : NetLimits]) : TcpStreamResult
  (match (construct adapter (Stream) address limits)
    [(OwnerOk owner) (StreamOk (TcpStream owner))]
    [(OwnerError failure) (StreamError failure)]))

;: Create, v6-only setup, bind and listen with fixed backlog 128.
(define (tcp-listener-bind
  [adapter : NetAdapter]
  [address : SocketAddr]
  [limits : NetLimits]) : TcpListenerResult
  (match (construct adapter (Listener) address limits)
    [(OwnerOk owner) (ListenerOk (TcpListener owner))]
    [(OwnerError failure) (ListenerError failure)]))

;: Bind exactly one resolved address. IPv6 is always v6-only.
(define (udp-bind
  [adapter : NetAdapter]
  [address : SocketAddr]
  [limits : NetLimits]) : UdpSocketResult
  (match (construct adapter (Datagram) address limits)
    [(OwnerOk owner) (UdpOk (UdpSocket owner))]
    [(OwnerError failure) (UdpError failure)]))

;: An endpoint is published only after complete metadata validation.
(defenum NetPeer
  (NoPeer)
  (Peer SocketAddr))

;: Primitive byte result. EOF is stream-only; zero UDP count is a datagram.
;: On CommittedMetadata, count/truncation and copied bytes are committed, but
;: peer is NoPeer. Receive consumed that datagram; peek left it queued.
(defstruct NetIoResult
  (count i64)
  (truncated? bool)
  (eof? bool)
  (status NetStatus)
  (peer NetPeer))

;: Failure before payload progress.
(define (io-error [failure : NetError]) : NetIoResult
  (NetIoResult 0 false false (Err (checked-error failure)) (NoPeer)))

;: Range validation uses subtraction, so start+count cannot overflow.
(define (range-valid? [length : i64] [start : i64] [count : i64]) : bool
  (and
    (>= length 0)
    (>= start 0)
    (>= count 0)
    (<= start length)
    (<= count (- length start))))

;: One shared work counter across all retries and whole-buffer suffixes.
(defstruct NetIoAttempt
  (result NetIoResult)
  (work-left i64))

;: Raw copy addresses stay strictly inside this module. The entire borrowed
;: range is checked by the public wrapper; each chunk is <= transfer capacity.
;: Recopy a write before every retry: an adapter may replace/alter its buffer.
(unsafe
  (define (prepare-buffer
    [state : (MutPtr SocketState)]
    [address : i64]
    [count : i64]
    [writing? : bool]) : bool
    (let
      [current : SocketState
        (unsafe
          (ptr-read state))]
      (if (not (range-valid? (array-length current.buffer.slots) 0 count))
        false
        (let
          [buffer : byte_buf.ByteBuf
            (byte_buf.ByteBuf current.buffer.slots count)]
          (if (and writing? (> count 0))
            (unsafe
              (string.string-runtime-copy-bytes!
                (__tl_array-data buffer.slots)
                (int->ptr (cast address : u64) : (Ptr u8))
                count))
            unit)
          (unsafe
            (restore-buffer state buffer))
          true)))))

;: Copy only a validated committed prefix. No copy is made for ordinary errors.
(unsafe
  (define (copy-received
    [state : (MutPtr SocketState)]
    [address : i64]
    [count : i64]) : unit
    (if (> count 0)
      (let
        [current : SocketState
          (unsafe
            (ptr-read state))]
        (unsafe
          (string.string-runtime-copy-bytes!
            (int->ptr (cast address : u64) : (MutPtr u8))
            (ptr-cast (__tl_array-data current.buffer.slots) : (Ptr u8))
            count)))
      unit)))

;: A single bounded wait per iteration; both interruption and spurious wakes
;: consume the original budget and re-check cancellation and deadline.
(unsafe
  (define (wait-ready
    [state : (MutPtr SocketState)]
    [req : NetRequest]
    [limits : NetLimits]
    [work : i64]) : NetAttempt
    (let
      [adapter : NetAdapter
        (unsafe
          (ptr-read state)).adapter]
      [left : i64 work]
      [done : bool false]
      [result : NetStep (Failed (error (WorkExhausted)))]
      (while (not done)
        (match (stop-reason adapter limits left)
          [(Err failure)
            (set! result (Failed failure))
            (set! done true)]
          [(Ok)
            (let
              [call : NetRequest req]
              (set!
                call.operation
                (if (reading? req.operation)
                  (WaitRead)
                  (WaitWrite)))
              (match (wait-slice adapter limits)
                [(SliceMs ms) (set! call.value ms)]
                [(SliceError failure)
                  (set! result (Failed failure))
                  (set! done true)])
              (if done
                unit
                (let
                  [reply : NetAttempt
                    (unsafe
                      (attempt state call limits false left))]
                  (set! left reply.work-left)
                  (match reply.step
                    [(Blocked) unit]
                    [(Interrupt) unit]
                    [_
                      (set! result reply.step)
                      (set! done true)]))))]))
      (NetAttempt result left))))

;: Validate and translate a committed adapter result. The adapter must return
;: counts <= dispatched length and enough live buffer bytes for receive copies.
(unsafe
  (define (io-result
    [state : (MutPtr SocketState)]
    [step : NetStep]
    [operation : NetOperation]
    [address : i64]
    [requested : i64]
    [udp? : bool]
    [writing? : bool]) : NetIoResult
    (let
      [count : i64 0]
      [truncated? : bool false]
      [peer : NetPeer (NoPeer)]
      [committed? : bool false]
      [metadata-error? : bool false]
      [status : NetStatus (Ok)]
      (match step
        [(Data n truncated)
          (set! count n)
          (set! truncated? truncated)
          (set! committed? true)
          (match operation
            [(ReceiveFrom) (set! metadata-error? true)]
            [(PeekFrom) (set! metadata-error? true)]
            [_ unit])]
        [(DatagramFrom n truncated source)
          (set! count n)
          (set! truncated? truncated)
          (set! committed? true)
          (if (and
            udp?
            (not writing?)
            (status-ok? (validate-address source))
            (=
              (address-family source)
              (unsafe
                (ptr-read state)).family))
            (set! peer (Peer source))
            (set! metadata-error? true))]
        [(MetadataFailure n truncated)
          (set! count n)
          (set! truncated? truncated)
          (set! committed? true)
          (set! metadata-error? true)]
        [_ (set! status (step-status step))])
      (if (and udp? writing?)
        (set! truncated? false)
        unit)
      (if (not committed?)
        (match status
          [(Err failure) (io-error failure)]
          [(Ok) (io-error (error (AdapterCorrupt)))])
        (let
          [current : SocketState
            (unsafe
              (ptr-read state))]
          (cond
            [(or
                (< count 0)
                (> count requested)
                (and
                  (not writing?)
                  (or
                    (< current.buffer.len count)
                    (> current.buffer.len (array-length current.buffer.slots)))))
              (io-error (error (AdapterCorrupt)))]
            [else
              (if (not writing?)
                (unsafe
                  (copy-received state address count))
                unit)
              (cond
                [(and udp? writing? (!= count requested))
                  (NetIoResult
                    count
                    false
                    false
                    (Err (error (PartialDatagram)))
                    (NoPeer))]
                [(or metadata-error? (and (not udp?) truncated?))
                  (NetIoResult
                    count
                    truncated?
                    false
                    (Err (error (CommittedMetadata)))
                    (NoPeer))]
                [(and (not udp?) writing? (= count 0) (> requested 0))
                  (io-error (error (ZeroProgress)))]
                [else
                  (NetIoResult
                    count
                    truncated?
                    (and (not udp?) (not writing?) (= count 0) (> requested 0))
                    (Ok)
                    peer)])]))))))

;: Internal finite-progress data loop. All addresses are validated borrowed
;: ranges. UDP preflight and transfer have separate dispatch/call accounting.
(unsafe
  (define (io
    [owner : (&mut owner SocketOwner)]
    [kind : SocketKind]
    [operation : NetOperation]
    [address : i64]
    [count : i64]
    [destination : SocketAddr]
    [limits : NetLimits]
    [wait? : bool]
    [work : i64]) : NetIoAttempt
    (let
      [udp? : bool (= (kind-code kind) 3)]
      [writing? : bool (not (reading? operation))]
      [left : i64 work]
      [result : NetIoResult (io-error (error (WorkExhausted)))]
      [done : bool false]
      [retry-preflight? : bool false]
      [valid : NetStatus (claim! owner kind)]
      (cond
        [(not (limits-valid? limits))
          (NetIoAttempt (io-error (error (InvalidRange))) left)]
        [(not (status-ok? valid))
          (NetIoAttempt
            (match valid
              [(Err failure) (io-error failure)]
              [_ result])
            left)]
        [(and udp? (> count datagram-max))
          (NetIoAttempt (io-error (error (InvalidRange))) left)]
        [(and (not udp?) (= count 0))
          (NetIoAttempt (NetIoResult 0 false false (Ok) (NoPeer)) left)]
        [else
          (let
            [state : (MutPtr SocketState) owner.state]
            [current : SocketState
              (unsafe
                (ptr-read state))]
            [adapter : NetAdapter current.adapter]
            [token : i64 current.token]
            [requested : i64
              (if udp?
                count
                (stream-attempt-size count))]
            [req : NetRequest (request operation kind token)]
            (set! req.address destination)
            (if (and
              udp?
              (!= (address-family destination) current.family)
              (match operation
                [(SendTo) true]
                [_ false]))
              (begin
                (set! result (io-error (error (UnsupportedAddressFamily))))
                (set! done true))
              unit)
            (while (not done)
              (set! retry-preflight? false)
              (match (if wait?
                (stop-reason adapter limits left)
                (if (> left 0)
                  (Ok)
                  (Err (error (WorkExhausted)))))
                [(Err failure)
                  (set! result (io-error failure))
                  (set! done true)]
                [(Ok)
                  (if udp?
                    (let
                      [preflight : NetRequest (request (Preflight) kind token)]
                      (set!
                        preflight.value
                        (match operation
                          [(SendTo) 0]
                          [(ReceiveFrom) 0]
                          [(PeekFrom) 0]
                          [_ 1]))
                      (let
                        [checked : NetAttempt
                          (unsafe
                            (attempt state preflight limits false left))]
                        (set! left checked.work-left)
                        (match (step-status checked.step)
                          [(Err failure)
                            (if (and
                              wait?
                              (match failure.kind
                                [(Interrupted) true]
                                [_ false]))
                              (set! retry-preflight? true)
                              (begin
                                (set! result (io-error failure))
                                (set! done true)))]
                          [_ unit])))
                    unit)
                  (if (and (not done) wait? udp?)
                    (match (stop-reason adapter limits left)
                      [(Err failure)
                        (set! result (io-error failure))
                        (set! done true)]
                      [_ unit])
                    unit)
                  (if (and (not done) (not retry-preflight?))
                    (if (not
                      (unsafe
                        (prepare-buffer state address requested writing?)))
                      (begin
                        (set! result (io-error (error (AdapterCorrupt))))
                        (set! done true))
                      (let
                        [reply : NetAttempt
                          (unsafe
                            (attempt state req limits false left))]
                        (set! left reply.work-left)
                        (match reply.step
                          [(Interrupt)
                            (if wait?
                              unit
                              (begin
                                (set! result (io-error (error (Interrupted))))
                                (set! done true)))]
                          [(Blocked)
                            (if wait?
                              (let
                                [ready : NetAttempt
                                  (unsafe
                                    (wait-ready state req limits left))]
                                (set! left ready.work-left)
                                (match (step-status ready.step)
                                  [(Err failure)
                                    (set! result (io-error failure))
                                    (set! done true)]
                                  [_ unit]))
                              (begin
                                (set! result (io-error (error (WouldBlock))))
                                (set! done true)))]
                          [_
                            (set!
                              result
                              (unsafe
                                (io-result
                                  state
                                  reply.step
                                  operation
                                  address
                                  requested
                                  udp?
                                  writing?)))
                            (set! done true)])))
                    unit)]))
            (NetIoAttempt result left))]))))

;: TCP read/peek share the checked mutable-byte boundary.
(define (stream-receive!
  [stream : (&mut stream TcpStream)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]
  [peek? : bool]
  [limits : NetLimits]
  [wait? : bool]) : NetIoResult
  (if (not (range-valid? (byte_buf.bytes-mut-length view) start count))
    (io-error (error (InvalidRange)))
    (unsafe
      (io
        (&mut stream.owner)
        (Stream)
        (if peek?
          (Peek)
          (Read))
        (+ (cast (ptr->int (byte_buf.bytes-mut-data view)) : i64) start)
        count
        (empty-address)
        limits
        wait?
        limits.work)).result))

;: TCP write checks the entire borrowed range, then dispatches a bounded prefix.
(define (stream-send!
  [stream : (&mut stream TcpStream)]
  [view : (& view bytes)]
  [start : i64]
  [count : i64]
  [limits : NetLimits]
  [wait? : bool]) : NetIoResult
  (if (not (range-valid? (byte_buf.bytes-length view) start count))
    (io-error (error (InvalidRange)))
    (unsafe
      (io
        (&mut stream.owner)
        (Stream)
        (Write)
        (+ (cast (ptr->int (byte_buf.bytes-data view)) : i64) start)
        count
        (empty-address)
        limits
        wait?
        limits.work)).result))

;: One TCP receive attempt; zero capacity is Data(0), never EOF.
(define (tcp-stream-try-read!
  [stream : (&mut stream TcpStream)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]) : NetIoResult
  (stream-receive! stream view start count false (default-limits) false))

;: One nonconsuming TCP receive attempt.
(define (tcp-stream-try-peek!
  [stream : (&mut stream TcpStream)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]) : NetIoResult
  (stream-receive! stream view start count true (default-limits) false))

;: One TCP send attempt; nonempty host count zero is ZeroProgress.
(define (tcp-stream-try-write!
  [stream : (&mut stream TcpStream)]
  [view : (& view bytes)]
  [start : i64]
  [count : i64]) : NetIoResult
  (stream-send! stream view start count (default-limits) false))

;: Receive one positive prefix or EOF under one finite budget.
(define (tcp-stream-read!
  [stream : (&mut stream TcpStream)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]
  [limits : NetLimits]) : NetIoResult
  (stream-receive! stream view start count false limits true))

;: Peek one positive prefix or EOF without consuming queued bytes.
(define (tcp-stream-peek!
  [stream : (&mut stream TcpStream)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]
  [limits : NetLimits]) : NetIoResult
  (stream-receive! stream view start count true limits true))

;: Send a positive prefix under one finite budget.
(define (tcp-stream-write!
  [stream : (&mut stream TcpStream)]
  [view : (& view bytes)]
  [start : i64]
  [count : i64]
  [limits : NetLimits]) : NetIoResult
  (stream-send! stream view start count limits true))

;: Whole-buffer result retains completed bytes on every terminal condition.
(defstruct NetTransfer
  (count i64)
  (status NetStatus))

;: Internal whole-buffer loop, with one work/deadline/cancellation budget.
(unsafe
  (define (transfer
    [stream : (&mut stream TcpStream)]
    [address : i64]
    [count : i64]
    [writing? : bool]
    [limits : NetLimits]) : NetTransfer
    (let
      [completed : i64 0]
      [left : i64 limits.work]
      [status : NetStatus (Ok)]
      [done : bool false]
      (if (not (limits-valid? limits))
        (begin
          (set! status (Err (error (InvalidRange))))
          (set! done true))
        unit)
      (if (and (= count 0) (not done))
        (begin
          (set! status (claim! (&mut stream.owner) (Stream)))
          (set! done true))
        unit)
      (while (not done)
        (let
          [reply : NetIoAttempt
            (unsafe
              (io
                (&mut stream.owner)
                (Stream)
                (if writing?
                  (Write)
                  (Read))
                (+ address completed)
                (- count completed)
                (empty-address)
                limits
                true
                left))]
          [result : NetIoResult reply.result]
          (set! left reply.work-left)
          (set! completed (+ completed result.count))
          (match result.status
            [(Err failure)
              (set! status (Err failure))
              (set! done true)]
            [(Ok)
              (cond
                [(= completed count) (set! done true)]
                [result.eof?
                  (set! status (Err (error (UnexpectedEof))))
                  (set! done true)]
                [(<= result.count 0)
                  (set! status (Err (error (ZeroProgress))))
                  (set! done true)]
                [else unit])])))
      (NetTransfer completed status))))

;: Read the entire requested suffix, retaining count on early EOF or failure.
(define (tcp-stream-read-exact!
  [stream : (&mut stream TcpStream)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]
  [limits : NetLimits]) : NetTransfer
  (if (not (range-valid? (byte_buf.bytes-mut-length view) start count))
    (NetTransfer 0 (Err (error (InvalidRange))))
    (unsafe
      (transfer
        stream
        (+ (cast (ptr->int (byte_buf.bytes-mut-data view)) : i64) start)
        count
        false
        limits))))

;: Write only uncompleted positive-count suffixes, never retry zero progress.
(define (tcp-stream-write-all!
  [stream : (&mut stream TcpStream)]
  [view : (& view bytes)]
  [start : i64]
  [count : i64]
  [limits : NetLimits]) : NetTransfer
  (if (not (range-valid? (byte_buf.bytes-length view) start count))
    (NetTransfer 0 (Err (error (InvalidRange))))
    (unsafe
      (transfer
        stream
        (+ (cast (ptr->int (byte_buf.bytes-data view)) : i64) start)
        count
        true
        limits))))

;: UDP receive/peek handles exactly one datagram, including a zero-capacity
;: destination. Connected operations require a live peer; from-operations
;: require no peer, checked separately by the adapter before each transfer.
(define (udp-receive-operation!
  [socket : (&mut socket UdpSocket)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]
  [from? : bool]
  [peek? : bool]
  [limits : NetLimits]
  [wait? : bool]) : NetIoResult
  (if (or
    (not (range-valid? (byte_buf.bytes-mut-length view) start count))
    (> count datagram-max))
    (io-error (error (InvalidRange)))
    (unsafe
      (io
        (&mut socket.owner)
        (Datagram)
        (if from?
          (if peek?
            (PeekFrom)
            (ReceiveFrom))
          (if peek?
            (PeekDatagram)
            (Receive)))
        (+ (cast (ptr->int (byte_buf.bytes-mut-data view)) : i64) start)
        count
        (empty-address)
        limits
        wait?
        limits.work)).result))

;: UDP send never retries a short count, including zero for nonempty input.
(define (udp-send-operation!
  [socket : (&mut socket UdpSocket)]
  [view : (& view bytes)]
  [start : i64]
  [count : i64]
  [to? : bool]
  [destination : SocketAddr]
  [limits : NetLimits]
  [wait? : bool]) : NetIoResult
  (cond
    [(or
        (not (range-valid? (byte_buf.bytes-length view) start count))
        (> count datagram-max))
      (io-error (error (InvalidRange)))]
    [(and to? (not (status-ok? (validate-address destination))))
      (io-error (error (InvalidEndpoint)))]
    [else
      (unsafe
        (io
          (&mut socket.owner)
          (Datagram)
          (if to?
            (SendTo)
            (Send))
          (+ (cast (ptr->int (byte_buf.bytes-data view)) : i64) start)
          count
          destination
          limits
          wait?
          limits.work)).result]))

;: One connected UDP send attempt, plus a bounded live-peer metadata preflight.
(define (udp-try-send!
  [socket : (&mut socket UdpSocket)]
  [view : (& view bytes)]
  [start : i64]
  [count : i64]) : NetIoResult
  (udp-send-operation!
    socket
    view
    start
    count
    false
    (empty-address)
    (default-limits)
    false))

;: One unconnected UDP send-to attempt plus preflight.
(define (udp-try-send-to!
  [socket : (&mut socket UdpSocket)]
  [view : (& view bytes)]
  [start : i64]
  [count : i64]
  [destination : SocketAddr]) : NetIoResult
  (udp-send-operation!
    socket
    view
    start
    count
    true
    destination
    (default-limits)
    false))

;: One connected receive, where zero count is an empty or truncated datagram.
(define (udp-try-receive!
  [socket : (&mut socket UdpSocket)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]) : NetIoResult
  (udp-receive-operation!
    socket
    view
    start
    count
    false
    false
    (default-limits)
    false))

;: One connected nonconsuming UDP receive.
(define (udp-try-peek!
  [socket : (&mut socket UdpSocket)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]) : NetIoResult
  (udp-receive-operation!
    socket
    view
    start
    count
    false
    true
    (default-limits)
    false))

;: One unconnected receive publishing one complete peer endpoint.
(define (udp-try-receive-from!
  [socket : (&mut socket UdpSocket)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]) : NetIoResult
  (udp-receive-operation!
    socket
    view
    start
    count
    true
    false
    (default-limits)
    false))

;: One unconnected nonconsuming receive publishing one complete peer endpoint.
(define (udp-try-peek-from!
  [socket : (&mut socket UdpSocket)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]) : NetIoResult
  (udp-receive-operation!
    socket
    view
    start
    count
    true
    true
    (default-limits)
    false))

;: Wait-capable connected send with a single operation budget.
(define (udp-send!
  [socket : (&mut socket UdpSocket)]
  [view : (& view bytes)]
  [start : i64]
  [count : i64]
  [limits : NetLimits]) : NetIoResult
  (udp-send-operation!
    socket
    view
    start
    count
    false
    (empty-address)
    limits
    true))

;: Wait-capable unconnected send with a single operation budget.
(define (udp-send-to!
  [socket : (&mut socket UdpSocket)]
  [view : (& view bytes)]
  [start : i64]
  [count : i64]
  [destination : SocketAddr]
  [limits : NetLimits]) : NetIoResult
  (udp-send-operation! socket view start count true destination limits true))

;: Wait-capable connected receive, exactly one datagram.
(define (udp-receive!
  [socket : (&mut socket UdpSocket)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]
  [limits : NetLimits]) : NetIoResult
  (udp-receive-operation! socket view start count false false limits true))

;: Wait-capable connected peek, leaving the datagram queued.
(define (udp-peek!
  [socket : (&mut socket UdpSocket)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]
  [limits : NetLimits]) : NetIoResult
  (udp-receive-operation! socket view start count false true limits true))

;: Wait-capable unconnected receive with source endpoint.
(define (udp-receive-from!
  [socket : (&mut socket UdpSocket)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]
  [limits : NetLimits]) : NetIoResult
  (udp-receive-operation! socket view start count true false limits true))

;: Wait-capable unconnected peek with source endpoint.
(define (udp-peek-from!
  [socket : (&mut socket UdpSocket)]
  [view : (&mut view bytes)]
  [start : i64]
  [count : i64]
  [limits : NetLimits]) : NetIoResult
  (udp-receive-operation! socket view start count true true limits true))

;: Common checked control dispatch. No wait/retry for options/address/shutdown.
(define (control!
  [owner : (&mut owner SocketOwner)]
  [kind : SocketKind]
  [req : NetRequest]
  [limits : NetLimits]
  [wait? : bool]) : NetStep
  (cond
    [(not (limits-valid? limits)) (Failed (error (InvalidRange)))]
    [else
      (match (claim! owner kind)
        [(Err failure) (Failed failure)]
        [(Ok)
          (let
            [call : NetRequest req]
            (set!
              call.token
              (unsafe
                (ptr-read owner.state)).token)
            (unsafe
              (attempt owner.state call limits wait? limits.work)).step)])]))

;: Close consumes the effective owner before one adapter call, even on error.
(define (close-owner! [owner : (&mut owner SocketOwner)] [kind : SocketKind]) : NetStatus
  (match (claim! owner kind)
    [(Err failure) (Err failure)]
    [(Ok)
      (unsafe
        (state-close owner.state))]))

;: Explicit TCP stream cleanup; later lexical cleanup is harmless.
(define (tcp-stream-close! [stream : (&mut stream TcpStream)]) : NetStatus
  (close-owner! (&mut stream.owner) (Stream)))

;: Explicit TCP listener cleanup.
(define (tcp-listener-close! [listener : (&mut listener TcpListener)]) : NetStatus
  (close-owner! (&mut listener.owner) (Listener)))

;: Explicit UDP cleanup.
(define (udp-close! [socket : (&mut socket UdpSocket)]) : NetStatus
  (close-owner! (&mut socket.owner) (Datagram)))

;: Duplicate creates a distinct native cleanup owner over shared kernel state.
(define (duplicate! [owner : (&mut owner SocketOwner)] [kind : SocketKind]) : OwnerResult
  (let
    [step : NetStep
      (control! owner kind (request (Duplicate) kind -1) (default-limits) false)]
    (match step
      [(Created token)
        (let
          [current : SocketState
            (unsafe
              (ptr-read owner.state))]
          (if (and (>= token 0) (!= token current.token))
            (OwnerOk
              (unsafe
                (publish current.adapter kind current.family token)))
            (OwnerError (error (AdapterCorrupt)))))]
      [_ (OwnerError (step-error step))])))

;: Duplicate stream; byte queues, options, shutdown and pending error are shared.
(define (tcp-stream-duplicate! [stream : (&mut stream TcpStream)]) : TcpStreamResult
  (match (duplicate! (&mut stream.owner) (Stream))
    [(OwnerOk owner) (StreamOk (TcpStream owner))]
    [(OwnerError failure) (StreamError failure)]))

;: Duplicate listener; accept queue and options are shared.
(define (tcp-listener-duplicate! [listener : (&mut listener TcpListener)]) : TcpListenerResult
  (match (duplicate! (&mut listener.owner) (Listener))
    [(OwnerOk owner) (ListenerOk (TcpListener owner))]
    [(OwnerError failure) (ListenerError failure)]))

;: Duplicate UDP socket; serialize connect/options against all duplicate I/O.
(define (udp-duplicate! [socket : (&mut socket UdpSocket)]) : UdpSocketResult
  (match (duplicate! (&mut socket.owner) (Datagram))
    [(OwnerOk owner) (UdpOk (UdpSocket owner))]
    [(OwnerError failure) (UdpError failure)]))

;: Stream and peer publish together; cleanup owns the stream payload.
(defenum TcpAcceptResult
  (:cleanup cleanup-tcp-accept-result)
  (AcceptOk TcpStream (:owned) SocketAddr)
  (AcceptError NetError))

;: Accept metadata failure closes only the newly accepted owner.
(define (accept!
  [listener : (&mut listener TcpListener)]
  [limits : NetLimits]
  [wait? : bool]) : TcpAcceptResult
  (let
    [step : NetStep
      (control!
        (&mut listener.owner)
        (Listener)
        (request (Accept) (Listener) -1)
        limits
        wait?)]
    (match step
      [(Accepted token peer)
        (let
          [current : SocketState
            (unsafe
              (ptr-read listener.owner.state))]
          (if (and
            (>= token 0)
            (!= token current.token)
            (status-ok? (validate-address peer))
            (= (address-family peer) current.family))
            (AcceptOk
              (TcpStream
                (unsafe
                  (publish current.adapter (Stream) current.family token)))
              peer)
            (begin
              (if (!= token current.token)
                (abandon current.adapter (Stream) token)
                unit)
              (AcceptError (error (AdapterCorrupt))))))]
      [_ (AcceptError (step-error step))])))

;: One accept attempt, with no wait or interruption retry.
(define (tcp-listener-try-accept! [listener : (&mut listener TcpListener)]) : TcpAcceptResult
  (accept! listener (default-limits) false))

;: Accept under one finite cancellation/deadline/work budget.
(define (tcp-listener-accept!
  [listener : (&mut listener TcpListener)]
  [limits : NetLimits]) : TcpAcceptResult
  (accept! listener limits true))

;: Address metadata is returned atomically and revalidated before publication.
(define (socket-address!
  [owner : (&mut owner SocketOwner)]
  [kind : SocketKind]
  [peer? : bool]) : SocketAddrResult
  (let
    [step : NetStep
      (control!
        owner
        kind
        (request
          (if peer?
            (PeerAddress)
            (LocalAddress))
          kind
          -1)
        (default-limits)
        false)]
    (match step
      [(Endpoint address)
        (if (and
          (status-ok? (validate-address address))
          (=
            (address-family address)
            (unsafe
              (ptr-read owner.state)).family))
          (Address address)
          (AddressError (error (AdapterCorrupt))))]
      [_ (AddressError (step-error step))])))

;: Stream's assigned local endpoint, including an ephemeral port.
(define (tcp-stream-local-address! [stream : (&mut stream TcpStream)]) : SocketAddrResult
  (socket-address! (&mut stream.owner) (Stream) false))

;: Stream's concrete peer endpoint.
(define (tcp-stream-peer-address! [stream : (&mut stream TcpStream)]) : SocketAddrResult
  (socket-address! (&mut stream.owner) (Stream) true))

;: Listener's bound local endpoint.
(define (tcp-listener-local-address! [listener : (&mut listener TcpListener)]) : SocketAddrResult
  (socket-address! (&mut listener.owner) (Listener) false))

;: UDP local endpoint.
(define (udp-local-address! [socket : (&mut socket UdpSocket)]) : SocketAddrResult
  (socket-address! (&mut socket.owner) (Datagram) false))

;: UDP connected peer, or NotConnected.
(define (udp-peer-address! [socket : (&mut socket UdpSocket)]) : SocketAddrResult
  (socket-address! (&mut socket.owner) (Datagram) true))

;: UDP connect/reconnect may discard already queued datagrams. No disconnect
;: exists in v1; duplicate users externally serialize connect and I/O.
(define (udp-connect!
  [socket : (&mut socket UdpSocket)]
  [peer : SocketAddr]
  [limits : NetLimits]) : NetStatus
  (cond
    [(not (limits-valid? limits)) (Err (error (InvalidRange)))]
    [(not (status-ok? (validate-address peer))) (Err (error (InvalidEndpoint)))]
    [else
      (match (claim! (&mut socket.owner) (Datagram))
        [(Err failure) (Err failure)]
        [(Ok)
          (let
            [current : SocketState
              (unsafe
                (ptr-read socket.owner.state))]
            (if (!= current.family (address-family peer))
              (Err (error (UnsupportedAddressFamily)))
              (let
                [req : NetRequest
                  (request (ConnectDatagram) (Datagram) current.token)]
                (set! req.address peer)
                (step-status
                  (unsafe
                    (attempt socket.owner.state req limits true limits.work)).step))))])]))

;: Half-shutdown is independent of cleanup close. Adapters normalize repeated
;: already-effective shutdown to Complete and share the state with duplicates.
(define (tcp-stream-shutdown!
  [stream : (&mut stream TcpStream)]
  [how : Shutdown]) : NetStatus
  (let
    [req : NetRequest (request (ShutdownOp) (Stream) -1)]
    (set! req.shutdown how)
    (step-status
      (control! (&mut stream.owner) (Stream) req (default-limits) false))))

;: Returned option scalar or structured error. Pending errors use another sum.
(defenum NetOptionResult
  (Option i64)
  (OptionError NetError))

;: take-error clears shared pending error state, even through a duplicate.
(defenum NetPendingError
  (NoError)
  (SocketError NetError)
  (QueryError NetError))

;: Reject unsupported kind/family combinations before capability dispatch.
(define (option-valid
  [kind : SocketKind]
  [family : i64]
  [option : SocketOption]
  [value : i64]
  [set? : bool]) : NetStatus
  (match option
    [(Broadcast)
      (cond
        [(!= (kind-code kind) 3) (Err (error (UnsupportedCapability)))]
        [(!= family 4) (Err (error (UnsupportedAddressFamily)))]
        [(and set? (not (or (= value 0) (= value 1))))
          (Err (error (InvalidOption)))]
        [else (Ok)])]
    [(NoDelay)
      (cond
        [(!= (kind-code kind) 1) (Err (error (UnsupportedCapability)))]
        [(and set? (not (or (= value 0) (= value 1))))
          (Err (error (InvalidOption)))]
        [else (Ok)])]
    [(UnicastHopLimit)
      (if (and set? (or (< value 1) (> value 255)))
        (Err (error (InvalidOption)))
        (Ok))]
    [(TakeError)
      (if set?
        (Err (error (UnsupportedCapability)))
        (Ok))]))

;: Checked option operation. Getter corruption is detected by the same bounds.
(define (socket-option!
  [owner : (&mut owner SocketOwner)]
  [kind : SocketKind]
  [option : SocketOption]
  [value : i64]
  [set? : bool]) : NetOptionResult
  (match (if (match option
    [(TakeError) true]
    [_ false])
    (Err (error (UnsupportedCapability)))
    (claim! owner kind))
    [(Err failure) (OptionError failure)]
    [(Ok)
      (let
        [current : SocketState
          (unsafe
            (ptr-read owner.state))]
        (match (option-valid kind current.family option value set?)
          [(Err failure) (OptionError failure)]
          [(Ok)
            (let
              [req : NetRequest
                (request
                  (if set?
                    (SetOption)
                    (GetOption))
                  kind
                  current.token)]
              (set! req.option option)
              (set! req.value value)
              (let
                [step : NetStep
                  (unsafe
                    (attempt owner.state req (default-limits) false 1)).step]
                (match step
                  [(Complete)
                    (if set?
                      (Option value)
                      (OptionError (error (AdapterCorrupt))))]
                  [(OptionValue result)
                    (if (and
                      (not set?)
                      (status-ok?
                        (option-valid kind current.family option result true)))
                      (Option result)
                      (OptionError (error (AdapterCorrupt))))]
                  [_ (OptionError (step-error step))])))]))]))

;: Shared pending-error query, separate from option integers.
(define (take-error! [owner : (&mut owner SocketOwner)] [kind : SocketKind]) : NetPendingError
  (let
    [step : NetStep
      (control! owner kind (request (GetOption) kind -1) (default-limits) false)]
    (match step
      [(Complete) (NoError)]
      [(PendingError failure) (SocketError (checked-error failure))]
      [_ (QueryError (step-error step))])))

;: Stream option access (NoDelay and UnicastHopLimit).
(define (tcp-stream-get-option!
  [stream : (&mut stream TcpStream)]
  [option : SocketOption]) : NetOptionResult
  (socket-option! (&mut stream.owner) (Stream) option 0 false))

;: Stream option mutation.
(define (tcp-stream-set-option!
  [stream : (&mut stream TcpStream)]
  [option : SocketOption]
  [value : i64]) : NetOptionResult
  (socket-option! (&mut stream.owner) (Stream) option value true))

;: Listener option access (UnicastHopLimit).
(define (tcp-listener-get-option!
  [listener : (&mut listener TcpListener)]
  [option : SocketOption]) : NetOptionResult
  (socket-option! (&mut listener.owner) (Listener) option 0 false))

;: Listener option mutation.
(define (tcp-listener-set-option!
  [listener : (&mut listener TcpListener)]
  [option : SocketOption]
  [value : i64]) : NetOptionResult
  (socket-option! (&mut listener.owner) (Listener) option value true))

;: UDP option access (Broadcast and UnicastHopLimit).
(define (udp-get-option!
  [socket : (&mut socket UdpSocket)]
  [option : SocketOption]) : NetOptionResult
  (socket-option! (&mut socket.owner) (Datagram) option 0 false))

;: UDP option mutation.
(define (udp-set-option!
  [socket : (&mut socket UdpSocket)]
  [option : SocketOption]
  [value : i64]) : NetOptionResult
  (socket-option! (&mut socket.owner) (Datagram) option value true))

;: Consume shared stream pending error.
(define (tcp-stream-take-error! [stream : (&mut stream TcpStream)]) : NetPendingError
  (take-error! (&mut stream.owner) (Stream)))

;: Consume shared listener pending error.
(define (tcp-listener-take-error! [listener : (&mut listener TcpListener)]) : NetPendingError
  (take-error! (&mut listener.owner) (Listener)))

;: Consume shared UDP pending error.
(define (udp-take-error! [socket : (&mut socket UdpSocket)]) : NetPendingError
  (take-error! (&mut socket.owner) (Datagram)))

;: Explicit owned-buffer read convenience; allocated bytes are never text.
(defstruct NetOwnedRead
  (buffer byte_buf.ByteBuf)
  (result NetIoResult))

;: Allocate at most one stream chunk and read into it. The live length is the
;: committed count, including committed-metadata failure; caller owns the bytes.
(define (tcp-stream-read-owned!
  [stream : (&mut stream TcpStream)]
  [capacity : i64]
  [limits : NetLimits]) : NetOwnedRead
  (if (or (< capacity 0) (> capacity stream-transfer-max))
    (NetOwnedRead (byte_buf.new) (io-error (error (InvalidRange))))
    (let
      [buffer : byte_buf.ByteBuf
        (byte_buf.ByteBuf (__tl_make-array u8 capacity) capacity)]
      [result : NetIoResult
        (tcp-stream-read!
          stream
          (byte_buf.as-mut-bytes (&mut buffer))
          0
          capacity
          limits)]
      (set! buffer.len result.count)
      (NetOwnedRead buffer result))))

;: Explicit ByteBuf write convenience; byte storage is borrowed, no text copy.
(define (tcp-stream-write-buffer!
  [stream : (&mut stream TcpStream)]
  [buffer : (& buffer byte_buf.ByteBuf)]
  [limits : NetLimits]) : NetTransfer
  (tcp-stream-write-all!
    stream
    (byte_buf.as-bytes buffer)
    0
    (byte_buf.len buffer)
    limits))

;: Explicit owned UDP receive/peek convenience. One bounded allocation, live
;: length equal to committed count; zero capacity still dispatches a datagram.
(define (udp-receive-owned!
  [socket : (&mut socket UdpSocket)]
  [capacity : i64]
  [from? : bool]
  [peek? : bool]
  [limits : NetLimits]) : NetOwnedRead
  (if (or (< capacity 0) (> capacity datagram-max))
    (NetOwnedRead (byte_buf.new) (io-error (error (InvalidRange))))
    (let
      [buffer : byte_buf.ByteBuf
        (byte_buf.ByteBuf (__tl_make-array u8 capacity) capacity)]
      [result : NetIoResult
        (udp-receive-operation!
          socket
          (byte_buf.as-mut-bytes (&mut buffer))
          0
          capacity
          from?
          peek?
          limits
          true)]
      (set! buffer.len result.count)
      (NetOwnedRead buffer result))))