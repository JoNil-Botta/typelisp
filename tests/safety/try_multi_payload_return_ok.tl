(defenum Pair
  (Ok i64 i64)
  (Err i64))

(defenum Single
  (Ok i64)
  (Err i64))

(define (single [x : i64]) : Single
  (if (> x 0)
    (Single.Ok x)
    (Single.Err (- 0 x))))

;: The enclosing family is only built through its Err variant, so its Ok
;: variant may carry several payloads.
(define (both [x : i64] [y : i64]) : Pair
  (Pair.Ok (try (single x)) (try (single y))))

(define (score [p : Pair]) : i64
  (match p
    [(Pair.Ok a b) (+ a b)]
    [(Pair.Err e) e]))

(define (main) : i64
  (+ (score (both 30 4)) (score (both 3 -8))))