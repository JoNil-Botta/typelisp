;# stdlib/fs.tl - Minimal filesystem helpers for TypeLisp tools (#850).
;#
;# Provides recoverable current-directory and temporary-directory APIs, path-join,
;# lexical path normalization, safe relative suffix checks, and cleanup helpers on
;# top of compiler/runtime primitives:
;#
;# `fs-mkdir-status`, `fs-remove-file-status`, `fs-remove-dir-status`,
;# `fs-rename-status`, `fs-read-dir-status`, `fs-read-dir`,
;# `fs-file-kind-status`, `fs-process-id`, `tl_fs_current_dir_status`, and
;# `tl_fs_current_dir`.
;#
;# Usage: `(import "stdlib/fs.tl")`
;#
;; requires-stage0-symbol: fs-file-kind-status
;# ```typelisp
;# (import "stdlib/fs.tl")
;# (define joined : String
;#   (let
;#     [left : String "target"]
;#     [right : String "tool-output.s"]
;#     (fs-path-join (& left) (& right))))
;# ```
(import "env.tl")

(import "io.tl")

(import "list.tl")

(import "string.tl")

;: Result type for directory-listing APIs.
(defenum ResultIoStringList
  (OkIoStringList StringList)
  (ErrIoStringList IoError))

;: Runtime status probe for retrieving the current working directory.
(extern tl_fs_current_dir_status : (-> i64))

;: Runtime string probe for retrieving the current working directory.
(extern tl_fs_current_dir : (-> String))

;: Common host status code for attempting to create an already-existing path.
(define fs-status-already-exists : i64
  17)

;: Maximum collision retries for `try-create-temp-dir`.
(define fs-temp-attempt-limit : i64
  100)

;: Reversed path segment stack used by lexical path normalization.
(defenum FsPathSegmentList
  (FsPathSegmentNil)
  (FsPathSegmentCons String FsPathSegmentList))

;: Runtime status sentinel for regular files returned by `fs-file-kind-status`.
(define fs-file-kind-regular-code : i64
  -1)

;: Runtime status sentinel for directories returned by `fs-file-kind-status`.
(define fs-file-kind-directory-code : i64
  -2)

;: Runtime status sentinel for filesystem nodes that are neither files nor directories.
(define fs-file-kind-other-code : i64
  -3)

;: Portable coarse filesystem node kind.
(defenum FsFileKind
  (FsFileRegular)
  (FsFileDirectory)
  (FsFileOther))

;: Result type for file-kind probes.
(defenum ResultFsFileKind
  (OkFsFileKind FsFileKind)
  (ErrFsFileKind IoError))

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
(define (fs-path-starts-separator? [path : (& path str)]) : bool
  (and (> (string-length path) 0) (fs-path-separator? (string-ref path 0))))

;: Return true when `path` ends with either supported separator character.
(define (fs-path-ends-separator? [path : (& path str)]) : bool
  (let
    [n : i64 (string-length path)]
    (and (> n 0) (fs-path-separator? (string-ref path (- n 1))))))

