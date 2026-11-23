(import compiler_tli_extract as extract)
(import compiler_tli_codec as codec)
(import compiler_tli_types as tli)
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
(defstruct Handle (:must-use) (:opaque) (:cleanup close-handle)
  (code i8) (fd i64 (:cleanup close-fd)))
(define (close-fd [fd : i64]) : unit unit)
(defenum Event (Empty) (Ready i64))
(defstruct Raw (:repr c) (code i8) (fd i32 (:align 8)))
(defstruct Borrowed (:lifetimes r) (fd (& r i64)))
(define (borrow [value : (& r i64)]) : (Borrowed r) (Borrowed value))
(define value : i64 (comptime (+ 20 22)))
(define g : String \"\")
(define (stash) : unit (set! g (string.append \"a\" \"b\")))
(define (relay) : unit (stash))
(define (scoped [f : (-> unit)]) : unit (with-arena phase (f)))
(define (startup) : i64 3)
(define first : i64 (startup))
(define second : i64 (startup))
(define (stop) : never (io.panic \"stop\"))
(unsafe (define (unsafe-id [x : i64]) : i64 x))
(defdispatch dispatch (scalar startup))
(extern (foreign [fixed : i64] [tail : ...i64]) : i64 (:symbol \"external_name\"))
(defmacro (keep [value : Expr]) : Expr value)
")

(define (extract-fixture-module) : tli.TliModuleRecord
  (api.compiler-typecheck-reset-load-session!)
  (let
    [source : String (extract-fixture)]
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
            0
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

(define (extract-fixture-fn
  [row : (& row tli.TliModuleRecord)]
  [name : (& str)]) : (& row tli.TliFnDecl)
  (for [index (iterator.range 0 (array-length row.functions))]
    (when
      (string.eq (& (array-ref row.functions index).name) name)
      (return (& (array-ref row.functions index)))))
  (io.panic name))

(test
  tli-checked-program-roundtrip
  (let
    [row : tli.TliModuleRecord (extract-fixture-module)]
    (test.assert-string-eq (& row.name) "fixture" "module owner")
    (test.assert-i64-eq (array-length row.imports) 2 "both import edges")
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
          (let
            [fd (& (array-ref fields 1))]
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
    (test.assert-i64-eq
      (array-length row.global-inits)
      2
      "two runtime global inits")
    (test.assert-string-eq
      (& (array-ref row.global-inits 0))
      "__global_init_fixture/first"
      "first startup symbol")
    (test.assert-string-eq
      (& (array-ref row.global-inits 1))
      "__global_init_fixture/second"
      "second startup symbol")
    (match (& (array-ref row.values 3).const-value)
      [(I64 n) (test.assert-i64-eq n 42 "comptime result payload")]
      [_ (io.panic "expected an integer constant")])
    (let
      [macro (& (array-ref row.macros 0))]
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