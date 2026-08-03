;; A shared Slice can be read, but never written through.
(define (write! [s : (& s (Slice i64))]) : unit
  (array-set! s 0 9))