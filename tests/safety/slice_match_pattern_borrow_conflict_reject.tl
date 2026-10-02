(define (main) : i64
  (let
    [items : (Array i64 3) (array 1 2 3)]
    (match (slice-view items 0 3)
      [(slice _ & rest)
        (begin
          (set! (array-ref items 1) 9)
          (array-length rest))]
      [(slice) 0])))