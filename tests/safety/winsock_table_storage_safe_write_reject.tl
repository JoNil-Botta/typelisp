(import stdlib.net_windows_winsock as winsock)

(define (main) : i64
  (begin
    (ptr-write! winsock.winsock-table-words (cast 0 : u64))
    42))