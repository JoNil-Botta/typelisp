;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that a local named `r` inside an arena is
;; an ordinary binder whose explicit borrow names it; runs to 42.
(define (probe [p : (& r i64)]) : i64
  (with-arena
    ar
    (let
      [r : i64 42]
      (deref (& r r)))))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s))))