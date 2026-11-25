;; Emit a checked interface from the embedded source inventory, then read it
;; back through the same directory and lazy record APIs used by inspect.
(import compiler_tli_extract as extract)
(import compiler_tli_types as tli)
(import compiler_tli_codec as codec)
(import compiler_tli_hydrate as hydrate)
(import compiler_intern as intern)
(cfg embedded-stdlib-tlci (import compiler_embedded_stdlib_tlci as tlci))
(import compiler_ast_types as ast)
(import compiler_load as load)
(import compiler_embedded_stdlib as embedded)
(import compiler_typecheck_api as api)
(import compiler_typecheck_core as tc)
(import compiler_cfg_core as cfg_core)
(import compiler_target_cfg_core as target_cfg)
(import compiler_build_identity as identity)
(import compiler_diagnostic as diag)
(import sym_i64_env as sym_env)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.iterator)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as strings)

(include-str payload-inventory "../../src/compiler_embedded_stdlib_payload.tl")

(define expected-source-modules : i64
  83)
(define expected-generated-modules : i64
  13)

;; Includes the current native clone operations.
(define expected-native-handles : i64
  (cfg embedded-stdlib-tlci 172 0))

(define (embedded-paths) : (__tl_dyn-array String)
  (let
    [paths : (__tl_dyn-array String)
      (__tl_make-array String expected-source-modules)]
    [count : i64 0]
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
            (or (< end start) (>= count expected-source-modules))
            (io.panic "invalid embedded stdlib source inventory"))
          (set!
            (array-ref paths count)
            (string.substring (& payload-inventory) start (- end start)))
          (+= count 1)
          (set! cursor (+ end 1)))
        (+= cursor 1)))
    (when
      (!= count expected-source-modules)
      (io.panic "unexpected embedded stdlib source count"))
    paths))

