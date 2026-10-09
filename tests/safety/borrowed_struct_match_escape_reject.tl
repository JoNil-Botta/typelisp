(defstruct Label
  (text String)
  (code i64))

(define (bad [_seed : (& outer i64)]) : (& outer str)
  (let
    [label : Label (Label "local" 0)]
    (match (& label)
      [(Label text _) text])))

(define (main) : i64
  (let
    [seed : i64 1]
    (__tl_string_length (bad (& seed)))))