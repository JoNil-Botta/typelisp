(defstruct Payload
  (text String))

(defenum Item
  (Named Payload))

(define (main) : i64
  (let
    [item : Item (Named (Payload "local"))]
    (match (& item)
      [(Named (Payload text))
        (set! item (Named (Payload "changed")))
        (__tl_string_length text)])))