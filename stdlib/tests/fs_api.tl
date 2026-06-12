(import "stdlib/core_macros.tl" module stdlib.core-macros as core)

(import "stdlib/fs.tl")

(import "stdlib/io.tl")

(import "stdlib/list.tl")

(import "stdlib/test.tl")

(import "stdlib/vector.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (assert-ok-unit [result : ResultIoUnit] [message : String]) : unit
  (match result
    [(OkIoUnit) unit]
    [(ErrIoUnit error) (panic (string-append message (io-error-message error)))]))

(define (assert-not-found-unit [result : ResultIoUnit] [message : String]) : unit
  (match result
    [(OkIoUnit) (panic (string-append message "unexpected success"))]
    [(ErrIoUnit error) (assert-true (io-error-not-found? error) message)]))

(define (assert-invalid-unit [result : ResultIoUnit] [message : String]) : unit
  (match result
    [(OkIoUnit) (panic (string-append message "unexpected success"))]
    [(ErrIoUnit error) (assert-true (io-error-invalid-path? error) message)]))

(define (assert-unsupported-unit [result : ResultIoUnit] [message : String]) : unit
  (match result
    [(OkIoUnit) (panic (string-append message "unexpected success"))]
    [(ErrIoUnit error) (assert-true (io-error-unsupported? error) message)]))

(define (expect-ok-string [result : ResultIoString] [message : String]) : String
  (match result
    [(OkIoString value) value]
    [(ErrIoString error)
      (panic (string-append message (io-error-message error)))]))

(define (expect-ok-string-list [result : ResultIoStringList] [message : String]) : StringList
  (match result
    [(OkIoStringList value) value]
    [(ErrIoStringList error)
      (panic (string-append message (io-error-message error)))]))

(define (expect-ok-string-vec [result : ResultIoStringVec] [message : String]) : StringVec
  (match result
    [(OkIoStringVec value) value]
    [(ErrIoStringVec error)
      (panic (string-append message (io-error-message error)))]))

(define (assert-unsupported-string-list
  [result : ResultIoStringList]
  [message : String]) : unit
  (match result
    [(OkIoStringList _) (panic (string-append message "unexpected success"))]
    [(ErrIoStringList error)
      (assert-true (io-error-unsupported? error) message)]))

(define (assert-not-found-string-list
  [result : ResultIoStringList]
  [message : String]) : unit
  (match result
    [(OkIoStringList _) (panic (string-append message "unexpected success"))]
    [(ErrIoStringList error) (assert-true (io-error-not-found? error) message)]))

(define (assert-invalid-string-list
  [result : ResultIoStringList]
  [message : String]) : unit
  (match result
    [(OkIoStringList _) (panic (string-append message "unexpected success"))]
    [(ErrIoStringList error)
      (assert-true (io-error-invalid-path? error) message)]))

(define (assert-error-string-list
  [result : ResultIoStringList]
  [message : String]) : unit
  (match result
    [(OkIoStringList _) (panic (string-append message "unexpected success"))]
    [(ErrIoStringList _) unit]))

(define (test-try-file-exists? [path : String]) : ResultIoBool
  (try-file-exists? (& path)))

(define (test-try-read-file [path : String]) : ResultIoString
  (try-read-file (& path)))

(define (test-try-write-file [path : String] [contents : String]) : ResultIoUnit
  (try-write-file (& path) (& contents)))

(define (test-fs-path-join [left : String] [right : String]) : String
  (fs-path-join (& left) (& right)))

(define (test-fs-path-join-many0) : String
  (fs-path-join-many))

(define (test-fs-path-join-many1 [a : String]) : String
  (fs-path-join-many a))

(define (test-fs-path-join-many2 [a : String] [b : String]) : String
  (fs-path-join-many a b))

(define (test-fs-path-join-many3 [a : String] [b : String] [c : String]) : String
  (fs-path-join-many a b c))

