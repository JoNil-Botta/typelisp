;: Runtime-indexed paths from one root conservatively overlap during replace!.
(define (main [left : i64] [right : i64]) : i64
  (let
    [items : (Array String 2) (array "left" "right")]
    [_old : String (replace! (array-ref items left) (array-ref items right))]
    42))