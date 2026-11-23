;; Internal global stores must preserve unrelated register homes, including
;; ABI return registers that remain live after a preceding allocation or load.
(import stdlib.iterator)
(import stdlib.test)

(defstruct Word
  (value i64))

(defstruct Ints
  (x i64)
  (y i64))

(defstruct Floats
  (x f64)
  (y f64))

(defstruct IntFloat
  (x i64)
  (y f64))

(defstruct FloatInt
  (x f64)
  (y i64))

(defenum Choice
  (Value i64)
  (Empty))

(define ints : Ints
  (Ints 7 8))
(define floats : Floats
  (Floats 7.0 8.0))
(define int-float : IntFloat
  (IntFloat 7 8.0))
(define float-int : FloatInt
  (FloatInt 7.0 8))
(define choice : Choice
  (Value 7))

(define (touch-ints [local : (& r Word)] [copied : Ints]) : i64
  (set! ints (Ints 98 99))
  (+ local.value (+ copied.x copied.y)))

(define (touch-floats [live : f64] [copied : Floats]) : f64
  (set! floats (Floats 98.0 99.0))
  (+ live (+ copied.x copied.y)))

(define (touch-int-float [live : f64] [copied : IntFloat]) : f64
  (set! int-float (IntFloat 98 99.0))
  (+ live (+ (cast copied.x : f64) copied.y)))

(define (touch-float-int [live : f64] [copied : FloatInt]) : f64
  (set! float-int (FloatInt 98.0 99))
  (+ live (+ copied.x (cast copied.y : f64))))

(define (touch-choice [local : (& r Word)] [copied : Choice]) : i64
  (set! choice (Value 99))
  (+
    local.value
    (match copied
      [(Value n) n]
      [(Empty) 0])))

(define (check-values) : i64
  (let
    [local : Word (Word 10)]
    (for [n (iterator.range -3 5)]
      (let
        [f : f64 (cast n : f64)]
        (set! ints (Ints n (+ n 1)))
        (set! floats (Floats f (+ f 1.0)))
        (set! int-float (IntFloat n (+ f 1.0)))
        (set! float-int (FloatInt f (+ n 1)))
        (set! choice (Value n))
        (unless (= (touch-ints (& local) ints) (+ 11 (* n 2))) (return 1))
        (unless (and (= ints.x 98) (= ints.y 99)) (return 2))
        (unless (= (touch-floats f floats) (+ 1.0 (* f 3.0))) (return 3))
        (unless (and (= floats.x 98.0) (= floats.y 99.0)) (return 4))
        (unless (= (touch-int-float f int-float) (+ 1.0 (* f 3.0))) (return 5))
        (unless (and (= int-float.x 98) (= int-float.y 99.0)) (return 6))
        (unless (= (touch-float-int f float-int) (+ 1.0 (* f 3.0))) (return 7))
        (unless (and (= float-int.x 98.0) (= float-int.y 99)) (return 8))
        (unless (= (touch-choice (& local) choice) (+ 10 n)) (return 9))
        (unless
          (match choice
            [(Value x) (= x 99)]
            [(Empty) false])
          (return 10)))))
  42)

(define (main) : i64
  (check-values))

(test
  global-pair-store-live
  (test.assert-i64-eq
    (check-values)
    42
    "global stores preserve live homes and both words"))