;; doc_cli_core.tl - Selfhost doc command logic.
;;
;; Usage through the current compiler runner:
;;   typelisp run selfhost/cli.tl -- doc input.tl output.md
;;   typelisp run selfhost/cli.tl -- doc entry.tl imported.tl output.md
;;   typelisp run selfhost/cli.tl -- doc --html input.tl output.html
;;   typelisp run selfhost/cli.tl -- doc --html entry.tl imported.tl output.html
;;   typelisp run selfhost/cli.tl -- doc --test input.tl
;;   typelisp run selfhost/cli.tl -- doc --load input.tl output.md [--stdlib-root <dir>...]
(import "../stdlib/io.tl")

(import "../stdlib/list.tl")

(import "doc_render.tl")

(import "doc_html.tl")

(import "doc_test.tl")

(import "compiler_load.tl")

(import "package_source_core.tl")

(defenum DocMaybeString
  (DocNoString)
  (DocSomeString String))

(defenum DocTestPathList
  (DocTestPathNil)
  (DocTestPathCons String (Box DocTestPathList)))

(defenum DocTestCliConfig
  (DocTestCliFileConfig DocTestPathList StringVec)
  (DocTestCliPackageConfig String bool StringVec))

(defenum ResultDocTestCliConfig
  (OkDocTestCliConfig DocTestCliConfig)
  (ErrDocTestCliConfig String))

(defenum DocDefaultCliConfig
  (DocDefaultCliExplicitConfig DocTestPathList DocMaybeString StringVec)
  (DocDefaultCliPackageConfig String bool String))

(defenum ResultDocDefaultCliConfig
  (OkDocDefaultCliConfig DocDefaultCliConfig)
  (ErrDocDefaultCliConfig String))

(define (doc-print-generated [output-path : String]) : unit
  (print-string (string-append "Generated: " (string-append output-path "\n"))))

(define (doc-generate-file [input-path : String] [output-path : String]) : i64
  (let
    [source : String (read-file input-path)]
    [markdown : String (doc-render-markdown (doc-extract-source source))]
    (begin
      (write-file output-path markdown)
      (doc-print-generated output-path)
      0)))

(define (doc-cli-module-cons [module : DocModule] [rest : DocModuleList]) : DocModuleList
  (DocModuleCons module (box rest)))

(define (doc-read-modules [idx : i64] [end : i64]) : DocModuleList
  (if (>= idx end)
    DocModuleNil
    (doc-cli-module-cons
      (DocModule (arg idx) (doc-extract-file (arg idx)))
      (doc-read-modules (+ idx 1) end))))

(define (doc-module-list-count [modules : DocModuleList]) : i64
  (match modules
    [(DocModuleNil) 0]
    [(DocModuleCons _ rest) (+ 1 (doc-module-list-count (box-get rest)))]))

(define (doc-modules-from-string-list [paths : StringList]) : DocModuleList
  (match paths
    [(StringNil) DocModuleNil]
    [(StringCons path rest)
      (doc-cli-module-cons
        (DocModule path (doc-extract-file path))
        (doc-modules-from-string-list (box-get rest)))]))

(define (doc-modules-from-paths [paths : AstDeclPathList] [seen : SymI64Env]) : DocModuleList
  (match paths
    [(AstDeclPathNil) DocModuleNil]
    [(AstDeclPathCons path rest)
      (let
        [rest : AstDeclPathList (box-get rest)]
        (if (sym-i64-contains seen path)
          (doc-modules-from-paths rest seen)
          (doc-cli-module-cons
            (DocModule path (doc-extract-file path))
            (doc-modules-from-paths rest (sym-i64-bind seen path 1)))))]))

(define (doc-render-loaded-markdown
  [input-path : String]
  [paths : AstDeclPathList]) : String
  (let
    [modules : DocModuleList
      (doc-modules-from-paths
        (ast-decl-path-cons input-path paths)
        (sym-i64-empty))]
    (if (> (doc-module-list-count modules) 1)
      (doc-render-module-graph-markdown modules)
      (doc-render-markdown (doc-extract-file input-path)))))

