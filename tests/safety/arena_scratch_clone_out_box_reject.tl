;: A with-scratch clone-out is a fresh allocation in the arena active around
;: the form. Inside `with-arena r` that is r, so the cloned Box carries r and
;: cannot leave the form that reclaims it (red-team find f01).
(import stdlib.string)

(define (bad) : (Box String)
  (with-arena r (with-scratch (box (string.append "a" "b")))))

(define (main) : i64
  (let
    [b (bad)]
    (string.string-length (& (deref b)))))