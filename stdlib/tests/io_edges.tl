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

(define io-missing-parent-file : String
  "target/stdlib-verify/io-missing-parent/io_edges.txt")

(define io-directory-path : String
  "target/stdlib-verify")

(define (expect-try-read-ok [path : String] [expected : String]) : unit
  (match (try-read-file path)
    [(OkIoString contents)
      (assert-string-eq contents expected "try-read-file returned contents")]
    [(ErrIoString error) (panic (io-error-message error))]))

(define (expect-try-read-missing [path : String]) : unit
  (match (try-read-file path)
    [(OkIoString _) (panic "try-read-file unexpectedly read missing file")]
    [(ErrIoString error)
      (begin
        (assert-true (io-error-not-found? error) "missing read error kind")
        (assert-string-eq
          (io-error-message error)
          (string-append "io: not found: " path)
          "missing read error render"))]))

(define (expect-try-write-ok [path : String] [contents : String]) : unit
  (match (try-write-file path contents)
    [(OkIoUnit) unit]
    [(ErrIoUnit error) (panic (io-error-message error))]))

(define (expect-try-read-error [path : String]) : unit
  (match (try-read-file path)
    [(OkIoString _) (panic "try-read-file unexpectedly succeeded")]
    [(ErrIoString _) unit]))

(define (expect-try-write-error [path : String]) : unit
  (match (try-write-file path "bad")
    [(OkIoUnit) (panic "try-write-file unexpectedly succeeded")]
    [(ErrIoUnit _) unit]))

(define (expect-invalid-path [error : IoError]) : unit
  (begin
    (assert-true (io-error-invalid-path? error) "invalid path error kind")
    (assert-string-eq
      (io-error-message error)
      "io: invalid path: "
      "invalid path error render")))

(define (main) : i64
  (begin
    (expect-try-read-missing io-missing-file)
    (match (try-file-exists? io-missing-file)
      [(OkIoBool exists) (assert-false exists "missing file does not exist")]
      [(ErrIoBool error) (panic (io-error-message error))])
    (match (try-read-file "")
      [(OkIoString _) (panic "empty path read should fail")]
      [(ErrIoString error) (expect-invalid-path error)])
    (match (try-write-file "" "bad")
      [(OkIoUnit) (panic "empty path write should fail")]
      [(ErrIoUnit error) (expect-invalid-path error)])
    (expect-try-read-error io-directory-path)
    (expect-try-write-error io-missing-parent-file)
    (assert-string-eq
      (read-file-or io-missing-file "fallback")
      "fallback"
      "missing file fallback")
    (assert-false
      (file-nonempty? io-missing-file)
      "missing file is not nonempty")
    (write-file io-empty-file "")
    (assert-false (file-nonempty? io-empty-file) "empty file is not nonempty")
    (expect-try-write-ok io-file "alpha")
    (expect-try-read-ok io-file "alpha")
    (assert-string-eq
      (read-file-or io-file "fallback")
      "alpha"
      "read existing file")
    (assert-true (file-nonempty? io-file) "written file is nonempty")
    (match (try-append-file io-file "-beta")
      [(OkIoUnit) unit]
      [(ErrIoUnit error) (panic (io-error-message error))])
    (assert-string-eq (read-file io-file) "alpha-beta" "append existing file")
    (append-file io-created-file "created")
    (assert-string-eq
      (read-file io-created-file)
      "created"
      "append creates missing file")
    42))