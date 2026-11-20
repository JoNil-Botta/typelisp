;: A defmacro that expands to a with-scratch clone-out gets the same treatment:
;: inside `with-arena r` the cloned Box carries r and cannot escape (red-team
;: find f06).
(import stdlib.string)

(defmacro (build) : Expr
  `(with-scratch (box (string.append "a" "b"))))

(define (bad) : (Box String)
  (with-arena r (build)))

(define (main) : i64
  (let
    [b (bad)]
    (string.string-length (& (deref b)))))