;: Overwriting an initialized array of cleanup-owning values would lose the old
;: elements' cleanups (SPEC 4.7.1): the old value must be moved or cleaned up
;: first. Main accepted it and never ran the first element's cleanup.
(define (drop-word [n : i64]) : unit
  unit)

(defstruct Tok
  (:cleanup close-tok)
  (n i64 (:cleanup drop-word)))

(define (main) : i64
  (let
    [arr (array (Tok 1))]
    (set! arr (array (Tok 2)))
    0))