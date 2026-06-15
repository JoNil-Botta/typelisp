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
    (assert-stdin-read (io.stdin-read-bytes 2) "ab" false "first byte read")
    (assert-stdin-read (io.stdin-read-bytes 10) "cdef" true "short byte read")
    (assert-stdin-read (io.stdin-read-bytes 0) "" true "zero byte read")
    (test.assert-true (io.stdin-at-eof?) "zero-byte read preserves EOF")
    42))