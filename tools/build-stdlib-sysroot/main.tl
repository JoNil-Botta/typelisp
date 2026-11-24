;; Single-pass embedded stdlib sysroot builder.
;; Loads, typechecks, and lowers the embedded stdlib ONCE, sharing the exact
;; checked program between `stdlib.tli` extraction and per-module `.s` emission
;; for `libstdlib.a`.
(import compiler_abi as abi)
(import compiler_ast_types as ast)
(import compiler_backend as backend)
(import compiler_backend_operands as be_operand)
(import compiler_backend_state as be_state)
(import compiler_cfg_core as cfg_core)
(import compiler_clone as clone_support)
(import compiler_diagnostic as diag)
(import compiler_embedded_stdlib as embedded)
(cfg embedded-stdlib-tlci (import compiler_embedded_stdlib_tlci as tlci))
(import compiler_intern as intern)
(import compiler_ir_types as ir)
(import compiler_load as load)
(import compiler_lower as lower)
(import compiler_optimize as opt)
(import compiler_parse_core as parser)
(import compiler_profile_state as profile_state)
(import compiler_specialize as spec)
(import compiler_target_cfg_core as target_cfg)
(import compiler_tli_codec as codec)
(import compiler_tli_extract as extract)
(import compiler_tli_types as tli)
(import compiler_typecheck_api as api)
(import compiler_typecheck_core as tc)
(import stdlib.byte_buf)
(import stdlib.fs)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as i64_map)
(import (hashmap.hashmap String i64) as str_map)
(import stdlib.io)
(import stdlib.iterator)
(import stdlib.sort)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.text_buf)
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

(define (sanitize-module-filename [name : (& str)]) : String
  (let
    [buf : text_buf.TextBuf (text_buf.empty)]
    [n : i64 (string.string-length name)]
    (for [i (iterator.range 0 n)]
      (let
        [c : char (string.string-ref name i)]
        [ok : bool
          (or
            (and (>= c 'a') (<= c 'z'))
            (and (>= c 'A') (<= c 'Z'))
            (and (>= c '0') (<= c '9'))
            (= c '_')
            (= c '-'))]
        (if ok
          (set! buf (text_buf.append buf (string.substring name i 1)))
          (set! buf (text_buf.append buf "_")))))
    (text_buf.render buf)))

(define (pad3 [n : i64]) : String
  (let
    [s : String (string.int->string n)]
    (cond
      [(< n 10) (str_cat.str-cat "00" s)]
      [(< n 100) (str_cat.str-cat "0" s)]
      [else s])))

(define (sort-strings! [items : (&mut (__tl_dyn-array String))]) : unit
  (let
    [n : i64 (array-length (deref items))]
    (for [i (iterator.range 1 n)]
      (let
        [j : i64 i]
        (while (> j 0)
          (let
            [left-gt : bool
              (sort.string-less-borrowed?
                (& (array-ref (deref items) j))
                (& (array-ref (deref items) (- j 1))))]
            (if left-gt
              (let
                [a : String (string.copy (& (array-ref (deref items) (- j 1))))]
                [b : String (string.copy (& (array-ref (deref items) j)))]
                (set! (array-ref (deref items) (- j 1)) b)
                (set! (array-ref (deref items) j) a)
                (-= j 1))
              (break))))))))

(define (make-fn-physical-signature
  [pools : ast.AstNodePoolContext]
  [params : (& ir.CompilerIrParamSeq)]
  [ret : (& ast.AstType)]) : ast.AstType
  (let
    [list : ast.AstTypeList (ast.ast-type-list-with-capacity params.len)]
    (for [i (iterator.range 0 params.len)]
      (match (& (array-ref params.slots i))
        [(ir.CompilerIrParam.Param _ pty _)
          (ast.ast-type-list-push
            (&mut list)
            (ast.ast-node-pool-context-type-push
              pools
              (ir.compiler-ir-clone-type pools (ast.ty-node-persist pty))))]))
    (let
      [ret-copy : ast.AstType
        (ir.compiler-ir-clone-type pools (ast.ty-node-persist ret))]
      (ast.ast-ty-func list (& ret-copy)))))

(define (intern-symbol!
  [interns : (&mut intern.InternCompatState)]
  [text : String]) : i64
  (let
    [id : i64 (intern.intern-compat-state-intern interns text)]
    (intern.intern-compat-state-install! (& (deref interns)))
    id))

(define (note-ref! [refs : (&mut i64_map.Map)] [symbol-id : i64]) : unit
  (i64_map.insert-ref! refs (ir.compiler-ir-symbol-id symbol-id) 1))

(define (collect-value-refs!
  [refs : (&mut i64_map.Map)]
  [value : (& ir.CompilerIrValue)]) : unit
  (match value
    [(ir.CompilerIrValue.Function name) (note-ref! refs name)]
    [(ir.CompilerIrValue.Global name) (note-ref! refs name)]
    [(ir.CompilerIrValue.GlobalAddr name) (note-ref! refs name)]
    [_ unit]))

