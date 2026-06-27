;; doc_cli_core.tl - Selfhost doc command logic.
;;
;; Usage through the current compiler runner:
;;   typelisp run selfhost/cli.tl -- doc input.tl output.md
;;   typelisp run selfhost/cli.tl -- doc entry.tl imported.tl output.md
;;   typelisp run selfhost/cli.tl -- doc --html input.tl output.html
;;   typelisp run selfhost/cli.tl -- doc --html entry.tl imported.tl output.html
;;   typelisp run selfhost/cli.tl -- doc --test input.tl
;;   typelisp run selfhost/cli.tl -- doc --test --batch inputs.txt
;;   typelisp run selfhost/cli.tl -- doc --load input.tl output.md [--stdlib-root <dir>...]
(import stdlib.io)
(import stdlib.vector)
(import "doc_render.tl")
(import "doc_html.tl")
(import "doc_test.tl")
(import "compiler_load.tl")
(import "package_source_core.tl")
(import stdlib.string)

(defenum DocMaybeString
  (DocNoString)
  (DocSomeString String))

(defenum DocTestCliConfig
  (DocTestCliFileConfig vector.StringVec vector.StringVec)
  (DocTestCliPackageConfig String bool vector.StringVec))

(defenum ResultDocTestBatchPaths
  (OkDocTestBatchPaths vector.StringVec)
  (ErrDocTestBatchPaths String))

(defenum ResultDocTestCliConfig
  (OkDocTestCliConfig DocTestCliConfig)
  (ErrDocTestCliConfig String))

(define doc-test-prefix-cache-stats : bool
  false)

(defenum DocDefaultCliConfig
  (DocDefaultCliExplicitConfig vector.StringVec DocMaybeString vector.StringVec)
  (DocDefaultCliPackageConfig String bool String))

(defenum ResultDocDefaultCliConfig
  (OkDocDefaultCliConfig DocDefaultCliConfig)
  (ErrDocDefaultCliConfig String))

(define (doc-print-wrote [output-path : String]) : unit
  (io.print-string
    (string.string-append "Wrote " (string.string-append output-path "\n"))))

(define (doc-generate-file [input-path : String] [output-path : String]) : i64
  (let
    [source : String (io.read-file input-path)]
    [markdown : String (doc-render-markdown (doc-extract-source source))]
    (begin
      (io.write-file output-path markdown)
      (doc-print-wrote output-path)
      0)))

(define (doc-cli-module-cons [module : DocModule] [rest : DocModuleList]) : DocModuleList
  (DocModuleCons module (box rest)))

(define (doc-read-modules [idx : i64] [end : i64]) : DocModuleList
  (if (>= idx end)
    DocModuleNil
    (doc-cli-module-cons
      (DocModule (io.arg idx) (doc-extract-file (io.arg idx)))
      (doc-read-modules (+ idx 1) end))))

(define (doc-module-list-count [modules : DocModuleList]) : i64
  (match modules
    [(DocModuleNil) 0]
    [(DocModuleCons _ rest) (+ 1 (doc-module-list-count (box-get rest)))]))

(define (doc-modules-from-string-vec-from
  [paths : vector.StringVec]
  [index : i64]) : DocModuleList
  (if (>= index (vector.string-vec-len paths))
    DocModuleNil
    (let
      [path : String (vector.string-vec-get paths index "")]
      (doc-cli-module-cons
        (DocModule path (doc-extract-file path))
        (doc-modules-from-string-vec-from paths (+ index 1))))))

(define (doc-modules-from-string-vec [paths : vector.StringVec]) : DocModuleList
  (doc-modules-from-string-vec-from paths 0))

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
  [stdlib-roots : vector.StringVec]) : i64
  (match (compiler-load-file-with-paths-and-roots
    input-path
    (sym-i64-empty)
    stdlib-roots)
    [(OkCompilerLoadWithPaths _ paths _ _)
      (begin
        (io.write-file
          output-path
          (doc-render-loaded-markdown input-path paths))
        (doc-print-wrote output-path)
        0)]
    [(ErrCompilerLoadWithPaths diag)
      (begin
        (io.print-error (compiler-diagnostic-render (box-get diag)))
        1)]))

