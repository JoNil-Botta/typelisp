(defstruct Bundle
  (name String)
  (pair (Tuple String String))
  (fixed (Array String 2))
  (items (Array String)))

(defenum StringList
  (SNil)
  (SCons String StringList))

(define (score-bool [ok : bool]) : i64
  (if ok
    1
    0))

(define (list-score [items : StringList]) : i64
  (match items
    [SNil 0]
    [(SCons head tail) (+ (string-length head) (list-score tail))]))

(define (bundle-score [bundle : Bundle]) : i64
  (+
    (score-bool (string-eq (struct-get bundle name) "name"))
    (+
      (score-bool (string-eq (tuple-ref (struct-get bundle pair) 0) "t0"))
      (+
        (score-bool (string-eq (tuple-ref (struct-get bundle pair) 1) "t1"))
        (+
          (score-bool (string-eq (array-ref (struct-get bundle fixed) 0) "f0"))
          (+
            (score-bool
              (string-eq (array-ref (struct-get bundle fixed) 1) "f1"))
            (+
              (score-bool
                (string-eq (array-ref (struct-get bundle items) 0) "d0"))
              (score-bool
                (string-eq (array-ref (struct-get bundle items) 1) "d1")))))))))

(define (make-bundle [items : (Array String)]) : Bundle
  (Bundle
    (string-append "na" "me")
    (tuple (string-append "t" "0") (string-append "t" "1"))
    (array (string-append "f" "0") (string-append "f" "1"))
    items))

(define (make-list) : StringList
  (SCons (string-append "a" "a") (SCons (string-append "b" "bb") SNil)))

(define (copy-from-scratch [home : i64] [scratch : i64]) : i64
  (begin
    (unsafe
      (arena-set! scratch))
    (let
      [items : (Array String) (make-array String 2)]
      (begin
        (array-set! items 0 (string-append "d" "0"))
        (array-set! items 1 (string-append "d" "1"))
        (let
          [bundle : Bundle (make-bundle items)]
          [list : StringList (make-list)]
          (begin
            (unsafe
              (arena-set! home))
            (let
              [bundle-copy : Bundle (clone bundle)]
              [list-copy : StringList (clone list)]
              (begin
                (unsafe
                  (arena-destroy scratch))
                (+ (bundle-score bundle-copy) (list-score list-copy))))))))))

(define (main) : i64
  (let
    [home : i64 (arena-current)]
    [scratch : i64 (arena-make)]
    (if (= (copy-from-scratch home scratch) 12)
      42
      1)))