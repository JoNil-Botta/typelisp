;# File I/O utility library for TypeLisp (#702).
;#
;# Provides file, argv, panic, and stdio helpers through direct extern bindings
;# to platform FFI symbols plus low-level language forms for argv and raw bytes.
;#
;# Public platform-facing functions such as `print-string`, `panic`, `arg`,
;# `read-file`, `write-file`, file-handle status helpers, and stdin/stdout
;# helpers are stdlib definitions in this module. Programs must import this module
;# to use them.
;#
;# The `try-*` helpers return explicit monomorphic result enums. Host errors
;# are reported through status-code primitives and mapped into `IoError`.
;#
;# Usage: `(import "stdlib/io.tl")`
;#
;# ```typelisp
;# (import "stdlib/io.tl")
;# (define fallback : ResultIoString
;#   (let [path : String "missing-file-for-docs.txt"] (try-read-file (& path))))
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
;#     (let [text : String "hello from io\n"] (stdout-write (& text)))
;#     0))
;# ```
(extern io-linux-open (:symbol "open") : (-> (Ptr u8) i32 i32 i32))
(extern io-linux-read (:symbol "read") : (-> i32 (MutPtr u8) i64 i64))
(extern io-linux-write (:symbol "write") : (-> i32 (Ptr u8) i64 i64))
(extern io-linux-close (:symbol "close") : (-> i32 i32))
(extern io-linux-lseek (:symbol "lseek") : (-> i32 i64 i32 i64))
(extern io-linux-access (:symbol "access") : (-> (Ptr u8) i32 i32))
(extern io-linux-errno-location (:symbol "__errno_location") : (-> (MutPtr i32)))

(extern io-windows-open (:symbol "_open") : (-> (Ptr u8) i32 i32 i32))
(extern io-windows-read (:symbol "_read") : (-> i32 (MutPtr u8) i32 i32))
(extern io-windows-write (:symbol "_write") : (-> i32 (Ptr u8) i32 i32))
(extern io-windows-close (:symbol "_close") : (-> i32 i32))
(extern io-windows-lseek (:symbol "_lseeki64") : (-> i32 i64 i32 i64))
(extern io-windows-access (:symbol "_access") : (-> (Ptr u8) i32 i32))
(extern io-windows-errno-location (:symbol "_errno") : (-> (MutPtr i32)))

(extern io-ffi-fflush (:symbol "fflush") : (-> (Ptr u8) i32))
(extern io-ffi-exit (:symbol "exit") : (-> i32 never))

(define io-file-handle-cap : i64
  1024)

(define io-file-handle-next : i64
  1)

(define io-file-fds : (Array i64)
  (make-array i64 1024))

(define io-file-modes : (Array i64)
  (make-array i64 1024))

(define io-file-states : (Array i64)
  (make-array i64 1024))

(define io-file-eofs : (Array bool)
  (make-array bool 1024))

(define io-file-last-ready : (Array bool)
  (make-array bool 1024))

(define io-file-last-bytes : (Array String)
  (make-array String 1024))

(define io-stdin-eof-state : bool
  false)

(define (io-c-string [text : String]) : (Array u8)
  (let
    [n : i64 (string-length text)]
    [buf : (Array u8) (make-array u8 (+ n 1))]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! buf i (cast (string-ref text i) : u8))
          (set! i (+ i 1))))
      (array-set! buf n (cast #\nul' : u8))
      buf)))

(define (io-array-ptr [buf : (Array u8)]) : (MutPtr u8)
  (unsafe (array-data buf)))

(define (io-array-const-ptr [buf : (Array u8)]) : (Ptr u8)
  (unsafe (ptr-cast (array-data buf) : (Ptr u8))))

(define (io-string-data [text : String]) : (Ptr u8)
  (unsafe (string-data text)))

(define (io-copy-c-string [ptr : (Ptr u8)]) : String
  (let
    [n : i64 (io-c-string-length ptr)]
    [buf : (Array u8) (make-array u8 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! buf i (unsafe (ptr-read (ptr-offset ptr i))))
          (set! i (+ i 1))))
      (unsafe (string-from-bytes (io-array-const-ptr buf) n)))))

