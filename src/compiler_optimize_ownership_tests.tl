;; Owning-buffer proofs use runtime identities, not equal symbol spellings.
(import compiler_optimize as opt)
(import compiler_ir_text as irt)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.test)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as owned_test_map)

;; Explicit fixture placeholders select canonical runtime operations. A user
;; function spelled tl_alloc stays an ordinary call in the negative cases.
(define (owned-test-runtime-instrs [instrs : ir.CompilerIrInstrSeq]) : ir.CompilerIrInstrSeq
  (let
    [b (ir.compiler-ir-instr-builder-with-capacity instrs.len)]
    (for [i (iterator.range 0 instrs.len)]
      (ir.compiler-ir-instr-builder-push!
        (&mut b)
        (match (ir.compiler-ir-instr-seq-ref instrs i)
          [(Call dst name args ty)
            (Call
              dst
              (cond
                [(string.eq (ir.compiler-ir-symbol-text name) "fixture_alloc")
                  cbi.compiler-builtin-id-tl-alloc]
                [(string.eq (ir.compiler-ir-symbol-text name) "fixture_zero")
                  cbi.compiler-builtin-id-tl-array-zero]
                [else name])
              args
              ty)]
          [_ (ir.compiler-ir-instr-seq-ref instrs i)])))
    (ir.compiler-ir-instr-builder-to-seq b)))

(define (owned-test-function [func : ir.CompilerIrFunction]) : ir.CompilerIrFunction
  (match func
    [(Function name params ret frame blocks abi)
      (Function
        name
        params
        ret
        frame
        (opt.opt-blocks-map-seq blocks owned-test-runtime-instrs)
        abi)]))

