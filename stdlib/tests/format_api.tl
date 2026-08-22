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

(define (main) : i64
  (let
    [state : FormatEvalState (FormatEvalState 0)]
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
      (string.eq owned-once "owned-owned"))
      42
      1)))