(import stdlib.string)

(define (main) : i64
  (let
    [items : (Array String 2) (array "a" "bc")]
    (match (& items)
      [(array first _)
        (begin
          (set! (array-ref items 0) "x")
          (string.string-length first))])))