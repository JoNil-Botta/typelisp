;; scaffold_cli_core.tl - selfhost `typelisp new` / `typelisp init` command logic (#1160).
;;
;; Shared by the retained `scaffold.tl` compatibility/coverage driver and the
;; unified `cli.tl` dispatcher. `new [--lib] <name>` creates a package skeleton
;; in `<name>/`;
;; `init [--lib] <name>` creates the skeleton in the current directory. Both
;; refuse to clobber an existing manifest or entry source.
(import "../stdlib/io.tl")

(import "../stdlib/fs.tl")

(import "../stdlib/string.tl")

;; A package name must be non-empty and contain only name-safe characters
;; (alphanumerics, `-`, `_`): no path separators or whitespace.
(define (scaffold-name-bad-char? [name : String] [idx : i64]) : bool
  (if (>= idx (string-length name))
    false
    (let
      [c : char (string-ref name idx)]
      (if (or
        (or (and (>= c #a') (<= c #z')) (and (>= c #A') (<= c #Z')))
        (or (and (>= c #0') (<= c #9')) (or (= c #-') (= c #_'))))
        (scaffold-name-bad-char? name (+ idx 1))
        true))))

(define (scaffold-name-ok? [name : String]) : bool
  (and (> (string-length name) 0) (not (scaffold-name-bad-char? name 0))))

;; The `typelisp.pkg` manifest text, matching the `(package ...)` form parsed by
;; compiler_load.tl: name, version, kind ("bin"|"staticlib"), and entry path.
(define (scaffold-manifest [name : String] [kind : String] [entry : String]) : String
  (string-append
    "(package (name \""
    (string-append
      name
      (string-append
        "\") (version \"0.1.0\") (kind \""
        (string-append
          kind
          (string-append "\") (entry \"" (string-append entry "\"))\n")))))))

(define (scaffold-bin-source) : String
  "(define (main) : i64\n  0)\n")

(define (scaffold-lib-source) : String
  "(define (answer) : i64\n  42)\n")

(define (scaffold-try-mkdir [path : String]) : ResultIoUnit
  (try-mkdir (& path)))

(define (scaffold-try-write-file [path : String] [contents : String]) : ResultIoUnit
  (try-write-file (& path) (& contents)))

;; Create a directory, treating an already-existing one as success. A genuine
;; create failure is an error.
(define (scaffold-ensure-dir [path : String]) : ResultIoUnit
  (match (scaffold-try-mkdir path)
    [(OkIoUnit) OkIoUnit]
    [(ErrIoUnit _)
      (if (file-exists? path)
        OkIoUnit
        (scaffold-try-mkdir path))]))

;; Write `contents` to `path`, refusing to overwrite an existing file.
(define (scaffold-write-new [path : String] [contents : String]) : i64
  (if (file-exists? path)
    (begin
      (print-error
        (string-append
          "scaffold: refusing to overwrite existing file: "
          (string-append path "\n")))
      1)
    (match (scaffold-try-write-file path contents)
      [(OkIoUnit) 0]
      [(ErrIoUnit _)
        (begin
          (print-error
            (string-append
              "scaffold: could not write "
              (string-append path "\n")))
          1)])))

;; Create `root/src/`, then write the manifest and entry source.
(define (scaffold-emit [root : String] [name : String] [is-lib : bool]) : i64
  (let
    [kind : String
      (if is-lib
        "staticlib"
        "bin")]
    [entry : String
      (if is-lib
        "src/lib.tl"
        "src/main.tl")]
    [src-dir : String (string-append root "/src")]
    [pkg-path : String (string-append root "/typelisp.pkg")]
    [src-path : String (string-append root (string-append "/" entry))]
    [source : String
      (if is-lib
        (scaffold-lib-source)
        (scaffold-bin-source))]
    (match (scaffold-ensure-dir src-dir)
      [(ErrIoUnit _)
        (begin
          (print-error
            (string-append
              "scaffold: could not create directory "
              (string-append src-dir "\n")))
          1)]
      [(OkIoUnit)
        (let
          [pkg-code : i64
            (scaffold-write-new pkg-path (scaffold-manifest name kind entry))]
          (if (= pkg-code 0)
            (let
              [src-code : i64 (scaffold-write-new src-path source)]
              (if (= src-code 0)
                (begin
                  (print-string
                    (string-append
                      "scaffold: created "
                      (string-append
                        kind
                        (string-append " package " (string-append name "\n")))))
                  0)
                src-code))
            pkg-code))])))

(define (scaffold-new [name : String] [is-lib : bool]) : i64
  (if (not (scaffold-name-ok? name))
    (begin
      (print-error
        (string-append
          "scaffold: invalid package name: "
          (string-append name "\n")))
      2)
    (match (scaffold-ensure-dir name)
      [(ErrIoUnit _)
        (begin
          (print-error
            (string-append
              "scaffold: could not create directory "
              (string-append name "\n")))
          1)]
      [(OkIoUnit) (scaffold-emit name name is-lib)])))

(define (scaffold-init [name : String] [is-lib : bool]) : i64
  (if (not (scaffold-name-ok? name))
    (begin
      (print-error
        (string-append
          "scaffold: invalid package name: "
          (string-append name "\n")))
      2)
    (scaffold-emit "." name is-lib)))

(define (scaffold-usage) : i64
  (begin
    (print-error "scaffold: usage: (new|init) [--lib] <name>\n")
    2))

;; Parse `[--lib] <name>` from argv starting at `idx`, bounded by `count`, then
;; dispatch to `new` or `init`.
(define (scaffold-dispatch-from
  [is-init : bool]
  [idx : i64]
  [count : i64]
  [is-lib : bool]) : i64
  (if (>= idx count)
    (scaffold-usage)
    (let
      [current : String (arg idx)]
      (if (string-eq current "--lib")
        (scaffold-dispatch-from is-init (+ idx 1) count true)
        (if (= (+ idx 1) count)
          (if is-init
            (scaffold-init current is-lib)
            (scaffold-new current is-lib))
          (scaffold-usage))))))

(define (scaffold-new-run-from [start : i64] [count : i64]) : i64
  (scaffold-dispatch-from false start count false))

(define (scaffold-init-run-from [start : i64] [count : i64]) : i64
  (scaffold-dispatch-from true start count false))

(define (scaffold-run-from [command-idx : i64] [count : i64]) : i64
  (if (>= command-idx count)
    (scaffold-usage)
    (let
      [command : String (arg command-idx)]
      (if (string-eq command "new")
        (scaffold-new-run-from (+ command-idx 1) count)
        (if (string-eq command "init")
          (scaffold-init-run-from (+ command-idx 1) count)
          (scaffold-usage))))))