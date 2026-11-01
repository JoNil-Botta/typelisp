;: A cleanup-owning aggregate may hold references (#8449), and reading a
;: reference through the referent of one a call returns disposes of nothing:
;: its cleanup assigns `g` only at the explicit discharge (#7904).
(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (drop-word [n : i64]) : unit
  (set! g (Big n n n n)))

(defstruct Handle
  (n i64))

(defstruct Holder
  (:lifetimes a)
  (:cleanup close-holder)
  (inner (& a Handle))
  (k i64 (:cleanup drop-word)))

(define (field-a [r : (& r Big)]) : (& r i64)
  (& r.a))

(define (read [r : (& r i64)] [n : i64]) : i64
  (+ n (deref r)))

(define (holder-of [w : (& w (Holder a))]) : (& w (Holder a))
  w)

(define (fd [h : (& Handle)]) : i64
  h.n)

(define (work [w : (& w (Holder a))]) : i64
  (read (field-a (& g)) (fd (deref (holder-of w)).inner)))

(define (main) : i64
  (let
    [h : Handle (Handle 5)]
    (let
      [w (Holder (& h) 1)]
      (let
        [r : i64 (work (& w))]
        (close-holder w)
        r))))