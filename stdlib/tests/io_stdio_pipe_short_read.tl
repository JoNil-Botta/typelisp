(import stdlib.io)

(import stdlib.test)

(define pipe-stdin-read-size : i64
  4194304)

(define pipe-stdin-expected-bytes : i64
  2097152)

(define (read-all-stdin-bytes-acc [total : i64]) : i64
  (let
    [chunk : String (io.read-stdin-bytes pipe-stdin-read-size)]
    [next : i64 (+ total (string-length chunk))]
    (if (io.stdin-eof?)
      next
      (read-all-stdin-bytes-acc next))))

(define (main) : i64
  (begin
    (test.assert-i64-eq
      (read-all-stdin-bytes-acc 0)
      pipe-stdin-expected-bytes
      "pipe stdin byte count")
    (test.assert-true (io.stdin-at-eof?) "pipe stdin EOF after read-all")
    42))