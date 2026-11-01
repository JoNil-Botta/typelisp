;: A reference to a cleanup-owning aggregate holding a reference is an
;: ordinary parameter (#8449).
(defstruct Handle
  (n i64))

(define (drop-word [n : i64]) : unit
  unit)

(defstruct Holder
  (:lifetimes a)
  (:cleanup close-holder)
  (inner (& a Handle))
  (k i64 (:cleanup drop-word)))

(define (peek [w : (& (Holder a))]) : i64
  w.inner.n)

(define (main) : i64
  (let
    [h : Handle (Handle 5)]
    (let
      [w (Holder (& h) 1)]
      (let
        [n : i64 (peek (& w))]
        (close-holder w)
        n))))