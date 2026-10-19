;; A view read through a shared reference stays shared: a field store
;; through it writes through `&` (Rust E0594). Main accepts it and writes
;; the caller's struct.
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
    [v p.s]
    (set! v.n (+ v.n 6))))

(define (main) : i64
  42)