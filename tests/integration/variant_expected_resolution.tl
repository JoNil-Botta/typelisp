;; Bare variant names resolve against the expected enum type (SPEC 3.5.1):
;; return and tail positions, typed lets, call arguments, struct fields,
;; variant payloads, `set!` targets, an imported enum and a comptime-generated
;; family enum. `Local` and `Level` repeat the provider's variant names in
;; another order, so a bare name lowered against the wrong enum changes the
;; exit status.
(import variant_expected_resolution_lib as lib)
(import stdlib.option)
(import (option.option i64) as option_i64)

(defenum Local
  (Pass i64)
  (Fail i64))

(defenum Level
  (High i64)
  (Low))

(defstruct Holder
  (outcome lib.Outcome)
  (level Level))

(defenum Wrap
  (Outer lib.Outcome)
  (Nested Holder)
  (Empty))

(define (returned [x : i64]) : lib.Outcome
  (Pass x))

(define (tail [early : bool] [x : i64]) : lib.Outcome
  (if early
    (Pass x)
    (let
      [next : i64 (+ x 1)]
      (match next
        [0 (Fail 0)]
        [_ (Fail next)]))))

(define (flag) : lib.Flag
  Low)

(define (maybe [x : i64]) : option_i64.Option
  (if (> x 0)
    (Some x)
    None))

(define (level-value [level : Level]) : i64
  (match level
    [(High value) value]
    [Low 0]))

(define (local-value [local : Local]) : i64
  (match local
    [(Pass value) value]
    [(Fail value) value]))

(define (main) : i64
  (let
    [typed : lib.Outcome (Pass 5)]
    [mutable : lib.Outcome (Fail 9)]
    [holder : Holder (Holder (Fail 3) (High 2))]
    [wrapped : Wrap (Nested (Holder (Pass 1) Low))]
    [outer : Wrap (Outer (Fail 50))]
    (begin
      (set! mutable (Pass 4))
      (set! holder.outcome (Pass 6))
      (+
        (lib.outcome-value (returned 10))
        (lib.outcome-value (tail true 7))
        (lib.outcome-value (tail false 4))
        (lib.outcome-value typed)
        (lib.outcome-value mutable)
        (lib.outcome-value holder.outcome)
        (level-value holder.level)
        (lib.flag-value (flag))
        (match wrapped
          [(Nested (Holder outcome level))
            (+ (lib.outcome-value outcome) (level-value level))]
          [_ 100])
        (match outer
          [(Outer (Fail value)) (- value 50)]
          [_ 100])
        (lib.outcome-value (Fail 2))
        (match (maybe 3)
          [(Some value) value]
          [None 100])
        (match (maybe 0)
          [(Some _) 100]
          [None 0])
        (local-value (Pass 10))))))