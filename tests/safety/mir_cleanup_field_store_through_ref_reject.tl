;: A store through a `&mut` into a cleanup-owning field overwrites an initialized
;: owner and would lose its cleanup: rejected, as main rejects it (#8449).
(define (drop-word [n : i64]) : unit
  unit)

(defstruct Tok
  (:cleanup close-tok)
  (n i64 (:cleanup drop-word)))

(defstruct Pair
  (:cleanup close-pair)
  (t Tok (:owned))
  (m i64))

(define (reset! [p : (&mut p Pair)]) : unit
  (set! p.t (Tok 9)))

(define (main) : i64
  (let
    [q : Pair (Pair (Tok 1) 0)]
    (reset! (&mut q))
    (close-pair q)
    0))