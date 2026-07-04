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
(import stdlib.vector as svec)
(import "doc_render.tl")
(import "doc_html.tl")
(import "doc_test.tl")
(import "doc_expand.tl")
(import "compiler_load.tl")
(import "package_source_core.tl")
(import stdlib.string)
(import sym_i64_env)

(defenum DocMaybeString
  (No)
  (Some String))

(defenum DocTestCliConfig
  (File svec.StringVec svec.StringVec)
  (Package String bool svec.StringVec))

(defenum ResultDocTestBatchPaths
  (Ok svec.StringVec)
  (Err String))

(defenum ResultDocTestCliConfig
  (Ok DocTestCliConfig)
  (Err String))

(define doc-test-prefix-cache-stats : bool
  false)

(defenum DocDefaultCliConfig
  (Explicit svec.StringVec DocMaybeString svec.StringVec)
  (Package String bool String))

(defenum ResultDocDefaultCliConfig
  (Ok DocDefaultCliConfig)
  (Err String))

(define (doc-print-wrote [output-path : String]) : unit
  (io.print-string (string.append "Wrote " (string.append output-path "\n"))))

(define (doc-generate-file [input-path : String] [output-path : String]) : i64
  (let
    [source : String (io.read-file input-path)]
    [markdown : String (doc-render-markdown (doc-extract-source source))]
    (begin
      (io.write-file output-path markdown)
      (doc-print-wrote output-path)
      0)))

(define (doc-cli-module-cons [module : DocModule] [rest : DocModuleList]) : DocModuleList
  (DocModuleList.Cons module (box rest)))

(define (doc-read-modules [idx : i64] [end : i64]) : DocModuleList
  (if (>= idx end)
    DocModuleList.Nil
    (doc-cli-module-cons
      (DocModule.Module (io.arg idx) (doc-extract-file (io.arg idx)))
      (doc-read-modules (+ idx 1) end))))

(define (doc-module-list-count [modules : DocModuleList]) : i64
  (match modules
    [(DocModuleList.Nil) 0]
    [(DocModuleList.Cons _ rest) (+ 1 (doc-module-list-count (box-get rest)))]))

(define (doc-modules-from-string-vec-from
  [paths : PackageSourceList]
  [index : i64]) : DocModuleList
  (if (>= index (package-source-list-len paths))
    DocModuleList.Nil
    (let
      [path : String (package-source-list-get paths index "")]
      (doc-cli-module-cons
        (DocModule.Module path (doc-extract-file path))
        (doc-modules-from-string-vec-from paths (+ index 1))))))

(define (doc-modules-from-string-vec [paths : PackageSourceList]) : DocModuleList
  (doc-modules-from-string-vec-from paths 0))

(define (doc-modules-from-paths
  [paths : AstDeclPathList]
  [seen : sym_i64_env.SymI64Env]) : DocModuleList
  (match (ast-decl-path-list-step paths)
    [(AstDeclPathListStep.Nil) DocModuleList.Nil]
    [(AstDeclPathListStep.Cons path rest)
      (let
        [rest : AstDeclPathList rest]
        (if (sym_i64_env.sym-i64-contains seen path)
          (doc-modules-from-paths rest seen)
          (doc-cli-module-cons
            (DocModule.Module path (doc-extract-file path))
            (doc-modules-from-paths rest (sym_i64_env.sym-i64-bind seen path 1)))))]))

(define (doc-generated-modules-from-source-paths
  [paths : AstDeclPathList]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.StringVec]) : ResultDocExpandedModules
  (match (ast-decl-path-list-step paths)
    [(AstDeclPathListStep.Nil) (ResultDocExpandedModules.Ok DocModuleList.Nil)]
    [(AstDeclPathListStep.Cons path rest)
      (let
        [rest : AstDeclPathList rest]
        (if (sym_i64_env.sym-i64-contains seen path)
          (doc-generated-modules-from-source-paths rest seen stdlib-roots)
          (let
            [next-seen : sym_i64_env.SymI64Env
              (sym_i64_env.sym-i64-bind seen path 1)]
            [docs : DocExtraction (doc-extract-file path)]
            (match (doc-expanded-generated-modules-from-source-docs
              path
              docs
              stdlib-roots)
              [(ResultDocExpandedModules.Ok head-modules)
                (match (doc-generated-modules-from-source-paths
                  rest
                  next-seen
                  stdlib-roots)
                  [(ResultDocExpandedModules.Ok tail-modules)
                    (ResultDocExpandedModules.Ok
                      (doc-module-list-append head-modules tail-modules))]
                  [(ResultDocExpandedModules.Err message)
                    (ResultDocExpandedModules.Err message)])]
              [(ResultDocExpandedModules.Err message)
                (ResultDocExpandedModules.Err message)]))))]))

