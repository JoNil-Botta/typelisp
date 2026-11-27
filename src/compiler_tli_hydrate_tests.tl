(import compiler_tli_hydrate as hydrate)
(import compiler_tli_codec as codec)
(import compiler_tli_types as tli)
(import tlci_core as tlci)
(import compiler_intern as intern)
(import compiler_tli_extract as extract)
(import compiler_ast_types as ast)
(import compiler_cfg_core as cfg_core)
(import compiler_load as load)
(import compiler_typecheck_api as api)
(import compiler_typecheck_core as tc)
(import compiler_target_cfg_core as target_cfg)
(import compiler_diagnostic as diag)
(import sym_i64_env)
(import stdlib.vector)
(import (vector.vector String) as strings)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import tli_cli_core as sysroot)
(import stdlib.byte_buf)
(import stdlib.arena)
(import stdlib.byte_le)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.iterator)
(import stdlib.profile)
(import stdlib.test)
(import compiler_builtin_ids as cbi)
(import compiler_ir_types as ir)
(import compiler_tli_compact_ir as compact)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as i64_map)

(define (tli-hydrate-fixture-module [name : String] [init : String] [cfg : i64]) : tli.TliModuleRecord
  (let
    [digest : (Array u8 32) (make-array u8 32)]
    (set! (array-ref digest 0) (cast cfg : u8))
    (tli.TliModuleRecord
      name
      ""
      (make-array u8 32)
      digest
      1
      (__tl_make-array tli.TliImport 0)
      (__tl_make-array init)
      (__tl_make-array tli.TliTypeDecl 0)
      (__tl_make-array tli.TliFnDecl 0)
      (__tl_make-array tli.TliValueDecl 0)
      (__tl_make-array tli.TliMacroHandle 0)
      (__tl_make-array tli.TliDispatchDecl 0))))

(define (tli-hydrate-fixture [dep-cfg : i64] [valid-pin : bool]) : (__tl_dyn-array
    u8)
  (let
    [bundle : tli.TliBundle
      (tli.TliBundle
        0
        "build"
        "target"
        (__tl_make-array
          (tli-hydrate-fixture-module "dep" "__tl_mod_init_dep" dep-cfg)
          (tli-hydrate-fixture-module "root" "__tl_mod_init_root" 0)
          (tli-hydrate-fixture-module "unused" "__tl_mod_init_unused" 1))
        (__tl_make-array tli.TliCompactGlobal 0)
        (__tl_make-array tli.TliCompactBodyEntry 0))]
    (set!
      (array-ref bundle.modules 1).imports
      (__tl_make-array
        (tli.TliImport "dep" 2 "alias" "item" (make-array u8 32))))
    (when
      valid-pin
      (test.assert-true
        (extract.tli-extract-pin-imports! (&mut bundle))
        "fixture import pins"))
    (codec.tli-encode-bundle (& bundle))))

(define (tli-hydrate-open [wire : (& wire (__tl_dyn-array u8))]) : hydrate.TliCatalog
  (let
    [cfg : (Array u8 32) (make-array u8 32)]
    (match (hydrate.tli-catalog-open wire "build" "target" (& cfg))
      [(Ok catalog) catalog]
      [(Err error) (io.panic error.message)])))

(define (tli-hydrate-root! [catalog : (&mut hydrate.TliCatalog)]) : i64
  (match (hydrate.tli-catalog-hydrate! catalog "root")
    [(Ok index) index]
    [(Err error) (io.panic error.message)]))

(define (tli-test-projection
  [catalog : (& catalog hydrate.TliCatalog)]
  [index : i64]) : unit
  (match (hydrate.tli-catalog-record catalog index)
    [(Some row)
      (let
        [edge : hydrate.TliHydratedImport
          (hydrate.tli-hydrate-import (& (array-ref row.imports 0)))]
        (test.assert-owned-string-eq
          (intern.intern-str edge.alias)
          "alias"
          "projected alias")
        (test.assert-owned-string-eq
          (intern.intern-str edge.item)
          "item"
          "projected item"))]
    [(None) (io.panic "root is not available")]))

(define (tli-test-lazy-closure [wire : (& wire (__tl_dyn-array u8))]) : unit
  (let
    [catalog : hydrate.TliCatalog (tli-hydrate-open wire)]
    (test.assert-i64-eq
      (hydrate.tli-catalog-ready-count (& catalog))
      0
      "no records hydrated by open")
    (let
      [root : i64 (tli-hydrate-root! (&mut catalog))]
      [used : i64 (hydrate.tli-catalog-owned-bytes (& catalog))]
      [symbols : (__tl_dyn-array i64)
        (hydrate.tli-catalog-startup-symbols (& catalog))]
      (test.assert-i64-eq
        (hydrate.tli-catalog-ready-count (& catalog))
        2
        "only the required closure is hydrated")
      (test.assert-owned-string-eq
        (intern.intern-str (array-ref symbols 0))
        "__tl_mod_init_dep"
        "dependency initializes first")
      (test.assert-owned-string-eq
        (intern.intern-str (array-ref symbols 1))
        "__tl_mod_init_root"
        "root initializes second")
      (test.assert-i64-eq
        (tli-hydrate-root! (&mut catalog))
        root
        "repeat lookup")
      (test.assert-i64-eq
        (hydrate.tli-catalog-owned-bytes (& catalog))
        used
        "repeat lookup does not decode")
      (tli-test-projection (& catalog) root))))

(test
  tli-lazy-closure-startup-and-release
  (let
    [wire : (__tl_dyn-array u8) (tli-hydrate-fixture 0 true)]
    ;; The warmup interns the projected names before the live-byte measurement.
    (with-arena
      tli-job
      (unsafe
        ;; intern-slice explicitly copies names into the interner's own arena.
        (tli-test-lazy-closure (& wire))))
    (let
      [before : i64 (profile.alloc-live)]
      (for [_ (iterator.range 0 12)]
        (with-arena
          tli-job
          (unsafe
            ;; intern-slice explicitly copies names into the interner's own arena.
            (tli-test-lazy-closure (& wire)))))
      (test.assert-i64-eq
        (profile.alloc-live)
        before
        "completed jobs release all catalog memory"))))

(define (tli-test-bad-closure
  [wire : (& wire (__tl_dyn-array u8))]
  [cfg-mismatch : bool]) : unit
  (let
    [catalog : hydrate.TliCatalog (tli-hydrate-open wire)]
    (match (hydrate.tli-catalog-hydrate! (&mut catalog) "root")
      [(Err failure)
        (test.assert-true
          (match failure.kind
            [(CfgFingerprintMismatch) cfg-mismatch]
            [(DigestMismatch) (not cfg-mismatch)]
            [_ false])
          "closure reports the invalid dependency")]
      [_ (io.panic "invalid dependency was accepted")])
    (match (hydrate.tli-catalog-record (& catalog) 1)
      [(None) unit]
      [_ (io.panic "partially validated root escaped")])))

(test
  tli-rejects-bad-build-target-cfg-and-digests
  (let
    [wire : (__tl_dyn-array u8) (tli-hydrate-fixture 0 true)]
    [bad-cfg : (__tl_dyn-array u8) (tli-hydrate-fixture 2 true)]
    [bad-pin : (__tl_dyn-array u8) (tli-hydrate-fixture 0 false)]
    [cfg : (Array u8 32) (make-array u8 32)]
    (match (hydrate.tli-catalog-open (& wire) "other" "target" (& cfg))
      [(Err failure)
        (match failure.kind
          [(CompilerBuildMismatch) unit]
          [_ (io.panic "expected build mismatch")])]
      [_ (io.panic "mismatched build was accepted")])
    (match (hydrate.tli-catalog-open (& wire) "build" "other" (& cfg))
      [(Err failure)
        (match failure.kind
          [(TargetMismatch) unit]
          [_ (io.panic "expected target mismatch")])]
      [_ (io.panic "mismatched target was accepted")])
    (let
      [before : i64 (profile.alloc-live)]
      (with-arena tli-job (tli-test-bad-closure (& bad-cfg) true))
      (with-arena tli-job (tli-test-bad-closure (& bad-pin) false))
      (test.assert-i64-eq
        (profile.alloc-live)
        before
        "rejected jobs reclaim catalog memory"))
    (let
      [start : i64
        (byte_le.read-u64 (& wire) (+ (byte_le.read-u64 (& wire) 40) 8))]
      (set! (array-ref wire start) (cast 0xff : u8))
      (match (hydrate.tli-catalog-open (& wire) "build" "target" (& cfg))
        [(Err failure)
          (match failure.kind
            [(DigestMismatch) unit]
            [_ (io.panic "expected envelope digest mismatch")])]
        [_ (io.panic "bad envelope digest was accepted")])
      (let
        [digest : (Array u8 32) (codec.tli-content-digest (& wire))]
        (codec.tli-copy-digest! (&mut wire) 80 (& digest))
        (with-arena tli-job (tli-test-bad-closure (& wire) false))))))

