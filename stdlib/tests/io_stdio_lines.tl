(import stdlib.io)

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
      (io.stdin-read-text read)
      expected-text
      (string-append message " text"))
    (test.assert-bool-eq
      (io.stdin-read-eof? read)
      expected-eof
      (string-append message " eof"))))

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
      (io.stdout-write (& text)))
    (let
      [text : String "-line"]
      (io.stdout-write-line (& text)))
    (let
      [text : String "stderr"]
      (io.stderr-write (& text)))
    (let
      [text : String "-line"]
      (io.stderr-write-line (& text)))
    (io.stdout-flush)
    42))