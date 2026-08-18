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
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector String) as doc_svec)
(import cli_option_core as cli_option)
(import doc_render)
(import doc_extract)
(import (vector.vector doc_render.DocModule core) as doc_module_vec)
(import doc_html)
(import doc_test)
(import doc_expand)
(import compiler_load)
(import compiler_ast_types as ast)
(import compiler_diagnostic as cdiag)
(import compiler_typecheck_core as tc)
(import package_source_core)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as doc_path_map)
(import stdlib.string)
(import sym_i64_env)

(defenum DocMaybeString
  (No)
  (Some String))

(defenum DocTestCliConfig
  (File doc_svec.Vec doc_svec.Vec)
  (Package String bool doc_svec.Vec))

(defenum ResultDocTestBatchPaths
  (Ok doc_svec.Vec)
  (Err String))

(defenum ResultDocTestCliConfig
  (Ok DocTestCliConfig)
  (Err String))

(define doc-test-prefix-cache-stats : bool
  false)

(defenum DocDefaultCliConfig
  (Explicit doc_svec.Vec DocMaybeString doc_svec.Vec)
  (Package String bool String))

(defenum ResultDocDefaultCliConfig
  (Ok DocDefaultCliConfig)
  (Err String))

(define (doc-print-wrote [output-path : String]) : unit
  (io.print-format "{}" (str_cat.str-cat "Wrote " output-path "\n")))

(define (doc-write-text [output-path : String] [contents : String]) : unit
  (io.write-file output-path (byte_buf.str-as-bytes (& contents))))

(define (doc-generate-file [input-path : String] [output-path : String]) : i64
  (let
    [source : String
      (byte_buf.to-string
        (io.read-file (owned_view.compiler-owned-shared-view input-path)))]
    [markdown : String
      (doc_render.doc-render-markdown (doc_extract.doc-extract-source source))]
    (begin
      (doc-write-text
        (owned_view.compiler-owned-shared-view output-path)
        markdown)
      (doc-print-wrote output-path)
      0)))

(define (doc-read-modules [idx : i64] [end : i64]) : doc_module_vec.Vec
  (let
    [i : i64 idx]
    [modules : doc_module_vec.Vec (doc_module_vec.with-capacity (- end idx))]
    (begin
      (while (< i end)
        (begin
          (doc_module_vec.push-ref!
            (&mut modules)
            (doc_render.DocModule.Module
              (io.arg i)
              (doc_extract.doc-extract-file (io.arg i))))
          (set! i (+ i 1))))
      modules)))

(define (doc-modules-from-package-sources-from
  [paths : doc_svec.Vec]
  [index : i64]
  [modules : (&mut modules doc_module_vec.Vec)]) : unit
  (if (>= index (doc_svec.len (& paths)))
    unit
    (let
      [path : String (doc_svec.get (& paths) index "")]
      (begin
        (doc_module_vec.push-ref!
          modules
          (doc_render.DocModule.Module
            (owned_view.compiler-owned-shared-view path)
            (doc_extract.doc-extract-file path)))
        (doc-modules-from-package-sources-from paths (+ index 1) modules)))))

(define (doc-modules-from-package-sources [paths : doc_svec.Vec]) : doc_module_vec.Vec
  (let
    [modules : doc_module_vec.Vec
      (doc_module_vec.with-capacity (doc_svec.len (& paths)))]
    (begin
      (doc-modules-from-package-sources-from paths 0 (&mut modules))
      modules)))

(define (doc-path-set-new) : doc_path_map.Map
  (doc_path_map.with-capacity 64))