(define (doc-generate-package
  [manifest-path : String]
  [has-manifest : bool]
  [output-path : String]) : i64
  (match (package-source-discover-for "doc" manifest-path has-manifest)
    [(ErrPackageSourceSet message)
      (begin
        (io.print-error (string.string-append message "\n"))
        1)]
    [(OkPackageSourceSet source-set)
      (begin
        (io.write-file
          output-path
          (doc-render-module-graph-markdown
            (doc-modules-from-string-vec (struct-get source-set sources))))
        (doc-print-wrote output-path)
        0)]))

(define (doc-generate-html-file [input-path : String] [output-path : String]) : i64
  (let
    [source : String (io.read-file input-path)]
    [html : String (doc-html-render-source input-path source)]
    (begin
      (io.write-file output-path html)
      (doc-print-wrote output-path)
      0)))

(define (doc-generate-html-module-graph [output-path : String]) : i64
  (let
    [modules : DocModuleList (doc-read-modules 2 (- (arg-count) 1))]
    (begin
      (io.write-file output-path (doc-html-render-module-graph modules))
      (doc-print-wrote output-path)
      0)))

(define (doc-test-file [input-path : String] [stdlib-roots : vector.StringVec]) : i64
  (let
    [report : DocTestRunReport
      (doc-test-run-file-with-roots input-path stdlib-roots)]
    (begin
      (if (doc-test-run-report-ok? report)
        (io.print-string
          (string.string-append (doc-test-run-report-render report) "\n"))
        (io.print-error (doc-test-run-report-render report)))
      (doc-test-run-report-status report))))

(define (doc-flag? [value : String]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (doc-stdlib-roots [idx : i64]) : vector.StringVec
  (let
    [i : i64 idx]
    [n : i64 (arg-count)]
    [roots : vector.StringVec (vector.string-vec-new)]
    (begin
      (while (< i n)
        (if (string.string-eq (io.arg i) "--stdlib-root")
          (if (< (+ i 1) n)
            (begin
              (set! roots (vector.string-vec-push roots (io.arg (+ i 1))))
              (set! i (+ i 2)))
            (set! i n))
          (set! i (+ i 1))))
      roots)))

(define (doc-modules-from-input-paths-before-last
  [paths : vector.StringVec]
  [index : i64]
  [last-index : i64]) : DocModuleList
  (if (>= index last-index)
    DocModuleNil
    (let
      [path : String (vector.string-vec-get paths index "")]
      (doc-cli-module-cons
        (DocModule path (doc-extract-file path))
        (doc-modules-from-input-paths-before-last paths (+ index 1) last-index)))))

(define (doc-generate-module-graph-from-input-paths [paths : vector.StringVec]) : i64
  (let
    [output-path : String (vector.string-vec-last paths "")]
    [modules : DocModuleList
      (doc-modules-from-input-paths-before-last
        paths
        0
        (- (vector.string-vec-len paths) 1))]
    (begin
      (io.write-file output-path (doc-render-module-graph-markdown modules))
      (doc-print-wrote output-path)
      0)))

(define (doc-test-batch-line-end [text : String] [start : i64] [n : i64]) : i64
  (let
    [i : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (if (or
            (= (string.string-ref text i) '\n')
            (= (string.string-ref text i) '\r'))
            (set! keep false)
            (set! i (+ i 1)))
          (set! keep false)))
      i)))

(define (doc-test-batch-next-line-start
  [text : String]
  [line-end : i64]
  [n : i64]) : i64
  (begin
    (unless (< line-end n) (return line-end))
    (let
      [c : char (string.string-ref text line-end)]
      (begin
        (unless (= c '\r') (return (+ line-end 1)))
        (unless (< (+ line-end 1) n) (return (+ line-end 1)))
        (if (= (string.string-ref text (+ line-end 1)) '\n')
          (+ line-end 2)
          (+ line-end 1))))))

(define (doc-test-batch-paths-from-text [text : String]) : vector.StringVec
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [paths : vector.StringVec (vector.string-vec-new)]
    (begin
      (while (< i n)
        (let
          [line-end : i64 (doc-test-batch-line-end text i n)]
          [line : String (string.substring text i (- line-end i))]
          (begin
            (if (> (string.string-length line) 0)
              (set! paths (vector.string-vec-push paths line))
              unit)
            (set! i (doc-test-batch-next-line-start text line-end n)))))
      paths)))

