;: A whole cleanup-owning referent is initialized: storing over it through a
;: `&mut` would lose its cleanup, as main also rejects (#8449).
(define (drop-word [n : i64]) : unit
  unit)

(defstruct Tok
  (:cleanup close-tok)
  (n i64 (:cleanup drop-word)))

(define (reset! [r : (&mut r Tok)]) : unit
  (set! (deref r) (Tok 9)))

(define (main) : i64
  (let
    [t : Tok (Tok 1)]
    (reset! (&mut t))
    (close-tok t)
    0))