(test
  tli-projects-arena-effect-mask-and-extra-indices
  (let
    [summary : tli.TliFnSummary
      (tli.TliFnSummary
        0
        (bit-or (shl 1 63) 1)
        (__tl_make-array 64 80)
        (__tl_make-array tli.TliGlobalWrite 0)
        -1
        (cast 0 : u8)
        0
        0
        0
        (make-array u8 32))]
    (test.assert-true
      (hydrate.tli-hydrate-arena-arg-store? (& summary) 0)
      "first mask bit")
    (test.assert-true
      (hydrate.tli-hydrate-arena-arg-store? (& summary) 63)
      "last mask bit")
    (test.assert-true
      (hydrate.tli-hydrate-arena-arg-store? (& summary) 64)
      "first extra index")
    (test.assert-true
      (hydrate.tli-hydrate-arena-arg-store? (& summary) 80)
      "higher extra index")
    (test.assert-true
      (not (hydrate.tli-hydrate-arena-arg-store? (& summary) 65))
      "missing extra index")
    (test.assert-true
      (not (hydrate.tli-hydrate-arena-arg-store? (& summary) -1))
      "negative index")))

(test
  tli-projects-opaque-field-markers-independently-of-unsafe
  (let
    [facts : hydrate.TliHydratedFacts (hydrate.tli-hydrated-facts-new 0)]
    [decls : ast.AstDeclList (ast.ast-decl-list-new)]
    [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
    [modules : ast.AstDeclModuleList (ast.ast-decl-module-list-new)]
    (for [i (iterator.range 0 3)]
      (let
        [unsafe? : bool (= i 2)]
        [row : tli.TliTypeDecl
          (tli.TliTypeDecl
            "Record"
            ""
            (if unsafe?
              8
              1)
            0
            0
            0
            0
            (tli.TliCleanup.No)
            (if (= i 1)
              (__tl_make-array "a")
              (__tl_make-array String 0))
            (tli.TliTypeBody.Struct
              (__tl_make-array
                (tli.TliField
                  "field"
                  (tli.TliType.I64)
                  (tli.TliCleanup.No)
                  0
                  0
                  (not unsafe?)))))]
        (hydrate.tli-hydrate-project-type!
          (&mut facts)
          (&mut decls)
          (&mut paths)
          (&mut modules)
          (& row)
          ""
          0
          0)
        (let
          [decl : ast.AstDecl
            (ast.ast-decl-list-get (& decls) i (ast.ast-decl-fallback))]
          (test.assert-i64-eq
            (ast.ast-decl-aggregate-markers (& decl))
            (if unsafe?
              0
              1)
            "preserved aggregate markers")
          (test.assert-true
            (= (ast.ast-decl-has-opaque-field? (& decl)) (not unsafe?))
            "opaque fields set the AST marker")
          (test.assert-true
            (match (& decl)
              [(Unsafe _) unsafe?]
              [_ (not unsafe?)])
            "only the wire unsafe flag sets the unsafe wrapper"))))))

(test
  tli-registers-hydrated-invalidate-types
  (let
    [before : i64 ast.ast-invalidate-type-count]
    [ty : tli.TliType (tli.TliType.Invalidate "r" (box (tli.TliType.I64)))]
    [hydrated : ast.AstType
      (ast.ty-node-get (hydrate.tli-hydrate-type-id (& ty)))]
    (test.assert-i64-eq
      ast.ast-invalidate-type-count
      (+ before 1)
      "hydration registers one invalidation effect")
    (match hydrated
      [(Invalidate life inner)
        (test.assert-i64-eq life (intern.intern "r") "invalidate lifetime")
        (test.assert-true
          (ast.ty-node-shallow-eq? inner (& (ast.AstType.I64)))
          "invalidate inner type")]
      [_ (io.panic "expected a hydrated Invalidate")])))

(test
  tli-canonicalizes-qualified-nominals-with-lifetime-args
  (let
    [name : i64 (ast.ast-nominal-name-id-key (intern.intern "dep/Named"))]
    (match (hydrate.tli-hydrate-type
      (& (tli.TliType.StructArgs "dep/Named" (__tl_make-array "r"))))
      [(StructArgs actual _) (test.assert-i64-eq actual name "struct identity")]
      [_ (io.panic "expected a hydrated StructArgs")])
    (match (hydrate.tli-hydrate-type
      (& (tli.TliType.EnumArgs "dep/Named" (__tl_make-array "r"))))
      [(EnumArgs actual _) (test.assert-i64-eq actual name "enum identity")]
      [_ (io.panic "expected a hydrated EnumArgs")])
    (match (hydrate.tli-hydrate-type
      (& (tli.TliType.VarArgs "dep/Named" (__tl_make-array "r"))))
      [(VarArgs actual _) (test.assert-i64-eq actual name "var identity")]
      [_ (io.panic "expected a hydrated VarArgs")])))

(test
  tli-retains-boxed-c-varargs-tail-after-job-arena
  (let
    [row : tli.TliFnDecl
      (tli.TliFnDecl
        "variadic"
        "dep"
        "variadic"
        3
        0
        ""
        true
        0
        (__tl_make-array tli.TliExternLinkInput 0)
        (__tl_make-array
          (tli.TliParam
            "tail"
            (tli.TliType.Tuple (__tl_make-array (tli.TliType.U8)))
            false))
        (tli.TliType.Unit)
        (tli.TliFnSummary
          0
          0
          (__tl_make-array i64 0)
          (__tl_make-array tli.TliGlobalWrite 0)
          -1
          (cast 0 : u8)
          0
          0
          0
          (make-array u8 32)))]
    [abi : ast.AstExternAbi (ast.AstExternAbi.C)]
    (with-arena
      tli-job
      (unsafe
        ;; Copy the ABI without promoting any of its payloads out of this arena.
        (let
          [hydrated : hydrate.TliHydratedFunction
            (hydrate.tli-hydrate-function (& row))]
          (ptr-write!
            (ptr-cast (ptr-addr-of abi) : (MutPtr ast.AstExternAbi))
            hydrated.abi))))
    (match abi
      [(CVarargsTyped (Tuple items))
        (match (ast.ty-node-get
          (hydrate.tli-hydrate-type-id (& (array-ref row.params 0).ty)))
          [(Tuple pooled)
            (let
              ;; Compare the box addresses before dereferencing the tail.
              [pool-owned : bool
                (unsafe
                  (=
                    (ptr-read (ptr-cast (ptr-addr-of items) : (Ptr u64)))
                    (ptr-read (ptr-cast (ptr-addr-of pooled) : (Ptr u64)))))]
              (test.assert-true pool-owned "varargs tail uses the pooled box")
              (when
                pool-owned
                (test.assert-i64-eq
                  (ast.ast-type-list-len (& (deref items)))
                  1
                  "varargs tail tuple length after the job ends")
                (test.assert-true
                  (ast.ty-node-shallow-eq?
                    (ast.ast-type-list-get (& (deref items)) 0 0)
                    (& (ast.AstType.U8)))
                  "varargs tail tuple member after the job ends")))]
          [_ (io.panic "expected a pooled varargs tuple")])]
      [_ (io.panic "expected a hydrated typed varargs tuple")])))

(define (tli-test-selected [selected : sysroot.TliSysroot] [expected : (& str)]) : unit
  (match selected
    [(Found path)
      (test.assert-string-eq (& path) expected "selected sysroot directory")]
    [_ (io.panic "expected a selected sysroot")]))

(define (tli-test-mkdir [path : (& str)]) : unit
  (match (fs.try-mkdir-if-missing path)
    [(OkIoUnit) unit]
    [(ErrIoUnit error) (io.panic (io.error-message error))]))

(define (tli-test-make-layout [root : (& str)]) : String
  (let
    [lib : String (fs.path-join root "lib")]
    [target : String (fs.path-join (& lib) "target")]
    (tli-test-mkdir (& lib))
    (tli-test-mkdir (& target))
    target))

(define (tli-test-touch-bundle [dir : (& str)]) : unit
  (let
    [path : String (sysroot.tli-sysroot-bundle-path dir)]
    (match (io.try-write-file (& path) (byte_buf.str-as-bytes "fixture"))
      [(OkIoUnit) unit]
      [(ErrIoUnit error) (io.panic (io.error-message error))])))

(define (tli-test-clean-layout [root : (& str)] [dir : (& str)]) : unit
  (let
    [path : String (sysroot.tli-sysroot-bundle-path dir)]
    [lib : String (fs.path-join root "lib")]
    (fs.try-remove-file-if-exists (& path))
    (fs.try-remove-dir-if-exists dir)
    (fs.try-remove-dir-if-exists (& lib))
    unit))

(test
  tli-sysroot-selection-order
  (tli-test-mkdir "target")
  (tli-test-mkdir "target/exp")
  (match (fs.try-create-temp-dir-in "target/exp" "tli-sysroot")
    [(ErrIoString error) (io.panic (io.error-message error))]
    [(OkIoString root)
      (let
        [bin : String (fs.path-join (& root) "bin")]
        [exe : String (fs.path-join (& bin) "typelisp")]
        [parent : String (tli-test-make-layout (& root))]
        [automatic : sysroot.TliSysrootOptions (sysroot.tli-sysroot-options)]
        (tli-test-mkdir (& bin))
        (tli-test-touch-bundle (& parent))
        (tli-test-selected
          (sysroot.tli-sysroot-resolve (& automatic) "" (& exe) "target")
          (& parent))
        (let
          [nearby : String (tli-test-make-layout (& bin))]
          [explicit : sysroot.TliSysrootOptions
            (sysroot.TliSysrootOptions "explicit" false)]
          [disabled : sysroot.TliSysrootOptions
            (sysroot.TliSysrootOptions "explicit" true)]
          [expected : String
            (sysroot.tli-sysroot-target-dir "explicit" "target")]
          (tli-test-touch-bundle (& nearby))
          (tli-test-selected
            (sysroot.tli-sysroot-resolve (& automatic) "" (& exe) "target")
            (& nearby))
          (tli-test-selected
            (sysroot.tli-sysroot-resolve
              (& automatic)
              (& root)
              (& exe)
              "target")
            (& parent))
          (tli-test-selected
            (sysroot.tli-sysroot-resolve (& explicit) "none" (& exe) "target")
            (& expected))
          (match (sysroot.tli-sysroot-resolve
            (& automatic)
            "none"
            (& exe)
            "target")
            [(Disabled) unit]
            [_ (io.panic "environment opt-out ignored")])
          (match (sysroot.tli-sysroot-resolve
            (& disabled)
            (& root)
            (& exe)
            "target")
            [(Disabled) unit]
            [_ (io.panic "flag opt-out ignored")])
          (tli-test-clean-layout (& bin) (& nearby)))
        (tli-test-clean-layout (& root) (& parent))
        (fs.try-remove-dir-if-exists (& bin))
        (fs.try-remove-dir-if-exists (& root))
        unit)]))

(test
  tli-sysroot-dir-override-probe
  (tli-test-mkdir "target")
  (tli-test-mkdir "target/exp")
  (match (fs.try-create-temp-dir-in "target/exp" "tli-override")
    [(ErrIoString error) (io.panic (io.error-message error))]
    [(OkIoString root)
      (let
        [missing-dir : String (fs.path-join (& root) "absent")]
        [top-file : String (fs.path-join (& root) "arena.tl")]
        [nested-dir : String (fs.path-join (& root) "compress")]
        [nested-file : String (fs.path-join (& nested-dir) "adler32.tl")]
        (when
          (sysroot.tli-sysroot-dir-overrides-stdlib? (& missing-dir))
          (io.panic "absent directory reported stdlib override"))
        (when
          (sysroot.tli-sysroot-dir-overrides-module?
            (& root)
            "arena.tl"
            "(define x : i64 1)\n")
          (io.panic "missing file reported stdlib override"))
        (match (io.try-write-file
          (& top-file)
          (byte_buf.str-as-bytes "(define x : i64 1)\n"))
          [(OkIoUnit) unit]
          [(ErrIoUnit error) (io.panic (io.error-message error))])
        (when
          (sysroot.tli-sysroot-dir-overrides-module?
            (& root)
            "arena.tl"
            "(define x : i64 1)\n")
          (io.panic "exact-matching file reported stdlib override"))
        (unless
          (sysroot.tli-sysroot-dir-overrides-module?
            (& root)
            "arena.tl"
            "(define x : i64 2)\n")
          (io.panic "modified top-level file missed stdlib override"))
        (match (io.try-write-file
          (& top-file)
          (byte_buf.str-as-bytes "(define x : i64 1)\n(test probe unit)\n"))
          [(OkIoUnit) unit]
          [(ErrIoUnit error) (io.panic (io.error-message error))])
        (when
          (sysroot.tli-sysroot-dir-overrides-module?
            (& root)
            "arena.tl"
            "(define x : i64 1)\n\n")
          (io.panic "blanked inline-test file reported stdlib override"))
        (tli-test-mkdir (& nested-dir))
        (match (io.try-write-file
          (& nested-file)
          (byte_buf.str-as-bytes "(define y : i64 9)\n"))
          [(OkIoUnit) unit]
          [(ErrIoUnit error) (io.panic (io.error-message error))])
        (unless
          (sysroot.tli-sysroot-dir-overrides-module?
            (& root)
            "compress/adler32.tl"
            "(define y : i64 0)\n")
          (io.panic "modified nested file missed stdlib override"))
        (fs.try-remove-file-if-exists (& nested-file))
        (fs.try-remove-dir-if-exists (& nested-dir))
        (fs.try-remove-file-if-exists (& top-file))
        (fs.try-remove-dir-if-exists (& root))
        unit)]))

(define (tli-test-extract-io) : tli.TliBundle
  (api.compiler-typecheck-reset-load-session!)
  (let
    [files : (Array String 11)
      (array
        "io.tl"
        "byte_buf.tl"
        "clone.tl"
        "comptime.tl"
        "format.tl"
        "format_writer_core.tl"
        "io_core.tl"
        "math.tl"
        "str_cat.tl"
        "str_cat_runtime.tl"
        "string.tl")]
    [sources : (__tl_dyn-array extract.TliSource)
      (__tl_make-array extract.TliSource (array-length files))]
    [roots : strings.Vec (strings.new)]
    [cfgs : sym_i64_env.SymI64Env
      (target_cfg.compiler-target-cfgs
        (target_cfg.compiler-target-cfg-host)
        (api.typecheck-compiler-source-language-cfgs))]
    (for [index (iterator.range 0 (array-length files))]
      (let
        [file (& (array-ref files index))]
        [path : String (str_cat.str-cat "stdlib/" (string.copy file))]
        [module : String
          (load.compiler-load-canonical-module-id-from-path (& path))]
        [digest : (Array u8 32)
          (match (io.try-read-file (& path))
            [(OkIoBytes data)
              (extract.tli-extract-sha256 (byte_buf.as-bytes (& data)))]
            [(ErrIoBytes error) (io.panic (io.error-message error))])]
        (set! (array-ref sources index) (extract.TliSource module path digest))))
    (match (load.compiler-load-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      (& roots)
      cfgs)
      [(Ok prelude prelude-paths _ seen)
        (match (load.compiler-load-stdlib-prelude-file-with-roots-cfg
          "stdlib/io.tl"
          seen
          (& roots)
          cfgs)
          [(Ok decls paths _ _)
            (match (extract.tli-extract
              (api.typecheck-request-serial
                (ast.AstProgram.Program
                  (box
                    (load.compiler-load-decl-list-append (& prelude) (& decls))))
                (load.compiler-load-decl-path-list-append
                  (& prelude-paths)
                  (& paths))
                roots
                cfgs
                (tc.tc-prefix-default-cache-scope))
              (& sources)
              tli.tli-is-stdlib-bundle
              "build"
              "target")
              [(Ok bundle) bundle]
              [(Err error) (io.panic error)])]
          [(Err error)
            (io.panic
              (diag.compiler-diagnostic-render (& (__tl-box-place error))))])]
      [(Err error)
        (io.panic (diag.compiler-diagnostic-render (& (__tl-box-place error))))])))

(define (tli-test-io-facts [row : (& tli.TliModuleRecord)]) : unit
  (let
    [layouts : i64 0]
    [never-calls : i64 0]
    [print-macros : i64 0]
    (for [index (iterator.range 0 (array-length row.types))]
      (let
        [ty : hydrate.TliHydratedType
          (hydrate.tli-hydrate-type-decl (& (array-ref row.types index)))]
        (when (and (> ty.size 0) (> ty.align 0)) (+= layouts 1))))
    (for [index (iterator.range 0 (array-length row.functions))]
      (let
        [fn : hydrate.TliHydratedFunction
          (hydrate.tli-hydrate-function (& (array-ref row.functions index)))]
        (when
          (!= (bit-and fn.effect-flags 8) 0)
          (match (ast.ty-node-get fn.signature-id)
            [(Func _ ret)
              (match (ast.ty-node-get ret)
                [(Never) (+= never-calls 1)]
                [_ (io.panic "never-returns effect on a returning function")])]
            [_ (io.panic "projected function lost its signature")]))))
    (for [index (iterator.range 0 (array-length row.macros))]
      (when
        (string.eq (& (array-ref row.macros index).identity) "stdlib.io/print")
        (test.assert-i64-eq
          (cast (array-ref row.macros index).result-kind : i64)
          0
          "print is an expression macro")
        (+= print-macros 1)))
    (test.assert-true (> layouts 0) "stdlib.io exports layout facts")
    (test.assert-true
      (> never-calls 0)
      "stdlib.io exports never-returning functions")
    (test.assert-i64-eq print-macros 1 "stdlib.io exports its print macro")))

(define (tli-test-stdlib-io-closure
  [wire : (& wire (__tl_dyn-array u8))]
  [cfg-digest : (& (Array u8 32))]) : unit
  (let
    [catalog : hydrate.TliCatalog
      (match (hydrate.tli-catalog-open wire "build" "target" cfg-digest)
        [(Ok catalog) catalog]
        [(Err failure) (io.panic failure.message)])]
    (test.assert-i64-eq
      (hydrate.tli-catalog-ready-count (& catalog))
      0
      "directory is lazy")
    (match (hydrate.tli-catalog-hydrate! (&mut catalog) "stdlib.io")
      [(Ok root)
        (test.assert-i64-eq
          (hydrate.tli-catalog-ready-count (& catalog))
          11
          "stdlib.io has ten transitive dependencies")
        (match (hydrate.tli-catalog-record (& catalog) root)
          [(Some row) (tli-test-io-facts row)]
          [(None) (io.panic "stdlib.io did not hydrate")])]
      [(Err failure) (io.panic failure.message)])
    (let
      [symbols : (__tl_dyn-array i64)
        (hydrate.tli-catalog-startup-symbols (& catalog))]
      (test.assert-i64-eq
        (array-length symbols)
        2
        "two startup wrappers in this closure")
      (test.assert-owned-string-eq
        (intern.intern-str (array-ref symbols 0))
        "__tl_mod_init_stdlib.format_writer_core"
        "initialize writer before formatter")
      (test.assert-owned-string-eq
        (intern.intern-str (array-ref symbols 1))
        "__tl_mod_init_stdlib.format"
        "initialize formatter next"))))

(test
  tli-hydrates-stdlib-io-transitive-closure
  (let
    [bundle : tli.TliBundle (tli-test-extract-io)]
    [cfg-digest : (Array u8 32)
      (array-ref bundle.modules 0).cfg-fingerprint-sha256]
    [wire : (__tl_dyn-array u8) (codec.tli-encode-bundle (& bundle))]
    (with-arena
      tli-job
      (unsafe
        ;; The compiler interner and type pool choose their own arenas.
        (tli-test-stdlib-io-closure (& wire) (& cfg-digest))))))

(define (tli-test-lazy-open-and-archive-startup
  [wire : (& wire (__tl_dyn-array u8))]
  [cfg-digest : (& (Array u8 32))]) : unit
  (let
    [catalog : hydrate.TliCatalog
      (match (hydrate.tli-catalog-open-lazy wire "build" "target" cfg-digest)
        [(Ok catalog) catalog]
        [(Err failure) (io.panic failure.message)])]
    (match (hydrate.tli-catalog-hydrate! (&mut catalog) "stdlib.io")
      [(Ok _) unit]
      [(Err failure) (io.panic failure.message)])
    (let
      [archive-inits : (__tl_dyn-array String)
        (hydrate.tli-catalog-startup-archive-symbols (& catalog))]
      (test.assert-i64-eq
        (array-length archive-inits)
        2
        "two archive startup init symbols")
      (test.assert-true
        (string.eq
          (& (array-ref archive-inits 0))
          "_tl___tl_mod_init_stdlib_format_writer_core")
        "archive startup init symbol 0")
      (test.assert-true
        (string.eq
          (& (array-ref archive-inits 1))
          "_tl___tl_mod_init_stdlib_format")
        "archive startup init symbol 1"))))

(test
  tli-lazy-open-and-archive-startup-symbols
  (let
    [bundle : tli.TliBundle (tli-test-extract-io)]
    [cfg-digest : (Array u8 32)
      (array-ref bundle.modules 0).cfg-fingerprint-sha256]
    [wire : (__tl_dyn-array u8) (codec.tli-encode-bundle (& bundle))]
    (test.assert-owned-string-eq
      (hydrate.tli-hydrate-archive-qualified-symbol
        ""
        "stdlib.format"
        "stdlib.format/formatter-cell")
      "_tl_stdlib_format_stdlib_format_formatter_cell"
      "archive symbol matches libstdlib.a double-module mangling")
    (test.assert-owned-string-eq
      (hydrate.tli-hydrate-archive-qualified-symbol
        "stdlib/random.tl"
        "stdlib.vector.generated.i64"
        "stdlib.vector.generated.i64/with-capacity")
      "_tl_stdlib_random_stdlib_vector_generated_i64_with_capacity"
      "archive symbol uses source-path prefix for generated stdlib modules")
    (with-arena
      tli-job
      (unsafe
        (tli-test-lazy-open-and-archive-startup (& wire) (& cfg-digest))))))

;; Find where `text` starts in the encoded string pool (count, then u32 length
;; and bytes per entry).
(define (tli-test-pool-text-offset
  [wire : (& wire (__tl_dyn-array u8))]
  [text : (& str)]) : i64
  (let
    [pool-start : i64 (byte_le.read-u64 wire 24)]
    [count : i64 (byte_le.read-u32 wire pool-start)]
    [table : i64 (+ pool-start 4)]
    [base : i64 (+ table (* 4 (+ count 1)))]
    (for [id (iterator.range 0 count)]
      (let
        [first : i64 (byte_le.read-u32 wire (+ table (* 4 id)))]
        [length : i64
          (- (byte_le.read-u32 wire (+ table (* 4 (+ id 1)))) first)]
        [start : i64 (+ base first)]
        [candidate : (__tl_dyn-array u8) (__tl_make-array u8 length)]
        (for [index (iterator.range 0 length)]
          (set! (array-ref candidate index) (array-ref wire (+ start index))))
        (let
          [found : String (byte_buf.to-string (byte_buf.from-array candidate))]
          (when (string.eq (& found) text) (return start)))))
    (io.panic "pool text not found")))

;; Full open verifies `index_sha256` and `content_sha256` before pool decoding;
;; lazy compile open skips both up-front index/content hashes and rejects
;; invalid UTF-8 pool strings on read, tampered module records via
;; `module_sha256`, and tampered compact bodies via `inline_ir_sha256`.
(define (tli-test-expect-open-failure
  [wire : (& wire (__tl_dyn-array u8))]
  [cfg-digest : (& (Array u8 32))]
  [lazy? : bool]
  [utf8? : bool]
  [message : (& str)]) : unit
  (match (if lazy?
    (hydrate.tli-catalog-open-lazy wire "build" "target" cfg-digest)
    (hydrate.tli-catalog-open wire "build" "target" cfg-digest))
    [(Err failure)
      (test.assert-true
        (match failure.kind
          [(DigestMismatch) (not utf8?)]
          [(Utf8) utf8?]
          [_ false])
        (string.copy message))]
    [(Ok _) (io.panic message)]))

(test
  tli-catalog-open-rejects-modified-pool-and-invalid-utf8
  (let
    [bundle : tli.TliBundle (tli-test-extract-io)]
    [cfg-digest : (Array u8 32)
      (array-ref bundle.modules 0).cfg-fingerprint-sha256]
    [wire : (__tl_dyn-array u8) (codec.tli-encode-bundle (& bundle))]
    ;; 1. Tampering `index_sha256` (even with `content_sha256` re-stamped) is
    ;; rejected by full open (`tli-catalog-open` / `inspect`).
    (let
      [saved-idx : u8 (array-ref wire tli.tli-index-digest-offset)]
      (set!
        (array-ref wire tli.tli-index-digest-offset)
        (cast (bit-xor (cast saved-idx : i64) 1) : u8))
      (codec.tli-copy-digest!
        (&mut wire)
        tli.tli-content-digest-offset
        (& (codec.tli-content-digest (& wire))))
      (with-arena
        tli-job
        (tli-test-expect-open-failure
          (& wire)
          (& cfg-digest)
          false
          false
          "tampered index_sha256 fails full open even when content_sha256 matches"))
      (set! (array-ref wire tli.tli-index-digest-offset) saved-idx)
      (codec.tli-copy-digest!
        (&mut wire)
        tli.tli-content-digest-offset
        (& (codec.tli-content-digest (& wire)))))
    ;; 2. Tampering a module record's bytes is rejected on lazy hydration via
    ;; `module_sha256`.
    (let
      [rec-start : i64
        (byte_le.read-u64 (& wire) (+ (byte_le.read-u64 (& wire) 40) 8))]
      [saved-rec : u8 (array-ref wire rec-start)]
      (set!
        (array-ref wire rec-start)
        (cast (bit-xor (cast saved-rec : i64) 1) : u8))
      (with-arena
        tli-job
        (match (hydrate.tli-catalog-open-lazy
          (& wire)
          "build"
          "target"
          (& cfg-digest))
          [(Err failure) (io.panic failure.message)]
          [(Ok catalog-val)
            (let
              [catalog : hydrate.TliCatalog catalog-val]
              [mod-name : String
                (string.copy (& (array-ref catalog.directory.entries 0).name))]
              (match (hydrate.tli-catalog-hydrate! (&mut catalog) (& mod-name))
                [(Err failure)
                  (test.assert-true
                    (match failure.kind
                      [(DigestMismatch) true]
                      [_ false])
                    "tampered module record fails lazy module_sha256")]
                [(Ok _)
                  (io.panic "lazy hydrate accepted tampered module_sha256")]))]))
      (set! (array-ref wire rec-start) saved-rec))
    ;; 3. Invalid UTF-8 in a directory-referenced pool string fails full open
    ;; via digest (then UTF-8 once re-stamped) and fails lazy open directly via
    ;; UTF-8 validation.
    (let
      [text : i64 (tli-test-pool-text-offset (& wire) "stdlib.io")]
      (set! (array-ref wire text) (cast 0xff : u8))
      (with-arena
        tli-job
        (tli-test-expect-open-failure
          (& wire)
          (& cfg-digest)
          false
          false
          "modified string pool bytes fail full open digest")
        (tli-test-expect-open-failure
          (& wire)
          (& cfg-digest)
          true
          true
          "lazy open rejects invalid UTF-8 pool text directly"))
      (let
        [index : (Array u8 32)
          (codec.tli-index-digest
            (& wire)
            (+ (byte_le.read-u64 (& wire) 40) (byte_le.read-u64 (& wire) 48)))]
        (codec.tli-copy-digest!
          (&mut wire)
          tli.tli-index-digest-offset
          (& index))
        (codec.tli-copy-digest!
          (&mut wire)
          tli.tli-content-digest-offset
          (& (codec.tli-content-digest (& wire))))
        (with-arena
          tli-job
          (tli-test-expect-open-failure
            (& wire)
            (& cfg-digest)
            true
            true
            "lazy open rejects re-hashed invalid UTF-8 pool text"))
        (with-arena
          tli-job
          (tli-test-expect-open-failure
            (& wire)
            (& cfg-digest)
            false
            true
            "re-hashed invalid UTF-8 pool text is rejected"))))))

(test
  tli-lazy-open-rejects-tampered-inline-ir-sha256
  (let
    [zero : (Array u8 32) (make-array u8 32)]
    [cfg-digest : (Array u8 32) (make-array u8 32)]
    [fns : (__tl_dyn-array tli.TliFnDecl) (__tl_make-array tli.TliFnDecl 1)]
    [mods : (__tl_dyn-array tli.TliModuleRecord)
      (__tl_make-array tli.TliModuleRecord 1)]
    [bodies : (__tl_dyn-array tli.TliCompactBodyEntry)
      (__tl_make-array tli.TliCompactBodyEntry 1)]
    (set!
      (array-ref fns 0)
      (tli.TliFnDecl
        "spmd-id"
        "test.compact"
        "test.compact/spmd-id"
        0
        0
        ""
        false
        0
        (__tl_make-array tli.TliExternLinkInput 0)
        (__tl_make-array tli.TliParam 0)
        (tli.TliType.Unit)
        (tli.TliFnSummary
          tli.tli-fn-spmd-inlineable
          0
          (__tl_make-array i64 0)
          (__tl_make-array tli.TliGlobalWrite 0)
          -1
          (cast 0 : u8)
          0
          0
          0
          zero)))
    (set!
      (array-ref mods 0)
      (tli.TliModuleRecord
        "test.compact"
        "test/compact.tl"
        zero
        cfg-digest
        0
        (__tl_make-array tli.TliImport 0)
        (__tl_make-array String 0)
        (__tl_make-array tli.TliTypeDecl 0)
        fns
        (__tl_make-array tli.TliValueDecl 0)
        (__tl_make-array tli.TliMacroHandle 0)
        (__tl_make-array tli.TliDispatchDecl 0)))
    (set!
      (array-ref bodies 0)
      (tli.TliCompactBodyEntry
        "test.compact"
        "spmd-id"
        "test.compact/spmd-id"
        (tli.TliCompactBody
          tli.tli-compact-body-has-spmd-expr
          (tli.tli-compact-ir-body-empty)
          (tli.TliSpmdExpr.Literal (tli.TliSpmdLiteral.Unit)))))
    (let
      [bundle : tli.TliBundle
        (tli.TliBundle
          tli.tli-has-compact-ir
          "build"
          "target"
          mods
          (__tl_make-array tli.TliCompactGlobal 0)
          bodies)]
      [wire : (__tl_dyn-array u8) (codec.tli-encode-bundle (& bundle))]
      [ir-start : i64 (byte_le.read-u64 (& wire) 56)]
      (with-arena
        tli-job
        (match (hydrate.tli-catalog-open-lazy
          (& wire)
          "build"
          "target"
          (& cfg-digest))
          [(Err failure) (io.panic failure.message)]
          [(Ok catalog-val)
            (let
              [catalog : hydrate.TliCatalog catalog-val]
              (match (hydrate.tli-catalog-hydrate!
                (&mut catalog)
                "test.compact")
                [(Err failure) (io.panic failure.message)]
                [(Ok _)
                  (let
                    [fn0
                      (& (array-ref (array-ref catalog.records 0).functions 0))]
                    [body-pos : i64 (+ ir-start fn0.summary.inline-ir-offset)]
                    (set!
                      (array-ref wire body-pos)
                      (cast
                        (bit-xor (cast (array-ref wire body-pos) : i64) 1)
                        : u8))
                    (match (hydrate.tli-catalog-open-lazy
                      (& wire)
                      "build"
                      "target"
                      (& cfg-digest))
                      [(Err failure) (io.panic failure.message)]
                      [(Ok bad-catalog)
                        (match (codec.tli-decode-compact-body-at
                          (& bad-catalog.directory)
                          fn0.summary.inline-ir-offset
                          fn0.summary.inline-ir-len
                          (& fn0.summary.inline-ir-sha256))
                          [(codec.TliCompactBodyResult.Err failure)
                            (test.assert-true
                              (match failure.kind
                                [(DigestMismatch) true]
                                [_ false])
                              "tampered compact body fails lazy inline_ir_sha256")]
                          [(codec.TliCompactBodyResult.Ok _)
                            (io.panic
                              "lazy decode accepted tampered inline_ir_sha256")])]))]))])))))

;; `() : i64` whose body returns a call to `callee`.
(define (tli-compact-test-call-fn [name : i64] [callee : i64]) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    name
    (ir.compiler-ir-param-seq-empty)
    (ast.AstType.I64)
    1
    (ir.compiler-ir-blocks
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-seq2
          (ir.CompilerIrInstr.Call
            0
            callee
            (ir.CompilerIrCallArgs.Nil)
            (ast.AstType.I64))
          (ir.CompilerIrInstr.Return
            (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0))))))
    (ir.CompilerIrFunctionAbi.Ordinary)))

