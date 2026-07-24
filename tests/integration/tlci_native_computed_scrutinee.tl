;; Differential corpus for the computed string-dispatch scrutinees that became
;; native tlci entries in #5604: `(match (type-kind (comptime.expr-type e)) ...)`
;; in `stdlib.math` exp/log/sqrt and `stdlib.io/format-value`, and
;; `(match (type-key T) ...)` in `stdlib.json/encode-int`, plus the `(cast e : T)`
;; template node the last two build. The compile-profile gate compiles this file
;; through the embedded (native) and the interpreted macro routes and requires
;; byte-identical assembly, so a divergence in the probe results, the arm
;; selection, or the reconstructed cast fails the build.
;; `stdlib.format` must precede `stdlib.json` here: the reverse order makes
;; `format.format`'s expansion fail to resolve `str_cat.str-cat` (#5648).
(import stdlib.format)

;; Referenced only as the serialize strategy module in the generated import
;; below, which the unused-import rule does not count as a reference.
;; lint-allow: unused-import
(import stdlib.json)
(import stdlib.math)
(import stdlib.serialize)
(import stdlib.string)

(defstruct Widths
  (small i32)
  (medium i64))

(import (serialize.serialize json Widths) as widths_json)

;; `math/exp`, `log`, and `sqrt` dispatch on the produced type of their operand,
;; so both f64 and f32 call sites must select their own arm.
(define (math-f64 [value : f64]) : f64
  (+ (math.exp value) (+ (math.log value) (math.sqrt value))))

(define (math-f32 [value : f32]) : f32
  (+ (math.exp value) (+ (math.log value) (math.sqrt value))))

;; `io/format-value` dispatches over string/i64/bool/char/f64/f32 arms; the f32
;; arm is the one that builds `(cast ,value : f64)`.
(define (describe
  [label : String]
  [count : i64]
  [flag : bool]
  [sep : char]
  [wide : f64]
  [narrow : f32]) : String
  (format.format "{}{}{}{}{}{}" label count flag sep wide narrow))

;; `json/encode-int` dispatches on the field's `type-key` and builds
;; `(cast ,value : i64)` for every non-u64 width.
(define (round-trip [value : Widths]) : i64
  (match (widths_json.decode (widths_json.encode value))
    [(widths_json.Ok decoded)
      (if (and
        (= (struct-get decoded small) (struct-get value small))
        (= (struct-get decoded medium) (struct-get value medium)))
        (struct-get decoded medium)
        -1)]
    [(widths_json.Err _) -2]))

(define (main) : i64
  (let
    [widths : Widths (Widths (cast 3 : i32) 9)]
    [rendered : String (describe "n=" 7 true '/' 1.5 0.5)]
    (if (and
      (string.eq rendered "n=7true/1.50.5")
      (= (round-trip widths) 9)
      (> (math-f64 2.0) 0.0)
      (> (math-f32 2.0) 0.0))
      42
      1)))