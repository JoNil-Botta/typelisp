;; Shared reads, explicit borrowing/cloning and owned moves remain distinct.
(defstruct Holder
  (b (Box i64)))

(define (borrowed-read [b : (& b (Box i64))]) : i64
  (deref (deref b)))

(define (shared-read [r : (& r Holder)]) : i64
  (let
    [view r.b]
    (+ (deref view) (borrowed-read (& view)))))

(define (cloned-read [r : (& r Holder)]) : i64
  (let
    [copy : (Box i64) (clone r.b)]
    (set! (deref copy) 99)
    (+ (deref copy) (deref r.b))))

(define (mutable-write [r : (&mut r Holder)]) : unit
  (set! (deref r.b) 21))

(define (owned-move [h : Holder]) : i64
  (let
    [b : (Box i64) h.b]
    (set! (deref b) 42)
    (deref b)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 20))]
    (when (!= (shared-read (& h)) 40) (return 1))
    (when (!= (cloned-read (& h)) 119) (return 2))
    (when (!= (deref h.b) 20) (return 3))
    (mutable-write (&mut h))
    (when (!= (shared-read (& h)) 42) (return 4))
    (owned-move h)))