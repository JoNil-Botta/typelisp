;; Emit a checked interface from the embedded source inventory, then read it
;; back through the same directory and lazy record APIs used by inspect.
(import compiler_tli_extract as extract)
(import compiler_tli_types as tli)
(import compiler_tli_codec as codec)
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

(define expected-modules : i64
  83)

;; The embedded catalog includes clone.deep (#9875).
(define expected-native-handles : i64
  (cfg embedded-stdlib-tlci 170 0))

(define (embedded-paths) : (__tl_dyn-array String)
  (let
    [paths : (__tl_dyn-array String) (__tl_make-array String expected-modules)]
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
            (or (< end start) (>= count expected-modules))
            (io.panic "invalid embedded stdlib source inventory"))
          (set!
            (array-ref paths count)
            (string.substring (& payload-inventory) start (- end start)))
          (+= count 1)
          (set! cursor (+ end 1)))
        (+= cursor 1)))
    (when
      (!= count expected-modules)
      (io.panic "unexpected embedded stdlib source count"))
    paths))

(define (roundtrip-load) : tli.TliBundle
  (api.compiler-typecheck-reset-load-session!)
  (let
    [paths : (__tl_dyn-array String) (embedded-paths)]
    [sources : (__tl_dyn-array extract.TliSource)
      (__tl_make-array extract.TliSource expected-modules)]
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
    (for [index (iterator.range 0 expected-modules)]
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
      (!= count expected-modules)
      (io.panic "wrong TLI module directory count"))
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
    (let
      [bundle : tli.TliBundle
        (tli.TliBundle
          directory.flags
          directory.compiler-build
          directory.target-triple
          modules)]
      [reencoded : (__tl_dyn-array u8) (codec.tli-encode-bundle (& bundle))]
      (when
        (!= (array-length reencoded) (array-length bytes))
        (io.panic "re-encoded TLI length changed"))
      (for [index (iterator.range 0 (array-length bytes))]
        (when
          (!= (array-ref reencoded index) (array-ref bytes index))
          (io.panic "re-encoded TLI bytes changed"))))
    (io.println
      "{}/{} modules, {} bytes, bit-identical. imports={} inits={} types={} functions={} values={} macros={} dispatches={} opaque={} cleanup={} consts={} never={} writes={} arena-global={} arena-param={} native={}"
      count
      expected-modules
      (array-length bytes)
      counts.imports
      counts.inits
      counts.types
      counts.functions
      counts.values
      counts.macros
      counts.dispatches
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

(define (main) : i64
  (when (!= (io.arg-count) 2) (io.panic "usage: roundtrip <out.tli>"))
  (let
    [path : String (io.arg 1)]
    [bundle : tli.TliBundle (roundtrip-load)]
    [encoded : byte_buf.ByteBuf
      (byte_buf.from-array (codec.tli-encode-bundle (& bundle)))]
    (match (io.try-write-file (& path) (byte_buf.as-bytes (& encoded)))
      [(OkIoUnit) unit]
      [(ErrIoUnit _) (io.panic "cannot write TLI bundle")])
    (match (io.try-read-file (& path))
      [(OkIoBytes data) (roundtrip-verify (& (byte_buf.to-array data)))]
      [(ErrIoBytes _) (io.panic "cannot read TLI bundle")]))
  0)