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
    (assert-stdin-read (io.stdin-read-bytes 2) "ab" false "first byte read")
    (assert-stdin-read (io.stdin-read-bytes 10) "cdef" true "short byte read")
    (assert-stdin-read (io.stdin-read-bytes 0) "" true "zero byte read")
    (test.assert-true (io.stdin-at-eof?) "zero-byte read preserves EOF")
    42))