(define (doc-modules-from-paths-into
  [paths : ast.AstDeclPathList]
  [seen : (&mut seen doc_path_map.Map)]
  [modules : (&mut modules doc_module_vec.Vec)]) : unit
  (match (ast.ast-decl-path-list-step paths)
    [(ast.AstDeclPathListStep.Nil) unit]
    [(ast.AstDeclPathListStep.Cons path rest)
      (let
        [rest : ast.AstDeclPathList rest]
        (if (doc_path_map.insert-if-absent-ref!
          seen
          (owned_view.compiler-owned-shared-view path)
          1)
          (begin
            (doc_module_vec.push-ref!
              modules
              (doc_render.DocModule.Module
                (owned_view.compiler-owned-shared-view path)
                (doc_extract.doc-extract-file
                  (owned_view.compiler-owned-shared-view path))))
            (doc-modules-from-paths-into rest seen modules))
          (doc-modules-from-paths-into rest seen modules)))]))

(define (doc-modules-from-paths [paths : ast.AstDeclPathList]) : doc_module_vec.Vec
  (let
    [modules : doc_module_vec.Vec (doc_module_vec.new)]
    [seen : doc_path_map.Map (doc-path-set-new)]
    (begin
      (doc-modules-from-paths-into paths (&mut seen) (&mut modules))
      modules)))

(define (doc-generated-modules-from-source-paths-into
  [paths : ast.AstDeclPathList]
  [seen : (&mut seen doc_path_map.Map)]
  [stdlib-roots : doc_svec.Vec]) : doc_expand.ResultDocExpandedModules
  (match (ast.ast-decl-path-list-step paths)
    [(ast.AstDeclPathListStep.Nil)
      (doc_expand.ResultDocExpandedModules.Ok (doc_module_vec.new))]
    [(ast.AstDeclPathListStep.Cons path rest)
      (let
        [rest : ast.AstDeclPathList rest]
        (if (doc_path_map.insert-if-absent-ref!
          seen
          (owned_view.compiler-owned-shared-view path)
          1)
          (let
            [docs : doc_extract.DocExtraction
              (doc_extract.doc-extract-file
                (owned_view.compiler-owned-shared-view path))]
            (match (doc_expand.doc-expanded-generated-modules-from-source-docs
              (owned_view.compiler-owned-shared-view path)
              docs
              (owned_view.compiler-owned-shared-view stdlib-roots))
              [(doc_expand.ResultDocExpandedModules.Ok head-modules)
                (match (doc-generated-modules-from-source-paths-into
                  (owned_view.compiler-owned-shared-view rest)
                  seen
                  (owned_view.compiler-owned-shared-view stdlib-roots))
                  [(doc_expand.ResultDocExpandedModules.Ok tail-modules)
                    (doc_expand.ResultDocExpandedModules.Ok
                      (doc_render.doc-module-list-append
                        head-modules
                        tail-modules))]
                  [(doc_expand.ResultDocExpandedModules.Err message)
                    (doc_expand.ResultDocExpandedModules.Err message)])]
              [(doc_expand.ResultDocExpandedModules.Err message)
                (doc_expand.ResultDocExpandedModules.Err message)]))
          (doc-generated-modules-from-source-paths-into rest seen stdlib-roots)))]))

(define (doc-generated-modules-from-source-paths
  [paths : ast.AstDeclPathList]
  [stdlib-roots : doc_svec.Vec]) : doc_expand.ResultDocExpandedModules
  (let
    [seen : doc_path_map.Map (doc-path-set-new)]
    (doc-generated-modules-from-source-paths-into
      paths
      (&mut seen)
      stdlib-roots)))

(define (doc-render-loaded-markdown
  [input-path : String]
  [paths : ast.AstDeclPathList]
  [generated-modules : doc_module_vec.Vec]) : String
  (let
    [modules : doc_module_vec.Vec
      (doc-modules-from-paths
        (ast.ast-decl-root-path-cons
          (owned_view.compiler-owned-shared-view input-path)
          paths))]
    [all-modules : doc_module_vec.Vec
      (doc_render.doc-module-list-append modules generated-modules)]
    (if (>
      (doc_render.doc-module-list-count
        (owned_view.compiler-owned-shared-view all-modules))
      1)
      (doc_render.doc-render-module-graph-markdown all-modules)
      (doc_render.doc-render-markdown (doc_extract.doc-extract-file input-path)))))