(define (io-c-string-length [ptr : (Ptr u8)]) : i64
  (let
    [n : i64 0]
    [done : bool false]
    (begin
      (while (not done)
        (if (= (cast (unsafe (ptr-read (ptr-offset ptr n))) : i64) 0)
          (set! done true)
          (set! n (+ n 1))))
      n)))

(define (io-last-error-code) : i64
  (cast
    (unsafe
      (ptr-read
        (cfg windows (io-windows-errno-location) (io-linux-errno-location))))
    : i64))

(define (io-platform-open [path : (Ptr u8)] [flags : i64] [mode : i64]) : i64
  (cfg windows
    (cast
      (io-windows-open path (cast flags : i32) (cast mode : i32))
      : i64)
    (cast
      (io-linux-open path (cast flags : i32) (cast mode : i32))
      : i64)))

(define (io-platform-read [fd : i64] [buf : (MutPtr u8)] [count : i64]) : i64
  (cfg windows
    (cast (io-windows-read (cast fd : i32) buf (cast count : i32)) : i64)
    (io-linux-read (cast fd : i32) buf count)))

(define (io-platform-write [fd : i64] [buf : (Ptr u8)] [count : i64]) : i64
  (cfg windows
    (cast (io-windows-write (cast fd : i32) buf (cast count : i32)) : i64)
    (io-linux-write (cast fd : i32) buf count)))

(define (io-platform-close [fd : i64]) : i64
  (cfg windows
    (cast (io-windows-close (cast fd : i32)) : i64)
    (cast (io-linux-close (cast fd : i32)) : i64)))

(define (io-platform-lseek [fd : i64] [offset : i64] [whence : i64]) : i64
  (cfg windows
    (io-windows-lseek (cast fd : i32) offset (cast whence : i32))
    (io-linux-lseek (cast fd : i32) offset (cast whence : i32))))

(define (io-platform-access [path : (Ptr u8)] [mode : i64]) : i64
  (cfg windows
    (cast (io-windows-access path (cast mode : i32)) : i64)
    (cast (io-linux-access path (cast mode : i32)) : i64)))

(define (io-open-read-flags) : i64
  (cfg windows 32768 0))

(define (io-open-write-truncate-flags) : i64
  (cfg windows 33537 577))

(define (io-open-write-append-flags) : i64
  (cfg windows 33033 1089))

(define (io-open-mode) : i64
  384)

(define (io-open-flags-for-mode [mode : i64]) : i64
  (cond
    [(= mode 0) (io-open-read-flags)]
    [(= mode 1) (io-open-write-truncate-flags)]
    [else (io-open-write-append-flags)]))

(define (io-neg-status [code : i64]) : i64
  (- 0 code))

(define (io-write-all-fd-status [fd : i64] [data : (Ptr u8)] [len : i64]) : i64
  (let
    [offset : i64 0]
    [status : i64 0]
    (begin
      (while (and (= status 0) (< offset len))
        (let
          [written : i64
            (io-platform-write
              fd
              (unsafe (ptr-offset data offset))
              (- len offset))]
          (if (< written 0)
            (set! status (io-last-error-code))
            (if (= written 0)
              (set! status 5)
              (set! offset (+ offset written))))))
      status)))

(define (io-write-string-fd-status [fd : i64] [text : String]) : i64
  (io-write-all-fd-status fd (io-string-data text) (string-length text)))

;: Write a string to stdout without adding a newline.
(define (print-string [text : String]) : unit
  (let
    [status : i64 (io-write-string-fd-status 1 text)]
    (if (= status 0)
      unit
      (io-ffi-exit 134))))

;: Compatibility alias for `print-string`.
(define (print-str [text : String]) : unit
  (print-string text))

;: Write a string to stderr without adding a newline.
(define (print-error [text : String]) : unit
  (let
    [status : i64 (io-write-string-fd-status 2 text)]
    (if (= status 0)
      unit
      (io-ffi-exit 134))))

;: Abort the process after writing `message` to stderr.
(define (panic [message : String]) : never
  (begin
    (print-error message)
    (io-ffi-exit 134)))

;: Alias for `panic`.
(define (error [message : String]) : never
  (panic message))

;: Return the number of process argv entries.
(define (arg-count) : i64
  (program-argc))