(define (test-fs-path-join-many4
  [a : String]
  [b : String]
  [c : String]
  [d : String]) : String
  (fs-path-join-many a b c d))

(define (test-fs-path-starts-separator? [path : String]) : bool
  (fs-path-starts-separator? (& path)))

(define (test-fs-dirname [path : String]) : String
  (fs-dirname (& path)))

(define (test-fs-basename [path : String]) : String
  (fs-basename (& path)))

(define (test-fs-extension [path : String]) : String
  (fs-extension (& path)))

(define (test-fs-path-normalize [path : String]) : String
  (fs-path-normalize (& path)))

(define (test-fs-path-absolute? [path : String]) : bool
  (fs-path-absolute? (& path)))

(define (test-fs-path-safe-relative? [path : String]) : bool
  (fs-path-safe-relative? (& path)))

(define (test-try-mkdir [path : String]) : ResultIoUnit
  (try-mkdir (& path)))

(define (test-try-mkdir-if-missing [path : String]) : ResultIoUnit
  (try-mkdir-if-missing (& path)))

(define (test-try-remove-file [path : String]) : ResultIoUnit
  (try-remove-file (& path)))

(define (test-try-remove-dir [path : String]) : ResultIoUnit
  (try-remove-dir (& path)))

(define (test-try-rename [source : String] [destination : String]) : ResultIoUnit
  (try-rename (& source) (& destination)))

(define (test-try-read-dir [path : String]) : ResultIoStringList
  (try-read-dir (& path)))

(define (test-try-read-dir-vec [path : String]) : ResultIoStringVec
  (try-read-dir-vec (& path)))

(define (test-try-file-kind [path : String]) : ResultFsFileKind
  (try-file-kind (& path)))

(define (test-try-file-metadata [path : String]) : ResultFsMetadata
  (try-file-metadata (& path)))

(define (test-fs-file-kind-status [path : String]) : i64
  (fs-file-kind-status path))

(define (test-fs-file-size-status [path : String]) : i64
  (fs-file-size-status path))

(define (test-fs-file-size [path : String]) : i64
  (fs-file-size path))

(define (test-try-remove-file-if-exists [path : String]) : ResultIoUnit
  (try-remove-file-if-exists (& path)))

(define (test-try-remove-dir-if-exists [path : String]) : ResultIoUnit
  (try-remove-dir-if-exists (& path)))

(define (test-try-create-temp-dir [prefix : String]) : ResultIoString
  (try-create-temp-dir (& prefix)))

(define (assert-exists [path : String] [expected : bool] [message : String]) : unit
  (match (test-try-file-exists? path)
    [(OkIoBool exists) (assert-bool-eq exists expected message)]
    [(ErrIoBool error) (panic (string-append message (io-error-message error)))]))

(define (expect-file-kind [result : ResultFsFileKind] [message : String]) : FsFileKind
  (match result
    [(OkFsFileKind kind) kind]
    [(ErrFsFileKind error)
      (panic (string-append message (io-error-message error)))]))

(define (expect-file-metadata [result : ResultFsMetadata] [message : String]) : FsMetadata
  (match result
    [(OkFsMetadata metadata) metadata]
    [(ErrFsMetadata error)
      (panic (string-append message (io-error-message error)))]))

(define (assert-file-kind-regular [path : String] [message : String]) : unit
  (match (expect-file-kind (test-try-file-kind path) message)
    [(FsFileRegular) unit]
    [_ (panic message)]))

(define (assert-file-kind-directory [path : String] [message : String]) : unit
  (match (expect-file-kind (test-try-file-kind path) message)
    [(FsFileDirectory) unit]
    [_ (panic message)]))

(define (assert-file-kind-not-found [path : String] [message : String]) : unit
  (match (test-try-file-kind path)
    [(ErrFsFileKind error) (assert-true (io-error-not-found? error) message)]
    [(OkFsFileKind _) (panic message)]))

(define (assert-file-kind-invalid [path : String] [message : String]) : unit
  (match (test-try-file-kind path)
    [(ErrFsFileKind error) (assert-true (io-error-invalid-path? error) message)]
    [(OkFsFileKind _) (panic message)]))

