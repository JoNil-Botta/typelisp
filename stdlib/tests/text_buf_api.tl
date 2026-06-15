(import stdlib.text_buf)

(import stdlib.io)

(import stdlib.test)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (assert-text-buf [buf : text_buf.TextBuf] [expected : String] [message : String]) : unit
  (begin
    (assert-owned-string-eq (text_buf.text-buf-render buf) expected message)
    (test.assert-i64-eq (text_buf.text-buf-length buf) (string-length expected) message)))

(define (main) : i64
  (begin
    (test.assert-true (text_buf.text-buf-empty? (text_buf.text-buf-empty)) "empty buffer predicate")
    (assert-text-buf (text_buf.text-buf-empty) "" "empty buffer renders empty")
    (assert-text-buf
      (text_buf.text-buf-append
        (text_buf.text-buf-append (text_buf.text-buf-append (text_buf.text-buf-empty) "alpha") " ")
        "beta")
      "alpha beta"
      "append order")
    (let
      [buf : text_buf.TextBuf (text_buf.text-buf-empty)]
      (begin
        (text_buf.text-buf-append! buf "")
        (assert-text-buf buf "" "mutable empty append leaves buffer empty")
        (text_buf.text-buf-append! buf "alpha")
        (text_buf.text-buf-append! buf "")
        (text_buf.text-buf-append! buf " beta")
        (assert-text-buf buf "alpha beta" "mutable append order")))
    (let
      [buf : text_buf.TextBuf (text_buf.text-buf-empty)]
      [i : i64 0]
      (begin
        (while (< i 6)
          (begin
            (set! buf (text_buf.text-buf-append buf "ha"))
            (set! i (+ i 1))))
        (assert-text-buf buf "hahahahahaha" "repeated append")))
    (let
      [buf : text_buf.TextBuf (text_buf.text-buf-empty)]
      [i : i64 0]
      (begin
        (while (< i 6)
          (begin
            (text_buf.text-buf-append! buf "ha")
            (set! i (+ i 1))))
        (assert-text-buf buf "hahahahahaha" "mutable repeated append")))
    (let
      [buf : text_buf.TextBuf (text_buf.text-buf-empty)]
      [i : i64 0]
      (begin
        (while (< i 40)
          (begin
            (set! buf (text_buf.text-buf-append buf "x"))
            (set! i (+ i 1))))
        (assert-text-buf
          buf
          "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
          "balanced repeated append")))
    (assert-text-buf
      (text_buf.text-buf-append
        (text_buf.text-buf-append
          (text_buf.text-buf-append
            (text_buf.text-buf-append (text_buf.text-buf-empty) "0123456789abcdefg")
            "a")
          "b")
        "0123456789abcdefg")
      "0123456789abcdefgab0123456789abcdefg"
      "mixed small and large chunks")
    (assert-text-buf
      (text_buf.text-buf-append-int
        (text_buf.text-buf-append-char
          (text_buf.text-buf-append-char
            (text_buf.text-buf-append (text_buf.text-buf-empty) "A")
            #\newline')
          #\tab')
        -12)
      "A\n\t-12"
      "char and int append")
    (let
      [buf : text_buf.TextBuf (text_buf.text-buf-empty)]
      (begin
        (text_buf.text-buf-append! buf "A")
        (text_buf.text-buf-append-char! buf #\newline')
        (text_buf.text-buf-append-char! buf #\tab')
        (text_buf.text-buf-append-int! buf -12)
        (assert-text-buf buf "A\n\t-12" "mutable char and int append")))
    (let
      [left : text_buf.TextBuf
        (text_buf.text-buf-append (text_buf.text-buf-append (text_buf.text-buf-empty) "left") "-")]
      [right : text_buf.TextBuf
        (text_buf.text-buf-append (text_buf.text-buf-append (text_buf.text-buf-empty) "right") "\n")]
      (assert-text-buf
        (text_buf.text-buf-append-buffer left right)
        "left-right\n"
        "append buffer"))
    (let
      [original : text_buf.TextBuf (text_buf.text-buf-append (text_buf.text-buf-empty) "keep")]
      (begin
        (assert-text-buf (text_buf.text-buf-clear original) "" "clear returns empty")
        (assert-text-buf (text_buf.text-buf-reset original) "" "reset returns empty")
        (assert-text-buf original "keep" "clear leaves original value")))
    (let
      [buf : text_buf.TextBuf (text_buf.text-buf-append (text_buf.text-buf-empty) "drop")]
      (begin
        (text_buf.text-buf-clear! buf)
        (assert-text-buf buf "" "mutable clear empties buffer")
        (text_buf.text-buf-append! buf "again")
        (assert-text-buf buf "again" "mutable append after clear")
        (text_buf.text-buf-reset! buf)
        (assert-text-buf buf "" "mutable reset empties buffer")))
    (let
      [path : String "target/stdlib-verify/text_buf_api_write.txt"]
      [buf : text_buf.TextBuf
        (text_buf.text-buf-append
          (text_buf.text-buf-append
            (text_buf.text-buf-append (text_buf.text-buf-empty) "stream")
            "-")
          "write")]
      [status : i64 (text_buf.text-buf-write-file path buf)]
      (begin
        (test.assert-i64-eq status 0 "text-buf write-file status")
        (assert-owned-string-eq (io.read-file path) "stream-write" "text-buf write-file content")))
    42))
