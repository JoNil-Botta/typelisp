;; Views of boxed contents read through a reference stay usable where they
;; do not move or write through a shared reference: reads, nested views and
;; borrows of the contents, and writes and `replace!` through a mutable view
;; (#8927).
(import stdlib.string)

(defstruct Holder
  (b (Box (Box i64)))
  (s (Box String)))

(define (text-length [s : (& s str)]) : i64
  (string.string-length s))

(define (peek [b : (& b (Box i64))]) : i64
  (deref (deref b)))

(define (read [r : (& r Holder)]) : i64
  (let
    [b r.b]
    [s r.s]
    [inner (deref b)]
    (+
      (+ (deref (deref b)) (deref inner))
      (+ (text-length (& (deref s))) (peek (& (deref b)))))))

(define (write [r : (&mut r Holder)]) : unit
  (let
    [b r.b]
    (set! (deref (deref b)) 10)
    (let
      [old : (Box i64) (replace! (deref b) (box 11))]
      (set! (deref b) old))))

(define (main) : i64
  (let
    [h : Holder (Holder (box (box 5)) (box (string.copy "abcd")))]
    (write (&mut h))
    ;; read: 10 + 10 + 4 + 10 = 34; then 34 + 10 - 2 = 42
    (+ (read (& h)) (- (deref (deref h.b)) 2))))