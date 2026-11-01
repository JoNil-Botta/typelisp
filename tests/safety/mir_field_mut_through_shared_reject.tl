;: A field behind a shared reference cannot be mutably borrowed (Rust E0596).
(defstruct Plan
  (marks (__tl_dyn-array i64))
  (count i64))

(define (fill [_items : (&mut items (__tl_dyn-array i64))]) : unit
  unit)

(define (reset [plan : (& plan Plan)]) : unit
  (fill (&mut plan.marks)))

(define (main) : i64
  0)