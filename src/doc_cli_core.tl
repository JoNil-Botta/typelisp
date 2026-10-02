;; doc_cli_core.tl - Selfhost doc command logic.
;;
;; Usage:
;;   typelisp doc input.tl output.md
;;   typelisp doc entry.tl imported.tl output.md
;;   typelisp doc --html input.tl output.html
;;   typelisp doc --html entry.tl imported.tl output.html
;;   typelisp doc --test input.tl
;;   typelisp doc --test --batch inputs.txt
;;   typelisp doc --load input.tl output.md [--stdlib-root <dir>...]
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.fs)
(import stdlib.env)
(import stdlib.process)
(import stdlib.vector)
(import (vector.vector String) as doc_svec)
(import cli_option_core as cli_option)
(import doc_render)
(import doc_extract)
(import (vector.vector doc_render.DocModule core) as doc_module_vec)
(import doc_html)
(import doc_local_site)
(import doc_test)
(import doc_expand)
(import compiler_load)
(import compiler_build_identity as build_identity)
(import compiler_ast_types as ast)
(import compiler_diagnostic as cdiag)
(import compiler_typecheck_core as tc)
(import compiler_intern as ci)
(import package_source_core)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as doc_path_map)
(import stdlib.string)
(import source_text_core as source_text)
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
  (Package String bool DocMaybeString bool bool))

(defenum ResultDocDefaultCliConfig
  (Ok DocDefaultCliConfig)
  (Err String))

(define (doc-print-wrote [output-path : String]) : unit
  (io.print-format "{}" (str_cat.str-cat "Wrote " output-path "\n")))

(define (doc-write-text [output-path : (& output-path str)] [contents : String]) : unit
  (io.write-file output-path (byte_buf.str-as-bytes (& contents))))

(define (doc-generate-file [input-path : String] [output-path : String]) : i64
  (let
    [source : String (byte_buf.to-string (io.read-file input-path))]
    [markdown : String
      (doc_render.doc-render-markdown (doc_extract.doc-extract-source source))]
    (begin
      (doc-write-text output-path markdown)
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

(define (doc-modules-from-package-sources-relative-from
  [paths : (& paths doc_svec.Vec)]
  [root : (& root str)]
  [index : i64]
  [modules : (&mut modules doc_module_vec.Vec)]) : unit
  (if (>= index (doc_svec.len (& paths)))
    unit
    (let
      [path : String (doc_svec.get (& paths) index "")]
      [relative : String
        (compiler_load.compiler-load-root-relative-path root path)]
      (begin
        (doc_module_vec.push-ref!
          modules
          (doc_render.DocModule.Module
            relative
            (doc_extract.doc-extract-file path)))
        (doc-modules-from-package-sources-relative-from
          paths
          root
          (+ index 1)
          modules)))))

(define (doc-modules-from-package-source-set
  [source-set : (& source-set package_source_core.PackageSourceSet)]) : doc_module_vec.Vec
  (let
    [root : String
      (compiler_load.compiler-load-normalize-path source-set.manifest-dir)]
    [modules : doc_module_vec.Vec
      (doc_module_vec.with-capacity (doc_svec.len (& source-set.sources)))]
    (begin
      (doc-modules-from-package-sources-relative-from
        source-set.sources
        root
        0
        (&mut modules))
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
                (doc_extract.doc-extract-file path)))
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
  [load-state : compiler_load.CompilerLoadSessionState]
  [job-state : tc.TcJobState]
  [pools : ast.AstNodePoolContext]
  [intern-state : ci.InternCompatState]
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
            [head-modules
              (try
                (doc_expand.doc-expanded-generated-modules-from-source-docs-with-state-and-pools-and-intern-state
                  (owned_view.compiler-owned-shared-view load-state)
                  job-state
                  path
                  docs
                  (owned_view.compiler-owned-shared-view stdlib-roots)
                  pools
                  (owned_view.compiler-owned-shared-view intern-state)))]
            [tail-modules
              (try
                (doc-generated-modules-from-source-paths-into
                  load-state
                  job-state
                  pools
                  intern-state
                  rest
                  seen
                  stdlib-roots))]
            (doc_expand.ResultDocExpandedModules.Ok
              (doc_render.doc-module-list-append head-modules tail-modules)))
          (doc-generated-modules-from-source-paths-into
            load-state
            job-state
            pools
            intern-state
            rest
            seen
            stdlib-roots)))]))

