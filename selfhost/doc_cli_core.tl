;; doc_cli_core.tl - Selfhost doc command logic.
;;
;; Usage through the current compiler runner:
;;   typelisp run selfhost/doc.tl -- input.tl output.md
;;   typelisp run selfhost/doc.tl -- entry.tl imported.tl output.md
;;   typelisp run selfhost/doc.tl -- --html input.tl output.html
;;   typelisp run selfhost/doc.tl -- --html entry.tl imported.tl output.html
;;   typelisp run selfhost/doc.tl -- --test input.tl
;;   typelisp run selfhost/doc.tl -- --load input.tl output.md [--stdlib-root <dir>...]
(import "../stdlib/io.tl")

(import "doc_render.tl")

(import "doc_html.tl")

(import "doc_test.tl")

(import "compiler_load.tl")

(defenum DocMaybeString
  (DocNoString)
  (DocSomeString String))

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

(define (doc-generate-module-graph [output-path : String]) : i64
  (let
    [modules : DocModuleList (doc-read-modules 1 (- (arg-count) 1))]
    (begin
      (write-file output-path (doc-render-module-graph-markdown modules))
      (doc-print-generated output-path)
      0)))

(define (doc-generate-loaded-file
  [input-path : String]
  [output-path : String]
  [stdlib-roots : CompilerLoadRootList]) : i64
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

(define (doc-test-file
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (let
    [report : DocTestRunReport
      (doc-test-run-file-with-roots input-path stdlib-roots)]
    (begin
      (if (doc-test-run-report-ok? report)
        (print-string (string-append (doc-test-run-report-render report) "\n"))
        (print-error (doc-test-run-report-render report)))
      (doc-test-run-report-status report))))

(define (doc-stdlib-roots [idx : i64]) : CompilerLoadRootList
  (if (>= idx (arg-count))
    CompilerLoadRootNil
    (if (string-eq (arg idx) "--stdlib-root")
      (if (< (+ idx 1) (arg-count))
        (CompilerLoadRootCons
          (arg (+ idx 1))
          (box (doc-stdlib-roots (+ idx 2))))
        CompilerLoadRootNil)
      (doc-stdlib-roots (+ idx 1)))))

(define (doc-has-output-option [idx : i64]) : bool
  (if (>= idx (arg-count))
    false
    (if (string-eq (arg idx) "-o")
      true
      (doc-has-output-option (+ idx 1)))))

(define (doc-output-option [idx : i64]) : DocMaybeString
  (if (>= idx (arg-count))
    (DocNoString)
    (if (string-eq (arg idx) "-o")
      (if (< (+ idx 1) (arg-count))
        (DocSomeString (arg (+ idx 1)))
        (DocNoString))
      (doc-output-option (+ idx 1)))))

(define (doc-invalid-args) : i64
  (begin
    (print-error "doc: expected input and output paths")
    1))

(define (doc-invalid-test-args) : i64
  (begin
    (print-error "doc: expected --test input path")
    1))

(define (doc-invalid-load-args) : i64
  (begin
    (print-error "doc: expected --load input and output paths")
    1))

(define (doc-invalid-html-args) : i64
  (begin
    (print-error "doc: expected --html input and output paths")
    1))

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
;; ... The standalone driver passes base=1; the unified dispatcher passes base=2.
(define (doc-main-test [base : i64]) : i64
  (if (>= (arg-count) (+ base 2))
    (doc-test-file (arg (+ base 1)) (doc-stdlib-roots (+ base 2)))
    (doc-invalid-test-args)))

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
  (cond
    [(doc-has-output-option (+ base 1))
      (match (doc-output-option (+ base 1))
        [(DocSomeString output-path)
          (doc-generate-loaded-file
            (arg base)
            output-path
            (doc-stdlib-roots (+ base 1)))]
        [(DocNoString) (doc-invalid-args)])]
    [(= (arg-count) (+ base 2)) (doc-generate-file (arg base) (arg (+ base 1)))]
    [(> (arg-count) (+ base 2))
      (doc-generate-module-graph (arg (- (arg-count) 1)))]
    [else (doc-invalid-args)]))

(define (doc-main-dispatch [kind : i64] [base : i64]) : i64
  (match kind
    [1 (doc-main-test base)]
    [2 (doc-main-html base)]
    [3 (doc-main-load base)]
    [_ (doc-main-default base)]))

;; Run the `doc` command; `start` is the index of the command-kind argument.
(define (doc-run-from [start : i64] [count : i64]) : i64
  (if (< count (+ start 1))
    (doc-invalid-args)
    (doc-main-dispatch (doc-command-kind (arg start)) start)))