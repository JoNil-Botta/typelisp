;: Matching a non-Copy global by value would consume its permanent place.
(defenum GlobalChoice
  (Text String)
  (None))

(define global-choice : GlobalChoice
  (GlobalChoice.Text "owned"))

(define (main) : i64
  (match global-choice
    [(GlobalChoice.Text _) 1]
    [(GlobalChoice.None) 0]))