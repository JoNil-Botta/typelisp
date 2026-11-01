;# Shared conformance cases. Platform leaves supply the same fixture hooks
;# using injected host-call scripts, then run their separate loopback cases.
;# No assertion depends on a platform's descriptor, errno or readiness ABI.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.net)
(import stdlib.net.ip)
(import stdlib.test)

;: Hooks describe deterministic injection and observation, never host policy.
(defstruct Fixture
  (adapter net.NetAdapter)
  (script (-> i64 net.NetOperation i64 i64 unit))
  (calls (-> i64 net.NetOperation i64))
  (clock (-> i64 i64 i64 unit))
  (queue (-> i64 i64 i64 unit))
  (last-token (-> i64 i64))
  (max-wait (-> i64 i64))
  (written-sum (-> i64 i64)))

(define (endpoint) : net.SocketAddr
  (net.V4 (net.SocketAddrV4 (ip.ipv4 127 0 0 1) 0)))

(define (buffer [size : i64]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf (byte_buf.ByteBuf (__tl_make-array u8 size) size)]
    [index : i64 0]
    (while (< index size)
      (set! out (byte_buf.set! out index (cast (% (+ index 1) 256) : u8)))
      (set! index (+ index 1)))
    out))

(define (open-stream [fixture : Fixture]) : net.TcpStream
  (match (net.tcp-stream-connect
    fixture.adapter
    (endpoint)
    (net.default-limits))
    [(StreamOk stream) stream]
    [(StreamError _) (io.panic "stream construction")]))

(define (open-listener [fixture : Fixture]) : net.TcpListener
  (match (net.tcp-listener-bind fixture.adapter (endpoint) (net.default-limits))
    [(ListenerOk listener) listener]
    [(ListenerError _) (io.panic "listener construction")]))

(define (open-udp [fixture : Fixture]) : net.UdpSocket
  (match (net.udp-bind fixture.adapter (endpoint) (net.default-limits))
    [(UdpOk socket) socket]
    [(UdpError _) (io.panic "UDP construction")]))

(define (kind [status : net.NetStatus]) : net.NetErrorKind
  (match status
    [(Ok) (net.Unavailable)]
    [(Err failure) failure.kind]))

(define (is-kind [status : net.NetStatus] [expected : net.NetErrorKind]) : bool
  (= (kind-code (kind status)) (kind-code expected)))

(define (kind-code [value : net.NetErrorKind]) : i64
  (match value
    [(InvalidEndpoint) 1]
    [(InvalidRange) 2]
    [(InvalidOption) 3]
    [(Unavailable) 4]
    [(PermissionDenied) 5]
    [(Busy) 6]
    [(TimedOut) 7]
    [(Canceled) 8]
    [(PeerClosed) 9]
    [(ResourceExhausted) 10]
    [(UnsupportedTarget) 11]
    [(UnsupportedAddressFamily) 12]
    [(UnsupportedCapability) 13]
    [(AdapterCorrupt) 14]
    [(Closed) 15]
    [(WorkExhausted) 16]
    [(HostFailure) 17]
    [(WouldBlock) 18]
    [(Interrupted) 19]
    [(ZeroProgress) 20]
    [(UnexpectedEof) 21]
    [(PartialDatagram) 22]
    [(CommittedMetadata) 23]
    [(NotConnected) 24]
    [(AlreadyConnected) 25]
    [(ConnectionRefused) 26]
    [(ConnectionReset) 27]
    [(AddressInUse) 28]
    [(AddressNotAvailable) 29]
    [(NetworkUnreachable) 30]
    [(BrokenPipe) 31]))

(define (assert-kind
  [status : net.NetStatus]
  [expected : net.NetErrorKind]
  [message : String]) : unit
  (test.assert-true
    (and (not (net.status-ok? status)) (is-kind status expected))
    message))

(define (canceled) : bool
  true)