(define (doc-generate-loaded-file
  [input-path : String]
  [output-path : String]
  [stdlib-roots : StringVec]) : i64
  (match (compiler-load-file-with-paths-and-roots
    input-path
    (sym-i64-empty)
    stdlib-roots)
    [(OkCompilerLoadWithPaths _ paths _ _)
      (begin
        (write-file output-path (doc-render-loaded-markdown input-path paths))
        (doc-print-generated output-path)
        0)]
    [(ErrCompilerLoadWithPaths diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (doc-generate-package
  [manifest-path : String]
  [has-manifest : bool]
  [output-path : String]) : i64
  (match (package-source-discover-for "doc" manifest-path has-manifest)
    [(ErrPackageSourceSet message)
      (begin
        (print-error (string-append message "\n"))
        1)]
    [(OkPackageSourceSet source-set)
      (begin
        (write-file
          output-path
          (doc-render-module-graph-markdown
            (doc-modules-from-string-list (struct-get source-set sources))))
        (doc-print-generated output-path)
        0)]))

(define (doc-generate-html-file [input-path : String] [output-path : String]) : i64
  (let
    [source : String (read-file input-path)]
    [html : String (doc-html-render-source input-path source)]
    (begin
      (write-file output-path html)
      (doc-print-generated output-path)
      0)))

(define (doc-generate-html-module-graph [output-path : String]) : i64
  (let
    [modules : DocModuleList (doc-read-modules 2 (- (arg-count) 1))]
    (begin
      (write-file output-path (doc-html-render-module-graph modules))
      (doc-print-generated output-path)
      0)))

(define (doc-test-file [input-path : String] [stdlib-roots : StringVec]) : i64
  (let
    [report : DocTestRunReport
      (doc-test-run-file-with-roots input-path stdlib-roots)]
    (begin
      (if (doc-test-run-report-ok? report)
        (print-string (string-append (doc-test-run-report-render report) "\n"))
        (print-error (doc-test-run-report-render report)))
      (doc-test-run-report-status report))))

(define (doc-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (doc-stdlib-roots [idx : i64]) : StringVec
  (let
    [i : i64 idx]
    [n : i64 (arg-count)]
    [roots : StringVec (string-vec-new)]
    (begin
      (while (< i n)
        (if (string-eq (arg i) "--stdlib-root")
          (if (< (+ i 1) n)
            (begin
              (set! roots (string-vec-push roots (arg (+ i 1))))
              (set! i (+ i 2)))
            (set! i n))
          (set! i (+ i 1))))
      roots)))

(define (doc-test-path-list-empty? [paths : DocTestPathList]) : bool
  (match paths
    [(DocTestPathNil) true]
    [(DocTestPathCons _ _) false]))

(define (doc-test-path-list-append [paths : DocTestPathList] [path : String]) : DocTestPathList
  (match paths
    [(DocTestPathNil) (DocTestPathCons path (box DocTestPathNil))]
    [(DocTestPathCons head rest)
      (DocTestPathCons
        head
        (box (doc-test-path-list-append (box-get rest) path)))]))

(define (doc-test-path-list-count [paths : DocTestPathList]) : i64
  (match paths
    [(DocTestPathNil) 0]
    [(DocTestPathCons _ rest) (+ 1 (doc-test-path-list-count (box-get rest)))]))

(define (doc-test-path-list-first [paths : DocTestPathList]) : String
  (match paths
    [(DocTestPathNil) ""]
    [(DocTestPathCons path _) path]))

(define (doc-test-path-list-second [paths : DocTestPathList]) : String
  (match paths
    [(DocTestPathNil) ""]
    [(DocTestPathCons _ rest) (doc-test-path-list-first (box-get rest))]))

(define (doc-test-path-list-last [paths : DocTestPathList]) : String
  (match paths
    [(DocTestPathNil) ""]
    [(DocTestPathCons path rest)
      (match (box-get rest)
        [(DocTestPathNil) path]
        [_ (doc-test-path-list-last (box-get rest))])]))

(define (doc-modules-from-doc-paths-before-last [paths : DocTestPathList]) : DocModuleList
  (match paths
    [(DocTestPathNil) DocModuleNil]
    [(DocTestPathCons path rest)
      (match (box-get rest)
        [(DocTestPathNil) DocModuleNil]
        [_
          (doc-cli-module-cons
            (DocModule path (doc-extract-file path))
            (doc-modules-from-doc-paths-before-last (box-get rest)))])]))

(define (doc-generate-module-graph-from-doc-paths [paths : DocTestPathList]) : i64
  (let
    [output-path : String (doc-test-path-list-last paths)]
    [modules : DocModuleList (doc-modules-from-doc-paths-before-last paths)]
    (begin
      (write-file output-path (doc-render-module-graph-markdown modules))
      (doc-print-generated output-path)
      0)))

(define (doc-test-config-finish
  [input-paths : DocTestPathList]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : StringVec]) : ResultDocTestCliConfig
  (if (doc-test-path-list-empty? input-paths)
    (OkDocTestCliConfig
      (DocTestCliPackageConfig manifest-path has-manifest stdlib-roots))
    (if has-manifest
      (ErrDocTestCliConfig
        "doc: cannot combine input paths with --manifest-path")
      (OkDocTestCliConfig (DocTestCliFileConfig input-paths stdlib-roots)))))

(define (doc-test-parse-options
  [idx : i64]
  [count : i64]
  [input-paths : DocTestPathList]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : StringVec]) : ResultDocTestCliConfig
  (if (>= idx count)
    (doc-test-config-finish input-paths manifest-path has-manifest stdlib-roots)
    (let
      [current : String (arg idx)]
      (cond
        [(string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrDocTestCliConfig "doc: --stdlib-root requires a value")
            (doc-test-parse-options
              (+ idx 2)
              count
              input-paths
              manifest-path
              has-manifest
              (string-vec-push stdlib-roots (arg (+ idx 1)))))]
        [(string-eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ErrDocTestCliConfig "doc: --manifest-path requires a value")
            (if has-manifest
              (ErrDocTestCliConfig "doc: duplicate --manifest-path")
              (doc-test-parse-options
                (+ idx 2)
                count
                input-paths
                (arg (+ idx 1))
                true
                stdlib-roots)))]
        [(doc-flag? current)
          (ErrDocTestCliConfig (string-append "doc: unknown flag " current))]
        [else
          (doc-test-parse-options
            (+ idx 1)
            count
            (doc-test-path-list-append input-paths current)
            manifest-path
            has-manifest
            stdlib-roots)]))))

