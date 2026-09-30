;; A generator helper splices a caller's value expression unchanged, so a raw
;; read inside it is checked in the caller's safe context. Before #7701 the
;; helper's own view wrapped this place in `unsafe` and authorized `ptr-read`.
(import stdlib.json)
(import stdlib.serialize)

(defenum Flag
  (On)
  (Off))

(define (main) : i64
  (let
    [flags : (Array Flag 1) (array On)]
    [index : (Ptr i64) (ptr-null : (Ptr i64))]
    [_encoded : json.Value
      (stdlib.serialize.encode-enum-dispatch
        json
        Flag
        __flag_alias
        (array-ref flags (ptr-read index)))]
    0))