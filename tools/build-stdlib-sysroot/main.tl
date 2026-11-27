;; Single-pass embedded stdlib sysroot builder.
;; Loads, typechecks, and lowers the embedded stdlib ONCE, sharing the exact
;; checked program between `stdlib.tli` extraction and per-module `.s` emission
;; for `libstdlib.a`.
(import compiler_ast_types as ast)
(import compiler_backend_state as be_state)
(import compiler_cfg_core as cfg_core)
(import compiler_diagnostic as diag)
(import compiler_embedded_stdlib as embedded)
(cfg embedded-stdlib-tlci (import compiler_embedded_stdlib_tlci as tlci))
(import compiler_load as load)
(import compiler_lower as lower)
(import compiler_target_cfg_core as target_cfg)
(import compiler_tli_extract as extract)
(import compiler_tli_types as tli)
(import compiler_typecheck_api as api)
(import compiler_typecheck_core as tc)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.iterator)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as strings)
(import sym_i64_env as sym_env)

(include-str payload-inventory "../../src/compiler_embedded_stdlib_payload.tl")

(define (embedded-paths) : (__tl_dyn-array String)
  (let
    [out : strings.Vec (strings.new)]
    [cursor : i64 0]
    [prefix : String "\"../stdlib/"]
    [size : i64 (string.string-length (& payload-inventory))]
    (while (< cursor size)
      (if (string.is-string-prefix-at (& payload-inventory) (& prefix) cursor)
        (let
          [start : i64 (+ cursor (string.string-length (& prefix)))]
          [end : i64
            (string.index-of-byte (& payload-inventory) start (cast 34 : u8))]
          (when
            (< end start)
            (io.panic "invalid embedded stdlib source inventory"))
          (strings.push-ref!
            (&mut out)
            (string.substring (& payload-inventory) start (- end start)))
          (set! cursor (+ end 1)))
        (+= cursor 1)))
    (let
      [count : i64 (strings.len (& out))]
      [paths : (__tl_dyn-array String) (__tl_make-array String count)]
      (when (<= count 0) (io.panic "empty embedded stdlib source inventory"))
      (for [index (iterator.range 0 count)]
        (set! (array-ref paths index) (strings.get (& out) index "")))
      paths)))

(define (parse-opt-level [text : (& str)]) : i64
  (cond
    [(string.eq text "0") 0]
    [(string.eq text "1") 1]
    [(string.eq text "2") 2]
    [else
      (io.panic
        (str_cat.str-cat
          "build-stdlib-sysroot: unsupported opt-level: "
          (string.copy text)))]))

