;; #7976: reads, shared borrows, owner functions and owner macros that call
;; them stay valid; the owner module writes its own globals.
(import foreign_global_dep as dep)
(import foreign_global_dep.counter)
(import foreign_global_dep.pair)
(import foreign_global_dep.slots)

(define (peek [value : (& i64)]) : i64
  (deref value))

(define (main) : i64
  (begin
    (dep.set-counter! 5)
    (dep.foreign-global-bump-via-writer! 6)
    (let
      [owner-result : i64 (dep.bump-inside-owner!)]
      [read : i64 (+ dep.counter (peek (& counter)))]
      [field : i64 (peek (& pair.right))]
      [element : i64 (peek (& (array-ref slots 0)))]
      [canonical : i64 foreign_global_dep.counter]
      (if (and
        (= owner-result 77)
        (= read 154)
        (= field 40)
        (= element 0)
        (= canonical 77))
        42
        1))))