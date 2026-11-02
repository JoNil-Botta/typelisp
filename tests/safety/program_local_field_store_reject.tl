(defstruct Held
  (value (& program str)))

;; Even with a local named program, a program field cannot store its borrow.
(define (store [held : (&mut h Held)]) : unit
  (let
    [program : String (clone "local")]
    (set! held.value (& program program))))

(define (main) : i64
  0)