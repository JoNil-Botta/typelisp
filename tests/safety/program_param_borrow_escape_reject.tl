;; A call never instantiates the reserved `program` lifetime: a `program`
;; parameter takes only a `program` reference, so `wrap` cannot store a borrow
;; of the caller's local in a struct that outlives it (Rust E0597 for
;; `&'static`). Main 4e46ce356 accepts it, and `bad` returns a dangling name.
(defstruct Named
  (name (& program str)))

(define (wrap [name : (& program str)]) : Named
  (Named name))

(define (bad) : Named
  (let
    [text : String (clone "abc")]
    (wrap (& text))))

(define (main) : i64
  42)