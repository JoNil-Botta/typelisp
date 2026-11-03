;; An annotation spelled like a colliding with-arena region, inside a local
;; of that name, names the local (#9593).
(define (probe [p : (& r i64)]) : i64
  (with-arena
    r
    (let
      [r : i64 42]
      [x : (& r i64) (& r r)]
      (deref x))))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s))))