;; A body calling itself would encode its own archive symbol with no extern-ref,
;; and hydration names the body by its source symbol, so the self-call would be
;; mangled twice; such a body ships no compact IR. Its caller still does.
(test
  tli-compact-ir-rejects-self-recursive-body
  (cbi.compiler-builtin-initialize-for-parse!)
  (let
    [self-sym : i64 (ir.compiler-ir-test-symbol "c36_compact_self")]
    [caller-sym : i64 (ir.compiler-ir-test-symbol "c36_compact_caller")]
    [functions : ir.CompilerIrFunctionSeq
      (ir.compiler-ir-function-seq-prepend
        (& (tli-compact-test-call-fn self-sym self-sym))
        (&
          (ir.compiler-ir-function-seq-prepend
            (& (tli-compact-test-call-fn caller-sym self-sym))
            (& (ir.compiler-ir-function-seq-empty)))))]
    [globals : ir.CompilerIrGlobalSeq (ir.compiler-ir-global-seq-empty)]
    [externs : ir.CompilerIrExternSeq (ir.compiler-ir-extern-seq-empty)]
    [fn-ids : i64_map.Map (i64_map.with-capacity 4)]
    [fn-skip : (__tl_dyn-array bool) (__tl_make-array bool 2)]
    [fn-links : (__tl_dyn-array String) (__tl_make-array String 2)]
    (i64_map.insert-ref! (&mut fn-ids) (ir.compiler-ir-symbol-id self-sym) 0)
    (i64_map.insert-ref! (&mut fn-ids) (ir.compiler-ir-symbol-id caller-sym) 1)
    (set! (array-ref fn-skip 0) false)
    (set! (array-ref fn-skip 1) false)
    (set! (array-ref fn-links 0) "_tl_c36_compact_self")
    (set! (array-ref fn-links 1) "_tl_c36_compact_caller")
    (let
      [tables : compact.TliIrEncodeTables
        (compact.TliIrEncodeTables
          fn-ids
          (i64_map.with-capacity 1)
          (i64_map.with-capacity 1)
          fn-skip
          (__tl_make-array bool 0)
          (__tl_make-array bool 0)
          (__tl_make-array bool 0)
          fn-links
          (__tl_make-array String 0))]
      [pools : ast.AstNodePoolContext
        (ast.ast-node-pool-context-capture-active)]
      [interns : intern.InternCompatState
        (intern.intern-compat-state-capture-active)]
      (match (compact.tli-encode-compact-ir-function
        pools
        (& tables)
        (& interns)
        (& globals)
        (& functions)
        (& externs)
        0)
        [(compact.TliEncodeCompactIrBodyResult.No) unit]
        [(compact.TliEncodeCompactIrBodyResult.Ok _)
          (test.assert-true false "encoded a self-recursive compact body")])
      (match (compact.tli-encode-compact-ir-function
        pools
        (& tables)
        (& interns)
        (& globals)
        (& functions)
        (& externs)
        1)
        [(compact.TliEncodeCompactIrBodyResult.No)
          (test.assert-true false "rejected the caller of a recursive body")]
        [(compact.TliEncodeCompactIrBodyResult.Ok body)
          (test.assert-i64-eq
            (array-length body.extern-refs)
            1
            "the caller names its callee by extern-ref")
          (test.assert-string-eq
            (& (array-ref body.extern-refs 0).link-symbol)
            "_tl_c36_compact_self"
            "the extern-ref carries the callee's archive symbol")]))))

