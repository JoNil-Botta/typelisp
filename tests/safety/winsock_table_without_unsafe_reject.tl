(import stdlib.net_windows_winsock as winsock)

(define (main) : i64
  (with
    ([lease (winsock.WinsockLease (box 1)) winsock.cleanup-winsock-lease])
    (begin
      (winsock.winsock-table-for-lease (& lease))
      42)))