(define (doc-generated-modules-from-source-paths
  [load-state : compiler_load.CompilerLoadSessionState]
  [job-state : tc.TcJobState]
  [pools : ast.AstNodePoolContext]
  [intern-state : ci.InternCompatState]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : doc_svec.Vec]) : doc_expand.ResultDocExpandedModules
  (let
    [seen : doc_path_map.Map (doc-path-set-new)]
    (doc-generated-modules-from-source-paths-into
      load-state
      job-state
      pools
      intern-state
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
  [load-state : compiler_load.CompilerLoadSessionState]
  [pools : ast.AstNodePoolContext]
  [intern-state : ci.InternCompatState]
  [input-path : (& input-path str)]
  [stdlib-roots : doc_svec.Vec]) : compiler_load.ResultCompilerLoadWithPaths
  (let
    [intern-state : ci.InternCompatState intern-state]
    (begin
      (compiler_load.compiler-load-session-state-use-with-intern-state!
        load-state
        (owned_view.compiler-owned-shared-view intern-state))
      (ast.ast-node-pool-context-install! pools)
      (ci.intern-compat-state-install! intern-state)
      (let
        [lazy-mode : bool
          (compiler_load.compiler-load-session-state-lazy-import-mode-enabled?
            (owned_view.compiler-owned-shared-view load-state))]
        [_eager : unit
          (compiler_load.compiler-load-session-state-lazy-import-mode-set-enabled!
            (owned_view.compiler-owned-shared-view load-state)
            false)]
        [loaded : compiler_load.ResultCompilerLoadWithPaths
          (compiler_load.compiler-load-file-with-paths-and-roots-cfg-with-pools
            (owned_view.compiler-owned-shared-view load-state)
            input-path
            (sym_i64_env.sym-i64-empty)
            stdlib-roots
            (sym_i64_env.sym-i64-empty)
            pools)]
        [_publish : unit
          (begin
            ;; The stateful loader extends the explicit segmented context. Do not
            ;; overwrite it with the stale compatibility-global view on return;
            ;; publish the completed owner for the remaining legacy readers.
            (ast.ast-node-pool-context-install! pools)
            (ci.intern-compat-state-capture-from-globals! (&mut intern-state)))]
        [_restore : unit
          (compiler_load.compiler-load-session-state-lazy-import-mode-set-enabled!
            load-state
            lazy-mode)]
        loaded))))

(define (doc-generate-loaded-file
  [input-path : String]
  [output-path : String]
  [stdlib-roots : doc_svec.Vec]) : i64
  (let
    [load-state : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-serial-test-session-state)]
    [job-state : tc.TcJobState (tc.tc-serial-job-state)]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    (match (doc-load-file-with-all-import-paths
      (owned_view.compiler-owned-shared-view load-state)
      pools
      (owned_view.compiler-owned-shared-view intern-state)
      input-path
      (owned_view.compiler-owned-shared-view stdlib-roots))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
        (match (doc-generated-modules-from-source-paths
          (owned_view.compiler-owned-shared-view load-state)
          job-state
          pools
          (owned_view.compiler-owned-shared-view intern-state)
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
                (match (doc_expand.doc-expanded-generated-modules-from-loaded-decls-with-state-and-pools-and-intern-state
                  load-state
                  job-state
                  decls
                  (owned_view.compiler-owned-shared-view paths)
                  stdlib-roots
                  pools
                  intern-state)
                  [(doc_expand.ResultDocExpandedModules.Ok modules) modules]
                  [(doc_expand.ResultDocExpandedModules.Err _)
                    (doc_module_vec.new)])]
              (begin
                (doc-write-text
                  output-path
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
          (io.print-error (cdiag.compiler-diagnostic-render (deref diag)))
          1)])))

(define (doc-ensure-directory [path : String]) : bool
  (match (fs.try-mkdir-if-missing (& path))
    [(io.OkIoUnit) true]
    [(io.ErrIoUnit error)
      (begin
        (io.print-error
          (str_cat.str-cat
            "doc: cannot create output directory '"
            path
            "': "
            (io.error-message error)
            "\n"))
        false)]))

(define (doc-linux-graphical-session?) : bool
  (let
    [display-name : String "DISPLAY"]
    [wayland-name : String "WAYLAND_DISPLAY"]
    (or
      (> (string.string-length (env.var-value (& display-name))) 0)
      (> (string.string-length (env.var-value (& wayland-name))) 0))))

