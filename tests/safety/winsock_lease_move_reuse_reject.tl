(import stdlib.net_windows_winsock as winsock)

(define (consume [_lease : winsock.WinsockLease]) : unit
  unit)

(define (main) : i64
  (with
    ([lease (winsock.WinsockLease (box 1)) winsock.cleanup-winsock-lease])
    (begin
      (consume lease)
      (consume lease)
      42)))