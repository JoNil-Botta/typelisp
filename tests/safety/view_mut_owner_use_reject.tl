;; A mutable view holds an exclusive loan of its path while it is used: the
;; owner cannot be read between taking the view and writing through it
;; (Rust E0502).
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

(define (look [p : (& p Out)]) : i64
  p.t)

(define (f [p : (&mut p Out)]) : i64
  (let
    [v p.s]
    [t (look p)]
    (set! (deref v.b) "zz")
    t))

(define (main) : i64
  42)