;: Return argv entry `index`, aborting on out-of-range indices.
(define (arg [index : i64]) : String
  (if (< index 0)
    (panic "tl: argv index out of bounds\n")
    (if (>= index (arg-count))
      (panic "tl: argv index out of bounds\n")
      (let
        [argv : (Ptr (Ptr u8)) (unsafe (program-argv))]
        [raw : (Ptr u8) (unsafe (ptr-read (ptr-offset argv index)))]
        (io-copy-c-string raw)))))

(define (io-read-fd-to-string [fd : i64]) : String
  (let
    [end : i64 (io-platform-lseek fd 0 2)]
    (if (< end 0)
      (panic "tl: read-file failed\n")
      (begin
        (if (< (io-platform-lseek fd 0 0) 0)
          (panic "tl: read-file failed\n")
          unit)
        (let
          [buf : (Array u8) (make-array u8 end)]
          [offset : i64 0]
          [done : bool false]
          (begin
            (while (and (not done) (< offset end))
              (let
                [read-count : i64
                  (io-platform-read
                    fd
                    (unsafe (ptr-offset (io-array-ptr buf) offset))
                    (- end offset))]
                (if (< read-count 0)
                  (panic "tl: read-file failed\n")
                  (if (= read-count 0)
                    (set! done true)
                    (set! offset (+ offset read-count))))))
            (unsafe (string-from-bytes (io-array-const-ptr buf) offset)))))))

;: Return the host status code for reading `path`.
(define (read-file-status [path : String]) : i64
  (let
    [path-bytes : (Array u8) (io-c-string path)]
    [fd : i64 (io-platform-open (io-array-const-ptr path-bytes) (io-open-read-flags) 0)]
    (if (< fd 0)
      (io-last-error-code)
      (let
        [probe : (Array u8) (make-array u8 1)]
        [read-count : i64 (io-platform-read fd (io-array-ptr probe) 1)]
        [status : i64
          (if (< read-count 0)
            (io-last-error-code)
            0)]
        (begin
          (io-platform-close fd)
          status)))))

;: Read a whole file, aborting on host read failure.
(define (read-file [path : String]) : String
  (let
    [path-bytes : (Array u8) (io-c-string path)]
    [fd : i64 (io-platform-open (io-array-const-ptr path-bytes) (io-open-read-flags) 0)]
    (if (< fd 0)
      (panic "tl: read-file failed\n")
      (let
        [contents : String (io-read-fd-to-string fd)]
        (begin
          (io-platform-close fd)
          contents)))))

(define (io-write-path-status [path : String] [contents : String] [flags : i64]) : i64
  (let
    [path-bytes : (Array u8) (io-c-string path)]
    [fd : i64 (io-platform-open (io-array-const-ptr path-bytes) flags (io-open-mode))]
    (if (< fd 0)
      (io-last-error-code)
      (let
        [status : i64
          (io-write-string-fd-status fd contents)]
        [close-status : i64 (io-platform-close fd)]
        (if (= status 0)
          (if (< close-status 0)
            (io-last-error-code)
            0)
          status)))))

;: Return the host status code for writing `contents` to `path`.
(define (write-file-status [path : String] [contents : String]) : i64
  (io-write-path-status path contents (io-open-write-truncate-flags)))

;: Write a whole file, aborting on host write failure.
(define (write-file [path : String] [contents : String]) : unit
  (let
    [status : i64 (write-file-status path contents)]
    (if (= status 0)
      unit
      (panic "tl: write-file failed\n"))))

;: Return the host status code for appending `contents` to `path`.
(define (append-file-status [path : String] [contents : String]) : i64
  (io-write-path-status path contents (io-open-write-append-flags)))

;: Return the host status code for probing `path`.
(define (file-exists-status [path : String]) : i64
  (let
    [path-bytes : (Array u8) (io-c-string path)]
    [status : i64 (io-platform-access (io-array-const-ptr path-bytes) 0)]
    (if (= status 0)
      0
      (io-last-error-code))))

;: Return true when `path` exists, aborting on hard host probe failure.
(define (file-exists? [path : String]) : bool
  (let
    [status : i64 (file-exists-status path)]
    (if (= status 0)
      true
      (if (or (= status 2) (= status 20))
        false
        (begin
          (panic "tl: file-exists? failed\n")
          false)))))

(define (io-valid-handle? [raw : i64]) : bool
  (and
    (> raw 0)
    (and (< raw io-file-handle-cap) (= (array-ref io-file-states raw) 1))))

;: Return a stdlib file handle id or negative status for opening `path`.
(define (file-open-status [path : String] [mode : i64]) : i64
  (let
    [path-bytes : (Array u8) (io-c-string path)]
    [fd : i64
      (io-platform-open
        (io-array-const-ptr path-bytes)
        (io-open-flags-for-mode mode)
        (io-open-mode))]
    (if (< fd 0)
      (io-neg-status (io-last-error-code))
      (if (>= io-file-handle-next io-file-handle-cap)
        (begin
          (io-platform-close fd)
          (io-neg-status 38))
        (let
          [handle : i64 io-file-handle-next]
          (begin
            (set! io-file-handle-next (+ io-file-handle-next 1))
            (array-set! io-file-fds handle fd)
            (array-set! io-file-modes handle mode)
            (array-set! io-file-states handle 1)
            (array-set! io-file-eofs handle false)
            (array-set! io-file-last-ready handle false)
            handle))))))

;: Return the host status code for closing a stdlib file handle id.
(define (file-close-status [raw : i64]) : i64
  (if (io-valid-handle? raw)
    (let
      [fd : i64 (array-ref io-file-fds raw)]
      [status : i64 (io-platform-close fd)]
      (begin
        (array-set! io-file-states raw 0)
        (if (< status 0)
          (io-last-error-code)
          0)))
    38))

;: Return the host status code for reading a chunk into the stdlib handle cache.
(define (file-read-chunk-status [raw : i64] [count : i64]) : i64
  (if (not (io-valid-handle? raw))
    38
    (if (not (= (array-ref io-file-modes raw) 0))
      38
      (if (< count 0)
        22
        (if (= count 0)
          (begin
            (array-set! io-file-last-bytes raw "")
            (array-set! io-file-last-ready raw true)
            0)
          (let
            [buf : (Array u8) (make-array u8 count)]
            [fd : i64 (array-ref io-file-fds raw)]
            [read-count : i64 (io-platform-read fd (io-array-ptr buf) count)]
            (if (< read-count 0)
              (io-last-error-code)
              (begin
                (if (= read-count 0)
                  (array-set! io-file-eofs raw true)
                  (array-set! io-file-eofs raw false))
                (array-set!
                  io-file-last-bytes
                  raw
                  (unsafe (string-from-bytes (io-array-const-ptr buf) read-count)))
                (array-set! io-file-last-ready raw true)
                0))))))))

;: Return the host status code for writing `contents` through a stdlib handle.
(define (file-write-status [raw : i64] [contents : String]) : i64
  (if (not (io-valid-handle? raw))
    38
    (if (= (array-ref io-file-modes raw) 0)
      38
      (io-write-string-fd-status (array-ref io-file-fds raw) contents))))

;: Return the host status code for flushing a stdlib handle.
(define (file-flush-status [raw : i64]) : i64
  (if (not (io-valid-handle? raw))
    38
    (if (= (array-ref io-file-modes raw) 0)
      38
      0)))

;: Return bytes from the last successful stdlib file chunk read.
(define (file-read-chunk-bytes [raw : i64]) : String
  (if (and (io-valid-handle? raw) (array-ref io-file-last-ready raw))
    (array-ref io-file-last-bytes raw)
    ""))

;: Return the sticky EOF bit from the last successful stdlib file chunk read.
(define (file-read-chunk-eof? [raw : i64]) : bool
  (if (io-valid-handle? raw)
    (array-ref io-file-eofs raw)
    true))

;: Read up to `count` bytes from stdin.
(define (read-stdin-bytes [count : i64]) : String
  (if (< count 0)
    (panic "tl: stdin failed\n")
    (if (= count 0)
      ""
      (let
        [buf : (Array u8) (make-array u8 count)]
        [read-count : i64 (io-platform-read 0 (io-array-ptr buf) count)]
        (if (< read-count 0)
          (panic "tl: stdin failed\n")
          (begin
            (if (< read-count count)
              (set! io-stdin-eof-state true)
              (set! io-stdin-eof-state false))
            (unsafe (string-from-bytes (io-array-const-ptr buf) read-count))))))))

;: Read one stdin line without the trailing newline.
(define (read-stdin-line) : String
  (let
    [bytes : (Array u8) (make-array u8 0)]
    [one : (Array u8) (make-array u8 1)]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [read-count : i64 (io-platform-read 0 (io-array-ptr one) 1)]
          (if (< read-count 0)
            (panic "tl: stdin failed\n")
            (if (= read-count 0)
              (begin
                (set! io-stdin-eof-state true)
                (set! done true))
              (let
                [byte : u8 (array-ref one 0)]
                (if (= (cast byte : i64) 10)
                  (set! done true)
                  (begin
                    (array-push! bytes byte)
                    (set! done false))))))))
      (unsafe
        (string-from-bytes
          (io-array-const-ptr bytes)
          (array-length bytes))))))

