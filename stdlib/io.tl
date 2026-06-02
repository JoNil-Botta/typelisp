;# File I/O utility library for TypeLisp (#702).
;#
;# Provides file, argv, panic, and stdio helpers built from explicit externs
;# to backend-emitted runtime symbols.
;#
;# Public runtime-facing functions such as `print-string`, `panic`, `arg`,
;# `read-file`, `write-file`, file-handle status helpers, and stdin/stdout
;# helpers are ordinary stdlib definitions in this module. Programs must import
;# this module to use them.
;#
;# The `try-*` helpers return explicit monomorphic result enums. Host errors
;# are reported through status-code primitives and mapped into `IoError`.
;#
;# Usage: `(import "stdlib/io.tl")`
;#
;# ```typelisp
;# (import "stdlib/io.tl")
;# (define fallback : ResultIoString (try-read-file "missing-file-for-docs.txt"))
;# ```
;#
;# ```typelisp
;# (import "stdlib/io.tl")
;# (define empty-read : StdinRead (stdin-read-bytes 0))
;# ```
;#
;# ```typelisp run
;# ;; doctest-exit: 0
;# ;; doctest-stdout: literal:hello from io\n
;# (import "stdlib/io.tl")
;# (define (main) : i64
;#   (begin
;#     (stdout-write "hello from io\n")
;#     0))
;# ```
(extern tl_print_string : (-> String unit))

(extern tl_print_error : (-> String unit))

(extern tl_abort_string : (-> String unit))

(extern tl_arg_count : (-> i64))

(extern tl_arg : (-> i64 String))

(extern tl_read_file : (-> String String))

(extern tl_read_file_status : (-> String i64))

(extern tl_write_file : (-> String String unit))

(extern tl_write_file_status : (-> String String i64))

(extern tl_append_file_status : (-> String String i64))

(extern tl_file_exists : (-> String bool))

(extern tl_file_exists_status : (-> String i64))

(extern tl_file_open_status : (-> String i64 i64))

(extern tl_file_close_status : (-> i64 i64))

(extern tl_file_read_chunk_status : (-> i64 i64 i64))

(extern tl_file_write_status : (-> i64 String i64))

(extern tl_file_flush_status : (-> i64 i64))

(extern tl_file_read_chunk_bytes : (-> i64 String))

(extern tl_file_read_chunk_eof : (-> i64 bool))

(extern tl_read_stdin_line : (-> String))

(extern tl_read_stdin_bytes : (-> i64 String))

(extern tl_stdin_eof : (-> bool))

(extern tl_flush_stdout : (-> unit))

;: Return the number of process argv entries.
(define (arg-count) : i64
  (tl_arg_count))

;: Return argv entry `index`, aborting on out-of-range indices.
(define (arg [index : i64]) : String
  (tl_arg index))

;: Write a string to stdout without adding a newline.
(define (print-string [text : String]) : unit
  (tl_print_string text))

;: Compatibility alias for `print-string`.
(define (print-str [text : String]) : unit
  (print-string text))

;: Write a string to stderr without adding a newline.
(define (print-error [text : String]) : unit
  (tl_print_error text))

;: Abort the process after writing `message` to stderr.
(define (panic [message : String]) : never
  (begin
    (tl_abort_string message)
    (panic message)))

;: Alias for `panic`.
(define (error [message : String]) : never
  (panic message))

;: Read a whole file, aborting on host read failure.
(define (read-file [path : String]) : String
  (tl_read_file path))

;: Return the host status code for reading `path`.
(define (read-file-status [path : String]) : i64
  (tl_read_file_status path))

;: Write a whole file, aborting on host write failure.
(define (write-file [path : String] [contents : String]) : unit
  (tl_write_file path contents))

;: Return the host status code for writing `contents` to `path`.
(define (write-file-status [path : String] [contents : String]) : i64
  (tl_write_file_status path contents))

;: Return the host status code for appending `contents` to `path`.
(define (append-file-status [path : String] [contents : String]) : i64
  (tl_append_file_status path contents))

;: Return true when `path` exists, aborting on hard host probe failure.
(define (file-exists? [path : String]) : bool
  (tl_file_exists path))

