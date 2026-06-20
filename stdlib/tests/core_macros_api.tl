(import stdlib.core_macros as core)

(defenum Expr
  (ECoreMacroShadow i64))

(define (stdlib-core-macros-api-fixture [flag : bool]) : unit
  (let
    [value : i64 0]
    (begin
      (core/and)
      (core/and flag)
      (core/and flag true true)
      (core/or)
      (core/or flag)
      (core/or flag false false)
      (core/when flag (set! value 1))
      (core/unless flag (set! value 2))
      (let
        [_observed : i64 value]
        unit))))

(define (stdlib-core-cond-i64 [value : i64]) : i64
  (core/cond [(< value 0) 0] [(= value 0) 1] [else (+ value 1)]))

(define (stdlib-core-cond-user-expr-shadow) : i64
  (core/cond [true 42] [else 0]))

(define (stdlib-core-cond-string [flag : bool]) : String
  (core/cond [flag "yes"] [else "no"]))

(define (stdlib-core-cond-unit [flag : bool]) : unit
  (core/cond [flag unit] [else unit]))

(define (stdlib-core-macros-short-circuit-value) : i64
  (let
    [value : i64 0]
    (begin
      (if (core/and
        true
        false
        (begin
          (set! value 1000)
          true))
        (set! value 1000)
        unit)
      (if (core/or
        true
        (begin
          (set! value 1000)
          false))
        unit
        (set! value 1000))
      value)))