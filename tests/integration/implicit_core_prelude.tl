;; implicit_core_prelude.tl - Regression smoke for the implicit core macro
;; prelude (#2060). This program imports NOTHING: bare `and`, `or` (including the
;; n-ary forms that only the macro accepts), `when`, and `unless` resolve to
;; stdlib/core_macros.tl, which the compile driver always links into every
;; program. Exit 42 confirms the prelude macros expanded and ran.
(define (main) : i64
  (let
    [value : i64 0]
    (begin
      ;; n-ary `and`/`or` (3 operands) parse as ordinary calls and only
      ;; typecheck because the prelude macro owns them.
      (when (and (> 5 3) (< 2 4) (= 1 1)) (set! value (+ value 10)))
      (unless (or false false false) (set! value (+ value 20)))
      ;; binary `and`/`or` and the guard forms route through the prelude too.
      (if (and true true)
        (set! value (+ value 6))
        unit)
      (if (or false true)
        (set! value (+ value 6))
        unit)
      value)))