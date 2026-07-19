;; clean_cli_core.tl - Selfhost clean command logic.
;;
;; Removes deterministic TypeLisp build artifacts and the dedicated ad-hoc
;; experiment subtree. Source-file cleanup targets default source-adjacent
;; outputs; package cleanup targets the manifest's package output directory;
;; experiment cleanup is constrained to the manifest's target/exp directory.
(import stdlib.io)
(import stdlib.fs)
(import "build_cli_core.tl")
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

(defenum CleanConfig
  (Source String bool)
  (Package String bool bool)
  (Experiments String bool bool))

(defenum ResultCleanConfig
  (Ok CleanConfig)
  (Err String))

(define (clean-flag? [value : String]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (clean-string-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [prefix-len : i64 (string.string-length prefix)]
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let
          [i : i64 0]
          [ok : bool true]
          (begin
            (while (and ok (< i prefix-len))
              (if (=
                (string.string-ref text (+ start i))
                (string.string-ref prefix i))
                (set! i (+ i 1))
                (set! ok false)))
            ok))))))

(define (clean-string-prefix? [text : String] [prefix : String]) : bool
  (clean-string-prefix-at? text prefix 0))

(define (clean-string-contains? [text : String] [needle : String]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [needle-len : i64 (string.string-length needle)]
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
    [text-len : i64 (string.string-length text)]
    [suffix-len : i64 (string.string-length suffix)]
    (if (> suffix-len text-len)
      false
      (string.eq
        (string.substring text (- text-len suffix-len) suffix-len)
        suffix))))

(define (clean-vcs-metadata-path? [path : String]) : bool
  (or
    (string.eq path ".git")
    (clean-string-prefix? path ".git/")
    (clean-string-prefix? path ".git\\")
    (clean-string-contains? path "/.git/")
    (clean-string-contains? path "\\.git\\")
    (clean-string-suffix? path "/.git")
    (clean-string-suffix? path "\\.git")))

(define (clean-dangerous-path? [path : String]) : bool
  (or
    (= (string.string-length path) 0)
    (string.eq path ".")
    (string.eq path "..")
    (string.eq path "/")
    (string.eq path "\\")
    (clean-vcs-metadata-path? path)))

(define (clean-file-exists? [path : String]) : bool
  (match (source-tool-try-file-exists? path)
    [(io.OkIoBool exists) exists]
    [(io.ErrIoBool _) false]))

(define (clean-report [dry-run : bool] [path : String]) : unit
  (io.print-string
    (str_cat.str-cat
      (if dry-run
        "Would remove: "
        "Removed: ")
      path
      "\n")))

(define (clean-remove-file [dry-run : bool] [path : String]) : i64
  (if (clean-file-exists? path)
    (if dry-run
      (begin
        (clean-report true path)
        0)
      (match (source-tool-try-remove-file-if-exists path)
        [(io.OkIoUnit)
          (begin
            (clean-report false path)
            0)]
        [(io.ErrIoUnit error)
          (begin
            (io.print-error
              (str_cat.str-cat
                "clean: failed to remove file "
                path
                ": "
                (io.error-message error)))
            1)]))
    0))

(define (clean-remove-dir [dry-run : bool] [path : String]) : i64
  (if (clean-file-exists? path)
    (if dry-run
      (begin
        (clean-report true path)
        0)
      (match (source-tool-try-remove-dir-if-exists path)
        [(io.OkIoUnit)
          (begin
            (clean-report false path)
            0)]
        [(io.ErrIoUnit error)
          (begin
            (io.print-error
              (str_cat.str-cat
                "clean: failed to remove directory "
                path
                ": "
                (io.error-message error)))
            1)]))
    0))

(define (clean-report-error
  [prefix : String]
  [path : String]
  [error : io.IoError]) : i64
  (begin
    (io.print-error (str_cat.str-cat prefix path ": " (io.error-message error)))
    1))

(define (clean-remove-tree-entry [path : String]) : i64
  (if (clean-vcs-metadata-path? path)
    (begin
      (io.print-error
        (str_cat.str-cat "clean: refusing VCS metadata path " path ""))
      1)
    (match (fs.try-file-kind-no-follow (& path))
      [(fs.ErrFsFileKind error)
        (clean-report-error "clean: failed to inspect " path error)]
      [(fs.OkFsFileKind kind)
        (cond
          [(fs.file-kind-directory? kind) (clean-remove-tree-dir path)]
          [(fs.file-kind-regular? kind)
            (match (source-tool-try-remove-file-if-exists path)
              [(io.OkIoUnit) 0]
              [(io.ErrIoUnit error)
                (clean-report-error "clean: failed to remove file " path error)])]
          [else
            (begin
              (io.print-error
                (str_cat.str-cat
                  "clean: refusing symbolic link or special filesystem node "
                  path
                  ""))
              1)])])))