(define (doc-test-batch-paths [list-path : String]) : ResultDocTestBatchPaths
  (match (io.try-read-file (& list-path))
    [(io.OkIoString text)
      (OkDocTestBatchPaths (doc-test-batch-paths-from-text text))]
    [(io.ErrIoString error)
      (ErrDocTestBatchPaths
        (string.string-append
          "doc: failed to read --batch list file: "
          (io.io-error-message error)))]))

(define (doc-test-config-finish
  [input-paths : vector.StringVec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : vector.StringVec]
  [batch-list : DocMaybeString]) : ResultDocTestCliConfig
  (match batch-list
    [(DocSomeString list-path)
      (if has-manifest
        (ErrDocTestCliConfig "doc: cannot combine --batch with --manifest-path")
        (if (not (vector.string-vec-is-empty? input-paths))
          (ErrDocTestCliConfig "doc: cannot combine input paths with --batch")
          (match (doc-test-batch-paths list-path)
            [(OkDocTestBatchPaths paths)
              (if (vector.string-vec-is-empty? paths)
                (ErrDocTestCliConfig "doc: --batch list is empty")
                (OkDocTestCliConfig (DocTestCliFileConfig paths stdlib-roots)))]
            [(ErrDocTestBatchPaths message) (ErrDocTestCliConfig message)])))]
    [(DocNoString)
      (cond
        [doc-test-prefix-cache-stats
          (ErrDocTestCliConfig "doc: --prefix-cache-stats requires --batch")]
        [(vector.string-vec-is-empty? input-paths)
          (OkDocTestCliConfig
            (DocTestCliPackageConfig manifest-path has-manifest stdlib-roots))]
        [has-manifest
          (ErrDocTestCliConfig
            "doc: cannot combine input paths with --manifest-path")]
        [else
          (OkDocTestCliConfig (DocTestCliFileConfig input-paths stdlib-roots))])]))

(define (doc-test-parse-options
  [idx : i64]
  [count : i64]
  [input-paths : vector.StringVec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : vector.StringVec]
  [batch-list : DocMaybeString]) : ResultDocTestCliConfig
  (if (>= idx count)
    (doc-test-config-finish
      input-paths
      manifest-path
      has-manifest
      stdlib-roots
      batch-list)
    (let
      [current : String (io.arg idx)]
      (cond
        [(string.string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrDocTestCliConfig "doc: --stdlib-root requires a value")
            (doc-test-parse-options
              (+ idx 2)
              count
              input-paths
              manifest-path
              has-manifest
              (vector.string-vec-push stdlib-roots (io.arg (+ idx 1)))
              batch-list))]
        [(string.string-eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ErrDocTestCliConfig "doc: --manifest-path requires a value")
            (if has-manifest
              (ErrDocTestCliConfig "doc: duplicate --manifest-path")
              (doc-test-parse-options
                (+ idx 2)
                count
                input-paths
                (io.arg (+ idx 1))
                true
                stdlib-roots
                batch-list)))]
        [(string.string-eq current "--batch")
          (if (>= (+ idx 1) count)
            (ErrDocTestCliConfig "doc: --batch requires a value")
            (match batch-list
              [(DocSomeString _) (ErrDocTestCliConfig "doc: duplicate --batch")]
              [(DocNoString)
                (doc-test-parse-options
                  (+ idx 2)
                  count
                  input-paths
                  manifest-path
                  has-manifest
                  stdlib-roots
                  (DocSomeString (io.arg (+ idx 1))))]))]
        [(string.string-eq current "--prefix-cache-stats")
          (begin
            (set! doc-test-prefix-cache-stats true)
            (doc-test-parse-options
              (+ idx 1)
              count
              input-paths
              manifest-path
              has-manifest
              stdlib-roots
              batch-list))]
        [(doc-flag? current)
          (ErrDocTestCliConfig
            (string.string-append "doc: unknown flag " current))]
        [else
          (doc-test-parse-options
            (+ idx 1)
            count
            (vector.string-vec-push input-paths current)
            manifest-path
            has-manifest
            stdlib-roots
            batch-list)]))))

