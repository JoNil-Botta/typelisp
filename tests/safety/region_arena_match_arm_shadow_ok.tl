;; A match binder spelled like a colliding arena shadows it only in its own
;; arm; a sibling arm still names the arena (#9593).
(defenum Pick
  (Take i64)
  (Skip))

(define (probe [p : (& r i64)] [v : Pick]) : i64
  (with-arena
    r
    (match v
      [(Take r) (+ (deref (& r r)) 2)]
      [(Skip)
        (let
          [x : (in r (Box i64)) (box 2)]
          (deref (& r (deref x))))])))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s) (Pick.Take 40))))