;: Return the host status code for probing `path`.
(define (file-exists-status [path : String]) : i64
  (tl_file_exists_status path))

;: Return a runtime file handle id or negative status for opening `path`.
(define (file-open-status [path : String] [mode : i64]) : i64
  (tl_file_open_status path mode))

;: Return the host status code for closing a runtime file handle id.
(define (file-close-status [handle : i64]) : i64
  (tl_file_close_status handle))

;: Return the host status code for reading a chunk into the runtime handle cache.
(define (file-read-chunk-status [handle : i64] [count : i64]) : i64
  (tl_file_read_chunk_status handle count))

;: Return the host status code for writing `contents` through a runtime handle.
(define (file-write-status [handle : i64] [contents : String]) : i64
  (tl_file_write_status handle contents))

;: Return the host status code for flushing a runtime handle.
(define (file-flush-status [handle : i64]) : i64
  (tl_file_flush_status handle))

;: Return bytes from the last successful runtime file chunk read.
(define (file-read-chunk-bytes [handle : i64]) : String
  (tl_file_read_chunk_bytes handle))

;: Return the sticky EOF bit from the last successful runtime file chunk read.
(define (file-read-chunk-eof? [handle : i64]) : bool
  (tl_file_read_chunk_eof handle))

;: Read one stdin line without the trailing newline.
(define (read-stdin-line) : String
  (tl_read_stdin_line))

;: Read up to `count` bytes from stdin.
(define (read-stdin-bytes [count : i64]) : String
  (tl_read_stdin_bytes count))

;: Return the sticky stdin EOF state.
(define (stdin-eof?) : bool
  (tl_stdin_eof))

;: Flush stdout.
(define (flush-stdout) : unit
  (tl_flush_stdout))

;: Structured file I/O failures.
;:
;: `IoSystemCode` stores a target-specific positive error code and path.
(defenum IoError
  (IoNotFound String)
  (IoPermissionDenied String)
  (IoInvalidPath String)
  (IoUnsupported String)
  (IoInterrupted String)
  (IoSystemCode i64 String)
  (IoUnknown String))

;: Result type for string-returning file I/O APIs.
(defenum ResultIoString
  (OkIoString String)
  (ErrIoString IoError))

;: Result type for unit-returning file I/O APIs.
(defenum ResultIoUnit
  (OkIoUnit)
  (ErrIoUnit IoError))

;: Result type for bool-returning file I/O APIs.
(defenum ResultIoBool
  (OkIoBool bool)
  (ErrIoBool IoError))

;: Opaque runtime-managed file handle id.
;:
;: v1 handles must be closed explicitly with `file-close`; there is no implicit
;: drop until move-only/drop semantics land.
(defstruct FileHandle
  (id i64))

;: File open mode for v1 streaming handles.
(defenum OpenMode
  (OpenRead)
  (OpenWriteTruncate)
  (OpenWriteAppend))

;: Result type for file-handle opening.
(defenum ResultIoFile
  (OkIoFile FileHandle)
  (ErrIoFile IoError))

;: Streaming file read chunk backed by active-arena owned bytes.
;:
;: `bytes` currently uses `String` as a byte container until #807 splits text
;: strings from binary byte slices.
(defstruct FileRead
  (bytes String)
  (eof bool))

;: Result type for streaming file reads.
(defenum ResultIoRead
  (OkIoRead FileRead)
  (ErrIoRead IoError))

;: Stdin read result containing the bytes/text read plus the post-read EOF flag.
;:
;: `text` is currently a `String` for both line and fixed-byte reads. This will
;: remain source-compatible but may gain a byte-slice variant after #807 splits
;: owned text strings from borrowed/binary bytes.
(defstruct StdinRead
  (text String)
  (eof bool))

;: Portable errno-style status code used by runtime helpers for success.
(define io-status-ok : i64
  0)

;: Common host status code for interrupted syscalls.
(define io-status-interrupted : i64
  4)

;: Common host status code for I/O errors such as short writes.
(define io-status-io-error : i64
  5)

;: Common host status code for paths that cannot be accessed due to permissions.
(define io-status-permission-denied : i64
  13)

