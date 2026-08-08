(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    (match (& items)
      [(array first _)
        (begin
          (array-set! items 0 41)
          (+ (deref first) 1))])))