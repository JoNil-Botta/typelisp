;; A Slice element cannot itself be an unsized Slice.
(define (bad [s : (& s (Slice (Slice i64)))]) : i64
  0)