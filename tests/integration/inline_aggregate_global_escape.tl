; Copy the observed scalar before replacing the global's owning value.
; The shared borrow ends at the call, so the later setter cannot invalidate it.
(import stdlib.io)

(defstruct Cell
  (slots (__tl_dyn-array i64))
  (len i64))

(define held : Cell
  (Cell (__tl_make-array i64 4) 4))

(define (install! [n : i64]) : unit
  (set! held (Cell (__tl_make-array i64 n) n)))

(define (observe [c : (& Cell)]) : i64
  c.len)

(define (main) : i64
  (let
    [observed : i64 (observe (& held))]
    (install! 9)
    (io.print-format "{}\n" observed))
  42)