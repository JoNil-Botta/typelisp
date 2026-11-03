;; A shadowing local's own initializer is still in the arena's scope, so its
;; annotations name the arena; later uses name the local (#9593).
(define (probe [p : (& r i64)]) : i64
  (with-arena
    r
    (let
      [r : i64
        (let
          [t : (in r (Box i64)) (box 40)]
          (deref t))]
      [y : (& r i64) (& r r)]
      (+ (deref y) 2))))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s))))