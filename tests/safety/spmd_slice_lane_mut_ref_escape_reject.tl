;; A per-lane mutable reference derived from a Slice cannot escape into a
;; closure, even when the closure itself remains inside the foreach body.
(define (capture-lane-ref! [output : (&mut output (Slice i64))] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [slot : (&mut output i64) (&mut (array-ref output i))]
      [saved : (-> i64)
        (lambda () : i64
          (deref slot))]
      unit)))

(define (main) : i64
  42)