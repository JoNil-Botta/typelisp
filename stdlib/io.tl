;;;; File I/O utility library for TypeLisp (#702).
;;;;
;;;; Provides higher-level file and stdio helpers built on the compiler/runtime
;;;; I/O primitives, mirroring how `stdlib/string.tl` wraps string primitives.
;;;;
;;;; Primitives required from the compiler/runtime: `read-file`, `write-file`,
;;;; `file-exists?`, `read-stdin-line`, `read-stdin-bytes`, `stdin-eof?`,
;;;; `print-string`, `print-error`, `flush-stdout`, `int->string`,
;;;; `string-append`, and `string-length`.
;;;;
;;;; The `try-*` helpers return explicit monomorphic result enums. The current
;;;; runtime can classify empty paths and expected read absence before calling
;;;; panic-on-error primitives; other host I/O failures still require
;;;; recoverable runtime primitives.
;;;;
;;;; Usage: `(import "stdlib/io.tl")`
;;;;
;;;; ```typelisp
;;;; (import "stdlib/io.tl")
;;;; (define fallback : ResultIoString (try-read-file "missing-file-for-docs.txt"))
;;;; ```
;;;;
;;;; ```typelisp
;;;; (import "stdlib/io.tl")
;;;; (define empty-read : StdinRead (stdin-read-bytes 0))
;;;; ```
;;; Structured file I/O failures.
;;;
;;; `IoSystemCode` stores a target-specific positive error code and path.
(defenum IoError
  (IoNotFound String)
  (IoPermissionDenied String)
  (IoInvalidPath String)
  (IoUnsupported String)
  (IoInterrupted String)
  (IoSystemCode i64 String)
  (IoUnknown String))

;;; Result type for string-returning file I/O APIs.
(defenum ResultIoString
  (OkIoString String)
  (ErrIoString IoError))

;;; Result type for unit-returning file I/O APIs.
(defenum ResultIoUnit
  (OkIoUnit)
  (ErrIoUnit IoError))

;;; Result type for bool-returning file I/O APIs.
(defenum ResultIoBool
  (OkIoBool bool)
  (ErrIoBool IoError))

;;; Stdin read result containing the bytes/text read plus the post-read EOF flag.
;;;
;;; `text` is currently a `String` for both line and fixed-byte reads. This will
;;; remain source-compatible but may gain a byte-slice variant after #807 splits
;;; owned text strings from borrowed/binary bytes.
(defstruct StdinRead
  (text String)
  (eof bool))

;;; Return true when `path` is syntactically empty.
(define (io-empty-path? [path : String]) : bool
  (= (string-length path) 0))

;;; Render an I/O error into a human-readable diagnostic string.
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

;;; Return true when `error` is a not-found diagnostic.
(define (io-error-not-found? [error : IoError]) : bool
  (match error
    [(IoNotFound _) true]
    [_ false]))

;;; Return true when `error` is an invalid-path diagnostic.
(define (io-error-invalid-path? [error : IoError]) : bool
  (match error
    [(IoInvalidPath _) true]
    [_ false]))

;;; Return true when `error` is an unsupported-runtime diagnostic.
(define (io-error-unsupported? [error : IoError]) : bool
  (match error
    [(IoUnsupported _) true]
    [_ false]))

;;; Read `path` and return either its contents or a structured I/O error.
;;;
;;; Missing paths return `IoNotFound`. Empty paths return `IoInvalidPath`.
;;; Other host read failures still panic in the underlying runtime primitive
;;; until recoverable file runtime support lands.
(define (try-read-file [path : String]) : ResultIoString
  (if (io-empty-path? path)
    (ErrIoString (IoInvalidPath path))
    (if (file-exists? path)
      (OkIoString (read-file path))
      (ErrIoString (IoNotFound path)))))

;;; Write `contents` to `path`, returning a structured result.
;;;
;;; Empty paths return `IoInvalidPath`. Other host write failures still panic in
;;; the underlying runtime primitive until recoverable file runtime support
;;; lands.
(define (try-write-file [path : String] [contents : String]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (IoInvalidPath path))
    (begin
      (write-file path contents)
      OkIoUnit)))

