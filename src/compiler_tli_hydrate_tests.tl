(import compiler_tli_hydrate as hydrate)
(import compiler_tli_codec as codec)
(import compiler_tli_types as tli)
(import compiler_intern as intern)
(import compiler_tli_extract as extract)
(import compiler_ast_types as ast)
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
(import stdlib.byte_le)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.iterator)
(import stdlib.profile)
(import stdlib.test)

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
          (tli-hydrate-fixture-module "unused" "__tl_mod_init_unused" 1)))]
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
        0
        0)]
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
          0
          0))]
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
    [offset : i64 (+ pool-start 4)]
    (for [_ (iterator.range 0 count)]
      (let
        [length : i64 (byte_le.read-u32 wire offset)]
        [start : i64 (+ offset 4)]
        [candidate : (__tl_dyn-array u8) (__tl_make-array u8 length)]
        (for [index (iterator.range 0 length)]
          (set! (array-ref candidate index) (array-ref wire (+ start index))))
        (let
          [found : String (byte_buf.to-string (byte_buf.from-array candidate))]
          (when (string.eq (& found) text) (return start)))
        (set! offset (+ start length))))
    (io.panic "pool text not found")))

;; Opening rejects a damaged string pool before any hydration: the eager open
;; through its content SHA-256 and UTF-8 checks, and the compiler's lazy
;; stdlib.tli open through the UTF-8 check on each pool string it reads.
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
    ;; The directory names every module, so both opens read this entry.
    [text : i64 (tli-test-pool-text-offset (& wire) "stdlib.io")]
    (set! (array-ref wire text) (cast 0xff : u8))
    (with-arena
      tli-job
      (tli-test-expect-open-failure
        (& wire)
        (& cfg-digest)
        false
        false
        "modified string pool bytes fail the content SHA-256")
      (tli-test-expect-open-failure
        (& wire)
        (& cfg-digest)
        true
        true
        "lazy open rejects invalid UTF-8 pool text"))
    (let
      [digest : (Array u8 32) (codec.tli-content-digest (& wire))]
      (codec.tli-copy-digest! (&mut wire) 80 (& digest))
      (with-arena
        tli-job
        (tli-test-expect-open-failure
          (& wire)
          (& cfg-digest)
          false
          true
          "re-hashed invalid UTF-8 pool text is rejected")))))