(define (tli-test-make-simple-bundle
  [mod-name : String]
  [src-path : String]
  [cfg-digest : (Array u8 32)]
  [imports : (__tl_dyn-array tli.TliImport)]
  [has-init? : bool]
  [fn-link-symbol : String]) : (__tl_dyn-array u8)
  (let
    [inits : (__tl_dyn-array String)
      (if has-init?
        (__tl_make-array (tli.tli-module-init-symbol (& mod-name)))
        (__tl_make-array String 0))]
    [fn-row : tli.TliFnDecl
      (tli.TliFnDecl
        "helper"
        (string.copy (& mod-name))
        (string.copy (& fn-link-symbol))
        0
        0
        ""
        false
        0
        (__tl_make-array tli.TliExternLinkInput 0)
        (__tl_make-array tli.TliParam 0)
        (tli.TliType.I64)
        (tli.TliFnSummary
          0
          0
          (__tl_make-array i64 0)
          (__tl_make-array tli.TliGlobalWrite 0)
          -1
          (cast 0 : u8)
          0
          0
          0
          (make-array u8 32)))]
    [record : tli.TliModuleRecord
      (tli.TliModuleRecord
        mod-name
        src-path
        (make-array u8 32)
        cfg-digest
        (if has-init?
          1
          0)
        imports
        inits
        (__tl_make-array tli.TliTypeDecl 0)
        (__tl_make-array fn-row)
        (__tl_make-array tli.TliValueDecl 0)
        (__tl_make-array tli.TliMacroHandle 0)
        (__tl_make-array tli.TliDispatchDecl 0))]
    [bundle : tli.TliBundle
      (tli.TliBundle
        0
        "build"
        "target"
        (__tl_make-array record)
        (__tl_make-array tli.TliCompactGlobal 0)
        (__tl_make-array tli.TliCompactBodyEntry 0))]
    (codec.tli-encode-bundle (& bundle))))

