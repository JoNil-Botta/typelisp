;; #8998 cache-gap control (ok): a local `a : (& a i64)` borrowing an older
;; local `a` is a self-named carrier; lifetime `a` is that older binding, found
;; past the carrier, also in a local environment longer than its cache
;; threshold (0 bindings between them, 0 after).
(define (f [q : (& q i64)]) : i64
  (let
    [a : i64 1]
    [a : (& a i64) (& a)]
    (let
      [r : (& a i64) a]
      (deref r))))

(define (main) : i64
  0)