;# Target-neutral socket conformance fake. No host calls, addresses or sleeps.
;# Contexts and generation-tagged tokens are checked with safe array accesses.
;# Script codes: >=0 explicit count, -1 blocked, -2 interrupted, -3 host error,
;# -4 overcount, -5 short returned buffer, -6 committed metadata failure,
;# -7 nonempty zero send, -8 invalid source, -9 host truncation. Default -1000
;# uses the shared queue. Script queues repeat their final entry when exhausted.
(import stdlib.byte_buf)
(import stdlib.net)
(import stdlib.net.ip as ip)
(import stdlib.local_ipc)

;: Maximum independent fixtures in one process.
(define capacity : i64
  128)

;: Checked integer slots per fixture.
(define row-size : i64
  2048)

;: Process-lifetime fixture storage, allocated once.
(define table : (__tl_dyn-array i64)
  (__tl_make-array i64 (* capacity row-size)))

;: Number of issued fixture contexts.
(define contexts : i64
  0)

;: Maximum simultaneous cleanup owners per fixture.
(define handles-per-context : i64
  16)

;: Stable operation index, also used by trace/script accessors.
(define (operation-code [operation : net.NetOperation]) : i64
  (match operation
    [(Create) 0]
    [(FinishConnect) 1]
    [(Accept) 2]
    [(Duplicate) 3]
    [(Close) 4]
    [(LocalAddress) 5]
    [(PeerAddress) 6]
    [(Read) 7]
    [(Peek) 8]
    [(Write) 9]
    [(Send) 10]
    [(Receive) 11]
    [(PeekDatagram) 12]
    [(SendTo) 13]
    [(ReceiveFrom) 14]
    [(PeekFrom) 15]
    [(ConnectDatagram) 16]
    [(Preflight) 17]
    [(WaitRead) 18]
    [(WaitWrite) 19]
    [(ShutdownOp) 20]
    [(GetOption) 21]
    [(SetOption) 22]))

;: Slot access traps safely for a forged context, never interprets it as memory.
(define (get [context : i64] [slot : i64]) : i64
  (if (or (< context 0) (>= context contexts) (< slot 0) (>= slot row-size))
    (array-ref table (* capacity row-size))
    (array-ref table (+ (* context row-size) slot))))

;: Write one checked fixture slot.
(define (put! [context : i64] [slot : i64] [value : i64]) : unit
  (if (or (< context 0) (>= context contexts) (< slot 0) (>= slot row-size))
    (set! (array-ref table (* capacity row-size)) value)
    (set! (array-ref table (+ (* context row-size) slot)) value)))

;: Virtual clock and optional step per host call, plus scripted counters.
(define (new) : i64
  (let
    [context : i64 contexts]
    (set! contexts (+ contexts 1))
    (put! context 0 0)
    (put! context 1 0)
    (put! context 2 0)
    context))

;: Read the virtual monotonic clock without advancing it.
(define (now-ms [context : i64]) : i64
  (get context 0))

;: Configure clock value and increment per simulated host call.
(define (set-clock! [context : i64] [now : i64] [step : i64]) : unit
  (put! context 0 now)
  (put! context 1 step))

;: Host calls (including metadata preflight) and per-operation dispatch counts.
(define (calls [context : i64] [operation : net.NetOperation]) : i64
  (get context (+ 32 (operation-code operation))))

;: Total simulated host calls after capability validation.
(define (host-calls [context : i64]) : i64
  (get context 2))

;: Largest requested readiness slice.
(define (max-wait [context : i64]) : i64
  (get context 3))

;: Most recent transfer request length.
(define (last-size [context : i64]) : i64
  (get context 4))

;: Sum of bytes actually sent, exposing suffix retransmission errors.
(define (written-sum [context : i64]) : i64
  (get context 5))

;: Override getter results with an out-of-range scalar; zero disables it.
(define (set-corrupt-option! [context : i64] [value : i64]) : unit
  (put! context 6 value))

;: Install the last created socket group's shared pending error.
(define (set-pending-error! [context : i64] [code : i64]) : unit
  (let
    [slot : i64 (% (last-token context) handles-per-context)]
    [group : i64 (get context (handle-slot slot 2))]
    (put! context (group-slot group 9) code)))

;: Set one deterministic operation script entry; at most 32 entries per queue.
(define (script!
  [context : i64]
  [operation : net.NetOperation]
  [index : i64]
  [code : i64]) : unit
  (let
    [base : i64 (+ 128 (* (operation-code operation) 36))]
    (if (or (< index 0) (>= index 32))
      (put! context row-size code)
      (begin
        (put! context (+ base 4 index) code)
        (if (>= index (get context base))
          (put! context base (+ index 1))
          unit)))))