;: Return the sticky stdin EOF state.
(define (stdin-eof?) : bool
  io-stdin-eof-state)

;: Flush stdout.
(define (flush-stdout) : unit
  (let
    [status : i32 (io-ffi-fflush (ptr-null : (Ptr u8)))]
    (if (= status (cast 0 : i32))
      unit
      (panic "tl: flush-stdout failed\n"))))

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

;: Opaque stdlib-managed file handle id.
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

;: Portable errno-style status code used by stdlib host helpers for success.
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

;: Copy a borrowed string slice into an owned active-arena `String`.
;:
;: Result payloads store owned strings, so helpers that receive borrowed paths
;: copy before constructing public diagnostics.
(define (io-copy-path [path : (& path str)]) : String
  (let
    [empty : String ""]
    (string-append path (& empty))))

;: Return true when `path` is syntactically empty.
(define (io-empty-path? [path : (& path str)]) : bool
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

;: Construct an invalid-path diagnostic from a borrowed path.
(define (io-invalid-path-error [path : (& path str)]) : IoError
  (IoInvalidPath (io-copy-path path)))

;: Convert a runtime status code into the public structured error model.
(define (io-error-from-status [path : (& path str)] [code : i64]) : IoError
  (let
    [owned-path : String (io-copy-path path)]
    (cond
      [(io-status-expected-absence? code) (IoNotFound owned-path)]
      [(= code io-status-permission-denied) (IoPermissionDenied owned-path)]
      [(= code io-status-invalid) (IoInvalidPath owned-path)]
      [(= code io-status-name-too-long) (IoInvalidPath owned-path)]
      [(= code io-status-interrupted) (IoInterrupted owned-path)]
      [(= code io-status-is-directory) (IoUnsupported owned-path)]
      [(= code io-status-unsupported) (IoUnsupported owned-path)]
      [(= code io-status-ok) (IoUnknown owned-path)]
      [else (IoSystemCode code owned-path)])))

;: Convert a status code for a fixed diagnostic label.
(define (io-error-from-label [label : String] [code : i64]) : IoError
  (let
    [path : String label]
    (io-error-from-status (& path) code)))

;: Convert an open mode into the stdlib helper's compact mode code.
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

;: Open `path` in `mode`, returning a stdlib-managed file handle.
;:
;: The returned handle must be passed to `file-close`. Empty paths return
;: `IoInvalidPath`; unsupported targets and mode/host failures are reported as
;: structured `IoError` values.
(define (file-open [path : (& path str)] [mode : OpenMode]) : ResultIoFile
  (if (io-empty-path? path)
    (ErrIoFile (io-invalid-path-error path))
    (let
      [raw : i64 (file-open-status path (open-mode-code mode))]
      (if (< raw 0)
        (ErrIoFile (io-error-from-status path (- 0 raw)))
        (OkIoFile (FileHandle raw))))))

;: Close a stdlib-managed file handle.
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
        (ErrIoUnit (io-error-from-label "file-close" status))))))

