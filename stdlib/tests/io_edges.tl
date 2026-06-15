(import stdlib.io)

(import stdlib.test)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

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
  (match (io.try-read-file (& path))
    [(io.OkIoString contents)
      (assert-owned-string-eq
        contents
        expected
        "try-read-file returned contents")]
    [(io.ErrIoString error) (io.panic (io.io-error-message error))]))

(define (expect-try-read-missing [path : String]) : unit
  (match (io.try-read-file (& path))
    [(io.OkIoString _) (io.panic "try-read-file unexpectedly read missing file")]
    [(io.ErrIoString error)
      (begin
        (test.assert-true (io.io-error-not-found? error) "missing read error kind")
        (assert-owned-string-eq
          (io.io-error-message error)
          (string-append "io: not found: " path)
          "missing read error render"))]))

(define (expect-try-write-ok [path : String] [contents : String]) : unit
  (match (io.try-write-file (& path) (& contents))
    [(io.OkIoUnit) unit]
    [(io.ErrIoUnit error) (io.panic (io.io-error-message error))]))

(define (expect-try-read-error [path : String]) : unit
  (match (io.try-read-file (& path))
    [(io.OkIoString _) (io.panic "try-read-file unexpectedly succeeded")]
    [(io.ErrIoString _) unit]))

(define (expect-try-write-error [path : String]) : unit
  (let
    [contents : String "bad"]
    (match (io.try-write-file (& path) (& contents))
      [(io.OkIoUnit) (io.panic "try-write-file unexpectedly succeeded")]
      [(io.ErrIoUnit _) unit])))

(define (expect-try-append-error [path : String]) : unit
  (let
    [contents : String "bad"]
    (match (io.try-append-file (& path) (& contents))
      [(io.OkIoUnit) (io.panic "try-append-file unexpectedly succeeded")]
      [(io.ErrIoUnit _) unit])))

(define (test-try-file-exists? [path : String]) : io.ResultIoBool
  (io.try-file-exists? (& path)))

(define (test-read-file-or [path : String] [fallback : String]) : String
  (io.read-file-or (& path) fallback))

(define (test-file-nonempty? [path : String]) : bool
  (io.file-nonempty? (& path)))

(define (test-try-append-file [path : String] [contents : String]) : io.ResultIoUnit
  (io.try-append-file (& path) (& contents)))

(define (test-append-file [path : String] [contents : String]) : unit
  (io.append-file (& path) (& contents)))

(define (expect-invalid-path [error : io.IoError]) : unit
  (begin
    (test.assert-true (io.io-error-invalid-path? error) "invalid path error kind")
    (assert-owned-string-eq
      (io.io-error-message error)
      "io: invalid path: "
      "invalid path error render")))

(define (main) : i64
  (begin
    (expect-try-read-missing io-missing-file)
    (match (test-try-file-exists? io-missing-file)
      [(io.OkIoBool exists) (test.assert-false exists "missing file does not exist")]
      [(io.ErrIoBool error) (io.panic (io.io-error-message error))])
    (let
      [path : String ""]
      (match (io.try-read-file (& path))
        [(io.OkIoString _) (io.panic "empty path read should fail")]
        [(io.ErrIoString error) (expect-invalid-path error)]))
    (let
      [path : String ""]
      [contents : String "bad"]
      (match (io.try-write-file (& path) (& contents))
        [(io.OkIoUnit) (io.panic "empty path write should fail")]
        [(io.ErrIoUnit error) (expect-invalid-path error)]))
    (let
      [path : String ""]
      [contents : String "bad"]
      (match (io.try-append-file (& path) (& contents))
        [(io.OkIoUnit) (io.panic "empty path append should fail")]
        [(io.ErrIoUnit error) (expect-invalid-path error)]))
    (expect-try-read-error io-directory-path)
    (expect-try-write-error io-missing-parent-file)
    (expect-try-append-error io-missing-parent-file)
    (assert-owned-string-eq
      (test-read-file-or io-missing-file "fallback")
      "fallback"
      "missing file fallback")
    (test.assert-false
      (test-file-nonempty? io-missing-file)
      "missing file is not nonempty")
    (io.write-file io-empty-file "")
    (test.assert-false
      (test-file-nonempty? io-empty-file)
      "empty file is not nonempty")
    (expect-try-write-ok io-file "alpha")
    (expect-try-read-ok io-file "alpha")
    (assert-owned-string-eq
      (test-read-file-or io-file "fallback")
      "alpha"
      "read existing file")
    (test.assert-true (test-file-nonempty? io-file) "written file is nonempty")
    (let
      [contents : String "-beta"]
      (match (test-try-append-file io-file contents)
        [(io.OkIoUnit) unit]
        [(io.ErrIoUnit error) (io.panic (io.io-error-message error))]))
    (assert-owned-string-eq
      (io.read-file io-file)
      "alpha-beta"
      "append existing file")
    (let
      [contents : String "created"]
      (test-append-file io-created-file contents))
    (assert-owned-string-eq
      (io.read-file io-created-file)
      "created"
      "append creates missing file")
    42))