(define (build-sysroot!
  [tli-out : (& str)]
  [asm-dir : (& str)]
  [manifest-out : (& str)]
  [target-name : (& str)]
  [opt-level : i64]
  [producer-identity : (& str)]) : unit
  (let
    [windows? : bool
      (cond
        [(string.eq target-name "linux-x86_64") false]
        [(string.eq target-name "windows-x86_64") true]
        [else
          (io.panic
            (str_cat.str-cat
              "build-stdlib-sysroot: unsupported target: "
              (string.copy target-name)))])]
    [target-triple : String
      (if windows?
        "x86_64-pc-windows-msvc"
        "x86_64-unknown-linux-gnu")]
    [lower-mode : lower.CompilerLowerMode
      (if windows?
        (lower.CompilerLowerMode.WindowsScalar)
        (lower.CompilerLowerMode.LinuxScalar))]
    [backend-target : be_state.CompilerBackendTarget
      (if windows?
        (be_state.CompilerBackendTarget.Windows)
        (be_state.CompilerBackendTarget.Linux))]
    [paths : (__tl_dyn-array String) (embedded-paths)]
    [source-count : i64 (array-length paths)]
    [sources : (__tl_dyn-array extract.TliSource)
      (__tl_make-array extract.TliSource source-count)]
    [roots : strings.Vec (strings.new)]
    [decls : ast.AstDeclList (ast.ast-decl-list-new)]
    [decl-paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
    [seen : sym_env.SymI64Env (sym_env.sym-i64-empty)]
    [_reset-load : unit (api.compiler-typecheck-reset-load-session!)]
    [cfgs : sym_env.SymI64Env
      (if windows?
        (target_cfg.compiler-target-enable-windows-cfgs
          (cfg_core.compiler-cfg-empty))
        (target_cfg.compiler-target-enable-linux-cfgs
          (cfg_core.compiler-cfg-empty)))]
    (for [index (iterator.range 0 source-count)]
      (let
        [suffix (& (array-ref paths index))]
        [path : String (str_cat.str-cat "stdlib/" (string.copy suffix))]
        [module-name : String
          (load.compiler-load-canonical-module-id-from-path (& path))]
        [source : String
          (match (embedded.compiler-embedded-stdlib-lookup (string.copy suffix))
            [(CompilerEmbeddedStdlibSomeSource source) source]
            [_
              (io.panic
                (str_cat.str-cat
                  "missing embedded source "
                  (string.copy suffix)))])]
        (set!
          (array-ref sources index)
          (extract.TliSource
            module-name
            (string.copy (& path))
            (extract.tli-extract-sha256 (byte_buf.str-as-bytes (& source)))))
        (match (load.compiler-load-stdlib-prelude-file-with-roots-cfg
          (& path)
          seen
          (& roots)
          cfgs)
          [(Ok loaded loaded-paths _ loaded-seen)
            (set!
              decls
              (load.compiler-load-decl-list-append (& decls) (& loaded)))
            (set!
              decl-paths
              (load.compiler-load-decl-path-list-append
                (& decl-paths)
                (& loaded-paths)))
            (set! seen loaded-seen)]
          [(Err failure)
            (io.panic
              (diag.compiler-diagnostic-render (& (__tl-box-place failure))))])))
    (let
      [request : api.TypecheckRequest
        (api.typecheck-request-serial
          (ast.AstProgram.Program (box decls))
          decl-paths
          roots
          cfgs
          (tc.tc-prefix-default-cache-scope))]
      [cfg-digest : (Array u8 32)
        (extract.tli-extract-stdlib-cfg-digest request.cfgs)]
      [records : (__tl_dyn-array extract.TliExtractModule)
        (extract.tli-extract-open-modules (& request) (& sources))]
      [job : tc.TcJobState request.job-state]
      [let-facts : tc.TcCheckedLetBindingFactState
        (tc.tc-job-state-checked-let-binding-facts job)]
      [bundle-flags : i64
        (+
          tli.tli-is-stdlib-bundle
          (cfg embedded-stdlib-tlci tli.tli-has-tlci-companion 0))]
      (set! request.retain-global-call-effects true)
      (tc.tc-checked-let-binding-facts-begin! let-facts false)
      (match (extract.tli-typecheck-for-extract-and-lower request)
        [(or (Partial diagnostics _ _ _) (Err diagnostics))
          (tc.tc-global-call-effects-finish! job)
          (tc.tc-checked-let-binding-facts-finish! let-facts)
          (io.panic
            (diag.compiler-diagnostic-render
              (&
                (diag.compiler-diagnostic-list-first
                  (& (__tl-box-place diagnostics))))))]
        [(Ok _ ctx env checked-paths)
          (tc.tc-checked-let-binding-facts-freeze! let-facts)
          (let
            [all-sources : (__tl_dyn-array extract.TliSource)
              (extract.tli-extract-add-generated-sources
                ctx
                (& checked-paths)
                (& sources))]
            [all-records : (__tl_dyn-array extract.TliExtractModule)
              (extract.tli-extract-extend-records records (& all-sources))]
            [bundle : tli.TliBundle
              (extract.tli-extract-checked
                ctx
                env
                (& checked-paths)
                (& all-sources)
                all-records
                (& cfg-digest)
                bundle-flags
                (string.copy producer-identity)
                (string.copy (& target-triple)))]
            (tc.tc-global-call-effects-finish! job)
            ;; Lower the EXACT same checked program once with opt-in module
            ;; ownership and per-module startup wrappers, then attach v3
            ;; compact_ir + packed optimizer summaries to `stdlib.tli` before
            ;; emitting partitioned per-module `.s` files.
            (let
              [pools : ast.AstNodePoolContext (tc.tc-context-pools ctx)]
              [checked-program : ast.AstProgram (tc.tc-context-program ctx)]
              [lower-state : lower.CompilerLowerState
                (lower.compiler-lower-state-new)]
              (lower.compiler-lower-state-enable-module-ownership!
                lower-state
                true)
              (ast.ast-node-pool-context-install! pools)
              (let
                [lower-names : lower.LowerNameEnv
                  (match (& checked-program)
                    [(ast.AstProgram.Program decls-box)
                      (lower.lower-name-env-from-decls-with-state
                        lower-state
                        (& (deref decls-box))
                        (& checked-paths)
                        ""
                        lower.LowerNameEnv.Nil)])]
                (match (lower.lower-compiler-program-checked-with-names-mode
                  lower-state
                  ctx
                  (tc.tc-env-with-cache env)
                  checked-program
                  checked-paths
                  ""
                  lower-names
                  lower-mode)
                  [(Err diag-box)
                    (tc.tc-checked-let-binding-facts-finish! let-facts)
                    (io.panic
                      (diag.compiler-diagnostic-render
                        (& (__tl-box-place diag-box))))]
                  [(Ok whole-program whole-spans lower-owner)
                    (tc.tc-checked-let-binding-facts-finish! let-facts)
                    (match (extract.tli-emit-partitioned-modules!
                      (&mut bundle)
                      tli-out
                      producer-identity
                      (& target-triple)
                      whole-program
                      whole-spans
                      lower-owner
                      pools
                      job
                      asm-dir
                      manifest-out
                      backend-target
                      (be_state.CompilerBackendMode.Scalar)
                      windows?
                      opt-level
                      true
                      (extract.TliPartitionObjectRoute.Assembly))
                      [(Err message) (io.panic message)]
                      [(Ok emitted)
                        (io.println
                          "build-stdlib-sysroot: {} total modules, {} emitted, {} skipped (empty), target={}"
                          (array-length bundle.modules)
                          emitted.emitted-modules
                          emitted.skipped-modules
                          target-triple)])
                    (lower.compiler-lower-arena-state-release!
                      (lower.compiler-lower-state-arenas lower-owner))]))))
          (cfg
            embedded-stdlib-tlci
            (tlci.compiler-embedded-stdlib-tlci-session-close!))]))))

(define (main) : i64
  (when
    (!= (io.arg-count) 7)
    (io.panic
      "usage: build-stdlib-sysroot <tli-out> <asm-dir> <manifest-out> <target> <opt-level> <producer-identity>"))
  (let
    [tli-out : String (io.arg 1)]
    [asm-dir : String (io.arg 2)]
    [manifest-out : String (io.arg 3)]
    [target-name : String (io.arg 4)]
    [opt-level : i64 (parse-opt-level (& (io.arg 5)))]
    [producer-identity : String (io.arg 6)]
    (when
      (= (string.string-length (& producer-identity)) 0)
      (io.panic "build-stdlib-sysroot: producer identity must not be empty"))
    (build-sysroot!
      (& tli-out)
      (& asm-dir)
      (& manifest-out)
      (& target-name)
      opt-level
      (& producer-identity)))
  0)