(define (stream-zero-and-ranges [make-fixture : (-> Fixture)]) : unit
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 8)]
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (let
        [zero : net.NetIoResult
          (net.tcp-stream-try-read!
            (&mut stream)
            (byte_buf.as-mut-bytes (&mut bytes))
            0
            0)]
        (test.assert-true
          (and (= zero.count 0) (not zero.eof?) (net.status-ok? zero.status))
          "zero read is data")
        (test.assert-i64-eq
          (f.calls f.adapter.context (net.Read))
          0
          "zero read skips host"))
      (net.tcp-stream-try-peek!
        (&mut stream)
        (byte_buf.as-mut-bytes (&mut bytes))
        0
        0)
      (net.tcp-stream-try-write!
        (&mut stream)
        (byte_buf.as-bytes (& bytes))
        8
        0)
      (test.assert-i64-eq
        (f.calls f.adapter.context (net.Peek))
        0
        "zero peek skips host")
      (test.assert-i64-eq
        (f.calls f.adapter.context (net.Write))
        0
        "zero write skips host")
      (assert-kind
        (net.tcp-stream-try-read!
          (&mut stream)
          (byte_buf.as-mut-bytes (&mut bytes))
          7
          2).status
        (net.InvalidRange)
        "range precheck")
      (assert-kind
        (net.tcp-stream-try-write!
          (&mut stream)
          (byte_buf.as-bytes (& bytes))
          9223372036854775807
          1).status
        (net.InvalidRange)
        "overflow precheck")
      (net.tcp-stream-close! (&mut stream))
      (assert-kind
        (net.tcp-stream-try-read!
          (&mut stream)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          0).status
        (net.Closed)
        "closed zero read")
      (assert-kind
        (net.tcp-stream-write-all!
          (&mut stream)
          (byte_buf.as-bytes (& bytes))
          0
          0
          (net.default-limits)).status
        (net.Closed)
        "closed zero whole write"))
    (test.assert-i64-eq (f.calls f.adapter.context (net.Close)) 1 "one close")))

(define (stream-partial-and-eof [make-fixture : (-> Fixture)]) : unit
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 10)]
    (f.script f.adapter.context (net.Read) 0 3)
    (f.script f.adapter.context (net.Read) 1 0)
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (let
        [result : net.NetTransfer
          (net.tcp-stream-read-exact!
            (&mut stream)
            (byte_buf.as-mut-bytes (&mut bytes))
            0
            10
            (net.default-limits))]
        (test.assert-i64-eq result.count 3 "early EOF retains count")
        (assert-kind result.status (net.UnexpectedEof) "early EOF kind"))
      (test.assert-i64-eq
        (f.calls f.adapter.context (net.Read))
        2
        "no EOF spin")))
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 10)]
    (f.script f.adapter.context (net.Write) 0 3)
    (f.script f.adapter.context (net.Write) 1 7)
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (let
        [result : net.NetTransfer
          (net.tcp-stream-write-all!
            (&mut stream)
            (byte_buf.as-bytes (& bytes))
            0
            10
            (net.default-limits))]
        (test.assert-true
          (and (= result.count 10) (net.status-ok? result.status))
          "partial whole write")
        (test.assert-i64-eq
          (f.written-sum f.adapter.context)
          55
          "only uncompleted suffix sent"))))
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 10)]
    (f.script f.adapter.context (net.Write) 0 3)
    (f.script f.adapter.context (net.Write) 1 0)
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (let
        [result : net.NetTransfer
          (net.tcp-stream-write-all!
            (&mut stream)
            (byte_buf.as-bytes (& bytes))
            0
            10
            (net.default-limits))]
        (test.assert-i64-eq result.count 3 "zero send retains prior count")
        (assert-kind result.status (net.ZeroProgress) "zero send stops"))
      (test.assert-i64-eq
        (f.calls f.adapter.context (net.Write))
        2
        "no zero-send spin"))))

