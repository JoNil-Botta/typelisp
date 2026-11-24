;; #9944: Unshadowed `program-argv` still requires an enclosing `unsafe` context.
(define (main) : i64
  (let
    [_p : (Ptr (Ptr u8)) (program-argv)]
    0))