(define (roundtrip-load) : tli.TliBundle
  (api.compiler-typecheck-reset-load-session!)
  (let
    [paths : (__tl_dyn-array String) (embedded-paths)]
    [sources : (__tl_dyn-array extract.TliSource)
      (__tl_make-array extract.TliSource expected-source-modules)]
    [roots : strings.Vec (strings.new)]
    [cfgs : sym_env.SymI64Env
      (cfg
        windows
        (target_cfg.compiler-target-enable-windows-cfgs
          (cfg_core.compiler-cfg-empty))
        (target_cfg.compiler-target-enable-linux-cfgs
          (cfg_core.compiler-cfg-empty)))]
    [decls : ast.AstDeclList (ast.ast-decl-list-new)]
    [decl-paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
    [seen : sym_env.SymI64Env (sym_env.sym-i64-empty)]
    (for [index (iterator.range 0 expected-source-modules)]
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
    (match (extract.tli-extract
      (api.typecheck-request-serial
        (ast.AstProgram.Program (box decls))
        decl-paths
        roots
        cfgs
        (tc.tc-prefix-default-cache-scope))
      (& sources)
      (+
        tli.tli-is-stdlib-bundle
        (cfg embedded-stdlib-tlci tli.tli-has-tlci-companion 0))
      (identity.compiler-build-producer-identity)
      (cfg windows "x86_64-pc-windows-msvc" "x86_64-unknown-linux-gnu"))
      [(Ok bundle) bundle]
      [(Err message) (io.panic message)])))

(defstruct RoundtripCounts
  (imports i64)
  (inits i64)
  (types i64)
  (functions i64)
  (values i64)
  (macros i64)
  (dispatches i64)
  (opaque i64)
  (cleanup i64)
  (consts i64)
  (never i64)
  (writes i64)
  (arena-global i64)
  (arena-param i64)
  (native i64))

(define (roundtrip-count!
  [counts : (&mut RoundtripCounts)]
  [row : (& row tli.TliModuleRecord)]) : unit
  (+= counts.imports (array-length row.imports))
  (+= counts.inits (array-length row.global-inits))
  (+= counts.types (array-length row.types))
  (+= counts.functions (array-length row.functions))
  (+= counts.values (array-length row.values))
  (+= counts.macros (array-length row.macros))
  (+= counts.dispatches (array-length row.dispatches))
  (for [item (& row.types)]
    (when (!= (bit-and item.flags 2) 0) (+= counts.opaque 1))
    (when (!= (bit-and item.flags 16) 0) (+= counts.cleanup 1)))
  (for [item (& row.values)]
    (when (!= (bit-and item.flags 8) 0) (+= counts.consts 1)))
  (for [item (& row.functions)]
    (when (!= (bit-and item.summary.effect-flags 8) 0) (+= counts.never 1))
    (when
      (!= (bit-and item.summary.effect-flags 16) 0)
      (+= counts.arena-global 1))
    (when
      (or
        (!= item.summary.arena-arg-store-mask 0)
        (> (array-length item.summary.arena-arg-store-extra) 0))
      (+= counts.arena-param 1))
    (+= counts.writes (array-length item.summary.global-writes)))
  (for [item (& row.macros)]
    (when
      (!= (bit-and item.flags 1) 0)
      (when
        (< item.tlci-entry-index 0)
        (io.panic "negative native macro index"))
      (+= counts.native 1))))

(define (roundtrip-verify-imports
  [row : (& row tli.TliModuleRecord)]
  [directory : (& directory codec.TliDirectory)]) : unit
  (for [edge (& row.imports)]
    (for [entry (& directory.entries)]
      (when
        (string.eq (& edge.module-name) (& entry.name))
        (unless
          (codec.tli-digest-eq?
            (& edge.interface-sha256)
            (& entry.module-sha256))
          (io.panic "in-bundle import does not pin its directory entry"))
        (break)))))

(define (roundtrip-verify [bytes : (& (__tl_dyn-array u8))]) : unit
  (let
    [directory : codec.TliDirectory
      (match (codec.tli-decode-directory bytes)
        [(Ok directory) directory]
        [(Err failure) (io.panic failure.message)])]
    [count : i64 (array-length directory.entries)]
    [modules : (__tl_dyn-array tli.TliModuleRecord)
      (__tl_make-array tli.TliModuleRecord count)]
    [counts : RoundtripCounts (RoundtripCounts 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)]
    (when
      (!= count (+ expected-source-modules expected-generated-modules))
      (io.panic "unexpected TLI source and generated module count"))
    (let
      [paths : (__tl_dyn-array String) (embedded-paths)]
      (for [index (iterator.range 0 expected-source-modules)]
        (let
          [path : String
            (str_cat.str-cat
              "stdlib/"
              (string.copy (& (array-ref paths index))))]
          [name : String
            (load.compiler-load-canonical-module-id-from-path (& path))]
          (when
            (< (hydrate.tli-catalog-find (& directory) (& name)) 0)
            (io.panic
              (string.append "TLI directory is missing source module " (& name)))))))
    (for [index (iterator.range 0 count)]
      (match (codec.tli-decode-module-at (& directory) index)
        [(Ok row)
          (roundtrip-count! (&mut counts) (& row))
          (roundtrip-verify-imports (& row) (& directory))
          (set! (array-ref modules index) row)]
        [(Err failure)
          (io.panic
            (str_cat.str-cat
              (string.copy (& (array-ref directory.entries index).name))
              ": "
              failure.message))]))
    (match (codec.tli-decode-bundle (& bytes))
      [(Err failure) (io.panic failure.message)]
      [(Ok bundle)
        (let
          [reencoded : (__tl_dyn-array u8) (codec.tli-encode-bundle (& bundle))]
          (when
            (!= (array-length reencoded) (array-length bytes))
            (io.panic "re-encoded TLI length changed"))
          (for [index (iterator.range 0 (array-length bytes))]
            (when
              (!= (array-ref reencoded index) (array-ref bytes index))
              (io.panic "re-encoded TLI bytes changed"))))])
    (io.println
      "{}/{} source modules and {} generated modules, {} bytes, bit-identical. imports={} inits={} types={} functions={} values={} macros={} dispatches={}"
      expected-source-modules
      expected-source-modules
      (- count expected-source-modules)
      (array-length bytes)
      counts.imports
      counts.inits
      counts.types
      counts.functions
      counts.values
      counts.macros
      counts.dispatches)
    (io.println
      "opaque={} cleanup={} consts={} never={} writes={} arena-global={} arena-param={} native={}"
      counts.opaque
      counts.cleanup
      counts.consts
      counts.never
      counts.writes
      counts.arena-global
      counts.arena-param
      counts.native)
    (unless
      (and
        (> counts.imports 0)
        (> counts.inits 0)
        (> counts.types 0)
        (> counts.functions 0)
        (> counts.values 0)
        (> counts.macros 0)
        (> counts.opaque 0)
        (> counts.cleanup 0)
        (> counts.consts 0)
        (> counts.never 0)
        (> counts.writes 0)
        (> counts.arena-param 0)
        (= counts.native expected-native-handles))
      (io.panic "unexpected TLI section counts"))))

(cfg
  embedded-stdlib-tlci
  (define (roundtrip-native-macro! [row : (& tli.TliMacroHandle)]) : unit
    (when
      (!= (bit-and row.flags 1) 0)
      (match (tlci.compiler-embedded-stdlib-tlci-catalog-lookup
        (string.copy (& row.identity)))
        [(Resolved resolved)
          (let
            [digest : (Array u8 32)
              (extract.tli-extract-native-catalog-digest
                resolved.catalog-generation)]
            (match (hydrate.tli-hydrate-native-macro
              row
              resolved.entry-index
              (& digest))
              [(Native _ _ _) unit]
              [_ (io.panic "TLI handle mismatches native TLCI lookup")]))]
        [_ (io.panic "native TLI handle has no TLCI entry")]))))

(define (roundtrip-project!
  [counts : (&mut RoundtripCounts)]
  [row : (& tli.TliModuleRecord)]) : unit
  (roundtrip-count! counts row)
  (for [index (iterator.range 0 (array-length row.types))]
    (let
      [ty : hydrate.TliHydratedType
        (hydrate.tli-hydrate-type-decl (& (array-ref row.types index)))]
      (unless
        (and (>= ty.size 0) (>= ty.align 0))
        (io.panic "invalid projected type layout"))))
  (for [index (iterator.range 0 (array-length row.functions))]
    (let
      [fn : hydrate.TliHydratedFunction
        (hydrate.tli-hydrate-function (& (array-ref row.functions index)))]
      (match (ast.ty-node-get fn.signature-id)
        [(Func _ _) unit]
        [_ (io.panic "invalid projected function signature")])))
  (for [index (iterator.range 0 (array-length row.values))]
    (let
      [value : hydrate.TliHydratedValue
        (hydrate.tli-hydrate-value (& (array-ref row.values index)))]
      (when (< value.type-id 0) (io.panic "invalid projected value type"))))
  (cfg
    embedded-stdlib-tlci
    (for [index (iterator.range 0 (array-length row.macros))]
      (roundtrip-native-macro! (& (array-ref row.macros index))))))

(define (roundtrip-hydrate!
  [bytes : (& bytes (__tl_dyn-array u8))]
  [cfg-digest : (& (Array u8 32))]) : unit
  (let
    [build : String (identity.compiler-build-producer-identity)]
    [target : String
      (cfg windows "x86_64-pc-windows-msvc" "x86_64-unknown-linux-gnu")]
    [catalog : hydrate.TliCatalog
      (match (hydrate.tli-catalog-open bytes (& build) (& target) cfg-digest)
        [(Ok catalog) catalog]
        [(Err error) (io.panic error.message)])]
    [counts : RoundtripCounts (RoundtripCounts 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)]
    (when
      (!= (hydrate.tli-catalog-ready-count (& catalog)) 0)
      (io.panic "TLI directory decoded records eagerly"))
    (match (hydrate.tli-catalog-hydrate! (&mut catalog) "stdlib.io")
      [(Ok _)
        (when
          (!= (hydrate.tli-catalog-ready-count (& catalog)) 11)
          (io.panic "stdlib.io must hydrate ten dependencies and the root"))]
      [(Err error) (io.panic error.message)])
    (for [index
      (iterator.range
        0
        (array-length (hydrate.tli-catalog-directory (& catalog)).entries))]
      (match (hydrate.tli-catalog-record (& catalog) index)
        [(Some row) (roundtrip-project! (&mut counts) row)]
        [(None) unit]))
    (let
      [startup : (__tl_dyn-array i64)
        (hydrate.tli-catalog-startup-symbols (& catalog))]
      (unless
        (and
          (> counts.types 0)
          (> counts.functions 0)
          (> counts.macros 0)
          (= counts.inits 2)
          (= (array-length startup) 2)
          (string.eq
            (intern.intern-str (array-ref startup 0))
            "__tl_mod_init_stdlib.format_writer_core")
          (string.eq
            (intern.intern-str (array-ref startup 1))
            "__tl_mod_init_stdlib.format"))
        (io.panic "stdlib.io closure lost semantic facts or init order")))
    (let
      [names : (Array String 3) (array "stdlib.args" "stdlib.json" "stdlib.fs")]
      (for [index (iterator.range 0 3)]
        (match (hydrate.tli-catalog-hydrate!
          (&mut catalog)
          (& (array-ref names index)))
          [(Ok _) unit]
          [(Err error) (io.panic error.message)])))
    (let
      [names : (Array String 3)
        (array
          "stdlib.vector.generated.String"
          "stdlib.vector.generated.core.enum_stdlib.json/Json"
          "stdlib.vector.generated.core.struct_stdlib.json/JsonMember")]
      (for [index (iterator.range 0 3)]
        (let
          [index : i64
            (hydrate.tli-catalog-find
              (hydrate.tli-catalog-directory (& catalog))
              (& (array-ref names index)))]
          (match (hydrate.tli-catalog-record (& catalog) index)
            [(Some row)
              (unless
                (and
                  (> (array-length row.types) 0)
                  (> (array-length row.functions) 0))
                (io.panic "generated stdlib interface has no declarations"))]
            [(None) (io.panic "generated stdlib interface did not hydrate")])))))
  (cfg embedded-stdlib-tlci (tlci.compiler-embedded-stdlib-tlci-session-close!)))

(define (main) : i64
  (when (!= (io.arg-count) 2) (io.panic "usage: roundtrip <out.tli>"))
  (let
    [path : String (io.arg 1)]
    [bundle : tli.TliBundle (roundtrip-load)]
    [cfg-digest : (Array u8 32)
      (array-ref bundle.modules 0).cfg-fingerprint-sha256]
    [encoded : byte_buf.ByteBuf
      (byte_buf.from-array (codec.tli-encode-bundle (& bundle)))]
    (match (io.try-write-file (& path) (byte_buf.as-bytes (& encoded)))
      [(OkIoUnit) unit]
      [(ErrIoUnit _) (io.panic "cannot write TLI bundle")])
    (match (io.try-read-file (& path))
      [(OkIoBytes data)
        (let
          [bytes : (__tl_dyn-array u8) (byte_buf.to-array data)]
          (roundtrip-verify (& bytes))
          (with-arena
            tli-job
            (unsafe
              ;; Compiler interner, AST pool and TLCI session select their own storage.
              (roundtrip-hydrate! (& bytes) (& cfg-digest)))))]
      [(ErrIoBytes _) (io.panic "cannot read TLI bundle")]))
  0)