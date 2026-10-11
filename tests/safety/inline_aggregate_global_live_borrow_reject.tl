; The live global borrow crosses a setter call and must fail before lowering.
; Keep the original escape shape at every optimization level on both targets.
(import stdlib.io)

(defstruct Cell
  (slots (__tl_dyn-array i64))
  (len i64))

(define held : Cell
  (Cell (__tl_make-array i64 4) 4))

(define (install! [n : i64]) : unit
  (set! held (Cell (__tl_make-array i64 n) n)))

(define (observe [c : (& Cell)]) : i64
  (install! 9)
  c.len)

(define (main) : i64
  (io.print-format "{}\n" (observe (& held)))
  42)
