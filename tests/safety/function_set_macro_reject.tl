(import function_assignment_dep as dep)

(define (main) : i64
  (let
    [cap : (-> i64) dep.big]
    (begin
      (dep.set-cap dep.big)
      (cap))))