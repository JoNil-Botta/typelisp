;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that let and lambda-parameter self-named
;; carriers of arena data check and run; runs to 42.
(define (probe [p : (& r i64)]) : i64
  (with-arena
    ar
    (let
      [x : (Box i64) (box 25)]
      [saved : (& ar i64) (& ar (deref x))]
      [r : (& ar i64) (& ar (deref x))]
      [alias : (& ar i64) r]
      [read
        (lambda ([r : (& ar i64)]) : i64
          (deref r))]
      (set! saved alias)
      (+ (read saved) (+ (deref alias) (- (deref p) 20))))))

(define (main) : i64
  (let
    [seed : i64 12]
    (probe (& seed))))