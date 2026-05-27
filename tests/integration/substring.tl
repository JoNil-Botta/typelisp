; Exercise substring/string-slice end to end across empty, boundary, short, and
; long slices. main returns 55 when every check passes.
(define (score [ok : bool] [points : i64]) : i64
  (if ok
    points
    0))

(define (main) : i64
  (let
    [mid : String (substring "abcdef" 2 3)]
    [empty : String (string-slice "abc" 1 0)]
    [full : String (substring "abcdef" 0 6)]
    [first : String (substring "abcdef" 0 1)]
    [last : String (substring "abcdef" 5 1)]
    [end-empty : String (string-slice "abcdef" 6 0)]
    [long : String
      (substring
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        10
        40)]
    [long-expected : String "klmnopqrstuvwxyz0123456789ABCDEFGHIJKLMN"]
    (+
      (+
        (+ (score (string-eq mid "cde") 1) (score (= (string-length mid) 3) 2))
        (+ (score (string-eq empty "") 3) (score (= (string-length empty) 0) 4)))
      (+
        (+ (score (string-eq full "abcdef") 5) (score (string-eq first "a") 6))
        (+
          (+ (score (string-eq last "f") 7) (score (string-eq end-empty "") 8))
          (+
            (score (= (string-length long) 40) 9)
            (score (string-eq long long-expected) 10)))))))