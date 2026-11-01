;; #9096: a field of the `&mut` stored in an array element read through a
;; shared reference to the array is not writable. Main 8d29b08a1 accepted the
;; place and reported only an incidental move error.
(defstruct Pt
  (s String)
  (x i64))

(defstruct Hold
  (:lifetimes a)
  (r (&mut a Pt)))

(define (sneak [hs : (& h (Array (Hold a) 1))]) : unit
  (set! (deref (array-ref (deref hs) 0).r).x 42))

(define (main) : i64
  (let
    [p : Pt (Pt "a" 7)]
    (let
      [arr (array (Hold (&mut p)))]
      (sneak (& arr)))
    p.x))