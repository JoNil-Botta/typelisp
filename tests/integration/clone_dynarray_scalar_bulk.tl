(import stdlib.array)
(import "stdlib/arena.tl")
(import "stdlib/string.tl")

(defstruct Pair
  (left i64)
  (right i64))

(define (make-i64-items) : (Array i64)
  (let
    [items : (Array i64) (array.make-array i64 64)]
    [i : i64 0]
    (begin
      (while (< i 64)
        (begin
          (array.array-set! items i (+ i 1))
          (set! i (+ i 1))))
      items)))

(define (clone-sum [items : (Array i64)] [rounds : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    [n : i64 (array.array-length items)]
    (begin
      (while (< i rounds)
        (let
          [copy : (Array i64) (clone items)]
          (begin
            (set! acc (+ acc (array.array-ref copy (% i n))))
            (set! i (+ i 1)))))
      acc)))

(define (i64-copy-independent?) : bool
  (let
    [items : (Array i64) (make-i64-items)]
    [copy : (Array i64) (clone items)]
    (begin
      (array.array-set! copy 0 999)
      (and (= (array.array-ref items 0) 1) (= (array.array-ref copy 0) 999)))))

(define (make-pairs) : (Array Pair)
  (let
    [items : (Array Pair) (array.make-array Pair 2)]
    (begin
      (array.array-set! items 0 (Pair 1 2))
      (array.array-set! items 1 (Pair 3 4))
      items)))

(define (pair-score [p : Pair]) : i64
  (+ (struct-get p left) (struct-get p right)))

(define (pair-copy-independent?) : bool
  (let
    [items : (Array Pair) (make-pairs)]
    [copy : (Array Pair) (clone items)]
    (begin
      (array.array-set! copy 1 (Pair 70 80))
      (and
        (= (pair-score (array.array-ref items 1)) 7)
        (= (pair-score (array.array-ref copy 1)) 150)))))

(define (scratch-string-array-copy-ok?) : bool
  (let
    [home : Arena (arena-current)]
    [scratch : Arena (arena-make)]
    (begin
      (unsafe
        (arena-set! scratch))
      (let
        [items : (Array String) (array.make-array String 2)]
        (begin
          (array.array-set! items 0 (string-append "s" "0"))
          (array.array-set! items 1 (string-append "s" "1"))
          (unsafe
            (arena-set! home))
          (let
            [copy : (Array String) (clone items)]
            (begin
              (unsafe
                (arena-destroy scratch))
              (and
                (string-eq (array.array-ref copy 0) "s0")
                (string-eq (array.array-ref copy 1) "s1")))))))))

(define (main) : i64
  (let
    [items : (Array i64) (make-i64-items)]
    [sum : i64 (clone-sum items 1024)]
    (begin
      (unless (= sum 33280) (return 2))
      (unless (i64-copy-independent?) (return 3))
      (unless (pair-copy-independent?) (return 4))
      (unless (scratch-string-array-copy-ok?) (return 5))
      42)))