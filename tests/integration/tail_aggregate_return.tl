; Tail calls returning non-register aggregate values forward the caller-owned
; sret slot through the tail jump instead of allocating a fresh result slot.
(defstruct Big
  (a i64)
  (b i64)
  (c i64))

(define (make-big [x : i64]) : Big
  (Big x (+ x 1) (+ x 2)))

(define (count-big [n : i64] [acc : i64]) : Big
  (if (= n 0)
    (make-big acc)
    (count-big (- n 1) (+ acc 1))))

(define (main) : i64
  (let
    [value : Big (count-big 100000 39)]
    (if (= (struct-get value a) 100039)
      (if (= (struct-get value c) 100041)
        42
        2)
      1)))