(define (doc-windows-graphical-session?) : bool
  (let
    [session-name : String "SESSIONNAME"]
    [terminal-name : String "WT_SESSION"]
    [session : String (env.var-value (& session-name))]
    (or
      (> (string.string-length (env.var-value (& terminal-name))) 0)
      (and
        (> (string.string-length session) 0)
        (not (string.eq session "Services"))))))

(define (doc-graphical-session?) : bool
  (cfg windows (doc-windows-graphical-session?) (doc-linux-graphical-session?)))

(define (doc-open-program) : String
  (let
    [name : String "TYPELISP_DOC_OPEN_PROGRAM"]
    (match (env.get (& name))
      [(env.EnvSomeString value) value]
      [(env.EnvNoString) (cfg windows "explorer.exe" "xdg-open")])))

(define (doc-open-generated-index [index-path : String]) : unit
  (if (not (doc-graphical-session?))
    (io.print-format
      "{}"
      (str_cat.str-cat "Open skipped; generated index: " index-path "\n"))
    (let
      [result : process.ResultProcessOutput
        (process.run
          (process.command
            (doc-open-program)
            (process.args-single
              (owned_view.compiler-owned-shared-view index-path))))]
      (if (process.result-success? result)
        (io.print-format "{}" (str_cat.str-cat "Opened " index-path "\n"))
        (io.print-format
          "{}"
          (str_cat.str-cat "Open failed; generated index: " index-path "\n"))))))

(define (doc-generate-package-local-site
  [source-set : package_source_core.PackageSourceSet]
  [open? : bool]
  [_no-deps? : bool]) : i64
  (match (package_source_core.package-source-set-digest
    (owned_view.compiler-owned-shared-view source-set))
    [(package_source_core.ResultPackageSourceDigest.Err message)
      (begin
        (io.print-error (str_cat.str-cat "doc: " message "\n"))
        1)]
    [(package_source_core.ResultPackageSourceDigest.Ok source-digest)
      (let
        [target-dir : String
          (fs.path-join-owned-pair source-set.manifest-dir "target")]
        [output-dir : String
          (fs.path-join-owned-pair
            (owned_view.compiler-owned-shared-view target-dir)
            "doc")]
        [index-path : String
          (fs.path-join-owned-pair
            (owned_view.compiler-owned-shared-view output-dir)
            "index.html")]
        [css-path : String
          (fs.path-join-owned-pair
            (owned_view.compiler-owned-shared-view output-dir)
            "typelisp-docs.css")]
        [client-path : String
          (fs.path-join-owned-pair
            (owned_view.compiler-owned-shared-view output-dir)
            "typelisp-docs.js")]
        [search-path : String
          (fs.path-join-owned-pair
            (owned_view.compiler-owned-shared-view output-dir)
            "typelisp-docs-search-index.js")]
        [manifest : compiler_load.CompilerPkgManifest source-set.manifest]
        [package-identity : String
          (doc_local_site.doc-local-site-package-identity
            (owned_view.compiler-owned-shared-view manifest.name)
            manifest.version)]
        [compiler-identity : String
          (build_identity.compiler-build-git-hash-shared-view)]
        [source-identity : String
          (doc_local_site.doc-local-site-source-identity source-digest)]
        [modules : doc_module_vec.Vec
          (doc-modules-from-package-source-set source-set)]
        (if (not (doc-ensure-directory target-dir))
          1
          (if (not (doc-ensure-directory output-dir))
            1
            (begin
              (doc-write-text css-path (doc_local_site.doc-local-site-css))
              (doc-write-text
                client-path
                (doc_local_site.doc-local-site-search-client))
              (doc-write-text
                search-path
                (doc_local_site.doc-local-site-search-index
                  compiler-identity
                  source-identity
                  package-identity
                  (owned_view.compiler-owned-shared-view modules)))
              (doc-write-text
                index-path
                (doc_local_site.doc-local-site-render-index
                  manifest.name
                  compiler-identity
                  source-identity
                  package-identity
                  modules))
              (doc-print-wrote
                (owned_view.compiler-owned-shared-view index-path))
              (if open?
                (doc-open-generated-index index-path)
                unit)
              0))))]))

