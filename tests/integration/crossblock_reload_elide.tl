(import stdlib.io)

;; FORCING TEST for CFG-aware cross-block reload-elision (carry the peephole's
;; reg->slot owner map across a NON-jump-target label, reset at every
;; jump/branch/switch/merge target). Two halves:
;;
;; (1) FALL-THROUGH ELISION (the win). `dispatch` reloads its read-only params
;;     after a real call and reuses them across single-predecessor fall-through
;;     match arms. The peephole carries the owner map across those arm labels and
;;     drops the redundant param reloads. The result must stay correct for every
;;     arm -- if a carry dropped a reload that was actually needed, an arm reads a
;;     stale register and the sum is wrong.
;;
;; (2) MERGE-LABEL SOUNDNESS (the guard). `accumulate`'s loop header is a MERGE
;;     reached from the preheader AND the back-edge, with a clobbering call in the
;;     body, so the two predecessors leave DIFFERENT register contents. The header
;;     is a branch target (>= 2 predecessors), so the peephole MUST reset there
;;     and keep the carry reloads. A wrong carry across the merge would read a
;;     stale/clobbered register from the wrong predecessor and corrupt `acc`.
;;
;; Inputs flow from (io.arg-count) so the optimizer cannot constant-fold the calls
;; (which would delete the cross-block live ranges this test depends on).
;; Self-recursive `touch` is not leaf-inlined, so the clobbering call survives.
;; touch(x) = x for x >= 0; clobbers caller-saved registers around each call.
(define (touch [x : i64]) : i64
  (if (<= x 0)
    0
    (+ 1 (touch (- x 1)))))

;; Read-only params reused across fall-through arms after a clobbering call.
(define (dispatch
  [tag : i64]
  [p0 : i64]
  [p1 : i64]
  [p2 : i64]
  [p3 : i64]
  [p4 : i64]
  [p5 : i64]) : i64
  (let
    [s : i64 (+ p0 (+ p1 (+ p2 (+ p3 (+ p4 p5)))))]
    [_ : i64 (touch tag)]
    (cond
      [(= tag 0) (+ s p0)]
      [(= tag 1) (+ s p1)]
      [(= tag 2) (+ s p2)]
      [else (+ s p3)])))

;; Loop whose header is a merge; a call inside the body clobbers caller-saved.
(define (accumulate [n : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (touch i)))
          (set! acc (+ acc i))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (io.arg-count)]
    [d0 : i64 (dispatch 0 n (+ n 1) (+ n 2) (+ n 3) (+ n 4) (+ n 5))]
    [d3 : i64 (dispatch 3 n (+ n 1) (+ n 2) (+ n 3) (+ n 4) (+ n 5))]
    [ac : i64 (accumulate (+ n 3))]
    ;; n = 1 (no extra argv): s = 1+2+3+4+5+6 = 21.
    ;;   d0 (tag 0) = s + p0 = 21 + 1 = 22.
    ;;   d3 (else)  = s + p3 = 21 + 4 = 25.
    ;;   accumulate(4): sum_{i=0..3} (touch i + i) = sum 2i = 0+2+4+6 = 12.
    ;; total = 22 + 25 + 12 = 59.
    [r : i64 (+ d0 (+ d3 ac))]
    (if (= r 59)
      42
      1)))