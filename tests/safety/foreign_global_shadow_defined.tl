;; #7976: a local or parameter that shadows an imported global, and caller
;; syntax naming a local passed through the owner's macro, are ordinary
;; local places.
(import foreign_global_dep.counter)
(import foreign_global_dep as dep)

(define (bump-parameter [counter : i64]) : i64
  (begin
    (set! counter (+ counter 1))
    counter))

(define (main) : i64
  (let
    [local : i64
      (let
        [counter : i64 10]
        (begin
          (set! counter 20)
          counter))]
    [through-macro : i64
      (let
        [target : i64 0]
        (begin
          (dep.foreign-global-assign! target 11)
          target))]
    (if (and
      (= local 20)
      (= (bump-parameter 10) 11)
      (= through-macro 11)
      (= counter 1))
      42
      1)))