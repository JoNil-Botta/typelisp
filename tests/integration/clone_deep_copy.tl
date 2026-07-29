(import stdlib.array)
(import stdlib.arena)
(import stdlib.string)

(defstruct Bundle
  (name String)
  (pair (Tuple String String))
  (fixed (Array String 2))
  (items (Array String)))

(define (score-bool [ok : bool]) : i64
  (if ok
    1
    0))

(define (sequence-score-from [items : (Array String)] [index : i64]) : i64
  (if (= index (array-length items))
    0
    (+
      (string-length (array-ref items index))
      (sequence-score-from items (+ index 1)))))

(define (sequence-score [items : (Array String)]) : i64
  (sequence-score-from items 0))

(define (bundle-score [bundle : Bundle]) : i64
  (+
    (score-bool (string.eq (struct-get bundle name) "name"))
    (+
      (score-bool (string.eq (tuple-ref (struct-get bundle pair) 0) "t0"))
      (+
        (score-bool (string.eq (tuple-ref (struct-get bundle pair) 1) "t1"))
        (+
          (score-bool (string.eq (array-ref (struct-get bundle fixed) 0) "f0"))
          (+
            (score-bool
              (string.eq (array-ref (struct-get bundle fixed) 1) "f1"))
            (+
              (score-bool
                (string.eq (array-ref (struct-get bundle items) 0) "d0"))
              (score-bool
                (string.eq (array-ref (struct-get bundle items) 1) "d1")))))))))

(define (make-bundle [items : (Array String)]) : Bundle
  (Bundle
    (string.append "na" "me")
    (tuple (string.append "t" "0") (string.append "t" "1"))
    (array (string.append "f" "0") (string.append "f" "1"))
    items))

(define (make-sequence) : (Array String)
  (make-array (string.append "a" "a") (string.append "b" "bb")))

(define (copy-from-scratch [home : arena.Arena] [scratch : arena.Arena]) : i64
  (begin
    (unsafe
      (arena.set! scratch))
    (let
      [items : (Array String) (array.make-array String 2)]
      (begin
        (array-set! items 0 (string.append "d" "0"))
        (array-set! items 1 (string.append "d" "1"))
        (let
          [bundle : Bundle (make-bundle items)]
          [sequence : (Array String) (make-sequence)]
          (begin
            (unsafe
              (arena.set! home))
            (let
              [bundle-copy : Bundle (clone bundle)]
              [sequence-copy : (Array String) (clone sequence)]
              (begin
                (unsafe
                  (arena.destroy scratch))
                (+ (bundle-score bundle-copy) (sequence-score sequence-copy))))))))))

(define (main) : i64
  (let
    [home : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    (if (= (copy-from-scratch home scratch) 12)
      42
      1)))