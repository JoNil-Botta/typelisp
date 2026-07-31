;; #5971: internal by-value memory aggregates use private callee storage.
;; Direct writes, writes through a moved alias, mutable borrows of the
;; parameter, match payload writes, and fixed-array element writes must not
;; mutate the caller's value.
(defstruct Big
  (f0 i64)
  (f1 i64)
  (f2 i64))

(defenum Wrapped
  (Wrap Big i64))

(define (direct-write [value : Big]) : i64
  (begin
    (set! (struct-get value f0) 99)
    (struct-get value f0)))

(define (alias-write [value : Big]) : i64
  (let
    [alias : Big value]
    (begin
      (set! (struct-get alias f0) 88)
      (struct-get alias f0))))

(define (write-first! [value : (&mut value Big)] [next : i64]) : unit
  (set! (struct-get value f0) next))

(define (borrow-write [value : Big]) : i64
  (begin
    (write-first! (&mut value) 77)
    (struct-get value f0)))

(define (match-write [value : Wrapped]) : i64
  (match value
    [(Wrap payload marker)
      (begin
        (set! (struct-get payload f0) 66)
        (+ (struct-get payload f0) marker))]))

(define (array-write [value : (Array i64 3)]) : i64
  (begin
    (array-set! value 0 55)
    (array-ref value 0)))

(define (ignore-big [result : i64] [_unused : Big]) : i64
  result)

(define (main) : i64
  (let
    [direct : Big (Big 1 11 21)]
    [direct-seen : i64 (direct-write direct)]
    [alias : Big (Big 2 12 22)]
    [alias-seen : i64 (alias-write alias)]
    [borrowed : Big (Big 3 13 23)]
    [borrow-seen : i64 (borrow-write borrowed)]
    [explicit : Big (Big 7 17 27)]
    [_ : unit (write-first! (&mut explicit) 44)]
    [wrapped : Wrapped (Wrap (Big 4 14 24) 5)]
    [match-seen : i64 (match-write wrapped)]
    [wrapped-first : i64
      (match wrapped
        [(Wrap payload _) (struct-get payload f0)])]
    [items : (Array i64 3) (array 5 15 25)]
    [array-seen : i64 (array-write items)]
    [unused-seen : i64 (ignore-big 33 (Big 8 18 28))]
    [offset : i64 10]
    [lambda-value : Big (Big 6 16 26)]
    [lambda-seen : i64
      ((lambda ([value : Big]) : i64
          (begin
            (set! (struct-get value f0) (+ 80 offset))
            (struct-get value f0)))
        lambda-value)]
    (if (and
      (= direct-seen 99)
      (= (struct-get direct f0) 1)
      (= alias-seen 88)
      (= (struct-get alias f0) 2)
      (= borrow-seen 77)
      (= (struct-get borrowed f0) 3)
      (= (struct-get explicit f0) 44)
      (= match-seen 71)
      (= wrapped-first 4)
      (= array-seen 55)
      (= (array-ref items 0) 5)
      (= unused-seen 33)
      (= lambda-seen 90)
      (= (struct-get lambda-value f0) 6))
      42
      1)))