;; Compilation may elide unused dotted imports after reading their surfaces.
;; Documentation graphs instead describe the source's complete explicit import
;; closure, so temporarily make this loader session eager and restore its prior
;; mode before rendering or reporting a diagnostic.
(define (doc-load-file-with-all-import-paths
  [input-path : String]
  [stdlib-roots : doc_svec.Vec]) : compiler_load.ResultCompilerLoadWithPaths
  (let
    [lazy-mode : bool
      (compiler_load.compiler-load-session-lazy-import-mode-enabled?)]
    [_eager : unit
      (compiler_load.compiler-load-session-lazy-import-mode-set-enabled! false)]
    [loaded : compiler_load.ResultCompilerLoadWithPaths
      (compiler_load.compiler-load-file-with-paths-and-roots
        input-path
        (sym_i64_env.sym-i64-empty)
        stdlib-roots)]
    [_restore : unit
      (compiler_load.compiler-load-session-lazy-import-mode-set-enabled!
        lazy-mode)]
    loaded))

(define (doc-generate-loaded-file
  [input-path : String]
  [output-path : String]
  [stdlib-roots : doc_svec.Vec]) : i64
  (match (doc-load-file-with-all-import-paths
    (owned_view.compiler-owned-shared-view input-path)
    (owned_view.compiler-owned-shared-view stdlib-roots))
    [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
      (match (doc-generated-modules-from-source-paths
        (ast.ast-decl-root-path-cons
          (owned_view.compiler-owned-shared-view input-path)
          (owned_view.compiler-owned-shared-view paths))
        (owned_view.compiler-owned-shared-view stdlib-roots))
        [(doc_expand.ResultDocExpandedModules.Ok source-generated-modules)
          (let
            ;; Expansion from public source docs is authoritative and errors
            ;; above fail the command. Loaded graph expansion is best-effort:
            ;; synthetic graph docs can combine helper declarations from many
            ;; modules in ways normal source builds never do.
            [generated-modules : doc_module_vec.Vec
              (match (doc_expand.doc-expanded-generated-modules-from-loaded-decls
                decls
                (owned_view.compiler-owned-shared-view paths)
                (owned_view.compiler-owned-shared-view stdlib-roots))
                [(doc_expand.ResultDocExpandedModules.Ok modules) modules]
                [(doc_expand.ResultDocExpandedModules.Err _)
                  (doc_module_vec.new)])]
            (begin
              (doc-write-text
                (owned_view.compiler-owned-shared-view output-path)
                (doc-render-loaded-markdown
                  input-path
                  paths
                  (doc_render.doc-module-list-append
                    generated-modules
                    source-generated-modules)))
              (doc-print-wrote output-path)
              0))]
        [(doc_expand.ResultDocExpandedModules.Err message)
          (begin
            (io.print-error message)
            1)])]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (begin
        (io.print-error
          (cdiag.compiler-diagnostic-render
            (cdiag.compiler-diagnostic-box-shared-view diag)))
        1)]))

(define (doc-generate-package
  [manifest-path : String]
  [has-manifest : bool]
  [output-path : String]) : i64
  (match (package_source_core.package-source-discover-for
    "doc"
    manifest-path
    has-manifest)
    [(package_source_core.ResultPackageSourceSet.Err message)
      (begin
        (io.print-error (str_cat.str-cat message "\n"))
        1)]
    [(package_source_core.ResultPackageSourceSet.Ok source-set)
      (begin
        (doc-write-text
          (owned_view.compiler-owned-shared-view output-path)
          (doc_render.doc-render-module-graph-markdown
            (doc-modules-from-package-sources source-set.sources)))
        (doc-print-wrote output-path)
        0)]))

