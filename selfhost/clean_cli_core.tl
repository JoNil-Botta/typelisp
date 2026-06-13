;; clean_cli_core.tl - Selfhost clean command logic (#1643).
;;
;; Removes deterministic TypeLisp build artifacts without walking arbitrary
;; directories. Source-file cleanup targets default source-adjacent outputs;
;; package cleanup targets the manifest's package output directory.
(import "../stdlib/fs.tl")

(import "../stdlib/io.tl")

(import "build_cli_core.tl")

(import "../stdlib/string.tl")

(import "../stdlib/str_cat.tl")

(defenum CleanConfig
  (CleanSourceConfig String bool)
  (CleanPackageConfig String bool bool))

(defenum ResultCleanConfig
  (OkCleanConfig CleanConfig)
  (ErrCleanConfig String))

(define (clean-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (clean-string-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let
          [i : i64 0]
          [ok : bool true]
          (begin
            (while (and ok (< i prefix-len))
              (if (= (string-ref text (+ start i)) (string-ref prefix i))
                (set! i (+ i 1))
                (set! ok false)))
            ok))))))

(define (clean-string-prefix? [text : String] [prefix : String]) : bool
  (clean-string-prefix-at? text prefix 0))

(define (clean-string-contains? [text : String] [needle : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [needle-len : i64 (string-length needle)]
    (if (= needle-len 0)
      true
      (if (> needle-len text-len)
        false
        (let
          [i : i64 0]
          [found : bool false]
          (begin
            (while (and (not found) (<= i (- text-len needle-len)))
              (if (clean-string-prefix-at? text needle i)
                (set! found true)
                (set! i (+ i 1))))
            found))))))

(define (clean-string-suffix? [text : String] [suffix : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [suffix-len : i64 (string-length suffix)]
    (if (> suffix-len text-len)
      false
      (string-eq (substring text (- text-len suffix-len) suffix-len) suffix))))

(define (clean-vcs-metadata-path? [path : String]) : bool
  (or
    (string-eq path ".git")
    (clean-string-prefix? path ".git/")
    (clean-string-prefix? path ".git\\")
    (clean-string-contains? path "/.git/")
    (clean-string-contains? path "\\.git\\")
    (clean-string-suffix? path "/.git")
    (clean-string-suffix? path "\\.git")))

(define (clean-dangerous-path? [path : String]) : bool
  (or
    (= (string-length path) 0)
    (string-eq path ".")
    (string-eq path "..")
    (string-eq path "/")
    (string-eq path "\\")
    (clean-vcs-metadata-path? path)))

(define (clean-file-exists? [path : String]) : bool
  (match (source-tool-try-file-exists? path)
    [(OkIoBool exists) exists]
    [(ErrIoBool _) false]))

(define (clean-report [dry-run : bool] [path : String]) : unit
  (print-string
    (string-append
      (if dry-run
        "Would remove: "
        "Removed: ")
      (string-append path "\n"))))

(define (clean-remove-file [dry-run : bool] [path : String]) : i64
  (if (clean-file-exists? path)
    (if dry-run
      (begin
        (clean-report true path)
        0)
      (match (source-tool-try-remove-file-if-exists path)
        [(OkIoUnit)
          (begin
            (clean-report false path)
            0)]
        [(ErrIoUnit error)
          (begin
            (print-error
              (str-cat
                "clean: failed to remove file "
                path
                (string-append ": " (io-error-message error))))
            1)]))
    0))

(define (clean-remove-dir [dry-run : bool] [path : String]) : i64
  (if (clean-file-exists? path)
    (if dry-run
      (begin
        (clean-report true path)
        0)
      (match (source-tool-try-remove-dir-if-exists path)
        [(OkIoUnit)
          (begin
            (clean-report false path)
            0)]
        [(ErrIoUnit error)
          (begin
            (print-error
              (str-cat
                "clean: failed to remove directory "
                path
                (string-append ": " (io-error-message error))))
            1)]))
    0))

(define (clean-merge-status [left : i64] [right : i64]) : i64
  (if (= left 0)
    right
    left))

(define (clean-source-artifact-safe? [source : String] [path : String]) : bool
  (and
    (not (clean-dangerous-path? path))
    (not (string-eq source path))
    (not (clean-string-suffix? path ".tl"))))

(define (clean-remove-source-artifact
  [source : String]
  [dry-run : bool]
  [path : String]) : i64
  (if (clean-source-artifact-safe? source path)
    (clean-remove-file dry-run path)
    0))

(define (clean-source [source : String] [dry-run : bool]) : i64
  (let
    [status : i64 0]
    (begin
      (set!
        status
        (clean-merge-status
          status
          (clean-remove-source-artifact
            source
            dry-run
            (source-tool-replace-extension source ".s"))))
      (set!
        status
        (clean-merge-status
          status
          (clean-remove-source-artifact
            source
            dry-run
            (source-tool-replace-extension source ".ir"))))
      (set!
        status
        (clean-merge-status
          status
          (clean-remove-source-artifact
            source
            dry-run
            (source-tool-replace-extension source ".o"))))
      (set!
        status
        (clean-merge-status
          status
          (clean-remove-source-artifact
            source
            dry-run
            (source-tool-replace-extension source ".obj"))))
      (set!
        status
        (clean-merge-status
          status
          (clean-remove-source-artifact
            source
            dry-run
            (source-tool-replace-extension source ""))))
      (set!
        status
        (clean-merge-status
          status
          (clean-remove-source-artifact
            source
            dry-run
            (source-tool-replace-extension source ".exe"))))
      status)))

(define (clean-package-name-safe? [name : String]) : bool
  (and
    (compiler-load-package-token-valid? name)
    (not (clean-string-contains? name "/"))
    (not (clean-string-contains? name "\\"))))

(define (clean-package-artifact-safe?
  [manifest-dir : String]
  [name : String]
  [path : String]) : bool
  (let
    [output-dir : String (build-package-output-dir manifest-dir name)]
    [output-prefix : String (string-append output-dir "/")]
    (and
      (not (clean-dangerous-path? path))
      (or (string-eq path output-dir) (clean-string-prefix? path output-prefix)))))

(define (clean-remove-package-file
  [manifest-dir : String]
  [name : String]
  [dry-run : bool]
  [path : String]) : i64
  (if (clean-package-artifact-safe? manifest-dir name path)
    (clean-remove-file dry-run path)
    (begin
      (print-error (str-cat "clean: refusing unsafe artifact path " path ""))
      1)))

(define (clean-remove-package-dir
  [manifest-dir : String]
  [name : String]
  [dry-run : bool]
  [path : String]) : i64
  (if (clean-package-artifact-safe? manifest-dir name path)
    (clean-remove-dir dry-run path)
    (begin
      (print-error (str-cat "clean: refusing unsafe artifact path " path ""))
      1)))

(define (clean-package-from-path [manifest-path : String] [dry-run : bool]) : i64
  (match (build-load-manifest manifest-path)
    [(ErrBuildManifest message)
      (begin
        (print-error (string-append "Error: " message))
        1)]
    [(OkBuildManifest manifest)
      (let
        [manifest-dir : String (compiler-load-dirname manifest-path)]
        [name : String (struct-get manifest name)]
        [status : i64 0]
        (if (not (clean-package-name-safe? name))
          (begin
            (print-error
              (str-cat "clean: refusing unsafe package name " name ""))
            1)
          (begin
            (set!
              status
              (clean-merge-status
                status
                (clean-remove-package-file
                  manifest-dir
                  name
                  dry-run
                  (build-package-asm-path manifest-dir name))))
            (set!
              status
              (clean-merge-status
                status
                (clean-remove-package-file
                  manifest-dir
                  name
                  dry-run
                  (build-package-obj-path
                    manifest-dir
                    name
                    (BackendTargetLinux)))))
            (set!
              status
              (clean-merge-status
                status
                (clean-remove-package-file
                  manifest-dir
                  name
                  dry-run
                  (build-package-obj-path
                    manifest-dir
                    name
                    (BackendTargetWindows)))))
            (set!
              status
              (clean-merge-status
                status
                (clean-remove-package-file
                  manifest-dir
                  name
                  dry-run
                  (build-package-bin-path
                    manifest-dir
                    name
                    (BackendTargetLinux)))))
            (set!
              status
              (clean-merge-status
                status
                (clean-remove-package-file
                  manifest-dir
                  name
                  dry-run
                  (build-package-bin-path
                    manifest-dir
                    name
                    (BackendTargetWindows)))))
            (set!
              status
              (clean-merge-status
                status
                (clean-remove-package-file
                  manifest-dir
                  name
                  dry-run
                  (build-package-lib-path
                    manifest-dir
                    name
                    (BackendTargetLinux)))))
            (set!
              status
              (clean-merge-status
                status
                (clean-remove-package-file
                  manifest-dir
                  name
                  dry-run
                  (build-package-lib-path
                    manifest-dir
                    name
                    (BackendTargetWindows)))))
            (set!
              status
              (clean-merge-status
                status
                (clean-remove-package-dir
                  manifest-dir
                  name
                  dry-run
                  (build-package-output-dir manifest-dir name))))
            status)))]))

(define (clean-package
  [manifest-path : String]
  [has-manifest : bool]
  [dry-run : bool]) : i64
  (let
    [resolved-manifest : CompilerLoadMaybePath
      (if has-manifest
        (CompilerLoadSomePath manifest-path)
        (build-discover-manifest-up "" 256))]
    (match resolved-manifest
      [(CompilerLoadNoPath)
        (begin
          (print-error
            "clean: could not find typelisp.pkg from '.' or any parent directory")
          1)]
      [(CompilerLoadSomePath path) (clean-package-from-path path dry-run)])))

(define (clean-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [has-source : bool]
  [manifest : String]
  [has-manifest : bool]
  [dry-run : bool]) : ResultCleanConfig
  (if (>= idx count)
    (begin
      (when
        (and has-source has-manifest)
        (return
          (ErrCleanConfig
            "clean: cannot combine a source file with --manifest-path")))
      (if has-source
        (OkCleanConfig (CleanSourceConfig source dry-run))
        (OkCleanConfig (CleanPackageConfig manifest has-manifest dry-run))))
    (let
      [current : String (arg idx)]
      (cond
        (string-eq current "--dry-run")
        (clean-parse-options
          (+ idx 1)
          count
          source
          has-source
          manifest
          has-manifest
          true)
        (string-eq current "--manifest-path")
        (if (>= (+ idx 1) count)
          (ErrCleanConfig "clean: --manifest-path requires a value")
          (if has-manifest
            (ErrCleanConfig
              "clean: --manifest-path was provided more than once")
            (clean-parse-options
              (+ idx 2)
              count
              source
              has-source
              (arg (+ idx 1))
              true
              dry-run)))
        (clean-flag? current)
        (ErrCleanConfig (string-append "clean: unknown flag " current))
        has-source
        (ErrCleanConfig "clean: accepts only one source file")
        (clean-parse-options
          (+ idx 1)
          count
          current
          true
          manifest
          has-manifest
          dry-run)))))

(define (clean-config-from [idx : i64] [count : i64]) : ResultCleanConfig
  (clean-parse-options idx count "" false "" false false))

(define (clean-run-from [idx : i64] [count : i64]) : i64
  (match (clean-config-from idx count)
    [(OkCleanConfig config)
      (match config
        [(CleanSourceConfig source dry-run) (clean-source source dry-run)]
        [(CleanPackageConfig manifest has-manifest dry-run)
          (clean-package manifest has-manifest dry-run)])]
    [(ErrCleanConfig message)
      (begin
        (print-error message)
        1)]))