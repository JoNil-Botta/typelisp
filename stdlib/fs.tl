;;;; stdlib/fs.tl - Minimal filesystem helpers for TypeLisp tools (#850).
;;;;
;;;; Provides recoverable temporary-directory, path-join, and cleanup helpers on
;;;; top of compiler/runtime primitives:
;;;;
;;;; `fs-mkdir-status`, `fs-remove-file-status`, `fs-remove-dir-status`, and
;;;; `fs-process-id`.
;;;;
;;;; Usage: `(import "stdlib/fs.tl")`
;;;;
;;;; ```typelisp
;;;; (import "stdlib/fs.tl")
;;;; (define joined : String (fs-path-join "target" "tool-output.s"))
;;;; ```
(import "env.tl")

(import "io.tl")

(import "string.tl")

;;; Common host status code for attempting to create an already-existing path.
(define fs-status-already-exists : i64
  17)

;;; Maximum collision retries for `try-create-temp-dir`.
(define fs-temp-attempt-limit : i64
  100)

;;; Return true on Windows-style hosts.
(define (fs-windows?) : bool
  (string-eq (env-path-list-separator) ";"))

;;; Return the preferred path separator for the current host.
(define (fs-path-separator) : String
  (if (fs-windows?)
    "\\"
    "/"))

;;; Return the preferred path separator as a character.
(define (fs-path-separator-char) : char
  (if (fs-windows?)
    #\\'
    #/'))

;;; Return true when `c` is either Unix or Windows path separator syntax.
(define (fs-path-separator? [c : char]) : bool
  (or (char-eq c #/') (char-eq c #\\')))

;;; Return true when `path` starts with either supported separator character.
(define (fs-path-starts-separator? [path : String]) : bool
  (and (> (string-length path) 0) (fs-path-separator? (string-ref path 0))))

;;; Return true when `path` ends with either supported separator character.
(define (fs-path-ends-separator? [path : String]) : bool
  (let
    [n : i64 (string-length path)]
    (and (> n 0) (fs-path-separator? (string-ref path (- n 1))))))

;;; Join `left` and `right` with exactly one host path separator when needed.
;;;
;;; Empty sides are returned without allocating an extra separator.
(define (fs-path-join [left : String] [right : String]) : String
  (if (= (string-length left) 0)
    right
    (if (= (string-length right) 0)
      left
      (if (fs-path-ends-separator? left)
        (if (fs-path-starts-separator? right)
          (string-append left (substring right 1 (- (string-length right) 1)))
          (string-append left right))
        (if (fs-path-starts-separator? right)
          (string-append left right)
          (string-append (string-append left (fs-path-separator)) right))))))

;;; Index of the last path separator in `path`, or `-1` when there is none.
(define (fs-last-separator-index [path : String]) : i64
  (let
    [n : i64 (string-length path)]
    [i : i64 0]
    [last : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (fs-path-separator? (string-ref path i))
            (set! last i)
            (set! last last))
          (set! i (+ i 1))))
      last)))

;;; Directory portion of `path`, without a trailing separator.
;;;
;;; Returns `"."` when `path` has no separator, and the host separator when the
;;; only separator is the leading one (a root child such as `/main.tl`).
(define (fs-dirname [path : String]) : String
  (let
    [last : i64 (fs-last-separator-index path)]
    (if (< last 0)
      "."
      (if (= last 0)
        (fs-path-separator)
        (substring path 0 last)))))

;;; Final component of `path` (the part after the last separator).
;;;
;;; Returns `path` unchanged when there is no separator, and `""` when `path`
;;; ends with a separator.
(define (fs-basename [path : String]) : String
  (let
    [n : i64 (string-length path)]
    [last : i64 (fs-last-separator-index path)]
    (if (< last 0)
      path
      (substring path (+ last 1) (- n (+ last 1))))))

;;; Extension of `path` without the leading dot (e.g. `"tl"` for `main.tl`).
;;;
;;; Operates on the basename, so directory dots do not count. Returns `""` when
;;; the basename has no dot or is a dotfile (a leading-dot name like
;;; `.gitignore`, which has no extension).
(define (fs-extension [path : String]) : String
  (let
    [base : String (fs-basename path)]
    [bn : i64 (string-length base)]
    [i : i64 0]
    [dot : i64 -1]
    (begin
      (while (< i bn)
        (begin
          (if (char-eq (string-ref base i) #.')
            (set! dot i)
            (set! dot dot))
          (set! i (+ i 1))))
      (if (<= dot 0)
        ""
        (substring base (+ dot 1) (- bn (+ dot 1)))))))

;;; Convert a runtime filesystem status into a structured `ResultIoUnit`.
(define (fs-status-result [path : String] [status : i64]) : ResultIoUnit
  (if (= status io-status-ok)
    OkIoUnit
    (ErrIoUnit (io-error-from-status path status))))

;;; Create `path` as a directory, returning a structured status.
;;;
;;; Linux uses mode `0700`; Windows uses the backend `_mkdir` helper.
(define (try-mkdir [path : String]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (IoInvalidPath path))
    (fs-status-result path (fs-mkdir-status path))))

;;; Remove a file path, returning a structured status.
(define (try-remove-file [path : String]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (IoInvalidPath path))
    (fs-status-result path (fs-remove-file-status path))))

;;; Remove an empty directory path, returning a structured status.
(define (try-remove-dir [path : String]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (IoInvalidPath path))
    (fs-status-result path (fs-remove-dir-status path))))

;;; Remove a file if present. Missing paths are considered already cleaned.
(define (try-remove-file-if-exists [path : String]) : ResultIoUnit
  (match (try-remove-file path)
    [(OkIoUnit) OkIoUnit]
    [(ErrIoUnit error)
      (if (io-error-not-found? error)
        OkIoUnit
        (ErrIoUnit error))]))

;;; Remove an empty directory if present. Missing paths are considered cleaned.
(define (try-remove-dir-if-exists [path : String]) : ResultIoUnit
  (match (try-remove-dir path)
    [(OkIoUnit) OkIoUnit]
    [(ErrIoUnit error)
      (if (io-error-not-found? error)
        OkIoUnit
        (ErrIoUnit error))]))

;;; Return the host temporary root used by `try-create-temp-dir`.
(define (fs-temp-root) : String
  (if (fs-windows?)
    (match (env-get "TEMP")
      [(EnvSomeString value) value]
      [(EnvNoString)
        (match (env-get "TMP")
          [(EnvSomeString value) value]
          [(EnvNoString) "."])])
    (match (env-get "TMPDIR")
      [(EnvSomeString value) value]
      [(EnvNoString) "/tmp"])))

;;; Compose one candidate temporary directory basename from prefix, pid, and attempt.
(define (fs-temp-name [prefix : String] [pid : i64] [attempt : i64]) : String
  (string-append
    (string-append prefix "-")
    (string-append (int->string pid) (string-append "-" (int->string attempt)))))

;;; Retry temporary directory creation until an unused candidate is found.
(define (fs-create-temp-dir-loop
  [root : String]
  [prefix : String]
  [pid : i64]
  [attempt : i64]) : ResultIoString
  (if (>= attempt fs-temp-attempt-limit)
    (ErrIoString (IoSystemCode fs-status-already-exists prefix))
    (let
      [candidate : String (fs-path-join root (fs-temp-name prefix pid attempt))]
      (let
        [status : i64 (fs-mkdir-status candidate)]
        (if (= status io-status-ok)
          (OkIoString candidate)
          (if (= status fs-status-already-exists)
            (fs-create-temp-dir-loop root prefix pid (+ attempt 1))
            (ErrIoString (io-error-from-status candidate status))))))))

;;; Create a unique temporary directory for tool artifacts.
;;;
;;; The directory is created below `$TMPDIR` on Linux (or `/tmp` when `TMPDIR` is
;;; missing), and below `%TEMP%`/`%TMP%` (or `.`) on Windows. The unique name is
;;; seeded by the process id (`GetCurrentProcessId` on Windows, `getpid` on
;;; Linux) and an attempt counter, retrying on collision.
(define (try-create-temp-dir [prefix : String]) : ResultIoString
  (if (io-empty-path? prefix)
    (ErrIoString (IoInvalidPath prefix))
    (fs-create-temp-dir-loop (fs-temp-root) prefix (fs-process-id) 0)))