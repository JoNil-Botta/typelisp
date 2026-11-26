(import same_name_struct)

(define (main) : i64
  (let
    [t : same_name_struct.Token (same_name_struct.make-token)]
    t.kind))