(define (clean-remove-tree-entries
  [root : String]
  [entries : fs.FsStringVector]
  [index : i64]) : i64
  (if (>= index (fs.string-vector-len (& entries)))
    0
    (let
      [name : String (fs.string-vector-get (& entries) index "")]
      [path : String (fs.path-join (& root) (& name))]
      [status : i64 (clean-remove-tree-entry path)]
      (if (= status 0)
        (clean-remove-tree-entries root entries (+ index 1))
        status))))

(define (clean-remove-tree-dir [path : String]) : i64
  (match (fs.try-read-dir (& path))
    [(fs.ErrIoStringVector error)
      (clean-report-error "clean: failed to read directory " path error)]
    [(fs.OkIoStringVector entries)
      (let
        [status : i64 (clean-remove-tree-entries path entries 0)]
        (if (not (= status 0))
          status
          (match (source-tool-try-remove-dir-if-exists path)
            [(io.OkIoUnit) 0]
            [(io.ErrIoUnit error)
              (clean-report-error
                "clean: failed to remove directory "
                path
                error)])))]))

(define (clean-remove-tree [dry-run : bool] [path : String]) : i64
  (if (not (clean-file-exists? path))
    0
    (if dry-run
      (begin
        (clean-report true path)
        0)
      (let
        [status : i64 (clean-remove-tree-entry path)]
        (if (= status 0)
          (begin
            (clean-report false path)
            0)
          status)))))

(define (clean-merge-status [left : i64] [right : i64]) : i64
  (if (= left 0)
    right
    left))

(define (clean-source-artifact-safe? [source : String] [path : String]) : bool
  (and
    (not (clean-dangerous-path? path))
    (not (string.eq source path))
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
    [output-prefix : String (string.append output-dir "/")]
    (and
      (not (clean-dangerous-path? path))
      (or (string.eq path output-dir) (clean-string-prefix? path output-prefix)))))

(define (clean-remove-package-file
  [manifest-dir : String]
  [name : String]
  [dry-run : bool]
  [path : String]) : i64
  (if (clean-package-artifact-safe? manifest-dir name path)
    (clean-remove-file dry-run path)
    (begin
      (io.print-error
        (str_cat.str-cat "clean: refusing unsafe artifact path " path ""))
      1)))

(define (clean-remove-package-dir
  [manifest-dir : String]
  [name : String]
  [dry-run : bool]
  [path : String]) : i64
  (if (clean-package-artifact-safe? manifest-dir name path)
    (clean-remove-dir dry-run path)
    (begin
      (io.print-error
        (str_cat.str-cat "clean: refusing unsafe artifact path " path ""))
      1)))

(define (clean-package-from-path [manifest-path : String] [dry-run : bool]) : i64
  (match (build-load-manifest manifest-path)
    [(ResultBuildManifest.Err message)
      (begin
        (io.print-error (string.append "Error: " message))
        1)]
    [(ResultBuildManifest.Ok manifest)
      (let
        [manifest-dir : String (compiler-load-dirname manifest-path)]
        [name : String (struct-get manifest name)]
        [status : i64 0]
        (if (not (clean-package-name-safe? name))
          (begin
            (io.print-error
              (str_cat.str-cat "clean: refusing unsafe package name " name ""))
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
                    (CompilerBackendTarget.Linux)))))
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
                    (CompilerBackendTarget.Windows)))))
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
                    (CompilerBackendTarget.Linux)))))
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
                    (CompilerBackendTarget.Windows)))))
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
                    (CompilerBackendTarget.Linux)))))
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
                    (CompilerBackendTarget.Windows)))))
            (set!
              status
              (clean-merge-status
                status
                (clean-remove-package-file
                  manifest-dir
                  name
                  dry-run
                  (build-package-tlci-path manifest-dir name))))
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
          (io.print-error
            "clean: could not find typelisp.pkg from '.' or any parent directory")
          1)]
      [(CompilerLoadSomePath path) (clean-package-from-path path dry-run)])))