;; Two package bundles plus a duplicate and a digest-mismatched one. Every
;; bundle and the catalog root live in the caller's scoped job arena, so the
;; decoded records are released with it.
(define (tli-test-multi-bundle-closure) : unit
  (let
    [cfg-digest : (Array u8 32) (make-array u8 32)]
    [wire-a : (__tl_dyn-array u8)
      (tli-test-make-simple-bundle
        "pkg_a.src.lib"
        "pkg_a/src/lib.tl"
        cfg-digest
        (__tl_make-array tli.TliImport 0)
        true
        "_tl_pkg_a_src_lib_tl_helper")]
    [cat-a : hydrate.TliCatalog
      (match (hydrate.tli-catalog-open-lazy
        (& wire-a)
        "build"
        "target"
        (& cfg-digest))
        [(Ok c) c]
        [(Err f) (io.panic f.message)])]
    [digest-a : (Array u8 32)
      (array-ref cat-a.directory.entries 0).module-sha256]
    [wire-b : (__tl_dyn-array u8)
      (tli-test-make-simple-bundle
        "pkg_b.src.lib"
        "pkg_b/src/lib.tl"
        cfg-digest
        (__tl_make-array (tli.TliImport "pkg_a.src.lib" 0 "a" "" digest-a))
        true
        "_tl_pkg_b_src_lib_tl_helper")]
    [cat-b : hydrate.TliCatalog
      (match (hydrate.tli-catalog-open-lazy
        (& wire-b)
        "build"
        "target"
        (& cfg-digest))
        [(Ok c) c]
        [(Err f) (io.panic f.message)])]
    [multi : hydrate.TliMultiCatalog
      (hydrate.tli-multi-catalog-new (arena.tl_arena_current))]
    (match (hydrate.tli-multi-catalog-attach-bundle!
      (&mut multi)
      (arena.tl_arena_current)
      false
      "pkg_a"
      "1.0.0"
      "/pkg_a"
      "/pkg_a/target/dev/libpkg_a.a"
      (tlci.tlci-spmd-callables-empty)
      cat-a.directory
      (& cfg-digest)
      (sym_i64_env.sym-i64-empty))
      [(Ok _) unit]
      [(Err m) (io.panic m)])
    (match (hydrate.tli-multi-catalog-attach-bundle!
      (&mut multi)
      (arena.tl_arena_current)
      false
      "pkg_b"
      "1.0.0"
      "/pkg_b"
      "/pkg_b/target/dev/libpkg_b.a"
      (tlci.tlci-spmd-callables-empty)
      cat-b.directory
      (& cfg-digest)
      (sym_i64_env.sym-i64-empty))
      [(Ok _) unit]
      [(Err m) (io.panic m)])
    ;; Duplicate module name must fail closed.
    (let
      [cat-dup : hydrate.TliCatalog
        (match (hydrate.tli-catalog-open-lazy
          (& wire-a)
          "build"
          "target"
          (& cfg-digest))
          [(Ok c) c]
          [(Err f) (io.panic f.message)])]
      (match (hydrate.tli-multi-catalog-attach-bundle!
        (&mut multi)
        (arena.tl_arena_current)
        false
        "pkg_a_dup"
        "1.0.0"
        "/pkg_a_dup"
        "/pkg_a_dup/target/dev/libpkg_a_dup.a"
        (tlci.tlci-spmd-callables-empty)
        cat-dup.directory
        (& cfg-digest)
        (sym_i64_env.sym-i64-empty))
        [(Ok _) (io.panic "duplicate module across bundles must fail closed")]
        [(Err _) unit]))
    ;; Hydrating pkg_b hydrates pkg_a first and orders startup init & archives.
    (let
      [gid-b : i64
        (hydrate.tli-multi-catalog-find-module (& multi) "pkg_b.src.lib")]
      (test.assert-true (>= gid-b 0) "found pkg_b.src.lib")
      (match (hydrate.tli-multi-catalog-hydrate-gid! (&mut multi) gid-b)
        [(Ok _) unit]
        [(Err f) (io.panic f.message)])
      (let
        [inits : (__tl_dyn-array String)
          (hydrate.tli-multi-startup-archive-symbols (& multi))]
        [archives : (__tl_dyn-array String)
          (hydrate.tli-multi-hydrated-archive-paths (& multi))]
        (test.assert-i64-eq
          (array-length inits)
          2
          "two cross-bundle startup inits")
        (test.assert-owned-string-eq
          (string.copy (& (array-ref inits 0)))
          "_tl___tl_mod_init_pkg_a_src_lib"
          "dep pkg_a initializes before importer pkg_b")
        (test.assert-owned-string-eq
          (string.copy (& (array-ref inits 1)))
          "_tl___tl_mod_init_pkg_b_src_lib"
          "importer pkg_b initializes second")
        (test.assert-i64-eq
          (array-length archives)
          2
          "two hydrated package archives")
        (test.assert-owned-string-eq
          (string.copy (& (array-ref archives 0)))
          "/pkg_b/target/dev/libpkg_b.a"
          "importer archive links before dependency archive")
        (test.assert-owned-string-eq
          (string.copy (& (array-ref archives 1)))
          "/pkg_a/target/dev/libpkg_a.a"
          "dependency archive links after importer archive")))
    ;; Cross-bundle import digest mismatch must fail closed.
    (let
      [bad-digest : (Array u8 32) (make-array u8 32)]
      (set! (array-ref bad-digest 0) (cast 0xaa : u8))
      (let
        [wire-bad : (__tl_dyn-array u8)
          (tli-test-make-simple-bundle
            "pkg_c.src.lib"
            "pkg_c/src/lib.tl"
            cfg-digest
            (__tl_make-array
              (tli.TliImport "pkg_a.src.lib" 0 "a" "" bad-digest))
            false
            "_tl_pkg_c_src_lib_tl_helper")]
        [cat-c : hydrate.TliCatalog
          (match (hydrate.tli-catalog-open-lazy
            (& wire-bad)
            "build"
            "target"
            (& cfg-digest))
            [(Ok c) c]
            [(Err f) (io.panic f.message)])]
        (match (hydrate.tli-multi-catalog-attach-bundle!
          (&mut multi)
          (arena.tl_arena_current)
          false
          "pkg_c"
          "1.0.0"
          "/pkg_c"
          "/pkg_c/target/dev/libpkg_c.a"
          (tlci.tlci-spmd-callables-empty)
          cat-c.directory
          (& cfg-digest)
          (sym_i64_env.sym-i64-empty))
          [(Ok _) unit]
          [(Err m) (io.panic m)])
        (let
          [gid-c : i64
            (hydrate.tli-multi-catalog-find-module (& multi) "pkg_c.src.lib")]
          (match (hydrate.tli-multi-catalog-hydrate-gid! (&mut multi) gid-c)
            [(Ok _)
              (io.panic "cross-bundle import SHA-256 mismatch must fail closed")]
            [(Err f)
              (test.assert-true
                (match f.kind
                  [(DigestMismatch) true]
                  [_ false])
                "cross-bundle mismatch reports DigestMismatch")]))))))

