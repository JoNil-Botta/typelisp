(import "stdlib/io.tl")
(import "stdlib/test.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (assert-stdin-read
  [read : StdinRead]
  [expected-text : String]
  [expected-eof : bool]
  [message : String]) : unit
  (begin
    (assert-owned-string-eq
      (stdin-read-text read)
      expected-text
      (string-append message " text"))
    (assert-bool-eq
      (stdin-read-eof? read)
      expected-eof
      (string-append message " eof"))))

(define (main) : i64
  (begin
    (assert-false (stdin-at-eof?) "stdin starts before EOF")
    (assert-stdin-read (stdin-read-line) "alpha" false "first line")
    (assert-false (stdin-at-eof?) "stdin not EOF after first line")
    (assert-stdin-read (stdin-read-line) "" false "blank line")
    (assert-stdin-read (stdin-read-line) "omega" true "final line")
    (assert-true (stdin-at-eof?) "stdin EOF sticks after final line")
    (let
      [text : String "stdout"]
      (stdout-write (& text)))
    (let
      [text : String "-line"]
      (stdout-write-line (& text)))
    (let
      [text : String "stderr"]
      (stderr-write (& text)))
    (let
      [text : String "-line"]
      (stderr-write-line (& text)))
    (stdout-flush)
    42))