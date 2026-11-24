;; The twin of `clone_read_receiver_retained.tl` where nothing after the
;; receiver writes what it selects: the receiver is lent for the read, not
;; moved or copied, so both arrays stay usable after the call, and the copy is
;; independent of the element it was cloned from.
(import stdlib.clone)

(defstruct Cell
  (items (__tl_dyn-array i64)))

(clone.gen-clone Cell)

(define (take-first [cells : (Array Cell 1)]) : i64
  (array-ref (array-ref cells 0).items 0))

(define (copy-lent [a : (Array Cell 1)] [b : (Array Cell 1)] [flag : bool]) : i64
  (let
    [chosen
      (if flag
        (& a)
        (& b))]
    [copy : Cell (clone-cell (& (array-ref (deref chosen) 0)))]
    (set! (array-ref copy.items 0) 30)
    (+ (array-ref copy.items 0) (take-first a) (take-first b))))

(define (main) : i64
  (copy-lent
    (array (Cell (__tl_make-array 4)))
    (array (Cell (__tl_make-array 8)))
    true))