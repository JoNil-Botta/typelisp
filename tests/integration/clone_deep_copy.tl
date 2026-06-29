(import stdlib.array)
(import stdlib.arena)
(import "stdlib/string.tl")

(defstruct Bundle
  (name String)
  (pair (Tuple String String))
  (fixed (Array String 2))
  (items (Array String)))

(defenum StringList
  (Nil)
  (Cons String (Box StringList)))

(define (score-bool [ok : bool]) : i64
  (if ok
    1
    0))

(define (list-score [items : StringList]) : i64
  (match items
    [StringList.Nil 0]
    [(StringList.Cons head tail)
      (+ (string-length head) (list-score (box-get tail)))]))

(define (bundle-score [bundle : Bundle]) : i64
  (+
    (score-bool (eq (struct-get bundle name) "name"))
    (+
      (score-bool (eq (tuple-ref (struct-get bundle pair) 0) "t0"))
      (+
        (score-bool (eq (tuple-ref (struct-get bundle pair) 1) "t1"))
        (+
          (score-bool (eq (array-ref (struct-get bundle fixed) 0) "f0"))
          (+
            (score-bool (eq (array-ref (struct-get bundle fixed) 1) "f1"))
            (+
              (score-bool (eq (array-ref (struct-get bundle items) 0) "d0"))
              (score-bool (eq (array-ref (struct-get bundle items) 1) "d1")))))))))

(define (make-bundle [items : (Array String)]) : Bundle
  (Bundle
    (append "na" "me")
    (tuple (append "t" "0") (append "t" "1"))
    (array (append "f" "0") (append "f" "1"))
    items))

(define (make-list) : StringList
  (StringList.Cons
    (append "a" "a")
    (box (StringList.Cons (append "b" "bb") (box StringList.Nil)))))

(define (copy-from-scratch [home : arena.Arena] [scratch : arena.Arena]) : i64
  (begin
    (unsafe
      (arena.set! scratch))
    (let
      [items : (Array String) (array.make-array String 2)]
      (begin
        (array-set! items 0 (append "d" "0"))
        (array-set! items 1 (append "d" "1"))
        (let
          [bundle : Bundle (make-bundle items)]
          [list : StringList (make-list)]
          (begin
            (unsafe
              (arena.set! home))
            (let
              [bundle-copy : Bundle (clone bundle)]
              [list-copy : StringList (clone list)]
              (begin
                (unsafe
                  (arena.destroy scratch))
                (+ (bundle-score bundle-copy) (list-score list-copy))))))))))

(define (main) : i64
  (let
    [home : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    (if (= (copy-from-scratch home scratch) 12)
      42
      1)))