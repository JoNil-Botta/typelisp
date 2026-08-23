(import stdlib.format)
(import stdlib.string)

(defstruct RootDisplay
  (value i64))

(defstruct FormatEvalState
  (value i64))

(define (to-string [value : (& value RootDisplay)]) : String
  (format.format "root={}" value.value))

(define (format-counted [state : (&mut state FormatEvalState)] [digit : i64]) : i64
  (begin
    (set! state.value (+ (* state.value 10) digit))
    digit))

(define (format-nested-capture
  ;; Referenced by generated call-site capture syntax.
  ;; lint-allow: unused-variable
  [prefix : String]) : String
  ;; The extra lexical scope is the behavior under test.
  ;; lint-allow: nested-let
  (let
    ;; Referenced by generated call-site capture syntax.
    ;; lint-allow: unused-variable
    [answer : i64 42]
    (let
      ;; Referenced by generated call-site capture syntax.
      ;; lint-allow: unused-variable
      [suffix : String "done"]
      (format.format "{prefix}:{answer}:{suffix}"))))

(define (format-captured-width [value : String]) : String
  (let
    ;; Referenced by generated call-site capture syntax.
    ;; lint-allow: unused-variable
    [width : i64 5]
    (format.format "{:width$}" value)))

(define (main) : i64
  (let
    [state : FormatEvalState (FormatEvalState 0)]
    [width-state : FormatEvalState (FormatEvalState 0)]
    [name : String "Ada"]
    [score : i64 -7]
    [enabled : bool true]
    [mark : char 'x']
    [ratio : f64 1.5]
    [got : String
      (format.format
        "{}:{}:{}:{}:{}:{} {{ok}}"
        name
        score
        enabled
        mark
        ratio
        (RootDisplay 9))]
    [indexed : String (format.format "{2}/{0}/{1}/{2}" "a" "b" "c")]
    [leading-zero : String (format.format "{01}:{00}" "zero" "one")]
    [mixed : String (format.format "{1} {} {0} {}" "1" "2")]
    [named : String
      (format.format
        "{left}:{right}:{left}:{hyphen-name}"
        (format.named left "L")
        (format.named right "R")
        (format.named hyphen-name "H"))]
    [named-mixed : String
      (format.format "{name}:{}:{}" "P0" "P1" (format.named name "N"))]
    [captured : String (format-nested-capture "start")]
    ;; Referenced by generated call-site capture syntax. This contextual
    ;; keyword spelling is intentional.
    ;; lint-allow: unused-variable
    [type : String "keyword"]
    [keyword-capture : String (format.format "{type}")]
    [trailing-whitespace : String
      (format.format "{name \t\r\n}" (format.named name "space"))]
    [ordered : String
      (format.format
        "{2}:{0}:{1}:{2}"
        (format-counted (&mut state) 1)
        (format-counted (&mut state) 2)
        (format-counted (&mut state) 3))]
    [owned-once : String (format.format "{0}-{0}" (format.format "{}" "owned"))]
    [default-string-width : String (format.format "{:5}" "x")]
    [default-number-width : String (format.format "{:5}" (cast 12 : i64))]
    [fill-left : String (format.format "{:-<5}" "x")]
    [centered : String (format.format "{:^6}" "ab")]
    [right-aligned : String (format.format "{:>5}" "x")]
    [explicit-plus : String (format.format "{:+5}" (cast 12 : i64))]
    [minus-no-op : String (format.format "{:-5}" (cast 12 : i64))]
    [zero-positive : String (format.format "{:05}" (cast 12 : i64))]
    [zero-negative : String (format.format "{:05}" (cast -12 : i64))]
    [zero-plus : String (format.format "{:+05}" (cast 12 : i64))]
    [zero-width : String (format.format "{:0}" "x")]
    [equal-width : String (format.format "{:4}" "wide")]
    [short-width : String (format.format "{:2}" "long")]
    [alternate-carried : String (format.format "{:#}" (cast 12 : i64))]
    [dynamic-indexed : String (format.format "{0:1$}" "x" (cast 5 : i64))]
    [dynamic-no-advance : String
      (format.format "{:1$}:{}:{}" "a" (cast 4 : i64) "b")]
    [dynamic-named : String
      (format.format
        "{value:width$}"
        (format.named value "x")
        (format.named width (cast 4 : i64)))]
    [dynamic-captured : String (format-captured-width "x")]
    [owner-padded : String (format.format "{:>8}" (RootDisplay 9))]
    [dynamic-eval : String
      (format.format
        "{0:1$}:{1}"
        (format-counted (&mut width-state) 1)
        (format-counted (&mut width-state) 5))]
    [repeated-count : String
      (format.format "{0:1$}|{2:1$}|{1}" "a" (cast 3 : i64) "b")]
    (if (and
      (string.eq got "Ada:-7:true:x:1.5:root=9 {ok}")
      (string.eq indexed "c/a/b/c")
      (string.eq leading-zero "one:zero")
      (string.eq mixed "2 1 1 2")
      (string.eq named "L:R:L:H")
      (string.eq named-mixed "N:P0:P1")
      (string.eq captured "start:42:done")
      (string.eq keyword-capture "keyword")
      (string.eq trailing-whitespace "space")
      (string.eq ordered "3:1:2:3")
      (= state.value 123)
      (string.eq owned-once "owned-owned")
      (string.eq default-string-width "x    ")
      (string.eq default-number-width "   12")
      (string.eq fill-left "x----")
      (string.eq centered "  ab  ")
      (string.eq right-aligned "    x")
      (string.eq explicit-plus "  +12")
      (string.eq minus-no-op "   12")
      (string.eq zero-positive "00012")
      (string.eq zero-negative "-0012")
      (string.eq zero-plus "+0012")
      (string.eq zero-width "x")
      (string.eq equal-width "wide")
      (string.eq short-width "long")
      (string.eq alternate-carried "12")
      (string.eq dynamic-indexed "x    ")
      (string.eq dynamic-no-advance "a   :4:b")
      (string.eq dynamic-named "x   ")
      (string.eq dynamic-captured "x    ")
      (string.eq owner-padded "  root=9")
      (string.eq dynamic-eval "    1:5")
      (= width-state.value 15)
      (string.eq repeated-count "a  |b  |3"))
      42
      1)))