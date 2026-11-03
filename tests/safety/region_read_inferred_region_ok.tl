;; A call's region formal that an earlier argument instantiates is the region a
;; later argument is read under: a Copy value read through the caller's
;; reference is expected under the caller's region (#8998).
(define (keep-number [p : (& p (Array i64 2))] [n : (in p i64)]) : i64
  (if (= n 20)
    20
    0))

(define (measure [numbers : (& numbers (Array i64 2))]) : i64
  (keep-number numbers (array-ref numbers 0)))

(define (main) : i64
  (let
    [numbers : (Array i64 2) (array 20 22)]
    (if (= (measure (& numbers)) 20)
      42
      1)))