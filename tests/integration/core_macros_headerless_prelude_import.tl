;; core_macros_headerless_prelude_import.tl - Regression for headerless
;; stdlib.core_macros loading as the implicit prelude and as an explicit import.
(import stdlib.core_macros as core)

(define (main) : i64
  (let
    [value : i64 0]
    [short : i64 0]
    (begin
      (when (and true true true) (set! value (+ value 10)))
      (core/when (core/and true true) (set! value (+ value 20)))
      (core/unless (core/or false false) (set! value (+ value 10)))
      (set! value (+ value (core/cond [false 0] [true 2] [else 100])))
      (if (core/and
        false
        (begin
          (set! short 1000)
          true))
        (set! short 1000)
        unit)
      (if (or false true)
        (set! value (+ value 0))
        (set! short 1000))
      (if (and (= value 42) (= short 0))
        42
        value))))