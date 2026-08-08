;; Generated module bodies can expose a native Slice through a nested generated
;; vector import for both scalar and aggregate element types.
(import stdlib.test)
(import stdlib.vector)

(defstruct Pair
  (value i64))

(defmacro (slice-user [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.native_slice_user." (type-key T)))]
    `(begin
      (module ,module-name)
      (import (vector.vector ,T) as vec)
      (define (score [first : ,T]) : i64
        (let
          [items : vec.Vec (vec.new)]
          (begin
            (vec.push-ref! (&mut items) first)
            (let
              [view : (& items (Slice ,T)) (vec.view (& items))]
              (if (= (array-length view) 1)
                (begin
                  (array-ref view 0)
                  42)
                0))))))))

(import (slice-user i64) as user)
(import (slice-user Pair) as pair-user)

(test
  generated-module-body-imports-vector-native-slice-i64
  (test.assert-i64-eq (user.score 7) 42 "generated body exposes native slice"))

(test
  generated-module-body-imports-vector-native-slice-struct
  (test.assert-i64-eq
    (pair-user.score (Pair 7))
    42
    "generated body exposes native aggregate slice"))