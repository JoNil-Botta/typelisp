;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that arena data typed with the arena
;; (`in`, a nominal and a reference) stays usable inside it; runs to 42.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (sum [p : (& r i64)]) : i64
  (with-arena
    ar
    (let
      [x : (in ar (Box i64)) (box 30)]
      [local : (RefBox ar) (RefBox (& ar (deref x)))]
      [read
        (lambda ([v : (& ar i64)]) : i64
          (deref v))]
      (+ (read local.value) (deref p)))))

(define (main) : i64
  (let
    [seed : i64 12]
    (sum (& seed))))