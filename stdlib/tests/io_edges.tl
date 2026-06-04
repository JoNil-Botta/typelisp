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
  (match (try-read-file (& path))
    [(OkIoString contents)
      (assert-string-eq contents expected "try-read-file returned contents")]
    [(ErrIoString error) (panic (io-error-message error))]))

(define (expect-try-read-missing [path : String]) : unit
  (match (try-read-file (& path))
    [(OkIoString _) (panic "try-read-file unexpectedly read missing file")]
    [(ErrIoString error)
      (begin
        (assert-true (io-error-not-found? error) "missing read error kind")
        (assert-string-eq
          (io-error-message error)
          (string-append "io: not found: " path)
          "missing read error render"))]))

(define (expect-try-write-ok [path : String] [contents : String]) : unit
  (match (try-write-file (& path) (& contents))
    [(OkIoUnit) unit]
    [(ErrIoUnit error) (panic (io-error-message error))]))

(define (expect-try-read-error [path : String]) : unit
  (match (try-read-file (& path))
    [(OkIoString _) (panic "try-read-file unexpectedly succeeded")]
    [(ErrIoString _) unit]))

(define (expect-try-write-error [path : String]) : unit
  (let
    [contents : String "bad"]
    (match (try-write-file (& path) (& contents))
      [(OkIoUnit) (panic "try-write-file unexpectedly succeeded")]
      [(ErrIoUnit _) unit])))

(define (expect-try-append-error [path : String]) : unit
  (let
    [contents : String "bad"]
    (match (try-append-file (& path) (& contents))
      [(OkIoUnit) (panic "try-append-file unexpectedly succeeded")]
      [(ErrIoUnit _) unit])))

(define (test-try-file-exists? [path : String]) : ResultIoBool
  (try-file-exists? (& path)))

(define (test-read-file-or [path : String] [fallback : String]) : String
  (read-file-or (& path) fallback))

(define (test-file-nonempty? [path : String]) : bool
  (file-nonempty? (& path)))

(define (test-try-append-file [path : String] [contents : String]) : ResultIoUnit
  (try-append-file (& path) (& contents)))

(define (test-append-file [path : String] [contents : String]) : unit
  (append-file (& path) (& contents)))

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
    (match (test-try-file-exists? io-missing-file)
      [(OkIoBool exists) (assert-false exists "missing file does not exist")]
      [(ErrIoBool error) (panic (io-error-message error))])
    (let
      [path : String ""]
      (match (try-read-file (& path))
        [(OkIoString _) (panic "empty path read should fail")]
        [(ErrIoString error) (expect-invalid-path error)]))
    (let
      [path : String ""]
      [contents : String "bad"]
      (match (try-write-file (& path) (& contents))
        [(OkIoUnit) (panic "empty path write should fail")]
        [(ErrIoUnit error) (expect-invalid-path error)]))
    (let
      [path : String ""]
      [contents : String "bad"]
      (match (try-append-file (& path) (& contents))
        [(OkIoUnit) (panic "empty path append should fail")]
        [(ErrIoUnit error) (expect-invalid-path error)]))
    (expect-try-read-error io-directory-path)
    (expect-try-write-error io-missing-parent-file)
    (expect-try-append-error io-missing-parent-file)
    (assert-string-eq
      (test-read-file-or io-missing-file "fallback")
      "fallback"
      "missing file fallback")
    (assert-false
      (test-file-nonempty? io-missing-file)
      "missing file is not nonempty")
    (write-file io-empty-file "")
    (assert-false
      (test-file-nonempty? io-empty-file)
      "empty file is not nonempty")
    (expect-try-write-ok io-file "alpha")
    (expect-try-read-ok io-file "alpha")
    (assert-string-eq
      (test-read-file-or io-file "fallback")
      "alpha"
      "read existing file")
    (assert-true (test-file-nonempty? io-file) "written file is nonempty")
    (let
      [contents : String "-beta"]
      (match (test-try-append-file io-file contents)
        [(OkIoUnit) unit]
        [(ErrIoUnit error) (panic (io-error-message error))]))
    (assert-string-eq (read-file io-file) "alpha-beta" "append existing file")
    (let
      [contents : String "created"]
      (test-append-file io-created-file contents))
    (assert-string-eq
      (read-file io-created-file)
      "created"
      "append creates missing file")
    42))