(import compiler_tli_extract as extract)
(import compiler_tli_codec as codec)
(import compiler_tli_types as tli)
(import compiler_tli_hydrate as hydrate)
(import tlci_core as tlci)
(import compiler_typecheck_api as api)
(import compiler_ast_types as ast)
(import compiler_diagnostic as diag)
(import compiler_incremental_binary as binary)
(import compiler_typecheck_core as tc)
(import sym_i64_env)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.test)
(import stdlib.vector)
(import (vector.vector String) as strings)

(define (extract-fixture) : String
  "(module fixture)
(import stdlib.string)
(import stdlib.io)
(import stdlib.arena)
(defstruct Handle (:must-use) (:opaque) (:cleanup close-handle)
  (code i8) (fd i64 (:cleanup close-fd) (:opaque)))
(define (close-fd [fd : i64]) : unit unit)
(defenum Event (Empty) (Ready i64))
(defstruct Raw (:repr c) (code i8) (fd i32 (:align 8)))
(defstruct Borrowed (:lifetimes r) (fd (& r i64)))
(define (borrow [value : (& r i64)]) : (Borrowed r) (Borrowed value))
(define value : i64 (comptime (+ 20 22)))
(define converted : f64 (cast (comptime 42) : f64))
(define g : String \"\")
(define (stash) : unit (set! g (string.append \"a\" \"b\")))
(define (relay) : unit (stash))
(define (arena-handle [a : arena.Arena]) : arena.Arena a)
(define (stash-in-arena [a : arena.Arena]) : unit
  (in-arena (arena-handle a) (set! g (string.copy \"kept\"))))
(define (put [out : (&mut String)]) : unit
  (set! (deref out) (string.append \"a\" \"b\")))
(define (scoped [f : (-> unit)]) : unit (with-arena phase (f)))
(define (noop) : unit unit)
(define (caller [x : i64]) : unit (scoped noop))
(define (forward [a : (-> unit)] [b : (-> unit)]) : unit (scoped b))
(define (wrap [a : (-> unit)] [b : (-> unit)]) : unit
  (scoped b)
  (with-arena phase (b)))
(define (startup) : i64 3)
(define first : i64 (startup))
(define second : i64 (startup))
(defmacro (emit-runtime [f : Expr] [v : Expr]) : Decls
  `(begin
    (define (,f) : unit (set! g (string.append \"a\" \"b\")))
    (define ,v : i64 (startup))))
(emit-runtime mutate generated)
(define (stop) : never (io.panic \"stop\"))
(unsafe (define (unsafe-id [x : i64]) : i64 x))
(defdispatch dispatch (scalar startup))
(extern (foreign [fixed : i64] [tail : ...i64]) : i64 (:symbol \"external_name\"))
(extern errno-slot (:symbol \"errno_slot\") (:link-lib \"crt_fixture\") : i64)
(defmacro (keep [value : Expr]) : Expr value)
(define (hidden-unsafe) : i64 (unsafe 1))
(define (via-hidden) : i64 (hidden-unsafe))
(define (reads-errno) : i64 errno-slot)
")

(define (extract-fixture-module [source : String]) : tli.TliModuleRecord
  (api.compiler-typecheck-reset-load-session!)
  (let
    [cfgs : sym_i64_env.SymI64Env (api.typecheck-compiler-source-language-cfgs)]
    [roots : strings.Vec (strings.new)]
    [sources : (__tl_dyn-array extract.TliSource)
      (__tl_make-array
        (extract.TliSource
          "fixture"
          ""
          (extract.tli-extract-sha256 (byte_buf.str-as-bytes (& source)))))]
    [bundle : tli.TliBundle
      (match (api.typecheck-compiler-source-load (string.copy (& source)))
        [(Ok decls paths _ _)
          (match (extract.tli-extract
            (api.typecheck-request-serial
              (ast.AstProgram.Program (box decls))
              paths
              roots
              cfgs
              (tc.tc-prefix-default-cache-scope))
            (& sources)
            tli.tli-is-stdlib-bundle
            "test"
            "x86_64-unknown-linux-gnu")
            [(Ok bundle) bundle]
            [(Err message) (io.panic message)])]
        [(Err failure)
          (io.panic
            (diag.compiler-diagnostic-render (& (__tl-box-place failure))))])]
    [encoded : (__tl_dyn-array u8) (codec.tli-encode-bundle (& bundle))]
    (match (codec.tli-decode-bundle (& encoded))
      [(Ok decoded)
        (test.assert-true
          (binary.compiler-incremental-binary-bytes-eq?
            (& encoded)
            (& (codec.tli-encode-bundle (& decoded))))
          "extract, decode and re-encode agree byte-for-byte")
        (let
          [live : (__tl_dyn-array bool) (__tl_make-array true)]
          (test.assert-i64-eq
            (array-length decoded.modules)
            1
            "one requested module")
          (tuple-ref (__tl_array-take! decoded.modules live 0) 1))]
      [(Err failure) (io.panic failure.message)])))

(define (extract-assert-impure
  [row : (& row tli.TliModuleRecord)]
  [name : (& str)]) : unit
  (test.assert-i64-eq
    (bit-and (extract-fixture-fn row name).summary.effect-flags 4)
    0
    (string.copy name)))

(define (extract-fixture-fn
  [row : (& row tli.TliModuleRecord)]
  [name : (& str)]) : (& row tli.TliFnDecl)
  (for [index (iterator.range 0 (array-length row.functions))]
    (when
      (string.eq (& (array-ref row.functions index).name) name)
      (return (& (array-ref row.functions index)))))
  (io.panic name))

(define (extract-fixture-value
  [row : (& row tli.TliModuleRecord)]
  [name : (& str)]) : (& row tli.TliValueDecl)
  (for [index (iterator.range 0 (array-length row.values))]
    (when
      (string.eq (& (array-ref row.values index).name) name)
      (return (& (array-ref row.values index)))))
  (io.panic name))

(test
  tli-checked-program-roundtrip
  (let
    [row : tli.TliModuleRecord (extract-fixture-module (extract-fixture))]
    (test.assert-string-eq (& row.name) "fixture" "module owner")
    (test.assert-i64-eq (array-length row.imports) 3 "three import edges")
    (test.assert-i64-eq (array-length row.types) 4 "structs and enum")
    (let
      [event (& (array-ref row.types 1))]
      [handle (& (array-ref row.types 2))]
      (test.assert-string-eq (& event.name) "Event" "enum row")
      (test.assert-i64-eq event.layout-size 16 "tag and payload size")
      (test.assert-i64-eq event.layout-align 8 "payload alignment")
      (match (& event.body)
        [(Enum variants)
          (test.assert-i64-eq (array-length variants) 2 "two variants")]
        [_ (io.panic "expected enum")])
      (test.assert-string-eq (& handle.name) "Handle" "struct row")
      (test.assert-i64-eq handle.flags 19 "must-use, opaque, cleanup")
      (test.assert-i64-eq (array-ref row.types 3).repr-kind 1 "repr c")
      (test.assert-i64-eq handle.layout-size 16 "struct size")
      (test.assert-i64-eq handle.layout-align 8 "struct alignment")
      (match (& handle.cleanup)
        [(Fn name)
          (test.assert-string-eq name "fixture/close-handle" "type cleanup")]
        [_ (io.panic "expected type cleanup")])
      (match (& handle.body)
        [(Struct fields)
          (test.assert-true (not (array-ref fields 0).opaque?) "public field")
          (let
            [fd (& (array-ref fields 1))]
            (test.assert-true fd.opaque? "opaque field")
            (test.assert-i64-eq fd.byte-offset 8 "checked field offset")
            (match (& fd.cleanup)
              [(Fn name)
                (test.assert-string-eq name "fixture/close-fd" "field cleanup")]
              [_ (io.panic "expected field cleanup")]))]
        [_ (io.panic "expected struct")]))
    (let
      [stash (extract-fixture-fn (& row) "stash")]
      [relay (extract-fixture-fn (& row) "relay")]
      [scoped (extract-fixture-fn (& row) "scoped")]
      [stop (extract-fixture-fn (& row) "stop")]
      [foreign (extract-fixture-fn (& row) "foreign")]
      [unsafe-id (extract-fixture-fn (& row) "unsafe-id")]
      [borrow (extract-fixture-fn (& row) "borrow")]
      (test.assert-string-eq
        (& stash.link-symbol)
        "fixture/stash"
        "canonical function symbol")
      (test.assert-i64-eq
        (bit-and relay.summary.effect-flags 16)
        16
        "transitive arena global escape")
      (test.assert-i64-eq
        scoped.summary.arena-arg-store-mask
        1
        "arena-scoped parameter call")
      (test.assert-i64-eq
        (bit-and stop.summary.effect-flags 8)
        8
        "never returns")
      (test.assert-i64-eq
        (bit-and unsafe-id.summary.effect-flags 1)
        1
        "unsafe declaration")
      ;; PURE (4) certifies the transitive comptime-purity walk.
      (test.assert-i64-eq
        (bit-and (extract-fixture-fn (& row) "startup").summary.effect-flags 4)
        4
        "pure body")
      (extract-assert-impure (& row) "hidden-unsafe")
      (extract-assert-impure (& row) "via-hidden")
      (extract-assert-impure (& row) "reads-errno")
      (extract-assert-impure (& row) "stop")
      (extract-assert-impure (& row) "unsafe-id")
      (test.assert-i64-eq foreign.abi 3 "typed C vararg wire tag")
      (test.assert-string-eq
        (& foreign.link-symbol)
        "external_name"
        "explicit extern symbol")
      (test.assert-i64-eq
        (array-length foreign.params)
        2
        "fixed parameters and typed tail")
      (match (& borrow.return-type)
        [(StructArgs name lifetimes)
          (test.assert-string-eq name "fixture/Borrowed" "qualified nominal")
          (test.assert-string-eq
            (& (array-ref lifetimes 0))
            "r"
            "portable lifetime")]
        [_ (io.panic "expected lifetime-parameterized nominal")])
      (test.assert-i64-eq
        (array-length stash.summary.global-writes)
        1
        "one direct global write")
      (test.assert-i64-eq
        (array-length relay.summary.global-writes)
        1
        "one transitive global write")
      (let
        [write (& (array-ref relay.summary.global-writes 0))]
        (test.assert-string-eq
          (& write.symbol)
          "fixture/g"
          "global write symbol")
        (test.assert-i64-eq (cast write.flags : i64) 2 "transitive write flag"))
      (test.assert-i64-eq
        (cast (array-ref stash.summary.global-writes 0).flags : i64)
        1
        "direct write flag"))
    (let
      [explicit (extract-fixture-fn (& row) "stash-in-arena")]
      [put (extract-fixture-fn (& row) "put")]
      [caller (extract-fixture-fn (& row) "caller")]
      [forward (extract-fixture-fn (& row) "forward")]
      [wrap (extract-fixture-fn (& row) "wrap")]
      [mutate (extract-fixture-fn (& row) "mutate")]
      (test.assert-i64-eq
        (bit-and explicit.summary.effect-flags 16)
        0
        "explicit arena global write does not use the ambient arena")
      (test.assert-i64-eq
        (bit-and put.summary.effect-flags 288)
        256
        "ambient arena argument store has its own effect bit")
      (test.assert-i64-eq caller.summary.arena-arg-store-mask 0 "plain caller")
      (test.assert-i64-eq
        forward.summary.arena-arg-store-mask
        0
        "forwarded callback")
      (test.assert-i64-eq
        wrap.summary.arena-arg-store-mask
        2
        "direct call of parameter 1")
      (test.assert-i64-eq
        (bit-and mutate.summary.effect-flags 6)
        0
        "generated function is runtime and can mutate globals")
      (test.assert-i64-eq
        (array-length mutate.summary.global-writes)
        1
        "generated function records its global write"))
    (test.assert-i64-eq (bit-and row.flags 1) 1 "module has global inits")
    (test.assert-i64-eq
      (array-length row.global-inits)
      1
      "one startup wrapper per module")
    (test.assert-string-eq
      (& (array-ref row.global-inits 0))
      "__tl_mod_init_fixture"
      "module startup wrapper symbol")
    (let
      [value (extract-fixture-value (& row) "value")]
      [converted (extract-fixture-value (& row) "converted")]
      [generated (extract-fixture-value (& row) "generated")]
      [foreign-value (extract-fixture-value (& row) "errno-slot")]
      (test.assert-true foreign-value.is-extern "extern value is marked")
      (test.assert-true (not value.is-extern) "local value is marked")
      (test.assert-i64-eq
        (array-length foreign-value.extern-link-inputs)
        1
        "extern value link input")
      (test.assert-string-eq
        (& (array-ref foreign-value.extern-link-inputs 0).name)
        "crt_fixture"
        "extern value links its declared library")
      (test.assert-i64-eq
        value.flags
        4
        "comptime expression has a runtime init")
      (test.assert-i64-eq
        converted.flags
        4
        "cast comptime expression has a runtime init")
      (test.assert-i64-eq
        generated.flags
        4
        "generated value has a runtime init")
      (match (& converted.ty)
        [(F64) unit]
        [_ (io.panic "expected an f64 value")])
      (match (& converted.const-value)
        [(None) unit]
        [_ (io.panic "cast comptime initializer has no static payload")]))
    (let
      [emitter (& (array-ref row.macros 0))]
      [macro (& (array-ref row.macros 1))]
      (test.assert-i64-eq
        (cast emitter.result-kind : i64)
        1
        "declaration macro result")
      (test.assert-i64-eq
        (cast macro.result-kind : i64)
        0
        "expression macro result")
      (test.assert-string-eq
        (& macro.identity)
        "fixture/keep"
        "canonical macro identity")
      (test.assert-i64-eq
        macro.tlci-entry-index
        -1
        "source macro has no native entry")
      (test.assert-i64-eq
        (array-length macro.params)
        1
        "macro parameter preserved"))))

(test
  tli-cleanup-symbols-use-defining-module
  (let
    [row : tli.TliModuleRecord
      (extract-fixture-module
        "(module fixture)
(import stdlib.crypto_secret as other)
(import stdlib.io as sink)
(defstruct Wrapped
  (:cleanup other.close-fixed)
  (qualified i64 (:cleanup stdlib.io/set-error-code))
  (slashed i64 (:cleanup sink/set-error-code)))
(defenum Choice
  (:cleanup other.close-bytes-result)
  (Empty)
  (Payload i64 (:cleanup sink/set-error-code)))
")]
    (match (& (array-ref row.types 0).cleanup)
      [(Fn name)
        (test.assert-string-eq
          name
          "fixture/other.close-bytes-result"
          "type-level enum cleanup stays in defining module")]
      [_ (io.panic "expected an enum cleanup")])
    (match (& (array-ref row.types 0).body)
      [(Enum variants)
        (match (& (array-ref (array-ref variants 1).payloads 0).cleanup)
          [(Fn name)
            (test.assert-string-eq
              name
              "stdlib.io/set-error-code"
              "slash-alias enum payload cleanup")]
          [_ (io.panic "expected an enum payload cleanup")])]
      [_ (io.panic "expected an enum body")])
    (match (& (array-ref row.types 1).cleanup)
      [(Fn name)
        (test.assert-string-eq
          name
          "fixture/other.close-fixed"
          "type-level struct cleanup stays in defining module")]
      [_ (io.panic "expected a struct cleanup")])
    (match (& (array-ref row.types 1).body)
      [(Struct fields)
        (match (& (array-ref fields 0).cleanup)
          [(Fn name)
            (test.assert-string-eq
              name
              "stdlib.io/set-error-code"
              "dotted struct field cleanup")]
          [_ (io.panic "expected dotted struct field cleanup")])
        (match (& (array-ref fields 1).cleanup)
          [(Fn name)
            (test.assert-string-eq
              name
              "stdlib.io/set-error-code"
              "slash-alias struct field cleanup")]
          [_ (io.panic "expected slash-alias struct field cleanup")])]
      [_ (io.panic "expected a struct body")])))

(test
  tli-cold-attribute-round-trip
  (let
    [row : tli.TliModuleRecord
      (extract-fixture-module
        "(module fixture)
(define (cold-unit) (:cold) unit)
(define (cold-result) (:export-symbol \"cold_result\") (:cold) : i64 42)
(define (warm-result) : i64 42)
")]
    [facts : hydrate.TliHydratedFacts (hydrate.tli-hydrated-facts-new 1)]
    [decls : ast.AstDeclList (ast.ast-decl-list-new)]
    [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
    [modules : ast.AstDeclModuleList (ast.ast-decl-module-list-new)]
    (test.assert-i64-eq
      (bit-and
        (extract-fixture-fn (& row) "cold-unit").summary.effect-flags
        tli.tli-fn-cold)
      tli.tli-fn-cold
      "a default-unit function retains its marker")
    (test.assert-i64-eq
      (bit-and
        (extract-fixture-fn (& row) "cold-result").summary.effect-flags
        tli.tli-fn-cold)
      tli.tli-fn-cold
      "the marker composes with an export symbol")
    (test.assert-i64-eq
      (bit-and
        (extract-fixture-fn (& row) "warm-result").summary.effect-flags
        tli.tli-fn-cold)
      0
      "an unmarked function stays warm")
    (for [i (iterator.range 0 (array-length row.functions))]
      (let
        [fn (& (array-ref row.functions i))]
        (hydrate.tli-hydrate-project-fn-with-context!
          (&mut facts)
          (&mut decls)
          (&mut paths)
          (&mut modules)
          fn
          false
          "provider"
          "0.1.0"
          (& (tlci.tlci-spmd-callables-empty))
          "provider.tl"
          0
          0
          0
          i)
        (let
          [decl : ast.AstDecl
            (ast.ast-decl-list-get (& decls) i (ast.ast-decl-fallback))]
          (test.assert-true
            (match (& decl)
              [(Extern meta _ (Function) _ _)
                (=
                  (ast.ast-decl-meta-cold? meta)
                  (not (string.eq (& fn.name) "warm-result")))]
              [_ false])
            "an imported extern retains the function's marker"))))))