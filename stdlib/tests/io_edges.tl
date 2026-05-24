(import "stdlib/io.tl")

(import "stdlib/test.tl")

(define io-file : String
  "target/stdlib-verify/io_edges_file.txt")

(define io-empty-file : String
  "target/stdlib-verify/io_edges_empty.txt")

(define io-created-file : String
  "target/stdlib-verify/io_edges_created.txt")

(define io-missing-file : String
  "target/stdlib-verify/io_edges_missing.txt")

(define (main) : i64
  (begin
    (assert-string-eq
      (read-file-or io-missing-file "fallback")
      "fallback"
      "missing file fallback")
    (assert-false
      (file-nonempty? io-missing-file)
      "missing file is not nonempty")
    (write-file io-empty-file "")
    (assert-false (file-nonempty? io-empty-file) "empty file is not nonempty")
    (write-file io-file "alpha")
    (assert-string-eq
      (read-file-or io-file "fallback")
      "alpha"
      "read existing file")
    (assert-true (file-nonempty? io-file) "written file is nonempty")
    (append-file io-file "-beta")
    (assert-string-eq (read-file io-file) "alpha-beta" "append existing file")
    (append-file io-created-file "created")
    (assert-string-eq
      (read-file io-created-file)
      "created"
      "append creates missing file")
    42))