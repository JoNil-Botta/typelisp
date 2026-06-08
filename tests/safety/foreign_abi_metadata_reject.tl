;: SPEC safe-code contract: foreign ABI metadata must use the checked source
;: forms; malformed metadata is statically rejected.
(extern (bad [arg0 : i64]) : i64 (:abi stdcall))

(define (main) : i64
  0)