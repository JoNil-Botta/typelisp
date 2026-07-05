; refs #331: aggregate globals are initialized through hidden runtime
; initializer functions, whose returned pointers are stored before main.
(import stdlib.string)
(import stdlib.option)
(import (option i64) as option_i64)

(defstruct Pair
  (x i64)
  (y i64))

(defstruct Nested
  (label String)
  (choice option_i64.Option))

(define greeting
  "hello")
(define choice : option_i64.Option
  (option_i64.Some 8))
(define pair
  (Pair 10 11))

; Compatibility exception for #3772: aggregate global initializers still require
; the bare dynamic-array allocation alias in stage0's hidden initializer path.
(define cells
  (make-array i64 3))
(define nested : Nested
  (Nested "ok" (option_i64.Some 3)))

(define (make-pair [x : i64] [y : i64]) : Pair
  (Pair x y))

(define (reset-pair!) : unit
  (set! pair (make-pair 12 9)))

(define (clobber-pair-stack [n : i64]) : i64
  (let
    [p : Pair (make-pair n (+ n 1))]
    (if (<= n 0)
      (+ (struct-get p x) (struct-get p y))
      (+ (struct-get p x) (clobber-pair-stack (- n 1))))))

(define (main) : i64
  (begin
    (reset-pair!)
    (clobber-pair-stack 24)
    (+
      (+
        (+ (string-length greeting) (length cells))
        (+ (struct-get pair x) (struct-get pair y)))
      (+
        (match choice
          [(option_i64.Some n) n]
          [(option_i64.None) 0])
        (+
          (string-length (struct-get nested label))
          (match (struct-get nested choice)
            [(option_i64.Some n) n]
            [(option_i64.None) 0]))))))
