;; An array literal does not drop an arena allocation's region tag by giving a
;; later element the type of a shorter-lived untagged element before it.
; Must fail: the boxed caller reference lives in the arena `r`.
(define (keep [p : (& a i64)]) : i64
  (let
    [z : i64 0]
    [o : (Box (& z i64)) (box (& z))]
    [kept
      (with-arena
        r
        (let
          [b (box p)]
          (array o b)))]
    0))

(define (main) : i64
  0)