;: Common host status code for a missing file or final path component.
(define io-status-not-found : i64
  2)

;: Common host status code for a missing path prefix component.
(define io-status-not-directory : i64
  20)

;: Common host status code for trying to read a directory as a file.
(define io-status-is-directory : i64
  21)

;: Common host status code for unsupported operations.
(define io-status-unsupported : i64
  38)

;: Common host status code for invalid arguments or path encodings.
(define io-status-invalid : i64
  22)

;: Common Linux host status code for an overlong path.
(define io-status-name-too-long : i64
  36)

;: Return true when `path` is syntactically empty.
(define (io-empty-path? [path : String]) : bool
  (= (string-length path) 0))

;: Render an I/O error into a human-readable diagnostic string.
(define (io-error-message [error : IoError]) : String
  (match error
    [(IoNotFound path) (string-append "io: not found: " path)]
    [(IoPermissionDenied path) (string-append "io: permission denied: " path)]
    [(IoInvalidPath path) (string-append "io: invalid path: " path)]
    [(IoUnsupported message) (string-append "io: unsupported: " message)]
    [(IoInterrupted path) (string-append "io: interrupted: " path)]
    [(IoSystemCode code path)
      (string-append
        (string-append "io: system error " (int->string code))
        (string-append ": " path))]
    [(IoUnknown path) (string-append "io: unknown failure: " path)]))

;: Return true when `error` is a not-found diagnostic.
(define (io-error-not-found? [error : IoError]) : bool
  (match error
    [(IoNotFound _) true]
    [_ false]))

;: Return true when `error` is an invalid-path diagnostic.
(define (io-error-invalid-path? [error : IoError]) : bool
  (match error
    [(IoInvalidPath _) true]
    [_ false]))

;: Return true when `error` is an unsupported-runtime diagnostic.
(define (io-error-unsupported? [error : IoError]) : bool
  (match error
    [(IoUnsupported _) true]
    [_ false]))

;: Return true when `code` means a path is absent rather than a hard probe error.
(define (io-status-expected-absence? [code : i64]) : bool
  (if (= code io-status-not-found)
    true
    (= code io-status-not-directory)))

;: Convert a runtime status code into the public structured error model.
(define (io-error-from-status [path : String] [code : i64]) : IoError
  (cond
    [(io-status-expected-absence? code) (IoNotFound path)]
    [(= code io-status-permission-denied) (IoPermissionDenied path)]
    [(= code io-status-invalid) (IoInvalidPath path)]
    [(= code io-status-name-too-long) (IoInvalidPath path)]
    [(= code io-status-interrupted) (IoInterrupted path)]
    [(= code io-status-is-directory) (IoUnsupported path)]
    [(= code io-status-unsupported) (IoUnsupported path)]
    [(= code io-status-ok) (IoUnknown path)]
    [else (IoSystemCode code path)]))

;: Convert an open mode into the runtime helper's compact mode code.
(define (open-mode-code [mode : OpenMode]) : i64
  (match mode
    [(OpenRead) 0]
    [(OpenWriteTruncate) 1]
    [(OpenWriteAppend) 2]))

;: Diagnostic payload for invalid or already-closed file handles.
(define (file-handle-invalid-message) : String
  "file handle is closed or invalid")

;: Diagnostic payload for invalid streaming reads.
(define (file-read-unsupported-message) : String
  "file handle is closed, invalid, or not open for reading")

;: Diagnostic payload for invalid streaming writes.
(define (file-write-unsupported-message) : String
  "file handle is closed, invalid, or not open for writing")

;: Diagnostic payload for invalid streaming flushes.
(define (file-flush-unsupported-message) : String
  "file handle is closed, invalid, or not open for writing")

;: Diagnostic payload for invalid streaming read counts.
(define (file-read-invalid-count-message) : String
  "file-read-chunk count must be non-negative")

