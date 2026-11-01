(import stdlib.byte_buf)
(import stdlib.net)
(import stdlib.net.ip)
(import stdlib.net_fake as fake)
(import stdlib.test)
(cfg compile-profile (import stdlib.profile))
(import stdlib.tests.net_conformance as c)

(define (fixture) : c.Fixture
  (c.Fixture
    (fake.adapter (fake.new))
    fake.script!
    fake.calls
    fake.set-clock!
    fake.queue!
    fake.last-token
    fake.max-wait
    fake.written-sum))

(define (options) : unit
  (let
    [f : c.Fixture (fixture)]
    (with
      ([stream (c.open-stream f) net.cleanup-tcp-stream])
      (match (net.tcp-stream-set-option! (&mut stream) (net.UnicastHopLimit) 0)
        [(OptionError failure)
          (test.assert-i64-eq
            (c.kind-code failure.kind)
            (c.kind-code (net.InvalidOption))
            "hop bound")]
        [_ (test.assert-true false "bad hop accepted")])
      (test.assert-i64-eq
        (fake.calls f.adapter.context (net.SetOption))
        0
        "option precheck")
      (fake.set-corrupt-option! f.adapter.context 256)
      (match (net.tcp-stream-get-option! (&mut stream) (net.UnicastHopLimit))
        [(OptionError failure)
          (test.assert-i64-eq
            (c.kind-code failure.kind)
            (c.kind-code (net.AdapterCorrupt))
            "bad host option")]
        [_ (test.assert-true false "corrupt option accepted")])
      (fake.set-corrupt-option! f.adapter.context 0)
      (fake.set-pending-error! f.adapter.context 111)
      (match (net.tcp-stream-get-option! (&mut stream) (net.TakeError))
        [(OptionError failure)
          (test.assert-i64-eq
            (c.kind-code failure.kind)
            (c.kind-code (net.UnsupportedCapability))
            "take-error has a dedicated result")]
        [_ (test.assert-true false "integer getter consumed pending error")])
      (match (net.tcp-stream-take-error! (&mut stream))
        [(SocketError failure)
          (test.assert-i64-eq failure.code 111 "pending error code")
          (test.assert-true
            (match failure.domain
              [(LinuxErrno) true]
              [_ false])
            "pending error domain")]
        [_ (test.assert-true false "missing pending error")])
      (test.assert-true
        (match (net.tcp-stream-take-error! (&mut stream))
          [(NoError) true]
          [_ false])
        "pending error consumed")))
  (let
    [f : c.Fixture (fixture)]
    [v6 : net.SocketAddr
      (net.V6 (net.SocketAddrV6 (ip.ipv6 0 0 0 0 0 0 0 1) 0 0))]
    (match (net.udp-bind f.adapter v6 (net.default-limits))
      [(UdpOk socket)
        (with
          ([owner socket net.cleanup-udp-socket])
          (match (net.udp-set-option! (&mut owner) (net.Broadcast) 1)
            [(OptionError failure)
              (test.assert-i64-eq
                (c.kind-code failure.kind)
                (c.kind-code (net.UnsupportedAddressFamily))
                "IPv6 broadcast rejected")]
            [_ (test.assert-true false "IPv6 broadcast accepted")])
          (test.assert-i64-eq
            (fake.calls f.adapter.context (net.SetOption))
            0
            "family before dispatch"))]
      [_ (test.assert-true false "v6 construction")])))

(define (stale-native-token) : unit
  (let
    [f : c.Fixture (fixture)]
    [old : i64 0]
    (with
      ([stream (c.open-stream f) net.cleanup-tcp-stream])
      (set! old (fake.last-token f.adapter.context)))
    (with
      ([stream (c.open-stream f) net.cleanup-tcp-stream])
      (test.assert-true
        (!= old (fake.last-token f.adapter.context))
        "slot reused with new generation")
      (let
        [before : i64 (fake.host-calls f.adapter.context)]
        [reply : net.NetReply
          (f.adapter.dispatch
            f.adapter.context
            (net.request (net.Close) (net.Stream) old)
            (byte_buf.new))]
        (test.assert-true
          (match reply.step
            [(Failed failure)
              (= (c.kind-code failure.kind) (c.kind-code (net.Closed)))]
            [_ false])
          "stale token rejected")
        (test.assert-i64-eq
          (fake.host-calls f.adapter.context)
          before
          "stale token no host call")))))

