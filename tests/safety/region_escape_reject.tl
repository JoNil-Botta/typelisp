;: SPEC safe-code contract: region-tagged aggregate handles cannot escape the
;: arena that owns them.
(import "stdlib/string.tl")

(define (main) : String
  (with-arena phase (int->string 41)))