(test
  tli-multi-bundle-startup-order-duplicate-and-digest-rejection
  (test.assert-owned-string-eq
    (hydrate.tli-hydrate-archive-fn-symbol-with-mode
      false
      "dep/src/lib.tl"
      (&
        (tli.TliFnDecl
          "helper"
          "dep.src.lib"
          "_tl_dep_src_lib_tl_helper"
          0
          0
          ""
          false
          0
          (__tl_make-array tli.TliExternLinkInput 0)
          (__tl_make-array tli.TliParam 0)
          (tli.TliType.I64)
          (tli.TliFnSummary
            0
            0
            (__tl_make-array i64 0)
            (__tl_make-array tli.TliGlobalWrite 0)
            -1
            (cast 0 : u8)
            0
            0
            0
            (make-array u8 32)))))
    "_tl_dep_src_lib_tl_helper"
    "non-stdlib bundle uses recorded link_symbol as-is")
  (test.assert-owned-string-eq
    (hydrate.tli-hydrate-archive-fn-symbol-with-mode
      false
      "dep/src/lib.tl"
      (&
        (tli.TliFnDecl
          "helper"
          "dep.src.lib"
          "_tl_dep_src_lib_tl_helper"
          0
          1
          "helper_c"
          false
          0
          (__tl_make-array tli.TliExternLinkInput 0)
          (__tl_make-array tli.TliParam 0)
          (tli.TliType.I64)
          (tli.TliFnSummary
            0
            0
            (__tl_make-array i64 0)
            (__tl_make-array tli.TliGlobalWrite 0)
            -1
            (cast 0 : u8)
            0
            0
            0
            (make-array u8 32)))))
    "helper_c$typelisp"
    "non-stdlib :export function uses TypeLisp ABI body symbol")
  (with-arena tli-job (tli-test-multi-bundle-closure)))