(define (doc-test-config-from [base : i64] [count : i64]) : ResultDocTestCliConfig
  (begin
    (set! doc-test-prefix-cache-stats false)
    (doc-test-parse-options
      (+ base 1)
      count
      (vector.string-vec-new)
      ""
      false
      (vector.string-vec-new)
      (DocNoString))))

(define (doc-test-files-from
  [input-paths : vector.StringVec]
  [index : i64]
  [stdlib-roots : vector.StringVec]
  [print-headers : bool]
  [status : i64]) : i64
  (if (>= index (vector.string-vec-len input-paths))
    status
    (let
      [input-path : String (vector.string-vec-get input-paths index "")]
      [file-status : i64
        (begin
          (if print-headers
            (io.print-string
              (string.string-append
                "--- "
                (string.string-append input-path "\n")))
            unit)
          (doc-test-file input-path stdlib-roots))]
      (doc-test-files-from
        input-paths
        (+ index 1)
        stdlib-roots
        print-headers
        (if (= status 0)
          file-status
          status)))))

(define (doc-test-files
  [input-paths : vector.StringVec]
  [stdlib-roots : vector.StringVec]
  [print-headers : bool]
  [status : i64]) : i64
  (doc-test-files-from input-paths 0 stdlib-roots print-headers status))

(define (doc-test-package-files-from
  [input-paths : vector.StringVec]
  [index : i64]
  [stdlib-roots : vector.StringVec]
  [status : i64]) : i64
  (if (>= index (vector.string-vec-len input-paths))
    status
    (let
      [input-path : String (vector.string-vec-get input-paths index "")]
      [file-status : i64
        (begin
          (io.print-string
            (string.string-append "--- " (string.string-append input-path "\n")))
          (doc-test-file input-path stdlib-roots))]
      (doc-test-package-files-from
        input-paths
        (+ index 1)
        stdlib-roots
        (if (= status 0)
          file-status
          status)))))

(define (doc-test-package-files
  [input-paths : vector.StringVec]
  [stdlib-roots : vector.StringVec]
  [status : i64]) : i64
  (doc-test-package-files-from input-paths 0 stdlib-roots status))

(define (doc-test-package
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : vector.StringVec]) : i64
  (match (package-source-discover-for "doc" manifest-path has-manifest)
    [(ErrPackageSourceSet message)
      (begin
        (io.print-error (string.string-append message "\n"))
        1)]
    [(OkPackageSourceSet source-set)
      (doc-test-package-files (struct-get source-set sources) stdlib-roots 0)]))

(define (doc-default-config-finish
  [input-paths : vector.StringVec]
  [output-path : DocMaybeString]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : vector.StringVec]) : ResultDocDefaultCliConfig
  (if (vector.string-vec-is-empty? input-paths)
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
  [input-paths : vector.StringVec]
  [output-path : DocMaybeString]
  [manifest-path : String]
  [stdlib-roots : vector.StringVec]) : ResultDocDefaultCliConfig
  (if (>= idx count)
    (doc-default-config-finish
      input-paths
      output-path
      manifest-path
      (not (string.string-eq manifest-path ""))
      stdlib-roots)
    (let
      [current : String (io.arg idx)]
      (cond
        [(string.string-eq current "-o")
          (if (>= (+ idx 1) count)
            (ErrDocDefaultCliConfig "doc: -o requires a value")
            (match output-path
              [(DocSomeString _) (ErrDocDefaultCliConfig "doc: duplicate -o")]
              [(DocNoString)
                (doc-default-parse-options
                  (+ idx 2)
                  count
                  input-paths
                  (DocSomeString (io.arg (+ idx 1)))
                  manifest-path
                  stdlib-roots)]))]
        [(string.string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrDocDefaultCliConfig "doc: --stdlib-root requires a value")
            (doc-default-parse-options
              (+ idx 2)
              count
              input-paths
              output-path
              manifest-path
              (vector.string-vec-push stdlib-roots (io.arg (+ idx 1)))))]
        [(string.string-eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ErrDocDefaultCliConfig "doc: --manifest-path requires a value")
            (if (not (string.string-eq manifest-path ""))
              (ErrDocDefaultCliConfig "doc: duplicate --manifest-path")
              (doc-default-parse-options
                (+ idx 2)
                count
                input-paths
                output-path
                (io.arg (+ idx 1))
                stdlib-roots)))]
        [(doc-flag? current)
          (ErrDocDefaultCliConfig
            (string.string-append "doc: unknown flag " current))]
        [else
          (doc-default-parse-options
            (+ idx 1)
            count
            (vector.string-vec-push input-paths current)
            output-path
            manifest-path
            stdlib-roots)]))))

