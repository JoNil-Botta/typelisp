;; INL-7: a loop-bearing body must not be imported into a caller whose loop the
;; pipeline has not built yet.
;;
;; The hot-loop-leaf band's third site tier admits a cyclic, call-free body at a
;; STRAIGHT-LINE site when the caller has no natural loop, on the argument that
;; "the imported loop becomes the caller's only one" -- no caller loop is there
;; for the import's working set to lengthen. The inliner runs before the
;; per-function pipeline, and that pipeline's first pass turns a SELF TAIL-CALL
;; into a back edge to the entry block. A self-tail-recursive caller therefore
;; presents to the band with an empty natural-loop set and leaves the pipeline
;; with a loop around its whole body, and the import lands inside it.
;;
;; This file holds both answers over ONE callee, so the only thing that differs
;; between them is the caller's own recursion:
;;
;;   * `rli-rows` is the refused shape -- sccp_lattice's `sccp-rewrite-rows`,
;;     which cost that row 2,346,224 instructions. It walks the tape by self
;;     tail-call, has no natural loop of its own, and calls `rli-scan` from one
;;     arm at a straight-line site;
;;   * `rli-peek` is the shape the clause must leave alone -- gvn_table's
;;     `gvn-facts-slot` callers, the measured win of the same tier. Same callee,
;;     same straight-line site, a caller that does not call itself.
;;
;; Both callers carry a bounds check of their own, which is what keeps the
;; cascade clause (an import must not hand a bounds-free single-reference caller
;; its first bounds check) out of the comparison: neither caller's admission
;; turns on it.
;;
;; `rli-scan`'s `array-ref` is where the abort twin's check lives. It sits
;; INSIDE the callee, so after the split it is a check `rli-peek` carries in a
;; copy and `rli-rows` reaches through a call, and the diagnostic must name this
;; file's line either way.
(import stdlib.io)
(import stdlib.string)

(define rli-tokens : (__tl_dyn-array i64)
  (__tl_make-array i64 0))
(define rli-subs : i64
  0)

;; The callee: cyclic, call-free, past the legacy 32-instruction band, and it
;; writes a module global so the whole body only became inlinable at all with
;; INL-6's multiblock `Store` admission.
(define (rli-scan [base : i64] [count : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 1469598103934665603]
    (begin
      (while (< i count)
        (let
          [v : i64 (array-ref rli-tokens (+ base i))]
          (begin
            (if (= (bit-and v 1) 0)
              (set! acc (* (bit-xor acc v) 1099511628211))
              (set! acc (+ (* acc 31) (shl v 3))))
            (set! rli-subs (+ rli-subs 1))
            (set! i (+ i 1)))))
      acc)))

;; The refused shape: a self-tail-recursive driver with no natural loop.
(define (rli-rows [row : i64] [limit : i64] [span : i64] [acc : i64]) : i64
  (if (>= row limit)
    acc
    (let
      [head : i64 (array-ref rli-tokens row)]
      (rli-rows
        (+ row 1)
        limit
        span
        (if (= (bit-and row 1) 0)
          (+ (* acc 7) (rli-scan row span))
          (+ (* acc 3) head))))))

;; The shape the clause leaves alone: the same callee at the same kind of site
;; in a caller that does not call itself.
(define (rli-peek [row : i64] [span : i64]) : i64
  (let
    [head : i64 (array-ref rli-tokens row)]
    (+ (* head 5) (rli-scan row span))))

(define (rli-fill [size : i64]) : unit
  (let
    [i : i64 0]
    [p : i64 5]
    (begin
      (set! rli-tokens (__tl_make-array i64 size))
      (while (< i size)
        (begin
          (set! (array-ref rli-tokens i) (+ (* p 2654435761) i))
          (set! p (+ p 3))
          (set! i (+ i 1))))
      unit)))

(define (main) : i64
  (let
    [size : i64 (string.>int (io.arg 1))]
    [rows : i64 (string.>int (io.arg 2))]
    [span : i64 (string.>int (io.arg 3))]
    [fold : i64 0]
    [peek : i64 0]
    (begin
      (rli-fill size)
      ;; A `span` that reaches past the tape from the last row walks the check
      ;; inside `rli-scan` off the end; a span that fits folds every row.
      (set! fold (rli-rows 0 rows span 1))
      (set! peek (rli-peek 1 span))
      (io.println "{}" (bit-and fold 268435455))
      (io.println "{}" (bit-and peek 268435455))
      (io.println "{}" rli-subs)
      42)))