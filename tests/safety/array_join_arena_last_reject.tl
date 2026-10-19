(define (bad) : (Array (Box i64) 2)
  (let
    [plain (box (ann 42 : i64))]
    (with-arena
      phase
      (let
        [items (array plain (box (ann 7 : i64)))]
        items))))

(define (main) : i64
  0)