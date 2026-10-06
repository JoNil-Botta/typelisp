(defmacro (emit-loop) : Decls
  '(define (generated-loop [value : i64]) : unit
    (while false
      value
      unit)))

(emit-loop)

(define (main) : i64
  0)