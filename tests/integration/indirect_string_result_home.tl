(import stdlib.io)
(import stdlib.string)

;; The indirect call returns a whole String. Its length word must survive
;; alongside the input String's length and the hidden Answer pointer.
(defstruct Answer
  (tag i64)
  (out String))

(define (echo [input : String]) : String
  input)

(define (suffix [input : String]) : String
  (string.concat input "bar"))

(define (finish [tag : i64] [out : String] [input : String]) : Answer
  (Answer (+ tag (string-length input)) out))

(define (dispatch [tag : i64] [input : String] [f : (-> String String)]) : Answer
  (finish tag (f "foo") input))

(define (main) : i64
  (let
    [n (io.arg-count)]
    [f : (-> String String)
      (if (= n 1)
        suffix
        echo)]
    [result (dispatch 19 "foo" f)]
    (if (and (= result.tag 22) (string.eq (& result.out) "foobar"))
      42
      1)))