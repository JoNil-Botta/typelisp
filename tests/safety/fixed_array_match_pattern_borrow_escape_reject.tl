(import stdlib.string)

(define (bad [seed : (& outer i64)]) : (& outer str)
  (let
    [items : (Array String 2) (array "local" (string.int->string (deref seed)))]
    (match (& items)
      [(array first _) first])))

(define (main) : i64
  (let
    [seed : i64 1]
    (string.string-length (bad (& seed)))))