(define (doc-generate-html-file [input-path : String] [output-path : String]) : i64
  (let
    [source : String
      (byte_buf.to-string
        (io.read-file (owned_view.compiler-owned-shared-view input-path)))]
    [html : String
      (doc_html.doc-html-render-source
        (owned_view.compiler-owned-shared-view input-path)
        source)]
    (begin
      (doc-write-text (owned_view.compiler-owned-shared-view output-path) html)
      (doc-print-wrote output-path)
      0)))

(define (doc-generate-html-module-graph [output-path : String]) : i64
  (let
    [modules : doc_module_vec.Vec (doc-read-modules 2 (- (io.arg-count) 1))]
    (begin
      (doc-write-text
        (owned_view.compiler-owned-shared-view output-path)
        (doc_html.doc-html-render-module-graph modules))
      (doc-print-wrote output-path)
      0)))

(define (doc-test-file [input-path : String] [stdlib-roots : doc_svec.Vec]) : i64
  (let
    [report : doc_test.DocTestRunReport
      (doc_test.doc-test-run-file-with-roots input-path stdlib-roots)]
    (begin
      (if (doc_test.doc-test-run-report-ok?
        (owned_view.compiler-owned-shared-view report))
        (io.print-format
          "{}"
          (str_cat.str-cat
            (doc_test.doc-test-run-report-render
              (owned_view.compiler-owned-shared-view report))
            "\n"))
        (io.print-error
          (doc_test.doc-test-run-report-render
            (owned_view.compiler-owned-shared-view report))))
      (doc_test.doc-test-run-report-status report))))

