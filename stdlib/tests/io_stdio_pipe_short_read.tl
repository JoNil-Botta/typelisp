(import "stdlib/io.tl")
(import "stdlib/test.tl")

(define pipe-stdin-read-size : i64
  4194304)
(define pipe-stdin-expected-bytes : i64
  2097152)

(define (read-all-stdin-bytes-acc [total : i64]) : i64
  (let
    [chunk : String (read-stdin-bytes pipe-stdin-read-size)]
    [next : i64 (+ total (string-length chunk))]
    (if (stdin-eof?)
      next
      (read-all-stdin-bytes-acc next))))

(define (main) : i64
  (begin
    (assert-i64-eq
      (read-all-stdin-bytes-acc 0)
      pipe-stdin-expected-bytes
      "pipe stdin byte count")
    (assert-true (stdin-at-eof?) "pipe stdin EOF after read-all")
    42))