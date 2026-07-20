;; Runtime coverage for the guarded sp-1/sp-2 bounds-check pairing rule. Both
;; underflow states must still take the ordinary array bounds abort at opt0 and
;; opt2: sp=1 makes only sp-2 wrap, while sp=0 makes both indices wrap.
(import stdlib.array)
(import stdlib.io)
(import stdlib.string)

(defenum UnderflowInst
  (Push0)
  (Push1)
  (Push2)
  (Push3)
  (Push4)
  (Add))

(define (push-value [stack : (Array i64)] [sp : i64] [value : i64]) : i64
  (begin
    (array-set! stack sp value)
    (+ sp 1)))

(define (run-underflow
  [program : (Array UnderflowInst)]
  [stack : (Array i64)]
  [initial-sp : i64]) : i64
  (let
    [pc : i64 0]
    [sp : i64 initial-sp]
    (begin
      (while (< pc (array-length program))
        (begin
          (match (array-ref program pc)
            [(Push0) (set! sp (push-value stack sp 0))]
            [(Push1) (set! sp (push-value stack sp 1))]
            [(Push2) (set! sp (push-value stack sp 2))]
            [(Push3) (set! sp (push-value stack sp 3))]
            [(Push4) (set! sp (push-value stack sp 4))]
            [(Add)
              (let
                [right : i64 (array-ref stack (- sp 1))]
                [left : i64 (array-ref stack (- sp 2))]
                (begin
                  (array-set! stack (- sp 2) (+ left right))
                  (set! sp (- sp 1))))])
          (set! pc (+ pc 1))))
      0)))

(define (main) : i64
  (let
    [initial-sp : i64 (string.>int (io.arg 1))]
    [program : (Array UnderflowInst) (make-array (Add))]
    [stack : (Array i64) (array.make-array i64 4)]
    (run-underflow program stack initial-sp)))