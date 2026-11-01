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

(define (main) : i64
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