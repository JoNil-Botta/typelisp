;; An immediate call is accepted when the caller explicitly assumes the raw
;; pointer contract. This is check-only and must never execute the null read.
(import stdlib.fs)

(define (raw-field [base : (MutPtr u8)] [offset : i64]) : i64
  (unsafe
    (fs.metadata-read-i64-at base offset)))

(define (main) : i64
  0)