;; A borrowed enum payload that is an inline struct must bind to the payload's
;; address. Loading the struct value and retyping its bits as a reference turns
;; a small integer field into an invalid pointer.
(defstruct SmallId
  (value u32))

(defenum Tokenish
  (Symbol SmallId)
  (End))

(define (score [token : (& token Tokenish)]) : i64
  (match token
    [(Tokenish.Symbol id) (+ 40 (cast id.value : i64))]
    [(Tokenish.End) 0]))

(define (main) : i64
  (let
    [token : Tokenish (Tokenish.Symbol (SmallId (cast 2 : u32)))]
    (score (& token))))