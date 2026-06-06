;: SPEC safe-code contract: references tied to visible lifetimes and scoped
;: arena allocations that return region-free scalars are valid safe code.
(import "stdlib/string.tl")

(define (take-ref [r : (& n i64)]) : unit
  unit)

(define (main [n : i64]) : i64
  (let
    [r : (& n i64) (& n)]
    (begin
      (take-ref r)
      (with-arena
        phase
        (let
          [text : String (int->string n)]
          (string-length text))))))