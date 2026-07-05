;; macro_generated_match_patterns.tl - public comptime Pattern API coverage (#3977).
(import stdlib.test)
(import stdlib.comptime)

(defenum GeneratedChoice
  (GeneratedEmpty)
  (GeneratedOne i64)
  (GeneratedPair i64 i64))

(defmacro (generated-choice-score [value : GeneratedChoice]) : i64
  (let
    [empty-payloads : PatternList (comptime.pattern-list-empty)]
    [empty-pattern : Pattern
      (comptime.pattern-variant "GeneratedChoice.GeneratedEmpty" empty-payloads)]
    [one-pattern : Pattern
      (comptime.pattern-variant
        "GeneratedOne"
        (comptime.pattern-list-cons
          (comptime.pattern-binding "x")
          (comptime.pattern-list-empty)))]
    [pair-pattern : Pattern
      (comptime.pattern-variant
        "GeneratedPair"
        (comptime.pattern-list-cons
          (comptime.pattern-binding "left")
          (comptime.pattern-list-cons
            (comptime.pattern-binding "right")
            (comptime.pattern-list-empty))))]
    [pair-body : Expr
      `(+ ,(comptime.expr-var "left") ,(comptime.expr-var "right"))]
    [arms : MatchArmList
      (comptime.match-arm-list-cons
        (comptime.match-arm empty-pattern (comptime.expr-int 0))
        (comptime.match-arm-list-cons
          (comptime.match-arm one-pattern (comptime.expr-var "x"))
          (comptime.match-arm-list-cons
            (comptime.match-arm pair-pattern pair-body)
            (comptime.match-arm-list-empty))))]
    (comptime.expr-match value arms)))

(test
  generated-enum-match-pattern-api
  (begin
    (test.assert-i64-eq
      (generated-choice-score (GeneratedEmpty))
      0
      "generated match handles qualified nullary variant pattern")
    (test.assert-i64-eq
      (generated-choice-score (GeneratedOne 42))
      42
      "generated match binds unary enum payload")
    (test.assert-i64-eq
      (generated-choice-score (GeneratedPair 20 22))
      42
      "generated match binds binary enum payloads")))