(define (doc-test-config-from [base : i64] [count : i64]) : ResultDocTestCliConfig
  (doc-test-parse-options
    (+ base 1)
    count
    DocTestPathNil
    ""
    false
    (string-vec-new)))

(define (doc-test-files
  [input-paths : DocTestPathList]
  [stdlib-roots : StringVec]
  [print-headers : bool]
  [status : i64]) : i64
  (match input-paths
    [(DocTestPathNil) status]
    [(DocTestPathCons input-path rest)
      (let
        [file-status : i64
          (begin
            (if print-headers
              (print-string
                (string-append "--- " (string-append input-path "\n")))
              unit)
            (doc-test-file input-path stdlib-roots))]
        (doc-test-files
          (box-get rest)
          stdlib-roots
          print-headers
          (if (= status 0)
            file-status
            status)))]))

(define (doc-test-package-files
  [input-paths : StringList]
  [stdlib-roots : StringVec]
  [status : i64]) : i64
  (match input-paths
    [(StringNil) status]
    [(StringCons input-path rest)
      (let
        [file-status : i64
          (begin
            (print-string
              (string-append "--- " (string-append input-path "\n")))
            (doc-test-file input-path stdlib-roots))]
        (doc-test-package-files
          (box-get rest)
          stdlib-roots
          (if (= status 0)
            file-status
            status)))]))

