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

(define (assert-unit-unsupported
  [result : ResultIoUnit]
  [operation : String]
  [message : String]) : unit
  (match result
    [(OkIoUnit)
      (panic
        (string-append
          message
          (string-append operation " unexpectedly succeeded")))]
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

(define (assert-read-ok
  [result : ResultIoRead]
  [expected-bytes : String]
  [expected-eof : bool]
  [message : String]) : unit
  (match result
    [(OkIoRead read)
      (begin
        (assert-string-eq
          (file-read-bytes read)
          expected-bytes
          (string-append message " bytes"))
        (assert-bool-eq
          (file-read-eof? read)
          expected-eof
          (string-append message " eof")))]
    [(ErrIoRead error) (panic (string-append message (io-error-message error)))]))

(define (assert-read-unsupported [result : ResultIoRead] [message : String]) : unit
  (match result
    [(OkIoRead _) (panic (string-append message "read unexpectedly succeeded"))]
    [(ErrIoRead error) (assert-true (io-error-unsupported? error) message)]))

(define (assert-read-invalid [result : ResultIoRead] [message : String]) : unit
  (match result
    [(OkIoRead _) (panic (string-append message "read unexpectedly succeeded"))]
    [(ErrIoRead error) (assert-true (io-error-invalid-path? error) message)]))

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
          (try-write-file handle-read-file "abcdef")
          "seed read handle file: ")
        (expect-open-ok (file-open handle-read-file OpenRead) "open read: "))]
    (begin
      (assert-read-invalid
        (file-read-chunk read-handle -1)
        "negative read count returns invalid path")
      (assert-read-ok
        (file-read-chunk read-handle 0)
        ""
        false
        "zero read keeps current eof")
      (assert-read-ok
        (file-read-chunk read-handle 2)
        "ab"
        false
        "first fixed chunk")
      (assert-read-ok
        (file-read-chunk read-handle 3)
        "cde"
        false
        "second fixed chunk")
      (assert-read-ok
        (file-read-chunk read-handle 10)
        "f"
        false
        "short read before eof")
      (assert-read-ok
        (file-read-chunk read-handle 10)
        ""
        true
        "empty read observes eof")
      (assert-read-ok
        (file-read-chunk read-handle 10)
        ""
        true
        "eof remains sticky")
      (assert-ok-unit (file-close read-handle) "close read handle: ")
      (assert-read-unsupported
        (file-read-chunk read-handle 1)
        "read after close returns unsupported")
      (assert-close-unsupported
        (file-close read-handle)
        "double close returns unsupported")
      (assert-read-unsupported
        (file-read-chunk (FileHandle 999) 1)
        "invalid read handle returns unsupported")
      (assert-close-unsupported
        (file-close (FileHandle 999))
        "invalid handle returns unsupported")
      (assert-unit-unsupported
        (file-write (FileHandle 999) "x")
        "write"
        "invalid write handle returns unsupported")
      (assert-unit-unsupported
        (file-flush (FileHandle 999))
        "flush"
        "invalid flush handle returns unsupported")
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
          (assert-read-unsupported
            (file-read-chunk truncate-handle 1)
            "write-only handle read returns unsupported")
          (assert-ok-unit
            (file-write truncate-handle "alpha")
            "write truncate alpha: ")
          (assert-ok-unit
            (file-write truncate-handle "")
            "write truncate empty chunk: ")
          (assert-ok-unit
            (file-write truncate-handle "-beta")
            "write truncate beta: ")
          (assert-ok-unit
            (file-flush truncate-handle)
            "flush truncate handle: ")
          (assert-ok-unit
            (file-close truncate-handle)
            "close truncate handle: ")
          (assert-file-contents
            handle-truncate-file
            "alpha-beta"
            "truncate writes replace existing file")
          (assert-unit-unsupported
            (file-write truncate-handle "after-close")
            "write"
            "write after close returns unsupported")
          (assert-unit-unsupported
            (file-flush truncate-handle)
            "flush"
            "flush after close returns unsupported")))
      (assert-ok-unit
        (try-write-file handle-truncate-file "readonly")
        "seed read-only write test file: ")
      (let
        [read-only-handle : FileHandle
          (expect-open-ok
            (file-open handle-truncate-file OpenRead)
            "open read-only for write test: ")]
        (begin
          (assert-unit-unsupported
            (file-write read-only-handle "x")
            "write"
            "read-only handle write returns unsupported")
          (assert-unit-unsupported
            (file-flush read-only-handle)
            "flush"
            "read-only handle flush returns unsupported")
          (assert-ok-unit
            (file-close read-only-handle)
            "close read-only handle: ")))
      (assert-ok-unit
        (try-write-file handle-append-file "seed")
        "seed append file: ")
      (let
        [append-handle : FileHandle
          (expect-open-ok
            (file-open handle-append-file OpenWriteAppend)
            "open append existing: ")]
        (begin
          (assert-ok-unit
            (file-write append-handle "-tail")
            "write append tail: ")
          (assert-ok-unit (file-flush append-handle) "flush append handle: ")
          (assert-ok-unit (file-close append-handle) "close append handle: ")
          (assert-file-contents
            handle-append-file
            "seed-tail"
            "append mode writes at end of file")))
      (assert-ok-unit
        (try-remove-file-if-exists handle-created-file)
        "clean append-created file: ")
      (let
        [created-handle : FileHandle
          (expect-open-ok
            (file-open handle-created-file OpenWriteAppend)
            "open append create: ")]
        (begin
          (assert-ok-unit
            (file-write created-handle "created")
            "write append-created file: ")
          (assert-ok-unit (file-flush created-handle) "flush created handle: ")
          (assert-ok-unit (file-close created-handle) "close created handle: ")
          (assert-file-exists
            handle-created-file
            true
            "append mode creates a missing file")
          (assert-file-contents
            handle-created-file
            "created"
            "append-created file contains written bytes"))))))

(define (main) : i64
  (begin
    (if (fs-windows?)
      (begin
        (assert-open-unsupported
          (file-open handle-read-file OpenRead)
          "windows file handles are unsupported")
        (assert-read-unsupported
          (file-read-chunk (FileHandle 1) 1)
          "windows file reads are unsupported")
        (assert-unit-unsupported
          (file-write (FileHandle 1) "x")
          "write"
          "windows file writes are unsupported")
        (assert-unit-unsupported
          (file-flush (FileHandle 1))
          "flush"
          "windows file flush is unsupported"))
      (exercise-linux-file-handles))
    42))