;; Refs #6188: memory-class aggregates are mutable through an explicit
;; reference parameter, while ordinary by-value parameters remain read-only.
(defstruct WidePair
  (left i64)
  (right i64)
  (padding i64))

(define (set-left! [pair : (&mut pair WidePair)] [value : i64]) : unit
  (set! (struct-get pair left) value))

(define (main) : i64
  (let
    [pair : WidePair (WidePair 0 2 3)]
    (begin
      (set-left! (&mut pair) 40)
      (+ (struct-get pair left) (struct-get pair right)))))