(define (clean-experiments-artifact-path [manifest-path : String]) : String
  (compiler-load-normalize-path
    (compiler-load-join-root-path
      (compiler-load-dirname manifest-path)
      "target/exp")))

(define (clean-experiments-artifact-safe?
  [manifest-path : String]
  [path : String]) : bool
  (let
    [expected : String (clean-experiments-artifact-path manifest-path)]
    [normalized : String (compiler-load-normalize-path path)]
    (and
      (not (clean-dangerous-path? normalized))
      (string.eq normalized expected)
      (or
        (string.eq expected "target/exp")
        (clean-string-suffix? expected "/target/exp")
        (clean-string-suffix? expected "\\target\\exp")))))

(define (clean-experiments-from-path [manifest-path : String] [dry-run : bool]) : i64
  (match (build-load-manifest manifest-path)
    [(ResultBuildManifest.Err message)
      (begin
        (io.print-error (string.append "Error: " message))
        1)]
    [(ResultBuildManifest.Ok _)
      (let
        [path : String (clean-experiments-artifact-path manifest-path)]
        (if (clean-experiments-artifact-safe? manifest-path path)
          (clean-remove-tree dry-run path)
          (begin
            (io.print-error
              (str_cat.str-cat
                "clean: refusing unsafe experiment artifact path "
                path
                ""))
            1)))]))

(define (clean-experiments
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
          (io.print-error
            "clean: could not find typelisp.pkg from '.' or any parent directory")
          1)]
      [(CompilerLoadSomePath path) (clean-experiments-from-path path dry-run)])))

(define (clean-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [has-source : bool]
  [manifest : String]
  [has-manifest : bool]
  [experiments : bool]
  [dry-run : bool]) : ResultCleanConfig
  (if (>= idx count)
    (begin
      (when
        (and has-source has-manifest)
        (return
          (ResultCleanConfig.Err
            "clean: cannot combine a source file with --manifest-path")))
      (when
        (and has-source experiments)
        (return
          (ResultCleanConfig.Err
            "clean: cannot combine a source file with --experiments")))
      (cond
        [has-source (ResultCleanConfig.Ok (CleanConfig.Source source dry-run))]
        [experiments
          (ResultCleanConfig.Ok
            (CleanConfig.Experiments manifest has-manifest dry-run))]
        [else
          (ResultCleanConfig.Ok
            (CleanConfig.Package manifest has-manifest dry-run))]))
    (let
      [current : String (io.arg idx)]
      (cond
        [(string.eq current "--dry-run")
          (clean-parse-options
            (+ idx 1)
            count
            source
            has-source
            manifest
            has-manifest
            experiments
            true)]
        [(string.eq current "--experiments")
          (if experiments
            (ResultCleanConfig.Err
              "clean: --experiments was provided more than once")
            (clean-parse-options
              (+ idx 1)
              count
              source
              has-source
              manifest
              has-manifest
              true
              dry-run))]
        [(string.eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ResultCleanConfig.Err "clean: --manifest-path requires a value")
            (if has-manifest
              (ResultCleanConfig.Err
                "clean: --manifest-path was provided more than once")
              (clean-parse-options
                (+ idx 2)
                count
                source
                has-source
                (io.arg (+ idx 1))
                true
                experiments
                dry-run)))]
        [(clean-flag? current)
          (ResultCleanConfig.Err (string.append "clean: unknown flag " current))]
        [has-source
          (ResultCleanConfig.Err "clean: accepts only one source file")]
        [else
          (clean-parse-options
            (+ idx 1)
            count
            current
            true
            manifest
            has-manifest
            experiments
            dry-run)]))))

(define (clean-config-from [idx : i64] [count : i64]) : ResultCleanConfig
  (clean-parse-options idx count "" false "" false false false))

(define (clean-run-from [idx : i64] [count : i64]) : i64
  (match (clean-config-from idx count)
    [(ResultCleanConfig.Ok config)
      (match config
        [(CleanConfig.Source source dry-run) (clean-source source dry-run)]
        [(CleanConfig.Package manifest has-manifest dry-run)
          (clean-package manifest has-manifest dry-run)]
        [(CleanConfig.Experiments manifest has-manifest dry-run)
          (clean-experiments manifest has-manifest dry-run)])]
    [(ResultCleanConfig.Err message)
      (begin
        (io.print-error message)
        1)]))