(defstruct Wide
  (x i64)
  (y i64)
  (guard i64))

(defstruct Pair
  (x i64)
  (y i64))

(define state : Wide
  (Wide 257 66051 131585))

(defmacro (write-y!) : Expr
  `(set! (deref (&mut state.y)) 77))

(define (control!) : unit
  (write-y!))

(define (shadow! [state : Pair]) : i64
  (write-y!)
  (unless (= state.x 17) (return 1))
  (unless (= state.y 23) (return 2))
  42)

(define (main) : i64
  (control!)
  (unless (= state.y 77) (return 1))
  (set! state.y 66051)
  (unless (= (shadow! (Pair 17 23)) 42) (return 2))
  (unless (= state.x 257) (return 3))
  (unless (= state.y 77) (return 4))
  (unless (= state.guard 131585) (return 5))
  42)