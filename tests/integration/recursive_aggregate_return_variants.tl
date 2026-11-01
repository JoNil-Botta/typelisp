(defstruct Big
  (a i64)
  (b i64)
  (c i64))

(defstruct Pair
  (a i64)
  (b i64))

(define (make-big [depth : i64] [seed : i64]) : Big
  (if (> depth 0)
    (make-big (- depth 1) (+ seed 1))
    (Big seed (+ seed 1) (+ seed 2))))

;; A register-class nominal result keeps the ordinary aggregate return path.
(define (make-pair [depth : i64]) : Pair
  (if (> depth 0)
    (make-pair (- depth 1))
    (Pair 20 22)))

;; Structural results use the leading hidden pointer when memory-class.
(define (make-fixed-array [depth : i64]) : (Array i64 3)
  (if (> depth 0)
    (make-fixed-array (- depth 1))
    (array 10 11 21)))

(define (make-tuple [depth : i64]) : (Tuple i64 i64)
  (if (> depth 0)
    (make-tuple (- depth 1))
    (tuple 20 22)))

;; Mutual tail calls remain distinct activations instead of self-loop copies.
(define (make-even [depth : i64]) : Big
  (if (> depth 0)
    (make-odd (- depth 1))
    (Big 10 11 21)))

(define (make-odd [depth : i64]) : Big
  (if (> depth 0)
    (make-even (- depth 1))
    (Big 20 21 1)))

(define (main) : i64
  (let
    [deep : Big (make-big 256 10)]
    [next : Big (make-big 3 20)]
    [pair : Pair (make-pair 128)]
    [values : (Array i64 3) (make-fixed-array 128)]
    [tuple-value : (Tuple i64 i64) (make-tuple 128)]
    [even : Big (make-even 32)]
    [odd : Big (make-even 33)]
    (if (and
      (= deep.a 266)
      (= deep.b 267)
      (= deep.c 268)
      (= next.a 23)
      (= next.b 24)
      (= next.c 25)
      (= pair.a 20)
      (= pair.b 22)
      (= (array-ref values 0) 10)
      (= (array-ref values 1) 11)
      (= (array-ref values 2) 21)
      (= (tuple-ref tuple-value 0) 20)
      (= (tuple-ref tuple-value 1) 22)
      (= even.a 10)
      (= even.b 11)
      (= even.c 21)
      (= odd.a 20)
      (= odd.b 21)
      (= odd.c 1))
      42
      1)))