(define (stream-retry-and-budgets [make-fixture : (-> Fixture)]) : unit
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 8)]
    (f.script f.adapter.context (net.Read) 0 -2)
    (f.script f.adapter.context (net.Read) 1 -1)
    (f.script f.adapter.context (net.Read) 2 2)
    (f.script f.adapter.context (net.WaitRead) 0 -2)
    (f.script f.adapter.context (net.WaitRead) 1 -1)
    (f.script f.adapter.context (net.WaitRead) 2 0)
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (let
        [result : net.NetIoResult
          (net.tcp-stream-read!
            (&mut stream)
            (byte_buf.as-mut-bytes (&mut bytes))
            0
            8
            (net.default-limits))]
        (test.assert-i64-eq result.count 2 "retry returns positive progress")
        (test.assert-i64-eq
          (f.calls f.adapter.context (net.Read))
          3
          "bounded data retries")
        (test.assert-i64-eq
          (f.calls f.adapter.context (net.WaitRead))
          3
          "bounded interrupted/spurious waits")
        (test.assert-true
          (<= (f.max-wait f.adapter.context) 100)
          "no unbounded wait"))))
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 8)]
    (f.script f.adapter.context (net.Read) 0 -2)
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (assert-kind
        (net.tcp-stream-try-read!
          (&mut stream)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          8).status
        (net.Interrupted)
        "try interrupted")
      (test.assert-i64-eq
        (f.calls f.adapter.context (net.Read))
        1
        "try never retries")
      (assert-kind
        (net.tcp-stream-read!
          (&mut stream)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          8
          (net.NetLimits (net.NoDeadline) net.never-canceled 3)).status
        (net.WorkExhausted)
        "finite retry budget")
      (test.assert-i64-eq
        (f.calls f.adapter.context (net.Read))
        4
        "work dispatch count")
      (assert-kind
        (net.tcp-stream-read!
          (&mut stream)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          8
          (net.NetLimits (net.Deadline 0) canceled 1)).status
        (net.Canceled)
        "cancel beats expired deadline")
      (assert-kind
        (net.tcp-stream-read!
          (&mut stream)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          8
          (net.NetLimits (net.Deadline 0) net.never-canceled 0)).status
        (net.TimedOut)
        "deadline beats work")
      (assert-kind
        (net.tcp-stream-read!
          (&mut stream)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          8
          (net.NetLimits (net.Deadline -1) net.never-canceled 8)).status
        (net.InvalidRange)
        "negative deadline precheck")
      (test.assert-i64-eq
        (f.calls f.adapter.context (net.Read))
        4
        "prechecks skip adapter"))))

(define (stream-peek-duplicate-shutdown [make-fixture : (-> Fixture)]) : unit
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 4)]
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (with
        ([other
            (match (net.tcp-stream-duplicate! (&mut stream))
              [(StreamOk value) value]
              [_ (io.panic "duplicate")])
            net.cleanup-tcp-stream])
        (net.tcp-stream-try-peek!
          (&mut stream)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          4)
        (test.assert-i64-eq
          (cast (byte_buf.ref (& bytes) 0) : i64)
          1
          "peek sees front")
        (net.tcp-stream-try-read!
          (&mut other)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          4)
        (test.assert-i64-eq
          (cast (byte_buf.ref (& bytes) 0) : i64)
          1
          "peek did not consume")
        (net.tcp-stream-try-read!
          (&mut stream)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          4)
        (test.assert-i64-eq
          (cast (byte_buf.ref (& bytes) 0) : i64)
          5
          "duplicate shares queue")
        (net.tcp-stream-set-option! (&mut stream) (net.NoDelay) 1)
        (test.assert-i64-eq
          (match (net.tcp-stream-get-option! (&mut other) (net.NoDelay))
            [(Option value) value]
            [_ -1])
          1
          "duplicate shares options")
        (net.tcp-stream-shutdown! (&mut stream) (net.ShutdownWrite))
        (test.assert-true
          (net.status-ok?
            (net.tcp-stream-shutdown! (&mut other) (net.ShutdownWrite)))
          "repeat shutdown normalized")
        (assert-kind
          (net.tcp-stream-try-write!
            (&mut other)
            (byte_buf.as-bytes (& bytes))
            0
            4).status
          (net.PeerClosed)
          "duplicate shares half-shutdown")
        (net.tcp-stream-close! (&mut stream))
        (test.assert-true
          (net.status-ok?
            (net.tcp-stream-try-read!
              (&mut other)
              (byte_buf.as-mut-bytes (&mut bytes))
              0
              4).status)
          "close leaves duplicate usable")))
    (test.assert-i64-eq
      (f.calls f.adapter.context (net.Close))
      2
      "independent duplicate cleanup")))