;: Return true when `path` starts with a Windows drive designator like `C:`.
;:
;: `C:relative` is drive-qualified but not absolute. `fs-path-safe-relative?`
;: rejects drive-qualified strings because they are not portable root suffixes.
(define (fs-path-drive-qualified? [path : (& path str)]) : bool
  (and (> (string-length path) 1) (char-eq (string-ref path 1) #:')))

;: Return true when `path` is rooted or drive-absolute.
;:
;: Both `/` and `\` count as rooted separators. Windows drive-style absolute
;: paths require a separator after the drive designator, such as `C:/tmp` or
;: `C:\tmp`; drive-relative strings like `C:tmp` return false.
(define (fs-path-absolute? [path : (& path str)]) : bool
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

;: Render a reversed normalized path segment stack using `/` separators.
(define (fs-path-segment-list-render [segments : FsPathSegmentList]) : String
  (match segments
    [(FsPathSegmentNil) ""]
    [(FsPathSegmentCons head rest)
      (let
        [prefix : String (fs-path-segment-list-render rest)]
        (if (= (string-length prefix) 0)
          head
          (string-append prefix (string-append "/" head))))]))

;: Fold one lexical path segment into the normalized segment stack.
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
(define (fs-path-normalize [path : (& path str)]) : String
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

;: Return true when a normalized relative path still escapes via leading `..`.
(define (fs-path-normalized-escapes? [normalized : (& normalized str)]) : bool
  (let
    [n : i64 (string-length normalized)]
    (if (string-eq normalized "..")
      true
      (and
        (> n 2)
        (and
          (char-eq (string-ref normalized 0) #.')
          (and
            (char-eq (string-ref normalized 1) #.')
            (fs-path-separator? (string-ref normalized 2))))))))

;: Return true when `path` is a non-empty relative suffix that stays below root.
;:
;: This is a lexical guard to use before joining user-controlled suffixes under
;: a trusted root. It rejects empty/`.` paths, absolute or drive-qualified paths,
;: and normalized paths whose first segment is `..`. It does not canonicalize
;: symlinks or query the filesystem.
(define (fs-path-safe-relative? [path : (& path str)]) : bool
  (if (or (fs-path-absolute? path) (fs-path-drive-qualified? path))
    false
    (let
      [normalized : String (fs-path-normalize path)]
      (and
        (not (string-eq normalized "."))
        (not (fs-path-normalized-escapes? (& normalized)))))))

;: Join `left` and `right` with exactly one host path separator when needed.
;:
;: Empty sides are returned without allocating an extra separator.
(define (fs-path-join [left : (& left str)] [right : (& right str)]) : String
  (cond
    [(= (string-length left) 0)
      (let
        [empty : String ""]
        (string-append right (& empty)))]
    [(= (string-length right) 0)
      (let
        [empty : String ""]
        (string-append left (& empty)))]
    [(fs-path-separator? (string-ref left (- (string-length left) 1)))
      (if (fs-path-separator? (string-ref right 0))
        (string-append left (substring right 1 (- (string-length right) 1)))
        (string-append left right))]
    [(fs-path-separator? (string-ref right 0)) (string-append left right)]
    [else (string-append (string-append left (fs-path-separator)) right)]))

;: Index of the last path separator in `path`, or `-1` when there is none.
(define (fs-last-separator-index [path : (& path str)]) : i64
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
(define (fs-dirname [path : (& path str)]) : String
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
(define (fs-basename [path : (& path str)]) : String
  (let
    [n : i64 (string-length path)]
    [last : i64 (fs-last-separator-index path)]
    (if (< last 0)
      (io-copy-path path)
      (substring path (+ last 1) (- n (+ last 1))))))

;: Extension of `path` without the leading dot (e.g. `"tl"` for `main.tl`).
;:
;: Operates on the basename, so directory dots do not count. Returns `""` when
;: the basename has no dot or is a dotfile (a leading-dot name like
;: `.gitignore`, which has no extension).
(define (fs-extension [path : (& path str)]) : String
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
(define (fs-status-result [path : (& path str)] [status : i64]) : ResultIoUnit
  (if (= status io-status-ok)
    OkIoUnit
    (ErrIoUnit (io-error-from-status path status))))

;: Convert a runtime file-kind status into a structured result.
(define (fs-file-kind-status-result [path : (& path str)] [status : i64]) : ResultFsFileKind
  (cond
    [(= status fs-file-kind-regular-code) (OkFsFileKind (FsFileRegular))]
    [(= status fs-file-kind-directory-code) (OkFsFileKind (FsFileDirectory))]
    [(= status fs-file-kind-other-code) (OkFsFileKind (FsFileOther))]
    [else (ErrFsFileKind (io-error-from-status path status))]))

;: Create `path` as a directory, returning a structured status.
;:
;: Linux uses mode `0700`; Windows uses the backend `_mkdir` helper.
(define (try-mkdir [path : (& path str)]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (io-invalid-path-error path))
    (fs-status-result path (fs-mkdir-status path))))

;: Create `path` as a directory when it is missing.
;:
;: A pre-existing path reported by the host as already-created is accepted.
(define (try-mkdir-if-missing [path : (& path str)]) : ResultIoUnit
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
(define (try-remove-file [path : (& path str)]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (io-invalid-path-error path))
    (fs-status-result path (fs-remove-file-status path))))

;: Remove an empty directory path, returning a structured status.
(define (try-remove-dir [path : (& path str)]) : ResultIoUnit
  (if (io-empty-path? path)
    (ErrIoUnit (io-invalid-path-error path))
    (fs-status-result path (fs-remove-dir-status path))))

;: Rename `source` to `destination`, returning a structured status.
;:
;: Host replacement behavior is target-defined: Linux follows `rename(2)`,
;: while Windows currently reports `IoUnsupported`.
(define (try-rename
  [source : (& source str)]
  [destination : (& destination str)]) : ResultIoUnit
  (if (= (string-length source) 0)
    (let
      [empty : String ""]
      (ErrIoUnit (IoInvalidPath (string-append source (& empty)))))
    (if (= (string-length destination) 0)
      (let
        [empty : String ""]
        (ErrIoUnit (IoInvalidPath (string-append destination (& empty)))))
      (let
        [arrow : String " -> "]
        [path : String
          (string-append (string-append source (& arrow)) destination)]
        (fs-status-result (& path) (fs-rename-status source destination))))))

;: Probe the coarse filesystem kind of `path`.
;:
;: Linux reports regular files, directories, and other node kinds. Windows
;: currently returns `IoUnsupported` through the runtime status helper.
(define (try-file-kind [path : (& path str)]) : ResultFsFileKind
  (if (io-empty-path? path)
    (ErrFsFileKind (io-invalid-path-error path))
    (fs-file-kind-status-result path (fs-file-kind-status path))))

;: Return true when `kind` is `FsFileRegular`.
(define (fs-file-kind-regular? [kind : FsFileKind]) : bool
  (match kind
    [(FsFileRegular) true]
    [_ false]))

;: Return true when `kind` is `FsFileDirectory`.
(define (fs-file-kind-directory? [kind : FsFileKind]) : bool
  (match kind
    [(FsFileDirectory) true]
    [_ false]))

;: Return true when `kind` is `FsFileOther`.
(define (fs-file-kind-other? [kind : FsFileKind]) : bool
  (match kind
    [(FsFileOther) true]
    [_ false]))

;: Split the runtime's newline-delimited directory payload into entry names.
(define (fs-read-dir-split [entries : String]) : StringList
  (let
    [n : i64 (string-length entries)]
    [items : StringList (StringNil)]
    [start : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (if (char-eq (string-ref entries i) #\newline')
          (begin
            (if (> i start)
              (set!
                items
                (StringCons (substring entries start (- i start)) items))
              unit)
            (set! start (+ i 1))
            (set! i (+ i 1)))
          (set! i (+ i 1))))
      (if (< start n)
        (string-list-reverse
          (StringCons (substring entries start (- n start)) items))
        (string-list-reverse items)))))

;: Read one directory and return entry names as a `StringList`.
;:
;: Entries are names only, not joined paths. The runtime filters `.` and `..`.
;: Host directory order is preserved and not guaranteed to be stable; callers
;: that need stable ordering should sort the returned list. The returned list
;: spine and entry strings allocate in the active arena.
(define (try-read-dir [path : (& path str)]) : ResultIoStringList
  (if (io-empty-path? path)
    (ErrIoStringList (io-invalid-path-error path))
    (let
      [status : i64 (fs-read-dir-status path)]
      (if (= status io-status-ok)
        (OkIoStringList (fs-read-dir-split (fs-read-dir path)))
        (ErrIoStringList (io-error-from-status path status))))))

;: Remove a file if present. Missing paths are considered already cleaned.
(define (try-remove-file-if-exists [path : (& path str)]) : ResultIoUnit
  (match (try-remove-file path)
    [(OkIoUnit) OkIoUnit]
    [(ErrIoUnit error)
      (if (io-error-not-found? error)
        OkIoUnit
        (ErrIoUnit error))]))

;: Remove an empty directory if present. Missing paths are considered cleaned.
(define (try-remove-dir-if-exists [path : (& path str)]) : ResultIoUnit
  (match (try-remove-dir path)
    [(OkIoUnit) OkIoUnit]
    [(ErrIoUnit error)
      (if (io-error-not-found? error)
        OkIoUnit
        (ErrIoUnit error))]))

;: Return the host temporary root used by `try-create-temp-dir`.
(define (fs-temp-root) : String
  (if (fs-windows?)
    (let
      [name : String "TEMP"]
      (match (env-get (& name))
        [(EnvSomeString value) value]
        [(EnvNoString)
          (let
            [name : String "TMP"]
            (match (env-get (& name))
              [(EnvSomeString value) value]
              [(EnvNoString) "."]))]))
    (let
      [name : String "TMPDIR"]
      (match (env-get (& name))
        [(EnvSomeString value) value]
        [(EnvNoString) "/tmp"]))))

;: Return the process current directory as an owned active-arena String.
;:
;: The returned path is the host-reported cwd; it is not symlink-canonicalized.
;: Unsupported targets return `ErrIoString` with `IoUnsupported`.
(define (try-current-dir) : ResultIoString
  (let
    [status : i64 (tl_fs_current_dir_status)]
    (if (= status io-status-ok)
      (OkIoString (tl_fs_current_dir))
      (ErrIoString (io-error-from-label "current directory" status)))))

;: Compose one candidate temporary directory basename from prefix, pid, and attempt.
(define (fs-temp-name [prefix : (& prefix str)] [pid : i64] [attempt : i64]) : String
  (string-append
    (string-append prefix "-")
    (string-append (int->string pid) (string-append "-" (int->string attempt)))))

;: Retry temporary directory creation until an unused candidate is found.
(define (fs-create-temp-dir-loop
  [root : (& root str)]
  [prefix : (& prefix str)]
  [pid : i64]
  [attempt : i64]) : ResultIoString
  (if (>= attempt fs-temp-attempt-limit)
    (let
      [empty : String ""]
      (ErrIoString
        (IoSystemCode fs-status-already-exists (string-append prefix (& empty)))))
    (let
      [name : String (fs-temp-name prefix pid attempt)]
      [path : String
        (cond
          [(= (string-length root) 0) name]
          [(= (string-length name) 0)
            (let
              [empty : String ""]
              (string-append root (& empty)))]
          [(fs-path-separator? (string-ref root (- (string-length root) 1)))
            (if (fs-path-separator? (string-ref name 0))
              (string-append
                root
                (substring (& name) 1 (- (string-length name) 1)))
              (string-append root (& name)))]
          [(fs-path-separator? (string-ref name 0))
            (string-append root (& name))]
          [else
            (string-append (string-append root (fs-path-separator)) (& name))])]
      [status : i64 (fs-mkdir-status path)]
      (if (= status io-status-ok)
        (OkIoString path)
        (if (= status fs-status-already-exists)
          (fs-create-temp-dir-loop root prefix pid (+ attempt 1))
          (ErrIoString (io-error-from-status (& path) status)))))))

;: Create a unique temporary directory for tool artifacts.
;:
;: The directory is created below `$TMPDIR` on Linux (or `/tmp` when `TMPDIR` is
;: missing), and below `%TEMP%`/`%TMP%` (or `.`) on Windows. The unique name is
;: seeded by the process id (`GetCurrentProcessId` on Windows, `getpid` on
;: Linux) and an attempt counter, retrying on collision.
(define (try-create-temp-dir [prefix : (& prefix str)]) : ResultIoString
  (if (= (string-length prefix) 0)
    (let
      [empty : String ""]
      (ErrIoString (IoInvalidPath (string-append prefix (& empty)))))
    (let
      [root : String (fs-temp-root)]
      (fs-create-temp-dir-loop (& root) prefix (fs-process-id) 0))))