;: Consume the next scripted step, repeating the last when exhausted.
(define (next-step [context : i64] [operation : net.NetOperation]) : i64
  (let
    [base : i64 (+ 128 (* (operation-code operation) 36))]
    [length : i64 (get context base)]
    [index : i64 (get context (+ base 1))]
    (if (= length 0)
      -1000
      (begin
        (put! context (+ base 1) (+ index 1))
        (get
          context
          (+
            base
            4
            (if (< index length)
              index
              (- length 1))))))))

;: Handle slots start at 1024; group slots at 1280. Each handle owns one
;: generation, each duplicate points to the same group (queues/options/state).
(define (handle-slot [slot : i64] [field : i64]) : i64
  (+ 1024 (* slot 8) field))

;: Slot for shared kernel state, separate from reusable descriptor slots.
(define (group-slot [group : i64] [field : i64]) : i64
  (+ 1280 (* group 16) field))

;: Decode and validate token before every simulated host dispatch.
(define (token-slot [context : i64] [token : i64] [kind : net.SocketKind]) : i64
  (if (< token 0)
    -1
    (let
      [slot : i64 (% token handles-per-context)]
      [generation : i64 (/ token handles-per-context)]
      (if (and
        (= (get context (handle-slot slot 0)) 1)
        (= (get context (handle-slot slot 1)) generation)
        (= (get context (handle-slot slot 3)) (net.kind-code kind)))
        slot
        -1))))

;: Issue a new independent token, reusing a closed slot with a fresh generation.
(define (allocate!
  [context : i64]
  [kind : net.SocketKind]
  [family : i64]
  [existing-group : i64]) : i64
  (let
    [slot : i64 0]
    (while (and
      (< slot handles-per-context)
      (= (get context (handle-slot slot 0)) 1))
      (set! slot (+ slot 1)))
    (if (= slot handles-per-context)
      -1
      (let
        [generation : i64 (+ (get context (handle-slot slot 1)) 1)]
        [group : i64
          (if (>= existing-group 0)
            existing-group
            0)]
        (if (< existing-group 0)
          (while (and
            (< group handles-per-context)
            (> (get context (group-slot group 8)) 0))
            (set! group (+ group 1)))
          unit)
        (put! context (handle-slot slot 0) 1)
        (put! context (handle-slot slot 1) generation)
        (put! context (handle-slot slot 2) group)
        (put! context (handle-slot slot 3) (net.kind-code kind))
        (put! context (handle-slot slot 4) family)
        (put!
          context
          (group-slot group 8)
          (+ (get context (group-slot group 8)) 1))
        (if (< existing-group 0)
          (begin
            (put!
              context
              (group-slot group 0)
              (if (= (net.kind-code kind) 1)
                1
                0))
            (put! context (group-slot group 1) 8)
            (put! context (group-slot group 2) 0)
            (put! context (group-slot group 3) 64)
            (put! context (group-slot group 4) 0)
            (put! context (group-slot group 5) 0)
            (put! context (group-slot group 6) 0)
            (put! context (group-slot group 7) 0)
            (put! context (group-slot group 9) 0))
          unit)
        (+ (* generation handles-per-context) slot)))))

;: Set queued payload length; -1 means no datagram available, 0 empty datagram.
(define (queue! [context : i64] [token : i64] [length : i64]) : unit
  (let
    [slot : i64 (% token handles-per-context)]
    [group : i64 (get context (handle-slot slot 2))]
    (put! context (group-slot group 1) length)
    (put! context (group-slot group 2) 0)))

;: Last created token, exposed for generation/corrupt-token conformance probes.
(define (last-token [context : i64]) : i64
  (get context 8))

;: Build a reply returning the owned transfer buffer.
(define (reply [step : net.NetStep] [buffer : byte_buf.ByteBuf] [calls : i64]) : net.NetReply
  (net.NetReply step buffer calls))

;: One simulated host failure.
(define (failure [kind : net.NetErrorKind] [buffer : byte_buf.ByteBuf]) : net.NetReply
  (reply (net.Failed (net.error kind)) buffer 1))

;: Validation-only rejection has no host call, but still consumes dispatch work.
(define (rejection [kind : net.NetErrorKind] [buffer : byte_buf.ByteBuf]) : net.NetReply
  (reply (net.Failed (net.error kind)) buffer 0))