(define (doc-generate-package
  [manifest-path : String]
  [has-manifest : bool]
  [output-path : DocMaybeString]
  [open? : bool]
  [no-deps? : bool]) : i64
  (match (package_source_core.package-source-discover-for
    "doc"
    manifest-path
    has-manifest)
    [(package_source_core.ResultPackageSourceSet.Err message)
      (begin
        (io.print-error (str_cat.str-cat message "\n"))
        1)]
    [(package_source_core.ResultPackageSourceSet.Ok source-set)
      (match output-path
        [(DocMaybeString.Some out)
          (begin
            (doc-write-text
              out
              (doc_render.doc-render-module-graph-markdown
                (doc-modules-from-package-sources source-set.sources)))
            (doc-print-wrote out)
            0)]
        [(DocMaybeString.No)
          (doc-generate-package-local-site source-set open? no-deps?)])]))

(define (doc-generate-html-file [input-path : String] [output-path : String]) : i64
  (let
    [source : String
      (byte_buf.to-string
        (io.read-file (owned_view.compiler-owned-shared-view input-path)))]
    [html : String (doc_html.doc-html-render-source input-path source)]
    (begin
      (doc-write-text output-path html)
      (doc-print-wrote output-path)
      0)))

(define (doc-generate-html-module-graph [output-path : String]) : i64
  (let
    [modules : doc_module_vec.Vec (doc-read-modules 2 (- (io.arg-count) 1))]
    (begin
      (doc-write-text
        output-path
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
  [paths : (& paths doc_svec.Vec)]
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
        paths
        0
        (- (doc_svec.len (& paths)) 1))]
    (begin
      (doc-write-text
        output-path
        (doc_render.doc-render-module-graph-markdown modules))
      (doc-print-wrote output-path)
      0)))

(define (doc-test-batch-paths-from-text [text : String]) : doc_svec.Vec
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [paths : doc_svec.Vec (doc_svec.new)]
    (begin
      (while (< i n)
        (let
          [line-end : i64 (source_text.line-end text i)]
          [line : String (string.substring text i (- line-end i))]
          (begin
            (if (> (string.string-length line) 0)
              (doc_svec.push-ref! (&mut paths) line)
              unit)
            (set! i (source_text.next-line-start text line-end)))))
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
          (let
            [paths (try (doc-test-batch-paths list-path))]
            (if (doc_svec.is-empty? (& paths))
              (ResultDocTestCliConfig.Err "doc: --batch list is empty")
              (ResultDocTestCliConfig.Ok
                (DocTestCliConfig.File paths stdlib-roots))))))]
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

(define (doc-test-config-from [base : i64] [count : i64]) : ResultDocTestCliConfig
  (let
    [args : cli_option.CliArgs
      (cli_option.cli-args
        "doc"
        "--stdlib-root <dir> --manifest-path <file> --batch <file> --prefix-cache-stats"
        (+ base 1)
        count)]
    [input-paths : doc_svec.Vec (doc_svec.new)]
    [manifest-path : String ""]
    [has-manifest : bool false]
    [stdlib-roots : doc_svec.Vec (doc_svec.new)]
    [batch-list : DocMaybeString (DocMaybeString.No)]
    (begin
      (set! doc-test-prefix-cache-stats false)
      (while (cli_option.cli-args-next! (&mut args))
        (cond
          [(string.eq args.name "--stdlib-root")
            (doc_svec.push-ref!
              (&mut stdlib-roots)
              (cli_option.cli-args-value (& args)))]
          [(string.eq args.name "--manifest-path")
            (if has-manifest
              (cli_option.cli-args-fail!
                (&mut args)
                "doc: duplicate --manifest-path")
              (begin
                (set! manifest-path (cli_option.cli-args-value (& args)))
                (set! has-manifest true)))]
          [(string.eq args.name "--batch")
            (match batch-list
              [(DocMaybeString.Some _)
                (cli_option.cli-args-fail! (&mut args) "doc: duplicate --batch")]
              [(DocMaybeString.No)
                (set!
                  batch-list
                  (DocMaybeString.Some (cli_option.cli-args-value (& args))))])]
          [(string.eq args.name "--prefix-cache-stats")
            (set! doc-test-prefix-cache-stats true)]
          [(cli_option.cli-flag? args.arg)
            (cli_option.cli-args-fail-arg! (&mut args) "doc: unknown flag ")]
          [else
            (doc_svec.push-ref! (&mut input-paths) (string.copy (& args.arg)))]))
      (if args.failed
        (ResultDocTestCliConfig.Err args.error)
        (doc-test-config-finish
          input-paths
          manifest-path
          has-manifest
          stdlib-roots
          batch-list)))))

