(import "stdlib/text_buf.tl")

(import "stdlib/test.tl")

(define (assert-text-buf [buf : TextBuf] [expected : String] [message : String]) : unit
  (begin
    (assert-string-eq (text-buf-render buf) expected message)
    (assert-i64-eq (text-buf-length buf) (string-length expected) message)))

(define (main) : i64
  (begin
    (assert-true (text-buf-empty? (text-buf-empty)) "empty buffer predicate")
    (assert-text-buf (text-buf-empty) "" "empty buffer renders empty")
    (assert-text-buf
      (text-buf-append
        (text-buf-append (text-buf-append (text-buf-empty) "alpha") " ")
        "beta")
      "alpha beta"
      "append order")
    (let
      [buf : TextBuf (text-buf-empty)]
      [i : i64 0]
      (begin
        (while (< i 6)
          (begin
            (set! buf (text-buf-append buf "ha"))
            (set! i (+ i 1))))
        (assert-text-buf buf "hahahahahaha" "repeated append")))
    (assert-text-buf
      (text-buf-append-int
        (text-buf-append-char
          (text-buf-append-char
            (text-buf-append (text-buf-empty) "A")
            #\newline')
          #\tab')
        -12)
      "A\n\t-12"
      "char and int append")
    (let
      [left : TextBuf
        (text-buf-append (text-buf-append (text-buf-empty) "left") "-")]
      [right : TextBuf
        (text-buf-append (text-buf-append (text-buf-empty) "right") "\n")]
      (assert-text-buf
        (text-buf-append-buffer left right)
        "left-right\n"
        "append buffer"))
    (let
      [original : TextBuf (text-buf-append (text-buf-empty) "keep")]
      (begin
        (assert-text-buf (text-buf-clear original) "" "clear returns empty")
        (assert-text-buf (text-buf-reset original) "" "reset returns empty")
        (assert-text-buf original "keep" "clear leaves original value")))
    42))