(define (owners-and-accept [make-fixture : (-> Fixture)]) : unit
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 4)]
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (with
        ([copy (net.TcpStream stream.owner) net.cleanup-tcp-stream])
        (net.tcp-stream-try-read!
          (&mut stream)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          4)
        (assert-kind
          (net.tcp-stream-close! (&mut copy))
          (net.Closed)
          "stale owner cannot close")
        (assert-kind
          (net.tcp-stream-try-read!
            (&mut copy)
            (byte_buf.as-mut-bytes (&mut bytes))
            0
            4).status
          (net.Closed)
          "stale owner cannot read")))
    (test.assert-i64-eq
      (f.calls f.adapter.context (net.Read))
      1
      "stale dispatch rejected")
    (test.assert-i64-eq
      (f.calls f.adapter.context (net.Close))
      1
      "stale cleanup skipped"))
  (let
    [f : Fixture (make-fixture)]
    (f.script f.adapter.context (net.Accept) 0 -8)
    (with
      ([listener (open-listener f) net.cleanup-tcp-listener])
      (match (net.tcp-listener-try-accept! (&mut listener))
        [(AcceptError failure)
          (test.assert-i64-eq
            (kind-code failure.kind)
            (kind-code (net.AdapterCorrupt))
            "invalid accept metadata")]
        [(AcceptOk stream _)
          (net.cleanup-tcp-stream stream)
          (io.panic "bad peer published")])
      (test.assert-i64-eq
        (f.calls f.adapter.context (net.Close))
        1
        "bad accepted owner closed")
      (f.script f.adapter.context (net.Accept) 1 0)
      (match (net.tcp-listener-try-accept! (&mut listener))
        [(AcceptOk stream _) (net.cleanup-tcp-stream stream)]
        [_ (io.panic "listener remains usable")]))
    (test.assert-i64-eq
      (f.calls f.adapter.context (net.Close))
      3
      "accepted/listener ownership"))
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 4)]
    (with
      ([listener (open-listener f) net.cleanup-tcp-listener])
      (with
        ([wrong (net.TcpStream listener.owner) net.cleanup-tcp-stream])
        (assert-kind
          (net.tcp-stream-try-read!
            (&mut wrong)
            (byte_buf.as-mut-bytes (&mut bytes))
            0
            4).status
          (net.InvalidOption)
          "cross-kind rewrap")))
    (test.assert-i64-eq
      (f.calls f.adapter.context (net.Read))
      0
      "kind check before dispatch")
    (test.assert-i64-eq
      (f.calls f.adapter.context (net.Close))
      1
      "rewrap still one cleanup")))

(define (udp-datagrams [make-fixture : (-> Fixture)]) : unit
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 4)]
    (with
      ([socket (open-udp f) net.cleanup-udp-socket])
      (let
        [token : i64 (f.last-token f.adapter.context)]
        (f.queue f.adapter.context token 0)
        (let
          [zero : net.NetIoResult
            (net.udp-try-receive-from!
              (&mut socket)
              (byte_buf.as-mut-bytes (&mut bytes))
              0
              4)]
          (test.assert-true
            (and
              (= zero.count 0)
              (not zero.eof?)
              (not zero.truncated?)
              (net.status-ok? zero.status)
              (match zero.peer
                [(Peer _) true]
                [_ false]))
            "empty UDP datagram has peer"))
        (f.queue f.adapter.context token 4)
        (let
          [peek : net.NetIoResult
            (net.udp-try-peek-from!
              (&mut socket)
              (byte_buf.as-mut-bytes (&mut bytes))
              0
              4)]
          (test.assert-true
            (and (= peek.count 4) (not peek.truncated?))
            "exact capacity not truncated"))
        (test.assert-i64-eq
          (net.udp-try-receive-from!
            (&mut socket)
            (byte_buf.as-mut-bytes (&mut bytes))
            0
            4).count
          4
          "peek retained datagram")
        (f.queue f.adapter.context token 9)
        (let
          [truncated : net.NetIoResult
            (net.udp-try-receive-from!
              (&mut socket)
              (byte_buf.as-mut-bytes (&mut bytes))
              0
              0)]
          (test.assert-true
            (and
              (= truncated.count 0)
              truncated.truncated?
              (not truncated.eof?))
            "zero-capacity nonempty UDP"))
        (test.assert-i64-eq
          (f.calls f.adapter.context (net.Preflight))
          4
          "metadata call per data attempt")
        (test.assert-i64-eq
          (f.calls f.adapter.context (net.ReceiveFrom))
          3
          "one datagram attempt per receive")
        (test.assert-true
          (net.status-ok?
            (net.udp-try-send-to!
              (&mut socket)
              (byte_buf.as-bytes (& bytes))
              0
              0
              (endpoint)).status)
          "empty UDP send dispatched")
        (test.assert-i64-eq
          (f.calls f.adapter.context (net.SendTo))
          1
          "empty UDP send host attempt")
        (f.script f.adapter.context (net.SendTo) 0 2)
        (let
          [partial : net.NetIoResult
            (net.udp-send-to!
              (&mut socket)
              (byte_buf.as-bytes (& bytes))
              0
              4
              (endpoint)
              (net.default-limits))]
          (test.assert-i64-eq partial.count 2 "partial datagram count")
          (assert-kind
            partial.status
            (net.PartialDatagram)
            "partial datagram no retry"))
        (test.assert-i64-eq
          (f.calls f.adapter.context (net.SendTo))
          2
          "partial send once")
        (f.script f.adapter.context (net.SendTo) 1 0)
        (assert-kind
          (net.udp-try-send-to!
            (&mut socket)
            (byte_buf.as-bytes (& bytes))
            0
            4
            (endpoint)).status
          (net.PartialDatagram)
          "zero nonempty datagram anomaly")
        (net.udp-connect! (&mut socket) (endpoint) (net.default-limits))
        (assert-kind
          (net.udp-try-send-to!
            (&mut socket)
            (byte_buf.as-bytes (& bytes))
            0
            4
            (endpoint)).status
          (net.AlreadyConnected)
          "connected forbids send-to")
        (test.assert-true
          (net.status-ok?
            (net.udp-try-send! (&mut socket) (byte_buf.as-bytes (& bytes)) 0 4).status)
          "connected send")))))