;: Return the bytes captured by a streaming file read.
(define (file-read-bytes [read : FileRead]) : String
  (struct-get read bytes))

;: Return true when a streaming file read observed EOF after the read.
(define (file-read-eof? [read : FileRead]) : bool
  (struct-get read eof))

;: Read up to `count` bytes from a stdlib-managed read-mode file handle.
;:
;: The returned bytes are represented as `String` until #807 adds a distinct
;: byte-string/slice type. A short read does not imply EOF; EOF becomes true
;: only after the stdlib receives a zero-byte host read.
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
          (ErrIoRead (io-error-from-label "file-read-chunk" status)))))))

;: Write `contents` to a stdlib-managed write-mode file handle.
;:
;: The stdlib retries short host writes until all bytes are accepted or a
;: host error is returned. Closed, invalid, read-only, and unsupported handles
;: return `IoUnsupported`.
(define (file-write [handle : FileHandle] [contents : (& contents str)]) : ResultIoUnit
  (let
    [status : i64 (file-write-status (struct-get handle id) contents)]
    (if (= status io-status-ok)
      OkIoUnit
      (if (= status io-status-unsupported)
        (ErrIoUnit (IoUnsupported (file-write-unsupported-message)))
        (ErrIoUnit (io-error-from-label "file-write" status))))))

