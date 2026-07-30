(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.test)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (assert-stdin-read
  [read : io.StdinRead]
  [expected-text : String]
  [expected-eof : bool]
  [message : String]) : unit
  (begin
    (assert-owned-string-eq
      (byte_buf.to-string (io.stdin-read-buffer read))
      expected-text
      (str_cat.str-cat message " text"))
    (test.assert-bool-eq
      (io.stdin-read-eof? read)
      expected-eof
      (str_cat.str-cat message " eof"))))

(define (main) : i64
  (begin
    (test.assert-false (io.stdin-at-eof?) "stdin starts before EOF")
    (assert-stdin-read (io.stdin-read-line) "alpha" false "first line")
    (test.assert-false (io.stdin-at-eof?) "stdin not EOF after first line")
    (assert-stdin-read (io.stdin-read-line) "" false "blank line")
    (assert-stdin-read (io.stdin-read-line) "omega" true "final line")
    (test.assert-true (io.stdin-at-eof?) "stdin EOF sticks after final line")
    (let
      [text : String "stdout"]
      (io.stdout-write (byte_buf.str-as-bytes (& text))))
    (let
      [text : String "-line"]
      (io.stdout-write-line (byte_buf.str-as-bytes (& text))))
    (let
      [text : String "stderr"]
      (io.stderr-write (byte_buf.str-as-bytes (& text))))
    (let
      [text : String "-line"]
      (io.stderr-write-line (byte_buf.str-as-bytes (& text))))
    (io.stdout-flush)
    42))