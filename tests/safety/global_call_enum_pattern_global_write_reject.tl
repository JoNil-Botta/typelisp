(import global_call_enum_pattern_dep as patterns)

(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (mutate!) : unit
  ;; A nullary enum pattern does not introduce a local named g. The nested
  ;; match also exercises conservative scope handling without a shallow type.
  (match (match true
    [true (patterns.State.g)]
    [false (patterns.State.Other)])
    [g (set! g (Big 9 9 9 9))]
    [Other unit]))

(define (observe [value : (& r Big)]) : i64
  (mutate!)
  value.a)

(define (main) : i64
  (observe (& g)))