;: Validate the whole value-only capability request, even when a caller
;: bypasses the public wrappers. An unavailable operation never reaches host.
(define (validate-request [req : net.NetRequest] [family : i64] [length : i64]) : net.NetStatus
  (let
    [kind : i64 (net.kind-code req.kind)]
    (cond
      [(and
          (net.one-data-call? req.operation)
          (or
            (and (= kind 3) (> length net.datagram-max))
            (and (= kind 1) (> length net.stream-transfer-max))))
        (net.Err (net.error (net.InvalidRange)))]
      [else
        (match req.operation
          [(Read)
            (if (= kind 1)
              (net.Ok)
              (net.Err (net.error (net.UnsupportedCapability))))]
          [(Peek)
            (if (= kind 1)
              (net.Ok)
              (net.Err (net.error (net.UnsupportedCapability))))]
          [(Write)
            (if (= kind 1)
              (net.Ok)
              (net.Err (net.error (net.UnsupportedCapability))))]
          [(Accept)
            (if (= kind 2)
              (net.Ok)
              (net.Err (net.error (net.UnsupportedCapability))))]
          [(ShutdownOp)
            (if (= kind 1)
              (net.Ok)
              (net.Err (net.error (net.UnsupportedCapability))))]
          [(FinishConnect)
            (if (= kind 1)
              (net.Ok)
              (net.Err (net.error (net.UnsupportedCapability))))]
          [(GetOption)
            (net.option-valid req.kind family req.option req.value false)]
          [(SetOption)
            (net.option-valid req.kind family req.option req.value true)]
          [(WaitRead)
            (if (and (> req.value 0) (<= req.value local_ipc.wait-slice-ms))
              (net.Ok)
              (net.Err (net.error (net.InvalidRange))))]
          [(WaitWrite)
            (if (and (> req.value 0) (<= req.value local_ipc.wait-slice-ms))
              (net.Ok)
              (net.Err (net.error (net.InvalidRange))))]
          [(Create)
            (if (and (= kind 2) (!= req.value net.listener-backlog))
              (net.Err (net.error (net.InvalidOption)))
              (net.validate-address req.address))]
          [_
            (if (and
              (not (= kind 3))
              (or
                (net.one-data-call? req.operation)
                (match req.operation
                  [(Preflight) true]
                  [(ConnectDatagram) true]
                  [_ false])))
              (net.Err (net.error (net.UnsupportedCapability)))
              (match req.operation
                [(SendTo)
                  (if (!= (net.address-family req.address) family)
                    (net.Err (net.error (net.UnsupportedAddressFamily)))
                    (net.validate-address req.address))]
                [(ConnectDatagram)
                  (if (!= (net.address-family req.address) family)
                    (net.Err (net.error (net.UnsupportedAddressFamily)))
                    (net.validate-address req.address))]
                [(Preflight)
                  (if (or (= req.value 0) (= req.value 1))
                    (net.Ok)
                    (net.Err (net.error (net.InvalidOption))))]
                [_ (net.Ok)]))])])))

;: Complete endpoint metadata in the group's canonical address family.
(define (endpoint [family : i64]) : net.SocketAddr
  (if (= family 6)
    (net.V6 (net.SocketAddrV6 (ip.ipv6 0 0 0 0 0 0 0 1) 0 0))
    (net.empty-address)))

