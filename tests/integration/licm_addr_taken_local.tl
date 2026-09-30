;; LICM and address-taken locals (#7974). A local whose address escapes can be
;; rewritten through that address by a call inside the loop, so its single
;; `mov` does not make it loop-invariant. Exits 42, or the number of the failed
;; check.
;; Writes 7 through `p` at the bottom of a short recursion, so the write sits in
;; a callee the loop cannot see into.
(define (write-seven [p : (MutPtr i64)] [depth : i64]) : i32
  (if (> depth 0)
    (write-seven p (- depth 1))
    (begin
      (unsafe
        (ptr-write! p 7))
      (cast 1 : i32))))

;; `(+ value 1)` reads a local the call rewrites: each iteration must see the
;; value the previous call stored (1 + 8 + 8), not the pre-loop one (1 + 1 + 1).
(define (read-after-call [depth : i64] [seed : i64]) : i64
  (let
    [value : i64 seed]
    [sum : i64 0]
    [i : i64 0]
    (begin
      (while (< i 3)
        (begin
          (set! sum (+ sum (+ value 1)))
          (write-seven
            (unsafe
              (ptr-addr-of value))
            depth)
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (+ 25 (read-after-call 3 0)))