(define (owned-test-constructor [buffer : String] [tail : String]) : ir.CompilerIrFunction
  (owned-test-function
    (irt.func
      (str_cat.str-cat
        "function @fresh(n=%0:i64, out=%1:u64, shared=%2:u64) -> u64 vars 16 {
entry:
"
        buffer
        "
  %7 = call fixture_zero(%6, %0) : unit
  %8 = call fixture_alloc(16) : (__tl_dyn-array i64)
  %9 = gep %8, 0 : u8
  store_ptr %9, %6 : u64
  %10 = gep %8, 8 : u8
  store_ptr %10, %0 : i64
"
        tail
        "
}"))))

(define (owned-test-field [buffer : String] [tail : String]) : i64
  (let
    [func (owned-test-constructor buffer tail)]
    (opt.opt-owned-return-field
      (ast.ast-node-pool-reader-type-segment-bases)
      (& func))))

(test
  owned-constructor-fresh-tree
  (cbi.compiler-builtin-initialize-for-parse!)
  (let
    [fresh : String "%6 = call fixture_alloc(%0) : u64"]
    [checked : String
      "%11 = gep %1, 0 : u8
  store_owned %8 -> %11 : (__tl_dyn-array i64)
  %12 = gep %1, 8 : u8
  store_ptr %12, %0 : i64
  return %1"]
    (test.assert-i64-eq
      (owned-test-field (clone fresh) (clone checked))
      0
      "fresh owned result field")
    (test.assert-i64-eq
      (owned-test-field (clone fresh) "return %8")
      -1
      "fresh direct dynamic-length descriptor")
    (test.assert-i64-eq
      (owned-test-field
        (clone fresh)
        "%11 = gep %1, 8 : u8
  store_owned %8 -> %11 : (__tl_dyn-array i64)
  %12 = gep %1, 0 : u8
  store_ptr %12, %0 : i64
  return %1")
      8
      "field layout is structural")
    (test.assert-i64-eq
      (owned-test-field "%6 = mov %2 : u64" (clone checked))
      -2
      "fresh wrapper around shared data is unknown")
    (test.assert-i64-eq
      (owned-test-field
        "branch true, create, other\ncreate:\n  %6 = call fixture_alloc(%0) : u64"
        (str_cat.str-cat (clone checked) "\nother:\n  tailcall unknown() : u64"))
      -2
      "every returning path must establish the fresh tree")
    (test.assert-i64-eq
      (owned-test-field "%6 = call tl_alloc(%0) : u64" (clone checked))
      -2
      "a user spelling does not prove allocation")
    (for [tail
      (array
        "%11 = gep %1, 0 : u8
  store_ptr %11, %8 : (__tl_dyn-array i64)
  return %1"
        "%11 = gep %1, 0 : u8
  store_owned %8 -> %11 : (__tl_dyn-array i64)
  store_owned %8 -> %11 : (__tl_dyn-array i64)
  return %1"
        "%11 = gep %1, 0 : u8
  store_owned %8 -> %11 : (__tl_dyn-array i64)
  store_ptr %11, 0 : i64
  return %1"
        "%11 = gep %1, 0 : u8
  store_owned %8 -> %11 : (__tl_dyn-array i64)
  %12 = gep %1, 8 : u8
  store_ptr %12, %6 : u64
  return %1"
        "%11 = gep %1, 0 : u8
  store_owned %8 -> %11 : (__tl_dyn-array i64)
  %12 = call opaque(%1) : unit
  return %1"
        "%11 = gep %1, 0 : u8
  store_owned %8 -> %11 : (__tl_dyn-array i64)
  %12 = call opaque(%8) : unit
  return %1"
        "%11 = gep %1, 0 : u8
  store_owned %8 -> %11 : (__tl_dyn-array i64)
  %12 = addr_of %1
  return %1"
        "%11 = gep %1, 0 : u8
  store_owned %8 -> %11 : (__tl_dyn-array i64)
  branch true, yes, no
yes:
  return %1
no:
  return %1")]
      (test.assert-i64-eq
        (owned-test-field (clone fresh) tail)
        -2
        "unproven transfer or escape stays unknown"))))

(define (owned-test-transfer [text : String]) : i64
  (let
    [func (owned-test-function (irt.func text))]
    [constructors (owned_test_map.with-capacity 1)]
    [aliases (owned_test_map.with-capacity 1)]
    [factory (ir.compiler-ir-test-symbol "factory")]
    (owned_test_map.insert-ref! (&mut constructors) factory 2)
    (owned_test_map.insert-ref! (&mut aliases) factory 1)
    (let
      [ctx (opt.opt-owned-transfers-new (& constructors) (& aliases) (& func))]
      [at : i64 (- ctx.flat.count 1)]
      (match (opt.opt-aggregate-split-at (& ctx.flat) at)
        [(Return (Some value))
          (opt.opt-owned-transfer-field (& ctx) (& value) at)]
        [_ -99]))))

(define (owned-test-wrapper [middle : String] [tail : String]) : String
  (str_cat.str-cat
    "function @wrapper() -> Pair vars 8 {
entry:
  %0 = alloc Pair
  %1 = addr_of %0
  %2 = call factory([sret arg 0] %1) : Pair
"
    middle
    "
  %3 = call fixture_alloc(16) : Pair
"
    tail
    "
}"))

(test
  owned-fresh-call-transfer
  (cbi.compiler-builtin-initialize-for-parse!)
  (test.assert-i64-eq
    (owned-test-transfer
      (owned-test-wrapper "" "copy_bytes %3, %2, 16
  return %3"))
    0
    "fresh invocation transfers once through a complete wrapper copy")
  (test.assert-i64-eq
    (owned-test-transfer
      (owned-test-wrapper
        "%4 = mov %2 : Pair"
        "copy_bytes %3, %4, 16
  %5 = mov %3 : Pair
  return %5"))
    0
    "same-owner moves preserve the tree")
  (for [tail
    (array
      "copy_bytes %3, %2, 8
  return %3"
      "copy_bytes %3, %2, 24
  return %3"
      "copy_bytes %3, %2, 16
  %4 = mov %2 : Pair
  return %3"
      "copy_bytes %3, %2, 16
  %4 = call escape(%1) : unit
  return %3"
      "copy_bytes %3, %2, 16
  %4 = call escape(%3) : unit
  return %3"
      "copy_bytes %3, %2, 16
  jump exit
exit:
  return %3"
      "copy_bytes %3, %2, 16
  copy_bytes %3, %2, 16
  return %3")]
    (test.assert-i64-eq
      (owned-test-transfer (owned-test-wrapper "" tail))
      -2
      "partial, escaping, duplicated or control-dependent transfer is unknown")))

(define (owned-test-summary-functions) : ir.CompilerIrFunctionSeq
  (cbi.compiler-builtin-initialize-for-parse!)
  (let
    [builder (ir.compiler-ir-function-builder-new)]
    (ir.compiler-ir-function-builder-push!
      (&mut builder)
      (owned-test-constructor
        "%6 = call fixture_alloc(%0) : u64"
        "%11 = gep %1, 0 : u8
  store_owned %8 -> %11 : (__tl_dyn-array i64)
  return %1"))
    ;; Put callers before callees: the summary uses the shared callgraph order.
    (ir.compiler-ir-function-builder-push!
      (&mut builder)
      (irt.func
        "function @forward() -> Pair vars 1 {
entry:
  %0 = call wrapped() : Pair
  return %0
}"))
    (ir.compiler-ir-function-builder-push!
      (&mut builder)
      (owned-test-function
        (irt.func
          "function @wrapped() -> Pair vars 4 {
entry:
  %0 = alloc Pair
  %1 = addr_of %0
  %2 = call fresh([sret arg 1] 16, %1, 0) : Pair
  %3 = call fixture_alloc(16) : Pair
  copy_bytes %3, %2, 16
  return %3
}")))
    (ir.compiler-ir-function-builder-to-seq builder)))

(test
  owned-constructor-callgraph
  (let
    [functions (owned-test-summary-functions)]
    [index (opt.opt-program-index-build (& functions))]
    [aliases (opt.opt-licm-return-alias-map (& functions) 4)]
    [rows
      (opt.opt-owned-constructors-build
        (ast.ast-node-pool-reader-type-segment-bases)
        (& index)
        (& aliases))]
    (test.assert-i64-eq
      (owned_test_map.get-value-or
        (& rows)
        (ir.compiler-ir-test-symbol "fresh")
        0)
      2
      "fresh field written into returned argument")
    (for [name (array "wrapped" "forward")]
      (test.assert-i64-eq
        (owned_test_map.get-value-or
          (& rows)
          (ir.compiler-ir-test-symbol name)
          0)
        -2
        "owned heap result remains fresh through an internal helper"))))

(test
  owned-paths-separate-storage-objects
  (let
    [env
      (opt.opt-licm-root-env-with-capacity 8 (owned_test_map.with-capacity 1))]
    [globals
      (opt.OptOwnedGlobals
        (owned_test_map.with-capacity 4)
        (__tl_make-array i64 3))]
    [instrs
      (irt.instrs
        "%0 = gep @left, 0 : u8
  %1 = load %0 : (__tl_dyn-array i64)
  %2 = gep %1, 0 : i64
  %3 = load %2 : u64
  %4 = gep %3, %20 : i64
  %5 = load %4 : i64
  %6 = gep @right, 1 : i64
  %7 = load %6 : (__tl_dyn-array i64)
  %8 = gep %7, 1 : i64
  %9 = load %8 : i64
  %10 = gep %7, 0 : u8
  %11 = load %10 : u64
  %12 = mov %11 : u64
  %13 = cast %12 : u64 to u64
  %14 = load %6 : u64
  %15 = gep @direct, 0 : i64
  %16 = load %15 : u64")]
    (set! (array-ref globals.fields 0) 2)
    (set! (array-ref globals.fields 1) 10)
    (set! (array-ref globals.fields 2) 1)
    (owned_test_map.insert-ref!
      (&mut globals.index)
      (ir.compiler-ir-test-symbol "left")
      0)
    (owned_test_map.insert-ref!
      (&mut globals.index)
      (ir.compiler-ir-test-symbol "right")
      1)
    (owned_test_map.insert-ref!
      (&mut globals.index)
      (ir.compiler-ir-test-symbol "direct")
      2)
    (set! env.owned-globals globals)
    (for [index (iterator.range 0 instrs.len)]
      (opt.opt-owned-path-update!
        (ast.ast-node-pool-reader-type-segment-bases)
        (&mut env)
        (ir.compiler-ir-instr-seq-borrow instrs index)))
    (for [var (iterator.range 0 17)]
      (let
        [expected : (Array i64 17) (array 1 2 2 3 3 0 4 5 5 0 5 6 6 0 0 8 9)]
        (test.assert-i64-eq
          (opt.opt-owned-path-of (& env) (& (ir.CompilerIrValue.Var var)))
          (array-ref expected var)
          "cell, descriptor and buffer have distinct path stages")))
    (test.assert-true
      (match (opt.opt-licm-root-env-offset
        (& env)
        (& (ir.CompilerIrValue.Var 7)))
        [(LookupFound n) (= n 0)]
        [_ false])
      "loading a descriptor resets the enclosing field coordinate")
    (test.assert-true
      (match (opt.opt-licm-root-env-offset
        (& env)
        (& (ir.CompilerIrValue.Var 4)))
        [(LookupMissing) true]
        [_ false])
      "a dynamic element index has no fixed byte coordinate")))

(define (owned-test-global-proof [body : String]) : opt.OptOwnedGlobals
  (match (irt.program
    (str_cat.str-cat
      "global @left : Pair = runtime-init@wrapped
global @right : Pair = runtime-init@wrapped
function @uses() -> i64 vars 16 {
entry:
  %0 = gep @left, 0 : u8
  %1 = load %0 : (__tl_dyn-array i64)
  %2 = gep %1, 0 : u8
  %3 = load %2 : u64
  %4 = gep %3, 0 : i64
  %5 = gep @right, 0 : u8
  %6 = load %5 : (__tl_dyn-array i64)
  %7 = gep %6, 0 : u8
  %8 = load %7 : u64
  %9 = gep %8, 0 : i64
"
      body
      "
  return 0
}"))
    [(Program globals functions _)
      (let
        [builder (ir.compiler-ir-function-builder-from-seq functions)]
        (ir.compiler-ir-function-builder-append-seq!
          (&mut builder)
          (& (owned-test-summary-functions)))
        (let
          [all (ir.compiler-ir-function-builder-to-seq builder)]
          [facts (opt.opt-program-facts-build (& all))]
          [aliases (opt.opt-licm-return-alias-map (& all) 8)]
          (opt.opt-owned-globals-build
            (ast.ast-node-pool-reader-type-segment-bases)
            (& globals)
            (& (ir.compiler-ir-extern-seq-empty))
            (& all)
            (& facts)
            (& aliases))))]))

(test
  owned-global-initializers-and-replacements
  (for [body
    (array
      "store_ptr %9, 3 : i64
  %10 = load %4 : i64"
      "%10 = call wrapped() : Pair
  store @left, %10 : Pair")]
    (let
      [proof (owned-test-global-proof body)]
      (test.assert-i64-eq
        (owned_test_map.len (& proof.index))
        2
        "separate invocations produce independent owners, including replacement")
      (test.assert-true
        (not
          (=
            (owned_test_map.get-value-or
              (& proof.index)
              (ir.compiler-ir-test-symbol "left")
              -1)
            (owned_test_map.get-value-or
              (& proof.index)
              (ir.compiler-ir-test-symbol "right")
              -1)))
        "one initializer function does not mean one allocation identity")))
  (for [body
    (array
      "%10 = load %0 : u64"
      "%10 = addr_of %1"
      "%10 = mov &@left : u64"
      "store_ptr %2, 0 : u64"
      "store_ptr %0, %1 : (__tl_dyn-array i64)"
      "store_owned %1 -> %0 : (__tl_dyn-array i64)")]
    (let
      [proof (owned-test-global-proof body)]
      (test.assert-true
        (not
          (owned_test_map.contains?
            (& proof.index)
            (ir.compiler-ir-test-symbol "left")))
        "raw load, escape and exposed descriptor slot reject ownership")
      (test.assert-true
        (owned_test_map.contains?
          (& proof.index)
          (ir.compiler-ir-test-symbol "right"))
        "an unrelated proof remains available")))
  (for [body
    (array
      "%10 = call opaque(%1) : unit"
      "%10 = call foreign() : unit"
      "%10 = call unknown() : Pair
  store @left, %10 : Pair"
      "store @right, @left : Pair"
      "store_ptr %0, %6 : (__tl_dyn-array i64)"
      "branch true, yes, no
yes:
  jump join
no:
  jump join
join:
  %10 = phi [%1, yes], [%6, no] : (__tl_dyn-array i64)")]
    (let
      [proof (owned-test-global-proof body)]
      (test.assert-i64-eq
        (owned_test_map.len (& proof.index))
        0
        "shallow aliases and unknown foreign writers cannot leave independent owners"))))

(test
  owned-global-external-data-boundary
  (let
    [name (ir.compiler-ir-test-symbol "foreign")]
    (for [index (iterator.range 0 3)]
      (let
        [externs (ir.compiler-ir-extern-builder-with-capacity 1)]
        [ty : ast.AstType
          (cond
            [(= index 0) (I64)]
            [(= index 1) (Struct (ir.compiler-ir-test-symbol "Pair"))]
            [else (ast.ast-ty-func (ast.ast-type-list-new) (& (I64)))])]
        (ir.compiler-ir-extern-builder-push!
          (&mut externs)
          (ir.CompilerIrExtern.Extern
            name
            name
            "foreign"
            ty
            (ast.AstExternAbi.C)
            name
            (ast.ast-extern-link-input-list-new)
            false))
        (test.assert-true
          (=
            (opt.opt-owned-external-data?
              (& (ir.compiler-ir-extern-builder-snapshot-seq (& externs))))
            (< index 2))
          "external data can expose global storage through an alternative link identity")))))

(test
  owned-global-proof-job-isolation
  (let
    [first (owned-test-global-proof "store_ptr %9, 3 : i64")]
    [generation (ast.ty-node-pool-generation-value)]
    (ast.ty-node-pool-reset!)
    (test.assert-true
      (> (ast.ty-node-pool-generation-value) generation)
      "the next job uses a new pooled type generation")
    (let
      [second (owned-test-global-proof "store @right, @left : Pair")]
      [third (owned-test-global-proof "store_ptr %9, 3 : i64")]
      (test.assert-i64-eq
        (owned_test_map.len (& first.index))
        2
        "retained proof owns its maps beyond the analysis scratch lifetime")
      (test.assert-i64-eq
        (owned_test_map.len (& second.index))
        0
        "same symbol IDs in a new job cannot reuse a previous positive proof")
      (test.assert-i64-eq
        (owned_test_map.len (& third.index))
        2
        "an intervening rejected job cannot poison the following proof"))))

(define (owned-test-licm-input) : String
  "global @left : Pair = runtime-init@wrapped
global @right : Pair = runtime-init@wrapped
function @work(index=%0:i64, count=%1:i64) -> i64 vars 24 {
entry:
  %2 = gep @left, 0 : u8
  %3 = load %2 : (__tl_dyn-array i64)
  %4 = gep %3, 8 : u8
  %5 = load %4 : i64
  %6 = gep %3, 0 : u8
  %7 = load %6 : u64
  %8 = gep %7, %0 : i64
  %9 = gep @right, 0 : u8
  %10 = load %9 : (__tl_dyn-array i64)
  %11 = gep %10, 0 : u8
  %12 = load %11 : u64
  %13 = gep %12, 0 : i64
  %21 = gep %10, 8 : u8
  %22 = load %21 : i64
  bounds_check %0, %5 message \"read\"
  jump header
header:
  %14 = phi [0, entry], [%18, body] : i64
  %19 = phi [0, entry], [%17, body] : i64
  %15 = lt %14, %1 : bool
  branch %15, body, exit
body:
  %16 = load %8 : i64
  store_ptr %13, %14 : i64
  %17 = add %19, %16 : i64
  %18 = add %14, 1 : i64
  jump header
exit:
  return %19
}")

(define (owned-test-licm [text : String] [with-proof? : bool]) : ir.CompilerIrFunction
  (match (irt.program text)
    [(Program globals functions _)
      (let
        [func (ir.compiler-ir-function-seq-ref functions 0)]
        [builder (ir.compiler-ir-function-builder-from-seq functions)]
        (ir.compiler-ir-function-builder-append-seq!
          (&mut builder)
          (& (owned-test-summary-functions)))
        (let
          [all (ir.compiler-ir-function-builder-to-seq builder)]
          [facts (opt.opt-program-facts-build (& all))]
          [aliases (opt.opt-licm-return-alias-map (& all) 8)]
          [cells (opt.opt-global-cell-summary-empty)]
          (when
            with-proof?
            (set!
              cells.owned-globals
              (opt.opt-owned-globals-build
                (ast.ast-node-pool-reader-type-segment-bases)
                (& globals)
                (& (ir.compiler-ir-extern-seq-empty))
                (& all)
                (& facts)
                (& aliases))))
          (test.assert-true
            (opt.opt-verify-ok? (& (opt.opt-verify-function (& func))))
            "ownership LICM input is valid SSA")
          (opt.opt-licm-function-with-global-cells
            (ast.ast-node-pool-reader-type-segment-bases)
            (& cells)
            true
            (& func))))]))

(define (owned-test-load-in-body? [func : (& ir.CompilerIrFunction)]) : bool
  (let
    [blocks (opt.opt-function-blocks func)]
    (match (opt.opt-cfg-find-block blocks (ir.compiler-ir-label "body"))
      [(Some (Block _ instrs))
        (for [index (iterator.range 0 instrs.len)]
          (match (ir.compiler-ir-instr-seq-borrow instrs index)
            [(Load 16 _ _) (return true)]
            [_ unit]))
        false]
      [_ false])))

(test
  owned-global-ordinary-licm
  (let
    [text (owned-test-licm-input)]
    [positive (owned-test-licm (clone text) true)]
    [without-proof (owned-test-licm (clone text) false)]
    (test.assert-true
      (opt.opt-verify-ok? (& (opt.opt-verify-function (& positive))))
      "hoisted owned-buffer read remains valid SSA")
    (test.assert-true
      (not (owned-test-load-in-body? (& positive)))
      "entry-bounded read moves across a different proven global buffer store")
    (test.assert-true
      (owned-test-load-in-body? (& without-proof))
      "the same loop without the ownership proof keeps its read")
    (for [negative
      (array
        (string.replace (clone text) "store_ptr %13" "store_ptr %8")
        (string.replace
          (clone text)
          "store_ptr %13, %14 : i64"
          "%23 = call opaque() : unit")
        (string.replace
          (clone text)
          "store_ptr %13, %14 : i64"
          "%23 = call wrapped() : Pair\n  store @left, %23 : Pair")
        (string.replace
          (clone text)
          "bounds_check %0, %5"
          "bounds_check %0, %22")
        (string.replace (clone text) "bounds_check %0, %5 message \"read\"" "")
        (string.replace
          (string.replace
            (clone text)
            "bounds_check %0, %5 message \"read\""
            "")
          "%16 = load %8 : i64"
          "%16 = load %8 : i64\n  bounds_check %0, %5 message \"late\""))]
      (test.assert-true
        (owned-test-load-in-body? (& (owned-test-licm negative true)))
        "same owner, unknown call, replacement or absent entry bound prevents motion"))))