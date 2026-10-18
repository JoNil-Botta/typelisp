;: Copying a reference into another binding ends nothing: the copy carries the
;: original's loan, so writing the referent before the copy's use conflicts.
(define (main) : i64
  (let
    [a : i64 1]
    (let
      [first (& a)]
      [second first]
      (set! a 2)
      (deref second))))