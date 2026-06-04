;# stdlib/fs.tl - Minimal filesystem helpers for TypeLisp tools (#850).
;#
;# Provides recoverable temporary-directory, path-join, lexical path
;# normalization, safe relative suffix checks, and cleanup helpers on top of
;# compiler/runtime primitives:
;#
;# `fs-mkdir-status`, `fs-remove-file-status`, `fs-remove-dir-status`,
;# `fs-rename-status`, and `fs-process-id`.
;#
;# Usage: `(import "stdlib/fs.tl")`
;#
;# ```typelisp
;# (import "stdlib/fs.tl")
;# (define joined : String (fs-path-join "target" "tool-output.s"))
;# ```
(import "env.tl")

(import "io.tl")

(import "string.tl")

;: Common host status code for attempting to create an already-existing path.
(define fs-status-already-exists : i64
  17)

;: Maximum collision retries for `try-create-temp-dir`.
(define fs-temp-attempt-limit : i64
  100)

(defenum FsPathSegmentList
  (FsPathSegmentNil)
  (FsPathSegmentCons String FsPathSegmentList))

;: Return true on Windows-style hosts.
(define (fs-windows?) : bool
  (string-eq (env-path-list-separator) ";"))

;: Return the preferred path separator for the current host.
(define (fs-path-separator) : String
  (if (fs-windows?)
    "\\"
    "/"))

