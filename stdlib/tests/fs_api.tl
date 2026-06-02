(import "stdlib/fs.tl")

(import "stdlib/io.tl")

(import "stdlib/test.tl")

(define (assert-ok-unit [result : ResultIoUnit] [message : String]) : unit
  (match result
    [(OkIoUnit) unit]
    [(ErrIoUnit error) (panic (string-append message (io-error-message error)))]))

(define (expect-ok-string [result : ResultIoString] [message : String]) : String
  (match result
    [(OkIoString value) value]
    [(ErrIoString error)
      (panic (string-append message (io-error-message error)))]))

(define (assert-exists [path : String] [expected : bool] [message : String]) : unit
  (match (try-file-exists? path)
    [(OkIoBool exists) (assert-bool-eq exists expected message)]
    [(ErrIoBool error) (panic (string-append message (io-error-message error)))]))

(define (assert-invalid-temp-dir) : unit
  (match (try-create-temp-dir "")
    [(ErrIoString error)
      (assert-true (io-error-invalid-path? error) "empty temp prefix invalid")]
    [(OkIoString _) (panic "empty temp prefix unexpectedly succeeded")]))

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
      (let
        [dir-a : String
          (expect-ok-string
            (try-create-temp-dir "typelisp fs test")
            "create temp dir a: ")]
        [dir-b : String
          (expect-ok-string
            (try-create-temp-dir "typelisp fs test")
            "create temp dir b: ")]
        [file-a : String (fs-path-join dir-a "artifact with space.s")]
        [file-b : String (fs-path-join dir-b "cleanup.obj")]
        (begin
          (assert-true
            (not (string-eq dir-a dir-b))
            "temp directories are unique")
          (assert-exists dir-a true "temp dir a exists")
          (assert-exists dir-b true "temp dir b exists")
          (assert-ok-unit
            (try-write-file file-a "assembly")
            "write temp artifact a: ")
          (assert-ok-unit
            (try-write-file file-b "object")
            "write temp artifact b: ")
          (assert-exists file-a true "temp artifact a exists")
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
          42)))))