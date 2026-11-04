;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that a resource named `r` inside an arena
;; is an ordinary binder; runs to 42.
(defstruct Pt
  (x i64))

(define (drop-pt [p : Pt]) : unit
  unit)

(define (probe [p : (& r i64)]) : i64
  (with-arena
    ar
    (with
      ([r (Pt 40) drop-pt])
      (let
        [y : (& r i64) (& r r.x)]
        (+ (deref y) 2)))))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s))))