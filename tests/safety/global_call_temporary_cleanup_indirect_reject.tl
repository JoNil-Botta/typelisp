(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (main) : i64
  (read-after (& g)))

(define (read-after [r : (& r Big)]) : i64
  (let
    [f : (-> unit)
      (lambda () : unit
        (fd (& (Handle 9)))
        unit)]
    (f)
    r.a))

(define (drop-word [n : i64]) : unit
  (set! g (Big n n n n)))

(defstruct Handle
  (:cleanup close-handle)
  (n i64 (:cleanup drop-word)))

(define (fd [h : (& Handle)]) : i64
  h.n)