(define (corrupt-and-host-errors [make-fixture : (-> Fixture)]) : unit
  (let
    [code : i64 -3]
    (while (>= code -6)
      (let
        [f : Fixture (make-fixture)]
        [bytes : byte_buf.ByteBuf (buffer 4)]
        (f.script f.adapter.context (net.Read) 0 code)
        (with
          ([stream (open-stream f) net.cleanup-tcp-stream])
          (let
            [result : net.NetIoResult
              (net.tcp-stream-try-read!
                (&mut stream)
                (byte_buf.as-mut-bytes (&mut bytes))
                0
                4)]
            (assert-kind
              result.status
              (cond
                [(= code -3) (net.HostFailure)]
                [(= code -6) (net.CommittedMetadata)]
                [else (net.AdapterCorrupt)])
              "corrupt or host data result")
            (if (= code -6)
              (test.assert-i64-eq
                result.count
                4
                "metadata preserves copied count")
              unit))))
      (set! code (- code 1))))
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 4)]
    (f.script f.adapter.context (net.ReceiveFrom) 0 -8)
    (with
      ([socket (open-udp f) net.cleanup-udp-socket])
      (let
        [result : net.NetIoResult
          (net.udp-try-receive-from!
            (&mut socket)
            (byte_buf.as-mut-bytes (&mut bytes))
            0
            4)]
        (assert-kind
          result.status
          (net.CommittedMetadata)
          "invalid source after payload")
        (test.assert-i64-eq result.count 4 "invalid source retains count")
        (test.assert-true
          (match result.peer
            [(NoPeer) true]
            [_ false])
          "no partial address")
        (test.assert-i64-eq
          (cast (byte_buf.ref (& bytes) 0) : i64)
          1
          "committed payload visible")))))

(define (construction-and-deadlines [make-fixture : (-> Fixture)]) : unit
  (let
    [f : Fixture (make-fixture)]
    (f.script f.adapter.context (net.Create) 0 1)
    (f.script f.adapter.context (net.FinishConnect) 0 -1)
    (match (net.tcp-stream-connect
      f.adapter
      (endpoint)
      (net.NetLimits (net.Deadline 150) net.never-canceled 20))
      [(StreamError failure)
        (test.assert-i64-eq
          (kind-code failure.kind)
          (kind-code (net.TimedOut))
          "pending connect timeout")]
      [(StreamOk stream)
        (net.cleanup-tcp-stream stream)
        (io.panic "pending connect published")])
    (test.assert-i64-eq
      (f.calls f.adapter.context (net.Close))
      1
      "pending construction closes once")
    (test.assert-true
      (<= (f.max-wait f.adapter.context) 100)
      "pending connect wait bound"))
  (let
    [f : Fixture (make-fixture)]
    (f.script f.adapter.context (net.Create) 0 1)
    (f.script f.adapter.context (net.FinishConnect) 0 -2)
    (f.script f.adapter.context (net.FinishConnect) 1 0)
    (with ([stream (open-stream f) net.cleanup-tcp-stream]) unit)
    (test.assert-i64-eq
      (f.calls f.adapter.context (net.FinishConnect))
      2
      "connect EINTR retries")
    (test.assert-i64-eq
      (f.calls f.adapter.context (net.Close))
      1
      "successful construction closes once"))
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 4)]
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (f.clock f.adapter.context 0 1)
      (let
        [progress : net.NetIoResult
          (net.tcp-stream-read!
            (&mut stream)
            (byte_buf.as-mut-bytes (&mut bytes))
            0
            4
            (net.NetLimits (net.Deadline 1) net.never-canceled 10))]
        (test.assert-true
          (and (= progress.count 4) (net.status-ok? progress.status))
          "positive progress wins over later expiry"))
      (f.clock f.adapter.context 0 1)
      (f.script f.adapter.context (net.Write) 0 2)
      (let
        [partial : net.NetTransfer
          (net.tcp-stream-write-all!
            (&mut stream)
            (byte_buf.as-bytes (& bytes))
            0
            4
            (net.NetLimits (net.Deadline 1) net.never-canceled 10))]
        (test.assert-i64-eq partial.count 2 "timeout retains committed prefix")
        (assert-kind partial.status (net.TimedOut) "timeout before next suffix"))))
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 4)]
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (f.script f.adapter.context (net.Read) 0 -1)
      (let
        [result : net.NetIoResult
          (net.tcp-stream-read!
            (&mut stream)
            (byte_buf.as-mut-bytes (&mut bytes))
            0
            4
            (net.NetLimits (net.Deadline 35) net.never-canceled 10))]
        (assert-kind result.status (net.TimedOut) "short deadline wakes")
        (test.assert-i64-eq
          (f.max-wait f.adapter.context)
          35
          "remaining time wait slice")
        (test.assert-i64-eq
          (f.calls f.adapter.context (net.Read))
          1
          "no data dispatch after expiry")))))

