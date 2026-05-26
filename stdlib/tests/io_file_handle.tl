(import "stdlib/fs.tl")

(import "stdlib/io.tl")

(import "stdlib/test.tl")

(define handle-read-file : String
  "target/stdlib-verify/io_file_handle_read.txt")

(define handle-truncate-file : String
  "target/stdlib-verify/io_file_handle_truncate.txt")

(define handle-append-file : String
  "target/stdlib-verify/io_file_handle_append.txt")

(define handle-created-file : String
  "target/stdlib-verify/io_file_handle_created.txt")

(define handle-missing-file : String
  "target/stdlib-verify/io_file_handle_missing.txt")

(define (assert-ok-unit [result : ResultIoUnit] [message : String]) : unit
  (match result
    [(OkIoUnit) unit]
    [(ErrIoUnit error) (panic (string-append message (io-error-message error)))]))

(define (expect-open-ok [result : ResultIoFile] [message : String]) : FileHandle
  (match result
    [(OkIoFile handle) handle]
    [(ErrIoFile error) (panic (string-append message (io-error-message error)))]))

(define (assert-close-unsupported [result : ResultIoUnit] [message : String]) : unit
  (match result
    [(OkIoUnit) (panic (string-append message "close unexpectedly succeeded"))]
    [(ErrIoUnit error) (assert-true (io-error-unsupported? error) message)]))

(define (assert-open-unsupported [result : ResultIoFile] [message : String]) : unit
  (match result
    [(OkIoFile _) (panic (string-append message "open unexpectedly succeeded"))]
    [(ErrIoFile error) (assert-true (io-error-unsupported? error) message)]))

(define (assert-open-invalid [result : ResultIoFile] [message : String]) : unit
  (match result
    [(OkIoFile _) (panic (string-append message "open unexpectedly succeeded"))]
    [(ErrIoFile error) (assert-true (io-error-invalid-path? error) message)]))

(define (assert-open-not-found [result : ResultIoFile] [message : String]) : unit
  (match result
    [(OkIoFile _) (panic (string-append message "open unexpectedly succeeded"))]
    [(ErrIoFile error) (assert-true (io-error-not-found? error) message)]))

(define (assert-file-contents
  [path : String]
  [expected : String]
  [message : String]) : unit
  (match (try-read-file path)
    [(OkIoString contents) (assert-string-eq contents expected message)]
    [(ErrIoString error)
      (panic (string-append message (io-error-message error)))]))

(define (assert-file-exists
  [path : String]
  [expected : bool]
  [message : String]) : unit
  (match (try-file-exists? path)
    [(OkIoBool exists) (assert-bool-eq exists expected message)]
    [(ErrIoBool error) (panic (string-append message (io-error-message error)))]))

(define (exercise-linux-file-handles) : unit
  (let
    [read-handle : FileHandle
      (begin
        (assert-ok-unit
          (try-write-file handle-read-file "alpha")
          "seed read handle file: ")
        (expect-open-ok (file-open handle-read-file OpenRead) "open read: "))]
    (begin
      (assert-ok-unit (file-close read-handle) "close read handle: ")
      (assert-close-unsupported
        (file-close read-handle)
        "double close returns unsupported")
      (assert-close-unsupported
        (file-close (FileHandle 999))
        "invalid handle returns unsupported")
      (assert-open-not-found
        (file-open handle-missing-file OpenRead)
        "missing read open")
      (assert-open-invalid (file-open "" OpenRead) "empty path open")
      (assert-ok-unit
        (try-write-file handle-truncate-file "payload")
        "seed truncate file: ")
      (let
        [truncate-handle : FileHandle
          (expect-open-ok
            (file-open handle-truncate-file OpenWriteTruncate)
            "open truncate: ")]
        (begin
          (assert-ok-unit
            (file-close truncate-handle)
            "close truncate handle: ")
          (assert-file-contents
            handle-truncate-file
            ""
            "truncate mode clears existing file")))
      (assert-ok-unit
        (try-write-file handle-append-file "seed")
        "seed append file: ")
      (let
        [append-handle : FileHandle
          (expect-open-ok
            (file-open handle-append-file OpenWriteAppend)
            "open append existing: ")]
        (begin
          (assert-ok-unit (file-close append-handle) "close append handle: ")
          (assert-file-contents
            handle-append-file
            "seed"
            "append mode preserves existing file without writes")))
      (let
        [created-handle : FileHandle
          (expect-open-ok
            (file-open handle-created-file OpenWriteAppend)
            "open append create: ")]
        (begin
          (assert-ok-unit (file-close created-handle) "close created handle: ")
          (assert-file-exists
            handle-created-file
            true
            "append mode creates a missing file"))))))

(define (main) : i64
  (begin
    (if (fs-windows?)
      (assert-open-unsupported
        (file-open handle-read-file OpenRead)
        "windows file handles are unsupported")
      (exercise-linux-file-handles))
    42))