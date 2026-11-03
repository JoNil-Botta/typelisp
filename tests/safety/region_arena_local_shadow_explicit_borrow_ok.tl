;; A local spelled like a colliding with-arena region shadows the arena for
;; its own scope: its explicit borrow lifetime names the local (#9593).
(define (probe [p : (& r i64)]) : i64
  (with-arena
    r
    (let
      [r : i64 42]
      (deref (& r r)))))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s))))