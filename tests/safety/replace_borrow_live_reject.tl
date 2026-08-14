;: Activation cannot overwrite a place protected by a live shared borrow.
(define (main) : i64
  (let
    [value : i64 1]
    [borrowed : (& value i64) (& value)]
    [_old : i64 (replace! value 2)]
    (deref borrowed)))