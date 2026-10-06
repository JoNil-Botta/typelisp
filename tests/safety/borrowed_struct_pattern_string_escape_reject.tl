(defstruct Label
  (text String)
  (code i64))

(define (bad [_seed : (& outer i64)]) : (& outer str)
  (let
    [items : (Tuple Label i64) (tuple (Label "local" 0) 0)]
    (match (& items)
      [(tuple (Label text _) _) text])))

(define (main) : i64
  (let
    [seed : i64 1]
    (__tl_string_length (bad (& seed)))))