(define (bounds-and-owned-bytes [make-fixture : (-> Fixture)]) : unit
  (test.assert-i64-eq
    (net.stream-attempt-size 2147483648)
    net.stream-transfer-max
    "long view bounded without int narrowing")
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer (+ net.stream-transfer-max 1))]
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (test.assert-i64-eq
        (net.tcp-stream-try-write!
          (&mut stream)
          (byte_buf.as-bytes (& bytes))
          0
          (+ net.stream-transfer-max 1)).count
        net.stream-transfer-max
        "long stream view primitive partial")
      (test.assert-i64-eq
        (net.tcp-stream-write-buffer!
          (&mut stream)
          (& bytes)
          (net.default-limits)).count
        (+ net.stream-transfer-max 1)
        "owned buffer whole helper")
      (let
        [owned : net.NetOwnedRead
          (net.tcp-stream-read-owned! (&mut stream) 4 (net.default-limits))]
        (test.assert-i64-eq
          (byte_buf.len (& owned.buffer))
          owned.result.count
          "owned read live bytes"))))
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer (+ net.datagram-max 1))]
    (with
      ([socket (open-udp f) net.cleanup-udp-socket])
      (assert-kind
        (net.udp-try-send-to!
          (&mut socket)
          (byte_buf.as-bytes (& bytes))
          0
          (+ net.datagram-max 1)
          (endpoint)).status
        (net.InvalidRange)
        "UDP max precheck")
      (test.assert-i64-eq
        (f.calls f.adapter.context (net.Preflight))
        0
        "UDP bound before preflight")
      (test.assert-i64-eq
        (net.udp-try-send-to!
          (&mut socket)
          (byte_buf.as-bytes (& bytes))
          0
          net.datagram-max
          (endpoint)).count
        net.datagram-max
        "UDP maximum accepted")
      (let
        [owned : net.NetOwnedRead
          (net.udp-receive-owned!
            (&mut socket)
            0
            true
            false
            (net.default-limits))]
        (test.assert-true
          (and (= (byte_buf.len (& owned.buffer)) 0) owned.result.truncated?)
          "owned zero UDP receive")))))

(define (accept-retry-and-close-interruption [make-fixture : (-> Fixture)]) : unit
  (let
    [f : Fixture (make-fixture)]
    (f.script f.adapter.context (net.Accept) 0 -2)
    (f.script f.adapter.context (net.Accept) 1 -1)
    (f.script f.adapter.context (net.Accept) 2 0)
    (with
      ([listener (open-listener f) net.cleanup-tcp-listener])
      (match (net.tcp-listener-try-accept! (&mut listener))
        [(AcceptError failure)
          (test.assert-i64-eq
            (kind-code failure.kind)
            (kind-code (net.Interrupted))
            "try accept interrupted")]
        [(AcceptOk stream _)
          (net.cleanup-tcp-stream stream)
          (io.panic "try accept retried")])
      (match (net.tcp-listener-accept! (&mut listener) (net.default-limits))
        [(AcceptOk stream _) (net.cleanup-tcp-stream stream)]
        [_ (io.panic "wait accept retry")]))
    (test.assert-i64-eq
      (f.calls f.adapter.context (net.Accept))
      3
      "accept transitions")
    (test.assert-i64-eq
      (f.calls f.adapter.context (net.WaitRead))
      1
      "accept readiness"))
  (let
    [f : Fixture (make-fixture)]
    (f.script f.adapter.context (net.Close) 0 -2)
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (assert-kind
        (net.tcp-stream-close! (&mut stream))
        (net.Interrupted)
        "ambiguous close returned")
      (assert-kind
        (net.tcp-stream-close! (&mut stream))
        (net.Closed)
        "ambiguous close not retried"))
    (test.assert-i64-eq
      (f.calls f.adapter.context (net.Close))
      1
      "ambiguous close exactly once")))