;: Return the preferred path separator as a character.
(define (fs-path-separator-char) : char
  (if (fs-windows?)
    #\\'
    #/'))

;: Return true when `c` is either Unix or Windows path separator syntax.
(define (fs-path-separator? [c : char]) : bool
  (or (char-eq c #/') (char-eq c #\\')))

;: Return true when `path` starts with either supported separator character.
(define (fs-path-starts-separator? [path : String]) : bool
  (and (> (string-length path) 0) (fs-path-separator? (string-ref path 0))))

;: Return true when `path` ends with either supported separator character.
(define (fs-path-ends-separator? [path : String]) : bool
  (let
    [n : i64 (string-length path)]
    (and (> n 0) (fs-path-separator? (string-ref path (- n 1))))))

;: Return true when `path` starts with a Windows drive designator like `C:`.
;:
;: `C:relative` is drive-qualified but not absolute. `fs-path-safe-relative?`
;: rejects drive-qualified strings because they are not portable root suffixes.
(define (fs-path-drive-qualified? [path : String]) : bool
  (and (> (string-length path) 1) (char-eq (string-ref path 1) #:')))

;: Return true when `path` is rooted or drive-absolute.
;:
;: Both `/` and `\` count as rooted separators. Windows drive-style absolute
;: paths require a separator after the drive designator, such as `C:/tmp` or
;: `C:\tmp`; drive-relative strings like `C:tmp` return false.
(define (fs-path-absolute? [path : String]) : bool
  (let
    [n : i64 (string-length path)]
    (if (= n 0)
      false
      (if (fs-path-separator? (string-ref path 0))
        true
        (and
          (> n 2)
          (and
            (fs-path-drive-qualified? path)
            (fs-path-separator? (string-ref path 2))))))))

(define (fs-path-segment-list-render [segments : FsPathSegmentList]) : String
  (match segments
    [(FsPathSegmentNil) ""]
    [(FsPathSegmentCons head rest)
      (let
        [prefix : String (fs-path-segment-list-render rest)]
        (if (= (string-length prefix) 0)
          head
          (string-append prefix (string-append "/" head))))]))

(define (fs-path-normalize-segment
  [segment : String]
  [segments : FsPathSegmentList]
  [rooted : bool]) : FsPathSegmentList
  (if (or (string-eq segment "") (string-eq segment "."))
    segments
    (if (string-eq segment "..")
      (match segments
        [(FsPathSegmentNil)
          (if rooted
            FsPathSegmentNil
            (FsPathSegmentCons segment segments))]
        [(FsPathSegmentCons top rest)
          (if (string-eq top "..")
            (FsPathSegmentCons segment segments)
            rest)])
      (FsPathSegmentCons segment segments))))

;: Lexically normalize `path` without resolving symlinks or touching the host FS.
;:
;: Both `/` and `\` are accepted as separators. Repeated separators and `.`
;: segments are removed, `..` pops a normal segment, rooted paths stay rooted,
;: and leading `..` segments are preserved for relative paths. Normalized output
;: uses `/` as its stable separator on every host; empty relative paths normalize
;: to `"."`.
(define (fs-path-normalize [path : String]) : String
  (let
    [n : i64 (string-length path)]
    [drive-root : bool
      (and
        (> n 2)
        (and
          (fs-path-drive-qualified? path)
          (fs-path-separator? (string-ref path 2))))]
    [rooted : bool
      (if drive-root
        true
        (and (> n 0) (fs-path-separator? (string-ref path 0))))]
    [i : i64
      (if drive-root
        3
        (if rooted
          1
          0))]
    [segment-start : i64 i]
    [segments : FsPathSegmentList FsPathSegmentNil]
    (begin
      (while (< i n)
        (begin
          (if (fs-path-separator? (string-ref path i))
            (begin
              (set!
                segments
                (fs-path-normalize-segment
                  (substring path segment-start (- i segment-start))
                  segments
                  rooted))
              (set! segment-start (+ i 1)))
            (set! segment-start segment-start))
          (set! i (+ i 1))))
      (set!
        segments
        (fs-path-normalize-segment
          (substring path segment-start (- n segment-start))
          segments
          rooted))
      (let
        [body : String (fs-path-segment-list-render segments)]
        (cond
          [(and drive-root (= (string-length body) 0))
            (string-append (substring path 0 2) "/")]
          [drive-root
            (string-append (substring path 0 2) (string-append "/" body))]
          [(and rooted (= (string-length body) 0)) "/"]
          [rooted (string-append "/" body)]
          [(= (string-length body) 0) "."]
          [else body])))))

(define (fs-path-normalized-escapes? [path : String]) : bool
  (let
    [n : i64 (string-length path)]
    (if (string-eq path "..")
      true
      (and
        (> n 2)
        (and
          (char-eq (string-ref path 0) #.')
          (and
            (char-eq (string-ref path 1) #.')
            (fs-path-separator? (string-ref path 2))))))))

;: Return true when `path` is a non-empty relative suffix that stays below root.
;:
;: This is a lexical guard to use before joining user-controlled suffixes under
;: a trusted root. It rejects empty/`.` paths, absolute or drive-qualified paths,
;: and normalized paths whose first segment is `..`. It does not canonicalize
;: symlinks or query the filesystem.
(define (fs-path-safe-relative? [path : String]) : bool
  (if (or (fs-path-absolute? path) (fs-path-drive-qualified? path))
    false
    (let
      [normalized : String (fs-path-normalize path)]
      (and
        (not (string-eq normalized "."))
        (not (fs-path-normalized-escapes? normalized))))))

;: Join `left` and `right` with exactly one host path separator when needed.
;:
;: Empty sides are returned without allocating an extra separator.
(define (fs-path-join [left : String] [right : String]) : String
  (cond
    [(= (string-length left) 0) right]
    [(= (string-length right) 0) left]
    [(fs-path-ends-separator? left)
      (if (fs-path-starts-separator? right)
        (string-append left (substring right 1 (- (string-length right) 1)))
        (string-append left right))]
    [(fs-path-starts-separator? right) (string-append left right)]
    [else (string-append (string-append left (fs-path-separator)) right)]))

;: Index of the last path separator in `path`, or `-1` when there is none.
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

;: Directory portion of `path`, without a trailing separator.
;:
;: Returns `"."` when `path` has no separator, and the host separator when the
;: only separator is the leading one (a root child such as `/main.tl`).
(define (fs-dirname [path : String]) : String
  (let
    [last : i64 (fs-last-separator-index path)]
    (if (< last 0)
      "."
      (if (= last 0)
        (fs-path-separator)
        (substring path 0 last)))))

;: Final component of `path` (the part after the last separator).
;:
;: Returns `path` unchanged when there is no separator, and `""` when `path`
;: ends with a separator.
(define (fs-basename [path : String]) : String
  (let
    [n : i64 (string-length path)]
    [last : i64 (fs-last-separator-index path)]
    (if (< last 0)
      path
      (substring path (+ last 1) (- n (+ last 1))))))

;: Extension of `path` without the leading dot (e.g. `"tl"` for `main.tl`).
;:
;: Operates on the basename, so directory dots do not count. Returns `""` when
;: the basename has no dot or is a dotfile (a leading-dot name like
;: `.gitignore`, which has no extension).
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

;: Convert a runtime filesystem status into a structured `ResultIoUnit`.
(define (fs-status-result [path : String] [status : i64]) : ResultIoUnit
  (if (= status io-status-ok)
    OkIoUnit
    (ErrIoUnit (io-error-from-status path status))))

;: Create `path` as a directory, returning a structured status.
;:
;: Linux uses mode `0700`; Windows uses the backend `_mkdir` helper.
(define (try-mkdir [path : String]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (IoInvalidPath path))
    (fs-status-result path (fs-mkdir-status path))))

;: Create `path` as a directory when it is missing.
;:
;: A pre-existing path reported by the host as already-created is accepted.
(define (try-mkdir-if-missing [path : String]) : ResultIoUnit
  (match (try-mkdir path)
    [(OkIoUnit) OkIoUnit]
    [(ErrIoUnit error)
      (match error
        [(IoSystemCode code _)
          (if (= code fs-status-already-exists)
            OkIoUnit
            (ErrIoUnit error))]
        [_ (ErrIoUnit error)])]))

;: Remove a file path, returning a structured status.
(define (try-remove-file [path : String]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (IoInvalidPath path))
    (fs-status-result path (fs-remove-file-status path))))

;: Remove an empty directory path, returning a structured status.
(define (try-remove-dir [path : String]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (IoInvalidPath path))
    (fs-status-result path (fs-remove-dir-status path))))

;: Rename `source` to `destination`, returning a structured status.
;:
;: Host replacement behavior is target-defined: Linux follows `rename(2)`,
;: while Windows currently reports `IoUnsupported`.
(define (try-rename [source : String] [destination : String]) : ResultIoUnit
  (if (io-empty-path? source)
    (ErrIoUnit (IoInvalidPath source))
    (if (io-empty-path? destination)
      (ErrIoUnit (IoInvalidPath destination))
      (fs-status-result
        (string-append (string-append source " -> ") destination)
        (fs-rename-status source destination)))))

;: Remove a file if present. Missing paths are considered already cleaned.
(define (try-remove-file-if-exists [path : String]) : ResultIoUnit
  (match (try-remove-file path)
    [(OkIoUnit) OkIoUnit]
    [(ErrIoUnit error)
      (if (io-error-not-found? error)
        OkIoUnit
        (ErrIoUnit error))]))

;: Remove an empty directory if present. Missing paths are considered cleaned.
(define (try-remove-dir-if-exists [path : String]) : ResultIoUnit
  (match (try-remove-dir path)
    [(OkIoUnit) OkIoUnit]
    [(ErrIoUnit error)
      (if (io-error-not-found? error)
        OkIoUnit
        (ErrIoUnit error))]))

;: Return the host temporary root used by `try-create-temp-dir`.
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

;: Compose one candidate temporary directory basename from prefix, pid, and attempt.
(define (fs-temp-name [prefix : String] [pid : i64] [attempt : i64]) : String
  (string-append
    (string-append prefix "-")
    (string-append (int->string pid) (string-append "-" (int->string attempt)))))

;: Retry temporary directory creation until an unused candidate is found.
(define (fs-create-temp-dir-loop
  [root : String]
  [prefix : String]
  [pid : i64]
  [attempt : i64]) : ResultIoString
  (if (>= attempt fs-temp-attempt-limit)
    (ErrIoString (IoSystemCode fs-status-already-exists prefix))
    (let
      [candidate : String (fs-path-join root (fs-temp-name prefix pid attempt))]
      [status : i64 (fs-mkdir-status candidate)]
      (if (= status io-status-ok)
        (OkIoString candidate)
        (if (= status fs-status-already-exists)
          (fs-create-temp-dir-loop root prefix pid (+ attempt 1))
          (ErrIoString (io-error-from-status candidate status)))))))

;: Create a unique temporary directory for tool artifacts.
;:
;: The directory is created below `$TMPDIR` on Linux (or `/tmp` when `TMPDIR` is
;: missing), and below `%TEMP%`/`%TMP%` (or `.`) on Windows. The unique name is
;: seeded by the process id (`GetCurrentProcessId` on Windows, `getpid` on
;: Linux) and an attempt counter, retrying on collision.
(define (try-create-temp-dir [prefix : String]) : ResultIoString
  (if (io-empty-path? prefix)
    (ErrIoString (IoInvalidPath prefix))
    (fs-create-temp-dir-loop (fs-temp-root) prefix (fs-process-id) 0)))