;; The twin of `clone_read_receiver_retained.tl` where nothing after the
;; receiver writes what it selects: the receiver is lent for the read, not
;; moved or copied, so both arrays stay usable after the clone, and the copy is
;; independent of the element it was cloned from.
(defstruct Cell
  (items (__tl_dyn-array i64)))

(define (take-first [cells : (Array Cell 1)]) : i64
  (array-ref (array-ref cells 0).items 0))

(define (copy-lent [a : (Array Cell 1)] [b : (Array Cell 1)] [flag : bool]) : i64
  (let
    [copy : Cell
      (clone
        (array-ref
          (if flag
            a
            b)
          0))]
    (set! (array-ref copy.items 0) 30)
    (+ (array-ref copy.items 0) (take-first a) (take-first b))))

(define (main) : i64
  (copy-lent
    (array (Cell (__tl_make-array 4)))
    (array (Cell (__tl_make-array 8)))
    true))