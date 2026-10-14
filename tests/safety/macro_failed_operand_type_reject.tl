;; `for` asks `expr-type` about its source. When that operand fails to
;; typecheck, the operand's own error is reported (#8871), not "expr-type
;; requires a typechecked Expr" at 1:1.
(define limit : i64
  65536)

(define (main) : i64
  (let
    [total : i64 0]
    (for [index (array 0 limit)]
      (set! total index))
    total))