(define (doc-test-files-from
  [input-paths : (& input-paths doc_svec.Vec)]
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
        input-paths
        (+ index 1)
        stdlib-roots
        print-headers
        (if (= status 0)
          file-status
          status)))))

(define (doc-test-files
  [input-paths : (& input-paths doc_svec.Vec)]
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
        input-paths
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
  [open? : bool]
  [no-deps? : bool]
  [stdlib-roots : doc_svec.Vec]) : ResultDocDefaultCliConfig
  (cond
    [(not (doc_svec.is-empty? (& input-paths)))
      (cond
        [has-manifest
          (ResultDocDefaultCliConfig.Err
            "doc: cannot combine input paths with --manifest-path")]
        [open?
          (ResultDocDefaultCliConfig.Err
            "doc: --open is only valid for package local HTML site output")]
        [no-deps?
          (ResultDocDefaultCliConfig.Err
            "doc: --no-deps is only valid for package documentation")]
        [else
          (ResultDocDefaultCliConfig.Ok
            (DocDefaultCliConfig.Explicit input-paths output-path stdlib-roots))])]
    [else
      (match output-path
        [(DocMaybeString.Some out)
          (if open?
            (ResultDocDefaultCliConfig.Err
              "doc: --open requires local HTML site output; omit -o")
            (ResultDocDefaultCliConfig.Ok
              (DocDefaultCliConfig.Package
                manifest-path
                has-manifest
                (DocMaybeString.Some out)
                false
                no-deps?)))]
        [(DocMaybeString.No)
          (ResultDocDefaultCliConfig.Ok
            (DocDefaultCliConfig.Package
              manifest-path
              has-manifest
              (DocMaybeString.No)
              open?
              no-deps?))])]))

(define (doc-default-config-from [base : i64] [count : i64]) : ResultDocDefaultCliConfig
  (let
    [args : cli_option.CliArgs
      (cli_option.cli-args
        "doc"
        "--stdlib-root <dir> -o <out.md> --manifest-path <file> --open --no-deps"
        base
        count)]
    [input-paths : doc_svec.Vec (doc_svec.new)]
    [output-path : DocMaybeString (DocMaybeString.No)]
    [manifest-path : String ""]
    [open? : bool false]
    [no-deps? : bool false]
    [stdlib-roots : doc_svec.Vec (doc_svec.new)]
    (begin
      (while (cli_option.cli-args-next! (&mut args))
        (cond
          [(string.eq args.name "--stdlib-root")
            (doc_svec.push-ref!
              (&mut stdlib-roots)
              (cli_option.cli-args-value (& args)))]
          [(string.eq args.name "-o")
            (match output-path
              [(DocMaybeString.Some _)
                (cli_option.cli-args-fail! (&mut args) "doc: duplicate -o")]
              [(DocMaybeString.No)
                (set!
                  output-path
                  (DocMaybeString.Some (cli_option.cli-args-value (& args))))])]
          ;; An empty --manifest-path value reads as absent, so a later one is
          ;; not a duplicate.
          [(string.eq args.name "--manifest-path")
            (if (not (string.eq manifest-path ""))
              (cli_option.cli-args-fail!
                (&mut args)
                "doc: duplicate --manifest-path")
              (set! manifest-path (cli_option.cli-args-value (& args))))]
          [(string.eq args.name "--open")
            (if open?
              (cli_option.cli-args-fail! (&mut args) "doc: duplicate --open")
              (set! open? true))]
          [(string.eq args.name "--no-deps")
            (if no-deps?
              (cli_option.cli-args-fail! (&mut args) "doc: duplicate --no-deps")
              (set! no-deps? true))]
          [(cli_option.cli-flag? args.arg)
            (cli_option.cli-args-fail-arg! (&mut args) "doc: unknown flag ")]
          [else
            (doc_svec.push-ref! (&mut input-paths) (string.copy (& args.arg)))]))
      (if args.failed
        (ResultDocDefaultCliConfig.Err args.error)
        (doc-default-config-finish
          input-paths
          output-path
          (string.copy (& manifest-path))
          (not (string.eq manifest-path ""))
          open?
          no-deps?
          stdlib-roots)))))

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
;; ... The unified dispatcher passes base=2.
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
                    input-paths
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
        [(DocDefaultCliConfig.Package
            manifest-path
            has-manifest
            output-path
            open?
            no-deps?)
          (doc-generate-package
            manifest-path
            has-manifest
            output-path
            open?
            no-deps?)])]
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