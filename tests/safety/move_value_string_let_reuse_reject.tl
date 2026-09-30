(import stdlib.string)

(define (pick [name : String]) : i64
  (let
    [kept : String
      (let
        [length : i64 (string.string-length name)]
        name)]
    (+ (string.string-length kept) (string.string-length name))))

(define (main) : i64
  42)