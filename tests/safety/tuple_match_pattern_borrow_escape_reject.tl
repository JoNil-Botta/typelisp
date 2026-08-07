(import stdlib.string)

(define (bad [seed : (& outer i64)]) : (& outer str)
  (let
    [pair : (Tuple String i64) (tuple "local" (deref seed))]
    (match (& pair)
      [(tuple text _) text])))

(define (main) : i64
  (let
    [seed : i64 1]
    (string.string-length (bad (& seed)))))