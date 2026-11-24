;; A macro body cannot reach the runtime abort path through a stdlib function:
;; `assert-true` calls the runtime assertion hook, so it lacks the PURE
;; certificate in prebuilt stdlib.tli and the call is rejected exactly as with
;; --no-prebuilt-stdlib.
(import stdlib.test)

(defmacro (checked-zero) : Expr
  (test.assert-true true "probe")
  (expr-int 0))

(define (main) : i64
  (checked-zero))