(define (selected-surface [make-fixture : (-> Fixture)]) : unit
  (let
    [f : Fixture (make-fixture)]
    (with
      ([listener (open-listener f) net.cleanup-tcp-listener])
      (test.assert-true
        (match (net.tcp-listener-local-address! (&mut listener))
          [(Address _) true]
          [_ false])
        "listener endpoint")
      (net.tcp-listener-set-option! (&mut listener) (net.UnicastHopLimit) 255)
      (test.assert-i64-eq
        (match (net.tcp-listener-get-option!
          (&mut listener)
          (net.UnicastHopLimit))
          [(Option value) value]
          [_ -1])
        255
        "listener hop limit")
      (test.assert-true
        (match (net.tcp-listener-take-error! (&mut listener))
          [(NoError) true]
          [_ false])
        "listener take error")
      (match (net.tcp-listener-duplicate! (&mut listener))
        [(ListenerOk other) (net.cleanup-tcp-listener other)]
        [_ (io.panic "listener duplicate")])))
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 4)]
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (test.assert-true
        (match (net.tcp-stream-local-address! (&mut stream))
          [(Address _) true]
          [_ false])
        "stream local")
      (test.assert-true
        (match (net.tcp-stream-peer-address! (&mut stream))
          [(Address _) true]
          [_ false])
        "stream peer")
      (test.assert-true
        (net.status-ok?
          (net.tcp-stream-peek!
            (&mut stream)
            (byte_buf.as-mut-bytes (&mut bytes))
            0
            4
            (net.default-limits)).status)
        "wait peek")
      (f.script f.adapter.context (net.Write) 0 -1)
      (assert-kind
        (net.tcp-stream-try-write!
          (&mut stream)
          (byte_buf.as-bytes (& bytes))
          0
          4).status
        (net.WouldBlock)
        "try would block")
      (f.script f.adapter.context (net.Write) 1 2)
      (let
        [limits : net.NetLimits
          (net.NetLimits
            (net.NoDeadline)
            (lambda () : bool
              (> (f.calls f.adapter.context (net.Write)) 1))
            10)]
        [result : net.NetTransfer
          (net.tcp-stream-write-all!
            (&mut stream)
            (byte_buf.as-bytes (& bytes))
            0
            4
            limits)]
        (test.assert-i64-eq
          result.count
          2
          "cancellation retains positive suffix")
        (assert-kind result.status (net.Canceled) "cancel before next suffix"))))
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 4)]
    (with
      ([socket (open-udp f) net.cleanup-udp-socket])
      (test.assert-true
        (match (net.udp-local-address! (&mut socket))
          [(Address _) true]
          [_ false])
        "UDP local")
      (assert-kind
        (net.udp-try-send! (&mut socket) (byte_buf.as-bytes (& bytes)) 0 4).status
        (net.NotConnected)
        "unconnected send preflight")
      (net.udp-set-option! (&mut socket) (net.Broadcast) 1)
      (test.assert-i64-eq
        (match (net.udp-get-option! (&mut socket) (net.Broadcast))
          [(Option value) value]
          [_ -1])
        1
        "UDP broadcast")
      (net.udp-connect! (&mut socket) (endpoint) (net.default-limits))
      (test.assert-true
        (match (net.udp-peer-address! (&mut socket))
          [(Address _) true]
          [_ false])
        "UDP peer")
      (f.queue f.adapter.context (f.last-token f.adapter.context) 4)
      (test.assert-i64-eq
        (net.udp-try-peek!
          (&mut socket)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          4).count
        4
        "connected try peek")
      (test.assert-i64-eq
        (net.udp-peek!
          (&mut socket)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          4
          (net.default-limits)).count
        4
        "connected wait peek")
      (test.assert-i64-eq
        (net.udp-receive!
          (&mut socket)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          4
          (net.default-limits)).count
        4
        "connected wait receive")
      (f.queue f.adapter.context (f.last-token f.adapter.context) 0)
      (test.assert-i64-eq
        (net.udp-try-receive!
          (&mut socket)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          4).count
        0
        "connected empty receive")
      (test.assert-i64-eq
        (net.udp-send!
          (&mut socket)
          (byte_buf.as-bytes (& bytes))
          0
          4
          (net.default-limits)).count
        4
        "connected wait send")
      (test.assert-true
        (match (net.udp-take-error! (&mut socket))
          [(NoError) true]
          [_ false])
        "UDP take error")
      (match (net.udp-duplicate! (&mut socket))
        [(UdpOk other) (net.cleanup-udp-socket other)]
        [_ (io.panic "UDP duplicate")])
      (net.udp-close! (&mut socket))))
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 4)]
    (with
      ([socket (open-udp f) net.cleanup-udp-socket])
      (f.script f.adapter.context (net.Preflight) 0 -2)
      (f.script f.adapter.context (net.Preflight) 1 0)
      (test.assert-i64-eq
        (net.udp-peek-from!
          (&mut socket)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          4
          (net.default-limits)).count
        4
        "UDP preflight interruption retries")
      (test.assert-i64-eq
        (f.calls f.adapter.context (net.Preflight))
        2
        "preflight trace includes retry")
      (test.assert-i64-eq
        (f.calls f.adapter.context (net.PeekFrom))
        1
        "preflight interruption no transfer")
      (test.assert-i64-eq
        (net.udp-receive-from!
          (&mut socket)
          (byte_buf.as-mut-bytes (&mut bytes))
          0
          4
          (net.default-limits)).count
        4
        "wait receive from"))))