;;; Probe whether `path` exists, returning a structured result.
;;;
;;; Missing paths are represented as `OkIoBool false`, because absence is an
;;; expected result of an existence probe. Empty paths return `IoInvalidPath`.
(define (try-file-exists? [path : String]) : ResultIoBool
  (if (io-empty-path? path)
    (ErrIoBool (IoInvalidPath path))
    (OkIoBool (file-exists? path))))

;;; Append `contents` to `path`, returning a structured result.
;;;
;;; This helper is non-atomic and rewrites the whole file. It can recover from
;;; missing reads by creating the file, but hard write failures still inherit the
;;; current runtime primitive's panic behavior.
(define (try-append-file [path : String] [contents : String]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (IoInvalidPath path))
    (match (try-read-file path)
      [(OkIoString existing)
        (try-write-file path (string-append existing contents))]
      [(ErrIoString error)
        (if (io-error-not-found? error)
          (try-write-file path contents)
          (ErrIoUnit error))])))

;;; Read the contents of `path` if it exists, otherwise return `fallback`.
;;;
;;; This is a convenience wrapper over `try-read-file`. It returns `fallback`
;;; for every structured error, preserving the historical optional-file API.
(define (read-file-or [path : String] [fallback : String]) : String
  (match (try-read-file path)
    [(OkIoString contents) contents]
    [(ErrIoString _) fallback]))

;;; Append `contents` to the file at `path`, creating it when absent.
;;;
;;; Implemented as a read-modify-write because there is no append primitive, so
;;; it is not atomic and rewrites the whole file.
(define (append-file [path : String] [contents : String]) : unit
  (match (try-append-file path contents)
    [(OkIoUnit) unit]
    [(ErrIoUnit error)
      (begin
        (panic (io-error-message error))
        unit)]))

;;; Return true when `path` exists and its contents are non-empty.
;;;
;;; Structured errors return false. Hard host failures may still panic in the
;;; underlying runtime primitive until recoverable file runtime support lands.
(define (file-nonempty? [path : String]) : bool
  (match (try-read-file path)
    [(OkIoString contents) (> (string-length contents) 0)]
    [(ErrIoString _) false]))

;;; Return the text/bytes captured by a stdin read result.
(define (stdin-read-text [read : StdinRead]) : String
  (struct-get read text))

;;; Return true when a stdin read observed EOF after the read completed.
(define (stdin-read-eof? [read : StdinRead]) : bool
  (struct-get read eof))

;;; Return the current sticky stdin EOF state without performing a read.
(define (stdin-at-eof?) : bool
  (stdin-eof?))

;;; Read one stdin line without the trailing newline and report post-read EOF.
;;;
;;; The returned string is allocated by the runtime in the active arena. Blank
;;; lines return an empty string with `eof` false; end-of-file after the final
;;; unterminated line returns that line with `eof` true.
(define (stdin-read-line) : StdinRead
  (let
    [text : String (read-stdin-line)]
    (StdinRead text (stdin-eof?))))

;;; Read up to `count` bytes from stdin and report post-read EOF.
;;;
;;; The returned bytes are represented as `String` until #807 adds a distinct
;;; byte-string/slice type. The runtime handles invalid counts consistently with
;;; the raw primitive.
(define (stdin-read-bytes [count : i64]) : StdinRead
  (let
    [text : String (read-stdin-bytes count)]
    (StdinRead text (stdin-eof?))))

;;; Write `text` to stdout without adding a newline.
(define (stdout-write [text : String]) : unit
  (print-string text))

;;; Write `text` and a trailing newline to stdout.
;;;
;;; This convenience helper allocates the newline-appended string.
(define (stdout-write-line [text : String]) : unit
  (print-string (string-append text "\n")))

;;; Flush stdout.
(define (stdout-flush) : unit
  (flush-stdout))

;;; Write `text` to stderr without adding a newline.
(define (stderr-write [text : String]) : unit
  (print-error text))

;;; Write `text` and a trailing newline to stderr.
;;;
;;; This convenience helper allocates the newline-appended string.
(define (stderr-write-line [text : String]) : unit
  (print-error (string-append text "\n")))