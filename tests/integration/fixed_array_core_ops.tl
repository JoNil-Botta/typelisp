;; Fixed-array construction, length, reads, and place writes are core forms and
;; require no module import. The counted receiver proves length evaluates its
;; argument exactly once even though lowering replaces the result with constant N.
(define (counted-array [calls : (&mut calls i64)]) : (Array i64 3)
  (begin
    (set! (deref calls) (+ (deref calls) 1))
    (make-array i64 3)))

(define (main) : i64
  (let
    [calls : i64 0]
    [counted-len : i64 (length (counted-array (&mut calls)))]
    [items : (Array i64 3) (make-array i64 (+ 1 2))]
    [empty : (Array i64 0) (make-array i64 0)]
    [texts : (Array String 2) (make-array String 2)]
    [zii : (Array unit 4) (make-array unit 4)]
    (begin
      (set! (array-ref items 0) 40)
      (set! (array-ref items 2) 2)
      (if (and
        (= calls 1)
        (= counted-len 3)
        (= (length items) 3)
        (= (length (& items)) 3)
        (= (array-length (&mut items)) 3)
        (= (array-length empty) 0)
        (= (length texts) 2)
        (= (length zii) 4)
        (= (+ (array-ref items 0) (array-ref items 2)) 42))
        42
        1))))