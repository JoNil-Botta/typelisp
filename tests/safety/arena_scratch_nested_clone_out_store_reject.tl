;: An inner with-scratch clone-out is tagged with the outer scratch region, so
;: storing it into a local declared outside the outer with-scratch is an escape
;: from the region that reclaims it.
(import stdlib.string)

(define (bad) : i64
  (let
    [b : (Box String) (box (string.append "x" "y"))]
    (with-scratch
      (begin
        (set! b (with-scratch (box (string.append "a" "b"))))
        (string.string-length (& (deref b)))))))

(define (main) : i64
  (let
    [n (bad)]
    (+ n (string.string-length "ab"))))