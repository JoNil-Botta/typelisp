(defstruct Payload
  (text String))

(defenum Item
  (Named Payload))

(define (bad [_seed : (& outer i64)]) : (& outer str)
  (let
    [item : Item (Named (Payload "local"))]
    (match (& item)
      [(Named (Payload text)) text])))

(define (main) : i64
  (let
    [seed : i64 1]
    (__tl_string_length (bad (& seed)))))
