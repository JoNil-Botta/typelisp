;: A with-escape clone-out is a fresh allocation in the arena active around
;: the form, so inside `with-arena r` the cloned Box carries r and cannot leave
;: the region that reclaims it (red-team find f02).
(import stdlib.arena)
(import stdlib.string)

(define (bad [scratch : arena.Arena]) : (Box String)
  (with-arena r (with-escape scratch (box (string.append "a" "b")))))

(define (main) : i64
  (let
    [scratch (arena.make)]
    [b (bad scratch)]
    (string.string-length (& (deref b)))))