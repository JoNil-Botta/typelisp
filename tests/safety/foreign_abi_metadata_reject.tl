;: SPEC safe-code contract: foreign ABI metadata must use the checked source
;: forms; malformed metadata is statically rejected.
(extern bad (: link "bad_tuple") : (-> i64 i64))

(define (main) : i64
  0)