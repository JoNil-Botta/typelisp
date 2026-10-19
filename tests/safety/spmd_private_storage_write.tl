;; Storage declared inside the gang belongs to one logical instance: varying
;; writes through uniform indexes into a body-local array, a helper-local
;; array, a local struct and its inline array field stay accepted, and reads
;; of that storage are varying. Uniform values through an array element's
;; field or tuple element at a uniform index stay accepted too.
(defstruct Pair
  (left i64)
  (right i64))

(defstruct Window
  (values (Array i64 2)))

(define (via-scratch [x : i64]) : i64
  (let
    [scratch : (Array i64 2) (array 0 0)]
    (begin
      (set! (array-ref scratch 1) (+ x 1))
      (array-ref scratch 1))))

(define (main) : i32
  (let
    [doubled : (Array i64 9) (array 0 0 0 0 0 0 0 0 0)]
    [bumped : (Array i64 9) (array 0 0 0 0 0 0 0 0 0)]
    [paired : (Array i64 9) (array 0 0 0 0 0 0 0 0 0)]
    [windowed : (Array i64 9) (array 0 0 0 0 0 0 0 0 0)]
    [pairs : (Array Pair 2) (array (Pair 0 0) (Pair 0 0))]
    [tuples : (Array (Tuple i64 i64) 2) (array (tuple 0 0) (tuple 0 0))]
    [answer : i64 42]
    (begin
      (foreach
        ([i : i64 0 9])
        (let
          [scratch : (Array i64 2) (array 0 0)]
          [pair : Pair (Pair 0 0)]
          [window : Window (Window (array 0 0))]
          [cell : (Tuple i64 i64) (tuple 0 0)]
          (begin
            (set! (array-ref scratch 0) (* i 2))
            (set! (array-ref doubled i) (array-ref scratch 0))
            (set! (array-ref bumped i) (via-scratch i))
            (set! pair.right (+ i 3))
            (set! (array-ref paired i) pair.right)
            (set! (array-ref window.values 1) i)
            (set! (tuple-ref cell 0) (array-ref window.values 1))
            (set! (array-ref windowed i) (tuple-ref cell 0))
            (set! (array-ref pairs 1).left answer)
            (set! (tuple-ref (array-ref tuples 1) 0) answer))))
      (if (and
        (= (array-ref doubled 8) 16)
        (= (array-ref bumped 8) 9)
        (= (array-ref paired 8) 11)
        (= (array-ref windowed 8) 8)
        (= (array-ref pairs 1).left 42)
        (= (array-ref pairs 0).left 0)
        (= (tuple-ref (array-ref tuples 1) 0) 42))
        42
        1))))