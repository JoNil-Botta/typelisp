(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (drop-word [n : i64]) : unit
  (set! g (Big n n n n)))

(defenum Handle
  (:cleanup close-handle)
  (Open i64 (:cleanup drop-word))
  (Empty))

(define (read-after [r : (& r Big)]) : i64
  (begin
    (with ([h (Handle.Open 9) close-handle]) unit)
    r.a))

(define (main) : i64
  (read-after (& g)))