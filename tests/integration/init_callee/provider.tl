;; A module with its own `range`, for comptime_init_callee. A bare call to it
;; from inside this module reports this module's identity unless a local of
;; the same name shadows it.
(import init_callee.probe)

(define (range [first : i64] [last : i64]) : i64
  (- last first))

(defstruct Pair
  (left i64)
  (right i64))

(define limit : i64
  3)

(define (bare-callee) : String
  (probe.callee-of [x (range 0 3)]))

(define (shadowed-callee) : String
  (let
    [range
      (lambda ([first : i64] [last : i64]) : i64
        (+ first last))]
    (probe.callee-of [x (range 0 3)])))

(define (parameter-callee [range : (-> i64 i64 i64)]) : String
  (probe.callee-of [x (range 0 3)]))