;; Refs #9498: packed one/two-word enums and nested enum fields preserve their
;; representation. Owning String payloads still require a recursive snapshot.
(import stdlib.string)

(defenum Flag
  (:lifetimes owner)
  (FlagOff)
  (FlagOn))

(defenum FloatChoice
  (:lifetimes owner)
  (FloatEmpty)
  (FloatValue f64))

(defenum Choice
  (:lifetimes owner)
  (ChoiceEmpty)
  (ChoiceValue i64))

(defstruct Holder
  (:lifetimes owner)
  (value (Choice owner))
  (extra i64))

(defenum BareChoice
  (BareEmpty)
  (BareValue i64))

(defenum TextChoice
  (:lifetimes owner)
  (TextEmpty)
  (TextValue String))

(define (make-flag [_seed : (& owner i64)]) : (Flag owner)
  (FlagOn))

(define (make-float [_seed : (& owner i64)]) : (FloatChoice owner)
  (FloatValue 40.0))

(define (make-choice [_seed : (& owner i64)] [value : i64]) : (Choice owner)
  (ChoiceValue value))

(define (case-one-word [seed : (& owner i64)]) : bool
  (let
    [value (make-flag seed)]
    [extra : i64 41]
    [read
      (lambda () : i64
        (match value
          [FlagOff 1]
          [FlagOn (+ extra 1)]))]
    (= (read) 42)))

(define (case-float [seed : (& owner i64)]) : bool
  (let
    [value (make-float seed)]
    [extra : f64 2.0]
    [read
      (lambda () : f64
        (match value
          [FloatEmpty 1.0]
          [(FloatValue payload) (+ payload extra)]))]
    (= (read) 42.0)))

(define (case-nested [seed : (& owner i64)]) : bool
  (let
    [value (make-choice seed 40)]
    [holder : (Holder owner) (Holder value 2)]
    [read
      (lambda () : i64
        (match holder.value
          [ChoiceEmpty 1]
          [(ChoiceValue payload) (+ payload holder.extra)]))]
    (= (read) 42)))

(define (case-bare) : bool
  (let
    [value : BareChoice (BareValue 42)]
    [read
      (lambda () : i64
        (match value
          [BareEmpty 1]
          [(BareValue payload) payload]))]
    (= (read) 42)))

(define (case-uncaptured [seed : (& owner i64)]) : bool
  (match (make-choice seed 42)
    [ChoiceEmpty false]
    [(ChoiceValue payload) (= payload 42)]))

(define (case-memory [_seed : (& owner i64)]) : bool
  (let
    [text : String (string.append "enum" "-capture")]
    [value : (TextChoice owner) (TextValue text)]
    [read
      (lambda () : i64
        (match value
          [TextEmpty 0]
          [(TextValue payload) (string.string-length payload)]))]
    (= (read) 12)))

(define (main) : i64
  (let
    [seed : i64 1]
    (unless (case-one-word (& seed)) (return 1))
    (unless (case-float (& seed)) (return 2))
    (unless (case-nested (& seed)) (return 3))
    (unless (case-bare) (return 4))
    (unless (case-uncaptured (& seed)) (return 5))
    (unless (case-memory (& seed)) (return 6))
    42))