(define (doc-test-package
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : StringVec]) : i64
  (match (package-source-discover-for "doc" manifest-path has-manifest)
    [(ErrPackageSourceSet message)
      (begin
        (print-error (string-append message "\n"))
        1)]
    [(OkPackageSourceSet source-set)
      (doc-test-package-files (struct-get source-set sources) stdlib-roots 0)]))

(define (doc-default-config-finish
  [input-paths : DocTestPathList]
  [output-path : DocMaybeString]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : StringVec]) : ResultDocDefaultCliConfig
  (if (doc-test-path-list-empty? input-paths)
    (match output-path
      [(DocSomeString out)
        (OkDocDefaultCliConfig
          (DocDefaultCliPackageConfig manifest-path has-manifest out))]
      [(DocNoString)
        (if has-manifest
          (ErrDocDefaultCliConfig
            "doc: package documentation requires -o <out.md>")
          (ErrDocDefaultCliConfig "doc: expected input and output paths"))])
    (if has-manifest
      (ErrDocDefaultCliConfig
        "doc: cannot combine input paths with --manifest-path")
      (OkDocDefaultCliConfig
        (DocDefaultCliExplicitConfig input-paths output-path stdlib-roots)))))

(define (doc-default-parse-options
  [idx : i64]
  [count : i64]
  [input-paths : DocTestPathList]
  [output-path : DocMaybeString]
  [has-output : bool]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : StringVec]) : ResultDocDefaultCliConfig
  (if (>= idx count)
    (doc-default-config-finish
      input-paths
      output-path
      manifest-path
      has-manifest
      stdlib-roots)
    (let
      [current : String (arg idx)]
      (cond
        [(string-eq current "-o")
          (if (>= (+ idx 1) count)
            (ErrDocDefaultCliConfig "doc: -o requires a value")
            (if has-output
              (ErrDocDefaultCliConfig "doc: duplicate -o")
              (doc-default-parse-options
                (+ idx 2)
                count
                input-paths
                (DocSomeString (arg (+ idx 1)))
                true
                manifest-path
                has-manifest
                stdlib-roots)))]
        [(string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrDocDefaultCliConfig "doc: --stdlib-root requires a value")
            (doc-default-parse-options
              (+ idx 2)
              count
              input-paths
              output-path
              has-output
              manifest-path
              has-manifest
              (string-vec-push stdlib-roots (arg (+ idx 1)))))]
        [(string-eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ErrDocDefaultCliConfig "doc: --manifest-path requires a value")
            (if has-manifest
              (ErrDocDefaultCliConfig "doc: duplicate --manifest-path")
              (doc-default-parse-options
                (+ idx 2)
                count
                input-paths
                output-path
                has-output
                (arg (+ idx 1))
                true
                stdlib-roots)))]
        [(doc-flag? current)
          (ErrDocDefaultCliConfig (string-append "doc: unknown flag " current))]
        [else
          (doc-default-parse-options
            (+ idx 1)
            count
            (doc-test-path-list-append input-paths current)
            output-path
            has-output
            manifest-path
            has-manifest
            stdlib-roots)]))))

(define (doc-default-config-from [base : i64] [count : i64]) : ResultDocDefaultCliConfig
  (doc-default-parse-options
    base
    count
    DocTestPathNil
    (DocNoString)
    false
    ""
    false
    (string-vec-new)))

(define (doc-invalid-args) : i64
  (begin
    (print-error "doc: expected input and output paths")
    1))

(define (doc-invalid-load-args) : i64
  (begin
    (print-error "doc: expected --load input and output paths")
    1))