;: One transfer uses scripted count or the shared deterministic byte queue.
(define (data!
  [context : i64]
  [req : net.NetRequest]
  [buffer : byte_buf.ByteBuf]
  [slot : i64]
  [code : i64]) : net.NetReply
  (let
    [group : i64 (get context (handle-slot slot 2))]
    [udp? : bool (= (net.kind-code req.kind) 3)]
    [read? : bool (net.reading? req.operation)]
    [peek? : bool
      (match req.operation
        [(Peek) true]
        [(PeekDatagram) true]
        [(PeekFrom) true]
        [_ false])]
    [from? : bool
      (match req.operation
        [(ReceiveFrom) true]
        [(PeekFrom) true]
        [_ false])]
    [length : i64 buffer.len]
    [queued : i64 (get context (group-slot group 1))]
    [position : i64 (get context (group-slot group 2))]
    [available : i64
      (if udp?
        queued
        (- queued position))]
    [count : i64
      (if (>= code 0)
        code
        (if read?
          (if (< available length)
            available
            length)
          length))]
    [truncated? : bool (and udp? read? (> queued length))]
    [returned : byte_buf.ByteBuf buffer]
    (put! context 4 length)
    (cond
      [(= code -1) (reply (net.Blocked) returned 1)]
      [(= code -2) (reply (net.Interrupt) returned 1)]
      [(= code -3)
        (reply
          (net.Failed (net.NetError (net.HostFailure) (net.WindowsWsa) 10054))
          returned
          1)]
      [(and udp? read? (< queued 0) (= code -1000))
        (reply (net.Blocked) returned 1)]
      [else
        (cond
          [(= code -4) (set! count (+ length 1))]
          [(= code -7) (set! count 0)]
          [(= code -9)
            (set! count length)
            (set! truncated? true)]
          [else unit])
        (if (and read? (>= count 0) (<= count length))
          (let
            [index : i64 0]
            (while (< index count)
              (set!
                returned
                (byte_buf.set!
                  returned
                  index
                  (cast (% (+ position index 1) 256) : u8)))
              (set! index (+ index 1))))
          unit)
        (if (and (not read?) (>= count 0) (<= count length))
          (let
            [index : i64 0]
            [sum : i64 (get context 5)]
            (while (< index count)
              (set! sum (+ sum (cast (byte_buf.ref (& returned) index) : i64)))
              (set! index (+ index 1)))
            (put! context 5 sum))
          unit)
        (if (and read? (not peek?))
          (if udp?
            (put! context (group-slot group 1) -1)
            (put! context (group-slot group 2) (+ position count)))
          unit)
        (if (= code -5)
          (set! returned (byte_buf.new))
          unit)
        (cond
          [(= code -6)
            (reply (net.MetadataFailure count truncated?) returned 1)]
          [(and from? (= code -8))
            (reply
              (net.DatagramFrom
                count
                truncated?
                (net.V4 (net.SocketAddrV4 (ip.ipv4 127 0 0 1) -1)))
              returned
              1)]
          [from?
            (reply
              (net.DatagramFrom
                count
                truncated?
                (endpoint (get context (handle-slot slot 4))))
              returned
              1)]
          [else (reply (net.Data count truncated?) returned 1)])])))

