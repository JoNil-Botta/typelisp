(import stdlib.string)

(define (tail-classify [text : String]) : i64
  (match text
    ["abcdef" 2]
    [(or "42" "59") 10]
    [_ 1]))

(define (value-classify [text : String]) : i64
  (+
    1
    (match text
      [(or "abcdef" "123456") 3]
      ["42" 7]
      [_ 0])))

(define (main) : i64
  (let
    [a (tail-classify (string.append "abc" "def"))]
    [b (tail-classify (string.int->string 42))]
    [c (tail-classify (string.int->string 59))]
    [d (tail-classify (string.append "abc" "dex"))]
    [e (value-classify (string.copy "abcdef"))]
    [f (value-classify (string.int->string 123456))]
    [g (value-classify (string.int->string 42))]
    [h (value-classify (string.copy "abcde"))]
    [i (tail-classify (string.copy ""))]
    (+ a (+ b (+ c (+ d (+ e (+ f (+ g (+ h (+ i 1)))))))))))