(define (assert-file-kind-unsupported [path : String] [message : String]) : unit
  (match (test-try-file-kind path)
    [(ErrFsFileKind error) (assert-true (io-error-unsupported? error) message)]
    [(OkFsFileKind _) (panic message)]))

(define (assert-file-metadata-regular-size
  [path : String]
  [expected-size : i64]
  [message : String]) : unit
  (let
    [metadata : FsMetadata
      (expect-file-metadata (test-try-file-metadata path) message)]
    (begin
      (match (fs-metadata-kind metadata)
        [(FsFileRegular) unit]
        [_ (panic message)])
      (assert-i64-eq (fs-metadata-size metadata) expected-size message))))

(define (assert-file-metadata-directory [path : String] [message : String]) : unit
  (match (fs-metadata-kind
    (expect-file-metadata (test-try-file-metadata path) message))
    [(FsFileDirectory) unit]
    [_ (panic message)]))

(define (assert-file-metadata-not-found [path : String] [message : String]) : unit
  (match (test-try-file-metadata path)
    [(ErrFsMetadata error) (assert-true (io-error-not-found? error) message)]
    [(OkFsMetadata _) (panic message)]))

(define (assert-file-metadata-invalid [path : String] [message : String]) : unit
  (match (test-try-file-metadata path)
    [(ErrFsMetadata error) (assert-true (io-error-invalid-path? error) message)]
    [(OkFsMetadata _) (panic message)]))

(define (assert-file-metadata-unsupported [path : String] [message : String]) : unit
  (match (test-try-file-metadata path)
    [(ErrFsMetadata error) (assert-true (io-error-unsupported? error) message)]
    [(OkFsMetadata _) (panic message)]))

(define (assert-runtime-metadata-regular
  [path : String]
  [expected-size : i64]
  [message : String]) : unit
  (begin
    (assert-i64-eq
      (test-fs-file-kind-status path)
      fs-file-kind-regular-code
      message)
    (assert-i64-eq (test-fs-file-size-status path) io-status-ok message)
    (assert-i64-eq (test-fs-file-size path) expected-size message)))

(define (assert-runtime-metadata-directory [path : String] [message : String]) : unit
  (begin
    (assert-i64-eq
      (test-fs-file-kind-status path)
      fs-file-kind-directory-code
      message)
    (assert-i64-eq (test-fs-file-size-status path) io-status-ok message)
    (assert-i64-eq (test-fs-file-size path) 0 message)))

(define (assert-runtime-metadata-not-found [path : String] [message : String]) : unit
  (begin
    (assert-i64-eq (test-fs-file-kind-status path) io-status-not-found message)
    (assert-i64-eq (test-fs-file-size-status path) io-status-not-found message)
    (assert-i64-eq (test-fs-file-size path) 0 message)))