;; Minimal S-expression scanner used by the stdlib `(cfg ...)` allowlist
;; coverage test so every `(cfg predicate ...)` atom under `stdlib/`
;; (excluding `stdlib/tests/`) is guaranteed to stay in sync with
;; `tli-hydrate-stdlib-cfg-atom?`.
(define (tli-test-cfg-space? [c : char]) : bool
  (or (= c ' ') (= c '\t') (= c '\r') (= c '\n')))

(define (tli-test-cfg-delim? [c : char]) : bool
  (or
    (tli-test-cfg-space? c)
    (= c '(')
    (= c ')')
    (= c '[')
    (= c ']')
    (= c ';')
    (= c '"')
    (= c '\'')))

(define (tli-test-cfg-skip-ws [text : (& str)] [pos : i64] [n : i64]) : i64
  (let
    [i : i64 pos]
    (while (< i n)
      (let
        [c : char (string.string-ref text i)]
        (cond
          [(tli-test-cfg-space? c) (+= i 1)]
          [(= c ';')
            (while (and (< i n) (!= (string.string-ref text i) '\n'))
              (+= i 1))]
          [else (return i)])))
    i))

(define (tli-test-cfg-skip-string [text : (& str)] [pos : i64] [n : i64]) : i64
  (let
    [i : i64 (+ pos 1)]
    (while (< i n)
      (let
        [c : char (string.string-ref text i)]
        (cond
          [(= c '\\') (+= i 2)]
          [(= c '"') (return (+ i 1))]
          [else (+= i 1)])))
    n))

(define (tli-test-cfg-skip-char [text : (& str)] [pos : i64] [n : i64]) : i64
  (let
    [i : i64 (+ pos 1)]
    (when (and (< i n) (= (string.string-ref text i) '\\')) (+= i 1))
    (when (< i n) (+= i 1))
    (when (and (< i n) (= (string.string-ref text i) '\'')) (+= i 1))
    i))

(define (tli-test-cfg-read-atom-end [text : (& str)] [pos : i64] [n : i64]) : i64
  (let
    [i : i64 pos]
    (while (and (< i n) (not (tli-test-cfg-delim? (string.string-ref text i))))
      (+= i 1))
    i))

;; Walk one `(cfg <predicate> ...)` predicate starting at `pos` and verify
;; every cfg atom is covered by `hydrate.tli-hydrate-stdlib-cfg-atom?`.
;; Returns the cursor immediately after the predicate.
(define (tli-test-cfg-check-predicate!
  [path : (& str)]
  [text : (& str)]
  [pos : i64]
  [n : i64]
  [atom-count : (&mut i64)]) : i64
  (let
    [i : i64 (tli-test-cfg-skip-ws text pos n)]
    (when (>= i n) (return i))
    (let
      [c : char (string.string-ref text i)]
      (cond
        [(or (= c '(') (= c '['))
          (let
            [close : char
              (if (= c '(')
                ')'
                ']')]
            [head-start : i64 (tli-test-cfg-skip-ws text (+ i 1) n)]
            [head-end : i64 (tli-test-cfg-read-atom-end text head-start n)]
            [head : String
              (string.substring text head-start (- head-end head-start))]
            [cur : i64 (tli-test-cfg-skip-ws text head-end n)]
            (unless
              (or
                (string.eq (& head) "all")
                (string.eq (& head) "any")
                (string.eq (& head) "not"))
              (io.panic
                (str_cat.str-cat
                  "unexpected cfg predicate head '"
                  head
                  "' in "
                  (string.copy path))))
            (while (and (< cur n) (!= (string.string-ref text cur) close))
              (set!
                cur
                (tli-test-cfg-check-predicate! path text cur n atom-count))
              (set! cur (tli-test-cfg-skip-ws text cur n)))
            (if (< cur n)
              (+ cur 1)
              cur))]
        [else
          (let
            [end : i64 (tli-test-cfg-read-atom-end text i n)]
            [atom : String (string.substring text i (- end i))]
            (unless
              (hydrate.tli-hydrate-stdlib-cfg-atom? (& atom))
              (io.panic
                (str_cat.str-cat
                  "stdlib cfg atom '"
                  atom
                  "' in "
                  (string.copy path)
                  " is missing from tli-hydrate-stdlib-cfg-atom?")))
            (set! (deref atom-count) (+ (deref atom-count) 1))
            end)]))))

(define (tli-test-cfg-scan-source!
  [path : (& str)]
  [text : (& str)]
  [atom-count : (&mut i64)]) : unit
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    (while (< i n)
      (set! i (tli-test-cfg-skip-ws text i n))
      (when (>= i n) (return unit))
      (let
        [c : char (string.string-ref text i)]
        (cond
          [(= c '"') (set! i (tli-test-cfg-skip-string text i n))]
          [(= c '\'') (set! i (tli-test-cfg-skip-char text i n))]
          [(or (= c '(') (= c '['))
            (let
              [head-start : i64 (tli-test-cfg-skip-ws text (+ i 1) n)]
              [head-end : i64 (tli-test-cfg-read-atom-end text head-start n)]
              (if (= (- head-end head-start) 3)
                (let
                  [head : String (string.substring text head-start 3)]
                  (if (string.eq (& head) "cfg")
                    (set!
                      i
                      (tli-test-cfg-check-predicate!
                        path
                        text
                        head-end
                        n
                        atom-count))
                    (set! i (+ i 1))))
                (set! i (+ i 1))))]
          [else (+= i 1)])))))

(define (tli-test-cfg-tl-file? [name : (& str)]) : bool
  (let
    [n : i64 (string.string-length name)]
    (and
      (>= n 3)
      (= (string.string-ref name (- n 3)) '.')
      (= (string.string-ref name (- n 2)) 't')
      (= (string.string-ref name (- n 1)) 'l'))))

(define (tli-test-cfg-walk-stdlib!
  [dir : (& str)]
  [file-count : (&mut i64)]
  [atom-count : (&mut i64)]) : unit
  (match (fs.try-read-dir dir)
    [(ErrIoStringVector error)
      (io.panic
        (str_cat.str-cat
          "cannot read stdlib dir "
          (string.copy dir)
          ": "
          (io.error-message error)))]
    [(OkIoStringVector entries)
      (let
        [count : i64 (fs.string-vector-len (& entries))]
        (for [i (iterator.range 0 count)]
          (let
            [name : String (fs.string-vector-get (& entries) i "")]
            (unless
              (or
                (string.eq (& name) ".")
                (string.eq (& name) "..")
                (and (string.eq dir "stdlib") (string.eq (& name) "tests")))
              (let
                [full : String (fs.path-join dir (& name))]
                (match (fs.try-file-kind (& full))
                  [(OkFsFileKind kind)
                    (cond
                      [(fs.file-kind-directory? kind)
                        (tli-test-cfg-walk-stdlib!
                          (& full)
                          file-count
                          atom-count)]
                      [(and
                        (fs.file-kind-regular? kind)
                        (tli-test-cfg-tl-file? (& name)))
                        (set! (deref file-count) (+ (deref file-count) 1))
                        (match (io.try-read-file (& full))
                          [(OkIoBytes data)
                            (let
                              [text : String (byte_buf.to-string data)]
                              (tli-test-cfg-scan-source!
                                (& full)
                                (& text)
                                atom-count))]
                          [(ErrIoBytes error)
                            (io.panic (io.error-message error))])]
                      [else unit])]
                  [_ unit]))))))]))

(test
  tli-stdlib-cfg-allowlist-covers-stdlib-sources
  (let
    [file-count : i64 0]
    [atom-count : i64 0]
    (tli-test-cfg-walk-stdlib! "stdlib" (&mut file-count) (&mut atom-count))
    (test.assert-true
      (>= file-count 50)
      "stdlib cfg allowlist check scanned stdlib sources")
    (test.assert-true
      (>= atom-count 20)
      "stdlib cfg allowlist check scanned stdlib cfg predicates")))

