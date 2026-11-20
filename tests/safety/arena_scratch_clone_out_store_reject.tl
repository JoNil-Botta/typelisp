;: The r-tagged clone-out result cannot be stored into a local declared outside
;: the `with-arena r` that reclaims it (red-team find f05).
(import stdlib.string)

(define (bad) : (Box String)
  (let
    [b : (Box String) (box (string.append "x" "y"))]
    (with-arena
      r
      (begin
        (set! b (with-scratch (box (string.append "a" "b"))))
        b))))

(define (main) : i64
  (let
    [b (bad)]
    (string.string-length (& (deref b)))))