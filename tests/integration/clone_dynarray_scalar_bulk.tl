(import stdlib.arena)
(import stdlib.string)

(defstruct Pair
  (left i64)
  (right i64))

(define (make-i64-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    [i : i64 0]
    (begin
      (while (< i 64)
        (begin
          (set! (array-ref items i) (+ i 1))
          (set! i (+ i 1))))
      items)))

(define (clone-sum [items : (__tl_dyn-array i64)] [rounds : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    [n : i64 (array-length items)]
    (begin
      (while (< i rounds)
        (let
          [copy : (__tl_dyn-array i64) (clone items)]
          (begin
            (set! acc (+ acc (array-ref copy (% i n))))
            (set! i (+ i 1)))))
      acc)))

(define (i64-copy-independent?) : bool
  (let
    [items : (__tl_dyn-array i64) (make-i64-items)]
    [copy : (__tl_dyn-array i64) (clone items)]
    (begin
      (set! (array-ref copy 0) 999)
      (and (= (array-ref items 0) 1) (= (array-ref copy 0) 999)))))

(define (make-pairs) : (__tl_dyn-array Pair)
  (__tl_make-array (Pair 1 2) (Pair 3 4)))

(define (pair-score [p : Pair]) : i64
  (+ p.left p.right))

(define (pair-copy-independent?) : bool
  (let
    [items : (__tl_dyn-array Pair) (make-pairs)]
    [copy : (__tl_dyn-array Pair) (clone items)]
    (begin
      (set! (array-ref copy 1) (Pair 70 80))
      (and
        (= (pair-score (array-ref items 1)) 7)
        (= (pair-score (array-ref copy 1)) 150)))))

(define (scratch-string-array-copy-ok?) : bool
  (let
    [home : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    (begin
      (unsafe
        (arena.set! scratch))
      (let
        [items : (__tl_dyn-array String) (__tl_make-array String 2)]
        (begin
          (set! (array-ref items 0) (string.append "s" "0"))
          (set! (array-ref items 1) (string.append "s" "1"))
          (unsafe
            (arena.set! home))
          (let
            [copy : (__tl_dyn-array String) (clone items)]
            (begin
              (unsafe
                (arena.destroy scratch))
              (and
                (string.eq (array-ref copy 0) "s0")
                (string.eq (array-ref copy 1) "s1")))))))))

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (make-i64-items)]
    [sum : i64 (clone-sum items 1024)]
    (begin
      (unless (= sum 33280) (return 2))
      (unless (i64-copy-independent?) (return 3))
      (unless (pair-copy-independent?) (return 4))
      (unless (scratch-string-array-copy-ok?) (return 5))
      42)))