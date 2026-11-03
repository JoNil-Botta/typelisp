;; A constructor's lifetime formals are inferred from its arguments even where
;; a binding at the call site has the same spelling: the field types are the
;; declaration's, so a formal never names that binding's lifetime (#8998).
(defenum Text
  (:lifetimes text)
  (Missing)
  (Present (& text str)))

(defstruct Command
  (:lifetimes program-name cwd)
  (name (& program-name str))
  (cwd (Text cwd)))

(define (present [value : (& value-text str)]) : (Text value-text)
  (Text.Present value))

;; A by-value parameter spelled like the formal.
(define (with-cwd-value
  [command : (& command (Command program-name cwd))]
  [cwd : (Text next-cwd)]) : (Command program-name next-cwd)
  (Command command.name cwd))

;; A reference parameter spelled like the formal, through a call.
(define (with-cwd
  [command : (& command (Command program-name cwd))]
  [cwd : (& next-cwd str)]) : (Command program-name next-cwd)
  (Command command.name (present cwd)))

;; The same through a variant constructor, whose formal is also spelled like
;; the parameter.
(define (with-cwd-variant
  [command : (& command (Command program-name cwd))]
  [cwd : (& next-cwd str)]) : (Command program-name next-cwd)
  (Command command.name (Text.Present cwd)))

(define (text-of [text : (& next str)]) : (Text next)
  (Text.Present text))

;; A local spelled like the formal, and a result typed by its annotation.
(define (with-cwd-local [name : (& program-name str)] [value : (Text next-cwd)]) : (Command
    program-name
    next-cwd)
  (let
    [cwd : i64 0]
    [command : (Command program-name next-cwd) (Command name value)]
    command))

(define (main) : i64
  0)