;; An array literal does not drop an arena allocation's region tag by joining
;; it with a shorter-lived untagged element.
; Must fail: the boxed caller reference lives in the arena `r`.
(define (keep [p : (& a i64)]) : i64
  (let
    [z : i64 0]
    [o : (Box (& z i64)) (box (& z))]
    [kept (with-arena r (array (box p) o))]
    0))

(define (main) : i64
  0)