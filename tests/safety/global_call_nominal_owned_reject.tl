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
  (:cleanup close-handle)
  (n i64 (:cleanup drop-word)))

(defstruct Holder
  (:cleanup close-holder)
  (h Handle (:owned)))

(define (read-after [r : (& r Big)]) : i64
  (begin
    (with ([h (Holder (Handle 9)) close-holder]) unit)
    r.a))

(define (main) : i64
  (read-after (& g)))