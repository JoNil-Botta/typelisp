(import stdlib.io)

(define (main) : i64
  (let
    [_handles (make-array (Tuple i64 io.FileHandle) 1)]
    42))