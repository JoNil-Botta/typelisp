;; A helper that builds and returns strings allocates them in its caller's
;; arena, which the call's result carries (#8681 twin).
(import stdlib.string)

(define (greeting [n : i64]) : String
  (string.append "hello:" (string.int->string n)))

(define (main) : i64
  (with-arena
    phase
    (let
      [text : String (greeting 4242424)]
      (+ (string.string-length (& text)) 29))))