;; A value read through a reference where its region-tagged type `(in p T)` is
;; expected is that value read under `p`. A Copy one is copied wherever it is
;; expected (a result, an argument), and a move-only one that is only lent is
;; read where it lies: through an annotation or a branch to a shared-reference
;; formal, or by `clone`. Nothing moves out of the referenced arrays.
(import stdlib.string)

(define (observe [text : (& str)]) : i64
  (string.string-length text))

(define (second [p : (& p (Array i64 2))]) : (in p i64)
  (array-ref p 1))

(define (keep [p : (& p (Array String 2))] [_s : (in p String)]) : i64
  3)

(define (keep-number [p : (& p (Array i64 2))] [n : (in p i64)]) : i64
  (if (= n 20)
    20
    0))

;; 5 + 5 + 7 + 3 + 20.
(define (measure
  [p : (& p (Array String 2))]
  [numbers : (& numbers (Array i64 2))]
  [flag : bool]) : i64
  (let
    [copy : String (clone (ann (array-ref p 1) : (in p String)))]
    (+
      (observe (ann (array-ref p 0) : (in p String)))
      (observe
        (if flag
          (array-ref p 0)
          (array-ref p 1)))
      (string.string-length (& copy))
      (keep p (clone (array-ref p 0)))
      (keep-number numbers (array-ref numbers 0)))))

(define (main) : i64
  (let
    [words : (Array String 2) (array "hello" "world!!")]
    [numbers : (Array i64 2) (array 20 22)]
    [total : i64 (measure (& words) (& numbers) true)]
    (if (and (= total 40) (= (second (& numbers)) 22))
      42
      1)))