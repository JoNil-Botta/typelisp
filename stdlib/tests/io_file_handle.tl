(import stdlib.fs)

(import stdlib.io)

(import stdlib.test)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

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

(define (assert-ok-unit [result : io.ResultIoUnit] [message : String]) : unit
  (match result
    [(io.OkIoUnit) unit]
    [(io.ErrIoUnit error) (io.panic (string-append message (io.io-error-message error)))]))

(define (expect-open-ok [result : io.ResultIoFile] [message : String]) : io.FileHandle
  (match result
    [(io.OkIoFile handle) handle]
    [(io.ErrIoFile error) (io.panic (string-append message (io.io-error-message error)))]))

(define (assert-close-unsupported [result : io.ResultIoUnit] [message : String]) : unit
  (match result
    [(io.OkIoUnit) (io.panic (string-append message "close unexpectedly succeeded"))]
    [(io.ErrIoUnit error) (test.assert-true (io.io-error-unsupported? error) message)]))

(define (assert-unit-unsupported
  [result : io.ResultIoUnit]
  [operation : String]
  [message : String]) : unit
  (match result
    [(io.OkIoUnit)
      (io.panic
        (string-append
          message
          (string-append operation " unexpectedly succeeded")))]
    [(io.ErrIoUnit error) (test.assert-true (io.io-error-unsupported? error) message)]))

(define (assert-open-unsupported [result : io.ResultIoFile] [message : String]) : unit
  (match result
    [(io.OkIoFile _) (io.panic (string-append message "open unexpectedly succeeded"))]
    [(io.ErrIoFile error) (test.assert-true (io.io-error-unsupported? error) message)]))

(define (assert-open-invalid [result : io.ResultIoFile] [message : String]) : unit
  (match result
    [(io.OkIoFile _) (io.panic (string-append message "open unexpectedly succeeded"))]
    [(io.ErrIoFile error) (test.assert-true (io.io-error-invalid-path? error) message)]))

(define (assert-open-not-found [result : io.ResultIoFile] [message : String]) : unit
  (match result
    [(io.OkIoFile _) (io.panic (string-append message "open unexpectedly succeeded"))]
    [(io.ErrIoFile error) (test.assert-true (io.io-error-not-found? error) message)]))

(define (assert-read-ok
  [result : io.ResultIoRead]
  [expected-bytes : String]
  [expected-eof : bool]
  [message : String]) : unit
  (match result
    [(io.OkIoRead read)
      (begin
        (assert-owned-string-eq
          (io.file-read-bytes read)
          expected-bytes
          (string-append message " bytes"))
        (test.assert-bool-eq
          (io.file-read-eof? read)
          expected-eof
          (string-append message " eof")))]
    [(io.ErrIoRead error) (io.panic (string-append message (io.io-error-message error)))]))

(define (assert-read-unsupported [result : io.ResultIoRead] [message : String]) : unit
  (match result
    [(io.OkIoRead _) (io.panic (string-append message "read unexpectedly succeeded"))]
    [(io.ErrIoRead error) (test.assert-true (io.io-error-unsupported? error) message)]))

(define (assert-read-invalid [result : io.ResultIoRead] [message : String]) : unit
  (match result
    [(io.OkIoRead _) (io.panic (string-append message "read unexpectedly succeeded"))]
    [(io.ErrIoRead error) (test.assert-true (io.io-error-invalid-path? error) message)]))

(define (test-try-read-file [path : String]) : io.ResultIoString
  (io.try-read-file (& path)))

(define (test-try-file-exists? [path : String]) : io.ResultIoBool
  (io.try-file-exists? (& path)))

(define (test-try-write-file [path : String] [contents : String]) : io.ResultIoUnit
  (io.try-write-file (& path) (& contents)))

(define (test-try-remove-file-if-exists [path : String]) : io.ResultIoUnit
  (fs.try-remove-file-if-exists (& path)))

(define (test-file-open [path : String] [mode : io.OpenMode]) : io.ResultIoFile
  (io.file-open (& path) mode))

(define (test-file-write [handle : io.FileHandle] [contents : String]) : io.ResultIoUnit
  (io.file-write handle (& contents)))

(define (assert-file-contents
  [path : String]
  [expected : String]
  [message : String]) : unit
  (match (test-try-read-file path)
    [(io.OkIoString contents) (assert-owned-string-eq contents expected message)]
    [(io.ErrIoString error)
      (io.panic (string-append message (io.io-error-message error)))]))

(define (assert-file-exists
  [path : String]
  [expected : bool]
  [message : String]) : unit
  (match (test-try-file-exists? path)
    [(io.OkIoBool exists) (test.assert-bool-eq exists expected message)]
    [(io.ErrIoBool error) (io.panic (string-append message (io.io-error-message error)))]))

