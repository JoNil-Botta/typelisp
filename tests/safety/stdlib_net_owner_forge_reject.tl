;; Safe code cannot build a socket owner, even from a null pointer (#9783).
(import stdlib.net)

(define (main) : i64
  (with
    ([stream
        (net.TcpStream
          (net.SocketOwner (ptr-null : (MutPtr net.SocketState)) 0))
        net.cleanup-tcp-stream])
    0))