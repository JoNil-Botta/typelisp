(import stdlib.string)

(extern (c-echo [text : String]) : String (:symbol "tl_certified_string_echo"))
(extern (get-pointer) : (CFunc non-null (-> String String)) (:symbol "tl_certified_string_pointer"))

(define (identity [text : String]) : String
  text)

(define (other [_text : String]) : String
  "changed")

(define (choose [flag : bool] [left : String] [right : String]) : String
  (if flag
    left
    right))

(define (first [text : String] [_later : unit]) : String
  text)

(define (snapshot) : String
  (let
    [text "answer"]
    (first
      text
      (begin
        (set! text "changed")
        unit))))

(define (looping) : String
  (let
    [text "answer"]
    [index : i64 0]
    (while (< index 6)
      (set! text (identity text))
      (set! index (+ index 1)))
    text))

(define (factory) : (-> String String)
  identity)

(define (foreign-factory) : (-> String String)
  c-echo)

(define (indirect) : String
  (let
    [apply identity]
    (apply
      (begin
        (set! apply other)
        "answer"))))

(define (c-pointer
  [apply : (CFunc non-null (-> String String))]
  [text : String]) : String
  (apply text))

(define (is-answer [text : String]) : bool
  (string.eq text "answer"))

(define (main) : i64
  (if (and
    (is-answer (identity "answer"))
    (is-answer (choose true "answer" "other"))
    (is-answer (choose false "other" "answer"))
    (is-answer (snapshot))
    (is-answer (looping))
    (is-answer (indirect))
    (is-answer ((factory) "answer"))
    (is-answer ((foreign-factory) "answer"))
    (is-answer (c-echo "answer"))
    (is-answer (c-pointer (get-pointer) "answer")))
    42
    1))