;: Open `path` in `mode`, returning a runtime-managed file handle.
;:
;: The returned handle must be passed to `file-close`. Empty paths return
;: `IoInvalidPath`; unsupported targets and mode/host failures are reported as
;: structured `IoError` values.
(define (file-open [path : String] [mode : OpenMode]) : ResultIoFile
  (if (io-empty-path? path)
    (ErrIoFile (IoInvalidPath path))
    (let
      [raw : i64 (file-open-status path (open-mode-code mode))]
      (if (< raw 0)
        (ErrIoFile (io-error-from-status path (- 0 raw)))
        (OkIoFile (FileHandle raw))))))

;: Close a runtime-managed file handle.
;:
;: Closing a valid handle returns `OkIoUnit`. Closing an invalid or already
;: closed handle returns `ErrIoUnit (IoUnsupported ...)` and never panics.
(define (file-close [handle : FileHandle]) : ResultIoUnit
  (let
    [status : i64 (file-close-status (struct-get handle id))]
    (if (= status io-status-ok)
      OkIoUnit
      (if (= status io-status-unsupported)
        (ErrIoUnit (IoUnsupported (file-handle-invalid-message)))
        (ErrIoUnit (io-error-from-status "file-close" status))))))

;: Return the bytes captured by a streaming file read.
(define (file-read-bytes [read : FileRead]) : String
  (struct-get read bytes))

;: Return true when a streaming file read observed EOF after the read.
(define (file-read-eof? [read : FileRead]) : bool
  (struct-get read eof))

;: Read up to `count` bytes from a runtime-managed read-mode file handle.
;:
;: The returned bytes are represented as `String` until #807 adds a distinct
;: byte-string/slice type. A short read does not imply EOF; EOF becomes true
;: only after the runtime receives a zero-byte host read.
(define (file-read-chunk [handle : FileHandle] [count : i64]) : ResultIoRead
  (if (< count 0)
    (ErrIoRead (IoInvalidPath (file-read-invalid-count-message)))
    (let
      [raw : i64 (struct-get handle id)]
      [status : i64 (file-read-chunk-status raw count)]
      (if (= status io-status-ok)
        (OkIoRead
          (FileRead (file-read-chunk-bytes raw) (file-read-chunk-eof? raw)))
        (if (= status io-status-unsupported)
          (ErrIoRead (IoUnsupported (file-read-unsupported-message)))
          (ErrIoRead (io-error-from-status "file-read-chunk" status)))))))

;: Write `contents` to a runtime-managed write-mode file handle.
;:
;: The runtime retries short host writes until all bytes are accepted or a
;: host error is returned. Closed, invalid, read-only, and unsupported handles
;: return `IoUnsupported`.
(define (file-write [handle : FileHandle] [contents : String]) : ResultIoUnit
  (let
    [status : i64 (file-write-status (struct-get handle id) contents)]
    (if (= status io-status-ok)
      OkIoUnit
      (if (= status io-status-unsupported)
        (ErrIoUnit (IoUnsupported (file-write-unsupported-message)))
        (ErrIoUnit (io-error-from-status "file-write" status))))))

;: Flush a runtime-managed write-mode file handle.
;:
;: Closed, invalid, read-only, and unsupported handles return
;: `IoUnsupported`; host flush failures are mapped through `io-error-from-status`.
(define (file-flush [handle : FileHandle]) : ResultIoUnit
  (let
    [status : i64 (file-flush-status (struct-get handle id))]
    (if (= status io-status-ok)
      OkIoUnit
      (if (= status io-status-unsupported)
        (ErrIoUnit (IoUnsupported (file-flush-unsupported-message)))
        (ErrIoUnit (io-error-from-status "file-flush" status))))))

;: Read `path` and return either its contents or a structured I/O error.
;:
;: Missing paths return `IoNotFound`. Empty paths return `IoInvalidPath`.
(define (try-read-file [path : String]) : ResultIoString
  (if (io-empty-path? path)
    (ErrIoString (IoInvalidPath path))
    (let
      [status : i64 (read-file-status path)]
      (if (= status io-status-ok)
        (OkIoString (read-file path))
        (ErrIoString (io-error-from-status path status))))))

;: Write `contents` to `path`, returning a structured result.
;:
;: Empty paths return `IoInvalidPath`.
(define (try-write-file [path : String] [contents : String]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (IoInvalidPath path))
    (let
      [status : i64 (write-file-status path contents)]
      (if (= status io-status-ok)
        OkIoUnit
        (ErrIoUnit (io-error-from-status path status))))))

