(import stdlib.string)

(define (length-of [text : (& t str)]) : i64
  (string.string-length text))

(define (main) : i64
  (let
    [x : String (string.append "four" "")]
    [z : String (string.append "sixteen" "chars!!!")]
    [first : i64
      (length-of
        (if true
          (& x)
          (& z)))]
    (+ 19 (+ first (+ (string.string-length x) (string.string-length z))))))