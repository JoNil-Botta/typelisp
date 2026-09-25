;: Replacing a global element must not manufacture ownership of a non-Copy value.
(define global-items : (Array String 1)
  (array "owned"))

(define (main) : i64
  (let
    [_old : String (replace! (array-ref global-items 0) "new")]
    42))