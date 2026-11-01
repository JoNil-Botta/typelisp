;; A view read through a view of a shared reference is shared: writing
;; through it writes through `&` (Rust E0594).
(defstruct In
  (b (Box String))
  (n i64))

(defstruct Mid
  (i In)
  (k i64))

(defstruct Out
  (s In)
  (m Mid)
  (t i64))

(define (make-out) : Out
  (Out (In (box "a") 1) (Mid (In (box "c") 3) 4) 5))

(define (f [p : (& p Out)]) : unit
  (let
    [v p.m]
    [u v.i]
    (set! (deref u.b) "zz")))

(define (main) : i64
  42)