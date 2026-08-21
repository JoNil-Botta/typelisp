;; TRAP PARITY for GAP10 (memory-destination read-modify-write folding).
;; The fold rewrites `a[i] = a[i] OP b[i]` from three instructions (load a[i],
;; combine with b[i], store back) into two (load b[i], combine into a[i] in
;; place). Two things move: the read of `b[i]` now happens BEFORE the read of
;; `a[i]`, and the write to `a[i]` is fused into the combine.
;; Neither may change where the program traps. `b` is short here, so the
;; versioning guard fails, the CHECKED clone runs, and iteration 4 aborts inside
;; b's bounds check. That check precedes both element accesses in the emitted
;; block -- the fold matches a window that starts at the first gep and admits no
;; BoundsCheck inside it, so a check can only ever sit before the window, never
;; between the load and the store it fuses.
;; This fixture pins the observable consequences: the line printed before the
;; loop must survive, the words the loop already merged must be the same ones
;; the unfolded program merged, the abort must name b's index and length, and
;; the exit status must be the abort status. A fold that reordered a trap, or
;; that wrote a[4] before the abort, would show up here and nowhere else.
(import stdlib.io)

(define (merge-row
  [a : (__tl_dyn-array i64)]
  [b : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (bit-or (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (main) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [b : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [i : i64 0]
    (begin
      (while (< i 8)
        (begin
          (set! (array-ref a i) 16)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i 4)
        (begin
          (set! (array-ref b i) 1)
          (set! i (+ i 1))))
      (io.print-format "{}" "rows\n")
      ;; Merges a[0..3] and then aborts reading b[4].
      (merge-row a b 8)
      (io.print-format "{}" "unreachable\n")
      0)))