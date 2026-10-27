(import global_field_macro_dep as dep)

(define (main) : i64
  (let
    [state : dep.Pair (dep.Pair 20 30)]
    (unless (= (dep.read-y) 2) (return 1))
    (unless (= (dep.read-y-inside) 2) (return 2))
    (unless (= (dep.read-y-value) 2) (return 3))
    (unless (= (dep.read-nested) 6) (return 4))
    (unless (= (dep.with-local state.y) 33) (return 5))
    (unless (= (dep.caller-value state.y) 30) (return 6))
    (dep.write-y-inside! 4)
    (unless (= (dep.read-y) 4) (return 7))
    (dep.bump-y-inside! 1)
    (unless (= (dep.read-y) 5) (return 8))
    (unless (= (dep.read-y-inside) 5) (return 9))
    (unless (= state.y 30) (return 10))
    42))