(define (duplicate-survives-reuse) : unit
  (let
    [f : c.Fixture (fixture)]
    [bytes : byte_buf.ByteBuf (c.buffer 4)]
    (with
      ([stream (c.open-stream f) net.cleanup-tcp-stream])
      (match (net.tcp-stream-duplicate! (&mut stream))
        [(StreamOk duplicate)
          (with
            ([other duplicate net.cleanup-tcp-stream])
            (net.tcp-stream-close! (&mut stream))
            (with
              ([fresh (c.open-stream f) net.cleanup-tcp-stream])
              (net.tcp-stream-shutdown! (&mut fresh) (net.ShutdownBoth))
              (let
                [read : net.NetIoResult
                  (net.tcp-stream-try-read!
                    (&mut other)
                    (byte_buf.as-mut-bytes (&mut bytes))
                    0
                    4)]
                (test.assert-i64-eq
                  read.count
                  4
                  "new socket does not reset duplicate group")
                (test.assert-true (not read.eof?) "new shutdown isolated"))))]
        [_ (test.assert-true false "duplicate")]))))

(cfg
  compile-profile
  (define (allocation-contract) : unit
    (let
      [f : c.Fixture (fixture)]
      [bytes : byte_buf.ByteBuf (c.buffer 4)]
      (with
        ([stream (c.open-stream f) net.cleanup-tcp-stream])
        (let
          [before : i64 (profile.alloc-total)]
          (net.tcp-stream-try-write!
            (&mut stream)
            (byte_buf.as-bytes (& bytes))
            0
            4)
          (net.tcp-stream-close! (&mut stream))
          (let
            [delta : i64 (- (profile.alloc-total) before)]
            (test.assert-i64-eq
              delta
              0
              "ordinary data and close allocate nothing"))))
      (let
        [before : i64 (profile.alloc-total)]
        [control : byte_buf.ByteBuf (byte_buf.new)]
        [delta : i64 (- (profile.alloc-total) before)]
        (test.assert-true
          (and (> delta 0) (= (byte_buf.len (& control)) 0))
          "allocation counter positive control")))))

(define (null-owners) : unit
  (with
    ([socket
        (net.UdpSocket
          (net.SocketOwner (ptr-null : (MutPtr net.SocketState)) 0))
        net.cleanup-udp-socket])
    (c.assert-kind
      (net.udp-connect! (&mut socket) (c.endpoint) (net.default-limits))
      (net.Closed)
      "safe null UDP owner"))
  (with
    ([stream
        (net.TcpStream
          (net.SocketOwner (ptr-null : (MutPtr net.SocketState)) 0))
        net.cleanup-tcp-stream])
    (c.assert-kind
      (net.tcp-stream-close! (&mut stream))
      (net.Closed)
      "safe null stream owner")))

(define corrupt-operation : i64
  -1)
(define corrupt-shape : i64
  0)

;; Supply a real independent fake token in a reply shape the operation forbids.
(define (corrupt-dispatch
  [context : i64]
  [req : net.NetRequest]
  [buffer : byte_buf.ByteBuf]) : net.NetReply
  (if (= (fake.operation-code req.operation) corrupt-operation)
    (if (= corrupt-shape 3)
      (net.NetReply (net.Created req.token) buffer 1)
      (let
        [creation : net.NetRequest
          (net.request
            (net.Create)
            (if (= corrupt-shape 2)
              (net.Stream)
              req.kind)
            -1)]
        (set! creation.value net.listener-backlog)
        (let
          [created : net.NetReply (fake.dispatch context creation buffer)]
          (match created.step
            [(Created token)
              (net.NetReply
                (cond
                  [(= corrupt-shape 0) (net.Created token)]
                  [(= corrupt-shape 1) (net.PendingConnect token)]
                  [else (net.Accepted token (net.empty-address))])
                created.buffer
                1)]
            [_ created]))))
    (fake.dispatch context req buffer)))

