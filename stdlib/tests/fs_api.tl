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

(define (test-try-file-exists? [path : String]) : ResultIoBool
  (try-file-exists? (& path)))

(define (test-try-read-file [path : String]) : ResultIoString
  (try-read-file (& path)))

(define (test-try-write-file [path : String] [contents : String]) : ResultIoUnit
  (try-write-file (& path) (& contents)))

(define (test-fs-path-join [left : String] [right : String]) : String
  (fs-path-join (& left) (& right)))

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

(define (assert-file-contents
  [path : String]
  [expected : String]
  [message : String]) : unit
  (match (test-try-read-file path)
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
    (assert-unsupported-unit
      (test-try-rename "windows source" "windows destination")
      "windows rename reports unsupported")
    (assert-invalid-unit
      (test-try-rename "" "windows destination")
      "windows empty rename source is invalid")
    (assert-invalid-unit
      (test-try-rename "windows source" "")
      "windows empty rename destination is invalid")))

(define (assert-linux-read-dir-api [root : String]) : unit
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
            (or
              (test-fs-path-starts-separator? cwd)
              (fs-test-drive-absolute? cwd))
            (test-fs-path-starts-separator? cwd))
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
    [joined : String (test-fs-path-join "left path" "right file")]
    [expected-join : String
      (string-append
        (string-append "left path" (fs-path-separator))
        "right file")]
    (begin
      (assert-string-eq joined expected-join "path join inserts separator")
      (assert-string-eq
        (test-fs-path-join "left/" "/right")
        "left/right"
        "path join avoids duplicate separator")
      ;; #822: pure path-string helpers (separator-agnostic; `/` cases are
      ;; stable on both Linux and Windows).
      (assert-string-eq
        (test-fs-dirname "src/app/main.tl")
        "src/app"
        "dirname strips final component")
      (assert-string-eq
        (test-fs-dirname "main.tl")
        "."
        "dirname of bare name is dot")
      (assert-string-eq
        (test-fs-basename "src/app/main.tl")
        "main.tl"
        "basename is final component")
      (assert-string-eq
        (test-fs-basename "main.tl")
        "main.tl"
        "basename of bare name is itself")
      (assert-string-eq
        (test-fs-extension "src/main.tl")
        "tl"
        "extension after last dot")
      (assert-string-eq
        (test-fs-extension "archive.tar.gz")
        "gz"
        "extension uses last dot")
      (assert-string-eq
        (test-fs-extension "Makefile")
        ""
        "no dot means no extension")
      (assert-string-eq
        (test-fs-extension ".gitignore")
        ""
        "leading-dot name has no extension")
      (assert-string-eq
        (test-fs-path-normalize "")
        "."
        "normalize empty path to dot")
      (assert-string-eq (test-fs-path-normalize ".") "." "normalize dot path")
      (assert-string-eq
        (test-fs-path-normalize "selfhost/./x/../compiler_load.tl")
        "selfhost/compiler_load.tl"
        "normalize dot and parent segments")
      (assert-string-eq
        (test-fs-path-normalize "target\\loader\\..\\dep.tl")
        "target/dep.tl"
        "normalize windows separators to slash")
      (assert-string-eq
        (test-fs-path-normalize "src//./app\\../main.tl")
        "src/main.tl"
        "normalize repeated and mixed separators")
      (assert-string-eq
        (test-fs-path-normalize "../pkg/lib.tl")
        "../pkg/lib.tl"
        "normalize preserves leading relative parent")
      (assert-string-eq
        (test-fs-path-normalize "a/../../b")
        "../b"
        "normalize preserves escaping relative parent")
      (assert-string-eq
        (test-fs-path-normalize "/a/..")
        "/"
        "normalize preserves root")
      (assert-string-eq
        (test-fs-path-normalize "\\a\\..\\b")
        "/b"
        "normalize rooted windows separators")
      (assert-string-eq
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
            (assert-mkdir-if-missing dir false))
          (assert-windows-rename-api)
          (assert-unsupported-string-list
            (test-try-read-dir ".")
            "windows read-dir reports unsupported")
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
            (assert-ok-unit
              (test-try-write-file file-a "assembly")
              "write temp artifact a: ")
            (assert-ok-unit
              (test-try-write-file file-b "object")
              "write temp artifact b: ")
            (assert-mkdir-if-missing dir-a true)
            (assert-exists file-a true "temp artifact a exists")
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
            (assert-linux-rename-api dir-c)
            (assert-ok-unit
              (test-try-remove-dir dir-c)
              "cleanup rename temp dir: ")
            (assert-linux-read-dir-api dir-d)
            (assert-ok-unit
              (test-try-remove-dir dir-d)
              "cleanup read-dir temp dir: ")
            42))))))