(import stdlib.comptime)
(import stdlib.arena)

;; Reflection keeps an `(:invalidate r T)` parameter as its own wrapper kind
;; (#6670): `function-param-type` returns it and `type-kind` reports
;; `invalidate`, while the next parameter reflects as its ordinary type.
(defmacro (invalidate-param-kind-code [f : type]) : i64
  (let
    [first : String (type-kind (function-param-type f 0))]
    [second : String (type-kind (function-param-type f 1))]
    (comptime.expr-int
      (match first
        ["invalidate"
          (match second
            ["i64" 42]
            [_ 2])]
        [_ 1]))))

(define (main) : i64
  (invalidate-param-kind-code
    (type (-> (:invalidate r (arena.Arena r)) i64 unit))))