(define (doc-invalid-html-args) : i64
  (begin
    (print-error "doc: expected --html input and output paths")
    1))

(define (doc-run-explicit-default
  [input-paths : DocTestPathList]
  [output-path : DocMaybeString]
  [stdlib-roots : StringVec]) : i64
  (match output-path
    [(DocSomeString out)
      (if (doc-test-path-list-empty? input-paths)
        (doc-invalid-args)
        (doc-generate-loaded-file
          (doc-test-path-list-first input-paths)
          out
          stdlib-roots))]
    [(DocNoString)
      (let
        [path-count : i64 (doc-test-path-list-count input-paths)]
        (cond
          [(= path-count 2)
            (doc-generate-file
              (doc-test-path-list-first input-paths)
              (doc-test-path-list-second input-paths))]
          [(> path-count 2)
            (doc-generate-module-graph-from-doc-paths input-paths)]
          [else (doc-invalid-args)]))]))

(define (doc-command-kind-load [value : String]) : i64
  (if (or (string-eq value "--load") (string-eq value "load"))
    3
    0))

(define (doc-command-kind-html [value : String]) : i64
  (if (or (string-eq value "--html") (string-eq value "html"))
    2
    (doc-command-kind-load value)))

(define (doc-command-kind [value : String]) : i64
  (if (or (string-eq value "--test") (string-eq value "test"))
    1
    (doc-command-kind-html value)))

;; The doc subcommands below take a `base` offset: `base` is the index of the
;; command-kind argument, so kind-relative arguments are at `base+1`, `base+2`,
;; ... The retained doc wrapper passes base=1; the unified dispatcher passes
;; base=2.
(define (doc-main-test [base : i64]) : i64
  (match (doc-test-config-from base (arg-count))
    [(OkDocTestCliConfig config)
      (match config
        [(DocTestCliFileConfig input-paths stdlib-roots)
          (doc-test-files
            input-paths
            stdlib-roots
            (> (doc-test-path-list-count input-paths) 1)
            0)]
        [(DocTestCliPackageConfig manifest-path has-manifest stdlib-roots)
          (doc-test-package manifest-path has-manifest stdlib-roots)])]
    [(ErrDocTestCliConfig message)
      (begin
        (print-error message)
        1)]))

(define (doc-main-html [base : i64]) : i64
  (if (= (arg-count) (+ base 3))
    (doc-generate-html-file (arg (+ base 1)) (arg (+ base 2)))
    (if (> (arg-count) (+ base 3))
      (doc-generate-html-module-graph (arg (- (arg-count) 1)))
      (doc-invalid-html-args))))

(define (doc-main-load [base : i64]) : i64
  (if (>= (arg-count) (+ base 3))
    (doc-generate-loaded-file
      (arg (+ base 1))
      (arg (+ base 2))
      (doc-stdlib-roots (+ base 3)))
    (doc-invalid-load-args)))

(define (doc-main-default [base : i64]) : i64
  (match (doc-default-config-from base (arg-count))
    [(OkDocDefaultCliConfig config)
      (match config
        [(DocDefaultCliExplicitConfig input-paths output-path stdlib-roots)
          (doc-run-explicit-default input-paths output-path stdlib-roots)]
        [(DocDefaultCliPackageConfig manifest-path has-manifest output-path)
          (doc-generate-package manifest-path has-manifest output-path)])]
    [(ErrDocDefaultCliConfig message)
      (begin
        (print-error message)
        1)]))

(define (doc-main-dispatch [kind : i64] [base : i64]) : i64
  (match kind
    [1 (doc-main-test base)]
    [2 (doc-main-html base)]
    [3 (doc-main-load base)]
    [_ (doc-main-default base)]))

;; Run the `doc` command; `start` is the index of the command-kind argument.
(define (doc-run-from [start : i64] [count : i64]) : i64
  (if (< count (+ start 1))
    (doc-main-default start)
    (doc-main-dispatch (doc-command-kind (arg start)) start)))