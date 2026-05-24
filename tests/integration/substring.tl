; Exercise substring/string-slice end to end:

; - "abcdef"[2..2+3] == "cde" and length 3

; - an empty slice has length 0 and compares equal to ""

; main returns 3 + 0 + 10 + 20 = 33.

(define (main) : i64
  (let
    [mid : String (substring "abcdef" 2 3)]
    [empty : String (string-slice "abc" 1 0)]
    (+
      (+ (string-length mid) (string-length empty))
      (+
        (if (string-eq mid "cde")
          10
          0)
        (if (string-eq empty "")
          20
          0)))))