(import "stdlib/fs.tl")

(import "stdlib/io.tl")

(import "stdlib/list.tl")

(import "stdlib/test.tl")

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

(define (assert-exists [path : String] [expected : bool] [message : String]) : unit
  (match (try-file-exists? path)
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
  (match (expect-file-kind (try-file-kind path) message)
    [(FsFileRegular) unit]
    [_ (panic message)]))

(define (assert-file-kind-directory [path : String] [message : String]) : unit
  (match (expect-file-kind (try-file-kind path) message)
    [(FsFileDirectory) unit]
    [_ (panic message)]))

(define (assert-file-kind-not-found [path : String] [message : String]) : unit
  (match (try-file-kind path)
    [(ErrFsFileKind error) (assert-true (io-error-not-found? error) message)]
    [(OkFsFileKind _) (panic message)]))

(define (assert-file-kind-invalid [path : String] [message : String]) : unit
  (match (try-file-kind path)
    [(ErrFsFileKind error) (assert-true (io-error-invalid-path? error) message)]
    [(OkFsFileKind _) (panic message)]))

(define (assert-file-kind-unsupported [path : String] [message : String]) : unit
  (match (try-file-kind path)
    [(ErrFsFileKind error) (assert-true (io-error-unsupported? error) message)]
    [(OkFsFileKind _) (panic message)]))

(define (assert-file-metadata-regular-size
  [path : String]
  [expected-size : i64]
  [message : String]) : unit
  (let
    [metadata : FsMetadata
      (expect-file-metadata (try-file-metadata path) message)]
    (begin
      (match (fs-metadata-kind metadata)
        [(FsFileRegular) unit]
        [_ (panic message)])
      (assert-i64-eq (fs-metadata-size metadata) expected-size message))))

(define (assert-file-metadata-directory [path : String] [message : String]) : unit
  (match (fs-metadata-kind
    (expect-file-metadata (try-file-metadata path) message))
    [(FsFileDirectory) unit]
    [_ (panic message)]))

(define (assert-file-metadata-not-found [path : String] [message : String]) : unit
  (match (try-file-metadata path)
    [(ErrFsMetadata error) (assert-true (io-error-not-found? error) message)]
    [(OkFsMetadata _) (panic message)]))

(define (assert-file-metadata-invalid [path : String] [message : String]) : unit
  (match (try-file-metadata path)
    [(ErrFsMetadata error) (assert-true (io-error-invalid-path? error) message)]
    [(OkFsMetadata _) (panic message)]))

(define (assert-file-metadata-unsupported [path : String] [message : String]) : unit
  (match (try-file-metadata path)
    [(ErrFsMetadata error) (assert-true (io-error-unsupported? error) message)]
    [(OkFsMetadata _) (panic message)]))

(define (assert-file-contents
  [path : String]
  [expected : String]
  [message : String]) : unit
  (match (try-read-file path)
    [(OkIoString contents) (assert-string-eq contents expected message)]
    [(ErrIoString error)
      (panic (string-append message (io-error-message error)))]))

;; Windows supports temp-dir creation (mkdir + GetCurrentProcessId, #850) but
;; not yet removal/cleanup (remove-file/remove-dir are unsupported stubs), so the
;; Windows arm asserts a successful, unique, existing create rather than the full
;; Linux create/write/remove lifecycle.
(define (assert-created-temp-dir) : unit
  (let
    [dir-a : String
      (expect-ok-string
        (try-create-temp-dir "typelisp fs test")
        "create temp dir a: ")]
    [dir-b : String
      (expect-ok-string
        (try-create-temp-dir "typelisp fs test")
        "create temp dir b: ")]
    (begin
      (assert-true (not (string-eq dir-a dir-b)) "temp directories are unique")
      (assert-exists dir-a true "temp dir a exists")
      (assert-exists dir-b true "temp dir b exists"))))

(define (assert-invalid-temp-dir) : unit
  (match (try-create-temp-dir "")
    [(ErrIoString error)
      (assert-true (io-error-invalid-path? error) "empty temp prefix invalid")]
    [(OkIoString _) (panic "empty temp prefix unexpectedly succeeded")]))

(define (assert-mkdir-if-missing [parent : String] [cleanup : bool]) : unit
  (let
    [dir : String (fs-path-join parent "mkdir-if-missing")]
    (begin
      (assert-ok-unit (try-mkdir-if-missing dir) "mkdir-if-missing new dir: ")
      (assert-exists dir true "mkdir-if-missing dir exists")
      (assert-ok-unit
        (try-mkdir-if-missing dir)
        "mkdir-if-missing existing dir: ")
      (if cleanup
        (assert-ok-unit (try-remove-dir dir) "mkdir-if-missing cleanup dir: ")
        unit))))

(define (assert-linux-rename-api [root : String]) : unit
  (let
    [file-source : String (fs-path-join root "rename source with space.txt")]
    [file-destination : String
      (fs-path-join root "rename destination with space.txt")]
    [replace-source : String (fs-path-join root "replace source.txt")]
    [replace-destination : String (fs-path-join root "replace destination.txt")]
    [dir-source : String (fs-path-join root "dir source with space")]
    [dir-destination : String (fs-path-join root "dir destination with space")]
    [missing-source : String (fs-path-join root "missing source.txt")]
    [missing-destination : String (fs-path-join root "missing destination.txt")]
    (begin
      (assert-ok-unit
        (try-write-file file-source "alpha")
        "write rename source: ")
      (assert-ok-unit
        (try-rename file-source file-destination)
        "rename file with spaces: ")
      (assert-exists file-source false "renamed source is gone")
      (assert-exists file-destination true "renamed destination exists")
      (assert-file-contents
        file-destination
        "alpha"
        "renamed destination preserves contents")
      (assert-not-found-unit
        (try-rename missing-source missing-destination)
        "missing rename source is not found")
      (assert-invalid-unit
        (try-rename "" file-destination)
        "empty rename source is invalid")
      (assert-invalid-unit
        (try-rename file-destination "")
        "empty rename destination is invalid")
      (assert-ok-unit
        (try-write-file replace-source "replacement")
        "write replacement source: ")
      (assert-ok-unit
        (try-write-file replace-destination "old")
        "write replacement destination: ")
      (assert-ok-unit
        (try-rename replace-source replace-destination)
        "rename replaces existing file: ")
      (assert-exists replace-source false "replacement source is gone")
      (assert-file-contents
        replace-destination
        "replacement"
        "rename replacement policy overwrites destination")
      (assert-ok-unit (try-mkdir dir-source) "create rename dir source: ")
      (assert-ok-unit
        (try-rename dir-source dir-destination)
        "rename directory with spaces: ")
      (assert-exists dir-source false "renamed directory source is gone")
      (assert-exists
        dir-destination
        true
        "renamed directory destination exists")
      (assert-ok-unit
        (try-remove-file file-destination)
        "cleanup renamed file: ")
      (assert-ok-unit
        (try-remove-file replace-destination)
        "cleanup replacement file: ")
      (assert-ok-unit
        (try-remove-dir dir-destination)
        "cleanup renamed directory: "))))

(define (assert-windows-rename-api) : unit
  (begin
    (assert-unsupported-unit
      (try-rename "windows source" "windows destination")
      "windows rename reports unsupported")
    (assert-invalid-unit
      (try-rename "" "windows destination")
      "windows empty rename source is invalid")
    (assert-invalid-unit
      (try-rename "windows source" "")
      "windows empty rename destination is invalid")))

(define (assert-linux-read-dir-api [root : String]) : unit
  (let
    [file-a : String (fs-path-join root "alpha.txt")]
    [file-b : String (fs-path-join root "beta data.txt")]
    [child-dir : String (fs-path-join root "child-dir")]
    [missing : String (fs-path-join root "missing")]
    (begin
      (assert-ok-unit (try-write-file file-a "alpha") "read-dir file a: ")
      (assert-ok-unit (try-write-file file-b "beta") "read-dir file b: ")
      (assert-ok-unit (try-mkdir child-dir) "read-dir child dir: ")
      (let
        [entries : StringList
          (expect-ok-string-list (try-read-dir root) "read dir: ")]
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
          (assert-not-found-string-list
            (try-read-dir missing)
            "read-dir missing path reports not found")
          (assert-error-string-list
            (try-read-dir file-a)
            "read-dir file path reports an IoError")
          (assert-invalid-string-list
            (try-read-dir "")
            "read-dir empty path invalid")
          (assert-ok-unit (try-remove-file file-a) "cleanup read-dir file a: ")
          (assert-ok-unit (try-remove-file file-b) "cleanup read-dir file b: ")
          (assert-ok-unit (try-remove-dir child-dir) "cleanup read-dir child: "))))))

(define (fs-test-drive-absolute? [path : String]) : bool
  (and
    (> (string-length path) 2)
    (and (= (string-ref path 1) #:') (fs-path-separator? (string-ref path 2)))))

(define (assert-current-dir-api) : unit
  (match (try-current-dir)
    [(OkIoString cwd)
      (begin
        (assert-true (> (string-length cwd) 0) "current dir is non-empty")
        (assert-true
          (if (fs-windows?)
            (or (fs-path-starts-separator? cwd) (fs-test-drive-absolute? cwd))
            (fs-path-starts-separator? cwd))
          "current dir has rooted shape"))]
    [(ErrIoString error)
      (if (fs-windows?)
        (assert-true
          (io-error-unsupported? error)
          "windows current dir may be unsupported")
        (panic
          (string-append
            "linux current dir unexpectedly failed: "
            (io-error-message error))))]))

(define (main) : i64
  (let
    [joined : String (fs-path-join "left path" "right file")]
    [expected-join : String
      (string-append
        (string-append "left path" (fs-path-separator))
        "right file")]
    (begin
      (assert-string-eq joined expected-join "path join inserts separator")
      (assert-string-eq
        (fs-path-join "left/" "/right")
        "left/right"
        "path join avoids duplicate separator")
      ;; #822: pure path-string helpers (separator-agnostic; `/` cases are
      ;; stable on both Linux and Windows).
      (assert-string-eq
        (fs-dirname "src/app/main.tl")
        "src/app"
        "dirname strips final component")
      (assert-string-eq
        (fs-dirname "main.tl")
        "."
        "dirname of bare name is dot")
      (assert-string-eq
        (fs-basename "src/app/main.tl")
        "main.tl"
        "basename is final component")
      (assert-string-eq
        (fs-basename "main.tl")
        "main.tl"
        "basename of bare name is itself")
      (assert-string-eq
        (fs-extension "src/main.tl")
        "tl"
        "extension after last dot")
      (assert-string-eq
        (fs-extension "archive.tar.gz")
        "gz"
        "extension uses last dot")
      (assert-string-eq
        (fs-extension "Makefile")
        ""
        "no dot means no extension")
      (assert-string-eq
        (fs-extension ".gitignore")
        ""
        "leading-dot name has no extension")
      (assert-string-eq
        (fs-path-normalize "")
        "."
        "normalize empty path to dot")
      (assert-string-eq (fs-path-normalize ".") "." "normalize dot path")
      (assert-string-eq
        (fs-path-normalize "selfhost/./x/../compiler_load.tl")
        "selfhost/compiler_load.tl"
        "normalize dot and parent segments")
      (assert-string-eq
        (fs-path-normalize "target\\loader\\..\\dep.tl")
        "target/dep.tl"
        "normalize windows separators to slash")
      (assert-string-eq
        (fs-path-normalize "src//./app\\../main.tl")
        "src/main.tl"
        "normalize repeated and mixed separators")
      (assert-string-eq
        (fs-path-normalize "../pkg/lib.tl")
        "../pkg/lib.tl"
        "normalize preserves leading relative parent")
      (assert-string-eq
        (fs-path-normalize "a/../../b")
        "../b"
        "normalize preserves escaping relative parent")
      (assert-string-eq
        (fs-path-normalize "/a/..")
        "/"
        "normalize preserves root")
      (assert-string-eq
        (fs-path-normalize "\\a\\..\\b")
        "/b"
        "normalize rooted windows separators")
      (assert-string-eq
        (fs-path-normalize "C:\\tmp\\..\\file.tl")
        "C:/file.tl"
        "normalize drive absolute path")
      (assert-bool-eq
        (fs-path-absolute? "/root")
        true
        "slash-rooted path is absolute")
      (assert-bool-eq
        (fs-path-absolute? "\\root")
        true
        "backslash-rooted path is absolute")
      (assert-bool-eq
        (fs-path-absolute? "C:/root")
        true
        "drive slash path is absolute")
      (assert-bool-eq
        (fs-path-absolute? "C:\\root")
        true
        "drive backslash path is absolute")
      (assert-bool-eq
        (fs-path-absolute? "C:root")
        false
        "drive-relative path is not absolute")
      (assert-bool-eq
        (fs-path-absolute? "src/main.tl")
        false
        "relative path is not absolute")
      (assert-bool-eq
        (fs-path-safe-relative? "src/main.tl")
        true
        "normal relative path is safe")
      (assert-bool-eq
        (fs-path-safe-relative? "src//./lib/../main.tl")
        true
        "normalizing relative path below root is safe")
      (assert-bool-eq
        (fs-path-safe-relative? "")
        false
        "empty path is not a safe suffix")
      (assert-bool-eq
        (fs-path-safe-relative? ".")
        false
        "dot path is not a safe suffix")
      (assert-bool-eq
        (fs-path-safe-relative? "..")
        false
        "parent path is not a safe suffix")
      (assert-bool-eq
        (fs-path-safe-relative? "../escape.tl")
        false
        "leading parent traversal is not safe")
      (assert-bool-eq
        (fs-path-safe-relative? "a/../../escape.tl")
        false
        "normalized parent traversal is not safe")
      (assert-bool-eq
        (fs-path-safe-relative? "/abs.tl")
        false
        "rooted path is not a safe suffix")
      (assert-bool-eq
        (fs-path-safe-relative? "C:/abs.tl")
        false
        "drive absolute path is not a safe suffix")
      (assert-bool-eq
        (fs-path-safe-relative? "C:relative.tl")
        false
        "drive-relative path is not a safe suffix")
      (assert-current-dir-api)
      (if (fs-windows?)
        (begin
          (assert-created-temp-dir)
          (let
            [dir : String
              (expect-ok-string
                (try-create-temp-dir "typelisp fs mkdir test")
                "create temp dir mkdir: ")]
            (assert-mkdir-if-missing dir false))
          (assert-windows-rename-api)
          (assert-file-kind-unsupported "." "windows file kind unsupported")
          (assert-file-metadata-unsupported
            "."
            "windows file metadata unsupported")
          (assert-unsupported-string-list
            (try-read-dir ".")
            "windows read-dir reports unsupported")
          42)
        (let
          [dir-a : String
            (expect-ok-string
              (try-create-temp-dir "typelisp fs test")
              "create temp dir a: ")]
          [dir-b : String
            (expect-ok-string
              (try-create-temp-dir "typelisp fs test")
              "create temp dir b: ")]
          [dir-c : String
            (expect-ok-string
              (try-create-temp-dir "typelisp fs rename test")
              "create temp dir c: ")]
          [dir-d : String
            (expect-ok-string
              (try-create-temp-dir "typelisp fs read dir test")
              "create temp dir d: ")]
          [file-a : String (fs-path-join dir-a "artifact with space.s")]
          [file-b : String (fs-path-join dir-b "cleanup.obj")]
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
            (assert-ok-unit
              (try-write-file file-a "assembly")
              "write temp artifact a: ")
            (assert-ok-unit
              (try-write-file file-b "object")
              "write temp artifact b: ")
            (assert-mkdir-if-missing dir-a true)
            (assert-exists file-a true "temp artifact a exists")
            (assert-file-kind-regular file-a "temp artifact a is regular")
            (assert-file-metadata-regular-size
              file-a
              8
              "temp artifact a metadata size")
            (assert-file-kind-not-found
              (fs-path-join dir-a "missing artifact.s")
              "missing file kind is not found")
            (assert-file-metadata-not-found
              (fs-path-join dir-a "missing artifact.s")
              "missing file metadata is not found")
            (assert-ok-unit (try-remove-file file-a) "remove temp artifact a: ")
            (assert-exists file-a false "temp artifact a removed")
            (assert-ok-unit (try-remove-dir dir-a) "remove temp dir a: ")
            (assert-exists dir-a false "temp dir a removed")
            (assert-ok-unit
              (try-remove-file-if-exists file-b)
              "cleanup temp artifact b: ")
            (assert-ok-unit
              (try-remove-file-if-exists file-b)
              "cleanup missing temp artifact b: ")
            (assert-ok-unit
              (try-remove-dir-if-exists dir-b)
              "cleanup temp dir b: ")
            (assert-ok-unit
              (try-remove-dir-if-exists dir-b)
              "cleanup missing temp dir b: ")
            (assert-invalid-temp-dir)
            (assert-file-kind-invalid "" "empty file-kind path invalid")
            (assert-file-metadata-invalid "" "empty metadata path invalid")
            (assert-linux-rename-api dir-c)
            (assert-ok-unit (try-remove-dir dir-c) "cleanup rename temp dir: ")
            (assert-linux-read-dir-api dir-d)
            (assert-ok-unit
              (try-remove-dir dir-d)
              "cleanup read-dir temp dir: ")
            42))))))