(define (zero-limit-validation [make-fixture : (-> Fixture)]) : unit
  (let
    [f : Fixture (make-fixture)]
    [bytes : byte_buf.ByteBuf (buffer 0)]
    (with
      ([stream (open-stream f) net.cleanup-tcp-stream])
      (assert-kind
        (net.tcp-stream-write-all!
          (&mut stream)
          (byte_buf.as-bytes (& bytes))
          0
          0
          (net.NetLimits (net.Deadline -1) net.never-canceled 1)).status
        (net.InvalidRange)
        "zero whole transfer still validates limits"))))

(define probe-calls : i64
  0)

(define (cancel-once) : bool
  (set! probe-calls (+ probe-calls 1))
  (= probe-calls 1))

(define (capability-limits [make-fixture : (-> Fixture)]) : unit
  (let
    [f : Fixture (make-fixture)]
    [req : net.NetRequest (net.request (net.Create) (net.Stream) -1)]
    (set! probe-calls 0)
    (set! req.limits (net.NetLimits (net.Deadline 0) cancel-once 8))
    (let
      [reply : net.NetReply
        (f.adapter.dispatch f.adapter.context req (byte_buf.new))]
      (test.assert-i64-eq reply.calls 0 "capability cancellation before host")
      (test.assert-i64-eq
        probe-calls
        1
        "observed cancellation is not re-polled")
      (test.assert-true
        (match reply.step
          [(Failed failure)
            (= (kind-code failure.kind) (kind-code (net.Canceled)))]
          [_ false])
        "capability sees original deadline and cancellation probe"))
    (set! req.limits (net.NetLimits (net.Deadline -1) net.never-canceled 8))
    (let
      [reply : net.NetReply
        (f.adapter.dispatch f.adapter.context req (byte_buf.new))]
      (test.assert-i64-eq reply.calls 0 "capability rejects negative deadline")
      (test.assert-true
        (match reply.step
          [(Failed failure)
            (= (kind-code failure.kind) (kind-code (net.InvalidRange)))]
          [_ false])
        "capability validates limits"))))

(define (run [make-fixture : (-> Fixture)]) : unit
  (capability-limits make-fixture)
  (zero-limit-validation make-fixture)
  (stream-zero-and-ranges make-fixture)
  (stream-partial-and-eof make-fixture)
  (stream-retry-and-budgets make-fixture)
  (stream-peek-duplicate-shutdown make-fixture)
  (owners-and-accept make-fixture)
  (udp-datagrams make-fixture)
  (corrupt-and-host-errors make-fixture)
  (construction-and-deadlines make-fixture)
  (bounds-and-owned-bytes make-fixture)
  (accept-retry-and-close-interruption make-fixture)
  (selected-surface make-fixture))