(test
  tli-stdlib-cfg-digest-scoping
  (let
    [linux-base : sym_i64_env.SymI64Env
      (target_cfg.compiler-target-cfgs
        (target_cfg.CompilerTargetCfg.Linux)
        (cfg_core.compiler-cfg-empty))]
    [linux-with-tooling : sym_i64_env.SymI64Env
      (cfg_core.compiler-cfg-enable
        (cfg_core.compiler-cfg-enable linux-base "selfhost-compile-manifest")
        "compiler-dependency-audit")]
    [linux-with-test : sym_i64_env.SymI64Env
      (cfg_core.compiler-cfg-enable linux-base "test")]
    [linux-with-profile : sym_i64_env.SymI64Env
      (cfg_core.compiler-cfg-enable linux-base "compile-profile")]
    [win-base : sym_i64_env.SymI64Env
      (target_cfg.compiler-target-cfgs
        (target_cfg.CompilerTargetCfg.Windows)
        (cfg_core.compiler-cfg-empty))]
    [win-with-tooling : sym_i64_env.SymI64Env
      (cfg_core.compiler-cfg-enable win-base "selfhost-compile-manifest")]
    [d-linux : (Array u8 32) (hydrate.tli-hydrate-stdlib-cfg-digest linux-base)]
    [d-linux-tooling : (Array u8 32)
      (hydrate.tli-hydrate-stdlib-cfg-digest linux-with-tooling)]
    [d-linux-test : (Array u8 32)
      (hydrate.tli-hydrate-stdlib-cfg-digest linux-with-test)]
    [d-linux-profile : (Array u8 32)
      (hydrate.tli-hydrate-stdlib-cfg-digest linux-with-profile)]
    [d-win : (Array u8 32) (hydrate.tli-hydrate-stdlib-cfg-digest win-base)]
    [d-win-tooling : (Array u8 32)
      (hydrate.tli-hydrate-stdlib-cfg-digest win-with-tooling)]
    [full-linux : (Array u8 32) (hydrate.tli-hydrate-cfg-digest linux-base)]
    [full-linux-tooling : (Array u8 32)
      (hydrate.tli-hydrate-cfg-digest linux-with-tooling)]
    [names-tooling : (__tl_dyn-array String)
      (__tl_make-array "selfhost-compile-manifest" "compiler-dependency-audit")]
    [names-test : (__tl_dyn-array String) (__tl_make-array "test")]
    [d-names-linux : (Array u8 32)
      (hydrate.tli-hydrate-stdlib-cfg-digest-for-names
        false
        (& names-tooling)
        2)]
    [d-names-linux-test : (Array u8 32)
      (hydrate.tli-hydrate-stdlib-cfg-digest-for-names false (& names-test) 1)]
    [d-names-win : (Array u8 32)
      (hydrate.tli-hydrate-stdlib-cfg-digest-for-names true (& names-tooling) 2)]
    (test.assert-true
      (codec.tli-digest-eq? (& d-linux) (& d-linux-tooling))
      "non-stdlib cfgs must not change stdlib cfg digest on linux")
    (test.assert-true
      (codec.tli-digest-eq? (& d-win) (& d-win-tooling))
      "non-stdlib cfgs must not change stdlib cfg digest on windows")
    (test.assert-true
      (not (codec.tli-digest-eq? (& d-linux) (& d-win)))
      "linux and windows stdlib cfg digests must differ")
    (test.assert-true
      (not (codec.tli-digest-eq? (& d-linux) (& d-linux-test)))
      "test cfg must change stdlib cfg digest")
    (test.assert-true
      (not (codec.tli-digest-eq? (& d-linux) (& d-linux-profile)))
      "compile-profile cfg must change stdlib cfg digest")
    (test.assert-true
      (not (codec.tli-digest-eq? (& full-linux) (& full-linux-tooling)))
      "package cfg digest still hashes arbitrary user cfgs")
    (test.assert-true
      (codec.tli-digest-eq? (& d-linux) (& d-names-linux))
      "name-based linux stdlib digest matches env-based digest")
    (test.assert-true
      (codec.tli-digest-eq? (& d-linux-test) (& d-names-linux-test))
      "name-based linux+test stdlib digest matches env-based digest")
    (test.assert-true
      (codec.tli-digest-eq? (& d-win) (& d-names-win))
      "name-based windows stdlib digest matches env-based digest")))

(defstruct TliTestBorrowedBundleBox
  (directory codec.TliDirectory)
  (records (__tl_dyn-array tli.TliModuleRecord))
  (decoded (__tl_dyn-array bool))
  (owned-cell (__tl_dyn-array i64)))

(test
  tli-batch-cache-override-and-borrowed-bundle-reuse
  (sysroot.tli-batch-cache-begin!)
  (let
    [roots : strings.Vec (strings.new)]
    (strings.push-ref! (&mut roots) "nonexistent-batch-root-a")
    (test.assert-true
      (not (sysroot.tli-sysroot-stdlib-roots-override? (& roots)))
      "first missing root check returns false")
    (test.assert-true
      (not (sysroot.tli-sysroot-stdlib-roots-override? (& roots)))
      "second identical root check hits batch override cache")
    (test.assert-i64-eq
      (sysroot.tli-batch-cache-test-override-misses)
      1
      "override check computed once")
    (test.assert-i64-eq
      (sysroot.tli-batch-cache-test-override-hits)
      1
      "second override check hit cache")
    (test.assert-true
      (> (sysroot.tli-batch-cache-arena-handle) 0)
      "batch cache allocated its own arena")
    (strings.push-ref! (&mut roots) "nonexistent-batch-root-b")
    (test.assert-true
      (not (sysroot.tli-sysroot-stdlib-roots-override? (& roots)))
      "different roots recompute cleanly")
    (test.assert-i64-eq
      (sysroot.tli-batch-cache-test-override-misses)
      2
      "changed roots missed cache"))
  (sysroot.tli-batch-cache-end!)
  (test.assert-i64-eq
    (sysroot.tli-batch-cache-arena-handle)
    0
    "batch cache arena destroyed cleanly on end")
  ;; Borrowed stdlib bundle shares decoded records across independent session
  ;; multi-catalogs and survives session release without destroying its arena.
  (let
    [shared-arena : i64 (arena.tl_arena_make)]
    [enclosing : i64 (arena.tl_arena_current)]
    [cfg-digest : (Array u8 32) (make-array u8 32)]
    (unsafe
      ;; lint-allow: raw-arena-op -- test allocates a shared batch-style arena to verify borrowed reuse.
      (arena.tl_arena_set shared-arena))
    (let
      [wire : (__tl_dyn-array u8)
        (tli-test-make-simple-bundle
          "stdlib.batch_probe"
          "stdlib/batch_probe.tl"
          cfg-digest
          (__tl_make-array tli.TliImport 0)
          true
          "_tl_stdlib_batch_probe_helper")]
      [cat : hydrate.TliCatalog
        (match (hydrate.tli-catalog-open-lazy
          (& wire)
          "build"
          "target"
          (& cfg-digest))
          [(Ok c) c]
          [(Err f) (io.panic f.message)])]
      [records : (__tl_dyn-array tli.TliModuleRecord)
        (__tl_make-array tli.TliModuleRecord 1)]
      [decoded : (__tl_dyn-array bool) (__tl_make-array bool 1)]
      [owned-cell : (__tl_dyn-array i64) (__tl_make-array cat.owned-bytes)]
      [box-cell : (__tl_dyn-array TliTestBorrowedBundleBox)
        (__tl_make-array
          (TliTestBorrowedBundleBox cat.directory records decoded owned-cell))]
      [box-addr : i64
        (unsafe
          (cast (ptr->int (__tl_array-data box-cell)) : i64))]
      (unsafe
        ;; lint-allow: raw-arena-op -- restore caller arena after populating shared test bundle.
        (arena.tl_arena_set enclosing))
      ;; Session 1 decodes into shared-arena and releases only its own root-arena.
      (let
        [root1 : i64 (arena.tl_arena_make)]
        [m1 : hydrate.TliMultiCatalog (hydrate.tli-multi-catalog-new root1)]
        [view1 : TliTestBorrowedBundleBox
          (unsafe
            (ptr-read
              (int->ptr (cast box-addr : u64) : (Ptr TliTestBorrowedBundleBox))))]
        (match (hydrate.tli-multi-catalog-attach-borrowed-stdlib-bundle!
          (&mut m1)
          shared-arena
          "/sysroot/libstdlib.a"
          view1.directory
          (& cfg-digest)
          (sym_i64_env.sym-i64-empty)
          view1.records
          view1.decoded
          view1.owned-cell)
          [(Ok _) unit]
          [(Err m) (io.panic m)])
        (test.assert-i64-eq
          (array-ref (hydrate.tli-multi-catalog-arenas (& m1)) 1)
          0
          "borrowed bundle arena is excluded from session-owned arenas")
        (match (hydrate.tli-multi-catalog-hydrate-gid! (&mut m1) 0)
          [(Ok _) unit]
          [(Err f) (io.panic f.message)])
        (test.assert-true
          (unsafe
            (array-ref
              (ptr-read
                (int->ptr
                  (cast box-addr : u64)
                  : (Ptr TliTestBorrowedBundleBox))).decoded
              0))
          "session 1 marked shared module record decoded")
        (hydrate.tli-multi-catalog-release! (& m1)))
      ;; Session 2 reuses the already-decoded record after session 1 released.
      (let
        [root2 : i64 (arena.tl_arena_make)]
        [m2 : hydrate.TliMultiCatalog (hydrate.tli-multi-catalog-new root2)]
        [view2 : TliTestBorrowedBundleBox
          (unsafe
            (ptr-read
              (int->ptr (cast box-addr : u64) : (Ptr TliTestBorrowedBundleBox))))]
        (match (hydrate.tli-multi-catalog-attach-borrowed-stdlib-bundle!
          (&mut m2)
          shared-arena
          "/sysroot/libstdlib.a"
          view2.directory
          (& cfg-digest)
          (sym_i64_env.sym-i64-empty)
          view2.records
          view2.decoded
          view2.owned-cell)
          [(Ok _) unit]
          [(Err m) (io.panic m)])
        (match (hydrate.tli-multi-catalog-hydrate-gid! (&mut m2) 0)
          [(Ok _) unit]
          [(Err f) (io.panic f.message)])
        (let
          [inits : (__tl_dyn-array String)
            (hydrate.tli-multi-startup-archive-symbols (& m2))]
          (test.assert-i64-eq
            (array-length inits)
            1
            "session 2 sees startup init from cached decoded record"))
        (hydrate.tli-multi-catalog-release! (& m2)))
      (unsafe
        ;; lint-allow: raw-arena-op -- destroy shared test bundle arena after both sessions release.
        (arena.tl_arena_destroy shared-arena)))))