(define (doc-flag? [value : String]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (doc-stdlib-roots [idx : i64]) : doc_svec.Vec
  (let
    [i : i64 idx]
    [n : i64 (io.arg-count)]
    [roots : doc_svec.Vec (doc_svec.new)]
    (begin
      (while (< i n)
        (if (string.eq (io.arg i) "--stdlib-root")
          (if (< (+ i 1) n)
            (begin
              (doc_svec.push-ref! (&mut roots) (io.arg (+ i 1)))
              (set! i (+ i 2)))
            (set! i n))
          (set! i (+ i 1))))
      roots)))

(define (doc-modules-from-input-paths-before-last
  [paths : doc_svec.Vec]
  [index : i64]
  [last-index : i64]) : doc_module_vec.Vec
  (let
    [i : i64 index]
    [modules : doc_module_vec.Vec
      (doc_module_vec.with-capacity (- last-index index))]
    (begin
      (while (< i last-index)
        (let
          [path : String (doc_svec.get (& paths) i "")]
          (begin
            (doc_module_vec.push-ref!
              (&mut modules)
              (doc_render.DocModule.Module
                (owned_view.compiler-owned-shared-view path)
                (doc_extract.doc-extract-file path)))
            (set! i (+ i 1)))))
      modules)))

(define (doc-generate-module-graph-from-input-paths [paths : doc_svec.Vec]) : i64
  (let
    [output-path : String (doc_svec.last (& paths) "")]
    [modules : doc_module_vec.Vec
      (doc-modules-from-input-paths-before-last
        (owned_view.compiler-owned-shared-view paths)
        0
        (- (doc_svec.len (& paths)) 1))]
    (begin
      (doc-write-text
        (owned_view.compiler-owned-shared-view output-path)
        (doc_render.doc-render-module-graph-markdown modules))
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

(define (doc-test-batch-paths-from-text [text : String]) : doc_svec.Vec
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [paths : doc_svec.Vec (doc_svec.new)]
    (begin
      (while (< i n)
        (let
          [line-end : i64
            (doc-test-batch-line-end
              (owned_view.compiler-owned-shared-view text)
              i
              n)]
          [line : String (string.substring text i (- line-end i))]
          (begin
            (if (> (string.string-length line) 0)
              (doc_svec.push-ref! (&mut paths) line)
              unit)
            (set!
              i
              (doc-test-batch-next-line-start
                (owned_view.compiler-owned-shared-view text)
                line-end
                n)))))
      paths)))

(define (doc-test-batch-paths [list-path : String]) : ResultDocTestBatchPaths
  (match (io.try-read-file (& list-path))
    [(io.OkIoBytes contents)
      (ResultDocTestBatchPaths.Ok
        (doc-test-batch-paths-from-text (byte_buf.to-string contents)))]
    [(io.ErrIoBytes error)
      (ResultDocTestBatchPaths.Err
        (str_cat.str-cat
          "doc: failed to read --batch list file: "
          (io.error-message error)))]))

(define (doc-test-config-finish
  [input-paths : doc_svec.Vec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : doc_svec.Vec]
  [batch-list : DocMaybeString]) : ResultDocTestCliConfig
  (match batch-list
    [(DocMaybeString.Some list-path)
      (if has-manifest
        (ResultDocTestCliConfig.Err
          "doc: cannot combine --batch with --manifest-path")
        (if (not (doc_svec.is-empty? (& input-paths)))
          (ResultDocTestCliConfig.Err
            "doc: cannot combine input paths with --batch")
          (match (doc-test-batch-paths list-path)
            [(ResultDocTestBatchPaths.Ok paths)
              (if (doc_svec.is-empty? (& paths))
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
        [(doc_svec.is-empty? (& input-paths))
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
  [input-paths : doc_svec.Vec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : doc_svec.Vec]
  [batch-list : DocMaybeString]) : ResultDocTestCliConfig
  (if (>= idx count)
    (doc-test-config-finish
      input-paths
      (owned_view.compiler-owned-shared-view manifest-path)
      has-manifest
      stdlib-roots
      batch-list)
    (let
      [current : String (io.arg idx)]
      (match (cli_option.cli-common-option-parse
        (owned_view.compiler-owned-shared-view current)
        idx
        count
        cli_option.cli-common-option-stdlib-root)
        [(cli_option.CliCommonOption.Missing kind)
          (ResultDocTestCliConfig.Err
            (cli_option.cli-common-option-missing-message "doc" kind))]
        [(cli_option.CliCommonOption.Value _ value next-idx)
          (doc-test-parse-options
            next-idx
            count
            input-paths
            manifest-path
            has-manifest
            (let
              [next-roots : doc_svec.Vec
                (owned_view.compiler-owned-shared-view stdlib-roots)]
              (begin
                (doc_svec.push-ref! (&mut next-roots) value)
                next-roots))
            batch-list)]
        [(cli_option.CliCommonOption.NotCommon)
          (cond
            [(string.eq current "--manifest-path")
              (if (>= (+ idx 1) count)
                (ResultDocTestCliConfig.Err
                  "doc: --manifest-path requires a value")
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
            [(doc-flag? (owned_view.compiler-owned-shared-view current))
              (ResultDocTestCliConfig.Err
                (str_cat.str-cat "doc: unknown flag " current))]
            [else
              (doc-test-parse-options
                (+ idx 1)
                count
                (let
                  [next-paths : doc_svec.Vec
                    (owned_view.compiler-owned-shared-view input-paths)]
                  (begin
                    (doc_svec.push-ref! (&mut next-paths) current)
                    next-paths))
                manifest-path
                has-manifest
                stdlib-roots
                batch-list)])]))))

(define (doc-test-config-from [base : i64] [count : i64]) : ResultDocTestCliConfig
  (begin
    (set! doc-test-prefix-cache-stats false)
    (doc-test-parse-options
      (+ base 1)
      count
      (doc_svec.new)
      ""
      false
      (doc_svec.new)
      (DocMaybeString.No))))

(define (doc-test-files-from
  [input-paths : doc_svec.Vec]
  [index : i64]
  [stdlib-roots : doc_svec.Vec]
  [print-headers : bool]
  [status : i64]) : i64
  (if (>= index (doc_svec.len (& input-paths)))
    status
    (let
      [input-path : String (doc_svec.get (& input-paths) index "")]
      [file-status : i64
        (begin
          (if print-headers
            (io.print-format
              "{}"
              (str_cat.str-cat
                "--- "
                (owned_view.compiler-owned-shared-view input-path)
                "\n"))
            unit)
          (doc-test-file
            input-path
            (owned_view.compiler-owned-shared-view stdlib-roots)))]
      (doc-test-files-from
        (owned_view.compiler-owned-shared-view input-paths)
        (+ index 1)
        stdlib-roots
        print-headers
        (if (= status 0)
          file-status
          status)))))

(define (doc-test-files
  [input-paths : doc_svec.Vec]
  [stdlib-roots : doc_svec.Vec]
  [print-headers : bool]
  [status : i64]) : i64
  (doc-test-files-from input-paths 0 stdlib-roots print-headers status))

(define (doc-test-package-files-from
  [input-paths : doc_svec.Vec]
  [index : i64]
  [stdlib-roots : doc_svec.Vec]
  [status : i64]) : i64
  (if (>= index (doc_svec.len (& input-paths)))
    status
    (let
      [input-path : String (doc_svec.get (& input-paths) index "")]
      [file-status : i64
        (begin
          (io.print-format
            "{}"
            (str_cat.str-cat
              "--- "
              (owned_view.compiler-owned-shared-view input-path)
              "\n"))
          (doc-test-file
            input-path
            (owned_view.compiler-owned-shared-view stdlib-roots)))]
      (doc-test-package-files-from
        (owned_view.compiler-owned-shared-view input-paths)
        (+ index 1)
        stdlib-roots
        (if (= status 0)
          file-status
          status)))))

(define (doc-test-package-files
  [input-paths : doc_svec.Vec]
  [stdlib-roots : doc_svec.Vec]
  [status : i64]) : i64
  (doc-test-package-files-from input-paths 0 stdlib-roots status))

(define (doc-test-package
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : doc_svec.Vec]) : i64
  (match (package_source_core.package-source-discover-for
    "doc"
    manifest-path
    has-manifest)
    [(package_source_core.ResultPackageSourceSet.Err message)
      (begin
        (io.print-error (str_cat.str-cat message "\n"))
        1)]
    [(package_source_core.ResultPackageSourceSet.Ok source-set)
      (doc-test-package-files source-set.sources stdlib-roots 0)]))

(define (doc-default-config-finish
  [input-paths : doc_svec.Vec]
  [output-path : DocMaybeString]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : doc_svec.Vec]) : ResultDocDefaultCliConfig
  (if (doc_svec.is-empty? (& input-paths))
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
  [input-paths : doc_svec.Vec]
  [output-path : DocMaybeString]
  [manifest-path : String]
  [stdlib-roots : doc_svec.Vec]) : ResultDocDefaultCliConfig
  (if (>= idx count)
    (doc-default-config-finish
      input-paths
      output-path
      (owned_view.compiler-owned-shared-view manifest-path)
      (not (string.eq manifest-path ""))
      stdlib-roots)
    (let
      [current : String (io.arg idx)]
      (match (cli_option.cli-common-option-parse
        (owned_view.compiler-owned-shared-view current)
        idx
        count
        cli_option.cli-common-option-stdlib-root)
        [(cli_option.CliCommonOption.Missing kind)
          (ResultDocDefaultCliConfig.Err
            (cli_option.cli-common-option-missing-message "doc" kind))]
        [(cli_option.CliCommonOption.Value _ value next-idx)
          (doc-default-parse-options
            next-idx
            count
            input-paths
            output-path
            manifest-path
            (let
              [next-roots : doc_svec.Vec
                (owned_view.compiler-owned-shared-view stdlib-roots)]
              (begin
                (doc_svec.push-ref! (&mut next-roots) value)
                next-roots)))]
        [(cli_option.CliCommonOption.NotCommon)
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
            [(string.eq current "--manifest-path")
              (if (>= (+ idx 1) count)
                (ResultDocDefaultCliConfig.Err
                  "doc: --manifest-path requires a value")
                (if (not (string.eq manifest-path ""))
                  (ResultDocDefaultCliConfig.Err
                    "doc: duplicate --manifest-path")
                  (doc-default-parse-options
                    (+ idx 2)
                    count
                    input-paths
                    output-path
                    (io.arg (+ idx 1))
                    stdlib-roots)))]
            [(doc-flag? (owned_view.compiler-owned-shared-view current))
              (ResultDocDefaultCliConfig.Err
                (str_cat.str-cat "doc: unknown flag " current))]
            [else
              (doc-default-parse-options
                (+ idx 1)
                count
                (let
                  [next-paths : doc_svec.Vec
                    (owned_view.compiler-owned-shared-view input-paths)]
                  (begin
                    (doc_svec.push-ref! (&mut next-paths) current)
                    next-paths))
                output-path
                manifest-path
                stdlib-roots)])]))))

(define (doc-default-config-from [base : i64] [count : i64]) : ResultDocDefaultCliConfig
  (doc-default-parse-options
    base
    count
    (doc_svec.new)
    (DocMaybeString.No)
    ""
    (doc_svec.new)))

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
  [input-paths : doc_svec.Vec]
  [output-path : DocMaybeString]
  [stdlib-roots : doc_svec.Vec]) : i64
  (match output-path
    [(DocMaybeString.Some out)
      (if (doc_svec.is-empty? (& input-paths))
        (doc-invalid-args)
        (doc-generate-loaded-file
          (doc_svec.get (& input-paths) 0 "")
          out
          stdlib-roots))]
    [(DocMaybeString.No)
      (let
        [path-count : i64 (doc_svec.len (& input-paths))]
        (if (= path-count 2)
          (doc-generate-file
            (doc_svec.get (& input-paths) 0 "")
            (doc_svec.get (& input-paths) 1 ""))
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
    (compiler_load.compiler-load-session-cache-enable!)
    (compiler_load.compiler-load-session-program-cache-disable!)
    (match (doc-test-config-from base (io.arg-count))
      [(ResultDocTestCliConfig.Ok config)
        (match config
          [(DocTestCliConfig.File input-paths stdlib-roots)
            (let
              [status : i64
                (begin
                  (if doc-test-prefix-cache-stats
                    (tc.tc-prefix-snapshot-cache-clear!)
                    unit)
                  (doc-test-files
                    (owned_view.compiler-owned-shared-view input-paths)
                    stdlib-roots
                    (> (doc_svec.len (& input-paths)) 1)
                    0))]
              (begin
                (if doc-test-prefix-cache-stats
                  (tc.tc-prefix-snapshot-cache-print-stats "doc-test-batch")
                  unit)
                status))]
          [(DocTestCliConfig.Package manifest-path has-manifest stdlib-roots)
            (doc-test-package manifest-path has-manifest stdlib-roots)])]
      [(ResultDocTestCliConfig.Err message)
        (begin
          (io.print-error message)
          1)])))

(define (doc-main-html [base : i64]) : i64
  (if (= (io.arg-count) (+ base 3))
    (doc-generate-html-file (io.arg (+ base 1)) (io.arg (+ base 2)))
    (if (> (io.arg-count) (+ base 3))
      (doc-generate-html-module-graph (io.arg (- (io.arg-count) 1)))
      (doc-invalid-html-args))))

(define (doc-main-load [base : i64]) : i64
  (if (>= (io.arg-count) (+ base 3))
    (doc-generate-loaded-file
      (io.arg (+ base 1))
      (io.arg (+ base 2))
      (doc-stdlib-roots (+ base 3)))
    (doc-invalid-load-args)))

(define (doc-main-default [base : i64]) : i64
  (match (doc-default-config-from base (io.arg-count))
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