;; Expression macros inside `with` bindings and bodies expand under the
;; sequential resource-binding environment.
(import stdlib.test)

(defmacro (forty-one) : i64
  `41)

(defmacro (increment [value : i64]) : i64
  `(+ ,value 1))

(define (cleanup-i64 [_value : i64]) : unit
  unit)

(test
  macro-expands-inside-with-resource
  (with
    ([first (forty-one) cleanup-i64] [second (increment first) cleanup-i64])
    (begin
      (test.assert-i64-eq first 41 "macro expands in resource initializer")
      (test.assert-i64-eq
        second
        42
        "later resource initializer sees earlier binding")
      (test.assert-i64-eq
        (increment second)
        43
        "macro expands in resource body"))))