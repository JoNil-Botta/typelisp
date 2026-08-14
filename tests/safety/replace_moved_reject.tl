;: There is no old value to return after a move.
(define (main) : i64
  (let
    [text : String "old"]
    [_moved : String text]
    (begin
      (replace! text "new")
      42)))