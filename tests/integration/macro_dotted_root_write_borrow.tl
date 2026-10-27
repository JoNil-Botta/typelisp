(defstruct Wide
  (x i64)
  (y i64)
  (guard i64))

(defstruct Narrow
  (x u8)
  (y u8)
  (guard u8))

(define state : Wide
  (Wide 257 66051 131585))

(defmacro (write-y!) : Expr
  `(set! (deref (&mut state.y)) 9))

(define (control!) : unit
  (write-y!))

(define (shadow! [state : (&mut p Narrow)]) : i64
  (write-y!)
  (cast state.y : i64))

(define (main) : i64
  (control!)
  (unless (= state.y 9) (return 2))
  (set! state.y 66051)
  (let
    [other : Narrow (Narrow 17 23 41)]
    (unless (= (shadow! (&mut other)) 23) (return 1))
    (unless (= other.x 17) (return 3))
    (unless (= other.y 23) (return 4))
    (unless (= other.guard 41) (return 5)))
  (unless (= state.x 257) (return 6))
  (unless (= state.y 9) (return 7))
  (unless (= state.guard 131585) (return 8))
  42)