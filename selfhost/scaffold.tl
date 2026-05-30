;; scaffold.tl - selfhost `typelisp new` / `typelisp init` driver (#1160).
;;
;; `new [--lib] <name>` creates a buildable package skeleton in a new `<name>/`
;; directory: a `typelisp.pkg` manifest (with `kind` "bin" by default or "lib"
;; with `--lib`) and a minimal entry source (`src/main.tl` or `src/lib.tl`).
;; `init [--lib] <name>` scaffolds the manifest + entry source in the *current*
;; directory instead of a new one. Both refuse to clobber an existing manifest
;; or entry source.
;;
;; The public `typelisp new`/`init` subcommands route here (main.rs runs this as a
;; program through selfhost/run.tl so its host file I/O executes inline); it can
;; also be invoked directly:
;;   typelisp run selfhost/scaffold.tl -- new [--lib] <name>
;;   typelisp run selfhost/scaffold.tl -- init [--lib] <name>
(import "../stdlib/fs.tl")

;; A package name must be non-empty and contain only name-safe characters
;; (alphanumerics, `-`, `_`) — no path separators or whitespace, so `new <name>`
;; cannot escape the working directory.
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

;; The `typelisp.pkg` manifest text, matching the `(package …)` form parsed by
;; compiler_load.tl: name, version, kind ("bin"|"lib"), and entry path.
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

;; Create a directory, treating an already-existing one as success (so `init`
;; can reuse the current directory). A genuine create failure is an error.
(define (scaffold-ensure-dir [path : String]) : ResultIoUnit
  (match (try-mkdir path)
    [(OkIoUnit) OkIoUnit]
    ;; A pre-existing directory is fine; surface other failures.
    [(ErrIoUnit _)
      (if (file-exists? path)
        OkIoUnit
        (try-mkdir path))]))

;; Write `contents` to `path`, refusing to overwrite an existing file.
(define (scaffold-write-new [path : String] [contents : String]) : i64
  (if (file-exists? path)
    (begin
      (print-error
        (string-append
          "scaffold: refusing to overwrite existing file: "
          (string-append path "\n")))
      1)
    (match (try-write-file path contents)
      [(OkIoUnit) 0]
      [(ErrIoUnit _)
        (begin
          (print-error
            (string-append
              "scaffold: could not write "
              (string-append path "\n")))
          1)])))

;; Create `root/src/` (root is "." for `init`), then write the manifest and the
;; entry source, refusing to clobber either. Returns a process exit code.
(define (scaffold-emit [root : String] [name : String] [is-lib : bool]) : i64
  (let
    [kind : String
      (if is-lib
        "lib"
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

;; `new [--lib] <name>`: create the `<name>/` directory then scaffold into it.
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

;; `init [--lib] <name>`: scaffold into the current directory (named `name`).
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

;; Parse `[--lib] <name>` from argv starting at `idx`, then dispatch to `run`.
(define (scaffold-dispatch [is-init : bool] [idx : i64] [is-lib : bool]) : i64
  (if (>= idx (arg-count))
    (scaffold-usage)
    (let
      [current : String (arg idx)]
      (if (string-eq current "--lib")
        (scaffold-dispatch is-init (+ idx 1) true)
        (if (= (+ idx 1) (arg-count))
          (if is-init
            (scaffold-init current is-lib)
            (scaffold-new current is-lib))
          (scaffold-usage))))))

;; Run as a program (via `typelisp run` or the `typelisp new|init` routing), so
;; argv is `[<prog>, <command>, <args>…]`: the command word is arg 1 and its
;; arguments start at arg 2.
(define (main) : i64
  (if (< (arg-count) 2)
    (scaffold-usage)
    (let
      [command : String (arg 1)]
      (if (string-eq command "new")
        (scaffold-dispatch false 2 false)
        (if (string-eq command "init")
          (scaffold-dispatch true 2 false)
          (scaffold-usage))))))