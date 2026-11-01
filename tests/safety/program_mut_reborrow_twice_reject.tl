;; A call taking `(&mut program T)` may keep its argument for the whole
;; program, so the reborrow it receives never ends: a second one would alias it
;; (Rust E0499 for `&'static mut`). Main 4e46ce356 accepts it.
(defstruct Pt
  (name String)
  (x i64))

(define (keep [_r : (&mut program Pt)]) : unit
  unit)

(define (twice [r : (&mut program Pt)]) : unit
  (keep r)
  (keep r))

(define (main) : i64
  42)