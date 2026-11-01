;: A slice element is always initialized: storing a cleanup-owning value over
;: it through the slice reference would lose the old element's cleanup. Main
;: rejects it; the graph had accepted it (#8449).
(define (drop-word [n : i64]) : unit
  unit)

(defstruct Tok
  (:cleanup close-tok)
  (n i64 (:cleanup drop-word)))

(define (reset! [s : (&mut s (Slice Tok))]) : unit
  (set! (array-ref s 0) (Tok 9)))

(define (main) : i64
  0)