(define (fold-value-ref
  [_role : ir.CompilerIrOperandRole]
  [refs : i64_map.Map]
  [value : ir.CompilerIrValue]) : i64_map.Map
  (let
    [out : i64_map.Map refs]
    (collect-value-refs! (&mut out) (& value))
    out))

(define (collect-instr-refs
  [refs : i64_map.Map]
  [instr : (& ir.CompilerIrInstr)]) : i64_map.Map
  (let
    [out : i64_map.Map refs]
    (match instr
      [(or (ir.CompilerIrInstr.Call _ name _ _)
           (ir.CompilerIrInstr.TailCall name _ _))
        (note-ref! (&mut out) name)]
      [(ir.CompilerIrInstr.CallCAbiStoreResult payload-box)
        (match (& (deref payload-box))
          [(fields name) (note-ref! (&mut out) name)])]
      [(ir.CompilerIrInstr.SpmdCall payload-box)
        (match (& (deref payload-box))
          [(fields callee) (note-ref! (&mut out) callee)])]
      [(ir.CompilerIrInstr.Store name _ _) (note-ref! (&mut out) name)]
      [_ unit])
    (ir.compiler-ir-instr-fold-uses (clone (deref instr)) out fold-value-ref)))

(defstruct ModuleRefs
  (refs i64_map.Map))

(define (module-refs-contains? [mrefs : (& ModuleRefs)] [symbol-id : i64]) : bool
  (i64_map.contains? (& mrefs.refs) (ir.compiler-ir-symbol-id symbol-id)))

(define (function-has-syscall? [func : (& ir.CompilerIrFunction)]) : bool
  (match func
    [(ir.CompilerIrFunction.Function _ _ _ _ blocks _)
      (match blocks
        [(ir.CompilerIrBlockList.Array block-seq)
          (let
            [found : bool false]
            (for [bi (iterator.range 0 block-seq.len)]
              (when
                (not found)
                (match (& (array-ref block-seq.slots bi))
                  [(ir.CompilerIrBlock.Block _ instrs)
                    (for [ii (iterator.range 0 instrs.len)]
                      (match (& (array-ref instrs.slots ii))
                        [(ir.CompilerIrInstr.Syscall _ _) (set! found true)]
                        [_ unit]))])))
            found)])]))

(define (function-collect-refs [func : (& ir.CompilerIrFunction)]) : i64_map.Map
  (let
    [refs : i64_map.Map (i64_map.with-capacity 32)]
    (match func
      [(ir.CompilerIrFunction.Function _ _ _ _ blocks _)
        (match blocks
          [(ir.CompilerIrBlockList.Array block-seq)
            (for [bi (iterator.range 0 block-seq.len)]
              (match (& (array-ref block-seq.slots bi))
                [(ir.CompilerIrBlock.Block _ instrs)
                  (for [ii (iterator.range 0 instrs.len)]
                    (set!
                      refs
                      (collect-instr-refs refs (& (array-ref instrs.slots ii)))))]))])])
    refs))

(define (compute-windows-syscall-skip-mask
  [functions : (& ir.CompilerIrFunctionSeq)]) : (__tl_dyn-array bool)
  (let
    [fn-count : i64 functions.len]
    [skip : (__tl_dyn-array bool) (__tl_make-array bool fn-count)]
    [fn-ids : (__tl_dyn-array i64) (__tl_make-array i64 fn-count)]
    [fn-refs : (__tl_dyn-array i64_map.Map)
      (__tl_make-array i64_map.Map fn-count)]
    [changed : bool false]
    (for [i (iterator.range 0 fn-count)]
      (match (& (array-ref functions.slots i))
        [(ir.CompilerIrFunction.Function fn-name _ _ _ _ _)
          (set! (array-ref fn-ids i) (ir.compiler-ir-symbol-id fn-name))])
      (set!
        (array-ref fn-refs i)
        (function-collect-refs (& (array-ref functions.slots i))))
      (when
        (function-has-syscall? (& (array-ref functions.slots i)))
        (set! (array-ref skip i) true)
        (set! changed true)))
    (while changed
      (set! changed false)
      (for [i (iterator.range 0 fn-count)]
        (when
          (not (array-ref skip i))
          (let
            [hit : bool false]
            (for [j (iterator.range 0 fn-count)]
              (when
                (and
                  (not hit)
                  (array-ref skip j)
                  (i64_map.contains?
                    (& (array-ref fn-refs i))
                    (array-ref fn-ids j)))
                (set! hit true)))
            (when hit (set! (array-ref skip i) true) (set! changed true))))))
    skip))

