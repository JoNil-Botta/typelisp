(import stdlib.comptime)

(defenum GeneratedChoice
  (GeneratedEmpty)
  (GeneratedOne i64)
  (GeneratedPair i64 i64))

(defmacro (generated-choice-score [value : GeneratedChoice]) : i64
  (let
    [empty-pattern : Pattern
      (comptime.pattern-variant "GeneratedEmpty" (comptime.pattern-list-empty))]
    [one-pattern : Pattern
      (comptime.pattern-variant
        "GeneratedOne"
        (comptime.pattern-list-cons
          (comptime.pattern-binding "x")
          (comptime.pattern-list-empty)))]
    [arms : MatchArmList
      (comptime.match-arm-list-cons
        (comptime.match-arm empty-pattern (comptime.expr-int 0))
        (comptime.match-arm-list-cons
          (comptime.match-arm one-pattern (comptime.expr-var "x"))
          (comptime.match-arm-list-empty)))]
    (comptime.expr-match value arms)))

(define (main) : i64
  (generated-choice-score (GeneratedEmpty)))