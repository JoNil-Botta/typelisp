(import stdlib.string)

(define (main) : i64
  (let
    [items : (Array String 2) (array "a" "bb")]
    (match (slice-mut-view items 0 2)
      [(slice first & _)
        (begin
          (set! (array-ref items 1) "c")
          (string.string-length (deref first)))]
      [(slice) 0])))