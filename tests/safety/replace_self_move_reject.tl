;: The two-phase reservation rejects moving the old owner as its replacement.
(define (main) : i64
  (let
    [text : String "old"]
    [_old : String (replace! text text)]
    42))