(define (corrupt-resource-cases) : unit
  (let
    [shape : i64 0]
    (while (< shape 4)
      (let
        [path : i64 0]
        (while (< path 4)
          (if (and (= path 3) (= shape 0))
            unit
            (let
              [f : c.Fixture (fixture)]
              (set! corrupt-shape shape)
              (set!
                corrupt-operation
                (fake.operation-code
                  (cond
                    [(= path 1) (net.WaitWrite)]
                    [(= path 3) (net.Duplicate)]
                    [else (net.WaitRead)])))
              (set!
                f.adapter
                (net.NetAdapter f.adapter.context fake.now-ms corrupt-dispatch))
              (if (= path 2)
                (with
                  ([listener (c.open-listener f) net.cleanup-tcp-listener])
                  (fake.script! f.adapter.context (net.Accept) 0 -1)
                  (match (net.tcp-listener-accept!
                    (&mut listener)
                    (net.default-limits))
                    [(AcceptError failure)
                      (c.assert-kind
                        (net.Err failure)
                        (net.AdapterCorrupt)
                        "bad resource reply during accept wait")]
                    [(AcceptOk stream _)
                      (net.cleanup-tcp-stream stream)
                      (test.assert-true false "unexpected accept")])
                  (test.assert-i64-eq
                    (fake.calls f.adapter.context (net.Close))
                    (if (= shape 3)
                      0
                      1)
                    "accept wait abandons returned token once"))
                (with
                  ([stream (c.open-stream f) net.cleanup-tcp-stream])
                  (if (= path 3)
                    (match (net.tcp-stream-duplicate! (&mut stream))
                      [(StreamError failure)
                        (c.assert-kind
                          (net.Err failure)
                          (net.AdapterCorrupt)
                          "bad duplicate resource shape")]
                      [(StreamOk duplicate)
                        (net.cleanup-tcp-stream duplicate)
                        (test.assert-true false "unexpected duplicate")])
                    (let
                      [bytes : byte_buf.ByteBuf (c.buffer 1)]
                      (fake.script!
                        f.adapter.context
                        (if (= path 1)
                          (net.Write)
                          (net.Read))
                        0
                        -1)
                      (let
                        [result : net.NetIoResult
                          (if (= path 1)
                            (net.tcp-stream-write!
                              (&mut stream)
                              (byte_buf.as-bytes (& bytes))
                              0
                              1
                              (net.default-limits))
                            (net.tcp-stream-read!
                              (&mut stream)
                              (byte_buf.as-mut-bytes (&mut bytes))
                              0
                              1
                              (net.default-limits)))]
                        (c.assert-kind
                          result.status
                          (net.AdapterCorrupt)
                          "bad resource reply during data wait"))))
                  (test.assert-i64-eq
                    (fake.calls f.adapter.context (net.Close))
                    (if (= shape 3)
                      0
                      1)
                    "bad resource token abandoned once")
                  (test.assert-true
                    (match (net.tcp-stream-local-address! (&mut stream))
                      [(Address _) true]
                      [_ false])
                    "original owner survives bad resource reply")))
              (test.assert-i64-eq
                (fake.calls f.adapter.context (net.Close))
                (if (= shape 3)
                  1
                  2)
                "returned token and original owner each cleaned once")))
          (set! path (+ path 1))))
      (set! shape (+ shape 1)))))

(define (send-truncation-cases) : unit
  (let
    [f : c.Fixture (fixture)]
    [bytes : byte_buf.ByteBuf (c.buffer 4)]
    (with
      ([socket (c.open-udp f) net.cleanup-udp-socket])
      (fake.script! f.adapter.context (net.SendTo) 0 -9)
      (let
        [sent : net.NetIoResult
          (net.udp-try-send-to!
            (&mut socket)
            (byte_buf.as-bytes (& bytes))
            0
            4
            (c.endpoint))]
        (test.assert-true
          (and
            (= sent.count 4)
            (net.status-ok? sent.status)
            (not sent.truncated?))
          "send-to has no receive truncation flag"))
      (test.assert-true
        (net.status-ok?
          (net.udp-connect! (&mut socket) (c.endpoint) (net.default-limits)))
        "connect for send truncation check")
      (fake.script! f.adapter.context (net.Send) 0 -9)
      (let
        [sent : net.NetIoResult
          (net.udp-try-send! (&mut socket) (byte_buf.as-bytes (& bytes)) 0 4)]
        (test.assert-true
          (and
            (= sent.count 4)
            (net.status-ok? sent.status)
            (not sent.truncated?))
          "connected send has no receive truncation flag")))))

(define (main) : i64
  (corrupt-resource-cases)
  (send-truncation-cases)
  (null-owners)
  (cfg compile-profile (allocation-contract))
  (options)
  (stale-native-token)
  (duplicate-survives-reuse)
  (let
    [bounded : net.NetError
      (net.checked-error
        (net.NetError (net.HostFailure) (net.WindowsKernel) 4294967296))]
    (test.assert-true
      (match bounded.domain
        [(NoHostCode) true]
        [_ false])
      "raw host code bound"))
  (test.assert-true
    (match (net.socket-addr-v6 (ip.ipv6 0 0 0 0 0 0 0 1) 65535 4294967295)
      [(Address a)
        (and
          (= (net.socket-addr-port a) 65535)
          (= (net.socket-addr-scope-id a) 4294967295))]
      [_ false])
    "endpoint maxima")
  (test.assert-true
    (match (net.socket-addr-v6 (ip.ipv6 0 0 0 0 0 0 0 1) 0 4294967296)
      [(AddressError _) true]
      [_ false])
    "scope overflow")
  42)