(define (doc-render-loaded-markdown
  [input-path : String]
  [paths : AstDeclPathList]
  [generated-modules : DocModuleList]) : String
  (let
    [modules : DocModuleList
      (doc-modules-from-paths
        (ast-decl-path-cons input-path paths)
        (sym_i64_env.sym-i64-empty))]
    [all-modules : DocModuleList
      (doc-module-list-append modules generated-modules)]
    (if (> (doc-module-list-count all-modules) 1)
      (doc-render-module-graph-markdown all-modules)
      (doc-render-markdown (doc-extract-file input-path)))))

(define (doc-generate-loaded-file
  [input-path : String]
  [output-path : String]
  [stdlib-roots : svec.StringVec]) : i64
  (match (compiler-load-file-with-paths-and-roots
    input-path
    (sym_i64_env.sym-i64-empty)
    stdlib-roots)
    [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
      (match (doc-generated-modules-from-source-paths
        (ast-decl-path-cons input-path paths)
        (sym_i64_env.sym-i64-empty)
        stdlib-roots)
        [(ResultDocExpandedModules.Ok source-generated-modules)
          (let
            ;; Expansion from public source docs is authoritative and errors
            ;; above fail the command. Loaded graph expansion is best-effort:
            ;; synthetic graph docs can combine helper declarations from many
            ;; modules in ways normal source builds never do.
            [generated-modules : DocModuleList
              (match (doc-expanded-generated-modules-from-loaded-decls
                decls
                paths
                stdlib-roots)
                [(ResultDocExpandedModules.Ok modules) modules]
                [(ResultDocExpandedModules.Err _) DocModuleList.Nil])]
            (begin
              (io.write-file
                output-path
                (doc-render-loaded-markdown
                  input-path
                  paths
                  (doc-module-list-append
                    generated-modules
                    source-generated-modules)))
              (doc-print-wrote output-path)
              0))]
        [(ResultDocExpandedModules.Err message)
          (begin
            (io.print-error message)
            1)])]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (io.print-error (compiler-diagnostic-render (box-get diag)))
        1)]))

