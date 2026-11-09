;; The name conversion is for scalars: an aggregate name at its region-tagged
;; type stays unrepresented (#9737).
(defstruct Pair
  (a i64)
  (b i64))

; Must fail: only a scalar name is read and converted.
(define (bad [p : (& p Pair)] [s : Pair]) : (in p Pair)
  s)

(define (main) : i64
  0)