;: Every metadata call and transfer appears separately in the trace. Invalid
;: tokens, kinds and arguments fail before the simulated host-call count moves.
(define (dispatch
  [context : i64]
  [req : net.NetRequest]
  [buffer : byte_buf.ByteBuf]) : net.NetReply
  (let
    [op : i64 (operation-code req.operation)]
    [slot : i64 (token-slot context req.token req.kind)]
    [create? : bool (= op 0)]
    [stop : net.NetStatus
      (if (net.limits-valid? req.limits)
        (net.stop-reason (adapter context) req.limits req.limits.work)
        (net.Err (net.error (net.InvalidRange))))]
    (put! context (+ 32 op) (+ (calls context req.operation) 1))
    (cond
      [(or
          (not (net.range-valid? (array-length buffer.slots) 0 buffer.len))
          (not (net.limits-valid? req.limits)))
        (rejection (net.InvalidRange) buffer)]
      [(and (not create?) (< slot 0)) (rejection (net.Closed) buffer)]
      [(and create? (not (net.status-ok? (net.validate-address req.address))))
        (rejection (net.InvalidEndpoint) buffer)]
      [(not
          (net.status-ok?
            (validate-request
              req
              (if create?
                (net.address-family req.address)
                (get context (handle-slot slot 4)))
              buffer.len)))
        (reply
          (net.Failed
            (match (validate-request
              req
              (if create?
                (net.address-family req.address)
                (get context (handle-slot slot 4)))
              buffer.len)
              [(Err error) error]
              [_ (net.error (net.AdapterCorrupt))]))
          buffer
          0)]
      [(not (net.status-ok? stop))
        (reply
          (net.Failed
            (match stop
              [(Err error) error]
              [_ (net.error (net.AdapterCorrupt))]))
          buffer
          0)]
      [else
        (put! context 2 (+ (host-calls context) 1))
        (put! context 0 (+ (get context 0) (get context 1)))
        (let
          [code : i64 (next-step context req.operation)]
          [group : i64
            (if create?
              0
              (get context (handle-slot slot 2)))]
          (cond
            [(= code -1) (reply (net.Blocked) buffer 1)]
            [(= code -2) (reply (net.Interrupt) buffer 1)]
            [(= code -3) (failure (net.HostFailure) buffer)]
            [else
              (match req.operation
                [(Create)
                  (let
                    [token : i64
                      (allocate!
                        context
                        req.kind
                        (net.address-family req.address)
                        -1)]
                    (put! context 8 token)
                    (reply
                      (if (= code 1)
                        (net.PendingConnect token)
                        (net.Created token))
                      buffer
                      1))]
                [(FinishConnect) (reply (net.Complete) buffer 1)]
                [(Close)
                  (put! context (handle-slot slot 0) 0)
                  (put!
                    context
                    (group-slot group 8)
                    (- (get context (group-slot group 8)) 1))
                  (reply (net.Complete) buffer 1)]
                [(Duplicate)
                  (reply
                    (net.Created
                      (allocate!
                        context
                        req.kind
                        (get context (handle-slot slot 4))
                        group))
                    buffer
                    1)]
                [(Accept)
                  (let
                    [token : i64
                      (allocate!
                        context
                        (net.Stream)
                        (get context (handle-slot slot 4))
                        -1)]
                    [address : net.SocketAddr
                      (endpoint (get context (handle-slot slot 4)))]
                    (if (= code -8)
                      (set!
                        address
                        (net.V4 (net.SocketAddrV4 (ip.ipv4 0 0 0 0) -1)))
                      unit)
                    (reply (net.Accepted token address) buffer 1))]
                [(LocalAddress)
                  (reply
                    (net.Endpoint (endpoint (get context (handle-slot slot 4))))
                    buffer
                    1)]
                [(PeerAddress)
                  (if (= (get context (group-slot group 0)) 0)
                    (failure (net.NotConnected) buffer)
                    (reply
                      (net.Endpoint
                        (endpoint (get context (handle-slot slot 4))))
                      buffer
                      1))]
                [(Preflight)
                  (if (= req.value (get context (group-slot group 0)))
                    (reply (net.Complete) buffer 1)
                    (failure
                      (if (= req.value 1)
                        (net.NotConnected)
                        (net.AlreadyConnected))
                      buffer))]
                [(ConnectDatagram)
                  (put! context (group-slot group 0) 1)
                  (put! context (group-slot group 1) -1)
                  (reply (net.Complete) buffer 1)]
                [(WaitRead)
                  (if (or (< req.value 1) (> req.value local_ipc.wait-slice-ms))
                    (failure (net.InvalidRange) buffer)
                    (begin
                      (if (> req.value (max-wait context))
                        (put! context 3 req.value)
                        unit)
                      (put! context 0 (+ (get context 0) req.value))
                      (reply (net.Complete) buffer 1)))]
                [(WaitWrite)
                  (if (or (< req.value 1) (> req.value local_ipc.wait-slice-ms))
                    (failure (net.InvalidRange) buffer)
                    (begin
                      (if (> req.value (max-wait context))
                        (put! context 3 req.value)
                        unit)
                      (put! context 0 (+ (get context 0) req.value))
                      (reply (net.Complete) buffer 1)))]
                [(ShutdownOp)
                  (match req.shutdown
                    [(ShutdownRead) (put! context (group-slot group 5) 1)]
                    [(ShutdownWrite) (put! context (group-slot group 6) 1)]
                    [(ShutdownBoth)
                      (put! context (group-slot group 5) 1)
                      (put! context (group-slot group 6) 1)])
                  (reply (net.Complete) buffer 1)]
                [(GetOption)
                  (match req.option
                    [(TakeError)
                      (let
                        [pending : i64 (get context (group-slot group 9))]
                        (put! context (group-slot group 9) 0)
                        (reply
                          (if (= pending 0)
                            (net.Complete)
                            (net.PendingError
                              (net.NetError
                                (net.HostFailure)
                                (net.LinuxErrno)
                                pending)))
                          buffer
                          1))]
                    [_
                      (reply
                        (net.OptionValue
                          (if (!= (get context 6) 0)
                            (get context 6)
                            (get
                              context
                              (group-slot
                                group
                                (match req.option
                                  [(UnicastHopLimit) 3]
                                  [(NoDelay) 4]
                                  [_ 7])))))
                        buffer
                        1)])]
                [(SetOption)
                  (put!
                    context
                    (group-slot
                      group
                      (match req.option
                        [(UnicastHopLimit) 3]
                        [(NoDelay) 4]
                        [_ 7]))
                    req.value)
                  (reply (net.Complete) buffer 1)]
                [_
                  (cond
                    [(and
                        (not (net.reading? req.operation))
                        (= (get context (group-slot group 6)) 1))
                      (failure (net.PeerClosed) buffer)]
                    [(and
                        (net.reading? req.operation)
                        (= (get context (group-slot group 5)) 1))
                      (reply (net.Data 0 false) buffer 1)]
                    [else (data! context req buffer slot code)])])]))])))

;: Checked capability using this fake's token table and virtual clock.
(define (adapter [context : i64]) : net.NetAdapter
  (net.NetAdapter context now-ms dispatch))