(define (collect-module-refs
  [globals : (& ir.CompilerIrGlobalSeq)]
  [functions : (& ir.CompilerIrFunctionSeq)]) : ModuleRefs
  (let
    [refs : i64_map.Map (i64_map.with-capacity 256)]
    (for [gi (iterator.range 0 globals.len)]
      (match (& (array-ref globals.slots gi))
        [(ir.CompilerIrGlobal.Global _ _ value)
          (collect-value-refs! (&mut refs) (& value))]))
    (for [fi (iterator.range 0 functions.len)]
      (match (& (array-ref functions.slots fi))
        [(ir.CompilerIrFunction.Function _ _ _ _ blocks _)
          (match blocks
            [(ir.CompilerIrBlockList.Array block-seq)
              (for [bi (iterator.range 0 block-seq.len)]
                (match (& (array-ref block-seq.slots bi))
                  [(ir.CompilerIrBlock.Block _ instrs)
                    (for [ii (iterator.range 0 instrs.len)]
                      (set!
                        refs
                        (collect-instr-refs
                          refs
                          (& (array-ref instrs.slots ii)))))]))])]))
    (ModuleRefs refs)))

(define (typecheck-for-tli-and-lower [request : api.TypecheckRequest]) : tc.ResultCompilerTypecheckChecked
  (let
    [observer-job : tc.TcJobState request.job-state]
    (tc.tc-job-state-set-parser-control!
      observer-job
      (parser.compiler-parse-control-from-cfg request.cfgs))
    (match request
      [(api.TypecheckRequest
          load-state
          prefix-cache
          job-state
          program
          paths
          stdlib-roots
          cfgs
          cache-scope
          pools
          request-intern-state
          _semantic-observer
          retain-global-call-effects)
        (let
          [intern-state : intern.InternCompatState request-intern-state]
          (tc.tc-spmd-inline-helper-stack-reset-for-job! job-state)
          (tc.tc-macro-call-site-state-reset!
            (tc.tc-job-state-macro-call-sites job-state))
          (tc.tc-typecheck-checked-result-with-pool-check
            job-state
            (let
              [owner-context : spec.SpecOwnerContext
                (spec.spec-owner-context-new pools (& intern-state))]
              [generated-result : spec.ResultGenProgramWithPaths
                (spec.gen-normalize-program-with-paths-and-pools-and-intern-state
                  (& program)
                  (& paths)
                  ""
                  owner-context)]
              (ast.ast-node-pool-context-install! pools)
              (intern.intern-compat-state-capture-from-globals!
                (&mut intern-state))
              (intern.intern-compat-state-install! (& intern-state))
              (match generated-result
                [(Err diag-box)
                  (tc.ResultCompilerTypecheckChecked.Err
                    (diag.compiler-diagnostic-list-box-single diag-box))]
                [(Ok generated generated-paths)
                  (let
                    [macro-result : tc.ResultMacroExpand
                      (tc.macro-expand-program-with-paths-and-pools-roots-cfg-with-load-state-and-job-state-and-intern-state
                        (load.compiler-load-serial-test-session-state)
                        job-state
                        generated
                        generated-paths
                        pools
                        (strings.new)
                        cfgs
                        (intern.intern-compat-state-capture-active))]
                    (ast.ast-node-pool-context-capture-active! pools)
                    (intern.intern-compat-state-capture-from-globals!
                      (&mut intern-state))
                    (match macro-result
                      [(Err diag-box)
                        (tc.ResultCompilerTypecheckChecked.Err
                          (diag.compiler-diagnostic-list-box-single diag-box))]
                      [(Ok expanded expanded-paths)
                        (tc.tc-clone-root-collection-use!
                          job-state
                          (match (& expanded)
                            [(ast.AstProgram.Program decls-box)
                              (ast.AstProgram.Program
                                (box (clone (deref decls-box))))]))
                        (tc.tc-typecheck-specialized-program-with-selected-lowering
                          load-state
                          prefix-cache
                          job-state
                          expanded
                          expanded-paths
                          stdlib-roots
                          cache-scope
                          pools
                          (intern.intern-source-name-session-handle
                            (intern.intern-source-name-session-from-state
                              (& intern-state)))
                          (intern.intern-compat-state-capture-active)
                          true
                          retain-global-call-effects)]))]))))])))

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
    [cfgs : sym_env.SymI64Env
      (if windows?
        (target_cfg.compiler-target-enable-windows-cfgs
          (cfg_core.compiler-cfg-empty))
        (target_cfg.compiler-target-enable-linux-cfgs
          (cfg_core.compiler-cfg-empty)))]
    [decls : ast.AstDeclList (ast.ast-decl-list-new)]
    [decl-paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
    [seen : sym_env.SymI64Env (sym_env.sym-i64-empty)]
    (api.compiler-typecheck-reset-load-session!)
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
      [cfg-digest : (Array u8 32) (extract.tli-extract-cfg-digest request.cfgs)]
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
      (match (typecheck-for-tli-and-lower request)
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
            (unless
              (extract.tli-extract-pin-imports! (&mut bundle))
              (io.panic "TLI import cycle cannot pin module record digests"))
            (tc.tc-global-call-effects-finish! job)
            (let
              [encoded-arr : (__tl_dyn-array u8)
                (codec.tli-encode-bundle (& bundle))]
              [encoded : byte_buf.ByteBuf
                (byte_buf.from-array
                  (let
                    [copy-bytes : (__tl_dyn-array u8)
                      (__tl_make-array u8 (array-length encoded-arr))]
                    (for [i (iterator.range 0 (array-length encoded-arr))]
                      (set! (array-ref copy-bytes i) (array-ref encoded-arr i)))
                    copy-bytes))]
              (match (codec.tli-decode-directory-for
                (& encoded-arr)
                producer-identity
                (& target-triple))
                [(Err fail) (io.panic fail.message)]
                [(Ok dir)
                  (when
                    (!=
                      (array-length dir.entries)
                      (array-length bundle.modules))
                    (io.panic "TLI directory count mismatch"))])
              (match (io.try-write-file tli-out (byte_buf.as-bytes (& encoded)))
                [(OkIoUnit) unit]
                [(ErrIoUnit _)
                  (io.panic
                    (str_cat.str-cat
                      "cannot write stdlib.tli: "
                      (string.copy tli-out)))]))
            ;; Now lower the EXACT same checked program once with opt-in module
            ;; ownership and per-module startup wrappers.
            (let
              [pools : ast.AstNodePoolContext (tc.tc-context-pools ctx)]
              [checked-program : ast.AstProgram (tc.tc-context-program ctx)]
              [source-decl-count : i64
                (match (& checked-program)
                  [(ast.AstProgram.Program decls-box)
                    (ast.ast-decl-list-len (& (deref decls-box)))])]
              [lower-state : lower.CompilerLowerState
                (lower.compiler-lower-state-new)]
              [clone-roots : clone_support.CloneRootEntries
                (tc.tc-clone-root-collection-finish! ctx)]
              [clone-able : clone_support.CloneNameSet
                (tc.tc-clone-able-set ctx)]
              (lower.compiler-lower-state-enable-module-ownership!
                lower-state
                true)
              (ast.ast-node-pool-context-install! pools)
              (let
                [clone-aug : lower.ResultLowerCloneAugment
                  (lower.lower-clone-handoff-augment
                    lower-state
                    ctx
                    env
                    ""
                    (tc.tc-context-program ctx)
                    clone-able
                    clone-roots
                    pools)]
                [augmented-program : ast.AstProgram
                  (match (& clone-aug)
                    [(Ok augmented _ _)
                      (match augmented
                        [(ast.AstProgram.Program decls-box)
                          (ast.AstProgram.Program
                            (box (clone (deref decls-box))))])]
                    [(Err message) (io.panic message)])]
                [all-clone-roots : clone_support.CloneRootEntries
                  (match clone-aug
                    [(Ok _ _ handoff-roots) handoff-roots]
                    [(Err message) (io.panic message)])]
                (ast.ast-node-pool-context-install! pools)
                (match (lower.lower-extend-checked-context-with-clone-decls
                  ctx
                  env
                  source-decl-count
                  (match (& augmented-program)
                    [(ast.AstProgram.Program decls-box)
                      (ast.AstProgram.Program (box (clone (deref decls-box))))]))
                  [(Err message) (io.panic message)]
                  [(Ok lower-ctx lower-env)
                    (let
                      [lower-names : lower.LowerNameEnv
                        (match (& augmented-program)
                          [(ast.AstProgram.Program decls-box)
                            (let
                              [decls-copy : ast.AstDeclList
                                (clone (deref decls-box))]
                              [base-names : lower.LowerNameEnv
                                (lower.lower-name-env-from-decls-with-state
                                  lower-state
                                  (& decls-copy)
                                  (& checked-paths)
                                  ""
                                  lower.LowerNameEnv.Nil)]
                              (lower.lower-name-env-add-clone-decls
                                lower-state
                                decls-copy
                                (& checked-paths)
                                ""
                                base-names
                                all-clone-roots
                                false))])]
                      (match (lower.lower-compiler-program-checked-with-names-mode
                        lower-state
                        lower-ctx
                        (tc.tc-env-with-cache lower-env)
                        augmented-program
                        checked-paths
                        ""
                        lower-names
                        all-clone-roots
                        lower-mode)
                        [(Err diag-box)
                          (tc.tc-checked-let-binding-facts-finish! let-facts)
                          (io.panic
                            (diag.compiler-diagnostic-render
                              (& (__tl-box-place diag-box))))]
                        [(Ok whole-program whole-spans lower-owner)
                          (tc.tc-checked-let-binding-facts-finish! let-facts)
                          (emit-partitioned-sysroot!
                            (& bundle)
                            whole-program
                            whole-spans
                            lower-owner
                            pools
                            job
                            asm-dir
                            manifest-out
                            backend-target
                            windows?
                            opt-level)
                          (lower.compiler-lower-arena-state-release!
                            (lower.compiler-lower-state-arenas lower-owner))]))]))))
          (cfg
            embedded-stdlib-tlci
            (tlci.compiler-embedded-stdlib-tlci-session-close!))]))))

