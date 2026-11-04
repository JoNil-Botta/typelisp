;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that arena annotations inside an SPMD
;; `foreach` arena check and lower; runs to 42.
(define (sum [p : (& r i64)]) : i64
  (foreach
    ([i : i64 0 1])
    (with-arena
      ar
      (let
        [n : i64 30]
        [x : (in ar (Box i64)) (box n)]
        [y : (& ar i64) (& ar (deref x))]
        unit)))
  (deref p))

(define (main) : i64
  (let
    [seed : i64 42]
    (sum (& seed))))