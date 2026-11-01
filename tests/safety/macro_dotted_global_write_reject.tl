(import macro_dotted_global_dep as dep)

(define (main) : i64
  (let
    [state : dep.Pair (dep.Pair 20 30)]
    (dep.write-y!)
    state.y))