;; Socket data/retry IR workload. Return a score without host diagnostic imports.
(import stdlib.byte_buf)
(import stdlib.net)
(import stdlib.net_fake as fake)

(define (stream-case) : bool
  (let
    [context : i64 (fake.new)]
    (match (net.tcp-stream-connect
      (fake.adapter context)
      (net.empty-address)
      (net.default-limits))
      [(StreamOk stream)
        (with
          ([owner stream net.cleanup-tcp-stream])
          (let
            [bytes : byte_buf.ByteBuf
              (byte_buf.ByteBuf (__tl_make-array u8 4) 4)]
            (fake.script! context (net.Read) 0 -1)
            (fake.script! context (net.Read) 1 2)
            (let
              [read : net.NetIoResult
                (net.tcp-stream-read!
                  (&mut owner)
                  (byte_buf.as-mut-bytes (&mut bytes))
                  0
                  4
                  (net.NetLimits (net.Deadline 1000) net.never-canceled 10))]
              [write : net.NetTransfer
                (net.tcp-stream-write-all!
                  (&mut owner)
                  (byte_buf.as-bytes (& bytes))
                  0
                  2
                  (net.default-limits))]
              (and
                (= read.count 2)
                (net.status-ok? read.status)
                (= write.count 2)
                (net.status-ok? write.status)
                (= (fake.calls context (net.Read)) 2)
                (= (fake.calls context (net.WaitRead)) 1)
                (= (fake.max-wait context) 100)
                (= (fake.written-sum context) 3)))))]
      [_ false])))

(define (datagram-case) : bool
  (let
    [context : i64 (fake.new)]
    (match (net.udp-bind
      (fake.adapter context)
      (net.empty-address)
      (net.default-limits))
      [(UdpOk socket)
        (with
          ([owner socket net.cleanup-udp-socket])
          (let
            [bytes : byte_buf.ByteBuf
              (byte_buf.ByteBuf (__tl_make-array u8 4) 4)]
            (fake.queue! context (fake.last-token context) 8)
            (let
              [peek : net.NetIoResult
                (net.udp-try-peek-from!
                  (&mut owner)
                  (byte_buf.as-mut-bytes (&mut bytes))
                  0
                  4)]
              [read : net.NetIoResult
                (net.udp-try-receive-from!
                  (&mut owner)
                  (byte_buf.as-mut-bytes (&mut bytes))
                  0
                  4)]
              (and
                (= peek.count 4)
                peek.truncated?
                (not peek.eof?)
                (net.status-ok? peek.status)
                (= read.count 4)
                read.truncated?
                (not read.eof?)
                (net.status-ok? read.status)
                (match read.peer
                  [(Peer _) true]
                  [_ false])
                (= (fake.calls context (net.PeekFrom)) 1)
                (= (fake.calls context (net.ReceiveFrom)) 1)))))]
      [_ false])))

(define (main) : i64
  (if (and (stream-case) (datagram-case))
    42
    1))