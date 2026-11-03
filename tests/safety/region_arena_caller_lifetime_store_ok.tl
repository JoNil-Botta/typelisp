;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that caller data stored into caller
;; storage inside an arena is not an escape (main rejected it while the arena
;; shared the caller's name).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [p : (& r i64)] [b : (&mut (RefBox r))]) : i64
  (with-arena
    ar
    (let
      [x : (Box i64) (box 5)]
      (set! b.value p)
      (+ (deref x) (deref b.value)))))

(define (main) : i64
  0)