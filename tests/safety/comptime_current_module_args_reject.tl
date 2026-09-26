;; `comptime.current-module` takes no arguments (#8102).
(import stdlib.comptime)

(defmacro (bad) : String
  (comptime.expr-string (comptime.current-module 1)))

(define (main) : i64
  (begin
    (bad)
    0))