;; A literal branch adopts the other branch's type only when the literal fits
;; it (#8590): 300 does not fit `u8`, so this join still fails.
(define (main) : i64
  (let
    [b : u8 (cast 1 : u8)]
    [v
      (if false
        300
        b)]
    0))