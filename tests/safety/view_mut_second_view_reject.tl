;; Another view of a mutable view's path cannot be used while the mutable
;; view is still written (Rust E0502).
(import stdlib.string)

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

(define (len-in [q : (& q In)]) : i64
  (string.string-length (& (deref q.b))))

(define (f [p : (&mut p Out)]) : i64
  (let
    [v p.s]
    [w p.s]
    [n (len-in (& w))]
    (set! (deref v.b) "zz")
    (+ n (len-in (& w)))))

(define (main) : i64
  42)