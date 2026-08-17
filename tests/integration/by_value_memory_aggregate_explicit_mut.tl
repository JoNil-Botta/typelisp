;; Refs #6215: a memory-class by-value aggregate has private callee storage,
;; while an explicit mutable reference remains caller-visible.
(defstruct WidePair
  (left i64)
  (right i64)
  (padding i64))

(define (set-left-local [pair : WidePair] [value : i64]) : i64
  (begin
    (set! pair.left value)
    pair.left))

(define (set-left! [pair : (&mut pair WidePair)] [value : i64]) : unit
  (set! pair.left value))

(define (main) : i64
  (let
    [pair : WidePair (WidePair 0 2 3)]
    [local-left : i64 (set-left-local pair 40)]
    (begin
      (set-left! (&mut pair) 2)
      (+ local-left pair.left))))
