; IAG-1: the escape shape the safety rule refuses. `observe` holds a borrow of
; the aggregate global across a call that rebinds it, so the box identity is
; observable and the classification must leave this global boxed. The printed
; value must be byte-identical to the pre-IAG compiler at every opt level: the
; current baseline is 4 at opt0/1 and 9 at opt2, where inlining materializes
; the borrow after the rebind.
(import stdlib.io)

(defstruct Cell
  (slots (__tl_dyn-array i64))
  (len i64))

(define held : Cell
  (Cell (__tl_make-array i64 4) 4))

(define (install! [n : i64]) : unit
  (set! held (Cell (__tl_make-array i64 n) n)))

(define (observe [c : (& Cell)]) : i64
  (begin
    (install! 9)
    c.len))

(define (main) : i64
  (begin
    (io.print-format "{}\n" (observe (& held)))
    42))