(define (doc-default-config-from [base : i64] [count : i64]) : ResultDocDefaultCliConfig
  (doc-default-parse-options
    base
    count
    (vector.string-vec-new)
    (DocNoString)
    ""
    (vector.string-vec-new)))

(define (doc-invalid-args) : i64
  (begin
    (io.print-error "doc: expected input and output paths")
    1))

(define (doc-invalid-load-args) : i64
  (begin
    (io.print-error "doc: expected --load input and output paths")
    1))

(define (doc-invalid-html-args) : i64
  (begin
    (io.print-error "doc: expected --html input and output paths")
    1))

(define (doc-run-explicit-default
  [input-paths : vector.StringVec]
  [output-path : DocMaybeString]
  [stdlib-roots : vector.StringVec]) : i64
  (match output-path
    [(DocSomeString out)
      (if (vector.string-vec-is-empty? input-paths)
        (doc-invalid-args)
        (doc-generate-loaded-file
          (vector.string-vec-get input-paths 0 "")
          out
          stdlib-roots))]
    [(DocNoString)
      (let
        [path-count : i64 (vector.string-vec-len input-paths)]
        (if (= path-count 2)
          (doc-generate-file
            (vector.string-vec-get input-paths 0 "")
            (vector.string-vec-get input-paths 1 ""))
          (if (> path-count 2)
            (doc-generate-module-graph-from-input-paths input-paths)
            (doc-invalid-args))))]))

(define (doc-command-kind-load [value : String]) : i64
  (if (or (string.string-eq value "--load") (string.string-eq value "load"))
    3
    0))

(define (doc-command-kind-html [value : String]) : i64
  (if (or (string.string-eq value "--html") (string.string-eq value "html"))
    2
    (doc-command-kind-load value)))

(define (doc-command-kind [value : String]) : i64
  (if (or (string.string-eq value "--test") (string.string-eq value "test"))
    1
    (doc-command-kind-html value)))

;; The doc subcommands below take a `base` offset: `base` is the index of the
;; command-kind argument, so kind-relative arguments are at `base+1`, `base+2`,
;; ... The retained doc wrapper passes base=1; the unified dispatcher passes
;; base=2.
(define (doc-main-test [base : i64]) : i64
  (begin
    (compiler-load-session-cache-enable!)
    (compiler-load-session-program-cache-disable!)
    (match (doc-test-config-from base (arg-count))
      [(OkDocTestCliConfig config)
        (match config
          [(DocTestCliFileConfig input-paths stdlib-roots)
            (let
              [status : i64
                (begin
                  (if doc-test-prefix-cache-stats
                    (tc-prefix-snapshot-cache-clear!)
                    unit)
                  (doc-test-files
                    input-paths
                    stdlib-roots
                    (> (vector.string-vec-len input-paths) 1)
                    0))]
              (begin
                (if doc-test-prefix-cache-stats
                  (tc-prefix-snapshot-cache-print-stats "doc-test-batch")
                  unit)
                status))]
          [(DocTestCliPackageConfig manifest-path has-manifest stdlib-roots)
            (doc-test-package manifest-path has-manifest stdlib-roots)])]
      [(ErrDocTestCliConfig message)
        (begin
          (io.print-error message)
          1)])))

(define (doc-main-html [base : i64]) : i64
  (if (= (arg-count) (+ base 3))
    (doc-generate-html-file (io.arg (+ base 1)) (io.arg (+ base 2)))
    (if (> (arg-count) (+ base 3))
      (doc-generate-html-module-graph (io.arg (- (arg-count) 1)))
      (doc-invalid-html-args))))

(define (doc-main-load [base : i64]) : i64
  (if (>= (arg-count) (+ base 3))
    (doc-generate-loaded-file
      (io.arg (+ base 1))
      (io.arg (+ base 2))
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
        (io.print-error message)
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
    (doc-main-dispatch (doc-command-kind (io.arg start)) start)))