;: Flush a stdlib-managed write-mode file handle.
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
        (ErrIoUnit (io-error-from-label "file-flush" status))))))

;: Read `path` and return either its contents or a structured I/O error.
;:
;: Missing paths return `IoNotFound`. Empty paths return `IoInvalidPath`.
(define (try-read-file [path : (& path str)]) : ResultIoString
  (if (io-empty-path? path)
    (ErrIoString (io-invalid-path-error path))
    (let
      [status : i64 (read-file-status path)]
      (if (= status io-status-ok)
        (OkIoString (read-file path))
        (ErrIoString (io-error-from-status path status))))))

;: Write `contents` to `path`, returning a structured result.
;:
;: Empty paths return `IoInvalidPath`.
(define (try-write-file [path : (& path str)] [contents : (& contents str)]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (io-invalid-path-error path))
    (let
      [status : i64 (write-file-status path contents)]
      (if (= status io-status-ok)
        OkIoUnit
        (ErrIoUnit (io-error-from-status path status))))))

;: Probe whether `path` exists, returning a structured result.
;:
;: Missing paths are represented as `OkIoBool false`, because absence is an
;: expected result of an existence probe. Empty paths return `IoInvalidPath`.
(define (try-file-exists? [path : (& path str)]) : ResultIoBool
  (if (io-empty-path? path)
    (ErrIoBool (io-invalid-path-error path))
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
(define (try-append-file [path : (& path str)] [contents : (& contents str)]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (io-invalid-path-error path))
    (let
      [status : i64 (append-file-status path contents)]
      (if (= status io-status-ok)
        OkIoUnit
        (ErrIoUnit (io-error-from-status path status))))))

;: Read the contents of `path` if it exists, otherwise return `fallback`.
;:
;: This is a convenience wrapper over `try-read-file`. It returns `fallback`
;: for every structured error, preserving the historical optional-file API.
(define (read-file-or [path : (& path str)] [fallback : String]) : String
  (match (try-read-file path)
    [(OkIoString contents) contents]
    [(ErrIoString _) fallback]))

;: Append `contents` to the file at `path`, creating it when absent.
;:
;: Uses the platform append status path: non-truncating, create-if-missing,
;: and best-effort host append semantics.
(define (append-file [path : (& path str)] [contents : (& contents str)]) : unit
  (match (try-append-file path contents)
    [(OkIoUnit) unit]
    [(ErrIoUnit error)
      (begin
        (panic (io-error-message error))
        unit)]))

;: Return true when `path` exists and its contents are non-empty.
;:
;: Structured errors return false.
(define (file-nonempty? [path : (& path str)]) : bool
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
;: byte-string/slice type.
(define (stdin-read-bytes [count : i64]) : StdinRead
  (let
    [text : String (read-stdin-bytes count)]
    (StdinRead text (stdin-eof?))))

;: Write `text` to stdout without adding a newline.
(define (stdout-write [text : (& text str)]) : unit
  (print-string text))

;: Write `text` and a trailing newline to stdout.
;:
;: This convenience helper allocates the newline-appended string.
(define (stdout-write-line [text : (& text str)]) : unit
  (let
    [newline : String "\n"]
    (print-string (string-append text (& newline)))))

;: Flush stdout.
(define (stdout-flush) : unit
  (flush-stdout))

;: Write `text` to stderr without adding a newline.
(define (stderr-write [text : (& text str)]) : unit
  (print-error text))

;: Write `text` and a trailing newline to stderr.
;:
;: This convenience helper allocates the newline-appended string.
(define (stderr-write-line [text : (& text str)]) : unit
  (let
    [newline : String "\n"]
    (print-error (string-append text (& newline)))))