(define (exercise-linux-file-handles) : unit
  (let
    [read-handle : io.FileHandle
      (begin
        (assert-ok-unit
          (test-try-write-file handle-read-file "abcdef")
          "seed read handle file: ")
        (expect-open-ok
          (test-file-open handle-read-file io.OpenRead)
          "open read: "))]
    (begin
      (assert-read-invalid
        (io.file-read-chunk read-handle -1)
        "negative read count returns invalid path")
      (assert-read-ok
        (io.file-read-chunk read-handle 0)
        ""
        false
        "zero read keeps current eof")
      (assert-read-ok
        (io.file-read-chunk read-handle 2)
        "ab"
        false
        "first fixed chunk")
      (assert-read-ok
        (io.file-read-chunk read-handle 3)
        "cde"
        false
        "second fixed chunk")
      (assert-read-ok
        (io.file-read-chunk read-handle 10)
        "f"
        false
        "short read before eof")
      (assert-read-ok
        (io.file-read-chunk read-handle 10)
        ""
        true
        "empty read observes eof")
      (assert-read-ok
        (io.file-read-chunk read-handle 10)
        ""
        true
        "eof remains sticky")
      (assert-ok-unit (io.file-close read-handle) "close read handle: ")
      (assert-read-unsupported
        (io.file-read-chunk read-handle 1)
        "read after close returns unsupported")
      (assert-close-unsupported
        (io.file-close read-handle)
        "double close returns unsupported")
      (assert-read-unsupported
        (io.file-read-chunk (io.FileHandle 999) 1)
        "invalid read handle returns unsupported")
      (assert-close-unsupported
        (io.file-close (io.FileHandle 999))
        "invalid handle returns unsupported")
      (assert-unit-unsupported
        (test-file-write (io.FileHandle 999) "x")
        "write"
        "invalid write handle returns unsupported")
      (assert-unit-unsupported
        (io.file-flush (io.FileHandle 999))
        "flush"
        "invalid flush handle returns unsupported")
      (assert-open-not-found
        (test-file-open handle-missing-file io.OpenRead)
        "missing read open")
      (assert-open-invalid (test-file-open "" io.OpenRead) "empty path open")
      (assert-ok-unit
        (test-try-write-file handle-truncate-file "payload")
        "seed truncate file: ")
      (let
        [truncate-handle : io.FileHandle
          (expect-open-ok
            (test-file-open handle-truncate-file io.OpenWriteTruncate)
            "open truncate: ")]
        (begin
          (assert-read-unsupported
            (io.file-read-chunk truncate-handle 1)
            "write-only handle read returns unsupported")
          (assert-ok-unit
            (test-file-write truncate-handle "alpha")
            "write truncate alpha: ")
          (assert-ok-unit
            (test-file-write truncate-handle "")
            "write truncate empty chunk: ")
          (assert-ok-unit
            (test-file-write truncate-handle "-beta")
            "write truncate beta: ")
          (assert-ok-unit
            (io.file-flush truncate-handle)
            "flush truncate handle: ")
          (assert-ok-unit
            (io.file-close truncate-handle)
            "close truncate handle: ")
          (assert-file-contents
            handle-truncate-file
            "alpha-beta"
            "truncate writes replace existing file")
          (assert-unit-unsupported
            (test-file-write truncate-handle "after-close")
            "write"
            "write after close returns unsupported")
          (assert-unit-unsupported
            (io.file-flush truncate-handle)
            "flush"
            "flush after close returns unsupported")))
      (assert-ok-unit
        (test-try-write-file handle-truncate-file "readonly")
        "seed read-only write test file: ")
      (let
        [read-only-handle : io.FileHandle
          (expect-open-ok
            (test-file-open handle-truncate-file io.OpenRead)
            "open read-only for write test: ")]
        (begin
          (assert-unit-unsupported
            (test-file-write read-only-handle "x")
            "write"
            "read-only handle write returns unsupported")
          (assert-unit-unsupported
            (io.file-flush read-only-handle)
            "flush"
            "read-only handle flush returns unsupported")
          (assert-ok-unit
            (io.file-close read-only-handle)
            "close read-only handle: ")))
      (assert-ok-unit
        (test-try-write-file handle-append-file "seed")
        "seed append file: ")
      (let
        [append-handle : io.FileHandle
          (expect-open-ok
            (test-file-open handle-append-file io.OpenWriteAppend)
            "open append existing: ")]
        (begin
          (assert-ok-unit
            (test-file-write append-handle "-tail")
            "write append tail: ")
          (assert-ok-unit (io.file-flush append-handle) "flush append handle: ")
          (assert-ok-unit (io.file-close append-handle) "close append handle: ")
          (assert-file-contents
            handle-append-file
            "seed-tail"
            "append mode writes at end of file")))
      (assert-ok-unit
        (test-try-remove-file-if-exists handle-created-file)
        "clean append-created file: ")
      (let
        [created-handle : io.FileHandle
          (expect-open-ok
            (test-file-open handle-created-file io.OpenWriteAppend)
            "open append create: ")]
        (begin
          (assert-ok-unit
            (test-file-write created-handle "created")
            "write append-created file: ")
          (assert-ok-unit (io.file-flush created-handle) "flush created handle: ")
          (assert-ok-unit (io.file-close created-handle) "close created handle: ")
          (assert-file-exists
            handle-created-file
            true
            "append mode creates a missing file")
          (assert-file-contents
            handle-created-file
            "created"
            "append-created file contains written bytes"))))))

(define (exercise-linux-file-handle-reuse) : unit
  (let
    [i : i64 0]
    (begin
      (assert-ok-unit
        (test-try-write-file handle-read-file "reuse")
        "seed reusable handle file: ")
      (while (< i 1100)
        (let
          [handle : io.FileHandle
            (expect-open-ok
              (test-file-open handle-read-file io.OpenRead)
              "reopen reusable read handle: ")]
          (begin
            (assert-ok-unit (io.file-close handle) "close reusable handle: ")
            (set! i (+ i 1)))))
      unit)))

(define (main) : i64
  (begin
    (if (fs.fs-windows?)
      (begin
        (assert-open-not-found
          (test-file-open handle-read-file io.OpenRead)
          "windows missing read handle reports not found")
        (assert-read-unsupported
          (io.file-read-chunk (io.FileHandle 1) 1)
          "windows file reads are unsupported")
        (assert-unit-unsupported
          (test-file-write (io.FileHandle 1) "x")
          "write"
          "windows file writes are unsupported")
        (assert-unit-unsupported
          (io.file-flush (io.FileHandle 1))
          "flush"
          "windows file flush is unsupported"))
      (begin
        (exercise-linux-file-handles)
        (exercise-linux-file-handle-reuse)))
    42))