(define (assert-string-vec3
  [items : StringVec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (begin
    (assert-i64-eq (string-vec-len items) 3 message)
    (assert-owned-string-eq (string-vec-get items 0 "missing") first message)
    (assert-owned-string-eq (string-vec-get items 1 "missing") second message)
    (assert-owned-string-eq (string-vec-get items 2 "missing") third message)))

(define (assert-file-contents
  [path : String]
  [expected : String]
  [message : String]) : unit
  (match (test-try-read-file path)
    [(OkIoString contents) (assert-owned-string-eq contents expected message)]
    [(ErrIoString error)
      (panic (string-append message (io-error-message error)))]))

;; Windows and Linux both support temp-dir creation; the broad lifecycle checks
;; below cover cleanup where the test owns all generated children.
(define (assert-created-temp-dir) : unit
  (let
    [dir-a : String
      (expect-ok-string
        (test-try-create-temp-dir "typelisp fs test")
        "create temp dir a: ")]
    [dir-b : String
      (expect-ok-string
        (test-try-create-temp-dir "typelisp fs test")
        "create temp dir b: ")]
    (begin
      (assert-true (not (string-eq dir-a dir-b)) "temp directories are unique")
      (assert-exists dir-a true "temp dir a exists")
      (assert-exists dir-b true "temp dir b exists"))))

(define (assert-invalid-temp-dir) : unit
  (match (test-try-create-temp-dir "")
    [(ErrIoString error)
      (assert-true (io-error-invalid-path? error) "empty temp prefix invalid")]
    [(OkIoString _) (panic "empty temp prefix unexpectedly succeeded")]))

(define (assert-mkdir-if-missing [parent : String] [cleanup : bool]) : unit
  (let
    [dir : String (test-fs-path-join parent "mkdir-if-missing")]
    (begin
      (assert-ok-unit
        (test-try-mkdir-if-missing dir)
        "mkdir-if-missing new dir: ")
      (assert-exists dir true "mkdir-if-missing dir exists")
      (assert-ok-unit
        (test-try-mkdir-if-missing dir)
        "mkdir-if-missing existing dir: ")
      (if cleanup
        (assert-ok-unit
          (test-try-remove-dir dir)
          "mkdir-if-missing cleanup dir: ")
        unit))))

(define (assert-linux-rename-api [root : String]) : unit
  (let
    [file-source : String
      (test-fs-path-join root "rename source with space.txt")]
    [file-destination : String
      (test-fs-path-join root "rename destination with space.txt")]
    [replace-source : String (test-fs-path-join root "replace source.txt")]
    [replace-destination : String
      (test-fs-path-join root "replace destination.txt")]
    [dir-source : String (test-fs-path-join root "dir source with space")]
    [dir-destination : String
      (test-fs-path-join root "dir destination with space")]
    [missing-source : String (test-fs-path-join root "missing source.txt")]
    [missing-destination : String
      (test-fs-path-join root "missing destination.txt")]
    (begin
      (assert-ok-unit
        (test-try-write-file file-source "alpha")
        "write rename source: ")
      (assert-ok-unit
        (test-try-rename file-source file-destination)
        "rename file with spaces: ")
      (assert-exists file-source false "renamed source is gone")
      (assert-exists file-destination true "renamed destination exists")
      (assert-file-contents
        file-destination
        "alpha"
        "renamed destination preserves contents")
      (assert-not-found-unit
        (test-try-rename missing-source missing-destination)
        "missing rename source is not found")
      (assert-invalid-unit
        (test-try-rename "" file-destination)
        "empty rename source is invalid")
      (assert-invalid-unit
        (test-try-rename file-destination "")
        "empty rename destination is invalid")
      (assert-ok-unit
        (test-try-write-file replace-source "replacement")
        "write replacement source: ")
      (assert-ok-unit
        (test-try-write-file replace-destination "old")
        "write replacement destination: ")
      (assert-ok-unit
        (test-try-rename replace-source replace-destination)
        "rename replaces existing file: ")
      (assert-exists replace-source false "replacement source is gone")
      (assert-file-contents
        replace-destination
        "replacement"
        "rename replacement policy overwrites destination")
      (assert-ok-unit (test-try-mkdir dir-source) "create rename dir source: ")
      (assert-ok-unit
        (test-try-rename dir-source dir-destination)
        "rename directory with spaces: ")
      (assert-exists dir-source false "renamed directory source is gone")
      (assert-exists
        dir-destination
        true
        "renamed directory destination exists")
      (assert-ok-unit
        (test-try-remove-file file-destination)
        "cleanup renamed file: ")
      (assert-ok-unit
        (test-try-remove-file replace-destination)
        "cleanup replacement file: ")
      (assert-ok-unit
        (test-try-remove-dir dir-destination)
        "cleanup renamed directory: "))))

(define (assert-windows-rename-api) : unit
  (begin
    (assert-not-found-unit
      (test-try-rename "windows source" "windows destination")
      "windows missing rename source reports not found")
    (assert-invalid-unit
      (test-try-rename "" "windows destination")
      "windows empty rename source is invalid")
    (assert-invalid-unit
      (test-try-rename "windows source" "")
      "windows empty rename destination is invalid")))

(define (assert-read-dir-api [root : String]) : unit
  (let
    [file-a : String (test-fs-path-join root "alpha.txt")]
    [file-b : String (test-fs-path-join root "beta data.txt")]
    [child-dir : String (test-fs-path-join root "child-dir")]
    [missing : String (test-fs-path-join root "missing")]
    (begin
      (assert-ok-unit (test-try-write-file file-a "alpha") "read-dir file a: ")
      (assert-ok-unit (test-try-write-file file-b "beta") "read-dir file b: ")
      (assert-ok-unit (test-try-mkdir child-dir) "read-dir child dir: ")
      (let
        [entries : StringList
          (expect-ok-string-list (test-try-read-dir root) "read dir: ")]
        [entries-vec : StringVec
          (expect-ok-string-vec (test-try-read-dir-vec root) "read dir vec: ")]
        (begin
          (assert-true
            (string-list-contains? entries "alpha.txt")
            "read-dir includes first file name")
          (assert-true
            (string-list-contains? entries "beta data.txt")
            "read-dir includes second file name")
          (assert-true
            (string-list-contains? entries "child-dir")
            "read-dir includes subdirectory name")
          (assert-false
            (string-list-contains? entries ".")
            "read-dir filters dot")
          (assert-false
            (string-list-contains? entries "..")
            "read-dir filters dotdot")
          (assert-true
            (string-vec-contains? entries-vec "alpha.txt")
            "read-dir vec includes first file name")
          (assert-true
            (string-vec-contains? entries-vec "beta data.txt")
            "read-dir vec includes second file name")
          (assert-true
            (string-vec-contains? entries-vec "child-dir")
            "read-dir vec includes subdirectory name")
          (assert-false
            (string-vec-contains? entries-vec ".")
            "read-dir vec filters dot")
          (assert-false
            (string-vec-contains? entries-vec "..")
            "read-dir vec filters dotdot")
          (assert-not-found-string-list
            (test-try-read-dir missing)
            "read-dir missing path reports not found")
          (assert-error-string-list
            (test-try-read-dir file-a)
            "read-dir file path reports an IoError")
          (assert-invalid-string-list
            (test-try-read-dir "")
            "read-dir empty path invalid")
          (assert-ok-unit
            (test-try-remove-file file-a)
            "cleanup read-dir file a: ")
          (assert-ok-unit
            (test-try-remove-file file-b)
            "cleanup read-dir file b: ")
          (assert-ok-unit
            (test-try-remove-dir child-dir)
            "cleanup read-dir child: "))))))

(define (fs-test-drive-absolute? [path : String]) : bool
  (core/and
    (> (string-length path) 2)
    (= (string-ref path 1) #:')
    (fs-path-separator? (string-ref path 2))))

(define (assert-current-dir-api) : unit
  (begin
    (assert-i64-eq (fs-current-dir-status) io-status-ok "current dir status ok")
    (let
      [direct-cwd : String (fs-current-dir)]
      (assert-true
        (> (string-length direct-cwd) 0)
        "direct current dir is non-empty"))
    (match (try-current-dir)
      [(OkIoString cwd)
        (begin
          (assert-true (> (string-length cwd) 0) "current dir is non-empty")
          (assert-true
            (if (fs-windows?)
              (core/or
                (test-fs-path-starts-separator? cwd)
                (fs-test-drive-absolute? cwd))
              (test-fs-path-starts-separator? cwd))
            "current dir has rooted shape"))]
      [(ErrIoString error)
        (assert-true
          false
          (string-append
            "current dir unexpectedly failed: "
            (io-error-message error)))])))

(define (main) : i64
  (let
    [joined : String (test-fs-path-join "left path" "right file")]
    [expected-join : String
      (string-append
        (string-append "left path" (fs-path-separator))
        "right file")]
    (begin
      (assert-owned-string-eq
        joined
        expected-join
        "path join inserts separator")
      (assert-owned-string-eq
        (test-fs-path-join "left/" "/right")
        "left/right"
        "path join avoids duplicate separator")
      (assert-owned-string-eq
        (test-fs-path-join-many0)
        ""
        "path join many zero segments")
      (assert-owned-string-eq
        (test-fs-path-join-many1 "solo")
        "solo"
        "path join many one segment")
      (assert-owned-string-eq
        (test-fs-path-join-many2 "left path" "right file")
        expected-join
        "path join many two segments")
      (assert-owned-string-eq
        (test-fs-path-join-many3 "left" "middle" "right")
        (string-append
          (string-append (string-append "left" (fs-path-separator)) "middle")
          (string-append (fs-path-separator) "right"))
        "path join many three segments")
      (assert-owned-string-eq
        (test-fs-path-join-many4 "left" "middle" "right" "leaf")
        (string-append
          (string-append
            (string-append (string-append "left" (fs-path-separator)) "middle")
            (string-append (fs-path-separator) "right"))
          (string-append (fs-path-separator) "leaf"))
        "path join many four segments")
      (assert-owned-string-eq
        (test-fs-path-join-many3 "left/" "/right" "leaf")
        (string-append "left/right" (string-append (fs-path-separator) "leaf"))
        "path join many avoids duplicate separator")
      (assert-string-vec3
        (fs-read-dir-split-vec "first\nsecond\nthird\n")
        "first"
        "second"
        "third"
        "read-dir split vec preserves payload order")
      ;; #822: pure path-string helpers (separator-agnostic; `/` cases are
      ;; stable on both Linux and Windows).
      (assert-owned-string-eq
        (test-fs-dirname "src/app/main.tl")
        "src/app"
        "dirname strips final component")
      (assert-owned-string-eq
        (test-fs-dirname "main.tl")
        "."
        "dirname of bare name is dot")
      (assert-owned-string-eq
        (test-fs-basename "src/app/main.tl")
        "main.tl"
        "basename is final component")
      (assert-owned-string-eq
        (test-fs-basename "main.tl")
        "main.tl"
        "basename of bare name is itself")
      (assert-owned-string-eq
        (test-fs-extension "src/main.tl")
        "tl"
        "extension after last dot")
      (assert-owned-string-eq
        (test-fs-extension "archive.tar.gz")
        "gz"
        "extension uses last dot")
      (assert-owned-string-eq
        (test-fs-extension "Makefile")
        ""
        "no dot means no extension")
      (assert-owned-string-eq
        (test-fs-extension ".gitignore")
        ""
        "leading-dot name has no extension")
      (assert-owned-string-eq
        (test-fs-path-normalize "")
        "."
        "normalize empty path to dot")
      (assert-owned-string-eq
        (test-fs-path-normalize ".")
        "."
        "normalize dot path")
      (assert-owned-string-eq
        (test-fs-path-normalize "selfhost/./x/../compiler_load.tl")
        "selfhost/compiler_load.tl"
        "normalize dot and parent segments")
      (assert-owned-string-eq
        (test-fs-path-normalize "target\\loader\\..\\dep.tl")
        "target/dep.tl"
        "normalize windows separators to slash")
      (assert-owned-string-eq
        (test-fs-path-normalize "src//./app\\../main.tl")
        "src/main.tl"
        "normalize repeated and mixed separators")
      (assert-owned-string-eq
        (test-fs-path-normalize "../pkg/lib.tl")
        "../pkg/lib.tl"
        "normalize preserves leading relative parent")
      (assert-owned-string-eq
        (test-fs-path-normalize "a/../../b")
        "../b"
        "normalize preserves escaping relative parent")
      (assert-owned-string-eq
        (test-fs-path-normalize "/a/..")
        "/"
        "normalize preserves root")
      (assert-owned-string-eq
        (test-fs-path-normalize "\\a\\..\\b")
        "/b"
        "normalize rooted windows separators")
      (assert-owned-string-eq
        (test-fs-path-normalize "C:\\tmp\\..\\file.tl")
        "C:/file.tl"
        "normalize drive absolute path")
      (assert-bool-eq
        (test-fs-path-absolute? "/root")
        true
        "slash-rooted path is absolute")
      (assert-bool-eq
        (test-fs-path-absolute? "\\root")
        true
        "backslash-rooted path is absolute")
      (assert-bool-eq
        (test-fs-path-absolute? "C:/root")
        true
        "drive slash path is absolute")
      (assert-bool-eq
        (test-fs-path-absolute? "C:\\root")
        true
        "drive backslash path is absolute")
      (assert-bool-eq
        (test-fs-path-absolute? "C:root")
        false
        "drive-relative path is not absolute")
      (assert-bool-eq
        (test-fs-path-absolute? "src/main.tl")
        false
        "relative path is not absolute")
      (assert-bool-eq
        (test-fs-path-safe-relative? "src/main.tl")
        true
        "normal relative path is safe")
      (assert-bool-eq
        (test-fs-path-safe-relative? "src//./lib/../main.tl")
        true
        "normalizing relative path below root is safe")
      (assert-bool-eq
        (test-fs-path-safe-relative? "")
        false
        "empty path is not a safe suffix")
      (assert-bool-eq
        (test-fs-path-safe-relative? ".")
        false
        "dot path is not a safe suffix")
      (assert-bool-eq
        (test-fs-path-safe-relative? "..")
        false
        "parent path is not a safe suffix")
      (assert-bool-eq
        (test-fs-path-safe-relative? "../escape.tl")
        false
        "leading parent traversal is not safe")
      (assert-bool-eq
        (test-fs-path-safe-relative? "a/../../escape.tl")
        false
        "normalized parent traversal is not safe")
      (assert-bool-eq
        (test-fs-path-safe-relative? "/abs.tl")
        false
        "rooted path is not a safe suffix")
      (assert-bool-eq
        (test-fs-path-safe-relative? "C:/abs.tl")
        false
        "drive absolute path is not a safe suffix")
      (assert-bool-eq
        (test-fs-path-safe-relative? "C:relative.tl")
        false
        "drive-relative path is not a safe suffix")
      (assert-current-dir-api)
      (if (fs-windows?)
        (begin
          (assert-created-temp-dir)
          (let
            [dir : String
              (expect-ok-string
                (test-try-create-temp-dir "typelisp fs mkdir test")
                "create temp dir mkdir: ")]
            [dir-d : String
              (expect-ok-string
                (test-try-create-temp-dir "typelisp fs read dir test")
                "create temp dir read dir: ")]
            [file-a : String (test-fs-path-join dir "artifact with space.s")]
            (begin
              (assert-mkdir-if-missing dir true)
              (assert-file-kind-directory dir "windows temp dir is directory")
              (assert-file-metadata-directory
                dir
                "windows temp dir metadata is directory")
              (assert-runtime-metadata-directory
                dir
                "windows runtime metadata dir")
              (assert-ok-unit
                (test-try-write-file file-a "assembly")
                "windows write temp artifact: ")
              (assert-file-kind-regular
                file-a
                "windows temp artifact is regular")
              (assert-file-metadata-regular-size
                file-a
                8
                "windows temp artifact metadata size")
              (assert-runtime-metadata-regular
                file-a
                8
                "windows runtime metadata file")
              (assert-file-kind-not-found
                (test-fs-path-join dir "missing artifact.s")
                "windows missing file kind is not found")
              (assert-file-metadata-not-found
                (test-fs-path-join dir "missing artifact.s")
                "windows missing file metadata is not found")
              (assert-runtime-metadata-not-found
                (test-fs-path-join dir "missing artifact.s")
                "windows runtime metadata missing")
              (assert-ok-unit
                (test-try-remove-file file-a)
                "windows remove temp artifact: ")
              (assert-read-dir-api dir-d)
              (assert-ok-unit
                (test-try-remove-dir dir-d)
                "windows cleanup read-dir temp dir: ")
              (assert-ok-unit
                (test-try-remove-dir dir)
                "windows cleanup mkdir temp dir: ")))
          (assert-windows-rename-api)
          (assert-file-kind-invalid "" "windows empty file-kind path invalid")
          (assert-file-metadata-invalid
            ""
            "windows empty metadata path invalid")
          42)
        (let
          [dir-a : String
            (expect-ok-string
              (test-try-create-temp-dir "typelisp fs test")
              "create temp dir a: ")]
          [dir-b : String
            (expect-ok-string
              (test-try-create-temp-dir "typelisp fs test")
              "create temp dir b: ")]
          [dir-c : String
            (expect-ok-string
              (test-try-create-temp-dir "typelisp fs rename test")
              "create temp dir c: ")]
          [dir-d : String
            (expect-ok-string
              (test-try-create-temp-dir "typelisp fs read dir test")
              "create temp dir d: ")]
          [file-a : String (test-fs-path-join dir-a "artifact with space.s")]
          [file-b : String (test-fs-path-join dir-b "cleanup.obj")]
          (begin
            (assert-true
              (not (string-eq dir-a dir-b))
              "temp directories are unique")
            (assert-exists dir-a true "temp dir a exists")
            (assert-exists dir-b true "temp dir b exists")
            (assert-file-kind-directory dir-a "temp dir a is directory")
            (assert-file-metadata-directory
              dir-a
              "temp dir a metadata is directory")
            (assert-runtime-metadata-directory dir-a "runtime metadata dir")
            (assert-ok-unit
              (test-try-write-file file-a "assembly")
              "write temp artifact a: ")
            (assert-ok-unit
              (test-try-write-file file-b "object")
              "write temp artifact b: ")
            (assert-mkdir-if-missing dir-a true)
            (assert-exists file-a true "temp artifact a exists")
            (assert-file-kind-regular file-a "temp artifact a is regular")
            (assert-file-metadata-regular-size
              file-a
              8
              "temp artifact a metadata size")
            (assert-runtime-metadata-regular file-a 8 "runtime metadata file")
            (assert-file-kind-not-found
              (test-fs-path-join dir-a "missing artifact.s")
              "missing file kind is not found")
            (assert-file-metadata-not-found
              (test-fs-path-join dir-a "missing artifact.s")
              "missing file metadata is not found")
            (assert-runtime-metadata-not-found
              (test-fs-path-join dir-a "missing artifact.s")
              "runtime metadata missing")
            (assert-ok-unit
              (test-try-remove-file file-a)
              "remove temp artifact a: ")
            (assert-exists file-a false "temp artifact a removed")
            (assert-ok-unit (test-try-remove-dir dir-a) "remove temp dir a: ")
            (assert-exists dir-a false "temp dir a removed")
            (assert-ok-unit
              (test-try-remove-file-if-exists file-b)
              "cleanup temp artifact b: ")
            (assert-ok-unit
              (test-try-remove-file-if-exists file-b)
              "cleanup missing temp artifact b: ")
            (assert-ok-unit
              (test-try-remove-dir-if-exists dir-b)
              "cleanup temp dir b: ")
            (assert-ok-unit
              (test-try-remove-dir-if-exists dir-b)
              "cleanup missing temp dir b: ")
            (assert-invalid-temp-dir)
            (assert-file-kind-invalid "" "empty file-kind path invalid")
            (assert-file-metadata-invalid "" "empty metadata path invalid")
            (assert-linux-rename-api dir-c)
            (assert-ok-unit
              (test-try-remove-dir dir-c)
              "cleanup rename temp dir: ")
            (assert-read-dir-api dir-d)
            (assert-ok-unit
              (test-try-remove-dir dir-d)
              "cleanup read-dir temp dir: ")
            42))))))