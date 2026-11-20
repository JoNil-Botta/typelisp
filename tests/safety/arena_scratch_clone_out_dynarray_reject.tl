;: A with-scratch clone-out of a dynamic buffer allocates its header in the
;: arena active around the form: inside `with-arena r` that header lives in the
;: reclaimed region, so the result cannot escape (red-team find f03).
(import stdlib.string)

(define (bad) : (__tl_dyn-array String)
  (with-arena
    r
    (with-scratch
      (__tl_make-array (string.append "a" "b") (string.append "c" "d")))))

(define (main) : i64
  (let
    [items (bad)]
    (if (string.eq (& (array-ref items 0)) "ab")
      42
      7)))