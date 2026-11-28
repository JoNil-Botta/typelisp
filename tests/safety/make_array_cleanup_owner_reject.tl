(define (close [fd : i64]) : unit
  unit)

(defstruct Handle
  (:cleanup close-handle)
  (fd i64 (:cleanup close)))

(define (main) : i64
  (let
    [items (__tl_make-array Handle 0)]
    (length items)))