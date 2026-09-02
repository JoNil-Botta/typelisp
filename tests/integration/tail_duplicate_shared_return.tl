;; TD-1 runtime coverage for the duplicated return tail. Both shapes below have
;; a return tail that the guard's BYPASS and the framed arms share, which is
;; what SW-1's well-formedness clause used to refuse. The bypass edge now gets
;; its own copy of that tail, returning bare; the original keeps the epilogue
;; for the predecessors the save point dominates.
;;
;; A clone that kept any part of the epilogue -- an `add rsp` or a pop run --
;; would unbalance the stack or restore garbage into a callee-saved register on
;; the bypass, and an original that lost it would leak the frame on the framed
;; path. Each shape is therefore called on BOTH sides of its guard, and the
;; caller checks a value it kept live across every call.
(import stdlib.io)

(define td-armed : i64
  0)
(define td-calls : i64
  0)

(define (td-sink [x : i64]) : i64
  (begin
    (set! td-calls (+ td-calls 1))
    (+ x 1)))

;; (a) The merge shape: the two arms join at a tail that computes from a phi, so
;; the duplicated tail carries real instructions, not just a return.
(define (td-merge [x : i64]) : i64
  (let
    [r : i64 0]
    (begin
      (if (= td-armed 0)
        (set! r (+ x 1))
        (set! r (+ (td-sink x) (td-sink (+ x 1)))))
      (+ r 5))))

;; (b) The `gvn_table_invalidate_var` shape: a guarded walk whose loop exits and
;; whose bypass all return through the SHARED epilogue label, so the duplicated
;; tail's body is the jump to that label and its clone is a lone `ret`.
(define td-head : i64
  -1)
(define td-hits : i64
  0)
(define td-steps : i64
  0)

(define (td-walk [var : i64]) : unit
  (let
    [node : i64 td-head]
    [found : bool false]
    (begin
      (while (and (>= node 0) (not found))
        (begin
          (set! td-steps (+ td-steps 1))
          (if (= (td-sink node) var)
            (set! found true)
            (set! node (- node 1)))))
      (when found (set! td-hits (+ td-hits 1))))))

(define keep-merge : (-> i64 i64)
  td-merge)
(define keep-walk : (-> i64 unit)
  td-walk)

;; `witness` stays live across each call, so a callee that pops the wrong number
;; of registers is observed here rather than only at the final return.
(define (td-probe [witness : i64]) : i64
  (let
    [a : i64 (td-merge 1)]
    [w1 : i64 (+ witness 0)]
    [_walked : unit (td-walk 2)]
    [w2 : i64 (+ w1 0)]
    (+ a (* w2 1000))))

(define (main) : i64
  (begin
    ;; Both guards bypass: every call returns through a duplicated tail.
    (io.print-format "{}\n" (td-probe 7))
    (set! td-armed 3)
    (set! td-head 4)
    ;; Both guards taken: every call returns through the framed tail.
    (io.print-format "{}\n" (td-probe 7))
    (io.print-format "{}\n" td-hits)
    (io.print-format "{}\n" td-steps)
    (io.print-format "{}\n" td-calls)
    42))