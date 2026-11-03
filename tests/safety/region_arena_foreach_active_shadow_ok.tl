;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that a `foreach-active` lane named `r`
;; inside an arena is an ordinary binder; runs to 42.
(define (probe [p : (& r i64)]) : i64
  (let
    [acc : (Array i64 1) (array 0)]
    (with-arena
      ar
      (foreach
        ([i : i64 0 1])
        (foreach-active
          [r : i64]
          (let
            [x : (& r i64) (& r r)]
            [y : i64 (deref (& r))]
            (set! (array-ref acc 0) (+ 42 (- (deref x) y)))))))
    (array-ref acc 0)))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s))))