(define (doc-generate-package
  [manifest-path : String]
  [has-manifest : bool]
  [output-path : String]) : i64
  (match (package-source-discover-for "doc" manifest-path has-manifest)
    [(ResultPackageSourceSet.Err message)
      (begin
        (io.print-error (string.append message "\n"))
        1)]
    [(ResultPackageSourceSet.Ok source-set)
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

(define (doc-test-file [input-path : String] [stdlib-roots : svec.StringVec]) : i64
  (let
    [report : DocTestRunReport
      (doc-test-run-file-with-roots input-path stdlib-roots)]
    (begin
      (if (doc-test-run-report-ok? report)
        (io.print-string
          (string.append (doc-test-run-report-render report) "\n"))
        (io.print-error (doc-test-run-report-render report)))
      (doc-test-run-report-status report))))

(define (doc-flag? [value : String]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (doc-stdlib-roots [idx : i64]) : svec.StringVec
  (let
    [i : i64 idx]
    [n : i64 (arg-count)]
    [roots : svec.StringVec (svec.string-vec-new)]
    (begin
      (while (< i n)
        (if (string.eq (io.arg i) "--stdlib-root")
          (if (< (+ i 1) n)
            (begin
              (set! roots (svec.string-vec-push roots (io.arg (+ i 1))))
              (set! i (+ i 2)))
            (set! i n))
          (set! i (+ i 1))))
      roots)))

(define (doc-modules-from-input-paths-before-last
  [paths : svec.StringVec]
  [index : i64]
  [last-index : i64]) : DocModuleList
  (if (>= index last-index)
    DocModuleList.Nil
    (let
      [path : String (svec.string-vec-get (& paths) index "")]
      (doc-cli-module-cons
        (DocModule.Module path (doc-extract-file path))
        (doc-modules-from-input-paths-before-last paths (+ index 1) last-index)))))

(define (doc-generate-module-graph-from-input-paths [paths : svec.StringVec]) : i64
  (let
    [output-path : String (svec.string-vec-last (& paths) "")]
    [modules : DocModuleList
      (doc-modules-from-input-paths-before-last
        paths
        0
        (- (svec.string-vec-len (& paths)) 1))]
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

(define (doc-test-batch-paths-from-text [text : String]) : svec.StringVec
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [paths : svec.StringVec (svec.string-vec-new)]
    (begin
      (while (< i n)
        (let
          [line-end : i64 (doc-test-batch-line-end text i n)]
          [line : String (string.substring text i (- line-end i))]
          (begin
            (if (> (string.string-length line) 0)
              (set! paths (svec.string-vec-push paths line))
              unit)
            (set! i (doc-test-batch-next-line-start text line-end n)))))
      paths)))

(define (doc-test-batch-paths [list-path : String]) : ResultDocTestBatchPaths
  (match (io.try-read-file (& list-path))
    [(io.OkIoString text)
      (ResultDocTestBatchPaths.Ok (doc-test-batch-paths-from-text text))]
    [(io.ErrIoString error)
      (ResultDocTestBatchPaths.Err
        (string.append
          "doc: failed to read --batch list file: "
          (io.error-message error)))]))

(define (doc-test-config-finish
  [input-paths : svec.StringVec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : svec.StringVec]
  [batch-list : DocMaybeString]) : ResultDocTestCliConfig
  (match batch-list
    [(DocMaybeString.Some list-path)
      (if has-manifest
        (ResultDocTestCliConfig.Err
          "doc: cannot combine --batch with --manifest-path")
        (if (not (svec.string-vec-is-empty? (& input-paths)))
          (ResultDocTestCliConfig.Err
            "doc: cannot combine input paths with --batch")
          (match (doc-test-batch-paths list-path)
            [(ResultDocTestBatchPaths.Ok paths)
              (if (svec.string-vec-is-empty? (& paths))
                (ResultDocTestCliConfig.Err "doc: --batch list is empty")
                (ResultDocTestCliConfig.Ok
                  (DocTestCliConfig.File paths stdlib-roots)))]
            [(ResultDocTestBatchPaths.Err message)
              (ResultDocTestCliConfig.Err message)])))]
    [(DocMaybeString.No)
      (cond
        [doc-test-prefix-cache-stats
          (ResultDocTestCliConfig.Err
            "doc: --prefix-cache-stats requires --batch")]
        [(svec.string-vec-is-empty? (& input-paths))
          (ResultDocTestCliConfig.Ok
            (DocTestCliConfig.Package manifest-path has-manifest stdlib-roots))]
        [has-manifest
          (ResultDocTestCliConfig.Err
            "doc: cannot combine input paths with --manifest-path")]
        [else
          (ResultDocTestCliConfig.Ok
            (DocTestCliConfig.File input-paths stdlib-roots))])]))

(define (doc-test-parse-options
  [idx : i64]
  [count : i64]
  [input-paths : svec.StringVec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : svec.StringVec]
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
        [(string.eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ResultDocTestCliConfig.Err "doc: --stdlib-root requires a value")
            (doc-test-parse-options
              (+ idx 2)
              count
              input-paths
              manifest-path
              has-manifest
              (let
                [next-roots : svec.StringVec stdlib-roots]
                (begin
                  (set!
                    next-roots
                    (svec.string-vec-push next-roots (io.arg (+ idx 1))))
                  next-roots))
              batch-list))]
        [(string.eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ResultDocTestCliConfig.Err "doc: --manifest-path requires a value")
            (if has-manifest
              (ResultDocTestCliConfig.Err "doc: duplicate --manifest-path")
              (doc-test-parse-options
                (+ idx 2)
                count
                input-paths
                (io.arg (+ idx 1))
                true
                stdlib-roots
                batch-list)))]
        [(string.eq current "--batch")
          (if (>= (+ idx 1) count)
            (ResultDocTestCliConfig.Err "doc: --batch requires a value")
            (match batch-list
              [(DocMaybeString.Some _)
                (ResultDocTestCliConfig.Err "doc: duplicate --batch")]
              [(DocMaybeString.No)
                (doc-test-parse-options
                  (+ idx 2)
                  count
                  input-paths
                  manifest-path
                  has-manifest
                  stdlib-roots
                  (DocMaybeString.Some (io.arg (+ idx 1))))]))]
        [(string.eq current "--prefix-cache-stats")
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
          (ResultDocTestCliConfig.Err
            (string.append "doc: unknown flag " current))]
        [else
          (doc-test-parse-options
            (+ idx 1)
            count
            (let
              [next-paths : svec.StringVec input-paths]
              (begin
                (set! next-paths (svec.string-vec-push next-paths current))
                next-paths))
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
      (svec.string-vec-new)
      ""
      false
      (svec.string-vec-new)
      (DocMaybeString.No))))

(define (doc-test-files-from
  [input-paths : svec.StringVec]
  [index : i64]
  [stdlib-roots : svec.StringVec]
  [print-headers : bool]
  [status : i64]) : i64
  (if (>= index (svec.string-vec-len (& input-paths)))
    status
    (let
      [input-path : String (svec.string-vec-get (& input-paths) index "")]
      [file-status : i64
        (begin
          (if print-headers
            (io.print-string
              (string.append "--- " (string.append input-path "\n")))
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
  [input-paths : svec.StringVec]
  [stdlib-roots : svec.StringVec]
  [print-headers : bool]
  [status : i64]) : i64
  (doc-test-files-from input-paths 0 stdlib-roots print-headers status))

(define (doc-test-package-files-from
  [input-paths : PackageSourceList]
  [index : i64]
  [stdlib-roots : svec.StringVec]
  [status : i64]) : i64
  (if (>= index (package-source-list-len input-paths))
    status
    (let
      [input-path : String (package-source-list-get input-paths index "")]
      [file-status : i64
        (begin
          (io.print-string
            (string.append "--- " (string.append input-path "\n")))
          (doc-test-file input-path stdlib-roots))]
      (doc-test-package-files-from
        input-paths
        (+ index 1)
        stdlib-roots
        (if (= status 0)
          file-status
          status)))))

(define (doc-test-package-files
  [input-paths : PackageSourceList]
  [stdlib-roots : svec.StringVec]
  [status : i64]) : i64
  (doc-test-package-files-from input-paths 0 stdlib-roots status))

(define (doc-test-package
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : svec.StringVec]) : i64
  (match (package-source-discover-for "doc" manifest-path has-manifest)
    [(ResultPackageSourceSet.Err message)
      (begin
        (io.print-error (string.append message "\n"))
        1)]
    [(ResultPackageSourceSet.Ok source-set)
      (doc-test-package-files (struct-get source-set sources) stdlib-roots 0)]))

(define (doc-default-config-finish
  [input-paths : svec.StringVec]
  [output-path : DocMaybeString]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : svec.StringVec]) : ResultDocDefaultCliConfig
  (if (svec.string-vec-is-empty? (& input-paths))
    (match output-path
      [(DocMaybeString.Some out)
        (ResultDocDefaultCliConfig.Ok
          (DocDefaultCliConfig.Package manifest-path has-manifest out))]
      [(DocMaybeString.No)
        (if has-manifest
          (ResultDocDefaultCliConfig.Err
            "doc: package documentation requires -o <out.md>")
          (ResultDocDefaultCliConfig.Err "doc: expected input and output paths"))])
    (if has-manifest
      (ResultDocDefaultCliConfig.Err
        "doc: cannot combine input paths with --manifest-path")
      (ResultDocDefaultCliConfig.Ok
        (DocDefaultCliConfig.Explicit input-paths output-path stdlib-roots)))))

(define (doc-default-parse-options
  [idx : i64]
  [count : i64]
  [input-paths : svec.StringVec]
  [output-path : DocMaybeString]
  [manifest-path : String]
  [stdlib-roots : svec.StringVec]) : ResultDocDefaultCliConfig
  (if (>= idx count)
    (doc-default-config-finish
      input-paths
      output-path
      manifest-path
      (not (string.eq manifest-path ""))
      stdlib-roots)
    (let
      [current : String (io.arg idx)]
      (cond
        [(string.eq current "-o")
          (if (>= (+ idx 1) count)
            (ResultDocDefaultCliConfig.Err "doc: -o requires a value")
            (match output-path
              [(DocMaybeString.Some _)
                (ResultDocDefaultCliConfig.Err "doc: duplicate -o")]
              [(DocMaybeString.No)
                (doc-default-parse-options
                  (+ idx 2)
                  count
                  input-paths
                  (DocMaybeString.Some (io.arg (+ idx 1)))
                  manifest-path
                  stdlib-roots)]))]
        [(string.eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ResultDocDefaultCliConfig.Err
              "doc: --stdlib-root requires a value")
            (doc-default-parse-options
              (+ idx 2)
              count
              input-paths
              output-path
              manifest-path
              (let
                [next-roots : svec.StringVec stdlib-roots]
                (begin
                  (set!
                    next-roots
                    (svec.string-vec-push next-roots (io.arg (+ idx 1))))
                  next-roots))))]
        [(string.eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ResultDocDefaultCliConfig.Err
              "doc: --manifest-path requires a value")
            (if (not (string.eq manifest-path ""))
              (ResultDocDefaultCliConfig.Err "doc: duplicate --manifest-path")
              (doc-default-parse-options
                (+ idx 2)
                count
                input-paths
                output-path
                (io.arg (+ idx 1))
                stdlib-roots)))]
        [(doc-flag? current)
          (ResultDocDefaultCliConfig.Err
            (string.append "doc: unknown flag " current))]
        [else
          (doc-default-parse-options
            (+ idx 1)
            count
            (let
              [next-paths : svec.StringVec input-paths]
              (begin
                (set! next-paths (svec.string-vec-push next-paths current))
                next-paths))
            output-path
            manifest-path
            stdlib-roots)]))))

(define (doc-default-config-from [base : i64] [count : i64]) : ResultDocDefaultCliConfig
  (doc-default-parse-options
    base
    count
    (svec.string-vec-new)
    (DocMaybeString.No)
    ""
    (svec.string-vec-new)))

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
  [input-paths : svec.StringVec]
  [output-path : DocMaybeString]
  [stdlib-roots : svec.StringVec]) : i64
  (match output-path
    [(DocMaybeString.Some out)
      (if (svec.string-vec-is-empty? (& input-paths))
        (doc-invalid-args)
        (doc-generate-loaded-file
          (svec.string-vec-get (& input-paths) 0 "")
          out
          stdlib-roots))]
    [(DocMaybeString.No)
      (let
        [path-count : i64 (svec.string-vec-len (& input-paths))]
        (if (= path-count 2)
          (doc-generate-file
            (svec.string-vec-get (& input-paths) 0 "")
            (svec.string-vec-get (& input-paths) 1 ""))
          (if (> path-count 2)
            (doc-generate-module-graph-from-input-paths input-paths)
            (doc-invalid-args))))]))

(define (doc-command-kind-load [value : String]) : i64
  (if (or (string.eq value "--load") (string.eq value "load"))
    3
    0))

(define (doc-command-kind-html [value : String]) : i64
  (if (or (string.eq value "--html") (string.eq value "html"))
    2
    (doc-command-kind-load value)))

(define (doc-command-kind [value : String]) : i64
  (if (or (string.eq value "--test") (string.eq value "test"))
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
      [(ResultDocTestCliConfig.Ok config)
        (match config
          [(DocTestCliConfig.File input-paths stdlib-roots)
            (let
              [status : i64
                (begin
                  (if doc-test-prefix-cache-stats
                    (tc-prefix-snapshot-cache-clear!)
                    unit)
                  (doc-test-files
                    input-paths
                    stdlib-roots
                    (> (svec.string-vec-len (& input-paths)) 1)
                    0))]
              (begin
                (if doc-test-prefix-cache-stats
                  (tc-prefix-snapshot-cache-print-stats "doc-test-batch")
                  unit)
                status))]
          [(DocTestCliConfig.Package manifest-path has-manifest stdlib-roots)
            (doc-test-package manifest-path has-manifest stdlib-roots)])]
      [(ResultDocTestCliConfig.Err message)
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
    [(ResultDocDefaultCliConfig.Ok config)
      (match config
        [(DocDefaultCliConfig.Explicit input-paths output-path stdlib-roots)
          (doc-run-explicit-default input-paths output-path stdlib-roots)]
        [(DocDefaultCliConfig.Package manifest-path has-manifest output-path)
          (doc-generate-package manifest-path has-manifest output-path)])]
    [(ResultDocDefaultCliConfig.Err message)
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