;: Resetting a global slot must not manufacture ownership of a non-Copy value.
(define global-items : (Array String 1)
  (array "owned"))

(define (main) : i64
  (let
    [_old : String (array-take! global-items 0)]
    42))