(define (emit-partitioned-sysroot!
  [bundle : (& tli.TliBundle)]
  [whole-program : ir.CompilerIrProgram]
  [_whole-spans : ir.CompilerSourceSpans]
  [lower-state : lower.CompilerLowerState]
  [pools : ast.AstNodePoolContext]
  [job : tc.TcJobState]
  [asm-dir : (& str)]
  [manifest-out : (& str)]
  [backend-target : be_state.CompilerBackendTarget]
  [windows? : bool]
  [opt-level : i64]) : unit
  (let
    [interns : intern.InternCompatState
      (lower.compiler-lower-state-interns lower-state)]
    [type-segment-bases : i64
      (ast.ast-node-pool-context-type-segment-bases (& pools))]
    [module-count : i64 (array-length bundle.modules)]
    [sorted-names : (__tl_dyn-array String)
      (__tl_make-array String module-count)]
    [name-to-slot : str_map.Map (str_map.with-capacity (* module-count 2))]
    [expected-inits : (__tl_dyn-array bool) (__tl_make-array bool module-count)]
    (intern.intern-compat-state-install! (& interns))
    (ast.ast-node-pool-context-install! pools)
    (for [i (iterator.range 0 module-count)]
      (set!
        (array-ref sorted-names i)
        (string.copy (& (array-ref bundle.modules i).name))))
    (sort-strings! (&mut sorted-names))
    (for [i (iterator.range 0 module-count)]
      (str_map.insert-ref!
        (&mut name-to-slot)
        (string.copy (& (array-ref sorted-names i)))
        i))
    (for [i (iterator.range 0 module-count)]
      (let
        [slot : i64
          (str_map.get-value-or
            (& name-to-slot)
            (string.copy (& (array-ref bundle.modules i).name))
            -1)]
        (when (< slot 0) (io.panic "missing module slot"))
        (set!
          (array-ref expected-inits slot)
          (> (array-length (array-ref bundle.modules i).global-inits) 0))))
    (match whole-program
      [(ir.CompilerIrProgram.Program
          whole-globals
          whole-functions
          whole-externs
          _)
        (let
          [fn-count : i64 whole-functions.len]
          [gl-count : i64 whole-globals.len]
          [ex-count : i64 whole-externs.len]
          [fn-owners : (__tl_dyn-array i64) (__tl_make-array i64 fn-count)]
          [fn-skip : (__tl_dyn-array bool)
            (if windows?
              (compute-windows-syscall-skip-mask (& whole-functions))
              (__tl_make-array bool fn-count))]
          [gl-owners : (__tl_dyn-array i64) (__tl_make-array i64 gl-count)]
          [gl-private : (__tl_dyn-array bool) (__tl_make-array bool gl-count)]
          [provided-by-fn : i64_map.Map (i64_map.with-capacity 64)]
          [found-inits : (__tl_dyn-array bool)
            (__tl_make-array bool module-count)]
          (for [i (iterator.range 0 ex-count)]
            (match (& (array-ref whole-externs.slots i))
              [(ir.CompilerIrExtern.Extern name-id _ _ _ _ _ _ provided _)
                (when
                  provided
                  (i64_map.insert-ref!
                    (&mut provided-by-fn)
                    (ir.compiler-ir-symbol-id name-id)
                    i))]))
          (for [i (iterator.range 0 fn-count)]
            (match (& (array-ref whole-functions.slots i))
              [(ir.CompilerIrFunction.Function fn-name _ _ _ _ _)
                (let
                  [owner-id : i64
                    (lower.compiler-lower-state-function-owner-module-id
                      lower-state
                      fn-name)]
                  [owner-name : String
                    (if (>= owner-id 0)
                      (lower.lower-name-id-text lower-state owner-id)
                      "")]
                  [slot : i64
                    (str_map.get-value-or
                      (& name-to-slot)
                      (string.copy (& owner-name))
                      -1)]
                  (when
                    (< slot 0)
                    (io.panic
                      (str_cat.str-cat
                        "build-stdlib-sysroot: unowned function "
                        (ir.compiler-ir-symbol-text fn-name)
                        " (owner="
                        owner-name
                        ")")))
                  (set! (array-ref fn-owners i) slot)
                  (let
                    [fn-text : String (ir.compiler-ir-symbol-text fn-name)]
                    [expected-wrapper : String
                      (tli.tli-module-init-symbol
                        (& (array-ref sorted-names slot)))]
                    (when
                      (string.eq (& fn-text) (& expected-wrapper))
                      (when
                        (array-ref fn-skip i)
                        (io.panic
                          (str_cat.str-cat
                            "build-stdlib-sysroot: startup init uses Linux syscall on Windows: "
                            fn-text)))
                      (set! (array-ref found-inits slot) true))))]))
          (for [i (iterator.range 0 gl-count)]
            (match (& (array-ref whole-globals.slots i))
              [(ir.CompilerIrGlobal.Global gl-name _ _)
                (let
                  [owner-id : i64
                    (lower.compiler-lower-state-global-owner-module-id
                      lower-state
                      gl-name)]
                  [owner-name : String
                    (if (>= owner-id 0)
                      (lower.lower-name-id-text lower-state owner-id)
                      "")]
                  [slot : i64
                    (str_map.get-value-or
                      (& name-to-slot)
                      (string.copy (& owner-name))
                      -1)]
                  (when
                    (< slot 0)
                    (io.panic
                      (str_cat.str-cat
                        "build-stdlib-sysroot: unowned global "
                        (ir.compiler-ir-symbol-text gl-name)
                        " (owner="
                        owner-name
                        ")")))
                  (set! (array-ref gl-owners i) slot)
                  (set!
                    (array-ref gl-private i)
                    (intern.intern-compat-state-generated-role-symbol?
                      (& interns)
                      gl-name
                      (intern.intern-generated-symbol-role-nullary-enum-object))))]))
          (for [m (iterator.range 0 module-count)]
            (when
              (!= (array-ref expected-inits m) (array-ref found-inits m))
              (io.panic
                (str_cat.str-cat
                  "build-stdlib-sysroot: stdlib.tli and libstdlib.a disagree on startup init for module "
                  (string.copy (& (array-ref sorted-names m)))))))
          ;; Precompute cross-module extern descriptors for all functions and
          ;; non-private globals.
          (let
            [fn-cross-externs : (__tl_dyn-array ir.CompilerIrExtern)
              (__tl_make-array ir.CompilerIrExtern fn-count)]
            [gl-cross-externs : (__tl_dyn-array ir.CompilerIrExtern)
              (__tl_make-array ir.CompilerIrExtern gl-count)]
            [base-reps : ir.CompilerIrRepresentationIndex
              (lower.lower-representation-index-from-layouts
                type-segment-bases
                job
                (ir.compiler-ir-representation-index-empty))]
            [manifest-buf : text_buf.TextBuf (text_buf.empty)]
            [emitted-modules : i64 0]
            [skipped-modules : i64 0]
            (for [i (iterator.range 0 fn-count)]
              (match (& (array-ref whole-functions.slots i))
                [(ir.CompilerIrFunction.Function fn-name fn-params fn-ret _ _ _)
                  (let
                    [fn-name-str : String (ir.compiler-ir-symbol-text fn-name)]
                    [fn-sig : ast.AstType
                      (make-fn-physical-signature pools fn-params fn-ret)]
                    [provided-idx : i64
                      (i64_map.get-value-or
                        (& provided-by-fn)
                        (ir.compiler-ir-symbol-id fn-name)
                        -1)]
                    [link-sym-str : String
                      (if (>= provided-idx 0)
                        (match (& (array-ref whole-externs.slots provided-idx))
                          [(ir.CompilerIrExtern.Extern
                              _
                              _
                              _
                              _
                              prov-abi
                              prov-sym
                              _
                              _
                              _)
                            (let
                              [raw : String
                                (intern.intern-compat-state-str
                                  (& interns)
                                  prov-sym)]
                              (if (and
                                windows?
                                (ast.ast-extern-abi-c? prov-abi))
                                (abi.compiler-abi-c-export-body-symbol raw)
                                raw))])
                        (let
                          [rt-sym : String
                            (be_operand.compiler-backend-runtime-prelude-string-helper-symbol
                              (string.copy (& fn-name-str)))]
                          (if (> (string.string-length (& rt-sym)) 0)
                            rt-sym
                            (be_state.compiler-backend-user-symbol-uncached
                              (string.copy (& fn-name-str))))))]
                    [link-sym-id : i64
                      (intern-symbol! (&mut interns) link-sym-str)]
                    (set!
                      (array-ref fn-cross-externs i)
                      (ir.CompilerIrExtern.Extern
                        fn-name
                        fn-name
                        fn-name-str
                        fn-sig
                        (ast.AstExternAbi.TypeLisp)
                        link-sym-id
                        (ast.ast-extern-link-input-list-new)
                        false
                        (ir.CompilerIrReturnStorage.None))))]))
            (for [i (iterator.range 0 gl-count)]
              (when
                (not (array-ref gl-private i))
                (match (& (array-ref whole-globals.slots i))
                  [(ir.CompilerIrGlobal.Global gl-name gl-ty _)
                    (let
                      [gl-name-str : String
                        (ir.compiler-ir-symbol-text gl-name)]
                      [link-sym-str : String
                        (be_state.compiler-backend-user-symbol-uncached
                          (string.copy (& gl-name-str)))]
                      [link-sym-id : i64
                        (intern-symbol! (&mut interns) link-sym-str)]
                      (set!
                        (array-ref gl-cross-externs i)
                        (ir.CompilerIrExtern.Extern
                          gl-name
                          gl-name
                          gl-name-str
                          (ir.compiler-ir-clone-type
                            pools
                            (ast.ty-node-persist gl-ty))
                          (ast.AstExternAbi.TypeLisp)
                          link-sym-id
                          (ast.ast-extern-link-input-list-new)
                          false
                          (ir.CompilerIrReturnStorage.None))))])))
            ;; Emit each non-empty module independently.
            (for [m (iterator.range 0 module-count)]
              (let
                [mod-name (& (array-ref sorted-names m))]
                [g-builder : ir.CompilerIrGlobalBuilder
                  (ir.compiler-ir-global-builder-with-capacity 16)]
                [f-builder : ir.CompilerIrFunctionBuilder
                  (ir.compiler-ir-function-builder-with-capacity 32)]
                (for [i (iterator.range 0 gl-count)]
                  (when
                    (= (array-ref gl-owners i) m)
                    (ir.compiler-ir-global-builder-push!
                      (&mut g-builder)
                      (ir.compiler-ir-clone-global
                        pools
                        (& (array-ref whole-globals.slots i))))))
                (for [i (iterator.range 0 fn-count)]
                  (when
                    (and
                      (= (array-ref fn-owners i) m)
                      (not (array-ref fn-skip i)))
                    (ir.compiler-ir-function-builder-push!
                      (&mut f-builder)
                      (ir.compiler-ir-clone-function
                        pools
                        (& (array-ref whole-functions.slots i))))))
                (if (and (= g-builder.len 0) (= f-builder.len 0))
                  (+= skipped-modules 1)
                  (let
                    [be-state-mod : be_state.CompilerBackendState
                      (be_state.compiler-backend-state-new
                        (intern.intern-compat-state-capture-active))]
                    [init-globals : ir.CompilerIrGlobalSeq
                      (ir.compiler-ir-global-builder-snapshot-seq (& g-builder))]
                    [mod-functions : ir.CompilerIrFunctionSeq
                      (ir.compiler-ir-function-builder-snapshot (& f-builder))]
                    [refs : ModuleRefs
                      (collect-module-refs (& init-globals) (& mod-functions))]
                    [e-builder : ir.CompilerIrExternBuilder
                      (ir.compiler-ir-extern-builder-with-capacity 64)]
                    [added-externs : i64_map.Map (i64_map.with-capacity 128)]
                    ;; Copy any referenced private (nullary enum) globals locally.
                    (for [i (iterator.range 0 gl-count)]
                      (when
                        (and
                          (!= (array-ref gl-owners i) m)
                          (array-ref gl-private i))
                        (match (& (array-ref whole-globals.slots i))
                          [(ir.CompilerIrGlobal.Global gl-name _ _)
                            (when
                              (module-refs-contains? (& refs) gl-name)
                              (ir.compiler-ir-global-builder-push!
                                (&mut g-builder)
                                (ir.compiler-ir-clone-global
                                  pools
                                  (& (array-ref whole-globals.slots i)))))])))
                    ;; 1. Keep provided externs owned by this module.
                    (for [i (iterator.range 0 fn-count)]
                      (when
                        (and
                          (= (array-ref fn-owners i) m)
                          (not (array-ref fn-skip i)))
                        (match (& (array-ref whole-functions.slots i))
                          [(ir.CompilerIrFunction.Function fn-name _ _ _ _ _)
                            (let
                              [pidx : i64
                                (i64_map.get-value-or
                                  (& provided-by-fn)
                                  (ir.compiler-ir-symbol-id fn-name)
                                  -1)]
                              (when
                                (>= pidx 0)
                                (i64_map.insert-ref!
                                  (&mut added-externs)
                                  (ir.compiler-ir-symbol-id fn-name)
                                  1)
                                (ir.compiler-ir-extern-builder-push!
                                  (&mut e-builder)
                                  (ir.compiler-ir-clone-extern
                                    pools
                                    (& (array-ref whole-externs.slots pidx))))))])))
                    ;; 2. Keep referenced base non-provided externs (e.g. C FFI).
                    (for [i (iterator.range 0 ex-count)]
                      (match (& (array-ref whole-externs.slots i))
                        [(ir.CompilerIrExtern.Extern
                            name-id
                            src-id
                            _
                            _
                            _
                            link-id
                            _
                            provided
                            _)
                          (when
                            (and
                              (not provided)
                              (not
                                (i64_map.contains?
                                  (& added-externs)
                                  (ir.compiler-ir-symbol-id name-id)))
                              (or
                                (module-refs-contains? (& refs) name-id)
                                (module-refs-contains? (& refs) src-id)
                                (module-refs-contains? (& refs) link-id)))
                            (i64_map.insert-ref!
                              (&mut added-externs)
                              (ir.compiler-ir-symbol-id name-id)
                              1)
                            (ir.compiler-ir-extern-builder-push!
                              (&mut e-builder)
                              (ir.compiler-ir-clone-extern
                                pools
                                (& (array-ref whole-externs.slots i)))))]))
                    ;; 3. Other modules' functions referenced by this module.
                    (for [i (iterator.range 0 fn-count)]
                      (when
                        (!= (array-ref fn-owners i) m)
                        (match (& (array-ref whole-functions.slots i))
                          [(ir.CompilerIrFunction.Function fn-name _ _ _ _ _)
                            (let
                              [fid : i64 (ir.compiler-ir-symbol-id fn-name)]
                              (when
                                (and
                                  (module-refs-contains? (& refs) fn-name)
                                  (not
                                    (i64_map.contains? (& added-externs) fid)))
                                (i64_map.insert-ref! (&mut added-externs) fid 1)
                                (ir.compiler-ir-extern-builder-push!
                                  (&mut e-builder)
                                  (ir.compiler-ir-clone-extern
                                    pools
                                    (& (array-ref fn-cross-externs i))))))])))
                    ;; 4. Other modules' non-private globals referenced by this module.
                    (for [i (iterator.range 0 gl-count)]
                      (when
                        (and
                          (!= (array-ref gl-owners i) m)
                          (not (array-ref gl-private i)))
                        (match (& (array-ref whole-globals.slots i))
                          [(ir.CompilerIrGlobal.Global gl-name _ _)
                            (let
                              [gid : i64 (ir.compiler-ir-symbol-id gl-name)]
                              (when
                                (and
                                  (module-refs-contains? (& refs) gl-name)
                                  (not
                                    (i64_map.contains? (& added-externs) gid)))
                                (i64_map.insert-ref! (&mut added-externs) gid 1)
                                (ir.compiler-ir-extern-builder-push!
                                  (&mut e-builder)
                                  (ir.compiler-ir-clone-extern
                                    pools
                                    (& (array-ref gl-cross-externs i))))))])))
                    (let
                      [mod-globals : ir.CompilerIrGlobalSeq
                        (ir.compiler-ir-global-builder-snapshot-seq
                          (& g-builder))]
                      [mod-externs : ir.CompilerIrExternSeq
                        (ir.compiler-ir-extern-builder-snapshot-seq
                          (& e-builder))]
                      [claims : ir.CompilerIrReturnStorageIndex
                        (ir.compiler-ir-return-storage-index-claims
                          type-segment-bases
                          (ir.compiler-ir-type-pool-count pools)
                          (& mod-functions)
                          (& mod-externs))]
                      [authority : ir.CompilerIrReturnStorageAuthority
                        (ir.compiler-ir-return-storage-authority-capture
                          pools
                          (& interns)
                          (if windows?
                            1
                            0)
                          claims)]
                      [mod-program : ir.CompilerIrProgram
                        (ir.CompilerIrProgram.Program
                          mod-globals
                          mod-functions
                          mod-externs
                          authority)]
                      [prof : profile_state.CompilerProfileState
                        (profile_state.compiler-profile-state-new)]
                      [mod-reps : ir.CompilerIrRepresentationIndex
                        (ir.compiler-ir-representation-index-with-authority
                          pools
                          (& interns)
                          (if windows?
                            1
                            0)
                          (& mod-program)
                          (clone base-reps))]
                      (be_state.compiler-backend-state-set-representations-for-pools!
                        be-state-mod
                        (& pools)
                        (clone mod-reps))
                      (match (opt.optimize-program
                        mod-program
                        (ir.compiler-source-spans-empty)
                        (opt.OptimizeRequest
                          pools
                          (intern.intern-compat-state-capture-active)
                          opt-level
                          prof
                          true
                          mod-reps
                          (opt.OptInputRetirement.Retain)
                          (__tl_make-array i64 0)))
                        [(opt.CompilerOptimizedProgram.Program
                            opt-program
                            opt-spans)
                          (match (backend.compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                            be-state-mod
                            pools
                            opt-program
                            backend-target
                            (be_state.CompilerBackendMode.Scalar)
                            opt-spans
                            false
                            false
                            prof)
                            [(Err diag-box)
                              (io.panic
                                (str_cat.str-cat
                                  "build-stdlib-sysroot: backend failed for module "
                                  (string.copy mod-name)
                                  ": "
                                  (diag.compiler-diagnostic-render
                                    (& (__tl-box-place diag-box)))))]
                            [(Ok asm)
                              (let
                                [file-name : String
                                  (str_cat.str-cat
                                    (pad3 m)
                                    "-"
                                    (sanitize-module-filename mod-name)
                                    ".s")]
                                [asm-path : String
                                  (fs.path-join asm-dir (& file-name))]
                                (match (io.try-write-file
                                  (& asm-path)
                                  (byte_buf.str-as-bytes (& asm)))
                                  [(OkIoUnit) unit]
                                  [(ErrIoUnit _)
                                    (io.panic
                                      (str_cat.str-cat
                                        "cannot write module asm: "
                                        asm-path))])
                                (set!
                                  manifest-buf
                                  (text_buf.append
                                    (text_buf.append manifest-buf file-name)
                                    "\n"))
                                (+= emitted-modules 1))])])
                      (backend.compiler-backend-state-release-final-arenas!
                        be-state-mod))))))
            (let
              [manifest-text : String (text_buf.render manifest-buf)]
              (match (io.try-write-file
                manifest-out
                (byte_buf.str-as-bytes (& manifest-text)))
                [(OkIoUnit) unit]
                [(ErrIoUnit _)
                  (io.panic
                    (str_cat.str-cat
                      "cannot write manifest: "
                      (string.copy manifest-out)))])
              (io.println
                "build-stdlib-sysroot: {} total modules, {} emitted, {} skipped (empty), target={}"
                module-count
                emitted-modules
                skipped-modules
                (if windows?
                  "x86_64-pc-windows-msvc"
                  "x86_64-unknown-linux-gnu")))))])))

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