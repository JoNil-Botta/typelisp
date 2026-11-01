(import stdlib.net)

(define (main) : i64
  (with
    ([forged
        (net.TcpStream
          (net.SocketOwner
            (int->ptr (cast 4096 : u64) : (MutPtr net.SocketState))
            0))
        net.cleanup-tcp-stream])
    (net.tcp-stream-close! (&mut forged))
    42))