;: Probe whether `path` exists, returning a structured result.
;:
;: Missing paths are represented as `OkIoBool false`, because absence is an
;: expected result of an existence probe. Empty paths return `IoInvalidPath`.
(define (try-file-exists? [path : String]) : ResultIoBool
  (if (io-empty-path? path)
    (ErrIoBool (IoInvalidPath path))
    (let
      [status : i64 (file-exists-status path)]
      (if (= status io-status-ok)
        (OkIoBool true)
        (if (io-status-expected-absence? status)
          (OkIoBool false)
          (ErrIoBool (io-error-from-status path status)))))))

;: Append `contents` to `path`, returning a structured result.
;:
;: The runtime opens the path in host append mode where available, preserving
;: existing contents and creating the file when missing. Empty paths return
;: `IoInvalidPath`.
(define (try-append-file [path : String] [contents : String]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (IoInvalidPath path))
    (let
      [status : i64 (append-file-status path contents)]
      (if (= status io-status-ok)
        OkIoUnit
        (ErrIoUnit (io-error-from-status path status))))))

;: Read the contents of `path` if it exists, otherwise return `fallback`.
;:
;: This is a convenience wrapper over `try-read-file`. It returns `fallback`
;: for every structured error, preserving the historical optional-file API.
(define (read-file-or [path : String] [fallback : String]) : String
  (match (try-read-file path)
    [(OkIoString contents) contents]
    [(ErrIoString _) fallback]))

;: Append `contents` to the file at `path`, creating it when absent.
;:
;: Uses the runtime append-status primitive: non-truncating, create-if-missing,
;: and best-effort host append semantics.
(define (append-file [path : String] [contents : String]) : unit
  (match (try-append-file path contents)
    [(OkIoUnit) unit]
    [(ErrIoUnit error)
      (begin
        (panic (io-error-message error))
        unit)]))

;: Return true when `path` exists and its contents are non-empty.
;:
;: Structured errors return false.
(define (file-nonempty? [path : String]) : bool
  (match (try-read-file path)
    [(OkIoString contents) (> (string-length contents) 0)]
    [(ErrIoString _) false]))

;: Return the text/bytes captured by a stdin read result.
(define (stdin-read-text [read : StdinRead]) : String
  (struct-get read text))

;: Return true when a stdin read observed EOF after the read completed.
(define (stdin-read-eof? [read : StdinRead]) : bool
  (struct-get read eof))

;: Return the current sticky stdin EOF state without performing a read.
(define (stdin-at-eof?) : bool
  (stdin-eof?))

;: Read one stdin line without the trailing newline and report post-read EOF.
;:
;: The returned string is allocated by the runtime in the active arena. Blank
;: lines return an empty string with `eof` false; end-of-file after the final
;: unterminated line returns that line with `eof` true.
(define (stdin-read-line) : StdinRead
  (let
    [text : String (read-stdin-line)]
    (StdinRead text (stdin-eof?))))

;: Read up to `count` bytes from stdin and report post-read EOF.
;:
;: The returned bytes are represented as `String` until #807 adds a distinct
;: byte-string/slice type. The runtime handles invalid counts consistently with
;: the raw primitive.
(define (stdin-read-bytes [count : i64]) : StdinRead
  (let
    [text : String (read-stdin-bytes count)]
    (StdinRead text (stdin-eof?))))

;: Write `text` to stdout without adding a newline.
(define (stdout-write [text : String]) : unit
  (print-string text))

;: Write `text` and a trailing newline to stdout.
;:
;: This convenience helper allocates the newline-appended string.
(define (stdout-write-line [text : String]) : unit
  (print-string (string-append text "\n")))

;: Flush stdout.
(define (stdout-flush) : unit
  (flush-stdout))

;: Write `text` to stderr without adding a newline.
(define (stderr-write [text : String]) : unit
  (print-error text))

;: Write `text` and a trailing newline to stderr.
;:
;: This convenience helper allocates the newline-appended string.
(define (stderr-write-line [text : String]) : unit
  (print-error (string-append text "\n")))