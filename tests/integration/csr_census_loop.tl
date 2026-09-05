(import stdlib.io)
(import stdlib.string)

;; FORCING TEST for RG-1 fix B on a CALL-CARRYING loop.
;;
;; The shape is benchmarks/callgraph_scc's `cg-census-blocks`, cut to its
;; skeleton: an outer loop over `position` whose body installs a per-block
;; weight and then runs an inner scan whose two conditional arms both CALL --
;; so `position`, the loop bound and the scan cursor are all live ACROSS a call
;; every iteration and are callee-saved-only candidates, while the calls' own
;; operands compete for the same six registers. The function therefore runs
;; with a full callee-saved run pushed, which is the shape where a save the
;; body never names costs two instructions on every call of the function.
;;
;; The map the arms bump is deliberately a real open-addressed probe over a
;; global array and is recursive, so neither arm can be inlined away and the
;; crossing is genuine.
;;
;; `main`'s second argument is the abort twin: a token stream whose block index
;; runs one past the depth table, so the located out-of-bounds message is
;; pinned at the default optimization level and again at opt-level 2, where
;; the versioner and the allocator have both rewritten the loop.
(define ccl-depths : (__tl_dyn-array i64)
  (__tl_make-array i64 8))
(define ccl-tokens : (__tl_dyn-array i64)
  (__tl_make-array i64 192))
(define ccl-slots : (__tl_dyn-array i64)
  (__tl_make-array i64 96))
(define ccl-site-weight : i64
  1)

(define (ccl-probe [key : i64] [walked : i64] [cursor : i64]) : i64
  (if (>= walked 32)
    -1
    (let
      [state : i64 (array-ref ccl-slots (* cursor 3))]
      (if (= state 0)
        (- 0 (+ 2 cursor))
        (if (= (array-ref ccl-slots (+ (* cursor 3) 1)) key)
          cursor
          (ccl-probe key (+ walked 1) (bit-and (+ cursor 1) 31)))))))

(define (ccl-bump [key : i64] [amount : i64]) : unit
  (let
    [slot : i64 (ccl-probe key 0 (bit-and (* key 2654435761) 31))]
    (if (>= slot 0)
      (set!
        (array-ref ccl-slots (+ (* slot 3) 2))
        (+ (array-ref ccl-slots (+ (* slot 3) 2)) amount))
      (let
        [index : i64 (- (- 0 slot) 2)]
        (begin
          (set! (array-ref ccl-slots (* index 3)) 2)
          (set! (array-ref ccl-slots (+ (* index 3) 1)) key)
          (set! (array-ref ccl-slots (+ (* index 3) 2)) amount))))))

(define (ccl-depth-weight [depth : i64]) : i64
  (if (<= depth 0)
    1
    (if (= depth 1)
      8
      64)))

;; The census walk itself: `position`, `blocks` and `cursor` are the values the
;; allocator has to place, and every arm of the inner scan calls.
(define (ccl-census-blocks [blocks : i64] [start : i64] [refs : i64]) : i64
  (let
    [cursor : i64 start]
    [end : i64 (+ start (* refs 3))]
    [position : i64 0]
    [seen : i64 0]
    (begin
      (while (< position blocks)
        (begin
          (set!
            ccl-site-weight
            (ccl-depth-weight (array-ref ccl-depths position)))
          (while (and (< cursor end) (= (array-ref ccl-tokens cursor) position))
            (begin
              (if (= (array-ref ccl-tokens (+ cursor 2)) 0)
                (ccl-bump (array-ref ccl-tokens (+ cursor 1)) ccl-site-weight)
                (ccl-bump (array-ref ccl-tokens (+ cursor 1)) 1))
              (set! seen (+ seen 1))
              (set! cursor (+ cursor 3))))
          (set! position (+ position 1))))
      ;; NON-TAIL self-recursion, never taken (`blocks` is at least 8 at every
      ;; call), keeps the walk out of every inline tier -- the measured tier
      ;; would otherwise take it into `main`'s loop -- so the gate can read its
      ;; own prologue (divmagic_hoist pattern). It sits after the walk so the
      ;; abort twin's pinned line does not move.
      (if (< blocks 0)
        (+ seen (ccl-census-blocks blocks start refs))
        seen))))

(define (ccl-fill! [blocks : i64] [refs : i64] [skew : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i blocks)
        (begin
          (set! (array-ref ccl-depths i) (bit-and i 1))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i refs)
        (begin
          ;; The abort twin sends the last token one block past the table.
          (set!
            (array-ref ccl-tokens (* i 3))
            (if (and (> skew 0) (= i (- refs 1)))
              blocks
              (bit-and i 7)))
          (set! (array-ref ccl-tokens (+ (* i 3) 1)) (+ (* i 3) 1))
          (set! (array-ref ccl-tokens (+ (* i 3) 2)) (bit-and i 1))
          (set! i (+ i 1))))
      unit)))

(define (ccl-total) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i 32)
        (begin
          (if (= (array-ref ccl-slots (* i 3)) 2)
            (set! total (+ total (array-ref ccl-slots (+ (* i 3) 2))))
            unit)
          (set! i (+ i 1))))
      total)))

(define (main) : i64
  (let
    [rounds : i64 (string.>int (io.arg 1))]
    [skew : i64 (string.>int (io.arg 2))]
    [seen : i64 0]
    [i : i64 0]
    (begin
      (ccl-fill! 8 64 skew)
      (while (< i rounds)
        (begin
          (set! seen (+ seen (ccl-census-blocks (+ 8 skew) 0 64)))
          (set! i (+ i 1))))
      (io.print-format "{} {}\n" seen (ccl-total))
      42)))