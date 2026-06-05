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
    (assert-stdin-read (stdin-read-bytes 2) "ab" false "first byte read")
    (assert-stdin-read (stdin-read-bytes 10) "cdef" true "short byte read")
    (assert-stdin-read (stdin-read-bytes 0) "" true "zero byte read")
    (assert-true (stdin-at-eof?) "zero-byte read preserves EOF")
    42))