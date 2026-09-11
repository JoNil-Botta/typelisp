;; Immediate calls compile when the caller explicitly assumes the raw range
;; and resource contracts. This check-only fixture must never execute them.
(import stdlib.io)
(import stdlib.io_core)

(define (raw-length [data : (Ptr u8)]) : i64
  (unsafe
    (io.c-string-length data)))

(define (raw-table-read [data : (MutPtr i64)] [index : i64]) : i64
  (unsafe
    (io_core.io-file-i64-ref data index)))

(define (main) : i64
  0)