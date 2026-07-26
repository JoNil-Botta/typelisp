;; compiler_optimize_tests.tl - Selfhost optimizer fixtures split from production.
(import "compiler_optimize.tl")
(import stdlib.io)
(import stdlib.array)
(import stdlib.arena)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as opt_i64_i64_map)
(import stdlib.option)
(import (option.option i64) as option_i64)
(import stdlib.vector)
(import (vector.vector OptAggregatePointer core) as opt_aggregate_pointer_vec)
(import (vector.vector OptAggregateAccess core) as opt_aggregate_access_vec)
(import (vector.vector OptAggregateAllocCandidate core) as opt_aggregate_candidate_vec)
(import (vector.vector OptAggregatePromoteSlot core) as opt_aggregate_promote_slot_vec)
(import compiler_builtin_ids as cbi)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

;; --- self-test ---------------------------------------------------------------
(define (opt-count-arith-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+ (opt-arith-instr-count instr) (opt-count-arith-instrs (box-get rest)))]))

(define (opt-arith-instr-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.BinOp _ _ _ _ _) 1]
    [(CompilerIrInstr.UnOp _ _ _ _) 1]
    [_ 0]))

(define (opt-count-arith-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-arith-instr-seq-from
      slots
      (+ index 1)
      count
      (+ acc (opt-arith-instr-count (array-ref slots index))))))

(define (opt-count-arith-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-arith-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-cpuid-instr-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.CpuId _ _ _ _) 1]
    [_ 0]))

(define (opt-xgetbv-instr-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Xgetbv _ _) 1]
    [_ 0]))

(define (opt-count-cpuid-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+ (opt-cpuid-instr-count instr) (opt-count-cpuid-instrs (box-get rest)))]))

(define (opt-count-xgetbv-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (opt-xgetbv-instr-count instr)
        (opt-count-xgetbv-instrs (box-get rest)))]))

(define (opt-count-cpuid-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-cpuid-instr-seq-from
      slots
      (+ index 1)
      count
      (+ acc (opt-cpuid-instr-count (array-ref slots index))))))

(define (opt-count-cpuid-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-cpuid-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-xgetbv-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-xgetbv-instr-seq-from
      slots
      (+ index 1)
      count
      (+ acc (opt-xgetbv-instr-count (array-ref slots index))))))

(define (opt-count-xgetbv-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-xgetbv-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-cpuid-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-cpuid-instr-seq instrs)
            (opt-count-cpuid-blocks (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-cpuid-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-count-xgetbv-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-xgetbv-instr-seq instrs)
            (opt-count-xgetbv-blocks (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-xgetbv-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-count-exact-instr-seq-from
  [instrs : CompilerIrInstrSeq]
  [needle : CompilerIrInstr]
  [index : i64]
  [acc : i64]) : i64
  (if (>= index (compiler-ir-instr-seq-count instrs))
    acc
    (opt-count-exact-instr-seq-from
      instrs
      needle
      (+ index 1)
      (if (opt-instr-eq (compiler-ir-instr-seq-ref instrs index) needle)
        (+ acc 1)
        acc))))

(define (opt-count-exact-instr-seq
  [instrs : CompilerIrInstrSeq]
  [needle : CompilerIrInstr]) : i64
  (opt-count-exact-instr-seq-from instrs needle 0 0))

(define (opt-count-exact-instr-blocks
  [blocks : CompilerIrBlockList]
  [needle : CompilerIrInstr]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-exact-instr-seq instrs needle)
            (opt-count-exact-instr-blocks (box-get rest) needle))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-exact-instr-blocks (compiler-ir-block-seq-to-list seq) needle)]))

(define (opt-count-exact-instr-functions
  [functions : CompilerIrFunctionList]
  [needle : CompilerIrInstr]) : i64
  (match functions
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function _ _ _ _ blocks)
          (+
            (opt-count-exact-instr-blocks blocks needle)
            (opt-count-exact-instr-functions (box-get rest) needle))])]
    [(CompilerIrFunctionList.Array seq)
      (opt-count-exact-instr-functions
        (compiler-ir-function-seq-to-list seq)
        needle)]))

(define (opt-count-exact-instr-program
  [program : CompilerIrProgram]
  [needle : CompilerIrInstr]) : i64
  (match program
    [(CompilerIrProgram.Program _ functions _)
      (opt-count-exact-instr-functions functions needle)]))

(define (opt-sum-mov-i64 [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+ (opt-mov-i64-value instr) (opt-sum-mov-i64 (box-get rest)))]))

(define (opt-mov-i64-value [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Mov _ (CompilerIrValue.I64 n) _) n]
    [_ 0]))

(define (opt-count-mov-i64-value [instrs : CompilerIrInstrList] [needle : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.Mov _ (CompilerIrValue.I64 n) _)
            (if (= n needle)
              1
              0)]
          [_ 0])
        (opt-count-mov-i64-value (box-get rest) needle))]))

(define (opt-count-mov-i64-value-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [needle : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-mov-i64-value-instr-seq-from
      slots
      (+ index 1)
      count
      needle
      (+
        acc
        (match (array-ref slots index)
          [(CompilerIrInstr.Mov _ (CompilerIrValue.I64 n) _)
            (if (= n needle)
              1
              0)]
          [_ 0])))))

(define (opt-count-mov-i64-value-instr-seq
  [instrs : CompilerIrInstrSeq]
  [needle : i64]) : i64
  (opt-count-mov-i64-value-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    needle
    0))

(define (opt-count-mov-bool-value
  [instrs : CompilerIrInstrList]
  [needle : bool]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.Mov _ (CompilerIrValue.Bool b) _)
            (if needle
              (if b
                1
                0)
              (if b
                0
                1))]
          [_ 0])
        (opt-count-mov-bool-value (box-get rest) needle))]))

(define (opt-sum-mov-var-src [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.Mov _ (CompilerIrValue.Var id) _) id]
          [_ 0])
        (opt-sum-mov-var-src (box-get rest)))]))

(define (opt-mov-dst-type-tag [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.Mov d _ ty)
          (if (= d dst)
            (ast-type-tag ty)
            (opt-mov-dst-type-tag (box-get rest) dst))]
        [_ (opt-mov-dst-type-tag (box-get rest) dst)])]))

(define (opt-mov-dst-i64-value
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [fallback : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) fallback]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.Mov d (CompilerIrValue.I64 n) _)
          (if (= d dst)
            n
            (opt-mov-dst-i64-value (box-get rest) dst fallback))]
        [_ (opt-mov-dst-i64-value (box-get rest) dst fallback)])]))

(define (opt-mov-dst-i64-value-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [dst : i64]
  [fallback : i64]) : i64
  (if (>= index count)
    fallback
    (match (array-ref slots index)
      [(CompilerIrInstr.Mov d (CompilerIrValue.I64 n) _)
        (if (= d dst)
          n
          (opt-mov-dst-i64-value-instr-seq-from
            slots
            (+ index 1)
            count
            dst
            fallback))]
      [_
        (opt-mov-dst-i64-value-instr-seq-from
          slots
          (+ index 1)
          count
          dst
          fallback)])))

(define (opt-mov-dst-i64-value-instr-seq
  [instrs : CompilerIrInstrSeq]
  [dst : i64]
  [fallback : i64]) : i64
  (opt-mov-dst-i64-value-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    dst
    fallback))

(define (opt-mov-dst-bool-value?
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [needle : bool]) : bool
  (match instrs
    [(CompilerIrInstrList.Nil) false]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.Mov d (CompilerIrValue.Bool b) _)
          (if (= d dst)
            (if needle
              b
              (not b))
            (opt-mov-dst-bool-value? (box-get rest) dst needle))]
        [_ (opt-mov-dst-bool-value? (box-get rest) dst needle)])]))

(define (opt-mov-dst-char-code
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [fallback : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) fallback]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.Mov d (CompilerIrValue.Char c) _)
          (if (= d dst)
            (cast c : i64)
            (opt-mov-dst-char-code (box-get rest) dst fallback))]
        [_ (opt-mov-dst-char-code (box-get rest) dst fallback)])]))

(define (opt-test-f64-bits [text : String]) : u64
  (match (compiler-float-parse-f64-bits text)
    [(CompilerFloatSomeBits bits) bits]
    [(CompilerFloatNoBits) (cast 0 : u64)]))

(define (opt-test-f32-bits [text : String]) : u64
  (match (compiler-float-parse-f32-bits text)
    [(CompilerFloatSomeBits bits) bits]
    [(CompilerFloatNoBits) (cast 0 : u64)]))

(define (opt-mov-dst-f64-bits?
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [want : u64]) : bool
  (match instrs
    [(CompilerIrInstrList.Nil) false]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.Mov d (CompilerIrValue.F64 bits) _)
          (if (= d dst)
            (= bits want)
            (opt-mov-dst-f64-bits? (box-get rest) dst want))]
        [_ (opt-mov-dst-f64-bits? (box-get rest) dst want)])]))

(define (opt-test-span [line : i64] [col : i64]) : AstSourceSpan
  (ast-source-span line col line col))

(define (opt-source-span-line-col-ok?
  [span : AstSourceSpan]
  [line : i64]
  [col : i64]) : bool
  (and
    (= (ast-source-span-start-line span) line)
    (= (ast-source-span-start-col span) col)))

(define (opt-span-lookup-ok?
  [spans : CompilerSourceSpans]
  [function : i64]
  [instr : CompilerIrInstr]
  [line : i64]
  [col : i64]) : bool
  (match (compiler-source-spans-lookup-instr spans function instr)
    [(CompilerMaybeSourceSpan.Some span)
      (opt-source-span-line-col-ok? span line col)]
    [(CompilerMaybeSourceSpan.No) false]))

(define (opt-span-lookup-missing?
  [spans : CompilerSourceSpans]
  [function : i64]
  [instr : CompilerIrInstr]) : bool
  (match (compiler-source-spans-lookup-instr spans function instr)
    [(CompilerMaybeSourceSpan.Some _) false]
    [(CompilerMaybeSourceSpan.No) true]))

(define (opt-test-symbol [name : String]) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (compiler-ir-test-symbol name)))

(define (compiler-optimize-runtime-call-identity-self-test) : i64
  (let
    [generated-alloc : i64 (opt-test-symbol "tl_alloc")]
    [generated-abort : i64 (opt-test-symbol ".L_tl_abort")]
    [generated-arena : i64 (opt-test-symbol "arena-current")]
    [runtime-alloc : CompilerIrInstr
      (CompilerIrInstr.Call
        91
        cbi.compiler-builtin-id-tl-alloc
        (CompilerIrCallArgs.One (CompilerIrValue.I64 16))
        (AstType.Struct (intern "RuntimePair")))]
    [hygienic-alloc : CompilerIrInstr
      (CompilerIrInstr.Call
        92
        generated-alloc
        (CompilerIrCallArgs.One (CompilerIrValue.I64 16))
        (AstType.Struct (intern "HygienicPair")))]
    [runtime-abort : CompilerIrInstr
      (CompilerIrInstr.Call
        93
        cbi.compiler-builtin-id-tl-abort-label
        (CompilerIrCallArgs.Nil)
        (AstType.Unit))]
    [hygienic-abort : CompilerIrInstr
      (CompilerIrInstr.Call
        94
        generated-abort
        (CompilerIrCallArgs.Nil)
        (AstType.Unit))]
    [runtime-facts : OptAliasFacts
      (opt-alias-update-value-facts (opt-alias-empty) runtime-alloc 0)]
    [hygienic-facts : OptAliasFacts
      (opt-alias-update-value-facts (opt-alias-empty) hygienic-alloc 0)]
    (cond
      [(= generated-alloc cbi.compiler-builtin-id-tl-alloc) 1]
      [(not
          (string.eq
            (compiler-ir-symbol-text generated-alloc)
            (compiler-ir-symbol-text cbi.compiler-builtin-id-tl-alloc)))
        2]
      [(not
          (compiler-ir-symbol-eq?
            cbi.compiler-builtin-id-tl-alloc
            cbi.compiler-builtin-id-tl-alloc))
        15]
      [(compiler-ir-symbol-eq? generated-alloc cbi.compiler-builtin-id-tl-alloc)
        16]
      [(not
          (compiler-ir-effect-eq?
            (compiler-ir-instr-effect runtime-alloc)
            CompilerIrEffect.MemoryWrite))
        3]
      [(not
          (compiler-ir-effect-eq?
            (compiler-ir-instr-effect hygienic-alloc)
            CompilerIrEffect.Unknown))
        4]
      [(match (opt-aggregate-direct-alloc runtime-alloc)
          [(OptMaybeAggregateAlloc.Some _ _ _) false]
          [(OptMaybeAggregateAlloc.No) true])
        5]
      [(match (opt-aggregate-direct-alloc hygienic-alloc)
          [(OptMaybeAggregateAlloc.No) false]
          [(OptMaybeAggregateAlloc.Some _ _ _) true])
        6]
      [(match (opt-scratch-direct-alloc runtime-alloc)
          [(OptScratchAlloc.Alloc _ _) false]
          [(OptScratchAlloc.NoAlloc) true])
        7]
      [(match (opt-scratch-direct-alloc hygienic-alloc)
          [(OptScratchAlloc.NoAlloc) false]
          [(OptScratchAlloc.Alloc _ _) true])
        8]
      [(match (opt-alias-lookup runtime-facts 91)
          [(OptMaybeAliasKind.Some kind)
            (not (opt-alias-kind-eq kind (OptAliasKind.Unique 0)))]
          [(OptMaybeAliasKind.No) true])
        9]
      [(match (opt-alias-lookup hygienic-facts 92)
          [(OptMaybeAliasKind.No) false]
          [(OptMaybeAliasKind.Some _) true])
        10]
      [(not (opt-licm-return-staging-instr? runtime-abort)) 11]
      [(opt-licm-return-staging-instr? hygienic-abort) 12]
      [(not
          (opt-scratch-arena-helper-call? cbi.compiler-builtin-id-arena-current))
        13]
      [(opt-scratch-arena-helper-call? generated-arena) 14]
      [else 42])))

(define (opt-spans-function-with-frame
  [instrs : CompilerIrInstrList]
  [frame : i64]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "main")
    CompilerIrParamList.Nil
    (AstType.I64)
    frame
    (compiler-ir-block-cons
      (compiler-ir-block (compiler-ir-label "entry") instrs)
      CompilerIrBlockList.Nil)))

(define (opt-spans-function [instrs : CompilerIrInstrList]) : CompilerIrFunction
  (opt-spans-function-with-frame instrs 4))

(define (opt-spans-program-with-frame
  [instrs : CompilerIrInstrList]
  [frame : i64]) : CompilerIrProgram
  (CompilerIrProgram.Program
    CompilerIrGlobalList.Nil
    (compiler-ir-function-cons
      (opt-spans-function-with-frame instrs frame)
      CompilerIrFunctionList.Nil)
    CompilerIrExternList.Nil))

(define (opt-spans-program [instrs : CompilerIrInstrList]) : CompilerIrProgram
  (opt-spans-program-with-frame instrs 4))

(define (opt-spans-base) : CompilerSourceSpans
  (compiler-source-spans-insert
    (compiler-source-spans-empty)
    (compiler-ir-symbol-typed-id (opt-test-symbol "main"))
    (opt-test-span 3 1)))

(define (compiler-optimize-spans-dce-ok?) : bool
  (let
    [dead : CompilerIrInstr
      (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 1) (AstType.I64))]
    [live : CompilerIrInstr
      (CompilerIrInstr.Call
        1
        (opt-test-symbol "opaque")
        (CompilerIrCallArgs.Nil)
        (AstType.I64))]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        dead
        (compiler-ir-instr-cons
          live
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
            CompilerIrInstrList.Nil)))]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert-instr
          (opt-spans-base)
          (opt-test-symbol "main")
          dead
          (opt-test-span 21 3))
        (opt-test-symbol "main")
        live
        (opt-test-span 31 5))]
    (match (optimize-program-with-spans-and-level
      (opt-spans-program instrs)
      spans
      1)
      [(CompilerOptimizedProgram.Program _ optimized-spans)
        (and
          (= (compiler-source-spans-instr-count optimized-spans) 1)
          (opt-span-lookup-missing?
            optimized-spans
            (opt-test-symbol "main")
            dead)
          (opt-span-lookup-ok?
            optimized-spans
            (opt-test-symbol "main")
            live
            31
            5))])))

(define (compiler-optimize-spans-fold-ok?) : bool
  (let
    [folded : CompilerIrInstr
      (CompilerIrInstr.BinOp
        2
        (CompilerIrBinOp.Add)
        (CompilerIrValue.I64 20)
        (CompilerIrValue.I64 22)
        (AstType.I64))]
    [rewritten : CompilerIrInstr
      (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 42) (AstType.I64))]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        folded
        (compiler-ir-instr-cons
          (CompilerIrInstr.AddrOf 3 2)
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
            CompilerIrInstrList.Nil)))]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (opt-spans-base)
        (opt-test-symbol "main")
        folded
        (opt-test-span 41 7))]
    (match (optimize-program-with-spans-and-level
      (opt-spans-program instrs)
      spans
      2)
      [(CompilerOptimizedProgram.Program _ optimized-spans)
        (opt-span-lookup-ok?
          optimized-spans
          (opt-test-symbol "main")
          rewritten
          41
          7)])))

(define (compiler-optimize-spans-cse-ok?) : bool
  (let
    [first : CompilerIrInstr
      (CompilerIrInstr.BinOp
        2
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 1)
        (AstType.I64))]
    [second : CompilerIrInstr
      (CompilerIrInstr.BinOp
        3
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 1)
        (AstType.I64))]
    [rewritten : CompilerIrInstr
      (CompilerIrInstr.Mov 3 (CompilerIrValue.Var 2) (AstType.I64))]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        first
        (compiler-ir-instr-cons
          second
          (compiler-ir-instr-cons
            (CompilerIrInstr.AddrOf 4 3)
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
              CompilerIrInstrList.Nil))))]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert-instr
          (opt-spans-base)
          (opt-test-symbol "main")
          first
          (opt-test-span 51 9))
        (opt-test-symbol "main")
        second
        (opt-test-span 61 11))]
    (match (optimize-program-with-spans-and-level
      (opt-spans-program-with-frame instrs 5)
      spans
      2)
      [(CompilerOptimizedProgram.Program optimized optimized-spans)
        (and
          (opt-span-lookup-ok?
            optimized-spans
            (opt-test-symbol "main")
            first
            51
            9)
          (opt-span-lookup-ok?
            optimized-spans
            (opt-test-symbol "main")
            rewritten
            61
            11)
          (= (opt-count-exact-instr-program optimized rewritten) 1)
          (=
            (opt-count-exact-instr-program
              optimized
              (CompilerIrInstr.AddrOf 4 3))
            1)
          (=
            (opt-count-exact-instr-program
              optimized
              (CompilerIrInstr.AddrOf 4 2))
            0))])))

(define (compiler-optimize-dead-addrof-ok?) : bool
  (let
    [producer : CompilerIrInstr
      (CompilerIrInstr.BinOp
        2
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 1)
        (AstType.I64))]
    [addr : CompilerIrInstr (CompilerIrInstr.AddrOf 3 2)]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        producer
        (compiler-ir-instr-cons
          addr
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 42)))
            CompilerIrInstrList.Nil)))]
    (match (optimize-program-with-spans-and-level
      (opt-spans-program instrs)
      (opt-spans-base)
      1)
      [(CompilerOptimizedProgram.Program optimized _)
        (and
          (= (opt-count-exact-instr-program optimized producer) 0)
          (= (opt-count-exact-instr-program optimized addr) 0))])))

(defstruct OptInlineSpanTestSymbols
  (main i64)
  (inline-span i64)
  (opaque i64))

(define (opt-inline-span-test-symbols) : OptInlineSpanTestSymbols
  (OptInlineSpanTestSymbols
    (opt-test-symbol "main")
    (opt-test-symbol "inline_span")
    (opt-test-symbol "opaque")))

(define (opt-inline-span-callee-call [symbols : OptInlineSpanTestSymbols]) : CompilerIrInstr
  (CompilerIrInstr.Call
    1
    (struct-get symbols opaque)
    (CompilerIrCallArgs.One (CompilerIrValue.Var 0))
    (AstType.I64)))

(define (opt-inline-span-callee [symbols : OptInlineSpanTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols inline-span)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "value" (AstType.I64) 0)
      CompilerIrParamList.Nil)
    (AstType.I64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (opt-inline-span-callee-call symbols)
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-span-caller-call [symbols : OptInlineSpanTestSymbols]) : CompilerIrInstr
  (CompilerIrInstr.Call
    0
    (struct-get symbols inline-span)
    (CompilerIrCallArgs.One (CompilerIrValue.I64 7))
    (AstType.I64)))

(define (opt-inline-span-caller [symbols : OptInlineSpanTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (opt-inline-span-caller-call symbols)
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-span-program [symbols : OptInlineSpanTestSymbols]) : CompilerIrProgram
  (CompilerIrProgram.Program
    CompilerIrGlobalList.Nil
    (compiler-ir-function-cons
      (opt-inline-span-caller symbols)
      (compiler-ir-function-cons
        (opt-inline-span-callee symbols)
        CompilerIrFunctionList.Nil))
    CompilerIrExternList.Nil))

(define (compiler-optimize-spans-inline-callee-ok?) : bool
  (let
    [symbols : OptInlineSpanTestSymbols (opt-inline-span-test-symbols)]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert-instr
          (opt-spans-base)
          (opt-test-symbol "inline_span")
          (opt-inline-span-callee-call symbols)
          (opt-test-span 71 13))
        (opt-test-symbol "main")
        (opt-inline-span-caller-call symbols)
        (opt-test-span 81 15))]
    [cloned-call : CompilerIrInstr
      (CompilerIrInstr.Call
        1
        (struct-get symbols opaque)
        (CompilerIrCallArgs.One (CompilerIrValue.I64 7))
        (AstType.I64))]
    (match (optimize-program-with-spans-and-level
      (opt-inline-span-program symbols)
      spans
      2)
      [(CompilerOptimizedProgram.Program _ optimized-spans)
        (opt-span-lookup-ok?
          optimized-spans
          (opt-test-symbol "main")
          cloned-call
          71
          13)])))

(define (compiler-optimize-spans-inline-fallback-ok?) : bool
  (let
    [symbols : OptInlineSpanTestSymbols (opt-inline-span-test-symbols)]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (opt-spans-base)
        (opt-test-symbol "main")
        (opt-inline-span-caller-call symbols)
        (opt-test-span 91 17))]
    [cloned-call : CompilerIrInstr
      (CompilerIrInstr.Call
        1
        (struct-get symbols opaque)
        (CompilerIrCallArgs.One (CompilerIrValue.I64 7))
        (AstType.I64))]
    (match (optimize-program-with-spans-and-level
      (opt-inline-span-program symbols)
      spans
      2)
      [(CompilerOptimizedProgram.Program _ optimized-spans)
        (opt-span-lookup-ok?
          optimized-spans
          (opt-test-symbol "main")
          cloned-call
          91
          17)])))

(define (opt-inline-span-branch-phi-inputs) : CompilerIrPhiInputList
  (compiler-ir-phi-input-cons
    (CompilerIrValue.Var 1)
    (compiler-ir-label "inl.entry.0.then")
    (compiler-ir-phi-input-cons
      (CompilerIrValue.I64 42)
      (compiler-ir-label "inl.entry.0.else")
      CompilerIrPhiInputList.Nil)))

(define (compiler-optimize-spans-inline-multiblock-ok?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert-instr
          (opt-spans-base)
          (opt-test-symbol "inline_branch")
          (opt-inline-branch-callee-mov)
          (opt-test-span 141 27))
        (opt-test-symbol "main")
        (opt-inline-branch-caller-call symbols)
        (opt-test-span 151 29))]
    [phi : CompilerIrInstr
      (CompilerIrInstr.Phi 0 (opt-inline-span-branch-phi-inputs) (AstType.I64))]
    (match (opt-inline-program-functions-with-spans
      (opt-inline-branch-functions symbols)
      2
      spans)
      [(OptInlineSpanProgram.Program optimized optimized-spans)
        (match (opt-function-list-find optimized "main")
          [(OptMaybeFunction.Some main)
            (and
              (= (compiler-ir-block-list-count (opt-function-blocks main)) 5)
              (opt-span-lookup-ok?
                optimized-spans
                (opt-test-symbol "main")
                (opt-inline-branch-callee-mov)
                141
                27)
              (opt-span-lookup-ok?
                optimized-spans
                (opt-test-symbol "main")
                phi
                151
                29))]
          [(OptMaybeFunction.No) false])])))

(define (compiler-optimize-spans-non-inline-call-ok?) : bool
  (let
    [call : CompilerIrInstr
      (CompilerIrInstr.Call
        1
        (opt-test-symbol "opaque")
        (CompilerIrCallArgs.One (CompilerIrValue.I64 5))
        (AstType.I64))]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        call
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
          CompilerIrInstrList.Nil))]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (opt-spans-base)
        (opt-test-symbol "main")
        call
        (opt-test-span 101 19))]
    (match (optimize-program-with-spans-and-level
      (opt-spans-program instrs)
      spans
      2)
      [(CompilerOptimizedProgram.Program _ optimized-spans)
        (opt-span-lookup-ok?
          optimized-spans
          (opt-test-symbol "main")
          call
          101
          19)])))

(define (compiler-optimize-spans-pack-word-ok?) : bool
  (let
    [pack : CompilerIrInstr
      (CompilerIrInstr.Pack
        2
        (compiler-ir-value-cons
          (CompilerIrValue.Var 0)
          (compiler-ir-value-cons
            (CompilerIrValue.Var 1)
            CompilerIrValueList.Nil))
        (AstType.Struct (intern "Pair")))]
    [word : CompilerIrInstr
      (CompilerIrInstr.Word 3 (CompilerIrValue.Var 2) 0 (AstType.I64))]
    [tail : CompilerIrInstr
      (CompilerIrInstr.TailCallIndirect
        (CompilerIrValue.Function (opt-test-symbol "tail_target"))
        (CompilerIrCallArgs.Nil)
        (AstType.I64))]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        pack
        (compiler-ir-instr-cons
          word
          (compiler-ir-instr-cons
            tail
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              CompilerIrInstrList.Nil))))]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert-instr
          (compiler-source-spans-insert-instr
            (opt-spans-base)
            (opt-test-symbol "main")
            pack
            (opt-test-span 111 21))
          (opt-test-symbol "main")
          word
          (opt-test-span 121 23))
        (opt-test-symbol "main")
        tail
        (opt-test-span 131 25))]
    (match (optimize-program-with-spans-and-level
      (opt-spans-program instrs)
      spans
      0)
      [(CompilerOptimizedProgram.Program _ optimized-spans)
        (and
          (= (compiler-source-spans-instr-count spans) 2)
          (opt-span-lookup-ok? spans (opt-test-symbol "main") pack 111 21)
          (opt-span-lookup-ok? spans (opt-test-symbol "main") word 121 23)
          (opt-span-lookup-missing? spans (opt-test-symbol "main") tail)
          (= (compiler-source-spans-instr-count optimized-spans) 2)
          (opt-span-lookup-ok?
            optimized-spans
            (opt-test-symbol "main")
            pack
            111
            21)
          (opt-span-lookup-ok?
            optimized-spans
            (opt-test-symbol "main")
            word
            121
            23)
          (opt-span-lookup-missing?
            optimized-spans
            (opt-test-symbol "main")
            tail))])))

(define (compiler-optimize-spans-self-test) : i64
  (if (and
    (compiler-optimize-spans-dce-ok?)
    (compiler-optimize-spans-fold-ok?)
    (compiler-optimize-spans-cse-ok?)
    (compiler-optimize-dead-addrof-ok?)
    (compiler-optimize-spans-inline-callee-ok?)
    (compiler-optimize-spans-inline-fallback-ok?)
    (compiler-optimize-spans-inline-multiblock-ok?)
    (compiler-optimize-spans-non-inline-call-ok?)
    (compiler-optimize-spans-pack-word-ok?))
    42
    1))

(define (opt-aggregate-test-alloc) : CompilerIrInstr
  (CompilerIrInstr.Call
    1
    cbi.compiler-builtin-id-tl-alloc
    (CompilerIrCallArgs.One (CompilerIrValue.I64 16))
    (AstType.Struct (intern "Pair"))))

(define (opt-aggregate-positive-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        2
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 0)
        (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 2)
          (CompilerIrValue.I64 10)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            3
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 8)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 3)
              (CompilerIrValue.Bool true)
              (AstType.Bool))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                4
                (CompilerIrValue.Var 1)
                (CompilerIrValue.I64 0)
                (AstType.U8))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 5 (CompilerIrValue.Var 4) (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 5)))
                  CompilerIrInstrList.Nil)))))))))

(define (opt-aggregate-returned-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Return
        (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
      CompilerIrInstrList.Nil)))

(define (opt-aggregate-passed-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call
        2
        (opt-test-symbol "touch")
        (CompilerIrCallArgs.One (CompilerIrValue.Var 1))
        (AstType.Unit))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Return
          (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
        CompilerIrInstrList.Nil))))

(define (opt-aggregate-global-store-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Store
        (opt-test-symbol "escaped")
        (CompilerIrValue.Var 1)
        (AstType.U64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Return
          (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
        CompilerIrInstrList.Nil))))

(define (opt-aggregate-store-through-other-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.StorePtr
        (CompilerIrValue.Var 99)
        (CompilerIrValue.Var 1)
        (AstType.U64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Return
          (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
        CompilerIrInstrList.Nil))))

(define (opt-aggregate-unknown-offset-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        2
        (CompilerIrValue.Var 1)
        (CompilerIrValue.Var 9)
        (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Return
          (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
        CompilerIrInstrList.Nil))))

(define (opt-aggregate-call-separated-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        2
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 0)
        (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 2)
          (CompilerIrValue.I64 10)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            9
            (opt-test-symbol "touch")
            (CompilerIrCallArgs.Nil)
            (AstType.Unit))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              3
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 0)
              (AstType.U8))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 4 (CompilerIrValue.Var 3) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                CompilerIrInstrList.Nil))))))))

(define (opt-aggregate-predicated-memory-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        2
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 0)
        (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 2)
          (CompilerIrValue.I64 10)
          (AstType.I64))
        (compiler-ir-instr-cons
          (ir-instr-predicated-load
            8
            (CompilerIrValue.Var 99)
            (CompilerIrValue.I64 0)
            (CompilerIrValue.Bool true)
            4
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              3
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 0)
              (AstType.U8))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 4 (CompilerIrValue.Var 3) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                CompilerIrInstrList.Nil))))))))

(define (opt-aggregate-phi-flowed-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (opt-aggregate-test-alloc)
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "join"))
          CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "join")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            2
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 1)
              (compiler-ir-label "entry")
              (CompilerIrPhiInputList.Nil))
            (AstType.U64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-aggregate-no-candidates? [instrs : CompilerIrInstrList]) : bool
  (=
    (opt-aggregate-candidate-list-count
      (opt-aggregate-allocation-candidates (opt-spans-program instrs)))
    0))

(define (opt-aggregate-phi-flowed-rejected?) : bool
  (=
    (opt-aggregate-candidate-list-count
      (opt-aggregate-allocation-candidates
        (CompilerIrProgram.Program
          CompilerIrGlobalList.Nil
          (compiler-ir-function-cons
            (CompilerIrFunction.Function
              (opt-test-symbol "main")
              CompilerIrParamList.Nil
              (AstType.I64)
              4
              (opt-aggregate-phi-flowed-blocks))
            CompilerIrFunctionList.Nil)
          CompilerIrExternList.Nil)))
    0))

(define (opt-aggregate-positive-classified?) : bool
  (let
    [instrs : CompilerIrInstrList (opt-aggregate-positive-instrs)]
    [instr-count : i64 (compiler-ir-instr-list-count instrs)]
    [candidates : opt_aggregate_candidate_vec.Vec
      (opt-aggregate-allocation-candidates (opt-spans-program instrs))]
    (if (= (opt-aggregate-candidate-list-count candidates) 1)
      (match (array-ref (opt_aggregate_candidate_vec.slots (& candidates)) 0)
        [(OptAggregateAllocCandidate.Candidate base ty size ptrs accesses)
          (and
            (= base 1)
            (= size 16)
            (opt-type-eq ty (AstType.Struct (intern "Pair")))
            (= (opt-aggregate-pointer-list-count ptrs) 3)
            (= (opt_aggregate_access_vec.len (& accesses)) 3)
            (= (opt-aggregate-access-list-store-count accesses) 2)
            (= (opt-aggregate-access-list-load-count accesses) 1)
            (< (opt_aggregate_pointer_vec.capacity (& ptrs)) instr-count)
            (< (opt_aggregate_access_vec.capacity (& accesses)) instr-count))])
      false)))

;; Grow the append-ordered classifier scratch vector past its initial capacity.
;; The optimizer relies on the exact load/store order when it later promotes an
;; aggregate, so test both the interleaving and the metadata preserved by each
;; access entry.
(define (opt-aggregate-access-vector-growth-ok?) : bool
  (let
    [accesses : opt_aggregate_access_vec.Vec
      (opt_aggregate_access_vec.with-capacity 1)]
    (begin
      (opt_aggregate_access_vec.push
        (&mut accesses)
        (OptAggregateAccess.Store 0 (AstType.I64)))
      (opt_aggregate_access_vec.push
        (&mut accesses)
        (OptAggregateAccess.Load 11 0 (AstType.I64)))
      (opt_aggregate_access_vec.push
        (&mut accesses)
        (OptAggregateAccess.Store 8 (AstType.Bool)))
      (opt_aggregate_access_vec.push
        (&mut accesses)
        (OptAggregateAccess.Load 12 8 (AstType.Bool)))
      (opt_aggregate_access_vec.push
        (&mut accesses)
        (OptAggregateAccess.Store 16 (AstType.U64)))
      (and
        (= (opt_aggregate_access_vec.len (& accesses)) 5)
        (>= (opt_aggregate_access_vec.capacity (& accesses)) 5)
        (= (opt-aggregate-access-list-store-count accesses) 3)
        (= (opt-aggregate-access-list-load-count accesses) 2)
        (match (opt_aggregate_access_vec.get
          (& accesses)
          0
          (OptAggregateAccess.Store -1 (AstType.Unit)))
          [(OptAggregateAccess.Store offset ty)
            (and (= offset 0) (opt-type-eq ty (AstType.I64)))]
          [_ false])
        (match (opt_aggregate_access_vec.get
          (& accesses)
          1
          (OptAggregateAccess.Store -1 (AstType.Unit)))
          [(OptAggregateAccess.Load dst offset ty)
            (and (= dst 11) (= offset 0) (opt-type-eq ty (AstType.I64)))]
          [_ false])
        (match (opt_aggregate_access_vec.get
          (& accesses)
          2
          (OptAggregateAccess.Store -1 (AstType.Unit)))
          [(OptAggregateAccess.Store offset ty)
            (and (= offset 8) (opt-type-eq ty (AstType.Bool)))]
          [_ false])
        (match (opt_aggregate_access_vec.get
          (& accesses)
          3
          (OptAggregateAccess.Store -1 (AstType.Unit)))
          [(OptAggregateAccess.Load dst offset ty)
            (and (= dst 12) (= offset 8) (opt-type-eq ty (AstType.Bool)))]
          [_ false])
        (match (opt_aggregate_access_vec.get
          (& accesses)
          4
          (OptAggregateAccess.Store -1 (AstType.Unit)))
          [(OptAggregateAccess.Store offset ty)
            (and (= offset 16) (opt-type-eq ty (AstType.U64)))]
          [_ false])))))

;; Exercise the three former hand-written scratch wrappers past their initial
;; capacity. Pointer facts must retain append order and newest-match lookup;
;; candidates and promotion slots must keep the same selection order.
(define (opt-aggregate-core-vector-growth-ok?) : bool
  (let
    [ptrs : opt_aggregate_pointer_vec.Vec
      (opt_aggregate_pointer_vec.with-capacity 1)]
    [candidates : opt_aggregate_candidate_vec.Vec
      (opt_aggregate_candidate_vec.with-capacity 1)]
    [promote-slots : opt_aggregate_promote_slot_vec.Vec
      (opt_aggregate_promote_slot_vec.with-capacity 1)]
    [index : i64 0]
    (begin
      (while (< index 5)
        (begin
          (opt_aggregate_pointer_vec.push
            (&mut ptrs)
            (OptAggregatePointer.Pointer
              (if (or (= index 0) (= index 4))
                10
                (+ 10 index))
              (* index 8)))
          (opt_aggregate_candidate_vec.push
            (&mut candidates)
            (OptAggregateAllocCandidate.Candidate
              index
              (AstType.Unit)
              (+ index 1)
              (opt_aggregate_pointer_vec.new)
              (opt_aggregate_access_vec.new)))
          (opt_aggregate_promote_slot_vec.push
            (&mut promote-slots)
            (OptAggregatePromoteSlot.Slot index (+ 100 index)))
          (set! index (+ index 1))))
      (and
        (= (opt_aggregate_pointer_vec.len (& ptrs)) 5)
        (>= (opt_aggregate_pointer_vec.capacity (& ptrs)) 5)
        (= (opt_aggregate_candidate_vec.len (& candidates)) 5)
        (>= (opt_aggregate_candidate_vec.capacity (& candidates)) 5)
        (= (opt_aggregate_promote_slot_vec.len (& promote-slots)) 5)
        (>= (opt_aggregate_promote_slot_vec.capacity (& promote-slots)) 5)
        (match (opt_aggregate_pointer_vec.get
          (& ptrs)
          0
          (OptAggregatePointer.Pointer -1 -1))
          [(OptAggregatePointer.Pointer var offset)
            (and (= var 10) (= offset 0))])
        (match (opt-aggregate-pointer-list-lookup ptrs 10)
          [(option_i64.Some offset) (= offset 32)]
          [(option_i64.None) false])
        (match (array-ref (opt_aggregate_candidate_vec.slots (& candidates)) 0)
          [(OptAggregateAllocCandidate.Candidate base _ size _ _)
            (and (= base 0) (= size 1))])
        (match (array-ref (opt_aggregate_candidate_vec.slots (& candidates)) 4)
          [(OptAggregateAllocCandidate.Candidate base _ size _ _)
            (and (= base 4) (= size 5))])
        (match (opt-aggregate-promote-lookup promote-slots 4)
          [(option_i64.Some storage) (= storage 104)]
          [(option_i64.None) false])))))

(define (compiler-optimize-aggregate-candidate-self-test) : i64
  (cond
    [(not (opt-aggregate-positive-classified?)) 1]
    [(not (opt-aggregate-no-candidates? (opt-aggregate-returned-instrs))) 2]
    [(not (opt-aggregate-no-candidates? (opt-aggregate-passed-instrs))) 3]
    [(not (opt-aggregate-no-candidates? (opt-aggregate-global-store-instrs))) 4]
    [(not
        (opt-aggregate-no-candidates?
          (opt-aggregate-store-through-other-instrs)))
      5]
    [(not (opt-aggregate-no-candidates? (opt-aggregate-unknown-offset-instrs)))
      6]
    [(not (opt-aggregate-no-candidates? (opt-aggregate-call-separated-instrs)))
      7]
    [(not (opt-aggregate-phi-flowed-rejected?)) 8]
    [(not
        (opt-aggregate-no-candidates? (opt-aggregate-predicated-memory-instrs)))
      9]
    [(not (opt-aggregate-access-vector-growth-ok?)) 10]
    [(not (opt-aggregate-core-vector-growth-ok?)) 11]
    [else 42]))

(define (opt-aggregate-array-local-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Call
      1
      cbi.compiler-builtin-id-tl-alloc
      (CompilerIrCallArgs.One (CompilerIrValue.I64 16))
      (ast-ty-array (AstType.I64) 2))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        2
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 0)
        (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 2)
          (CompilerIrValue.Var 9)
          (ast-ty-array (AstType.I64) 2))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            3
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 0)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load
              4
              (CompilerIrValue.Var 3)
              (ast-ty-array (AstType.I64) 2))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
              CompilerIrInstrList.Nil)))))))

(define (opt-count-tl-alloc-calls [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.Call _ name _ _)
            (if (= name cbi.compiler-builtin-id-tl-alloc)
              1
              0)]
          [_ 0])
        (opt-count-tl-alloc-calls (box-get rest)))]))

(define (opt-count-ir-alloc-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.Alloc _ _) 1]
          [_ 0])
        (opt-count-ir-alloc-instrs (box-get rest)))]))

(define (opt-count-addr-of-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.AddrOf _ _) 1]
          [_ 0])
        (opt-count-addr-of-instrs (box-get rest)))]))

(define (opt-aggregate-promote-test-function [instrs : CompilerIrInstrList]) : CompilerIrFunction
  (opt-aggregate-stack-promote-function (opt-spans-function instrs)))

;; Self-test helper: materializes the optimized first block for list-shaped
;; assertions only, outside the production optimizer pipeline.
(define (opt-aggregate-promote-test-instrs [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match (opt-aggregate-promote-test-function instrs)
    [(CompilerIrFunction.Function _ _ _ _ blocks)
      (match (compiler-ir-block-list-force-cons blocks)
        [(CompilerIrBlockList.Cons block _)
          (match block
            [(CompilerIrBlock.Block _ optimized)
              (compiler-ir-instr-seq-to-list optimized)])]
        [(CompilerIrBlockList.Array _) CompilerIrInstrList.Nil]
        [(CompilerIrBlockList.Nil) CompilerIrInstrList.Nil])]))

(define (opt-aggregate-promote-test-frame [instrs : CompilerIrInstrList]) : i64
  (match (opt-aggregate-promote-test-function instrs)
    [(CompilerIrFunction.Function _ _ _ frame _) frame]))

(define (compiler-optimize-aggregate-promote-self-test) : i64
  (let
    [positive : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-positive-instrs))]
    [returned : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-returned-instrs))]
    [passed : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-passed-instrs))]
    [stored : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-global-store-instrs))]
    [unknown-offset : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-unknown-offset-instrs))]
    [call-separated : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-call-separated-instrs))]
    [array-local : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-array-local-instrs))]
    [level0 : CompilerIrProgram
      (optimize-program-with-level
        (opt-spans-program (opt-aggregate-positive-instrs))
        0)]
    [level2 : CompilerIrProgram
      (optimize-program-with-level
        (opt-spans-program (opt-aggregate-positive-instrs))
        2)]
    (cond
      [(not (= (opt-count-tl-alloc-calls positive) 0)) 1]
      [(not (= (opt-count-ir-alloc-instrs positive) 1)) 2]
      [(not (= (opt-count-addr-of-instrs positive) 1)) 3]
      [(not
          (=
            (opt-aggregate-promote-test-frame (opt-aggregate-positive-instrs))
            6))
        4]
      [(not (= (opt-count-tl-alloc-calls returned) 1)) 5]
      [(not (= (opt-count-tl-alloc-calls passed) 1)) 6]
      [(not (= (opt-count-tl-alloc-calls stored) 1)) 7]
      [(not (= (opt-count-tl-alloc-calls unknown-offset) 1)) 8]
      [(not (= (opt-count-tl-alloc-calls call-separated) 1)) 9]
      [(not (= (opt-count-tl-alloc-calls array-local) 1)) 10]
      [(not (= (opt-count-tl-alloc-calls (opt-program-first-instrs level0)) 1))
        11]
      [(not (= (opt-count-tl-alloc-calls (opt-program-first-instrs level2)) 0))
        12]
      [else 42])))

(define (opt-aggregate-repeated-load-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        2
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 0)
        (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 2)
          (CompilerIrValue.I64 10)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            3
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 0)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 4 (CompilerIrValue.Var 3) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                5
                (CompilerIrValue.Var 1)
                (CompilerIrValue.I64 0)
                (AstType.U8))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 6 (CompilerIrValue.Var 5) (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 6)))
                  CompilerIrInstrList.Nil)))))))))

(define (opt-aggregate-overwritten-load-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        2
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 0)
        (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 2)
          (CompilerIrValue.I64 10)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 20)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              3
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 0)
              (AstType.U8))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 4 (CompilerIrValue.Var 3) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                CompilerIrInstrList.Nil))))))))

(define (opt-aggregate-escaped-then-load-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Store
        (opt-test-symbol "escaped")
        (CompilerIrValue.Var 1)
        (AstType.U64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          2
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (AstType.U8))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 10)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              3
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 0)
              (AstType.U8))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 4 (CompilerIrValue.Var 3) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                CompilerIrInstrList.Nil))))))))

(define (opt-aggregate-array-typed-load-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        2
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 0)
        (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 2)
          (CompilerIrValue.Var 9)
          (ast-ty-array (AstType.I64) 2))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            3
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 0)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load
              4
              (CompilerIrValue.Var 3)
              (ast-ty-array (AstType.I64) 2))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
              CompilerIrInstrList.Nil)))))))

(define (opt-aggregate-branch-load-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (opt-aggregate-test-alloc)
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            2
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 0)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 2)
              (CompilerIrValue.I64 10)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Bool true)
                (compiler-ir-label "then")
                (compiler-ir-label "else"))
              CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            3
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 0)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 4 (CompilerIrValue.Var 3) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
              CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

(define (opt-count-load-dst-instrs [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.Load d _ _)
            (if (= d dst)
              1
              0)]
          [_ 0])
        (opt-count-load-dst-instrs (box-get rest) dst))]))

(define (opt-count-load-dst-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [dst : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-load-dst-instr-seq-from
      slots
      (+ index 1)
      count
      dst
      (+
        acc
        (match (array-ref slots index)
          [(CompilerIrInstr.Load d _ _)
            (if (= d dst)
              1
              0)]
          [_ 0])))))

(define (opt-count-load-dst-instr-seq [instrs : CompilerIrInstrSeq] [dst : i64]) : i64
  (opt-count-load-dst-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    dst
    0))

(define (opt-count-load-dst-blocks [blocks : CompilerIrBlockList] [dst : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-load-dst-instr-seq instrs dst)
            (opt-count-load-dst-blocks (box-get rest) dst))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-load-dst-blocks (compiler-ir-block-seq-to-list seq) dst)]))

(define (opt-count-mov-i64-value-blocks
  [blocks : CompilerIrBlockList]
  [needle : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-mov-i64-value-instr-seq instrs needle)
            (opt-count-mov-i64-value-blocks (box-get rest) needle))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-mov-i64-value-blocks
        (compiler-ir-block-seq-to-list seq)
        needle)]))

(define (opt-aggregate-sroa-test-instrs [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  ;; Self-test helper: materializes one optimized block for list assertions.
  (match (opt-aggregate-sroa-function (opt-spans-function instrs))
    [(CompilerIrFunction.Function _ _ _ _ blocks)
      (match (compiler-ir-block-list-force-cons blocks)
        [(CompilerIrBlockList.Cons block _)
          (match block
            [(CompilerIrBlock.Block _ optimized)
              (compiler-ir-instr-seq-to-list optimized)])]
        [(CompilerIrBlockList.Array _) CompilerIrInstrList.Nil]
        [(CompilerIrBlockList.Nil) CompilerIrInstrList.Nil])]))

(define (opt-aggregate-sroa-test-blocks [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match (opt-aggregate-sroa-function
    (CompilerIrFunction.Function
      (opt-test-symbol "main")
      CompilerIrParamList.Nil
      (AstType.I64)
      4
      blocks))
    [(CompilerIrFunction.Function _ _ _ _ optimized) optimized]))

(define (compiler-optimize-aggregate-sroa-self-test) : i64
  (let
    [positive-result : OptFunctionPassResult
      (opt-aggregate-sroa-function-pass
        (opt-spans-function (opt-aggregate-positive-instrs)))]
    [positive-changed : bool
      (match positive-result
        [(OptFunctionPassResult.Result _ changed) changed])]
    [noop-result : OptFunctionPassResult
      (opt-aggregate-sroa-function-pass
        (opt-spans-function
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 42)))
            CompilerIrInstrList.Nil)))]
    [noop-changed : bool
      (match noop-result
        [(OptFunctionPassResult.Result _ changed) changed])]
    [positive : CompilerIrInstrList
      (match positive-result
        [(OptFunctionPassResult.Result func _) (opt-function-first-instrs func)])]
    [repeated : CompilerIrInstrList
      (opt-aggregate-sroa-test-instrs (opt-aggregate-repeated-load-instrs))]
    [overwritten : CompilerIrInstrList
      (opt-aggregate-sroa-test-instrs (opt-aggregate-overwritten-load-instrs))]
    [barrier : CompilerIrInstrList
      (opt-aggregate-sroa-test-instrs (opt-aggregate-call-separated-instrs))]
    [escaped : CompilerIrInstrList
      (opt-aggregate-sroa-test-instrs (opt-aggregate-escaped-then-load-instrs))]
    [array-typed : CompilerIrInstrList
      (opt-aggregate-sroa-test-instrs (opt-aggregate-array-typed-load-instrs))]
    [branched : CompilerIrBlockList
      (opt-aggregate-sroa-test-blocks (opt-aggregate-branch-load-blocks))]
    (cond
      [(not positive-changed) 1]
      [noop-changed 2]
      [(not (= (opt-count-load-dst-instrs positive 5) 0)) 3]
      [(not (= (opt-mov-dst-i64-value positive 5 -1) 10)) 4]
      [(not (= (opt-count-load-dst-instrs repeated 4) 0)) 5]
      [(not (= (opt-count-load-dst-instrs repeated 6) 0)) 6]
      [(not (= (opt-count-mov-i64-value repeated 10) 2)) 7]
      [(not (= (opt-count-load-dst-instrs overwritten 4) 0)) 8]
      [(not (= (opt-mov-dst-i64-value overwritten 4 -1) 20)) 9]
      [(not (= (opt-count-mov-i64-value overwritten 10) 0)) 10]
      [(not (= (opt-count-load-dst-instrs barrier 4) 1)) 11]
      [(not (= (opt-count-mov-i64-value barrier 10) 0)) 12]
      [(not (= (opt-count-load-dst-instrs escaped 4) 1)) 13]
      [(not (= (opt-count-mov-i64-value escaped 10) 0)) 14]
      [(not (= (opt-count-load-dst-instrs array-typed 4) 1)) 15]
      [(not (= (opt-count-load-dst-blocks branched 4) 1)) 16]
      [(not (= (opt-count-mov-i64-value-blocks branched 10) 0)) 17]
      [else 42])))

(define (opt-count-cast-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.Cast _ _ _ _) 1]
          [_ 0])
        (opt-count-cast-instrs (box-get rest)))]))

(define (opt-count-cast-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-cast-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(CompilerIrInstr.Cast _ _ _ _) 1]
          [_ 0])))))

(define (opt-count-cast-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-cast-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

;; Builds `[Mov v0=20, Mov v1=22, BinOp v2 = v0 + v1]` (one arithmetic instr).
(define (opt-self-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 20) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 22) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.I64))
        (CompilerIrInstrList.Nil)))))

(define (opt-stale-load-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 41) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 0 (CompilerIrValue.Var 9) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          1
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        (CompilerIrInstrList.Nil)))))

(define (opt-vector-mask-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 3) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 4) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Splat 2 (CompilerIrValue.Var 0) 4 (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.LaneId 3 4 (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.TailMask
              4
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 1)
              4)
            (compiler-ir-instr-cons
              (ir-instr-vector-bin-op
                5
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 2)
                (CompilerIrValue.Var 3)
                4
                (AstType.I64))
              (compiler-ir-instr-cons
                (ir-instr-select
                  6
                  (CompilerIrValue.Var 4)
                  (CompilerIrValue.Var 5)
                  (CompilerIrValue.Var 2)
                  4
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (ir-instr-predicated-store
                    (CompilerIrValue.Var 8)
                    (CompilerIrValue.Var 0)
                    (CompilerIrValue.Var 6)
                    (CompilerIrValue.Var 4)
                    4
                    (AstType.I64))
                  CompilerIrInstrList.Nil)))))))))

(define (opt-vector-cse-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (ir-instr-vector-bin-op
      2
      (CompilerIrBinOp.Add)
      (CompilerIrValue.Var 0)
      (CompilerIrValue.Var 1)
      4
      (AstType.I64))
    (compiler-ir-instr-cons
      (ir-instr-vector-bin-op
        3
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 1)
        4
        (AstType.I64))
      CompilerIrInstrList.Nil)))

(define (opt-vector-reduce-cse-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.VectorReduce
      1
      (CompilerIrVectorReduceOp.Sum)
      (CompilerIrValue.Var 0)
      4
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.VectorReduce
        2
        (CompilerIrVectorReduceOp.Sum)
        (CompilerIrValue.Var 0)
        4
        (AstType.I64))
      CompilerIrInstrList.Nil)))

(define (opt-vector-reduce-stale-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.VectorReduce
        1
        (CompilerIrVectorReduceOp.Sum)
        (CompilerIrValue.Var 0)
        4
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        CompilerIrInstrList.Nil))))

(define (opt-vector-copy-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 2 (CompilerIrValue.Var 0) (AstType.I64))
    (compiler-ir-instr-cons
      (ir-instr-vector-bin-op
        3
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 2)
        (CompilerIrValue.Var 1)
        4
        (AstType.I64))
      CompilerIrInstrList.Nil)))

(define (opt-mask-copy-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 2 (CompilerIrValue.Var 0) (AstType.Bool))
    (compiler-ir-instr-cons
      (CompilerIrInstr.MaskBinOp
        3
        (CompilerIrMaskBinOp.And)
        (CompilerIrValue.Var 2)
        (CompilerIrValue.Var 1)
        4)
      CompilerIrInstrList.Nil)))

(define (opt-mask-reduce-copy-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 1 (CompilerIrValue.Var 0) (AstType.Bool))
    (compiler-ir-instr-cons
      (CompilerIrInstr.MaskReduce
        2
        (CompilerIrMaskReduceOp.Any)
        (CompilerIrValue.Var 1)
        4)
      CompilerIrInstrList.Nil)))

(define (opt-mask-not-copy-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 1 (CompilerIrValue.Var 0) (AstType.Bool))
    (compiler-ir-instr-cons
      (CompilerIrInstr.MaskNot 2 (CompilerIrValue.Var 1) 4)
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 4 (CompilerIrValue.Bool true) (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.MaskNot 5 (CompilerIrValue.Var 4) 4)
          CompilerIrInstrList.Nil)))))

(define (opt-mask-idempotent-copy-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 1 (CompilerIrValue.Var 0) (AstType.Bool))
    (compiler-ir-instr-cons
      (CompilerIrInstr.MaskBinOp
        2
        (CompilerIrMaskBinOp.Or)
        (CompilerIrValue.Var 1)
        (CompilerIrValue.Var 1)
        4)
      (compiler-ir-instr-cons
        (CompilerIrInstr.MaskReduce
          3
          (CompilerIrMaskReduceOp.Any)
          (CompilerIrValue.Var 2)
          4)
        (compiler-ir-instr-cons
          (CompilerIrInstr.MaskBinOp
            4
            (CompilerIrMaskBinOp.And)
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 1)
            4)
          (compiler-ir-instr-cons
            (CompilerIrInstr.MaskReduce
              5
              (CompilerIrMaskReduceOp.Any)
              (CompilerIrValue.Var 4)
              4)
            CompilerIrInstrList.Nil))))))

(define (opt-count-vector-binop-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.VectorBinOp payload-box)
            (match (box-get payload-box)
              [(CompilerIrInstrVectorBinOpPayload.Payload _ _ _ _ _ _) 1])]
          [_ 0])
        (opt-count-vector-binop-instrs (box-get rest)))]))

(define (opt-count-vector-reduce-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.VectorReduce _ _ _ _ _) 1]
          [_ 0])
        (opt-count-vector-reduce-instrs (box-get rest)))]))

(define (opt-vector-binop-lhs-var [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) (- 0 1)]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.VectorBinOp payload-box)
          (match (box-get payload-box)
            [(CompilerIrInstrVectorBinOpPayload.Payload d _ lhs _ _ _)
              (if (= d dst)
                (match lhs
                  [(CompilerIrValue.Var id) id]
                  [_ (- 0 1)])
                (opt-vector-binop-lhs-var (box-get rest) dst))])]
        [_ (opt-vector-binop-lhs-var (box-get rest) dst)])]))

(define (opt-mask-binop-lhs-var [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) (- 0 1)]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.MaskBinOp d _ lhs _ _)
          (if (= d dst)
            (match lhs
              [(CompilerIrValue.Var id) id]
              [_ (- 0 1)])
            (opt-mask-binop-lhs-var (box-get rest) dst))]
        [_ (opt-mask-binop-lhs-var (box-get rest) dst)])]))

(define (opt-mask-reduce-src-var [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) (- 0 1)]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.MaskReduce d _ src _)
          (if (= d dst)
            (match src
              [(CompilerIrValue.Var id) id]
              [_ (- 0 1)])
            (opt-mask-reduce-src-var (box-get rest) dst))]
        [_ (opt-mask-reduce-src-var (box-get rest) dst)])]))

(define (opt-mask-not-src-var [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) (- 0 1)]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.MaskNot d src _)
          (if (= d dst)
            (match src
              [(CompilerIrValue.Var id) id]
              [_ (- 0 1)])
            (opt-mask-not-src-var (box-get rest) dst))]
        [_ (opt-mask-not-src-var (box-get rest) dst)])]))

(define (compiler-optimize-vector-mask-self-test) : i64
  (let
    [instrs : CompilerIrInstrList (opt-vector-mask-test-instrs)]
    [folded : CompilerIrInstrList (opt-fold-instrs (OptConstEnv.Nil) instrs)]
    [dce : CompilerIrInstrList
      (opt-dce-instrs
        (opt-collect-instrs-uses (opt_i64_i64_map.with-capacity 64) instrs)
        instrs)]
    [bounds : CompilerIrInstrList
      (opt-bounds-instrs (OptBoundsFacts.Nil) (OptBoundsCastEnv.Nil) instrs)]
    [vector-cse : CompilerIrInstrList
      (opt-cse-instrs (OptExprTable.Nil) (opt-vector-cse-instrs))]
    [vector-reduce-cse : CompilerIrInstrList
      (opt-cse-instrs (OptExprTable.Nil) (opt-vector-reduce-cse-instrs))]
    [vector-stale : CompilerIrInstrList
      (opt-fold-instrs (OptConstEnv.Nil) (opt-vector-reduce-stale-instrs))]
    [vector-copy : CompilerIrInstrList
      (opt-copy-instrs (OptCopyEnv.Nil) (opt-vector-copy-instrs))]
    [mask-copy : CompilerIrInstrList
      (opt-copy-instrs (OptCopyEnv.Nil) (opt-mask-copy-instrs))]
    [mask-reduce-copy : CompilerIrInstrList
      (opt-copy-instrs (OptCopyEnv.Nil) (opt-mask-reduce-copy-instrs))]
    [mask-not-copy : CompilerIrInstrList
      (opt-copy-instrs (OptCopyEnv.Nil) (opt-mask-not-copy-instrs))]
    [mask-idempotent-copy : CompilerIrInstrList
      (opt-copy-instrs
        (OptCopyEnv.Nil)
        (opt-fold-instrs (OptConstEnv.Nil) (opt-mask-idempotent-copy-instrs)))]
    [mask-idempotent-dce : CompilerIrInstrList
      (opt-dce-instrs
        (opt-collect-instrs-uses
          (opt_i64_i64_map.with-capacity 64)
          mask-idempotent-copy)
        mask-idempotent-copy)]
    (cond
      [(not (opt-instr-list-eq folded instrs)) 1]
      [(not (= (compiler-ir-instr-list-count dce) 8)) 2]
      [(not (= (compiler-ir-instr-list-count bounds) 8)) 3]
      [(not (= (opt-count-vector-binop-instrs vector-cse) 2)) 4]
      [(not (= (opt-mov-dst-type-tag vector-cse 3) 0)) 5]
      [(not (= (opt-count-vector-reduce-instrs vector-reduce-cse) 2)) 6]
      [(not (= (opt-mov-dst-type-tag vector-reduce-cse 2) 0)) 7]
      [(not (= (opt-count-arith-instrs vector-stale) 1)) 8]
      [(not (= (opt-count-mov-i64-value vector-stale 11) 0)) 9]
      [(not (= (opt-vector-binop-lhs-var vector-copy 3) 2)) 10]
      [(not (= (opt-mask-binop-lhs-var mask-copy 3) 0)) 11]
      [(not (= (opt-mask-reduce-src-var mask-reduce-copy 2) 0)) 12]
      [(not (= (opt-mask-not-src-var mask-not-copy 2) 0)) 13]
      [(not (= (opt-mask-binop-lhs-var mask-idempotent-copy 2) 0)) 14]
      [(not (= (opt-mask-binop-lhs-var mask-idempotent-copy 4) 0)) 15]
      [(not (= (opt-mov-dst-type-tag mask-idempotent-copy 2) 0)) 16]
      [(not (= (opt-mask-reduce-src-var mask-idempotent-copy 3) 0)) 17]
      [(not (= (opt-mask-reduce-src-var mask-idempotent-copy 5) 0)) 18]
      [(not (= (compiler-ir-instr-list-count mask-idempotent-dce) 0)) 19]
      [(not (= (opt-mask-not-src-var mask-not-copy 5) 4)) 20]
      [else 42])))

;; Returns 42 when folding turns the one arithmetic instruction into a `Mov`
;; literal whose value (20 + 22) is correct, and a later `Load` redefining a
;; formerly-constant var invalidates the stale fact before another arithmetic
;; instruction reads that var.
(define (compiler-optimize-self-test-failure-message
  [name : String]
  [actual : i64]
  [expected : i64]) : String
  (str_cat.str-cat
    "optimizer self-test failed: "
    name
    " (expected "
    (string.int->string expected)
    ", got "
    (string.int->string actual)
    ")"))

(define (compiler-optimize-self-test-require-i64!
  [name : String]
  [actual : i64]
  [expected : i64]) : unit
  (unless
    (= actual expected)
    (io.panic
      (compiler-optimize-self-test-failure-message name actual expected))))

(define (compiler-optimize-self-test-require! [name : String] [ok : bool]) : unit
  (unless ok (io.panic (str_cat.str-cat "optimizer self-test failed: " name))))

(define (compiler-optimize-self-test) : i64
  (let
    [instrs : CompilerIrInstrList (opt-self-test-instrs)]
    [optimized : CompilerIrInstrList (opt-fold-instrs (OptConstEnv.Nil) instrs)]
    [fold-fire-result : OptBlockListPassResult
      (optimize-block-list-for-function-pass
        8
        CompilerIrParamList.Nil
        (compiler-ir-block-cons
          (compiler-ir-block (compiler-ir-label "entry") instrs)
          CompilerIrBlockList.Nil))]
    [fold-noop-result : OptBlockListPassResult
      (optimize-block-list-for-function-pass
        1
        CompilerIrParamList.Nil
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "entry")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 42)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil))]
    (begin
      (compiler-optimize-self-test-require!
        "fold pass reports a real rewrite"
        (match fold-fire-result
          [(OptBlockListPassResult.Result _ changed) changed]))
      (compiler-optimize-self-test-require!
        "fold pass reports and reuses a no-op"
        (match fold-noop-result
          [(OptBlockListPassResult.Result _ changed) (not changed)]))
      (compiler-optimize-self-test-require-i64!
        "constant-fold input arithmetic count"
        (opt-count-arith-instrs instrs)
        1)
      (compiler-optimize-self-test-require-i64!
        "constant-fold output arithmetic count"
        (opt-count-arith-instrs optimized)
        0)
      (compiler-optimize-self-test-require-i64!
        "constant-fold literal sum"
        (opt-sum-mov-i64 optimized)
        84)
      (let
        [stale-instrs : CompilerIrInstrList (opt-stale-load-test-instrs)]
        [stale-optimized : CompilerIrInstrList
          (opt-fold-instrs (OptConstEnv.Nil) stale-instrs)]
        (begin
          (compiler-optimize-self-test-require-i64!
            "stale load invalidates constant fact"
            (opt-count-arith-instrs stale-optimized)
            1)
          (compiler-optimize-self-test-require-i64!
            "vector/mask folding and copy propagation"
            (compiler-optimize-vector-mask-self-test)
            42)
          (compiler-optimize-self-test-require!
            "loop-BCE argc summary prescan"
            (opt-loop-bce-argc-summary-prescan-self-test?))
          42)))))

(define (opt-typed-fold-u64-shr-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 20 (CompilerIrValue.I64 (- 0 1)) (AstType.U64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 21 (CompilerIrValue.I64 63) (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          22
          (CompilerIrBinOp.Shr)
          (CompilerIrValue.Var 20)
          (CompilerIrValue.Var 21)
          (AstType.U64))
        (CompilerIrInstrList.Nil)))))

(define (opt-typed-fold-shift-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 15 (CompilerIrValue.I64 1) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 16 (CompilerIrValue.I64 3) (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          17
          (CompilerIrBinOp.Shl)
          (CompilerIrValue.Var 15)
          (CompilerIrValue.Var 16)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 18 (CompilerIrValue.I64 (- 0 8)) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              19
              (CompilerIrBinOp.Shr)
              (CompilerIrValue.Var 18)
              (CompilerIrValue.I64 1)
              (AstType.I64))
            (opt-typed-fold-u64-shr-instrs)))))))

(define (opt-typed-fold-div-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BinOp
      13
      (CompilerIrBinOp.Div)
      (CompilerIrValue.I64 42)
      (CompilerIrValue.I64 6)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        14
        (CompilerIrBinOp.Mod)
        (CompilerIrValue.I64 22)
        (CompilerIrValue.I64 7)
        (AstType.U8))
      (opt-typed-fold-shift-instrs))))

(define (opt-typed-fold-bool-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 11 (CompilerIrValue.Bool true) (AstType.Bool))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        12
        (CompilerIrBinOp.And)
        (CompilerIrValue.Var 11)
        (CompilerIrValue.Bool false)
        (AstType.Bool))
      (opt-typed-fold-div-instrs))))

(define (opt-typed-fold-cast-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Cast 7 (CompilerIrValue.Var 0) (AstType.U8) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Cast
        8
        (CompilerIrValue.I64 300)
        (AstType.U16)
        (AstType.Char))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 9 (CompilerIrValue.Char 'A') (AstType.Char))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Cast
            10
            (CompilerIrValue.Var 9)
            (AstType.Char)
            (AstType.I64))
          (opt-typed-fold-bool-instrs))))))

(define (opt-typed-fold-compare-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 (- 0 1)) (AstType.I8))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 4 (CompilerIrValue.I64 1) (AstType.I8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          5
          (CompilerIrBinOp.Lt)
          (CompilerIrValue.Var 3)
          (CompilerIrValue.Var 4)
          (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            6
            (CompilerIrBinOp.Lt)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            (AstType.Bool))
          (opt-typed-fold-cast-instrs))))))

(define (opt-typed-fold-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 255) (AstType.U8))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 1) (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.U8))
        (opt-typed-fold-compare-instrs)))))

(define (opt-typed-fold-invalid-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BinOp
      30
      (CompilerIrBinOp.Div)
      (CompilerIrValue.I64 1)
      (CompilerIrValue.I64 0)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        31
        (CompilerIrBinOp.Div)
        (CompilerIrValue.I64 (- 0 128))
        (CompilerIrValue.I64 (- 0 1))
        (AstType.I8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          32
          (CompilerIrBinOp.Shl)
          (CompilerIrValue.I64 1)
          (CompilerIrValue.I64 (- 0 1))
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            33
            (CompilerIrBinOp.Shl)
            (CompilerIrValue.I64 1)
            (CompilerIrValue.I64 8)
            (AstType.U8))
          (CompilerIrInstrList.Nil))))))

(define (opt-float-fold-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov
      40
      (CompilerIrValue.F64 (opt-test-f64-bits "1.5"))
      (AstType.F64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        41
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 40)
        (CompilerIrValue.F64 (opt-test-f64-bits "2.25"))
        (AstType.F64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          42
          (CompilerIrBinOp.Lt)
          (CompilerIrValue.Var 41)
          (CompilerIrValue.F64 (opt-test-f64-bits "4.0"))
          (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.UnOp
            43
            (CompilerIrUnOp.Neg)
            (CompilerIrValue.Var 41)
            (AstType.F64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Cast
              44
              (CompilerIrValue.F64 (opt-test-f64-bits "1.00000001"))
              (AstType.F64)
              (AstType.F32))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                56
                (CompilerIrBinOp.Mul)
                (CompilerIrValue.F64 (opt-test-f64-bits "-0.0"))
                (CompilerIrValue.F64 (opt-test-f64-bits "1.0"))
                (AstType.F64))
              (CompilerIrInstrList.Nil))))))))

(define (opt-float-fold-invalid-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BinOp
      45
      (CompilerIrBinOp.Div)
      (CompilerIrValue.F64 (opt-test-f64-bits "1.0"))
      (CompilerIrValue.F64 (opt-test-f64-bits "0.0"))
      (AstType.F64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        57
        (CompilerIrBinOp.Div)
        (CompilerIrValue.F64 (opt-test-f32-bits "1.0"))
        (CompilerIrValue.F64 (opt-test-f32-bits "0.0"))
        (AstType.F32))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          58
          (CompilerIrBinOp.Mul)
          (CompilerIrValue.F64 (opt-test-f64-bits "1e+308"))
          (CompilerIrValue.F64 (opt-test-f64-bits "1e+308"))
          (AstType.F64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Cast
            59
            (CompilerIrValue.F64 (opt-test-f64-bits "3.5e+38"))
            (AstType.F64)
            (AstType.F32))
          (CompilerIrInstrList.Nil))))))

(define (opt-finite-cast-fold-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Cast
      46
      (CompilerIrValue.I64 (- 0 42))
      (AstType.I64)
      (AstType.F64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Cast
        47
        (CompilerIrValue.I64 (- 0 1))
        (AstType.U64)
        (AstType.F64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Cast
          48
          (CompilerIrValue.I64 (- 0 1))
          (AstType.U64)
          (AstType.F32))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Cast
            49
            (CompilerIrValue.Char 'A')
            (AstType.Char)
            (AstType.F64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Cast
              50
              (CompilerIrValue.F64 (opt-test-f64-bits "3.75"))
              (AstType.F64)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Cast
                51
                (CompilerIrValue.F64 (opt-test-f64-bits "-3.75"))
                (AstType.F64)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Cast
                  52
                  (CompilerIrValue.F64 (opt-test-f64-bits "65.9"))
                  (AstType.F64)
                  (AstType.Char))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Cast
                    53
                    (CompilerIrValue.F64 (opt-test-f32-bits "3.9"))
                    (AstType.F32)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Cast
                      54
                      (CompilerIrValue.I64 16777217)
                      (AstType.I64)
                      (AstType.F32))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Cast
                        55
                        (CompilerIrValue.F64 (opt-test-f32-bits "-3.9"))
                        (AstType.F32)
                        (AstType.I64))
                      (CompilerIrInstrList.Nil))))))))))))

(define (opt-finite-cast-no-fold-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Cast
      60
      (CompilerIrValue.F64 (opt-test-f64-bits "9223372036854775808.0"))
      (AstType.F64)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Cast
        61
        (CompilerIrValue.F64 (opt-test-f64-bits "-1.0"))
        (AstType.F64)
        (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Cast
          62
          (CompilerIrValue.F64 (opt-test-f64-bits "256.0"))
          (AstType.F64)
          (AstType.Char))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Cast
            63
            (CompilerIrValue.F64 (opt-test-f64-bits "9223372036854775808.0"))
            (AstType.F64)
            (AstType.U64))
          (CompilerIrInstrList.Nil))))))

(define (compiler-optimize-float-fold-ok?) : bool
  (let
    [pos : CompilerIrInstrList
      (opt-fold-instrs (OptConstEnv.Nil) (opt-float-fold-instrs))]
    [neg : CompilerIrInstrList
      (opt-fold-instrs (OptConstEnv.Nil) (opt-float-fold-invalid-instrs))]
    [finite-casts : CompilerIrInstrList
      (opt-fold-instrs (OptConstEnv.Nil) (opt-finite-cast-fold-instrs))]
    [deferred-casts : CompilerIrInstrList
      (opt-fold-instrs (OptConstEnv.Nil) (opt-finite-cast-no-fold-instrs))]
    (and
      (= (opt-count-arith-instrs pos) 0)
      (= (opt-count-cast-instrs pos) 0)
      (opt-mov-dst-f64-bits? pos 41 (opt-test-f64-bits "3.75"))
      (opt-mov-dst-bool-value? pos 42 true)
      (opt-mov-dst-f64-bits? pos 43 (opt-test-f64-bits "-3.75"))
      (opt-mov-dst-f64-bits? pos 44 (opt-test-f32-bits "1.00000001"))
      (opt-mov-dst-f64-bits? pos 56 (opt-test-f64-bits "-0.0"))
      (= (opt-count-arith-instrs neg) 3)
      (= (opt-count-cast-instrs neg) 1)
      (= (opt-count-cast-instrs finite-casts) 0)
      (opt-mov-dst-f64-bits? finite-casts 46 (opt-test-f64-bits "-42.0"))
      (opt-mov-dst-f64-bits?
        finite-casts
        47
        (opt-test-f64-bits "18446744073709551616.0"))
      (opt-mov-dst-f64-bits?
        finite-casts
        48
        (opt-test-f32-bits "18446744073709551616.0"))
      (opt-mov-dst-f64-bits? finite-casts 49 (opt-test-f64-bits "65.0"))
      (= (opt-mov-dst-i64-value finite-casts 50 999) 3)
      (= (opt-mov-dst-i64-value finite-casts 51 999) (- 0 3))
      (= (opt-mov-dst-char-code finite-casts 52 0) 65)
      (= (opt-mov-dst-i64-value finite-casts 53 999) 3)
      (opt-mov-dst-f64-bits? finite-casts 54 (opt-test-f32-bits "16777217.0"))
      (= (opt-mov-dst-i64-value finite-casts 55 999) (- 0 3))
      (= (opt-count-cast-instrs deferred-casts) 4))))

(define (compiler-optimize-typed-fold-self-test) : i64
  (let
    [pos : CompilerIrInstrList
      (opt-fold-instrs (OptConstEnv.Nil) (opt-typed-fold-instrs))]
    [neg : CompilerIrInstrList
      (opt-fold-instrs (OptConstEnv.Nil) (opt-typed-fold-invalid-instrs))]
    (begin
      (unless (= (opt-count-arith-instrs pos) 0) (return 1))
      (unless (= (opt-count-cast-instrs pos) 0) (return 3))
      (unless (= (opt-mov-dst-i64-value pos 2 (- 0 999)) 0) (return 4))
      (unless (opt-mov-dst-bool-value? pos 5 true) (return 5))
      (unless (opt-mov-dst-bool-value? pos 6 false) (return 6))
      (unless (= (opt-mov-dst-i64-value pos 7 0) 255) (return 7))
      (unless (= (opt-mov-dst-char-code pos 8 0) 44) (return 8))
      (unless (= (opt-mov-dst-i64-value pos 10 0) 65) (return 9))
      (unless (opt-mov-dst-bool-value? pos 12 false) (return 10))
      (unless (= (opt-mov-dst-i64-value pos 13 0) 7) (return 11))
      (unless (= (opt-mov-dst-i64-value pos 14 0) 1) (return 12))
      (unless (= (opt-mov-dst-i64-value pos 17 0) 8) (return 13))
      (unless (= (opt-mov-dst-i64-value pos 19 0) (- 0 4)) (return 14))
      (unless (= (opt-mov-dst-i64-value pos 22 0) 1) (return 15))
      (unless (= (opt-count-arith-instrs neg) 4) (return 16))
      (unless (compiler-float-self-test) (return 17))
      (unless (compiler-optimize-float-fold-ok?) (return 18))
      (unless
        (and
          (match (opt-fold-unop
            (CompilerIrUnOp.Sqrt)
            (OptKnownConst.SomeConst
              (CompilerIrValue.F64 (opt-test-f64-bits "4.0"))
              (AstType.F64))
            (AstType.F64))
            [(CompilerIrMaybeValue.No) true]
            [_ false])
          (match (opt-fold-unop
            (CompilerIrUnOp.Sqrt)
            (OptKnownConst.SomeConst
              (CompilerIrValue.F64 (opt-test-f32-bits "4.0"))
              (AstType.F32))
            (AstType.F32))
            [(CompilerIrMaybeValue.No) true]
            [_ false]))
        (return 19))
      42)))

;; Positive strength-reduction cases: integer neutral/absorbing identities and
;; boolean `and`/`or` identities. The first instruction uses `AstType.U8` to prove
;; non-i64 integer result types keep their original type.
(define (opt-strength-self-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BinOp
      10
      (CompilerIrBinOp.Add)
      (CompilerIrValue.Var 1)
      (CompilerIrValue.I64 0)
      (AstType.U8))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        11
        (CompilerIrBinOp.Add)
        (CompilerIrValue.I64 0)
        (CompilerIrValue.Var 2)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          12
          (CompilerIrBinOp.Sub)
          (CompilerIrValue.Var 3)
          (CompilerIrValue.I64 0)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            13
            (CompilerIrBinOp.Mul)
            (CompilerIrValue.Var 4)
            (CompilerIrValue.I64 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              14
              (CompilerIrBinOp.Mul)
              (CompilerIrValue.I64 1)
              (CompilerIrValue.Var 5)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                15
                (CompilerIrBinOp.Mul)
                (CompilerIrValue.Var 6)
                (CompilerIrValue.I64 0)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  16
                  (CompilerIrBinOp.Mul)
                  (CompilerIrValue.I64 0)
                  (CompilerIrValue.Var 7)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    17
                    (CompilerIrBinOp.And)
                    (CompilerIrValue.Var 8)
                    (CompilerIrValue.Bool true)
                    (AstType.Bool))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.BinOp
                      18
                      (CompilerIrBinOp.And)
                      (CompilerIrValue.Bool true)
                      (CompilerIrValue.Var 9)
                      (AstType.Bool))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.BinOp
                        19
                        (CompilerIrBinOp.And)
                        (CompilerIrValue.Var 8)
                        (CompilerIrValue.Bool false)
                        (AstType.Bool))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.BinOp
                          20
                          (CompilerIrBinOp.And)
                          (CompilerIrValue.Bool false)
                          (CompilerIrValue.Var 9)
                          (AstType.Bool))
                        (compiler-ir-instr-cons
                          (CompilerIrInstr.BinOp
                            21
                            (CompilerIrBinOp.Or)
                            (CompilerIrValue.Var 8)
                            (CompilerIrValue.Bool false)
                            (AstType.Bool))
                          (compiler-ir-instr-cons
                            (CompilerIrInstr.BinOp
                              22
                              (CompilerIrBinOp.Or)
                              (CompilerIrValue.Bool false)
                              (CompilerIrValue.Var 9)
                              (AstType.Bool))
                            (compiler-ir-instr-cons
                              (CompilerIrInstr.BinOp
                                23
                                (CompilerIrBinOp.Or)
                                (CompilerIrValue.Var 8)
                                (CompilerIrValue.Bool true)
                                (AstType.Bool))
                              (compiler-ir-instr-cons
                                (CompilerIrInstr.BinOp
                                  24
                                  (CompilerIrBinOp.Or)
                                  (CompilerIrValue.Bool true)
                                  (CompilerIrValue.Var 9)
                                  (AstType.Bool))
                                (CompilerIrInstrList.Nil)))))))))))))))))

;; Negative cases for edge-sensitive operations and non-identities: division,
;; modulo, shifts, and `0 - x` must stay as `BinOp`s.
(define (opt-strength-negative-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BinOp
      30
      (CompilerIrBinOp.Div)
      (CompilerIrValue.Var 1)
      (CompilerIrValue.I64 0)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        31
        (CompilerIrBinOp.Mod)
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          32
          (CompilerIrBinOp.Shl)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            33
            (CompilerIrBinOp.Shr)
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 0)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              34
              (CompilerIrBinOp.Sub)
              (CompilerIrValue.I64 0)
              (CompilerIrValue.Var 1)
              (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

;; Returns 42 when every positive identity is rewritten to `Mov`, the typed U8
;; identity keeps its result type, and the negative cases stay untouched.
(define (compiler-optimize-strength-self-test) : i64
  (let
    [pos : CompilerIrInstrList
      (opt-strength-instrs (OptConstEnv.Nil) (opt-strength-self-test-instrs))]
    [neg : CompilerIrInstrList
      (opt-strength-instrs (OptConstEnv.Nil) (opt-strength-negative-instrs))]
    (cond
      [(not (= (opt-count-arith-instrs pos) 0)) 1]
      [(not (= (opt-sum-mov-var-src pos) 49)) 2]
      [(not (= (opt-count-mov-i64-value pos 0) 2)) 3]
      [(not (= (opt-count-mov-bool-value pos false) 2)) 4]
      [(not (= (opt-count-mov-bool-value pos true) 2)) 5]
      [(not (= (opt-mov-dst-type-tag pos 10) (ast-type-tag (AstType.U8)))) 6]
      [(not (= (opt-count-arith-instrs neg) 5)) 7]
      [else 42])))

;; Builds `[Mov v0=99 (unused), Call v1 = noop(), Pack v2 (unused), Return v1]`.
;; `v0` and `v2` are dead pure temporaries; `v1` is produced by a side-effecting
;; call and used by the return, so DCE must drop only the pure temporaries
;; (4 instrs -> 2).
(define (opt-dce-self-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 99) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call
        1
        (opt-test-symbol "noop")
        (CompilerIrCallArgs.Nil)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Pack
          2
          (compiler-ir-value-cons
            (CompilerIrValue.I64 7)
            (compiler-ir-value-cons
              (CompilerIrValue.I64 9)
              CompilerIrValueList.Nil))
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
          (CompilerIrInstrList.Nil))))))

(define (opt-dce-isolated-unused-alloc-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Return (CompilerIrMaybeValue.No))
      (CompilerIrInstrList.Nil))))

(define (opt-dce-used-alloc-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.AddrOf 1 0)
      (compiler-ir-instr-cons
        (CompilerIrInstr.Return
          (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
        (CompilerIrInstrList.Nil)))))

(define (opt-dce-alloc-run-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Alloc 1 (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Alloc 2 (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return (CompilerIrMaybeValue.No))
          (CompilerIrInstrList.Nil))))))

(define (opt-dce-clean-list-count [instrs : CompilerIrInstrList]) : i64
  (let
    [used : opt_i64_i64_map.Map
      (opt-collect-instrs-uses (opt_i64_i64_map.with-capacity 64) instrs)]
    [cleaned : CompilerIrInstrList (opt-dce-instrs used instrs)]
    (compiler-ir-instr-list-count cleaned)))

(define (opt-dce-clean-array-count [instrs : CompilerIrInstrList]) : i64
  (let
    [block : CompilerIrBlock
      (compiler-ir-block (compiler-ir-label "entry") instrs)]
    [used : (Array i64)
      (opt-collect-blocks-uses-array
        64
        (compiler-ir-block-cons block CompilerIrBlockList.Nil))]
    [cleaned : CompilerIrBlock (opt-dce-block-array used block)]
    (match cleaned
      [(CompilerIrBlock.Block _ cleaned-instrs)
        (compiler-ir-instr-seq-count cleaned-instrs)])))

(define (compiler-optimize-dce-alloc-self-test) : i64
  (let
    [isolated : CompilerIrInstrList (opt-dce-isolated-unused-alloc-instrs)]
    [used : CompilerIrInstrList (opt-dce-used-alloc-instrs)]
    [run : CompilerIrInstrList (opt-dce-alloc-run-instrs)]
    (cond
      [(not (= (opt-dce-clean-list-count isolated) 1)) 1]
      [(not (= (opt-dce-clean-list-count used) 3)) 2]
      [(not (= (opt-dce-clean-list-count run) 4)) 3]
      [(not (= (opt-dce-clean-array-count isolated) 1)) 4]
      [(not (= (opt-dce-clean-array-count used) 3)) 5]
      [(not (= (opt-dce-clean-array-count run) 4)) 6]
      [else 42])))

;; Returns 42 when DCE keeps the used call result `v1` and the side-effecting
;; instructions, drops the unused `v0`, and is idempotent on a second pass.
(define (compiler-optimize-dce-self-test) : i64
  (let
    [instrs : CompilerIrInstrList (opt-dce-self-test-instrs)]
    [used : opt_i64_i64_map.Map
      (opt-collect-instrs-uses (opt_i64_i64_map.with-capacity 64) instrs)]
    [cleaned : CompilerIrInstrList (opt-dce-instrs used instrs)]
    [again : CompilerIrInstrList
      (opt-dce-instrs
        (opt-collect-instrs-uses (opt_i64_i64_map.with-capacity 64) cleaned)
        cleaned)]
    [unused-word-dead : bool
      (opt-instr-dead?
        (opt_i64_i64_map.with-capacity 4)
        (CompilerIrInstr.Word 3 (CompilerIrValue.Var 2) 0 (AstType.I64)))]
    [dead-blocks : CompilerIrBlockList
      (compiler-ir-block-cons
        (compiler-ir-block (compiler-ir-label "entry") instrs)
        CompilerIrBlockList.Nil)]
    [dead-result : OptBlockListPassResult
      (opt-dce-block-list-array-pass
        (opt-collect-blocks-uses-array 8 dead-blocks)
        dead-blocks)]
    [live-blocks : CompilerIrBlockList
      (compiler-ir-block-cons
        (compiler-ir-block (compiler-ir-label "entry") cleaned)
        CompilerIrBlockList.Nil)]
    [live-result : OptBlockListPassResult
      (opt-dce-block-list-array-pass
        (opt-collect-blocks-uses-array 8 live-blocks)
        live-blocks)]
    [alloc-tests : i64 (compiler-optimize-dce-alloc-self-test)]
    (cond
      [(not
          (match dead-result
            [(OptBlockListPassResult.Result _ changed) changed]))
        1]
      [(not
          (match live-result
            [(OptBlockListPassResult.Result _ changed) (not changed)]))
        2]
      [(not (opt-used-contains used 1)) 3]
      [(opt-used-contains used 0) 4]
      [(not (= (compiler-ir-instr-list-count instrs) 4)) 5]
      [(not (= (compiler-ir-instr-list-count cleaned) 2)) 6]
      [(not (= (compiler-ir-instr-list-count again) 2)) 7]
      [(not unused-word-dead) 8]
      [(not (= alloc-tests 42)) 9]
      [else 42])))

;; Builds `[Mov v0=4096 (an address), Load v1 = *v0, Return v1]`. `v0` feeds a
;; `Load`, so DCE must treat it as used and keep it; without collecting the
;; Load's operand uses, DCE would wrongly drop `v0`'s Mov and break the load.
(define (opt-dce-mem-self-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 4096) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 1 (CompilerIrValue.Var 0) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Return
          (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
        (CompilerIrInstrList.Nil)))))

;; Returns 42 when DCE keeps the `Mov` that feeds the `Load` (operand uses of
;; pointer/memory ops are collected), leaving all three instructions intact.
(define (compiler-optimize-dce-mem-self-test) : i64
  (let
    [instrs : CompilerIrInstrList (opt-dce-mem-self-test-instrs)]
    [used : opt_i64_i64_map.Map
      (opt-collect-instrs-uses (opt_i64_i64_map.with-capacity 64) instrs)]
    [cleaned : CompilerIrInstrList (opt-dce-instrs used instrs)]
    (if (opt-used-contains used 0)
      (if (= (compiler-ir-instr-list-count cleaned) 3)
        42
        2)
      1)))

(define (opt-count-binop-op-instr
  [instr : CompilerIrInstr]
  [op : CompilerIrBinOp]) : i64
  (match instr
    [(CompilerIrInstr.BinOp _ actual _ _ _)
      (if (opt-binop-eq actual op)
        1
        0)]
    [_ 0]))

(define (opt-count-binop-op-instr-seq-from
  [instrs : CompilerIrInstrSeq]
  [op : CompilerIrBinOp]
  [index : i64]
  [acc : i64]) : i64
  (if (>= index (compiler-ir-instr-seq-count instrs))
    acc
    (opt-count-binop-op-instr-seq-from
      instrs
      op
      (+ index 1)
      (+
        acc
        (opt-count-binop-op-instr (compiler-ir-instr-seq-ref instrs index) op)))))

(define (opt-count-binop-op-instr-seq
  [instrs : CompilerIrInstrSeq]
  [op : CompilerIrBinOp]) : i64
  (opt-count-binop-op-instr-seq-from instrs op 0 0))

(define (opt-count-binop-op-blocks
  [blocks : CompilerIrBlockList]
  [op : CompilerIrBinOp]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-binop-op-instr-seq instrs op)
            (opt-count-binop-op-blocks (box-get rest) op))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-binop-op-blocks (compiler-ir-block-seq-to-list seq) op)]))

(define (opt-divrem-test-return
  [result : CompilerIrValue]
  [return-result? : bool]) : CompilerIrInstr
  (if return-result?
    (CompilerIrInstr.Return (CompilerIrMaybeValue.Some result))
    (CompilerIrInstr.Return (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))))

(define (opt-divrem-test-params [ty : AstType]) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "lhs" ty 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "rhs" ty 1)
      (CompilerIrParamList.Nil))))

(define (opt-divrem-branch-blocks
  [cmp-op : CompilerIrBinOp]
  [cmp-lhs : CompilerIrValue]
  [cmp-rhs : CompilerIrValue]
  [arith-op : CompilerIrBinOp]
  [arith-lhs : CompilerIrValue]
  [arith-rhs : CompilerIrValue]
  [arith-ty : AstType]
  [return-result? : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp 2 cmp-op cmp-lhs cmp-rhs (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 2)
            (compiler-ir-label "safe")
            (compiler-ir-label "exit"))
          CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "safe")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp 3 arith-op arith-lhs arith-rhs arith-ty)
          (compiler-ir-instr-cons
            (opt-divrem-test-return (CompilerIrValue.Var 3) return-result?)
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "exit")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

(define (opt-divrem-cast-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Cast
          2
          (CompilerIrValue.Var 1)
          (AstType.I64)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            3
            (CompilerIrBinOp.Gt)
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 0)
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 3)
              (compiler-ir-label "safe")
              (compiler-ir-label "exit"))
            CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "safe")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            4
            (CompilerIrBinOp.Div)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "exit")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

(define (opt-divrem-rhs-redefined-before-branch-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Ne)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 2)
              (compiler-ir-label "safe")
              (compiler-ir-label "exit"))
            CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "safe")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            3
            (CompilerIrBinOp.Div)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "exit")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

(define (opt-divrem-rhs-redefined-in-safe-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Ne)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 2)
            (compiler-ir-label "safe")
            (compiler-ir-label "exit"))
          CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "safe")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              3
              (CompilerIrBinOp.Div)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "exit")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

(define (opt-divrem-lhs-not-min-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Ne)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 2)
            (compiler-ir-label "check_lhs")
            (compiler-ir-label "exit"))
          CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "check_lhs")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            3
            (CompilerIrBinOp.Ne)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.I64 (opt-signed-min (AstType.I64)))
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 3)
              (compiler-ir-label "safe")
              (compiler-ir-label "exit"))
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "safe")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Div)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(define (opt-divrem-dce-blocks
  [params : CompilerIrParamList]
  [blocks : CompilerIrBlockList]
  [frame : i64]) : CompilerIrBlockList
  (let
    [safe : CompilerIrBlockList (opt-divrem-safety-blocks params blocks)]
    [used : (Array i64) (opt-collect-blocks-uses-array frame safe)]
    (opt-dce-block-list-array used safe)))

(define (compiler-optimize-divrem-safety-self-test) : i64
  (let
    [i64-params : CompilerIrParamList (opt-divrem-test-params (AstType.I64))]
    [u64-params : CompilerIrParamList (opt-divrem-test-params (AstType.U64))]
    [signed-positive : CompilerIrBlockList
      (opt-divrem-safety-blocks
        i64-params
        (opt-divrem-branch-blocks
          (CompilerIrBinOp.Gt)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (CompilerIrBinOp.Div)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.I64)
          true))]
    [signed-mod-positive : CompilerIrBlockList
      (opt-divrem-safety-blocks
        i64-params
        (opt-divrem-branch-blocks
          (CompilerIrBinOp.Ge)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 1)
          (CompilerIrBinOp.Mod)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.I64)
          true))]
    [unsigned-nonzero : CompilerIrBlockList
      (opt-divrem-safety-blocks
        u64-params
        (opt-divrem-branch-blocks
          (CompilerIrBinOp.Ne)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (CompilerIrBinOp.Div)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.U64)
          true))]
    [lhs-not-min : CompilerIrBlockList
      (opt-divrem-safety-blocks i64-params (opt-divrem-lhs-not-min-blocks))]
    [zero-reachable : CompilerIrBlockList
      (opt-divrem-safety-blocks
        i64-params
        (opt-divrem-branch-blocks
          (CompilerIrBinOp.Ne)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 (- 0 1))
          (CompilerIrBinOp.Div)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.I64)
          true))]
    [neg-one-reachable : CompilerIrBlockList
      (opt-divrem-safety-blocks
        i64-params
        (opt-divrem-branch-blocks
          (CompilerIrBinOp.Ne)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (CompilerIrBinOp.Div)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.I64)
          true))]
    [weak-negative-range : CompilerIrBlockList
      (opt-divrem-safety-blocks
        i64-params
        (opt-divrem-branch-blocks
          (CompilerIrBinOp.Lt)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (CompilerIrBinOp.Div)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.I64)
          true))]
    [cast-unsupported : CompilerIrBlockList
      (opt-divrem-safety-blocks i64-params (opt-divrem-cast-blocks))]
    [rhs-redefined-before-branch : CompilerIrBlockList
      (opt-divrem-safety-blocks
        i64-params
        (opt-divrem-rhs-redefined-before-branch-blocks))]
    [rhs-redefined-in-safe : CompilerIrBlockList
      (opt-divrem-safety-blocks
        i64-params
        (opt-divrem-rhs-redefined-in-safe-blocks))]
    [safe-unused : CompilerIrBlockList
      (opt-divrem-dce-blocks
        i64-params
        (opt-divrem-branch-blocks
          (CompilerIrBinOp.Gt)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (CompilerIrBinOp.Div)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.I64)
          false)
        4)]
    [unproven-unused : CompilerIrBlockList
      (opt-divrem-dce-blocks
        i64-params
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "entry")
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                2
                (CompilerIrBinOp.Div)
                (CompilerIrValue.Var 0)
                (CompilerIrValue.Var 1)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
                CompilerIrInstrList.Nil)))
          CompilerIrBlockList.Nil)
        4)]
    (begin
      (unless
        (=
          (opt-count-binop-op-blocks signed-positive (CompilerIrBinOp.SafeDiv))
          1)
        (return 1))
      (unless
        (= (opt-count-binop-op-blocks signed-positive (CompilerIrBinOp.Div)) 0)
        (return 2))
      (unless
        (=
          (opt-count-binop-op-blocks
            signed-mod-positive
            (CompilerIrBinOp.SafeMod))
          1)
        (return 3))
      (unless
        (=
          (opt-count-binop-op-blocks unsigned-nonzero (CompilerIrBinOp.SafeDiv))
          1)
        (return 4))
      (unless
        (= (opt-count-binop-op-blocks lhs-not-min (CompilerIrBinOp.SafeDiv)) 1)
        (return 5))
      (unless
        (= (opt-count-binop-op-blocks zero-reachable (CompilerIrBinOp.Div)) 1)
        (return 6))
      (unless
        (=
          (opt-count-binop-op-blocks neg-one-reachable (CompilerIrBinOp.Div))
          1)
        (return 7))
      (unless
        (=
          (opt-count-binop-op-blocks weak-negative-range (CompilerIrBinOp.Div))
          1)
        (return 8))
      (unless
        (= (opt-count-binop-op-blocks cast-unsupported (CompilerIrBinOp.Div)) 1)
        (return 9))
      (unless
        (=
          (opt-count-binop-op-blocks
            rhs-redefined-before-branch
            (CompilerIrBinOp.Div))
          1)
        (return 10))
      (unless
        (=
          (opt-count-binop-op-blocks
            rhs-redefined-in-safe
            (CompilerIrBinOp.Div))
          1)
        (return 11))
      (unless
        (= (opt-count-binop-op-blocks safe-unused (CompilerIrBinOp.SafeDiv)) 0)
        (return 12))
      (unless
        (= (opt-count-binop-op-blocks safe-unused (CompilerIrBinOp.Div)) 0)
        (return 13))
      (unless
        (= (opt-count-binop-op-blocks unproven-unused (CompilerIrBinOp.Div)) 1)
        (return 14))
      42)))

;; `[BinOp v2 = v0 + v1, BinOp v3 = v0 + v1]` with non-constant operands: CSE
;; rewrites the second into `Mov v3 = v2` (two arithmetic instrs -> one).
(define (opt-cse-self-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BinOp
      2
      (CompilerIrBinOp.Add)
      (CompilerIrValue.Var 0)
      (CompilerIrValue.Var 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        3
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 1)
        (AstType.I64))
      (CompilerIrInstrList.Nil))))

(define (opt-cse-sqrt-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.UnOp
      2
      (CompilerIrUnOp.Sqrt)
      (CompilerIrValue.Var 0)
      (AstType.F64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.UnOp
        3
        (CompilerIrUnOp.Sqrt)
        (CompilerIrValue.Var 0)
        (AstType.F64))
      (CompilerIrInstrList.Nil))))

;; A store between the two identical expressions clears the table, so the second
;; expression is preserved (no cross-store CSE).
(define (opt-cse-store-clears-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BinOp
      2
      (CompilerIrBinOp.Add)
      (CompilerIrValue.Var 0)
      (CompilerIrValue.Var 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Store
        (opt-test-symbol "g")
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          3
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.I64))
        (CompilerIrInstrList.Nil)))))

;; Redefining an operand (`v0`) between the two expressions invalidates the
;; available entry, so the second expression is preserved (correctness on
;; non-SSA IR).
(define (opt-cse-operand-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BinOp
      2
      (CompilerIrBinOp.Add)
      (CompilerIrValue.Var 0)
      (CompilerIrValue.Var 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 5) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          3
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.I64))
        (CompilerIrInstrList.Nil)))))

(define (opt-cse-probe-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.CpuId 2 (CompilerIrValue.Var 0) (CompilerIrValue.I64 0) 1)
    (compiler-ir-instr-cons
      (CompilerIrInstr.CpuId
        3
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        1)
      (compiler-ir-instr-cons
        (CompilerIrInstr.Xgetbv 4 (CompilerIrValue.I64 0))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Xgetbv 5 (CompilerIrValue.I64 0))
          (CompilerIrInstrList.Nil))))))

(define (opt-cse-probe-different-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.CpuId 2 (CompilerIrValue.I64 7) (CompilerIrValue.I64 0) 1)
    (compiler-ir-instr-cons
      (CompilerIrInstr.CpuId
        3
        (CompilerIrValue.I64 7)
        (CompilerIrValue.I64 0)
        2)
      (compiler-ir-instr-cons
        (CompilerIrInstr.CpuId
          4
          (CompilerIrValue.I64 7)
          (CompilerIrValue.I64 1)
          1)
        (compiler-ir-instr-cons
          (CompilerIrInstr.Xgetbv 5 (CompilerIrValue.I64 0))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Xgetbv 6 (CompilerIrValue.I64 1))
            (CompilerIrInstrList.Nil)))))))

;; Returns 42 when CSE eliminates the repeated pure expression (2 arithmetic
;; instrs -> 1) yet preserves the second expression both across an intervening
;; store and across an operand redefinition (still 2 arithmetic instrs each).
;; It also CSEs identical CPU probes while preserving probes with different
;; register indices or operands.
;; Self-test: const-global propagation. Verifies the immutability proof
;; (literal-init globals enter the table; stored, non-literal, address-taken, and
;; zero-valued globals are excluded) and the binop-operand rewrite (uses of a
;; proven constant global -- both ordinary operands and div/mod divisors -- become
;; literals; excluded globals are left as hidden loads).
(defstruct OptConstDivisorTestSymbols
  (konst i64)
  (mutable i64)
  (uninit i64)
  (borrowed i64)
  (zero i64)
  (big i64))

(define (opt-const-divisor-test-symbols) : OptConstDivisorTestSymbols
  (OptConstDivisorTestSymbols
    (opt-test-symbol "konst")
    (opt-test-symbol "mut")
    (opt-test-symbol "uninit")
    (opt-test-symbol "borrowed")
    (opt-test-symbol "zero")
    (opt-test-symbol "big")))

(define (opt-const-divisor-test-globals [symbols : OptConstDivisorTestSymbols]) : CompilerIrGlobalList
  (compiler-ir-global-cons
    (CompilerIrGlobal.Global
      (struct-get symbols konst)
      (AstType.I64)
      (CompilerIrValue.I64 1000000007))
    (compiler-ir-global-cons
      (CompilerIrGlobal.Global
        (struct-get symbols mutable)
        (AstType.I64)
        (CompilerIrValue.I64 7))
      (compiler-ir-global-cons
        (CompilerIrGlobal.Global
          (struct-get symbols uninit)
          (AstType.I64)
          (CompilerIrValue.Unit))
        (compiler-ir-global-cons
          (CompilerIrGlobal.Global
            (struct-get symbols borrowed)
            (AstType.I64)
            (CompilerIrValue.I64 99))
          (compiler-ir-global-cons
            (CompilerIrGlobal.Global
              (struct-get symbols zero)
              (AstType.I64)
              (CompilerIrValue.I64 0))
            (compiler-ir-global-cons
              (CompilerIrGlobal.Global
                (struct-get symbols big)
                (AstType.I64)
                (CompilerIrValue.I64 4294967295))
              CompilerIrGlobalList.Nil)))))))

(define (opt-const-divisor-test-blocks [symbols : OptConstDivisorTestSymbols]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        ;; mod by a proven constant global -> rewritten to its literal divisor
        (CompilerIrInstr.BinOp
          10
          (CompilerIrBinOp.Mod)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Global (struct-get symbols konst))
          (AstType.I64))
        (compiler-ir-instr-cons
          ;; mod by a written global -> must NOT be rewritten
          (CompilerIrInstr.BinOp
            11
            (CompilerIrBinOp.Mod)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Global (struct-get symbols mutable))
            (AstType.I64))
          (compiler-ir-instr-cons
            ;; div by a non-literal (init-function) global -> must NOT be rewritten
            (CompilerIrInstr.BinOp
              12
              (CompilerIrBinOp.Div)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Global (struct-get symbols uninit))
              (AstType.I64))
            (compiler-ir-instr-cons
              ;; ordinary operand use of the constant global -> rewritten (general)
              (CompilerIrInstr.BinOp
                13
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 0)
                (CompilerIrValue.Global (struct-get symbols konst))
                (AstType.I64))
              (compiler-ir-instr-cons
                ;; use of an address-taken global -> must NOT be rewritten
                (CompilerIrInstr.BinOp
                  14
                  (CompilerIrBinOp.BitAnd)
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.Global (struct-get symbols borrowed))
                  (AstType.I64))
                (compiler-ir-instr-cons
                  ;; use of a zero-valued global -> must NOT be rewritten
                  (CompilerIrInstr.BinOp
                    15
                    (CompilerIrBinOp.BitAnd)
                    (CompilerIrValue.Var 0)
                    (CompilerIrValue.Global (struct-get symbols zero))
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    ;; use of a >imm32 global -> must NOT be rewritten
                    (CompilerIrInstr.BinOp
                      16
                      (CompilerIrBinOp.BitAnd)
                      (CompilerIrValue.Var 0)
                      (CompilerIrValue.Global (struct-get symbols big))
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      ;; taking the address disqualifies "borrowed"
                      (CompilerIrInstr.Mov
                        20
                        (CompilerIrValue.GlobalAddr
                          (struct-get symbols borrowed))
                        (AstType.U64))
                      (compiler-ir-instr-cons
                        ;; the store disqualifies "mut"
                        (CompilerIrInstr.Store
                          (struct-get symbols mutable)
                          (CompilerIrValue.I64 9)
                          (AstType.I64))
                        (compiler-ir-instr-cons
                          (CompilerIrInstr.Return
                            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 10)))
                          CompilerIrInstrList.Nil)))))))))))
    CompilerIrBlockList.Nil))

(define (opt-const-divisor-test-rhs-in-seq
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [count : i64]
  [dst : i64]) : CompilerIrValue
  (if (>= index count)
    (CompilerIrValue.Unit)
    (match (compiler-ir-instr-seq-ref instrs index)
      [(CompilerIrInstr.BinOp d _ _ rhs _)
        (if (= d dst)
          rhs
          (opt-const-divisor-test-rhs-in-seq instrs (+ index 1) count dst))]
      [_ (opt-const-divisor-test-rhs-in-seq instrs (+ index 1) count dst)])))

(define (opt-const-divisor-test-rhs [blocks : CompilerIrBlockList] [dst : i64]) : CompilerIrValue
  (match blocks
    [(CompilerIrBlockList.Nil) (CompilerIrValue.Unit)]
    [(CompilerIrBlockList.Cons block _)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (opt-const-divisor-test-rhs-in-seq
            instrs
            0
            (compiler-ir-instr-seq-count instrs)
            dst)])]
    [(CompilerIrBlockList.Array seq)
      (opt-const-divisor-test-rhs (compiler-ir-block-seq-to-list seq) dst)]))

(define (opt-const-divisor-test-is-i64? [v : CompilerIrValue] [n : i64]) : bool
  (match v
    [(CompilerIrValue.I64 m) (= m n)]
    [_ false]))

(define (opt-const-divisor-test-is-global?
  [v : CompilerIrValue]
  [name : String]) : bool
  (match v
    [(CompilerIrValue.Global m) (string.eq (compiler-ir-symbol-text m) name)]
    [_ false]))

(define (compiler-optimize-const-divisor-self-test) : i64
  (let
    [symbols : OptConstDivisorTestSymbols (opt-const-divisor-test-symbols)]
    [globals : CompilerIrGlobalList (opt-const-divisor-test-globals symbols)]
    [blocks : CompilerIrBlockList (opt-const-divisor-test-blocks symbols)]
    [functions : CompilerIrFunctionList
      (compiler-ir-function-cons
        (CompilerIrFunction.Function
          (opt-test-symbol "f")
          CompilerIrParamList.Nil
          (AstType.I64)
          16
          blocks)
        CompilerIrFunctionList.Nil)]
    [table : opt_i64_i64_map.Map (opt-const-divisors-build globals functions)]
    [rewritten : CompilerIrBlockList
      (opt-const-divisor-rewrite-blocks table blocks)]
    (cond
      [(not (opt_i64_i64_map.contains? (& table) (struct-get symbols konst))) 1]
      [(not
          (match (opt_i64_i64_map.get (& table) (struct-get symbols konst))
            [(opt_i64_i64_map.LookupFound n) (= n 1000000007)]
            [(opt_i64_i64_map.LookupMissing) false]))
        2]
      [(opt_i64_i64_map.contains? (& table) (struct-get symbols mutable)) 3]
      [(opt_i64_i64_map.contains? (& table) (struct-get symbols uninit)) 4]
      [(opt_i64_i64_map.contains? (& table) (struct-get symbols borrowed)) 5]
      [(opt_i64_i64_map.contains? (& table) (struct-get symbols zero)) 6]
      [(not
          (opt-const-divisor-test-is-i64?
            (opt-const-divisor-test-rhs rewritten 10)
            1000000007))
        7]
      [(not
          (opt-const-divisor-test-is-i64?
            (opt-const-divisor-test-rhs rewritten 13)
            1000000007))
        8]
      [(not
          (opt-const-divisor-test-is-global?
            (opt-const-divisor-test-rhs rewritten 11)
            "mut"))
        9]
      [(not
          (opt-const-divisor-test-is-global?
            (opt-const-divisor-test-rhs rewritten 12)
            "uninit"))
        10]
      [(not
          (opt-const-divisor-test-is-global?
            (opt-const-divisor-test-rhs rewritten 14)
            "borrowed"))
        11]
      [(not
          (opt-const-divisor-test-is-global?
            (opt-const-divisor-test-rhs rewritten 15)
            "zero"))
        12]
      [(opt_i64_i64_map.contains?
          (& table)
          (compiler-ir-symbol-id (struct-get symbols big)))
        13]
      [(not
          (opt-const-divisor-test-is-global?
            (opt-const-divisor-test-rhs rewritten 16)
            "big"))
        14]
      [else 42])))

(define (compiler-optimize-cse-self-test) : i64
  (let
    [cse : CompilerIrInstrList
      (opt-cse-instrs (OptExprTable.Nil) (opt-cse-self-test-instrs))]
    [sqrt : CompilerIrInstrList
      (opt-cse-instrs (OptExprTable.Nil) (opt-cse-sqrt-instrs))]
    [store : CompilerIrInstrList
      (opt-cse-instrs (OptExprTable.Nil) (opt-cse-store-clears-instrs))]
    [redef : CompilerIrInstrList
      (opt-cse-instrs (OptExprTable.Nil) (opt-cse-operand-redef-instrs))]
    [probe : CompilerIrInstrList
      (opt-cse-instrs (OptExprTable.Nil) (opt-cse-probe-instrs))]
    [probe-different : CompilerIrInstrList
      (opt-cse-instrs (OptExprTable.Nil) (opt-cse-probe-different-instrs))]
    (begin
      (unless (= (opt-count-arith-instrs cse) 1) (return 1))
      (unless (= (opt-mov-src-var sqrt 3 (- 0 1)) 2) (return 10))
      (unless (= (opt-count-arith-instrs store) 2) (return 2))
      (unless (= (opt-count-arith-instrs redef) 2) (return 3))
      (unless (= (opt-count-cpuid-instrs probe) 1) (return 4))
      (unless (= (opt-mov-src-var probe 3 (- 0 1)) 2) (return 5))
      (unless (= (opt-count-xgetbv-instrs probe) 1) (return 6))
      (unless (= (opt-mov-src-var probe 5 (- 0 1)) 4) (return 7))
      (unless (= (opt-count-cpuid-instrs probe-different) 3) (return 8))
      (unless (= (opt-count-xgetbv-instrs probe-different) 2) (return 9))
      42)))

;; --- cross-block GVN self-tests ---------------------------------------------
(define (opt-gvn-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "a" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "b" (AstType.I64) 1)
      (CompilerIrParamList.Nil))))

(define (opt-gvn-count-binops-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-arith-instr-seq instrs)
            (opt-gvn-count-binops-blocks (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-gvn-count-binops-blocks (compiler-ir-block-seq-to-list seq))]))

;; Diamond: `a + b` computed in the entry block and recomputed in the
;; post-dominating join. The entry strictly dominates the join, so the join's
;; expression is rewritten to a copy and the binop count drops from 2 to 1.
(define (opt-gvn-diamond-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          10
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "l")
            (compiler-ir-label "r"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "l")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "j"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "r")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "j"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "j")
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                11
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 0)
                (CompilerIrValue.Var 1)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 11)))
                (CompilerIrInstrList.Nil))))
          (CompilerIrBlockList.Nil))))))

;; Two sibling arms each compute `a + b`, and the join recomputes it. Neither arm
;; strictly dominates the join, so no cross-block CSE fires and all 3 binops stay.
(define (opt-gvn-siblings-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 0)
          (compiler-ir-label "l")
          (compiler-ir-label "r"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "l")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            10
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "j"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "r")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              11
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "j"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "j")
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                12
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 0)
                (CompilerIrValue.Var 1)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 12)))
                (CompilerIrInstrList.Nil))))
          (CompilerIrBlockList.Nil))))))

;; The shared operand `v2` is reassigned in each block, so it has two value
;; sources and is not stable. Even though the entry dominates the join, the two
;; `v0 + v2` expressions compute different values and must not be CSE'd: 2 binops.
(define (opt-gvn-redef-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 5) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            10
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 2)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "j"))
            (CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "j")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 7) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              11
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 2)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 11)))
              (CompilerIrInstrList.Nil)))))
      (CompilerIrBlockList.Nil))))

;; Loop: the header computes `a + b` and the body recomputes it. The header
;; strictly dominates the body, so the body's expression is rewritten: 2 -> 1.
(define (opt-gvn-loop-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "h"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "h")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            10
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              11
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "h"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 10)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-gvn-probe-dominated-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.CpuId
          20
          (CompilerIrValue.I64 7)
          (CompilerIrValue.I64 0)
          1)
        (compiler-ir-instr-cons
          (CompilerIrInstr.Xgetbv 21 (CompilerIrValue.I64 0))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "use"))
            (CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.CpuId
            22
            (CompilerIrValue.I64 7)
            (CompilerIrValue.I64 0)
            1)
          (compiler-ir-instr-cons
            (CompilerIrInstr.Xgetbv 23 (CompilerIrValue.I64 0))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 23)))
              (CompilerIrInstrList.Nil)))))
      (CompilerIrBlockList.Nil))))

(define (opt-gvn-probe-different-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.CpuId
          20
          (CompilerIrValue.I64 7)
          (CompilerIrValue.I64 0)
          1)
        (compiler-ir-instr-cons
          (CompilerIrInstr.Xgetbv 21 (CompilerIrValue.I64 0))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "use"))
            (CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.CpuId
            22
            (CompilerIrValue.I64 7)
            (CompilerIrValue.I64 0)
            2)
          (compiler-ir-instr-cons
            (CompilerIrInstr.CpuId
              23
              (CompilerIrValue.I64 7)
              (CompilerIrValue.I64 1)
              1)
            (compiler-ir-instr-cons
              (CompilerIrInstr.Xgetbv 24 (CompilerIrValue.I64 1))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 24)))
                (CompilerIrInstrList.Nil))))))
      (CompilerIrBlockList.Nil))))

;; Returns 42 only when cross-block GVN rewrites dominated repeats (diamond and
;; loop drop to 1 binop), leaves non-dominating siblings alone (3 binops), and
;; refuses to CSE across a reassigned operand (2 binops). CPU probes are reused
;; only when an identical probe is available from a strict dominator.
(define (compiler-optimize-gvn-self-test) : i64
  (let
    [probe : CompilerIrBlockList
      (opt-gvn-blocks (opt-gvn-test-params) (opt-gvn-probe-dominated-blocks))]
    [probe-different : CompilerIrBlockList
      (opt-gvn-blocks (opt-gvn-test-params) (opt-gvn-probe-different-blocks))]
    (begin
      (unless
        (=
          (opt-gvn-count-binops-blocks
            (opt-gvn-blocks (opt-gvn-test-params) (opt-gvn-diamond-blocks)))
          1)
        (return 1))
      (unless
        (=
          (opt-gvn-count-binops-blocks
            (opt-gvn-blocks (opt-gvn-test-params) (opt-gvn-siblings-blocks)))
          3)
        (return 2))
      (unless
        (=
          (opt-gvn-count-binops-blocks
            (opt-gvn-blocks (opt-gvn-test-params) (opt-gvn-redef-blocks)))
          2)
        (return 3))
      (unless
        (=
          (opt-gvn-count-binops-blocks
            (opt-gvn-blocks (opt-gvn-test-params) (opt-gvn-loop-blocks)))
          1)
        (return 4))
      (unless (= (opt-count-cpuid-blocks probe) 1) (return 5))
      (unless (= (opt-blocks-mov-src-var probe 22 (- 0 1)) 20) (return 6))
      (unless (= (opt-count-xgetbv-blocks probe) 1) (return 7))
      (unless (= (opt-blocks-mov-src-var probe 23 (- 0 1)) 21) (return 8))
      (unless (= (opt-count-cpuid-blocks probe-different) 3) (return 9))
      (unless (= (opt-count-xgetbv-blocks probe-different) 2) (return 10))
      42)))

(define (opt-word-instr-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Word _ _ _ _) 1]
    [_ 0]))

(define (opt-count-word-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-word-instr-seq-from
      slots
      (+ index 1)
      count
      (+ acc (opt-word-instr-count (array-ref slots index))))))

(define (opt-count-word-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-word-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-words-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-word-instr-seq instrs)
            (opt-count-words-blocks (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-words-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-pack-instr-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Pack _ _ _) 1]
    [_ 0]))

(define (opt-count-pack-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-pack-instr-seq-from
      slots
      (+ index 1)
      count
      (+ acc (opt-pack-instr-count (array-ref slots index))))))

(define (opt-count-pack-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-pack-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-packs-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-pack-instr-seq instrs)
            (opt-count-packs-blocks (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-packs-blocks (compiler-ir-block-seq-to-list seq))]))

;; A Pack whose extractions all fold block-locally leaves the group unused:
;; the array-backed pipeline DCE must retire it (the map-backed DCE always
;; did; the array mirror was missing the Pack/Word arms).
(define (opt-dce-pack-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Pack
          10
          (compiler-ir-value-cons
            (CompilerIrValue.Var 0)
            (compiler-ir-value-cons
              (CompilerIrValue.Var 1)
              CompilerIrValueList.Nil))
          (AstType.Struct (intern "Pair")))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Word 11 (CompilerIrValue.Var 10) 0 (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Word 12 (CompilerIrValue.Var 10) 1 (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                13
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 11)
                (CompilerIrValue.Var 12)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 13)))
                (CompilerIrInstrList.Nil)))))))
    (CompilerIrBlockList.Nil)))

;; Returns 42 only when the full pipeline folds both extractions block-locally
;; and retires the now-unused Pack (0 Words and 0 Packs remain).
(define (compiler-optimize-dce-pack-self-test) : i64
  (match (optimize-function-once
    (CompilerIrFunction.Function
      (opt-test-symbol "dce_pack")
      (opt-gvn-test-params)
      (AstType.I64)
      16
      (opt-dce-pack-blocks)))
    [(CompilerIrFunction.Function _ _ _ _ optimized-blocks)
      (begin
        (unless (= (opt-count-words-blocks optimized-blocks) 0) (return 1))
        (unless (= (opt-count-packs-blocks optimized-blocks) 0) (return 2))
        42)]))

(define (opt-instr-compare-dst? [instr : CompilerIrInstr] [dst : i64]) : bool
  (match instr
    [(CompilerIrInstr.BinOp d op _ _ _)
      (and (= d dst) (opt-bool-branch-compare-op? op))]
    [_ false]))

(define (opt-block-instr-at [block : CompilerIrBlock] [index : i64]) : CompilerIrInstr
  (match block
    [(CompilerIrBlock.Block _ instrs) (compiler-ir-instr-seq-ref instrs index)]))

(define (opt-block-instr-count [block : CompilerIrBlock]) : i64
  (match block
    [(CompilerIrBlock.Block _ instrs) (compiler-ir-instr-seq-count instrs)]))

;; The counted-fill shape: the loop-closing compare sits one flag-safe
;; pointer-increment Gep away from its branch. Sinking moves it adjacent so
;; the backend can fuse cmp;jcc.
(define (opt-cmp-sink-test-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "loop")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          5
          (CompilerIrBinOp.Lt)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            6
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 8)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 5)
              (compiler-ir-label "t")
              (compiler-ir-label "f"))
            (CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "t")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "f")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
            (CompilerIrInstrList.Nil)))
        (CompilerIrBlockList.Nil)))))

;; Same shape, but the intervening instruction redefines a compare operand:
;; the compare must stay put.
(define (opt-cmp-sink-blocked-test-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "loop")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          5
          (CompilerIrBinOp.Lt)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            0
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 5)
              (compiler-ir-label "t")
              (compiler-ir-label "f"))
            (CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "t")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "f")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
            (CompilerIrInstrList.Nil)))
        (CompilerIrBlockList.Nil)))))

;; Returns 42 only when the movable compare lands right before the branch and
;; the operand-clobbering one stays at index 0.
(define (compiler-optimize-cmp-sink-self-test) : i64
  (match (opt-cmp-sink-blocks-pass (opt-cmp-sink-test-blocks))
    [(OptBlockListPassResult.Result moved-blocks moved-changed)
      (match moved-blocks
        [(CompilerIrBlockList.Cons moved _)
          (match (opt-cmp-sink-blocks-pass (opt-cmp-sink-blocked-test-blocks))
            [(OptBlockListPassResult.Result stayed-blocks stayed-changed)
              (match stayed-blocks
                [(CompilerIrBlockList.Cons stayed _)
                  (begin
                    (unless moved-changed (return 1))
                    (when stayed-changed (return 2))
                    (unless
                      (opt-instr-compare-dst?
                        (opt-block-instr-at
                          moved
                          (- (opt-block-instr-count moved) 2))
                        5)
                      (return 3))
                    (unless
                      (opt-instr-compare-dst? (opt-block-instr-at stayed 0) 5)
                      (return 4))
                    42)]
                [_ 5])])]
        [_ 6])]))

(define (opt-successor-sink-test-function
  [name : String]
  [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol name)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "cond" (AstType.Bool) 0)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "value" (AstType.I64) 1)
        CompilerIrParamList.Nil))
    (AstType.I64)
    16
    blocks))

;; Both producers start in `entry`. Backward planning first moves the Pack whose
;; Word use is in `use`, then recognizes that the Load's only remaining use is
;; in that already-moved Pack and moves the Load ahead of it.
(define (opt-successor-sink-positive-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Pack
            3
            (compiler-ir-value-cons
              (CompilerIrValue.Var 2)
              CompilerIrValueList.Nil)
            (AstType.Struct (intern "OneWord")))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "use")
              (compiler-ir-label "other"))
            CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Word 4 (CompilerIrValue.Var 3) 0 (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "other")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

;; The payload address uses a two-instruction address chain that is also needed
;; by the tag load in the dispatch block. Sinking the payload Load therefore
;; moves v4 but clones v3 and, transitively, v2 with fresh ids 16 and 17.
(define (opt-successor-sink-remat-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Mul)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 16)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            3
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 2)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              4
              (CompilerIrValue.Var 3)
              (CompilerIrValue.I64 8)
              (AstType.U8))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 5 (CompilerIrValue.Var 4) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 6 (CompilerIrValue.Var 3) (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Switch
                    (CompilerIrValue.Var 6)
                    0
                    (compiler-ir-switch-case-cons
                      0
                      (compiler-ir-label "other")
                      CompilerIrSwitchCaseList.Nil)
                    (compiler-ir-label "use"))
                  CompilerIrInstrList.Nil)))))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 5)))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "other")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 6)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

;; v2 is a source-block Mov with uses in both paths. It cannot move and is not
;; in the Gep/BinOp rematerialization whitelist, so neither consumer may sink.
(define (opt-successor-sink-live-range-blocked-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 2)
              (CompilerIrValue.I64 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Var 0)
                (compiler-ir-label "use")
                (compiler-ir-label "other"))
              CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "other")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

;; v2 is external to `entry`, but the key address/load/compare makes it part of
;; the terminator dependency slice. The sibling payload Gep/Load may therefore
;; move to the matching arm without rematerializing that already-live leaf.
(define (opt-successor-sink-terminator-live-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "preheader")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "entry"))
          CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            3
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 0)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 4 (CompilerIrValue.Var 3) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                5
                (CompilerIrValue.Var 2)
                (CompilerIrValue.I64 8)
                (AstType.U8))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 6 (CompilerIrValue.Var 5) (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    7
                    (CompilerIrBinOp.Eq)
                    (CompilerIrValue.Var 4)
                    (CompilerIrValue.I64 1)
                    (AstType.Bool))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Branch
                      (CompilerIrValue.Var 7)
                      (compiler-ir-label "use")
                      (compiler-ir-label "other"))
                    CompilerIrInstrList.Nil)))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "use")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 6)))
            CompilerIrInstrList.Nil))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "other")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

;; v2 is defined in a predecessor and is not otherwise live in either
;; successor. Moving the source-block address producer would extend v2's live
;; range, while cloning it would do the same, so the payload Load must stay.
(define (opt-successor-sink-external-leaf-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "preheader")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "entry"))
          CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            3
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 8)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 4 (CompilerIrValue.Var 3) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Var 0)
                (compiler-ir-label "use")
                (compiler-ir-label "other"))
              CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "use")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
            CompilerIrInstrList.Nil))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "other")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

;; Sinking v8 would require cloning v6..v2. The fifth clone exceeds the cap;
;; the whole transaction, including its tentative fresh frame ids, rolls back.
(define (opt-successor-sink-remat-cap-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            3
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 3)
              (CompilerIrValue.I64 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                5
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 4)
                (CompilerIrValue.I64 1)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  6
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 5)
                  (CompilerIrValue.I64 1)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Gep
                    7
                    (CompilerIrValue.Var 6)
                    (CompilerIrValue.I64 0)
                    (AstType.U8))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Load
                      8
                      (CompilerIrValue.Var 7)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.BinOp
                        9
                        (CompilerIrBinOp.Add)
                        (CompilerIrValue.Var 6)
                        (CompilerIrValue.I64 1)
                        (AstType.I64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Switch
                          (CompilerIrValue.Var 9)
                          0
                          (compiler-ir-switch-case-cons
                            0
                            (compiler-ir-label "other")
                            CompilerIrSwitchCaseList.Nil)
                          (compiler-ir-label "use"))
                        CompilerIrInstrList.Nil))))))))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 8)))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "other")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 9)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

;; Strength-reduced loop-pointer form used by vm_run. The dead block-local Mul
;; is the retained rematerialization recipe; v12 itself must not reach `use`.
(define (opt-successor-sink-induction-remat-blocks-with-step [step : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "preheader")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          10
          (CompilerIrBinOp.Mul)
          (CompilerIrValue.I64 0)
          (CompilerIrValue.I64 16)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            11
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 10)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "header"))
            CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "header")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            12
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 11)
              (compiler-ir-label "preheader")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 13)
                (compiler-ir-label "merge")
                CompilerIrPhiInputList.Nil))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              2
              (compiler-ir-phi-input-cons
                (CompilerIrValue.I64 0)
                (compiler-ir-label "preheader")
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 3)
                  (compiler-ir-label "merge")
                  CompilerIrPhiInputList.Nil))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                4
                (CompilerIrBinOp.Mul)
                (CompilerIrValue.Var 2)
                (CompilerIrValue.I64 16)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Gep
                  5
                  (CompilerIrValue.Var 12)
                  (CompilerIrValue.I64 8)
                  (AstType.U8))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Load 6 (CompilerIrValue.Var 5) (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Gep
                      7
                      (CompilerIrValue.Var 12)
                      (CompilerIrValue.I64 0)
                      (AstType.U8))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Load
                        8
                        (CompilerIrValue.Var 7)
                        (AstType.I64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Switch
                          (CompilerIrValue.Var 8)
                          0
                          (compiler-ir-switch-case-cons
                            0
                            (compiler-ir-label "other")
                            CompilerIrSwitchCaseList.Nil)
                          (compiler-ir-label "use"))
                        CompilerIrInstrList.Nil)))))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "use")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 6)))
            CompilerIrInstrList.Nil))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "other")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "merge"))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "merge")
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  3
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 2)
                  (CompilerIrValue.I64 step)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Gep
                    13
                    (CompilerIrValue.Var 12)
                    (CompilerIrValue.I64 16)
                    (AstType.U8))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Jump (compiler-ir-label "header"))
                    CompilerIrInstrList.Nil))))
            CompilerIrBlockList.Nil))))))

(define (opt-successor-sink-induction-remat-blocks) : CompilerIrBlockList
  (opt-successor-sink-induction-remat-blocks-with-step 1))

;; v2 is read in both successors, so neither successor owns every use.
(define (opt-successor-sink-multi-use-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "left")
            (compiler-ir-label "right"))
          CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "left")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "right")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

;; `left` is a direct successor of entry but also reachable through `right`.
;; Entry still dominates it, keeping the fixture valid SSA, while its two
;; predecessors make it ineligible for sinking.
(define (opt-successor-sink-multi-pred-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "left")
            (compiler-ir-label "right"))
          CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "right")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "left"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "left")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

;; The StorePtr between the Load and terminator is an explicit first-cut load
;; barrier even though the loaded result is used in only one successor.
(define (opt-successor-sink-store-barrier-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 9)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "use")
              (compiler-ir-label "other"))
            CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "other")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

;; SafeDiv still has language-level abort semantics and must not be scheduled
;; conditionally, despite otherwise looking like a pure binary definition.
(define (opt-successor-sink-trapping-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.SafeDiv)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 2)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "use")
            (compiler-ir-label "other"))
          CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "other")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

(define (opt-successor-sink-instr-seq-defines?
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [dst : i64]) : bool
  (if (>= index (compiler-ir-instr-seq-count instrs))
    false
    (match (opt-instr-def-var (compiler-ir-instr-seq-ref instrs index))
      [(option_i64.Some found)
        (if (= found dst)
          true
          (opt-successor-sink-instr-seq-defines? instrs (+ index 1) dst))]
      [(option_i64.None)
        (opt-successor-sink-instr-seq-defines? instrs (+ index 1) dst)])))

(define (opt-successor-sink-def-label
  [blocks : CompilerIrBlockList]
  [dst : i64]
  [fallback : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) fallback]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block label instrs)
          (if (opt-successor-sink-instr-seq-defines? instrs 0 dst)
            label
            (opt-successor-sink-def-label (box-get rest) dst fallback))])]
    [(CompilerIrBlockList.Array seq)
      (opt-successor-sink-def-label
        (compiler-ir-block-seq-to-list seq)
        dst
        fallback)]))

(define (opt-successor-sink-run-function
  [name : String]
  [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (opt-successor-sink-function (opt-successor-sink-test-function name blocks)))

(define (opt-successor-sink-run [name : String] [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (opt-function-blocks (opt-successor-sink-run-function name blocks)))

(define (compiler-optimize-successor-sink-self-test) : i64
  (let
    [positive : CompilerIrBlockList
      (opt-successor-sink-run
        "successor_sink_positive"
        (opt-successor-sink-positive-blocks))]
    [remat-function : CompilerIrFunction
      (opt-successor-sink-run-function
        "successor_sink_remat"
        (opt-successor-sink-remat-blocks))]
    [remat : CompilerIrBlockList (opt-function-blocks remat-function)]
    [live-range-blocked : CompilerIrBlockList
      (opt-successor-sink-run
        "successor_sink_live_range_blocked"
        (opt-successor-sink-live-range-blocked-blocks))]
    [terminator-live : CompilerIrBlockList
      (opt-successor-sink-run
        "successor_sink_terminator_live"
        (opt-successor-sink-terminator-live-blocks))]
    [external-leaf-function : CompilerIrFunction
      (opt-successor-sink-run-function
        "successor_sink_external_leaf"
        (opt-successor-sink-external-leaf-blocks))]
    [external-leaf : CompilerIrBlockList
      (opt-function-blocks external-leaf-function)]
    [remat-cap-function : CompilerIrFunction
      (opt-successor-sink-run-function
        "successor_sink_remat_cap"
        (opt-successor-sink-remat-cap-blocks))]
    [remat-cap : CompilerIrBlockList (opt-function-blocks remat-cap-function)]
    [induction-input : CompilerIrBlockList
      (opt-successor-sink-induction-remat-blocks)]
    [induction-cell : (Array i64) (opt-used-array-new 1)]
    [_induction-cell-init : unit (array-set! induction-cell 0 16)]
    [induction-direct : CompilerIrBlockList
      (opt-successor-sink-blocks 16 induction-cell induction-input)]
    [induction-function : CompilerIrFunction
      (opt-successor-sink-run-function
        "successor_sink_induction_remat"
        (opt-successor-sink-induction-remat-blocks))]
    [induction : CompilerIrBlockList (opt-function-blocks induction-function)]
    [induction-step-two-function : CompilerIrFunction
      (opt-successor-sink-run-function
        "successor_sink_induction_step_two"
        (opt-successor-sink-induction-remat-blocks-with-step 2))]
    [induction-step-two : CompilerIrBlockList
      (opt-function-blocks induction-step-two-function)]
    [multi-use : CompilerIrBlockList
      (opt-successor-sink-run
        "successor_sink_multi_use"
        (opt-successor-sink-multi-use-blocks))]
    [multi-pred : CompilerIrBlockList
      (opt-successor-sink-run
        "successor_sink_multi_pred"
        (opt-successor-sink-multi-pred-blocks))]
    [store-barrier : CompilerIrBlockList
      (opt-successor-sink-run
        "successor_sink_store_barrier"
        (opt-successor-sink-store-barrier-blocks))]
    [trapping : CompilerIrBlockList
      (opt-successor-sink-run
        "successor_sink_trapping"
        (opt-successor-sink-trapping-blocks))]
    (begin
      (unless
        (=
          (opt-successor-sink-def-label positive 2 (compiler-ir-label-none))
          (compiler-ir-label "use"))
        (return 1))
      (unless
        (=
          (opt-successor-sink-def-label positive 3 (compiler-ir-label-none))
          (compiler-ir-label "use"))
        (return 2))
      (unless
        (=
          (opt-successor-sink-def-label multi-use 2 (compiler-ir-label-none))
          (compiler-ir-label "entry"))
        (return 3))
      (unless
        (=
          (opt-successor-sink-def-label multi-pred 2 (compiler-ir-label-none))
          (compiler-ir-label "entry"))
        (return 4))
      (unless
        (=
          (opt-successor-sink-def-label
            store-barrier
            2
            (compiler-ir-label-none))
          (compiler-ir-label "entry"))
        (return 5))
      (unless
        (=
          (opt-successor-sink-def-label trapping 2 (compiler-ir-label-none))
          (compiler-ir-label "entry"))
        (return 6))
      (unless (= (opt-function-frame remat-function) 18) (return 7))
      (unless
        (and
          (=
            (opt-successor-sink-def-label remat 2 (compiler-ir-label-none))
            (compiler-ir-label "entry"))
          (=
            (opt-successor-sink-def-label remat 3 (compiler-ir-label-none))
            (compiler-ir-label "entry"))
          (=
            (opt-successor-sink-def-label remat 4 (compiler-ir-label-none))
            (compiler-ir-label "use"))
          (=
            (opt-successor-sink-def-label remat 5 (compiler-ir-label-none))
            (compiler-ir-label "use"))
          (=
            (opt-successor-sink-def-label remat 16 (compiler-ir-label-none))
            (compiler-ir-label "use"))
          (=
            (opt-successor-sink-def-label remat 17 (compiler-ir-label-none))
            (compiler-ir-label "use")))
        (return 8))
      (unless
        (and
          (=
            (opt-successor-sink-def-label
              live-range-blocked
              3
              (compiler-ir-label-none))
            (compiler-ir-label "entry"))
          (=
            (opt-successor-sink-def-label
              live-range-blocked
              4
              (compiler-ir-label-none))
            (compiler-ir-label "entry")))
        (return 9))
      (unless
        (and
          (=
            (opt-successor-sink-def-label
              terminator-live
              5
              (compiler-ir-label-none))
            (compiler-ir-label "use"))
          (=
            (opt-successor-sink-def-label
              terminator-live
              6
              (compiler-ir-label-none))
            (compiler-ir-label "use")))
        (return 10))
      (unless
        (and
          (= (opt-function-frame external-leaf-function) 16)
          (=
            (opt-successor-sink-def-label
              external-leaf
              4
              (compiler-ir-label-none))
            (compiler-ir-label "entry")))
        (return 11))
      (unless (= (opt-function-frame remat-cap-function) 16) (return 12))
      (unless
        (=
          (opt-successor-sink-def-label remat-cap 8 (compiler-ir-label-none))
          (compiler-ir-label "entry"))
        (return 13))
      (unless
        (and
          (= (array-ref induction-cell 0) 18)
          (=
            (opt-successor-sink-def-label
              induction-direct
              6
              (compiler-ir-label-none))
            (compiler-ir-label "use"))
          (=
            (opt-successor-sink-def-label
              induction-direct
              5
              (compiler-ir-label-none))
            (compiler-ir-label "use"))
          (=
            (opt-successor-sink-def-label
              induction-direct
              16
              (compiler-ir-label-none))
            (compiler-ir-label "use"))
          (=
            (opt-successor-sink-def-label
              induction-direct
              17
              (compiler-ir-label-none))
            (compiler-ir-label "use")))
        (return 14))
      (unless
        (and
          (= (opt-function-frame induction-function) 18)
          (=
            (opt-successor-sink-def-label induction 6 (compiler-ir-label-none))
            (compiler-ir-label "use"))
          (=
            (opt-successor-sink-def-label induction 5 (compiler-ir-label-none))
            (compiler-ir-label "use"))
          (=
            (opt-successor-sink-def-label induction 16 (compiler-ir-label-none))
            (compiler-ir-label "use"))
          (=
            (opt-successor-sink-def-label induction 17 (compiler-ir-label-none))
            (compiler-ir-label "use")))
        (return 15))
      (unless
        (and
          (= (opt-function-frame induction-step-two-function) 16)
          (=
            (opt-successor-sink-def-label
              induction-step-two
              6
              (compiler-ir-label-none))
            (compiler-ir-label "use"))
          (=
            (opt-successor-sink-def-label
              induction-step-two
              5
              (compiler-ir-label-none))
            (compiler-ir-label "use"))
          (=
            (opt-successor-sink-def-label
              induction-step-two
              16
              (compiler-ir-label-none))
            (compiler-ir-label-none))
          (=
            (opt-successor-sink-def-label
              induction-step-two
              17
              (compiler-ir-label-none))
            (compiler-ir-label-none)))
        (return 16))
      42)))

;; Returns the lhs var id of the `BinOp` whose destination is `dst`, or -1 if it
;; is absent or its lhs is not a var. Used to inspect copy-propagation rewrites.
(define (opt-copy-binop-lhs-var [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) (- 0 1)]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.BinOp d _ l _ _)
          (if (= d dst)
            (match l
              [(CompilerIrValue.Var id) id]
              [_ (- 0 1)])
            (opt-copy-binop-lhs-var (box-get rest) dst))]
        [_ (opt-copy-binop-lhs-var (box-get rest) dst)])]))

(define (opt-copy-binop-lhs-var-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [dst : i64]) : i64
  (if (>= index count)
    (- 0 1)
    (match (array-ref slots index)
      [(CompilerIrInstr.BinOp actual _ lhs _ _)
        (if (= actual dst)
          (match lhs
            [(CompilerIrValue.Var id) id]
            [_ (- 0 1)])
          (opt-copy-binop-lhs-var-instr-seq-from slots (+ index 1) count dst))]
      [_ (opt-copy-binop-lhs-var-instr-seq-from slots (+ index 1) count dst)])))

(define (opt-copy-binop-lhs-var-instr-seq
  [instrs : CompilerIrInstrSeq]
  [dst : i64]) : i64
  (opt-copy-binop-lhs-var-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    dst))

;; `[Mov v1 = v0, BinOp v2 = v1 + 1]`: copy propagation rewrites the binop lhs
;; from v1 to v0.
(define (opt-copy-pos-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 1 (CompilerIrValue.Var 0) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        2
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (CompilerIrInstrList.Nil))))

;; `[Mov v1 = v0, Load v0 = *v9, BinOp v2 = v1 + 1]`: redefining the copy source
;; v0 invalidates the v1 -> v0 fact, so the binop lhs stays v1.
(define (opt-copy-src-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 1 (CompilerIrValue.Var 0) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 0 (CompilerIrValue.Var 9) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        (CompilerIrInstrList.Nil)))))

;; `[Mov v1 = v0, Load v1 = *v9, BinOp v2 = v1 + 1]`: redefining the copy
;; destination v1 invalidates the fact, so the binop lhs stays v1.
(define (opt-copy-dst-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 1 (CompilerIrValue.Var 0) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 1 (CompilerIrValue.Var 9) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        (CompilerIrInstrList.Nil)))))

;; `[BinOp v2 = v0 + v1, BinOp v3 = v0 + v1, BinOp v4 = v3 + 1, Return v4]`: CSE
;; rewrites the second expression to `Mov v3 = v2`; copy propagation then rewrites
;; the v4 lhs from v3 to v2, leaving the `Mov v3` copy dead for DCE to drop (the
;; `Return v4` keeps v4 live so only the copy is removed: 4 instrs -> 3).
(define (opt-copy-cse-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BinOp
      2
      (CompilerIrBinOp.Add)
      (CompilerIrValue.Var 0)
      (CompilerIrValue.Var 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        3
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          4
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 3)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
          (CompilerIrInstrList.Nil))))))

;; `[Mov v1 = 1.5f64, BinOp v2 = v1 + v1]`: an F64 source is not recorded as a
;; copy in this slice, so the binop lhs stays v1 (no unsafe literal propagation).
(define (opt-copy-f64-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov
      1
      (CompilerIrValue.F64 (opt-test-f64-bits "1.5"))
      (AstType.F64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        2
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 1)
        (CompilerIrValue.Var 1)
        (AstType.F64))
      (CompilerIrInstrList.Nil))))

(define (opt-copy-phi-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 1 (CompilerIrValue.Var 0) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Phi
        2
        (compiler-ir-phi-input-cons
          (CompilerIrValue.Var 1)
          (compiler-ir-label "left")
          CompilerIrPhiInputList.Nil)
        (AstType.I64))
      (CompilerIrInstrList.Nil))))

(define (opt-copy-pack-words [a : CompilerIrValue] [b : CompilerIrValue]) : CompilerIrValueList
  (compiler-ir-value-cons a (compiler-ir-value-cons b CompilerIrValueList.Nil)))

(define (opt-copy-pack-word-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Pack
      2
      (opt-copy-pack-words (CompilerIrValue.Var 0) (CompilerIrValue.Var 1))
      (AstType.Struct (intern "Pair")))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Word 3 (CompilerIrValue.Var 2) 0 (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Word 4 (CompilerIrValue.Var 2) 1 (AstType.I64))
        (CompilerIrInstrList.Nil)))))

(define (opt-copy-pack-source-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Pack
      2
      (opt-copy-pack-words (CompilerIrValue.Var 0) (CompilerIrValue.Var 1))
      (AstType.Struct (intern "Pair")))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 0 (CompilerIrValue.Var 9) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Word 3 (CompilerIrValue.Var 2) 0 (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Word 4 (CompilerIrValue.Var 2) 1 (AstType.I64))
          (CompilerIrInstrList.Nil))))))

(define (opt-copy-pack-dst-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Pack
      2
      (opt-copy-pack-words (CompilerIrValue.Var 0) (CompilerIrValue.Var 1))
      (AstType.Struct (intern "Pair")))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 2 (CompilerIrValue.Var 9) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Word 3 (CompilerIrValue.Var 2) 0 (AstType.I64))
        (CompilerIrInstrList.Nil)))))

(define (opt-copy-mov-src-var
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [fallback : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) fallback]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.Mov found src _)
          (if (= found dst)
            (match src
              [(CompilerIrValue.Var id) id]
              [_ fallback])
            (opt-copy-mov-src-var (box-get rest) dst fallback))]
        [_ (opt-copy-mov-src-var (box-get rest) dst fallback)])]))

(define (opt-copy-word-src-var
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [fallback : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) fallback]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.Word found src _ _)
          (if (= found dst)
            (match src
              [(CompilerIrValue.Var id) id]
              [_ fallback])
            (opt-copy-word-src-var (box-get rest) dst fallback))]
        [_ (opt-copy-word-src-var (box-get rest) dst fallback)])]))

(define (opt-phi-first-input-var
  [inputs : CompilerIrPhiInputList]
  [fallback : i64]) : i64
  (match (compiler-ir-phi-input-list-force-cons inputs)
    [(CompilerIrPhiInputList.Nil) fallback]
    [(CompilerIrPhiInputList.Array seq)
      (opt-phi-first-input-var (compiler-ir-phi-input-seq-to-list seq) fallback)]
    [(CompilerIrPhiInputList.Cons value _ _)
      (match value
        [(CompilerIrValue.Var id) id]
        [_ fallback])]))

(define (opt-phi-dst-first-input-var
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [fallback : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) fallback]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.Phi found inputs _)
          (if (= found dst)
            (opt-phi-first-input-var inputs fallback)
            (opt-phi-dst-first-input-var (box-get rest) dst fallback))]
        [_ (opt-phi-dst-first-input-var (box-get rest) dst fallback)])]))

;; Returns 42 when block-local copy propagation: rewrites a var copy into a later
;; use (pos: lhs v1 -> v0); does not propagate after the source (src-redef) or
;; destination (dst-redef) var is redefined; rewrites a CSE-introduced copy so
;; DCE can drop it (cse: lhs v3 -> v2, leaving 3 instrs); does not propagate an
;; unsafe F64 source (f64: lhs stays v1); and leaves phi inputs untouched because
;; they are edge operands rather than block-local value uses.
(define (compiler-optimize-copy-self-test) : i64
  (let
    [pos : CompilerIrInstrList
      (opt-copy-instrs (OptCopyEnv.Nil) (opt-copy-pos-instrs))]
    [src-redef : CompilerIrInstrList
      (opt-copy-instrs (OptCopyEnv.Nil) (opt-copy-src-redef-instrs))]
    [dst-redef : CompilerIrInstrList
      (opt-copy-instrs (OptCopyEnv.Nil) (opt-copy-dst-redef-instrs))]
    [cse : CompilerIrInstrList
      (opt-copy-instrs
        (OptCopyEnv.Nil)
        (opt-cse-instrs (OptExprTable.Nil) (opt-copy-cse-instrs)))]
    [cse-dce : CompilerIrInstrList
      (opt-dce-instrs
        (opt-collect-instrs-uses (opt_i64_i64_map.with-capacity 64) cse)
        cse)]
    [f64 : CompilerIrInstrList
      (opt-copy-instrs (OptCopyEnv.Nil) (opt-copy-f64-instrs))]
    [phi : CompilerIrInstrList
      (opt-copy-instrs (OptCopyEnv.Nil) (opt-copy-phi-instrs))]
    [pack-word : CompilerIrInstrList
      (opt-copy-instrs (OptCopyEnv.Nil) (opt-copy-pack-word-instrs))]
    [pack-source-redef : CompilerIrInstrList
      (opt-copy-instrs (OptCopyEnv.Nil) (opt-copy-pack-source-redef-instrs))]
    [pack-dst-redef : CompilerIrInstrList
      (opt-copy-instrs (OptCopyEnv.Nil) (opt-copy-pack-dst-redef-instrs))]
    (cond
      [(not (= (opt-copy-binop-lhs-var pos 2) 0)) 1]
      [(not (= (opt-copy-binop-lhs-var src-redef 2) 1)) 2]
      [(not (= (opt-copy-binop-lhs-var dst-redef 2) 1)) 3]
      [(not (= (opt-copy-binop-lhs-var cse 4) 2)) 4]
      [(not (= (compiler-ir-instr-list-count cse-dce) 3)) 5]
      [(not (= (opt-copy-binop-lhs-var f64 2) 1)) 6]
      [(not (= (opt-phi-dst-first-input-var phi 2 (- 0 1)) 1)) 7]
      [(not (= (opt-copy-mov-src-var pack-word 3 (- 0 1)) 0)) 8]
      [(not (= (opt-copy-mov-src-var pack-word 4 (- 0 1)) 1)) 9]
      [(not (= (opt-copy-word-src-var pack-source-redef 3 (- 0 1)) 2)) 10]
      [(not (= (opt-copy-mov-src-var pack-source-redef 4 (- 0 1)) 1)) 11]
      [(not (= (opt-copy-word-src-var pack-dst-redef 3 (- 0 1)) 2)) 12]
      [else 42])))

;; Count explicit trapping bounds checks after the dedicated bounds pass.
(define (opt-count-bounds-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.BoundsCheck _ _ _) 1]
          [_ 0])
        (opt-count-bounds-instrs (box-get rest)))]))

(define (opt-bounds-duplicate-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BoundsCheck
      (CompilerIrValue.Var 0)
      (CompilerIrValue.Var 1)
      (compiler-ir-label "bounds_ok.0"))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BoundsCheck
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 1)
        (compiler-ir-label "bounds_ok.1"))
      (CompilerIrInstrList.Nil))))

(define (opt-bounds-different-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BoundsCheck
      (CompilerIrValue.Var 0)
      (CompilerIrValue.Var 1)
      (compiler-ir-label "bounds_ok.0"))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BoundsCheck
        (CompilerIrValue.Var 1)
        (CompilerIrValue.Var 0)
        (compiler-ir-label "bounds_ok.1"))
      (CompilerIrInstrList.Nil))))

(define (opt-bounds-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BoundsCheck
      (CompilerIrValue.Var 0)
      (CompilerIrValue.Var 1)
      (compiler-ir-label "bounds_ok.0"))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 7) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BoundsCheck
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (compiler-ir-label "bounds_ok.1"))
        (CompilerIrInstrList.Nil)))))

(define (opt-bounds-call-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BoundsCheck
      (CompilerIrValue.Var 0)
      (CompilerIrValue.Var 1)
      (compiler-ir-label "bounds_ok.0"))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call
        9
        (opt-test-symbol "touch")
        (CompilerIrCallArgs.Nil)
        (AstType.Unit))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BoundsCheck
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (compiler-ir-label "bounds_ok.1"))
        (CompilerIrInstrList.Nil)))))

(define (opt-bounds-branch-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BoundsCheck
      (CompilerIrValue.Var 0)
      (CompilerIrValue.Var 1)
      (compiler-ir-label "bounds_ok.0"))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Branch
        (CompilerIrValue.Bool true)
        (compiler-ir-label "ok")
        (compiler-ir-label "fail"))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BoundsCheck
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (compiler-ir-label "bounds_ok.1"))
        (CompilerIrInstrList.Nil)))))

(define (opt-bounds-copy-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 2 (CompilerIrValue.Var 0) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BoundsCheck
        (CompilerIrValue.Var 2)
        (CompilerIrValue.Var 1)
        (compiler-ir-label "bounds_ok.0"))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BoundsCheck
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (compiler-ir-label "bounds_ok.1"))
        (CompilerIrInstrList.Nil)))))

(define (opt-bounds-dce-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 1) (AstType.U64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 2) (AstType.U64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BoundsCheck
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (compiler-ir-label "bounds_ok.0"))
        (CompilerIrInstrList.Nil)))))

;; Index-cast canonicalization: two accesses to the same logical index
;; (var0) and array (var1) each emit a fresh `Cast(_, I64->U64)` of var0 and a
;; fresh length load; the second bounds check is redundant. Without
;; canonicalization the distinct cast vars (10 vs 14) never match, so this case
;; pins the optimization (count 1).
(define (opt-bounds-index-cast-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Cast
      10
      (CompilerIrValue.Var 0)
      (AstType.I64)
      (AstType.U64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        11
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 12 (CompilerIrValue.Var 11) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Cast
            13
            (CompilerIrValue.Var 12)
            (AstType.I64)
            (AstType.U64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BoundsCheck
              (CompilerIrValue.Var 10)
              (CompilerIrValue.Var 13)
              (compiler-ir-label "bounds_ok.0"))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Cast
                14
                (CompilerIrValue.Var 0)
                (AstType.I64)
                (AstType.U64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Gep
                  15
                  (CompilerIrValue.Var 1)
                  (CompilerIrValue.I64 1)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Load
                    16
                    (CompilerIrValue.Var 15)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Cast
                      17
                      (CompilerIrValue.Var 16)
                      (AstType.I64)
                      (AstType.U64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.BoundsCheck
                        (CompilerIrValue.Var 14)
                        (CompilerIrValue.Var 17)
                        (compiler-ir-label "bounds_ok.1"))
                      (CompilerIrInstrList.Nil))))))))))))

;; Adversarial: redefining the index source (var0) between the two checks must
;; invalidate the canonicalized fact, so the second check is kept (count 2). A
;; `<=`-into-`<` or stale-source bug would wrongly drop it.
(define (opt-bounds-index-cast-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Cast
      10
      (CompilerIrValue.Var 0)
      (AstType.I64)
      (AstType.U64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        11
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 12 (CompilerIrValue.Var 11) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Cast
            13
            (CompilerIrValue.Var 12)
            (AstType.I64)
            (AstType.U64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BoundsCheck
              (CompilerIrValue.Var 10)
              (CompilerIrValue.Var 13)
              (compiler-ir-label "bounds_ok.0"))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 7) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Cast
                  14
                  (CompilerIrValue.Var 0)
                  (AstType.I64)
                  (AstType.U64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Gep
                    15
                    (CompilerIrValue.Var 1)
                    (CompilerIrValue.I64 1)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Load
                      16
                      (CompilerIrValue.Var 15)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Cast
                        17
                        (CompilerIrValue.Var 16)
                        (AstType.I64)
                        (AstType.U64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.BoundsCheck
                          (CompilerIrValue.Var 14)
                          (CompilerIrValue.Var 17)
                          (compiler-ir-label "bounds_ok.1"))
                        (CompilerIrInstrList.Nil)))))))))))))

(define (opt-bounds-cross-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BoundsCheck
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (compiler-ir-label "bounds_ok.0"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "next")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BoundsCheck
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            (compiler-ir-label "bounds_ok.1"))
          (CompilerIrInstrList.Nil)))
      (CompilerIrBlockList.Nil))))

(defstruct OptLoopBceTestSymbols
  (touch i64)
  (argc i64)
  (base i64))

(define (opt-loop-bce-test-symbols) : OptLoopBceTestSymbols
  (OptLoopBceTestSymbols
    (opt-test-symbol "touch")
    (opt-test-symbol "argc")
    (opt-test-symbol "base")))

(define (opt-loop-bce-test-summaries
  [symbols : OptLoopBceTestSymbols]
  [clean-touch : bool]
  [argc-return : bool]) : OptLoopBceSummaries
  (let
    [clean : opt_i64_i64_map.Map
      (if clean-touch
        (let
          [map : opt_i64_i64_map.Map (opt_i64_i64_map.with-capacity 8)]
          (begin
            (opt_i64_i64_map.insert-ref!
              (&mut map)
              (compiler-ir-symbol-id (struct-get symbols touch))
              1)
            map))
        (opt_i64_i64_map.with-capacity 8))]
    [argc : opt_i64_i64_map.Map
      (if argc-return
        (let
          [map : opt_i64_i64_map.Map (opt_i64_i64_map.with-capacity 8)]
          (begin
            (opt_i64_i64_map.insert-ref!
              (&mut map)
              (compiler-ir-symbol-id (struct-get symbols argc))
              1)
            map))
        (opt_i64_i64_map.with-capacity 8))]
    (OptLoopBceSummaries
      true
      clean
      clean
      (opt_i64_i64_map.with-capacity 8)
      argc
      (opt_i64_i64_map.with-capacity 8))))

(define (opt-loop-bce-test-entry-tail [init : i64]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 init) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Jump (compiler-ir-label "header"))
      (CompilerIrInstrList.Nil))))

(define (opt-loop-bce-test-entry-after-store
  [symbols : OptLoopBceTestSymbols]
  [init : i64]
  [with-call : bool]) : CompilerIrInstrList
  (let
    [tail : CompilerIrInstrList (opt-loop-bce-test-entry-tail init)]
    (if with-call
      (compiler-ir-instr-cons
        (CompilerIrInstr.Call
          20
          (struct-get symbols touch)
          (CompilerIrCallArgs.One (CompilerIrValue.Var 2))
          (AstType.Unit))
        tail)
      tail)))

(define (opt-loop-bce-test-entry
  [symbols : OptLoopBceTestSymbols]
  [init : i64]
  [with-call : bool]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "entry")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Alloc 2 (AstType.U8))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            3
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 8)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 3)
              (CompilerIrValue.Var 1)
              (AstType.I64))
            (opt-loop-bce-test-entry-after-store symbols init with-call)))))))

(define (opt-loop-bce-test-argc-entry
  [symbols : OptLoopBceTestSymbols]
  [init : i64]
  [with-call : bool]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "entry")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call
        10
        (struct-get symbols argc)
        (CompilerIrCallArgs.Nil)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load
          11
          (CompilerIrValue.Global (struct-get symbols base))
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            1
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 11)
            (CompilerIrValue.Var 10)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Alloc 2 (AstType.U8))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Call
                12
                (struct-get symbols argc)
                (CompilerIrCallArgs.Nil)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load
                  13
                  (CompilerIrValue.Global (struct-get symbols base))
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    14
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 13)
                    (CompilerIrValue.Var 12)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Gep
                      3
                      (CompilerIrValue.Var 2)
                      (CompilerIrValue.I64 8)
                      (AstType.U8))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.StorePtr
                        (CompilerIrValue.Var 3)
                        (CompilerIrValue.Var 14)
                        (AstType.I64))
                      (opt-loop-bce-test-entry-after-store
                        symbols
                        init
                        with-call))))))))))))

(define (opt-loop-bce-test-header) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "header")
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        4
        (CompilerIrBinOp.Lt)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 1)
        (AstType.Bool))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 4)
          (compiler-ir-label "body")
          (compiler-ir-label "exit"))
        (CompilerIrInstrList.Nil)))))

(define (opt-loop-bce-test-affine-header [limit : i64]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "header")
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        4
        (CompilerIrBinOp.Lt)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 limit)
        (AstType.Bool))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 4)
          (compiler-ir-label "body")
          (compiler-ir-label "exit"))
        (CompilerIrInstrList.Nil)))))

(define (opt-loop-bce-test-body) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        5
        (CompilerIrValue.Var 2)
        (CompilerIrValue.I64 8)
        (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 6 (CompilerIrValue.Var 5) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Cast
            7
            (CompilerIrValue.Var 6)
            (AstType.I64)
            (AstType.U64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Cast
              8
              (CompilerIrValue.Var 0)
              (AstType.I64)
              (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BoundsCheck
                (CompilerIrValue.Var 8)
                (CompilerIrValue.Var 7)
                (compiler-ir-label "bounds_ok"))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  9
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.I64 1)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Mov 0 (CompilerIrValue.Var 9) (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Jump (compiler-ir-label "header"))
                    (CompilerIrInstrList.Nil)))))))))))

(define (opt-loop-bce-test-affine-body-instrs [reversed : bool]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      5
      (CompilerIrValue.Var 2)
      (CompilerIrValue.I64 8)
      (AstType.U8))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 6 (CompilerIrValue.Var 5) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Cast
          7
          (CompilerIrValue.Var 6)
          (AstType.I64)
          (AstType.U64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            15
            (CompilerIrBinOp.Add)
            (if reversed
              (CompilerIrValue.I64 3)
              (CompilerIrValue.Var 0))
            (if reversed
              (CompilerIrValue.Var 0)
              (CompilerIrValue.I64 3))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Cast
              8
              (CompilerIrValue.Var 15)
              (AstType.I64)
              (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BoundsCheck
                (CompilerIrValue.Var 8)
                (CompilerIrValue.Var 7)
                (compiler-ir-label "bounds_ok"))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  9
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.I64 1)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Mov 0 (CompilerIrValue.Var 9) (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Jump (compiler-ir-label "header"))
                    (CompilerIrInstrList.Nil)))))))))))

(define (opt-loop-bce-test-affine-body [reversed : bool]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (opt-loop-bce-test-affine-body-instrs reversed)))

(define (opt-loop-bce-test-affine-call-body
  [symbols : OptLoopBceTestSymbols]
  [reversed : bool]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call
        20
        (struct-get symbols touch)
        (CompilerIrCallArgs.One (CompilerIrValue.Var 2))
        (AstType.Unit))
      (opt-loop-bce-test-affine-body-instrs reversed))))

(define (opt-loop-bce-test-exit) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "exit")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Return (CompilerIrMaybeValue.No))
      (CompilerIrInstrList.Nil))))

(define (opt-loop-bce-test-blocks
  [symbols : OptLoopBceTestSymbols]
  [init : i64]
  [with-call : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-loop-bce-test-entry symbols init with-call)
    (compiler-ir-block-cons
      (opt-loop-bce-test-header)
      (compiler-ir-block-cons
        (opt-loop-bce-test-body)
        (compiler-ir-block-cons
          (opt-loop-bce-test-exit)
          (CompilerIrBlockList.Nil))))))

(define (opt-loop-bce-test-affine-blocks
  [symbols : OptLoopBceTestSymbols]
  [init : i64]
  [limit : i64]
  [body : CompilerIrBlock]
  [with-call : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-loop-bce-test-entry symbols init with-call)
    (compiler-ir-block-cons
      (opt-loop-bce-test-affine-header limit)
      (compiler-ir-block-cons
        body
        (compiler-ir-block-cons
          (opt-loop-bce-test-exit)
          (CompilerIrBlockList.Nil))))))

(define (opt-loop-bce-test-argc-blocks
  [symbols : OptLoopBceTestSymbols]
  [init : i64]
  [with-call : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-loop-bce-test-argc-entry symbols init with-call)
    (compiler-ir-block-cons
      (opt-loop-bce-test-header)
      (compiler-ir-block-cons
        (opt-loop-bce-test-body)
        (compiler-ir-block-cons
          (opt-loop-bce-test-exit)
          (CompilerIrBlockList.Nil))))))

(define (opt-loop-bce-test-nested-entry [symbols : OptLoopBceTestSymbols]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "entry")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call
        10
        (struct-get symbols argc)
        (CompilerIrCallArgs.Nil)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Alloc 2 (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              3
              (CompilerIrValue.Var 2)
              (CompilerIrValue.I64 8)
              (AstType.U8))
            (compiler-ir-instr-cons
              (CompilerIrInstr.StorePtr
                (CompilerIrValue.Var 3)
                (CompilerIrValue.Var 1)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Mov 30 (CompilerIrValue.I64 0) (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Mov 31 (CompilerIrValue.I64 3) (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Jump (compiler-ir-label "outer_header"))
                    (CompilerIrInstrList.Nil)))))))))))

(define (opt-loop-bce-test-outer-header) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "outer_header")
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        32
        (CompilerIrBinOp.Lt)
        (CompilerIrValue.Var 30)
        (CompilerIrValue.Var 31)
        (AstType.Bool))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 32)
          (compiler-ir-label "outer_body")
          (compiler-ir-label "exit"))
        (CompilerIrInstrList.Nil)))))

(define (opt-loop-bce-test-outer-body) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "outer_body")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 0) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "header"))
        (CompilerIrInstrList.Nil)))))

(define (opt-loop-bce-test-inner-header) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "header")
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        4
        (CompilerIrBinOp.Lt)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 1)
        (AstType.Bool))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 4)
          (compiler-ir-label "body")
          (compiler-ir-label "after_inner"))
        (CompilerIrInstrList.Nil)))))

(define (opt-loop-bce-test-after-inner) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "after_inner")
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        33
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 30)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 30 (CompilerIrValue.Var 33) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "outer_header"))
          (CompilerIrInstrList.Nil))))))

(define (opt-loop-bce-test-nested-blocks [symbols : OptLoopBceTestSymbols]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-loop-bce-test-nested-entry symbols)
    (compiler-ir-block-cons
      (opt-loop-bce-test-outer-header)
      (compiler-ir-block-cons
        (opt-loop-bce-test-outer-body)
        (compiler-ir-block-cons
          (opt-loop-bce-test-inner-header)
          (compiler-ir-block-cons
            (opt-loop-bce-test-body)
            (compiler-ir-block-cons
              (opt-loop-bce-test-after-inner)
              (compiler-ir-block-cons
                (opt-loop-bce-test-exit)
                (CompilerIrBlockList.Nil)))))))))

(define (opt-loop-bce-string-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "text" (AstType.String) 2)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "other" (AstType.String) 20)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "unknown" (AstType.U64) 30)
        (CompilerIrParamList.Nil)))))

(define (opt-loop-bce-string-test-entry [init : i64]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "entry")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        3
        (CompilerIrValue.Var 2)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 1 (CompilerIrValue.Var 3) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 init) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "header"))
            (CompilerIrInstrList.Nil)))))))

(define (opt-loop-bce-string-test-header [off-by-one : bool]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "header")
    (if off-by-one
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          14
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            4
            (CompilerIrBinOp.Lt)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 14)
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 4)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          4
          (CompilerIrBinOp.Lt)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 4)
            (compiler-ir-label "body")
            (compiler-ir-label "exit"))
          (CompilerIrInstrList.Nil))))))

(define (opt-loop-bce-string-test-body-instrs [object-var : i64]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      5
      (CompilerIrValue.Var object-var)
      (CompilerIrValue.I64 0)
      (AstType.U8))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 6 (CompilerIrValue.Var 5) (AstType.U64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          7
          (CompilerIrValue.Var object-var)
          (CompilerIrValue.I64 8)
          (AstType.U8))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Cast
              9
              (CompilerIrValue.Var 8)
              (AstType.I64)
              (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Cast
                10
                (CompilerIrValue.Var 0)
                (AstType.I64)
                (AstType.U64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BoundsCheck
                  (CompilerIrValue.Var 10)
                  (CompilerIrValue.Var 9)
                  (compiler-ir-label "str_bounds_ok"))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Gep
                    11
                    (CompilerIrValue.Var 6)
                    (CompilerIrValue.Var 0)
                    (AstType.Char))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Load
                      12
                      (CompilerIrValue.Var 11)
                      (AstType.Char))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.BinOp
                        13
                        (CompilerIrBinOp.Add)
                        (CompilerIrValue.Var 0)
                        (CompilerIrValue.I64 1)
                        (AstType.I64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Mov
                          0
                          (CompilerIrValue.Var 13)
                          (AstType.I64))
                        (compiler-ir-instr-cons
                          (CompilerIrInstr.Jump (compiler-ir-label "header"))
                          (CompilerIrInstrList.Nil))))))))))))))

(define (opt-loop-bce-string-test-ref-instrs
  [object-var : i64]
  [base : i64]
  [tail : CompilerIrInstrList]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      base
      (CompilerIrValue.Var object-var)
      (CompilerIrValue.I64 0)
      (AstType.U8))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load (+ base 1) (CompilerIrValue.Var base) (AstType.U64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          (+ base 2)
          (CompilerIrValue.Var object-var)
          (CompilerIrValue.I64 8)
          (AstType.U8))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load
            (+ base 3)
            (CompilerIrValue.Var (+ base 2))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Cast
              (+ base 4)
              (CompilerIrValue.Var (+ base 3))
              (AstType.I64)
              (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Cast
                (+ base 5)
                (CompilerIrValue.Var 0)
                (AstType.I64)
                (AstType.U64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BoundsCheck
                  (CompilerIrValue.Var (+ base 5))
                  (CompilerIrValue.Var (+ base 4))
                  (compiler-ir-label "str_bounds_ok"))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Gep
                    (+ base 6)
                    (CompilerIrValue.Var (+ base 1))
                    (CompilerIrValue.Var 0)
                    (AstType.Char))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Load
                      (+ base 7)
                      (CompilerIrValue.Var (+ base 6))
                      (AstType.Char))
                    tail))))))))))

(define (opt-loop-bce-string-test-affine-body-instrs
  [object-var : i64]
  [reversed : bool]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      5
      (CompilerIrValue.Var object-var)
      (CompilerIrValue.I64 0)
      (AstType.U8))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 6 (CompilerIrValue.Var 5) (AstType.U64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          7
          (CompilerIrValue.Var object-var)
          (CompilerIrValue.I64 8)
          (AstType.U8))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Cast
              9
              (CompilerIrValue.Var 8)
              (AstType.I64)
              (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                15
                (CompilerIrBinOp.Add)
                (if reversed
                  (CompilerIrValue.I64 3)
                  (CompilerIrValue.Var 0))
                (if reversed
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.I64 3))
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Cast
                  10
                  (CompilerIrValue.Var 15)
                  (AstType.I64)
                  (AstType.U64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BoundsCheck
                    (CompilerIrValue.Var 10)
                    (CompilerIrValue.Var 9)
                    (compiler-ir-label "str_bounds_ok"))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Gep
                      11
                      (CompilerIrValue.Var 6)
                      (CompilerIrValue.Var 15)
                      (AstType.Char))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Load
                        12
                        (CompilerIrValue.Var 11)
                        (AstType.Char))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.BinOp
                          13
                          (CompilerIrBinOp.Add)
                          (CompilerIrValue.Var 0)
                          (CompilerIrValue.I64 1)
                          (AstType.I64))
                        (compiler-ir-instr-cons
                          (CompilerIrInstr.Mov
                            0
                            (CompilerIrValue.Var 13)
                            (AstType.I64))
                          (compiler-ir-instr-cons
                            (CompilerIrInstr.Jump (compiler-ir-label "header"))
                            (CompilerIrInstrList.Nil)))))))))))))))

(define (opt-loop-bce-string-test-body [object-var : i64]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (opt-loop-bce-string-test-body-instrs object-var)))

(define (opt-loop-bce-string-test-call-body
  [symbols : OptLoopBceTestSymbols]
  [object-var : i64]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call
        21
        (struct-get symbols touch)
        (CompilerIrCallArgs.One (CompilerIrValue.Var object-var))
        (AstType.Unit))
      (opt-loop-bce-string-test-body-instrs object-var))))

(define (opt-loop-bce-string-test-store-body [object-var : i64]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (compiler-ir-instr-cons
      (CompilerIrInstr.StorePtr
        (CompilerIrValue.Var 30)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (opt-loop-bce-string-test-body-instrs object-var))))

(define (opt-loop-bce-string-test-reassign-body) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 2 (CompilerIrValue.Var 20) (AstType.String))
      (opt-loop-bce-string-test-body-instrs 2))))

(define (opt-loop-bce-string-test-blocks
  [init : i64]
  [body : CompilerIrBlock]
  [off-by-one : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-loop-bce-string-test-entry init)
    (compiler-ir-block-cons
      (opt-loop-bce-string-test-header off-by-one)
      (compiler-ir-block-cons
        body
        (compiler-ir-block-cons
          (opt-loop-bce-test-exit)
          (CompilerIrBlockList.Nil))))))

(define (opt-loop-bce-string-test-split-body) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (opt-loop-bce-string-test-ref-instrs
      2
      30
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Bool true)
          (compiler-ir-label "tail")
          (compiler-ir-label "exit"))
        (CompilerIrInstrList.Nil)))))

(define (opt-loop-bce-string-test-split-tail) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "tail")
    (opt-loop-bce-string-test-body-instrs 2)))

(define (opt-loop-bce-string-test-split-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-loop-bce-string-test-entry 0)
    (compiler-ir-block-cons
      (opt-loop-bce-string-test-header false)
      (compiler-ir-block-cons
        (opt-loop-bce-string-test-split-body)
        (compiler-ir-block-cons
          (opt-loop-bce-string-test-split-tail)
          (compiler-ir-block-cons
            (opt-loop-bce-test-exit)
            (CompilerIrBlockList.Nil)))))))

(define (opt-loop-bce-string-test-transitive-entry) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "entry")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        3
        (CompilerIrValue.Var 2)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 1 (CompilerIrValue.Var 3) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 40 (CompilerIrValue.I64 3) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                41
                (CompilerIrBinOp.Ge)
                (CompilerIrValue.Var 0)
                (CompilerIrValue.I64 0)
                (AstType.Bool))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 41)
                  (compiler-ir-label "upper")
                  (compiler-ir-label "exit"))
                (CompilerIrInstrList.Nil)))))))))

(define (opt-loop-bce-string-test-transitive-upper [with-upper : bool]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "upper")
    (if with-upper
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          42
          (CompilerIrBinOp.Le)
          (CompilerIrValue.Var 40)
          (CompilerIrValue.Var 1)
          (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 42)
            (compiler-ir-label "header")
            (compiler-ir-label "exit"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "header"))
        (CompilerIrInstrList.Nil)))))

(define (opt-loop-bce-string-test-transitive-header) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "header")
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        43
        (CompilerIrBinOp.Lt)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.Var 40)
        (AstType.Bool))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 43)
          (compiler-ir-label "body")
          (compiler-ir-label "exit"))
        (CompilerIrInstrList.Nil)))))

(define (opt-loop-bce-string-test-transitive-body) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (opt-loop-bce-string-test-ref-instrs
      2
      50
      (compiler-ir-instr-cons
        (CompilerIrInstr.Return
          (CompilerIrMaybeValue.Some (CompilerIrValue.Var 57)))
        (CompilerIrInstrList.Nil)))))

(define (opt-loop-bce-string-test-transitive-blocks [with-upper : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-loop-bce-string-test-transitive-entry)
    (compiler-ir-block-cons
      (opt-loop-bce-string-test-transitive-upper with-upper)
      (compiler-ir-block-cons
        (opt-loop-bce-string-test-transitive-header)
        (compiler-ir-block-cons
          (opt-loop-bce-string-test-transitive-body)
          (compiler-ir-block-cons
            (opt-loop-bce-test-exit)
            (CompilerIrBlockList.Nil)))))))

(define (opt-loop-bce-test-count
  [blocks : CompilerIrBlockList]
  [summaries : OptLoopBceSummaries]) : i64
  (opt-count-bounds-blocks
    (opt-loop-bce-blocks summaries (CompilerIrParamList.Nil) blocks)))

(define (opt-loop-bce-string-test-count
  [blocks : CompilerIrBlockList]
  [summaries : OptLoopBceSummaries]) : i64
  (opt-count-bounds-blocks
    (opt-loop-bce-blocks summaries (opt-loop-bce-string-test-params) blocks)))

;; Dominated bounds-dedup fixture: entry checks (idx,len); the dominated mid /
;; left / exit blocks re-check the same pair (removable), while a different
;; length, a multi-def index, and a sibling block that only sees the multi-def
;; var must all keep their checks.
(define (opt-bounds-dom-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "idx" (AstType.I64) 1)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "len" (AstType.I64) 2)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "len2" (AstType.I64) 3)
          (CompilerIrParamList.Nil))))))

(define (opt-bounds-dom-test-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BoundsCheck
          (CompilerIrValue.Var 1)
          (CompilerIrValue.Var 2)
          (compiler-ir-label "e_ok"))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "mid"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "mid")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BoundsCheck
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 2)
            (compiler-ir-label "m_ok"))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BoundsCheck
              (CompilerIrValue.Var 1)
              (CompilerIrValue.Var 3)
              (compiler-ir-label "m2_ok"))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov 5 (CompilerIrValue.I64 1) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 0)
                  (compiler-ir-label "left")
                  (compiler-ir-label "right"))
                (CompilerIrInstrList.Nil))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "left")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BoundsCheck
              (CompilerIrValue.Var 1)
              (CompilerIrValue.Var 2)
              (compiler-ir-label "l_ok"))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov 5 (CompilerIrValue.I64 2) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BoundsCheck
                  (CompilerIrValue.Var 5)
                  (CompilerIrValue.Var 2)
                  (compiler-ir-label "l2_ok"))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Jump (compiler-ir-label "join"))
                  (CompilerIrInstrList.Nil))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "right")
            (compiler-ir-instr-cons
              (CompilerIrInstr.BoundsCheck
                (CompilerIrValue.Var 5)
                (CompilerIrValue.Var 2)
                (compiler-ir-label "r_ok"))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "join"))
                (CompilerIrInstrList.Nil))))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "join")
              (compiler-ir-instr-cons
                (CompilerIrInstr.BoundsCheck
                  (CompilerIrValue.Var 1)
                  (CompilerIrValue.Var 2)
                  (compiler-ir-label "j_ok"))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
                  (CompilerIrInstrList.Nil))))
            (CompilerIrBlockList.Nil)))))))

(define (compiler-optimize-bounds-dom-self-test) : i64
  (let
    [blocks : CompilerIrBlockList (opt-bounds-dom-test-blocks)]
    [before : i64 (opt-count-bounds-blocks blocks)]
    [after-blocks : CompilerIrBlockList
      (opt-bounds-dom-blocks-with-context
        (opt-cfg-context-build blocks)
        (opt-bounds-dom-test-params)
        8
        blocks)]
    [after : i64 (opt-count-bounds-blocks after-blocks)]
    (cond
      [(not (= before 7)) 1]
      ;; kept: entry (first), mid's different-length, left's multi-def index,
      ;; right's multi-def index. dropped: mid/left/join duplicates of
      ;; (idx,len). The fixture is intentionally multi-def (the negative
      ;; case), so a full verify does not apply; the pass only deletes
      ;; mid-block instructions, checked structurally below.
      [(not (= after 4)) 2]
      [(not (= (compiler-ir-block-list-count after-blocks) 5)) 3]
      [(not (opt-cfg-successor-targets-known? after-blocks)) 4]
      [else 42])))

(define (compiler-optimize-bounds-self-test) : i64
  (let
    [symbols : OptLoopBceTestSymbols (opt-loop-bce-test-symbols)]
    [duplicate : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (opt-bounds-duplicate-instrs))]
    [different : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (opt-bounds-different-instrs))]
    [redef : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (opt-bounds-redef-instrs))]
    [call : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (opt-bounds-call-instrs))]
    [branch : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (opt-bounds-branch-instrs))]
    [copy : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (opt-copy-instrs (OptCopyEnv.Nil) (opt-bounds-copy-instrs)))]
    [dce : CompilerIrInstrList
      (opt-dce-instrs
        (opt-collect-instrs-uses
          (opt_i64_i64_map.with-capacity 64)
          (opt-bounds-dce-instrs))
        (opt-bounds-dce-instrs))]
    [cross : CompilerIrBlockList
      (optimize-block-list (opt-bounds-cross-blocks))]
    [loop-positive : i64
      (opt-loop-bce-test-count
        (opt-loop-bce-test-blocks symbols 0 false)
        (opt-loop-bce-test-summaries symbols false false))]
    [loop-negative-init : i64
      (opt-loop-bce-test-count
        (opt-loop-bce-test-argc-blocks symbols (- 0 1) false)
        (opt-loop-bce-test-summaries symbols false true))]
    [loop-unknown-call : i64
      (opt-loop-bce-test-count
        (opt-loop-bce-test-argc-blocks symbols 0 true)
        (opt-loop-bce-test-summaries symbols false true))]
    [loop-clean-call : i64
      (opt-loop-bce-test-count
        (opt-loop-bce-test-argc-blocks symbols 0 true)
        (opt-loop-bce-test-summaries symbols true true))]
    [loop-argc : i64
      (opt-loop-bce-test-count
        (opt-loop-bce-test-argc-blocks symbols 0 false)
        (opt-loop-bce-test-summaries symbols false true))]
    [loop-nested : i64
      (opt-loop-bce-test-count
        (opt-loop-bce-test-nested-blocks symbols)
        (opt-loop-bce-test-summaries symbols false true))]
    [string-positive : i64
      (opt-loop-bce-string-test-count
        (opt-loop-bce-string-test-blocks
          0
          (opt-loop-bce-string-test-body 2)
          false)
        (opt-loop-bce-test-summaries symbols false false))]
    [string-mismatch : i64
      (opt-loop-bce-string-test-count
        (opt-loop-bce-string-test-blocks
          0
          (opt-loop-bce-string-test-body 20)
          false)
        (opt-loop-bce-test-summaries symbols false false))]
    [string-call : i64
      (opt-loop-bce-string-test-count
        (opt-loop-bce-string-test-blocks
          0
          (opt-loop-bce-string-test-call-body symbols 2)
          false)
        (opt-loop-bce-test-summaries symbols false false))]
    [string-store : i64
      (opt-loop-bce-string-test-count
        (opt-loop-bce-string-test-blocks
          0
          (opt-loop-bce-string-test-store-body 2)
          false)
        (opt-loop-bce-test-summaries symbols false false))]
    [string-negative-init : i64
      (opt-loop-bce-string-test-count
        (opt-loop-bce-string-test-blocks
          (- 0 1)
          (opt-loop-bce-string-test-body 2)
          false)
        (opt-loop-bce-test-summaries symbols false false))]
    [string-off-by-one : i64
      (opt-loop-bce-string-test-count
        (opt-loop-bce-string-test-blocks
          0
          (opt-loop-bce-string-test-body 2)
          true)
        (opt-loop-bce-test-summaries symbols false false))]
    [string-reassign : i64
      (opt-loop-bce-string-test-count
        (opt-loop-bce-string-test-blocks
          0
          (opt-loop-bce-string-test-reassign-body)
          false)
        (opt-loop-bce-test-summaries symbols false false))]
    [string-split : i64
      (opt-loop-bce-string-test-count
        (opt-loop-bce-string-test-split-blocks)
        (opt-loop-bce-test-summaries symbols false false))]
    [string-transitive : i64
      (opt-loop-bce-string-test-count
        (opt-loop-bce-string-test-transitive-blocks true)
        (opt-loop-bce-test-summaries symbols false false))]
    [string-transitive-missing-upper : i64
      (opt-loop-bce-string-test-count
        (opt-loop-bce-string-test-transitive-blocks false)
        (opt-loop-bce-test-summaries symbols false false))]
    [loop-affine-reversed : i64
      (opt-loop-bce-test-count
        (opt-loop-bce-test-affine-blocks
          symbols
          0
          7
          (opt-loop-bce-test-affine-body true)
          false)
        (opt-loop-bce-test-summaries symbols false false))]
    [loop-affine-missing-offset-bound : i64
      (opt-loop-bce-test-count
        (opt-loop-bce-test-affine-blocks
          symbols
          0
          10
          (opt-loop-bce-test-affine-body true)
          false)
        (opt-loop-bce-test-summaries symbols false false))]
    [string-affine-missing-offset-bound : i64
      (opt-loop-bce-string-test-count
        (opt-loop-bce-string-test-blocks
          0
          (compiler-ir-block
            (compiler-ir-label "body")
            (opt-loop-bce-string-test-affine-body-instrs 2 true))
          false)
        (opt-loop-bce-test-summaries symbols false false))]
    [loop-affine-negative-init : i64
      (opt-loop-bce-test-count
        (opt-loop-bce-test-affine-blocks
          symbols
          (- 0 1)
          7
          (opt-loop-bce-test-affine-body true)
          false)
        (opt-loop-bce-test-summaries symbols false false))]
    [loop-affine-call : i64
      (opt-loop-bce-test-count
        (opt-loop-bce-test-affine-blocks
          symbols
          0
          7
          (opt-loop-bce-test-affine-call-body symbols true)
          false)
        (opt-loop-bce-test-summaries symbols false false))]
    [index-cast : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (opt-bounds-index-cast-instrs))]
    [index-cast-redef : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsFacts.Nil)
        (OptBoundsCastEnv.Nil)
        (opt-bounds-index-cast-redef-instrs))]
    (cond
      [(not (= (opt-count-bounds-instrs duplicate) 1)) 1]
      [(not (= (opt-count-bounds-instrs different) 2)) 2]
      [(not (= (opt-count-bounds-instrs redef) 2)) 3]
      [(not (= (opt-count-bounds-instrs call) 2)) 4]
      [(not (= (opt-count-bounds-instrs branch) 2)) 5]
      [(not (= (opt-count-bounds-instrs copy) 1)) 6]
      [(not (= (compiler-ir-instr-list-count dce) 3)) 7]
      [(not (= (opt-count-bounds-blocks cross) 2)) 8]
      [(not (= loop-positive 0)) 9]
      [(not (= loop-negative-init 1)) 10]
      [(not (= loop-unknown-call 1)) 11]
      [(not (= loop-clean-call 0)) 12]
      [(not (= loop-argc 0)) 13]
      [(not (= loop-nested 0)) 14]
      [(not (= string-positive 0)) 15]
      [(not (= string-mismatch 1)) 16]
      [(not (= string-call 1)) 17]
      [(not (= string-store 1)) 18]
      [(not (= string-negative-init 1)) 19]
      [(not (= string-off-by-one 1)) 20]
      [(not (= string-reassign 1)) 21]
      [(not (= string-split 0)) 22]
      [(not (= (opt-count-bounds-instrs index-cast) 1)) 23]
      [(not (= (opt-count-bounds-instrs index-cast-redef) 2)) 24]
      [(not (= string-transitive 0)) 25]
      [(not (= string-transitive-missing-upper 1)) 26]
      [(not (= loop-affine-reversed 0)) 27]
      [(not (= loop-affine-missing-offset-bound 1)) 28]
      [(not (= string-affine-missing-offset-bound 1)) 29]
      [(not (= loop-affine-negative-init 1)) 30]
      [(not (= loop-affine-call 1)) 31]
      [else 42])))

;; Copy propagation can expose a repeated expression only after CSE has already
;; run for that iteration. A second pass then CSEs `v3` to `v2`; copy propagation
;; rewrites `v4`, and DCE drops the now-unused copy.
(define (opt-fixed-point-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 1 (CompilerIrValue.Var 0) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        2
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          3
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            4
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 2)
            (CompilerIrValue.Var 3)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
            (CompilerIrInstrList.Nil)))))))

(define (opt-test-function-symbol [name : i64] [instrs : CompilerIrInstrList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    name
    (CompilerIrParamList.Nil)
    (AstType.I64)
    5
    (compiler-ir-block-cons
      (compiler-ir-block (compiler-ir-label "entry") instrs)
      (CompilerIrBlockList.Nil))))

(define (opt-test-function-named [name : String] [instrs : CompilerIrInstrList]) : CompilerIrFunction
  (opt-test-function-symbol (opt-test-symbol name) instrs))

(define (opt-test-function [instrs : CompilerIrInstrList]) : CompilerIrFunction
  (opt-test-function-named "fixed" instrs))

(define (opt-test-program [instrs : CompilerIrInstrList]) : CompilerIrProgram
  (CompilerIrProgram.Program
    (CompilerIrGlobalList.Nil)
    (compiler-ir-function-cons
      (opt-test-function instrs)
      (CompilerIrFunctionList.Nil))
    (CompilerIrExternList.Nil)))

;; Self-test helper: exposes the first optimized block as a list for existing
;; instruction-count assertions; not used by production passes.
(define (opt-function-first-instrs [func : CompilerIrFunction]) : CompilerIrInstrList
  (match func
    [(CompilerIrFunction.Function _ _ _ _ blocks)
      (match (compiler-ir-block-list-force-cons blocks)
        [(CompilerIrBlockList.Cons block _)
          (match block
            [(CompilerIrBlock.Block _ instrs)
              (compiler-ir-instr-seq-to-list instrs)])]
        [(CompilerIrBlockList.Array _) (CompilerIrInstrList.Nil)]
        [(CompilerIrBlockList.Nil) (CompilerIrInstrList.Nil)])]))

(define (opt-program-first-instrs [program : CompilerIrProgram]) : CompilerIrInstrList
  (match program
    [(CompilerIrProgram.Program _ funcs _)
      (match funcs
        [(CompilerIrFunctionList.Cons func _) (opt-function-first-instrs func)]
        [(CompilerIrFunctionList.Nil) (CompilerIrInstrList.Nil)]
        [(CompilerIrFunctionList.Array seq)
          (if (> (compiler-ir-function-seq-count seq) 0)
            (opt-function-first-instrs (compiler-ir-function-seq-ref seq 0))
            (CompilerIrInstrList.Nil))])]))

(define (opt-program-functions [program : CompilerIrProgram]) : CompilerIrFunctionList
  (match program
    [(CompilerIrProgram.Program _ funcs _) funcs]))

(define (opt-program-globals [program : CompilerIrProgram]) : CompilerIrGlobalList
  (match program
    [(CompilerIrProgram.Program globals _ _) globals]))

(define (opt-global-list-defines?
  [globals : CompilerIrGlobalList]
  [name : String]) : bool
  (match globals
    [(CompilerIrGlobalList.Nil) false]
    [(CompilerIrGlobalList.Cons global rest)
      (match global
        [(CompilerIrGlobal.Global global-name _ _)
          (if (string.eq (compiler-ir-symbol-text global-name) name)
            true
            (opt-global-list-defines? (box-get rest) name))])]
    [(CompilerIrGlobalList.Array seq) (opt-global-seq-defines? seq name 0)]))

(define (opt-global-seq-defines?
  [globals : CompilerIrGlobalSeq]
  [name : String]
  [index : i64]) : bool
  (if (>= index (compiler-ir-global-seq-count globals))
    false
    (match (compiler-ir-global-seq-ref globals index)
      [(CompilerIrGlobal.Global global-name _ _)
        (if (string.eq (compiler-ir-symbol-text global-name) name)
          true
          (opt-global-seq-defines? globals name (+ index 1)))])))

(define (opt-level-parse-ok? [value : String] [expected : i64]) : bool
  (match (compiler-optimize-parse-level value)
    [(ResultCompilerOptimizeLevel.Ok level) (= level expected)]
    [(ResultCompilerOptimizeLevel.Err) false]))

(define (opt-level-parse-err? [value : String]) : bool
  (match (compiler-optimize-parse-level value)
    [(ResultCompilerOptimizeLevel.Ok _) false]
    [(ResultCompilerOptimizeLevel.Err) true]))

(define (compiler-optimize-level-policy-ok?) : bool
  (and
    (= (compiler-optimize-default-level) 1)
    (compiler-optimize-level-valid? 0)
    (compiler-optimize-level-valid? 1)
    (compiler-optimize-level-valid? 2)
    (not (compiler-optimize-level-valid? 3))
    (not (compiler-optimize-level-valid? (- 0 1)))
    (not (compiler-optimize-level-valid? 4))
    (opt-level-parse-ok? "0" 0)
    (opt-level-parse-ok? "1" 1)
    (opt-level-parse-ok? "2" 2)
    (opt-level-parse-err? "3")
    (opt-level-parse-err? "")
    (opt-level-parse-err? "4")
    (opt-level-parse-err? "10")))

(define (compiler-optimize-level-program-ok?) : bool
  (let
    [program : CompilerIrProgram (opt-test-program (opt-self-test-instrs))]
    [level0 : CompilerIrProgram (optimize-program-with-level program 0)]
    [level1 : CompilerIrProgram (optimize-program-with-level program 1)]
    [level2 : CompilerIrProgram (optimize-program-with-level program 2)]
    [defaulted : CompilerIrProgram (optimize-program program)]
    [fixed-program : CompilerIrProgram
      (opt-test-program (opt-fixed-point-instrs))]
    [level1-fixed : CompilerIrProgram
      (optimize-program-with-level fixed-program 1)]
    [level2-fixed : CompilerIrProgram
      (optimize-program-with-level fixed-program 2)]
    [level0-instrs : CompilerIrInstrList (opt-program-first-instrs level0)]
    [level1-instrs : CompilerIrInstrList (opt-program-first-instrs level1)]
    [level2-instrs : CompilerIrInstrList (opt-program-first-instrs level2)]
    [level1-fixed-instrs : CompilerIrInstrList
      (opt-program-first-instrs level1-fixed)]
    [level2-fixed-instrs : CompilerIrInstrList
      (opt-program-first-instrs level2-fixed)]
    (cond
      [(not (opt-program-eq program level0)) false]
      [(not (= (opt-count-arith-instrs level0-instrs) 1)) false]
      [(not (= (compiler-ir-instr-list-count level1-instrs) 0)) false]
      [(not (= (compiler-ir-instr-list-count level2-instrs) 0)) false]
      [(not (opt-program-eq level1 defaulted)) false]
      [(not (= (compiler-ir-instr-list-count level1-fixed-instrs) 4)) false]
      [(not (= (opt-count-arith-instrs level1-fixed-instrs) 3)) false]
      [(not (= (compiler-ir-instr-list-count level2-fixed-instrs) 3)) false]
      [(not (= (opt-count-arith-instrs level2-fixed-instrs) 2)) false]
      [else true])))

(define (compiler-optimize-level1-escape-equivalent-one-ok?
  [func : CompilerIrFunction]) : bool
  (let
    [summaries : OptLoopBceSummaries (opt-loop-bce-empty-summaries)]
    [expected : CompilerIrFunction
      (compiler-ir-function-compact-blocks
        (optimize-function-with-level-and-summaries func 1 summaries))]
    [scratch : i64 (arena.tl_arena_make)]
    [escaped : CompilerIrFunction
      (optimize-function-level1-escaping-with-summaries func scratch summaries)]
    [ok : bool (opt-function-eq expected escaped)]
    (begin
      (unsafe
        (arena.tl_arena_destroy scratch))
      ok)))

(define (compiler-optimize-level1-escape-equivalent-ok?) : bool
  (and
    (compiler-optimize-level1-escape-equivalent-one-ok?
      (opt-test-function
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
          CompilerIrInstrList.Nil)))
    (compiler-optimize-level1-escape-equivalent-one-ok?
      (opt-test-function (opt-self-test-instrs)))))

(define (compiler-optimize-level-self-test) : i64
  (begin
    (unless (compiler-optimize-level-policy-ok?) (return 1))
    (unless (compiler-optimize-level-program-ok?) (return 2))
    (unless (compiler-optimize-level1-escape-equivalent-ok?) (return 3))
    42))

(defstruct OptGlobalDceTestSymbols
  (main i64)
  (helper i64)
  (dead i64)
  (callback-target i64)
  (callback i64)
  (used-global i64)
  (stored-global i64)
  (runtime-global i64)
  (dead-global i64))

(define (opt-global-dce-test-symbols) : OptGlobalDceTestSymbols
  (OptGlobalDceTestSymbols
    (opt-test-symbol "main")
    (opt-test-symbol "helper")
    (opt-test-symbol "dead")
    (opt-test-symbol "callback-target")
    (opt-test-symbol "callback")
    (opt-test-symbol "used-global")
    (opt-test-symbol "stored-global")
    (opt-test-symbol "runtime-global")
    (opt-test-symbol "dead-global")))

(define (opt-global-dce-main-instrs [symbols : OptGlobalDceTestSymbols]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov
      3
      (CompilerIrValue.Global (struct-get symbols used-global))
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Store
        (struct-get symbols stored-global)
        (CompilerIrValue.I64 99)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Call
          1
          (struct-get symbols helper)
          (CompilerIrCallArgs.Nil)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            2
            (opt-test-symbol "tl_substring")
            (compiler-ir-call-args-from-list
              (compiler-ir-value-cons
                (CompilerIrValue.I64 0)
                (compiler-ir-value-cons
                  (CompilerIrValue.I64 0)
                  (compiler-ir-value-cons
                    (CompilerIrValue.I64 0)
                    CompilerIrValueList.Nil))))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
            (CompilerIrInstrList.Nil)))))))

(define (opt-global-dce-return-instrs [value : i64]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Return
      (CompilerIrMaybeValue.Some (CompilerIrValue.I64 value)))
    (CompilerIrInstrList.Nil)))

(define (opt-global-dce-large-return-step [idx : i64] [value : i64]) : CompilerIrInstrList
  (if (>= idx 9)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Return
        (CompilerIrMaybeValue.Some (CompilerIrValue.I64 value)))
      (CompilerIrInstrList.Nil))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov idx (CompilerIrValue.I64 value) (AstType.I64))
      (opt-global-dce-large-return-step (+ idx 1) value))))

;; A direct-called fixture callee whose call-free body exceeds the opt1
;; tiny-leaf cap, so the level-1 pruning assertions keep an out-of-line
;; callee to observe instead of watching it get inlined away.
(define (opt-global-dce-large-callee [name : i64] [value : i64]) : CompilerIrFunction
  (CompilerIrFunction.Function
    name
    (CompilerIrParamList.Nil)
    (AstType.I64)
    10
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (opt-global-dce-large-return-step 0 value))
      (CompilerIrBlockList.Nil))))

(define (opt-global-dce-program [symbols : OptGlobalDceTestSymbols]) : CompilerIrProgram
  (CompilerIrProgram.Program
    (compiler-ir-global-cons
      (CompilerIrGlobal.Global
        (struct-get symbols callback)
        (AstType.I64)
        (CompilerIrValue.Global (struct-get symbols callback-target)))
      (compiler-ir-global-cons
        (CompilerIrGlobal.Global
          (struct-get symbols used-global)
          (AstType.I64)
          (CompilerIrValue.I64 3))
        (compiler-ir-global-cons
          (CompilerIrGlobal.Global
            (struct-get symbols stored-global)
            (AstType.I64)
            (CompilerIrValue.I64 0))
          (compiler-ir-global-cons
            (CompilerIrGlobal.Global
              (struct-get symbols runtime-global)
              (AstType.I64)
              (CompilerIrValue.Unit))
            (compiler-ir-global-cons
              (CompilerIrGlobal.Global
                (struct-get symbols dead-global)
                (AstType.I64)
                (CompilerIrValue.I64 5))
              (CompilerIrGlobalList.Nil))))))
    (compiler-ir-function-cons
      (opt-test-function-symbol
        (struct-get symbols main)
        (opt-global-dce-main-instrs symbols))
      (compiler-ir-function-cons
        (opt-global-dce-large-callee (struct-get symbols helper) 7)
        (compiler-ir-function-cons
          (opt-test-function-symbol
            (struct-get symbols dead)
            (opt-global-dce-return-instrs 9))
          (compiler-ir-function-cons
            (opt-test-function-symbol
              (struct-get symbols callback-target)
              (opt-global-dce-return-instrs 11))
            (compiler-ir-function-cons
              (opt-test-function-named
                "C:/repo/stdlib/runtime.tl::substring"
                (opt-global-dce-return-instrs 13))
              (compiler-ir-function-cons
                (opt-test-function-named
                  "C:/repo/stdlib/runtime.tl::int-to-string"
                  (opt-global-dce-return-instrs 17))
                (CompilerIrFunctionList.Nil)))))))
    (CompilerIrExternList.Nil)))

(define (opt-global-dce-no-main-program) : CompilerIrProgram
  (CompilerIrProgram.Program
    (CompilerIrGlobalList.Nil)
    (compiler-ir-function-cons
      (opt-test-function-named "helper" (opt-global-dce-return-instrs 7))
      (compiler-ir-function-cons
        (opt-test-function-named "dead" (opt-global-dce-return-instrs 9))
        (CompilerIrFunctionList.Nil)))
    (CompilerIrExternList.Nil)))

(define (compiler-optimize-global-dce-ok?) : bool
  (let
    [symbols : OptGlobalDceTestSymbols (opt-global-dce-test-symbols)]
    [program : CompilerIrProgram (opt-global-dce-program symbols)]
    ;; Level 0 keeps every function; level 1 (the cheap optimized build) prunes
    ;; functions unreachable from the roots without inlining the survivors.
    [level0 : CompilerIrProgram (optimize-program-with-level program 0)]
    [level1 : CompilerIrProgram (optimize-program-with-level program 1)]
    [no-main : CompilerIrProgram
      (optimize-program-with-level (opt-global-dce-no-main-program) 1)]
    [level0-functions : CompilerIrFunctionList (opt-program-functions level0)]
    [level1-functions : CompilerIrFunctionList (opt-program-functions level1)]
    [no-main-functions : CompilerIrFunctionList (opt-program-functions no-main)]
    [level0-globals : CompilerIrGlobalList (opt-program-globals level0)]
    [level1-globals : CompilerIrGlobalList (opt-program-globals level1)]
    (and
      (= (compiler-ir-function-list-count level0-functions) 6)
      (= (compiler-ir-function-list-count level1-functions) 4)
      (= (compiler-ir-global-list-count level0-globals) 5)
      (= (compiler-ir-global-list-count level1-globals) 3)
      (opt-function-list-defines? level1-functions "main")
      (opt-function-list-defines? level1-functions "helper")
      (opt-function-list-defines? level1-functions "callback-target")
      (opt-function-list-defines?
        level1-functions
        "C:/repo/stdlib/runtime.tl::substring")
      (not
        (opt-function-list-defines?
          level1-functions
          "C:/repo/stdlib/runtime.tl::int-to-string"))
      (not (opt-function-list-defines? level1-functions "dead"))
      (opt-global-list-defines? level1-globals "used-global")
      (opt-global-list-defines? level1-globals "stored-global")
      (opt-global-list-defines? level1-globals "runtime-global")
      (not (opt-global-list-defines? level1-globals "dead-global"))
      (not (opt-global-list-defines? level1-globals "callback"))
      (= (compiler-ir-function-list-count no-main-functions) 2))))

(define (compiler-optimize-global-dce-self-test) : i64
  (if (compiler-optimize-global-dce-ok?)
    42
    1))

(defstruct OptCallgraphTestSymbols
  (main i64)
  (a i64)
  (b i64)
  (c i64)
  (address-taken i64)
  (external i64)
  (rec-even i64)
  (rec-odd i64)
  (lonely i64)
  (self i64)
  (leaf i64))

(define (opt-callgraph-test-symbols) : OptCallgraphTestSymbols
  (OptCallgraphTestSymbols
    (opt-test-symbol "main")
    (opt-test-symbol "a")
    (opt-test-symbol "b")
    (opt-test-symbol "c")
    (opt-test-symbol "address_taken")
    (opt-test-symbol "external")
    (opt-test-symbol "rec_even")
    (opt-test-symbol "rec_odd")
    (opt-test-symbol "lonely")
    (opt-test-symbol "self")
    (opt-test-symbol "leaf")))

(define (opt-callgraph-test-slot [index : OptFunctionIndex] [name : i64]) : i64
  (match (opt-function-index-slot index name)
    [(option_i64.Some slot) slot]
    [(option_i64.None) -1]))

(define (opt-callgraph-test-edge?
  [index : OptFunctionIndex]
  [graph : OptCallGraph]
  [caller : i64]
  [callee : i64]) : bool
  (opt-callgraph-has-edge?
    graph
    (opt-callgraph-test-slot index caller)
    (opt-callgraph-test-slot index callee)))

(define (opt-callgraph-test-edge-count
  [index : OptFunctionIndex]
  [graph : OptCallGraph]
  [caller : i64]) : i64
  (opt-callgraph-callee-count graph (opt-callgraph-test-slot index caller)))

(define (opt-callgraph-main-instrs [symbols : OptCallgraphTestSymbols]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Call
      0
      (struct-get symbols a)
      CompilerIrCallArgs.Nil
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call
        1
        (struct-get symbols external)
        CompilerIrCallArgs.Nil
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.CallIndirect
          2
          (CompilerIrValue.Function (struct-get symbols c))
          CompilerIrCallArgs.Nil
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov
            3
            (CompilerIrValue.Global (struct-get symbols address-taken))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.TailCall
              (struct-get symbols b)
              CompilerIrCallArgs.Nil
              (AstType.I64))
            CompilerIrInstrList.Nil))))))

(define (opt-callgraph-call-instrs [name : i64]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Call 0 name CompilerIrCallArgs.Nil (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Return
        (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
      CompilerIrInstrList.Nil)))

(define (opt-callgraph-tail-instrs [name : i64]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.TailCall name CompilerIrCallArgs.Nil (AstType.I64))
    CompilerIrInstrList.Nil))

(define (opt-callgraph-return-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Return (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
    CompilerIrInstrList.Nil))

(define (opt-callgraph-acyclic-functions [symbols : OptCallgraphTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-test-function-symbol
      (struct-get symbols main)
      (opt-callgraph-main-instrs symbols))
    (compiler-ir-function-cons
      (opt-test-function-symbol
        (struct-get symbols a)
        (opt-callgraph-call-instrs (struct-get symbols c)))
      (compiler-ir-function-cons
        (opt-test-function-symbol
          (struct-get symbols b)
          (opt-callgraph-return-instrs))
        (compiler-ir-function-cons
          (opt-test-function-symbol
            (struct-get symbols c)
            (opt-callgraph-tail-instrs (struct-get symbols b)))
          (compiler-ir-function-cons
            (opt-test-function-symbol
              (struct-get symbols address-taken)
              (opt-callgraph-return-instrs))
            CompilerIrFunctionList.Nil))))))

(define (opt-callgraph-rec-even-instrs [symbols : OptCallgraphTestSymbols]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Call
      0
      (struct-get symbols rec-odd)
      CompilerIrCallArgs.Nil
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call
        1
        (struct-get symbols rec-odd)
        CompilerIrCallArgs.Nil
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Return
          (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
        CompilerIrInstrList.Nil))))

(define (opt-callgraph-recursive-functions [symbols : OptCallgraphTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-test-function-symbol
      (struct-get symbols rec-even)
      (opt-callgraph-rec-even-instrs symbols))
    (compiler-ir-function-cons
      (opt-test-function-symbol
        (struct-get symbols rec-odd)
        (opt-callgraph-tail-instrs (struct-get symbols rec-even)))
      (compiler-ir-function-cons
        (opt-test-function-symbol
          (struct-get symbols lonely)
          (opt-callgraph-return-instrs))
        CompilerIrFunctionList.Nil))))

(define (compiler-optimize-callgraph-acyclic-ok?) : bool
  (let
    [symbols : OptCallgraphTestSymbols (opt-callgraph-test-symbols)]
    [functions : CompilerIrFunctionList
      (opt-callgraph-acyclic-functions symbols)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [graph : OptCallGraph (opt-callgraph-build index)]
    (cond
      [(not (= (struct-get graph count) 5)) false]
      [(not
          (=
            (opt-callgraph-test-edge-count
              index
              graph
              (struct-get symbols main))
            2))
        false]
      [(not
          (opt-callgraph-test-edge?
            index
            graph
            (struct-get symbols main)
            (struct-get symbols a)))
        false]
      [(not
          (opt-callgraph-test-edge?
            index
            graph
            (struct-get symbols main)
            (struct-get symbols b)))
        false]
      [(opt-callgraph-test-edge?
          index
          graph
          (struct-get symbols main)
          (struct-get symbols c))
        false]
      [(opt-callgraph-test-edge?
          index
          graph
          (struct-get symbols main)
          (struct-get symbols address-taken))
        false]
      [(not
          (=
            (opt-callgraph-test-edge-count index graph (struct-get symbols a))
            1))
        false]
      [(not
          (opt-callgraph-test-edge?
            index
            graph
            (struct-get symbols a)
            (struct-get symbols c)))
        false]
      [(not
          (=
            (opt-callgraph-test-edge-count index graph (struct-get symbols b))
            0))
        false]
      [(not
          (=
            (opt-callgraph-test-edge-count index graph (struct-get symbols c))
            1))
        false]
      [(not
          (opt-callgraph-test-edge?
            index
            graph
            (struct-get symbols c)
            (struct-get symbols b)))
        false]
      [(not
          (=
            (opt-callgraph-test-edge-count
              index
              graph
              (struct-get symbols address-taken))
            0))
        false]
      [else true])))

(define (compiler-optimize-callgraph-recursive-ok?) : bool
  (let
    [symbols : OptCallgraphTestSymbols (opt-callgraph-test-symbols)]
    [functions : CompilerIrFunctionList
      (opt-callgraph-recursive-functions symbols)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [graph : OptCallGraph (opt-callgraph-build index)]
    (cond
      [(not (= (struct-get graph count) 3)) false]
      [(not
          (=
            (opt-callgraph-test-edge-count
              index
              graph
              (struct-get symbols rec-even))
            1))
        false]
      [(not
          (opt-callgraph-test-edge?
            index
            graph
            (struct-get symbols rec-even)
            (struct-get symbols rec-odd)))
        false]
      [(opt-callgraph-test-edge?
          index
          graph
          (struct-get symbols rec-even)
          (struct-get symbols rec-even))
        false]
      [(not
          (=
            (opt-callgraph-test-edge-count
              index
              graph
              (struct-get symbols rec-odd))
            1))
        false]
      [(not
          (opt-callgraph-test-edge?
            index
            graph
            (struct-get symbols rec-odd)
            (struct-get symbols rec-even)))
        false]
      [(not
          (=
            (opt-callgraph-test-edge-count
              index
              graph
              (struct-get symbols lonely))
            0))
        false]
      [else true])))

(define (opt-scc-result-component [result : OptSccResult] [slot : i64]) : i64
  (array-ref (struct-get result scc-of) slot))

(define (opt-scc-component-size [result : OptSccResult] [scc-id : i64]) : i64
  (let
    [scc-of : (Array i64) (struct-get result scc-of)]
    [count : i64 (array-length scc-of)]
    [slot : i64 0]
    [size : i64 0]
    (begin
      (while (< slot count)
        (begin
          (if (= (array-ref scc-of slot) scc-id)
            (set! size (+ size 1))
            unit)
          (set! slot (+ slot 1))))
      size)))

(define (opt-scc-order-position [result : OptSccResult] [scc-id : i64]) : i64
  (let
    [order : (Array i64) (struct-get result order)]
    [count : i64 (array-length order)]
    [index : i64 0]
    [position : i64 (- 0 1)]
    (begin
      (while (and (< index count) (< position 0))
        (begin
          (if (= (array-ref order index) scc-id)
            (set! position index)
            unit)
          (set! index (+ index 1))))
      position)))

(define (opt-scc-before? [result : OptSccResult] [left : i64] [right : i64]) : bool
  (let
    [left-pos : i64 (opt-scc-order-position result left)]
    [right-pos : i64 (opt-scc-order-position result right)]
    (and (>= left-pos 0) (>= right-pos 0) (< left-pos right-pos))))

(define (opt-scc-self-recursive-functions [symbols : OptCallgraphTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-test-function-symbol
      (struct-get symbols self)
      (opt-callgraph-tail-instrs (struct-get symbols self)))
    (compiler-ir-function-cons
      (opt-test-function-symbol
        (struct-get symbols leaf)
        (opt-callgraph-return-instrs))
      CompilerIrFunctionList.Nil)))

(define (compiler-optimize-scc-self-recursive-ok?) : bool
  (let
    [symbols : OptCallgraphTestSymbols (opt-callgraph-test-symbols)]
    [functions : CompilerIrFunctionList
      (opt-scc-self-recursive-functions symbols)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [graph : OptCallGraph (opt-callgraph-build index)]
    [result : OptSccResult (opt-scc-compute graph)]
    [self-slot : i64 (opt-callgraph-test-slot index (struct-get symbols self))]
    [leaf-slot : i64 (opt-callgraph-test-slot index (struct-get symbols leaf))]
    [self-scc : i64 (opt-scc-result-component result self-slot)]
    [leaf-scc : i64 (opt-scc-result-component result leaf-slot)]
    (cond
      [(not (opt-callgraph-has-edge? graph self-slot self-slot)) false]
      [(< self-scc 0) false]
      [(< leaf-scc 0) false]
      [(= self-scc leaf-scc) false]
      [(not (= (opt-scc-component-size result self-scc) 1)) false]
      [(not (= (opt-scc-component-size result leaf-scc) 1)) false]
      [else true])))

(define (compiler-optimize-scc-mutual-recursive-ok?) : bool
  (let
    [symbols : OptCallgraphTestSymbols (opt-callgraph-test-symbols)]
    [functions : CompilerIrFunctionList
      (opt-callgraph-recursive-functions symbols)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [graph : OptCallGraph (opt-callgraph-build index)]
    [result : OptSccResult (opt-scc-compute graph)]
    [even-slot : i64
      (opt-callgraph-test-slot index (struct-get symbols rec-even))]
    [odd-slot : i64
      (opt-callgraph-test-slot index (struct-get symbols rec-odd))]
    [lonely-slot : i64
      (opt-callgraph-test-slot index (struct-get symbols lonely))]
    [even-scc : i64 (opt-scc-result-component result even-slot)]
    [odd-scc : i64 (opt-scc-result-component result odd-slot)]
    [lonely-scc : i64 (opt-scc-result-component result lonely-slot)]
    (cond
      [(< even-scc 0) false]
      [(not (= even-scc odd-scc)) false]
      [(= even-scc lonely-scc) false]
      [(not (= (opt-scc-component-size result even-scc) 2)) false]
      [(not (= (opt-scc-component-size result lonely-scc) 1)) false]
      [else true])))

(define (compiler-optimize-scc-reverse-topo-ok?) : bool
  (let
    [symbols : OptCallgraphTestSymbols (opt-callgraph-test-symbols)]
    [functions : CompilerIrFunctionList
      (opt-callgraph-acyclic-functions symbols)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [graph : OptCallGraph (opt-callgraph-build index)]
    [result : OptSccResult (opt-scc-compute graph)]
    [order : (Array i64) (struct-get result order)]
    [main-scc : i64
      (opt-scc-result-component
        result
        (opt-callgraph-test-slot index (struct-get symbols main)))]
    [a-scc : i64
      (opt-scc-result-component
        result
        (opt-callgraph-test-slot index (struct-get symbols a)))]
    [b-scc : i64
      (opt-scc-result-component
        result
        (opt-callgraph-test-slot index (struct-get symbols b)))]
    [c-scc : i64
      (opt-scc-result-component
        result
        (opt-callgraph-test-slot index (struct-get symbols c)))]
    [address-scc : i64
      (opt-scc-result-component
        result
        (opt-callgraph-test-slot index (struct-get symbols address-taken)))]
    (cond
      [(not (= (array-length order) 5)) false]
      [(not (= (array-ref order 0) b-scc)) false]
      [(not (= (array-ref order 1) c-scc)) false]
      [(not (= (array-ref order 2) a-scc)) false]
      [(not (= (array-ref order 3) main-scc)) false]
      [(not (= (array-ref order 4) address-scc)) false]
      [(not (opt-scc-before? result b-scc c-scc)) false]
      [(not (opt-scc-before? result c-scc a-scc)) false]
      [(not (opt-scc-before? result a-scc main-scc)) false]
      [(not (opt-scc-before? result b-scc main-scc)) false]
      [else true])))

(define (compiler-optimize-scc-self-test) : i64
  (cond
    [(not (compiler-optimize-scc-self-recursive-ok?)) 1]
    [(not (compiler-optimize-scc-mutual-recursive-ok?)) 2]
    [(not (compiler-optimize-scc-reverse-topo-ok?)) 3]
    [else 42]))

(define (compiler-optimize-callgraph-self-test) : i64
  (if (compiler-optimize-callgraph-acyclic-ok?)
    (if (compiler-optimize-callgraph-recursive-ok?)
      42
      2)
    1))

(define (opt-inline-frame-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "left" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "right" (AstType.I64) 1)
      CompilerIrParamList.Nil)))

(defstruct OptInlineFrameTestSymbols
  (main i64)
  (inline-add i64)
  (inline-mid i64)
  (inline-group-word i64))

(define (opt-inline-frame-test-symbols) : OptInlineFrameTestSymbols
  (OptInlineFrameTestSymbols
    (opt-test-symbol "main")
    (opt-test-symbol "inline_add")
    (opt-test-symbol "inline_mid")
    (opt-test-symbol "inline_group_word")))

(define (opt-inline-frame-callee [symbols : OptInlineFrameTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols inline-add)
    (opt-inline-frame-params)
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            2
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-frame-caller [symbols : OptInlineFrameTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 10) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 32) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Call
                2
                (struct-get symbols inline-add)
                (CompilerIrCallArgs.Two
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.Var 1))
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
                CompilerIrInstrList.Nil)))))
      CompilerIrBlockList.Nil)))

(define (opt-inline-frame-functions [symbols : OptInlineFrameTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-frame-caller symbols)
    (compiler-ir-function-cons
      (opt-inline-frame-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (opt-inline-known-indirect-caller [symbols : OptInlineFrameTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 10) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 32) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.CallIndirect
                2
                (CompilerIrValue.Function (struct-get symbols inline-add))
                (CompilerIrCallArgs.Two
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.Var 1))
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
                CompilerIrInstrList.Nil)))))
      CompilerIrBlockList.Nil)))

(define (opt-inline-known-indirect-functions
  [symbols : OptInlineFrameTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-known-indirect-caller symbols)
    (compiler-ir-function-cons
      (opt-inline-frame-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (opt-inline-pack-word-callee [symbols : OptInlineFrameTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols inline-group-word)
    (opt-inline-frame-params)
    (AstType.I64)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Pack
            2
            (compiler-ir-value-cons
              (CompilerIrValue.Var 0)
              (compiler-ir-value-cons
                (CompilerIrValue.Var 1)
                CompilerIrValueList.Nil))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Word 3 (CompilerIrValue.Var 2) 1 (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              CompilerIrInstrList.Nil))))
      CompilerIrBlockList.Nil)))

;; The caller passes its args from vars 1/2 (NOT the callee's param ids 0/1)
;; and uses a spacer var 0, so a missing remap of the inlined Pack/Word
;; operands is observable: the cloned Pack must read vars 1/2 (the call
;; arguments), never the callee-local 0/1 (regression guard -- the inliner
;; cloned Pack/Word through its catch-all without remapping).
(define (opt-inline-pack-word-caller [symbols : OptInlineFrameTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 99) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 20) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 22) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Call
                  3
                  (struct-get symbols inline-group-word)
                  (CompilerIrCallArgs.Two
                    (CompilerIrValue.Var 1)
                    (CompilerIrValue.Var 2))
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                  CompilerIrInstrList.Nil))))))
      CompilerIrBlockList.Nil)))

(define (opt-inline-pack-word-functions [symbols : OptInlineFrameTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-pack-word-caller symbols)
    (compiler-ir-function-cons
      (opt-inline-pack-word-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (opt-inline-level-functions [level : i64]) : CompilerIrFunctionList
  (let
    [symbols : OptInlineFrameTestSymbols (opt-inline-frame-test-symbols)]
    (opt-inline-program-functions (opt-inline-frame-functions symbols) level)))

(define (opt-inline-self-recursive) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "self_inline")
    CompilerIrParamList.Nil
    (AstType.I64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            0
            (opt-test-symbol "self_inline")
            CompilerIrCallArgs.Nil
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-large-callee-instrs [idx : i64]) : CompilerIrInstrList
  (if (> idx (opt-inline-max-body))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Return
        (CompilerIrMaybeValue.Some (CompilerIrValue.Var idx)))
      CompilerIrInstrList.Nil)
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        (+ idx 1)
        (CompilerIrBinOp.Add)
        (if (= idx 0)
          (CompilerIrValue.I64 0)
          (CompilerIrValue.Var idx))
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (opt-inline-large-callee-instrs (+ idx 1)))))

(defstruct OptInlineBoundsTestSymbols
  (main i64)
  (too-large i64)
  (bounds-inline i64)
  (bounds-leaf-inline i64))

(define (opt-inline-bounds-test-symbols) : OptInlineBoundsTestSymbols
  (OptInlineBoundsTestSymbols
    (opt-test-symbol "main")
    (opt-test-symbol "too_large_inline")
    (opt-test-symbol "bounds_inline")
    (opt-test-symbol "bounds_leaf_inline")))

(define (opt-inline-large-callee [symbols : OptInlineBoundsTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols too-large)
    CompilerIrParamList.Nil
    (AstType.I64)
    (+ (opt-inline-max-body) 2)
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (opt-inline-large-callee-instrs 0))
      CompilerIrBlockList.Nil)))

(define (opt-inline-bounds-callee [symbols : OptInlineBoundsTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols bounds-inline)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "idx" (AstType.I64) 0)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "len" (AstType.I64) 1)
        CompilerIrParamList.Nil))
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BoundsCheck
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            (compiler-ir-label "bounds_inline.ok"))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-call-one [dst : i64] [callee : i64]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Call dst callee CompilerIrCallArgs.Nil (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Return
        (CompilerIrMaybeValue.Some (CompilerIrValue.Var dst)))
      CompilerIrInstrList.Nil)))

(define (opt-inline-call-large [symbols : OptInlineBoundsTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (opt-inline-call-one 0 (struct-get symbols too-large)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-call-bounds [symbols : OptInlineBoundsTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            2
            (struct-get symbols bounds-inline)
            (CompilerIrCallArgs.Two
              (CompilerIrValue.I64 0)
              (CompilerIrValue.I64 4))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-call-bounds-twice [symbols : OptInlineBoundsTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            2
            (struct-get symbols bounds-inline)
            (CompilerIrCallArgs.Two
              (CompilerIrValue.I64 0)
              (CompilerIrValue.I64 4))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Call
              3
              (struct-get symbols bounds-inline)
              (CompilerIrCallArgs.Two
                (CompilerIrValue.I64 1)
                (CompilerIrValue.I64 4))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              CompilerIrInstrList.Nil))))
      CompilerIrBlockList.Nil)))

(define (opt-inline-duplicate-bounds-label-function
  [symbols : OptInlineBoundsTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    0
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BoundsCheck
            (CompilerIrValue.I64 0)
            (CompilerIrValue.I64 4)
            (compiler-ir-label "dup.ok"))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BoundsCheck
              (CompilerIrValue.I64 1)
              (CompilerIrValue.I64 4)
              (compiler-ir-label "dup.ok"))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
              CompilerIrInstrList.Nil))))
      CompilerIrBlockList.Nil)))

(define (opt-inline-large-functions [symbols : OptInlineBoundsTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-call-large symbols)
    (compiler-ir-function-cons
      (opt-inline-large-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (opt-inline-bounds-functions [symbols : OptInlineBoundsTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-call-bounds symbols)
    (compiler-ir-function-cons
      (opt-inline-bounds-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (opt-inline-bounds-twice-functions
  [symbols : OptInlineBoundsTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-call-bounds-twice symbols)
    (compiler-ir-function-cons
      (opt-inline-bounds-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (opt-inline-bounds-leaf-instrs [index : i64] [limit : i64]) : CompilerIrInstrList
  (if (>= index limit)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Return (CompilerIrMaybeValue.No))
      CompilerIrInstrList.Nil)
    (compiler-ir-instr-cons
      (if (= index 0)
        (CompilerIrInstr.BoundsCheck
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (compiler-ir-label "bounds_leaf.ok"))
        (CompilerIrInstr.Mov
          (+ index 1)
          (CompilerIrValue.I64 index)
          (AstType.I64)))
      (opt-inline-bounds-leaf-instrs (+ index 1) limit))))

(define (opt-inline-bounds-leaf-callee
  [symbols : OptInlineBoundsTestSymbols]
  [body : i64]) : CompilerIrFunction
  (compiler-ir-function-compact-blocks
    (CompilerIrFunction.Function
      (struct-get symbols bounds-leaf-inline)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "idx" (AstType.I64) 0)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "len" (AstType.I64) 1)
          CompilerIrParamList.Nil))
      (AstType.Unit)
      (+ body 1)
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (opt-inline-bounds-leaf-instrs 0 body))
        CompilerIrBlockList.Nil))))

(define (opt-inline-call-bounds-leaf [symbols : OptInlineBoundsTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 1) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 8) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Call
                2
                (struct-get symbols bounds-leaf-inline)
                (CompilerIrCallArgs.Two
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.Var 1))
                (AstType.Unit))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.I64 42)))
                CompilerIrInstrList.Nil)))))
      CompilerIrBlockList.Nil)))

(define (opt-inline-bounds-leaf-functions
  [symbols : OptInlineBoundsTestSymbols]
  [body : i64]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-call-bounds-leaf symbols)
    (compiler-ir-function-cons
      (opt-inline-bounds-leaf-callee symbols body)
      CompilerIrFunctionList.Nil)))

(define (opt-inline-multi-call-caller [symbols : OptInlineFrameTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    6
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 10) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 20) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Call
                2
                (struct-get symbols inline-add)
                (CompilerIrCallArgs.Two
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.Var 1))
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Call
                  3
                  (struct-get symbols inline-add)
                  (CompilerIrCallArgs.Two
                    (CompilerIrValue.Var 1)
                    (CompilerIrValue.Var 2))
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                  CompilerIrInstrList.Nil))))))
      CompilerIrBlockList.Nil)))

(define (opt-inline-multi-call-functions [symbols : OptInlineFrameTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-multi-call-caller symbols)
    (compiler-ir-function-cons
      (opt-inline-frame-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (opt-inline-cascade-mid [symbols : OptInlineFrameTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols inline-mid)
    (opt-inline-frame-params)
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            2
            (struct-get symbols inline-add)
            (CompilerIrCallArgs.Two
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 1))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-cascade-main [symbols : OptInlineFrameTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 20) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 22) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Call
                2
                (struct-get symbols inline-mid)
                (CompilerIrCallArgs.Two
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.Var 1))
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
                CompilerIrInstrList.Nil)))))
      CompilerIrBlockList.Nil)))

(define (opt-inline-cascade-functions [symbols : OptInlineFrameTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-cascade-main symbols)
    (compiler-ir-function-cons
      (opt-inline-cascade-mid symbols)
      (compiler-ir-function-cons
        (opt-inline-frame-callee symbols)
        CompilerIrFunctionList.Nil))))

(define (opt-inline-mutual-a) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "inline_mut_a")
    CompilerIrParamList.Nil
    (AstType.I64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            0
            (opt-test-symbol "inline_mut_b")
            CompilerIrCallArgs.Nil
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-mutual-b) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "inline_mut_b")
    CompilerIrParamList.Nil
    (AstType.I64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            0
            (opt-test-symbol "inline_mut_a")
            CompilerIrCallArgs.Nil
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-mutual-functions) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-mutual-a)
    (compiler-ir-function-cons (opt-inline-mutual-b) CompilerIrFunctionList.Nil)))

(define (opt-devirt-dynamic-caller) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "dynamic")
    CompilerIrParamList.Nil
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.CallIndirect
              2
              (CompilerIrValue.Var 0)
              (CompilerIrCallArgs.One (CompilerIrValue.I64 1))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
              CompilerIrInstrList.Nil))))
      CompilerIrBlockList.Nil)))

(define (opt-devirt-reach-target) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "kept_target")
    CompilerIrParamList.Nil
    (AstType.I64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "exit"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "exit")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 7)))
            CompilerIrInstrList.Nil))
        CompilerIrBlockList.Nil))))

(define (opt-devirt-reach-main) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "main")
    CompilerIrParamList.Nil
    (AstType.I64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.CallIndirect
            1
            (CompilerIrValue.Function (opt-test-symbol "kept_target"))
            CompilerIrCallArgs.Nil
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-devirt-reach-program) : CompilerIrProgram
  (CompilerIrProgram.Program
    CompilerIrGlobalList.Nil
    (compiler-ir-function-cons
      (opt-devirt-reach-main)
      (compiler-ir-function-cons
        (opt-devirt-reach-target)
        (compiler-ir-function-cons
          (opt-test-function-named "dead" (opt-global-dce-return-instrs 9))
          CompilerIrFunctionList.Nil)))
    CompilerIrExternList.Nil))

(define (opt-inline-count-binop-dst [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.BinOp d _ _ _ _)
            (if (= d dst)
              1
              0)]
          [_ 0])
        (opt-inline-count-binop-dst (box-get rest) dst))]))

(define (opt-count-direct-call-name
  [instrs : CompilerIrInstrList]
  [name : String]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.Call _ call-name _ _)
            (if (string.eq (compiler-ir-symbol-text call-name) name)
              1
              0)]
          [_ 0])
        (opt-count-direct-call-name (box-get rest) name))]))

(define (opt-count-direct-call-name-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [name : String]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-direct-call-name-instr-seq-from
      slots
      (+ index 1)
      count
      name
      (+
        acc
        (match (array-ref slots index)
          [(CompilerIrInstr.Call _ call-name _ _)
            (if (string.eq (compiler-ir-symbol-text call-name) name)
              1
              0)]
          [_ 0])))))

(define (opt-count-direct-call-name-instr-seq
  [instrs : CompilerIrInstrSeq]
  [name : String]) : i64
  (opt-count-direct-call-name-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    name
    0))

(define (opt-count-direct-call-name-blocks
  [blocks : CompilerIrBlockList]
  [name : String]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-direct-call-name-instr-seq instrs name)
            (opt-count-direct-call-name-blocks (box-get rest) name))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-direct-call-name-blocks
        (compiler-ir-block-seq-to-list seq)
        name)]))

(define (opt-count-direct-call-name-function-list
  [functions : CompilerIrFunctionList]
  [func-name : String]
  [call-name : String]) : i64
  (match (opt-function-list-find functions func-name)
    [(OptMaybeFunction.Some func)
      (opt-count-direct-call-name-blocks (opt-function-blocks func) call-name)]
    [(OptMaybeFunction.No) (- 0 1)]))

(define (opt-count-indirect-call-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.CallIndirect _ _ _ _) 1]
          [(CompilerIrInstr.CallIndirectC _ _ _ _) 1]
          [_ 0])
        (opt-count-indirect-call-instrs (box-get rest)))]))

(define (opt-inline-mov-dst-src?
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [src : i64]) : bool
  (match instrs
    [(CompilerIrInstrList.Nil) false]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.Mov d (CompilerIrValue.Var s) _)
          (if (and (= d dst) (= s src))
            true
            (opt-inline-mov-dst-src? (box-get rest) dst src))]
        [_ (opt-inline-mov-dst-src? (box-get rest) dst src)])]))

(define (opt-inline-function-instrs
  [functions : CompilerIrFunctionList]
  [name : String]) : CompilerIrInstrList
  (match (opt-function-list-find functions name)
    [(OptMaybeFunction.Some func) (opt-function-first-instrs func)]
    [(OptMaybeFunction.No) CompilerIrInstrList.Nil]))

(define (opt-inline-function-frame
  [functions : CompilerIrFunctionList]
  [name : String]) : i64
  (match (opt-function-list-find functions name)
    [(OptMaybeFunction.Some func) (opt-function-frame func)]
    [(OptMaybeFunction.No) (- 0 1)]))

(define (compiler-optimize-inline-level-gate-ok?) : bool
  (let
    [level0 : CompilerIrInstrList
      (opt-inline-function-instrs (opt-inline-level-functions 0) "main")]
    [level1 : CompilerIrInstrList
      (opt-inline-function-instrs (opt-inline-level-functions 1) "main")]
    [level2 : CompilerIrInstrList
      (opt-inline-function-instrs (opt-inline-level-functions 2) "main")]
    (and
      (= (opt-count-direct-call-name level0 "inline_add") 1)
      ;; Level 1 runs the call-free tiny-leaf pass, which admits the
      ;; inline_add fixture; only level 0 leaves the call in place.
      (= (opt-count-direct-call-name level1 "inline_add") 0)
      (= (opt-count-direct-call-name level2 "inline_add") 0))))

(define (compiler-optimize-inline-self-recursive-ok?) : bool
  (let
    [functions : CompilerIrFunctionList
      (compiler-ir-function-cons
        (opt-inline-self-recursive)
        CompilerIrFunctionList.Nil)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions functions 2)]
    [instrs : CompilerIrInstrList
      (opt-inline-function-instrs optimized "self_inline")]
    (= (opt-count-direct-call-name instrs "self_inline") 1)))

(define (compiler-optimize-inline-large-callee-ok?) : bool
  (let
    [symbols : OptInlineBoundsTestSymbols (opt-inline-bounds-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-large-functions symbols) 2)]
    [instrs : CompilerIrInstrList (opt-inline-function-instrs optimized "main")]
    (= (opt-count-direct-call-name instrs "too_large_inline") 1)))

(define (compiler-optimize-inline-bounds-callee-ok?) : bool
  (let
    [symbols : OptInlineBoundsTestSymbols (opt-inline-bounds-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-bounds-functions symbols) 2)]
    [instrs : CompilerIrInstrList (opt-inline-function-instrs optimized "main")]
    (and
      (= (opt-count-direct-call-name instrs "bounds_inline") 0)
      (= (opt-count-bounds-instrs instrs) 1)
      (match instrs
        [(CompilerIrInstrList.Cons
            (CompilerIrInstr.BoundsCheck
              (CompilerIrValue.I64 index)
              (CompilerIrValue.I64 length)
              label)
            _)
          (and
            (= index 0)
            (= length 4)
            (not (not (compiler-ir-label-some? label)))
            (not (= label (compiler-ir-label "bounds_inline.ok"))))]
        [_ false]))))

(define (compiler-optimize-inline-bounds-labels-distinct-ok?) : bool
  (let
    [symbols : OptInlineBoundsTestSymbols (opt-inline-bounds-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions
        (opt-inline-bounds-twice-functions symbols)
        2)]
    [instrs : CompilerIrInstrList (opt-inline-function-instrs optimized "main")]
    (and
      (= (opt-count-direct-call-name instrs "bounds_inline") 0)
      (= (opt-count-bounds-instrs instrs) 2)
      (match instrs
        [(CompilerIrInstrList.Cons
            (CompilerIrInstr.BoundsCheck
              (CompilerIrValue.I64 first-index)
              (CompilerIrValue.I64 first-length)
              first-label)
            rest)
          (match (box-get rest)
            [(CompilerIrInstrList.Cons _ rest2)
              (match (box-get rest2)
                [(CompilerIrInstrList.Cons
                    (CompilerIrInstr.BoundsCheck
                      (CompilerIrValue.I64 second-index)
                      (CompilerIrValue.I64 second-length)
                      second-label)
                    _)
                  (and
                    (= first-index 0)
                    (= first-length 4)
                    (= second-index 1)
                    (= second-length 4)
                    (not (not (compiler-ir-label-some? first-label)))
                    (not (not (compiler-ir-label-some? second-label)))
                    (not (= first-label second-label))
                    (not (= first-label (compiler-ir-label "bounds_inline.ok")))
                    (not
                      (= second-label (compiler-ir-label "bounds_inline.ok"))))]
                [_ false])]
            [_ false])]
        [_ false]))))

(define (compiler-optimize-inline-bounds-label-guard-ok?) : bool
  (let
    [symbols : OptInlineBoundsTestSymbols (opt-inline-bounds-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions
        (opt-inline-bounds-twice-functions symbols)
        2)]
    [duplicate : CompilerIrFunction
      (opt-inline-duplicate-bounds-label-function symbols)]
    [fallback : CompilerIrFunction
      (opt-inline-frame-caller (opt-inline-frame-test-symbols))]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (and
          (opt-inline-structure-ok? (opt-function-blocks main))
          (not (opt-inline-structure-ok? (opt-function-blocks duplicate)))
          (opt-function-eq
            (opt-inline-revert-or-keep fallback duplicate)
            fallback))]
      [(OptMaybeFunction.No) false])))

(define (compiler-optimize-inline-bounds-leaf-body-gate-ok?) : bool
  (let
    [accepted-symbols : OptInlineBoundsTestSymbols
      (opt-inline-bounds-test-symbols)]
    [rejected-symbols : OptInlineBoundsTestSymbols
      (opt-inline-bounds-test-symbols)]
    [accepted : CompilerIrFunctionList
      (opt-inline-program-functions
        (opt-inline-bounds-leaf-functions
          accepted-symbols
          (opt-inline-bounds-leaf-max-body))
        2)]
    [rejected : CompilerIrFunctionList
      (opt-inline-program-functions
        (opt-inline-bounds-leaf-functions
          rejected-symbols
          (+ (opt-inline-bounds-leaf-max-body) 1))
        2)]
    [accepted-instrs : CompilerIrInstrList
      (opt-inline-function-instrs accepted "main")]
    [rejected-instrs : CompilerIrInstrList
      (opt-inline-function-instrs rejected "main")]
    (and
      (= (opt-count-direct-call-name accepted-instrs "bounds_leaf_inline") 0)
      (= (opt-count-bounds-instrs accepted-instrs) 1)
      (= (opt-count-direct-call-name rejected-instrs "bounds_leaf_inline") 1))))

(define (compiler-optimize-inline-multi-call-ok?) : bool
  (let
    [symbols : OptInlineFrameTestSymbols (opt-inline-frame-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-multi-call-functions symbols) 2)]
    [instrs : CompilerIrInstrList (opt-inline-function-instrs optimized "main")]
    [frame : i64 (opt-inline-function-frame optimized "main")]
    (cond
      [(not (= frame 8)) false]
      [(not (= (compiler-ir-instr-list-count instrs) 7)) false]
      [(not (= (opt-count-direct-call-name instrs "inline_add") 0)) false]
      [(not (= (opt-inline-count-binop-dst instrs 6) 1)) false]
      [(not (= (opt-inline-count-binop-dst instrs 7) 1)) false]
      [(not (opt-inline-mov-dst-src? instrs 2 6)) false]
      [(not (opt-inline-mov-dst-src? instrs 3 7)) false]
      [else true])))

(define (compiler-optimize-inline-bottom-up-writeback-ok?) : bool
  (let
    [symbols : OptInlineFrameTestSymbols (opt-inline-frame-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-cascade-functions symbols) 2)]
    [main-instrs : CompilerIrInstrList
      (opt-inline-function-instrs optimized "main")]
    [mid-instrs : CompilerIrInstrList
      (opt-inline-function-instrs optimized "inline_mid")]
    (and
      (= (opt-count-direct-call-name main-instrs "inline_mid") 0)
      (= (opt-count-direct-call-name main-instrs "inline_add") 0)
      (= (opt-inline-count-binop-dst main-instrs 4) 1)
      (= (opt-count-direct-call-name mid-instrs "inline_add") 0)
      (= (opt-inline-count-binop-dst mid-instrs 3) 1))))

(define (compiler-optimize-inline-mutual-scc-refusal-ok?) : bool
  (let
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-mutual-functions) 2)]
    [a-instrs : CompilerIrInstrList
      (opt-inline-function-instrs optimized "inline_mut_a")]
    [b-instrs : CompilerIrInstrList
      (opt-inline-function-instrs optimized "inline_mut_b")]
    (and
      (= (opt-count-direct-call-name a-instrs "inline_mut_b") 1)
      (= (opt-count-direct-call-name a-instrs "inline_mut_a") 0)
      (= (opt-count-direct-call-name b-instrs "inline_mut_a") 1)
      (= (opt-count-direct-call-name b-instrs "inline_mut_b") 0))))

(define (opt-inline-pack-words-are-vars-1-2? [words : CompilerIrValueList]) : bool
  (match (compiler-ir-value-list-force-cons words)
    [(CompilerIrValueList.Cons a arest)
      (match a
        [(CompilerIrValue.Var av)
          (match (box-get arest)
            [(CompilerIrValueList.Cons b brest)
              (match b
                [(CompilerIrValue.Var bv)
                  (match (box-get brest)
                    [(CompilerIrValueList.Nil) (and (= av 1) (= bv 2))]
                    [_ false])]
                [_ false])]
            [_ false])]
        [_ false])]
    [_ false]))

;; True when the inlined body contains a Pack reading the CALLER's argument
;; vars (1/2, remapped from the callee's params 0/1) and a Word whose source
;; is that Pack's (rebased) destination.
(define (opt-inline-pack-word-remap-ok-scan
  [instrs : CompilerIrInstrList]
  [pack-dst : i64]
  [pack-ok : bool]
  [word-ok : bool]) : bool
  (match instrs
    [(CompilerIrInstrList.Nil) (and pack-ok word-ok)]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.Pack dst words _)
          (opt-inline-pack-word-remap-ok-scan
            (box-get rest)
            dst
            (opt-inline-pack-words-are-vars-1-2? words)
            word-ok)]
        [(CompilerIrInstr.Word _ src _ _)
          (opt-inline-pack-word-remap-ok-scan
            (box-get rest)
            pack-dst
            pack-ok
            (match src
              [(CompilerIrValue.Var sv) (= sv pack-dst)]
              [_ false]))]
        [_
          (opt-inline-pack-word-remap-ok-scan
            (box-get rest)
            pack-dst
            pack-ok
            word-ok)])]))

(define (compiler-optimize-inline-pack-word-ok?) : bool
  (let
    [symbols : OptInlineFrameTestSymbols (opt-inline-frame-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-pack-word-functions symbols) 2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (and
          (=
            (opt-count-direct-call-name
              (opt-function-first-instrs main)
              "inline_group_word")
            0)
          (opt-inline-pack-word-remap-ok-scan
            (opt-function-first-instrs main)
            (- 0 1)
            false
            false))]
      [(OptMaybeFunction.No) false])))

(define (opt-inline-branch-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 0)
    CompilerIrParamList.Nil))

(define (opt-inline-branch-callee-mov) : CompilerIrInstr
  (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 7) (AstType.I64)))

(defstruct OptInlineMultiTestSymbols
  (main i64)
  (inline-branch i64)
  (inline-tiny-predicate i64)
  (inline-loop i64)
  (mb-bounds i64)
  (inline-switch i64)
  (inline-switch-costly i64)
  (inline-mut-param-loop i64)
  (inline-nonleaf i64)
  (external-helper i64)
  (inline-tiny-nonleaf-predicate i64)
  (external-predicate i64))

(define (opt-inline-multi-test-symbols) : OptInlineMultiTestSymbols
  (OptInlineMultiTestSymbols
    (opt-test-symbol "main")
    (opt-test-symbol "inline_branch")
    (opt-test-symbol "inline_tiny_predicate")
    (opt-test-symbol "inline_loop")
    (opt-test-symbol "mb_bounds")
    (opt-test-symbol "inline_switch")
    (opt-test-symbol "inline_switch_costly")
    (opt-test-symbol "inline_mut_param_loop")
    (opt-test-symbol "inline_nonleaf")
    (opt-test-symbol "external_helper")
    (opt-test-symbol "inline_tiny_nonleaf_predicate")
    (opt-test-symbol "external_predicate")))

(define (opt-inline-branch-callee [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols inline-branch)
    (opt-inline-branch-params)
    (AstType.I64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "then")
            (compiler-ir-label "else"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "then")
          (compiler-ir-instr-cons
            (opt-inline-branch-callee-mov)
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "else")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 42)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(define (opt-inline-branch-caller-call [symbols : OptInlineMultiTestSymbols]) : CompilerIrInstr
  (CompilerIrInstr.Call
    0
    (struct-get symbols inline-branch)
    (CompilerIrCallArgs.One (CompilerIrValue.Bool true))
    (AstType.I64)))

(define (opt-inline-branch-caller [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (opt-inline-branch-caller-call symbols)
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-branch-functions [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-branch-caller symbols)
    (compiler-ir-function-cons
      (opt-inline-branch-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (opt-inline-repeated-predicate-callee
  [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols inline-tiny-predicate)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "value" (AstType.I64) 0)
      CompilerIrParamList.Nil)
    (AstType.Bool)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            1
            (CompilerIrBinOp.Lt)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.I64 10)
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 1)
              (compiler-ir-label "yes")
              (compiler-ir-label "no"))
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "yes")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Bool true)))
            CompilerIrInstrList.Nil))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "no")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Bool false)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(define (opt-inline-repeated-predicate-caller
  [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.Bool)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            0
            (struct-get symbols inline-tiny-predicate)
            (CompilerIrCallArgs.One (CompilerIrValue.I64 7))
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "second")
              (compiler-ir-label "done"))
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "second")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Call
              1
              (struct-get symbols inline-tiny-predicate)
              (CompilerIrCallArgs.One (CompilerIrValue.I64 12))
              (AstType.Bool))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "done")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Bool false)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(define (opt-inline-repeated-predicate-functions
  [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-repeated-predicate-caller symbols)
    (compiler-ir-function-cons
      (opt-inline-repeated-predicate-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (compiler-optimize-inline-repeated-tiny-predicate-ok?) : bool
  (let
    [level0-symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [level1-symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [level2-symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [level0 : CompilerIrFunctionList
      (opt-inline-program-functions
        (opt-inline-repeated-predicate-functions level0-symbols)
        0)]
    [level1 : CompilerIrFunctionList
      (opt-inline-program-functions
        (opt-inline-repeated-predicate-functions level1-symbols)
        1)]
    [level2 : CompilerIrFunctionList
      (opt-inline-program-functions
        (opt-inline-repeated-predicate-functions level2-symbols)
        2)]
    (match (opt-function-list-find level2 "main")
      [(OptMaybeFunction.Some main)
        (let
          [blocks : CompilerIrBlockList (opt-function-blocks main)]
          (and
            (=
              (opt-count-direct-call-name-function-list
                level0
                "main"
                "inline_tiny_predicate")
              2)
            (=
              (opt-count-direct-call-name-function-list
                level1
                "main"
                "inline_tiny_predicate")
              2)
            (=
              (opt-count-direct-call-name-blocks blocks "inline_tiny_predicate")
              0)
            (opt-inline-structure-ok? blocks)))]
      [(OptMaybeFunction.No) false])))

(define (compiler-optimize-inline-multiblock-ok?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-branch-functions symbols) 2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (let
          [blocks : CompilerIrBlockList (opt-function-blocks main)]
          (and
            (= (opt-count-direct-call-name-blocks blocks "inline_branch") 0)
            (= (compiler-ir-block-list-count blocks) 5)
            (= (opt-count-phi-blocks blocks) 1)
            (= (opt-function-frame main) 2)
            (opt-inline-structure-ok? blocks)))]
      [(OptMaybeFunction.No) false])))

(define (opt-inline-loop-callee [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols inline-loop)
    CompilerIrParamList.Nil
    (AstType.I64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "loop")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Bool true)
              (compiler-ir-label "loop")
              (compiler-ir-label "exit"))
            CompilerIrInstrList.Nil))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 1)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(define (opt-inline-loop-caller [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            0
            (struct-get symbols inline-loop)
            CompilerIrCallArgs.Nil
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-loop-functions [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-loop-caller symbols)
    (compiler-ir-function-cons
      (opt-inline-loop-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (compiler-optimize-inline-multiblock-acyclic-ok?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-loop-functions symbols) 2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (let
          [blocks : CompilerIrBlockList (opt-function-blocks main)]
          (and
            (= (opt-count-direct-call-name-blocks blocks "inline_loop") 0)
            (= (compiler-ir-block-list-count blocks) 5)
            (= (opt-count-phi-blocks blocks) 0)
            (opt-inline-structure-ok? blocks)))]
      [(OptMaybeFunction.No) false])))

;; Multiblock bounds-carrying absorbable callee: with BoundsCheck admitted to
;; the multiblock instruction set, a single-call-site helper whose body
;; contains a check must inline (the absorb bonus), with its ok-label
;; freshened by the site prefix so the caller's labels stay unique.
(define (opt-inline-mb-bounds-callee [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols mb-bounds)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "idx" (AstType.I64) 0)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "len" (AstType.I64) 1)
        CompilerIrParamList.Nil))
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BoundsCheck
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            (compiler-ir-label "mb_ok"))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Bool true)
              (compiler-ir-label "then")
              (compiler-ir-label "else"))
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "then")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
            CompilerIrInstrList.Nil))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "else")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(define (opt-inline-mb-bounds-caller [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "a" (AstType.I64) 0)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "b" (AstType.I64) 1)
        CompilerIrParamList.Nil))
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            2
            (struct-get symbols mb-bounds)
            (CompilerIrCallArgs.Two
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 1))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (compiler-optimize-inline-multiblock-bounds-ok?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions
        (compiler-ir-function-cons
          (opt-inline-mb-bounds-caller symbols)
          (compiler-ir-function-cons
            (opt-inline-mb-bounds-callee symbols)
            CompilerIrFunctionList.Nil))
        2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (let
          [blocks : CompilerIrBlockList (opt-function-blocks main)]
          (and
            (= (opt-count-direct-call-name-blocks blocks "mb_bounds") 0)
            (= (opt-count-bounds-blocks blocks) 1)
            (opt-inline-structure-ok? blocks)))]
      [(OptMaybeFunction.No) false])))

(define (opt-inline-switch-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "tag" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "idx" (AstType.I64) 1)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "len" (AstType.I64) 2)
        CompilerIrParamList.Nil))))

(define (opt-inline-switch-cases [zero-label : i64] [one-label : i64]) : CompilerIrSwitchCaseList
  (compiler-ir-switch-case-cons
    0
    zero-label
    (compiler-ir-switch-case-cons 1 one-label CompilerIrSwitchCaseList.Nil)))

(define (opt-inline-switch-loop-bounds-instr [ok-label : i64]) : CompilerIrInstr
  (CompilerIrInstr.BoundsCheck
    (CompilerIrValue.Var 1)
    (CompilerIrValue.Var 2)
    ok-label))

(define (opt-inline-switch-loop-phi-instr) : CompilerIrInstr
  (CompilerIrInstr.Phi
    3
    (compiler-ir-phi-input-cons
      (CompilerIrValue.I64 10)
      (compiler-ir-label "zero")
      (compiler-ir-phi-input-cons
        (CompilerIrValue.I64 20)
        (compiler-ir-label "one")
        CompilerIrPhiInputList.Nil))
    (AstType.I64)))

;; A cyclic bounds-carrying Switch callee remains behind the acyclic gate even
;; when absorbable, unless its exact IR-symbol leaf is the measured `vm-run`
;; exception.
(define (opt-inline-switch-callee-named [callee-name : i64]) : CompilerIrFunction
  (CompilerIrFunction.Function
    callee-name
    (opt-inline-switch-params)
    (AstType.I64)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "loop")
          (compiler-ir-instr-cons
            (opt-inline-switch-loop-bounds-instr
              (compiler-ir-label "switch_bounds_ok"))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Switch
                (CompilerIrValue.Var 0)
                0
                (opt-inline-switch-cases
                  (compiler-ir-label "zero")
                  (compiler-ir-label "one"))
                (compiler-ir-label "loop"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "zero")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "one")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "join"))
                CompilerIrInstrList.Nil))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "join")
                (compiler-ir-instr-cons
                  (opt-inline-switch-loop-phi-instr)
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return
                      (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                    CompilerIrInstrList.Nil)))
              CompilerIrBlockList.Nil)))))))

(define (opt-inline-switch-callee [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (opt-inline-switch-callee-named (struct-get symbols inline-switch)))

;; The acyclic counterpart exercises Switch admission and label remapping. Its
;; join phi makes stale, unprefixed case/default predecessor labels observable.
(define (opt-inline-acyclic-switch-callee [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols inline-switch)
    (opt-inline-switch-params)
    (AstType.I64)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BoundsCheck
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 2)
            (compiler-ir-label "switch_bounds_ok"))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Switch
              (CompilerIrValue.Var 0)
              0
              (opt-inline-switch-cases
                (compiler-ir-label "zero")
                (compiler-ir-label "one"))
              (compiler-ir-label "other"))
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "zero")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            CompilerIrInstrList.Nil))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "one")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "other")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "join"))
                CompilerIrInstrList.Nil))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "join")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Phi
                    3
                    (compiler-ir-phi-input-cons
                      (CompilerIrValue.I64 10)
                      (compiler-ir-label "zero")
                      (compiler-ir-phi-input-cons
                        (CompilerIrValue.I64 20)
                        (compiler-ir-label "one")
                        (compiler-ir-phi-input-cons
                          (CompilerIrValue.I64 30)
                          (compiler-ir-label "other")
                          CompilerIrPhiInputList.Nil)))
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return
                      (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                    CompilerIrInstrList.Nil)))
              CompilerIrBlockList.Nil)))))))

(define (opt-inline-switch-caller-call-named [callee-name : i64]) : CompilerIrInstr
  (let
    [args : (Array CompilerIrValue) (array.make-array CompilerIrValue 3)]
    (begin
      ;; Swap the first two arguments so the Switch scrutinee and BoundsCheck
      ;; index must both be remapped rather than retaining their callee ids.
      (array-set! args 0 (CompilerIrValue.Var 1))
      (array-set! args 1 (CompilerIrValue.Var 0))
      (array-set! args 2 (CompilerIrValue.Var 2))
      (CompilerIrInstr.Call
        3
        callee-name
        (CompilerIrCallArgs.Array args)
        (AstType.I64)))))

(define (opt-inline-switch-caller-named
  [symbols : OptInlineMultiTestSymbols]
  [callee-name : i64]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    (opt-inline-switch-params)
    (AstType.I64)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (opt-inline-switch-caller-call-named callee-name)
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-switch-caller [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (opt-inline-switch-caller-named symbols (struct-get symbols inline-switch)))

(define (opt-inline-cloned-switch-terminator-ok? [blocks : CompilerIrBlockList]) : bool
  (match (opt-cfg-find-block blocks (compiler-ir-label "inl.entry.0.entry"))
    [(OptMaybeBlock.No) false]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (if (= (compiler-ir-instr-seq-count instrs) 2)
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.BoundsCheck _ _ ok-label)
                (and
                  (=
                    ok-label
                    (compiler-ir-label "inl.entry.0.switch_bounds_ok"))
                  (match (compiler-ir-instr-seq-ref instrs 1)
                    [(CompilerIrInstr.Switch value tag-base cases default-label)
                      (let
                        [case-labels : OptLabelSet
                          (opt-cfg-switch-case-successors OptLabelSet.Nil cases)]
                        (and
                          (match value
                            [(CompilerIrValue.Var id) (= id 1)]
                            [_ false])
                          (= tag-base 0)
                          (= (opt-label-count case-labels) 2)
                          (opt-label-contains
                            case-labels
                            (compiler-ir-label "inl.entry.0.zero"))
                          (opt-label-contains
                            case-labels
                            (compiler-ir-label "inl.entry.0.one"))
                          (=
                            default-label
                            (compiler-ir-label "inl.entry.0.other"))))]
                    [_ false]))]
              [_ false])
            false)])]))

(define (opt-inline-cloned-switch-phi-ok? [blocks : CompilerIrBlockList]) : bool
  (match (opt-cfg-find-block blocks (compiler-ir-label "inl.entry.0.join"))
    [(OptMaybeBlock.No) false]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (if (> (compiler-ir-instr-seq-count instrs) 0)
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.Phi _ inputs _)
                (and
                  (= (compiler-ir-phi-input-list-count inputs) 3)
                  (opt-inline-phi-input-label?
                    inputs
                    (compiler-ir-label "inl.entry.0.zero"))
                  (opt-inline-phi-input-label?
                    inputs
                    (compiler-ir-label "inl.entry.0.one"))
                  (opt-inline-phi-input-label?
                    inputs
                    (compiler-ir-label "inl.entry.0.other")))]
              [_ false])
            false)])]))

(define (compiler-optimize-inline-multiblock-switch-ok?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions
        (compiler-ir-function-cons
          (opt-inline-switch-caller symbols)
          (compiler-ir-function-cons
            (opt-inline-acyclic-switch-callee symbols)
            CompilerIrFunctionList.Nil))
        2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (let
          [blocks : CompilerIrBlockList (opt-function-blocks main)]
          (and
            (= (opt-count-direct-call-name-blocks blocks "inline_switch") 0)
            (= (opt-count-bounds-blocks blocks) 1)
            (opt-inline-cloned-switch-terminator-ok? blocks)
            (opt-inline-cloned-switch-phi-ok? blocks)
            (opt-inline-structure-ok? blocks)))]
      [(OptMaybeFunction.No) false])))

(define (compiler-optimize-inline-multiblock-cyclic-bounds-switch-refusal-ok?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions
        (compiler-ir-function-cons
          (opt-inline-switch-caller symbols)
          (compiler-ir-function-cons
            (opt-inline-switch-callee symbols)
            CompilerIrFunctionList.Nil))
        2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (let
          [blocks : CompilerIrBlockList (opt-function-blocks main)]
          (and
            (= (opt-count-direct-call-name-blocks blocks "inline_switch") 1)
            (= (opt-count-bounds-blocks blocks) 0)
            (opt-inline-structure-ok? blocks)))]
      [(OptMaybeFunction.No) false])))

(define (opt-inline-switch-functions-named
  [symbols : OptInlineMultiTestSymbols]
  [callee-name : i64]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-switch-caller-named symbols callee-name)
    (compiler-ir-function-cons
      (opt-inline-switch-callee-named callee-name)
      CompilerIrFunctionList.Nil)))

(define (opt-inline-switch-case-result-ok?
  [functions : CompilerIrFunctionList]
  [callee-text : String]
  [expected-calls : i64]
  [expected-bounds : i64]) : bool
  (match (opt-function-list-find functions "main")
    [(OptMaybeFunction.Some main)
      (let
        [blocks : CompilerIrBlockList (opt-function-blocks main)]
        (and
          (=
            (opt-count-direct-call-name-blocks blocks callee-text)
            expected-calls)
          (= (opt-count-bounds-blocks blocks) expected-bounds)
          (opt-inline-structure-ok? blocks)))]
    [(OptMaybeFunction.No) false]))

(define (compiler-optimize-inline-vm-run-bounds-loop-ok?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [vm-text : String "bench.tl::vm-run"]
    [other-text : String "bench.tl::qs-partition"]
    [vm-name : i64 (opt-test-symbol vm-text)]
    [other-name : i64 (opt-test-symbol other-text)]
    [vm-opt2 : CompilerIrFunctionList
      (opt-inline-program-functions
        (opt-inline-switch-functions-named symbols vm-name)
        2)]
    [other-opt2 : CompilerIrFunctionList
      (opt-inline-program-functions
        (opt-inline-switch-functions-named symbols other-name)
        2)]
    [vm-opt1 : CompilerIrFunctionList
      (opt-inline-program-functions
        (opt-inline-switch-functions-named symbols vm-name)
        1)]
    (and
      (opt-inline-switch-case-result-ok? vm-opt2 vm-text 0 1)
      (opt-inline-switch-case-result-ok? other-opt2 other-text 1 0)
      (opt-inline-switch-case-result-ok? vm-opt1 vm-text 1 0))))

(define (opt-inline-phi-span-ok-instr-seq-from?
  [instrs : CompilerIrInstrSeq]
  [pos : i64]
  [spans : CompilerSourceSpans]
  [caller-name : i64]
  [line : i64]
  [col : i64]) : bool
  (if (>= pos (compiler-ir-instr-seq-count instrs))
    false
    (let
      [instr : CompilerIrInstr (compiler-ir-instr-seq-ref instrs pos)]
      (or
        (match instr
          [(CompilerIrInstr.Phi _ _ _)
            (opt-span-lookup-ok? spans caller-name instr line col)]
          [_ false])
        (opt-inline-phi-span-ok-instr-seq-from?
          instrs
          (+ pos 1)
          spans
          caller-name
          line
          col)))))

(define (opt-inline-phi-span-ok-blocks?
  [blocks : CompilerIrBlockList]
  [spans : CompilerSourceSpans]
  [caller-name : i64]
  [line : i64]
  [col : i64]) : bool
  (match blocks
    [(CompilerIrBlockList.Nil) false]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (or
            (opt-inline-phi-span-ok-instr-seq-from?
              instrs
              0
              spans
              caller-name
              line
              col)
            (opt-inline-phi-span-ok-blocks?
              (box-get rest)
              spans
              caller-name
              line
              col))])]
    [(CompilerIrBlockList.Array seq)
      (opt-inline-phi-span-ok-blocks?
        (compiler-ir-block-seq-to-list seq)
        spans
        caller-name
        line
        col)]))

(define (opt-inline-switch-span-case-code
  [callee-text : String]
  [expect-inline? : bool]) : i64
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [callee-name : i64 (opt-test-symbol callee-text)]
    [caller-name : i64 (struct-get symbols main)]
    [callee-phi : CompilerIrInstr (opt-inline-switch-loop-phi-instr)]
    [caller-call : CompilerIrInstr
      (opt-inline-switch-caller-call-named callee-name)]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert-instr
          (opt-spans-base)
          callee-name
          callee-phi
          (opt-test-span 171 33))
        caller-name
        caller-call
        (opt-test-span 181 35))]
    (match (opt-inline-program-functions-with-spans
      (opt-inline-switch-functions-named symbols callee-name)
      2
      spans)
      [(OptInlineSpanProgram.Program optimized optimized-spans)
        (match (opt-function-list-find optimized "main")
          [(OptMaybeFunction.Some main)
            (let
              [blocks : CompilerIrBlockList (opt-function-blocks main)]
              (+
                (if (=
                  (opt-count-direct-call-name-blocks blocks callee-text)
                  (if expect-inline?
                    0
                    1))
                  1
                  0)
                (+
                  (if (=
                    (opt-count-bounds-blocks blocks)
                    (if expect-inline?
                      1
                      0))
                    2
                    0)
                  (+
                    (if (if expect-inline?
                      (opt-inline-phi-span-ok-blocks?
                        blocks
                        optimized-spans
                        caller-name
                        171
                        33)
                      (opt-span-lookup-ok?
                        optimized-spans
                        caller-name
                        caller-call
                        181
                        35))
                      4
                      0)
                    (if (opt-inline-structure-ok? blocks)
                      8
                      0)))))]
          [(OptMaybeFunction.No) 0])])))

(define (compiler-optimize-spans-inline-vm-run-bounds-loop-ok?) : bool
  (and
    (= (opt-inline-switch-span-case-code "bench.tl::vm-run" true) 15)
    (= (opt-inline-switch-span-case-code "bench.tl::qs-partition" false) 15)))

(define (opt-inline-costly-switch-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "tag" (AstType.I64) 0)
    CompilerIrParamList.Nil))

;; Five body instructions plus six added blocks leave this non-absorbable i64
;; callee above the weighted threshold even with a constant argument at each
;; of its two sites. Switch admission must not bypass that cost decision.
(define (opt-inline-costly-switch-callee [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols inline-switch-costly)
    (opt-inline-costly-switch-params)
    (AstType.I64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Switch
            (CompilerIrValue.Var 0)
            0
            (opt-inline-switch-cases
              (compiler-ir-label "zero")
              (compiler-ir-label "one"))
            (compiler-ir-label "other"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "zero")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            CompilerIrInstrList.Nil))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "one")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "other")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "join"))
                CompilerIrInstrList.Nil))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "join")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Phi
                    1
                    (compiler-ir-phi-input-cons
                      (CompilerIrValue.I64 10)
                      (compiler-ir-label "zero")
                      (compiler-ir-phi-input-cons
                        (CompilerIrValue.I64 20)
                        (compiler-ir-label "one")
                        (compiler-ir-phi-input-cons
                          (CompilerIrValue.I64 30)
                          (compiler-ir-label "other")
                          CompilerIrPhiInputList.Nil)))
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return
                      (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
                    CompilerIrInstrList.Nil)))
              CompilerIrBlockList.Nil)))))))

(define (opt-inline-costly-switch-caller [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            0
            (struct-get symbols inline-switch-costly)
            (CompilerIrCallArgs.One (CompilerIrValue.I64 0))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Call
              1
              (struct-get symbols inline-switch-costly)
              (CompilerIrCallArgs.One (CompilerIrValue.I64 1))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                2
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 0)
                (CompilerIrValue.Var 1)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
                CompilerIrInstrList.Nil)))))
      CompilerIrBlockList.Nil)))

(define (compiler-optimize-inline-multiblock-switch-cost-refusal-ok?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions
        (compiler-ir-function-cons
          (opt-inline-costly-switch-caller symbols)
          (compiler-ir-function-cons
            (opt-inline-costly-switch-callee symbols)
            CompilerIrFunctionList.Nil))
        2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (let
          [blocks : CompilerIrBlockList (opt-function-blocks main)]
          (and
            (=
              (opt-count-direct-call-name-blocks blocks "inline_switch_costly")
              2)
            (opt-inline-structure-ok? blocks)))]
      [(OptMaybeFunction.No) false])))

(define (opt-inline-mut-param-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "n" (AstType.I64) 0)
    CompilerIrParamList.Nil))

(define (opt-inline-mut-param-callee [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols inline-mut-param-loop)
    (opt-inline-mut-param-params)
    (AstType.I64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "loop")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              0
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.I64 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Bool false)
                (compiler-ir-label "loop")
                (compiler-ir-label "exit"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(define (opt-inline-mut-param-caller [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            0
            (struct-get symbols inline-mut-param-loop)
            (CompilerIrCallArgs.One (CompilerIrValue.I64 4))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-mut-param-functions [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-mut-param-caller symbols)
    (compiler-ir-function-cons
      (opt-inline-mut-param-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (compiler-optimize-inline-mut-param-loop-ok?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-mut-param-functions symbols) 2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (let
          [blocks : CompilerIrBlockList (opt-function-blocks main)]
          (and
            (=
              (opt-count-direct-call-name-blocks blocks "inline_mut_param_loop")
              0)
            (= (compiler-ir-block-list-count blocks) 5)
            (opt-verify-ok? (opt-verify-function main))))]
      [(OptMaybeFunction.No) false])))

(define (opt-inline-caller-phi-loop-caller
  [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            0
            (struct-get symbols inline-loop)
            CompilerIrCallArgs.Nil
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Bool true)
              (compiler-ir-label "left")
              (compiler-ir-label "right"))
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "left")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            CompilerIrInstrList.Nil))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "right")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "join")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Phi
                  1
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.I64 7)
                    (compiler-ir-label "left")
                    (compiler-ir-phi-input-cons
                      (CompilerIrValue.I64 9)
                      (compiler-ir-label "right")
                      CompilerIrPhiInputList.Nil))
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
                  CompilerIrInstrList.Nil)))
            CompilerIrBlockList.Nil))))))

(define (opt-inline-caller-phi-loop-functions
  [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-caller-phi-loop-caller symbols)
    (compiler-ir-function-cons
      (opt-inline-loop-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (compiler-optimize-inline-caller-phi-loop-ok?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions
        (opt-inline-caller-phi-loop-functions symbols)
        2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (let
          [blocks : CompilerIrBlockList (opt-function-blocks main)]
          (and
            (= (opt-count-direct-call-name-blocks blocks "inline_loop") 0)
            (= (compiler-ir-block-list-count blocks) 8)
            (= (opt-count-phi-blocks blocks) 1)
            (opt-inline-structure-ok? blocks)))]
      [(OptMaybeFunction.No) false])))

(define (opt-inline-nonleaf-callee [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols inline-nonleaf)
    CompilerIrParamList.Nil
    (AstType.I64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Bool true)
            (compiler-ir-label "call")
            (compiler-ir-label "ret"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "call")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Call
              0
              (struct-get symbols external-helper)
              CompilerIrCallArgs.Nil
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "ret")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 3)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(define (opt-inline-nonleaf-caller [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.I64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            0
            (struct-get symbols inline-nonleaf)
            CompilerIrCallArgs.Nil
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (opt-inline-nonleaf-functions [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-nonleaf-caller symbols)
    (compiler-ir-function-cons
      (opt-inline-nonleaf-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (compiler-optimize-inline-multiblock-nonleaf-ok?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-nonleaf-functions symbols) 2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (let
          [blocks : CompilerIrBlockList (opt-function-blocks main)]
          (and
            (= (opt-count-direct-call-name-blocks blocks "inline_nonleaf") 0)
            (= (opt-count-direct-call-name-blocks blocks "external_helper") 1)
            (= (opt-count-phi-blocks blocks) 1)
            (opt-inline-structure-ok? blocks)))]
      [(OptMaybeFunction.No) false])))

(define (opt-inline-repeated-nonleaf-predicate-callee
  [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols inline-tiny-nonleaf-predicate)
    CompilerIrParamList.Nil
    (AstType.Bool)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Bool true)
            (compiler-ir-label "call")
            (compiler-ir-label "ret"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "call")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Call
              1
              (struct-get symbols external-predicate)
              CompilerIrCallArgs.Nil
              (AstType.Bool))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "ret")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Bool false)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(define (opt-inline-repeated-nonleaf-predicate-caller
  [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (struct-get symbols main)
    CompilerIrParamList.Nil
    (AstType.Bool)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            0
            (struct-get symbols inline-tiny-nonleaf-predicate)
            CompilerIrCallArgs.Nil
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "second")
              (compiler-ir-label "done"))
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "second")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Call
              1
              (struct-get symbols inline-tiny-nonleaf-predicate)
              CompilerIrCallArgs.Nil
              (AstType.Bool))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "done")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Bool false)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(define (opt-inline-repeated-nonleaf-predicate-functions
  [symbols : OptInlineMultiTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-repeated-nonleaf-predicate-caller symbols)
    (compiler-ir-function-cons
      (opt-inline-repeated-nonleaf-predicate-callee symbols)
      CompilerIrFunctionList.Nil)))

(define (compiler-optimize-inline-repeated-nonleaf-predicate-refusal-ok?) : bool
  (let
    [symbols : OptInlineMultiTestSymbols (opt-inline-multi-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions
        (opt-inline-repeated-nonleaf-predicate-functions symbols)
        2)]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (let
          [blocks : CompilerIrBlockList (opt-function-blocks main)]
          (and
            (=
              (opt-count-direct-call-name-blocks
                blocks
                "inline_tiny_nonleaf_predicate")
              2)
            (opt-inline-structure-ok? blocks)))]
      [(OptMaybeFunction.No) false])))

(define (compiler-optimize-inline-census-direct-ok?) : bool
  (let
    [symbols : OptInlineFrameTestSymbols (opt-inline-frame-test-symbols)]
    [functions : CompilerIrFunctionList (opt-inline-frame-functions symbols)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [census : OptInlineCensus (opt-inline-census-build index functions)]
    (and
      (=
        (opt-inline-census-refcount
          index
          census
          (struct-get symbols inline-add))
        1)
      (not
        (opt-inline-census-address-taken?
          index
          census
          (struct-get symbols inline-add)))
      (opt-inline-census-absorbable?
        index
        census
        (struct-get symbols main)
        (struct-get symbols inline-add)))))

(define (compiler-optimize-inline-census-address-ok?) : bool
  (let
    [symbols : OptInlineFrameTestSymbols (opt-inline-frame-test-symbols)]
    [functions : CompilerIrFunctionList
      (opt-inline-known-indirect-functions symbols)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [census : OptInlineCensus (opt-inline-census-build index functions)]
    (and
      (opt-inline-census-address-taken?
        index
        census
        (struct-get symbols inline-add))
      (not
        (opt-inline-census-absorbable?
          index
          census
          (struct-get symbols main)
          (struct-get symbols inline-add))))))

(define (compiler-optimize-inline-cost-model-ok?) : bool
  (and
    (opt-inline-bounds-leaf-return-type? (AstType.I64))
    (opt-inline-bounds-leaf-return-type? (AstType.Bool))
    (opt-inline-bounds-leaf-return-type? (AstType.Unit))
    (not (opt-inline-bounds-leaf-return-type? (AstType.String)))
    (opt-inline-value-constant? (CompilerIrValue.I64 7))
    (not (opt-inline-value-constant? (CompilerIrValue.Var 7)))
    (=
      (opt-inline-args-const-count
        (CompilerIrCallArgs.Two (CompilerIrValue.I64 1) (CompilerIrValue.Var 2)))
      1)
    (opt-inline-cost-inline? 8 0 0 false 64 0)
    (not (opt-inline-cost-inline? 10 3 0 false 10 0))
    (opt-inline-cost-inline? 10 3 0 true 10 0)
    (not
      (opt-inline-cost-inline? 1 1 0 true (opt-inline-heavy-gate-block-limit) 0))
    (not (opt-inline-cost-inline? 1 1 0 true 80 32))
    (opt-inline-cost-inline? 8 1 8 false 10 0)
    (not (opt-inline-bounds-inline-ok? true false 1 2))
    (opt-inline-bounds-inline-ok? true false 2 2)
    (opt-inline-bounds-inline-ok? true true 0 2)
    (opt-inline-bounds-inline-ok? false false 0 2)))

(define (compiler-optimize-inline-multiblock-return-gate-ok?) : bool
  (let
    [direct-params : CompilerIrParamList
      (compiler-ir-param-cons
        (CompilerIrParam.Param "value" (AstType.I64) 0)
        CompilerIrParamList.Nil)]
    [enum-ty : AstType (AstType.Enum (opt-test-symbol "InlineReturnEnum"))]
    [sret-params : CompilerIrParamList
      (compiler-ir-param-cons
        (CompilerIrParam.Param "__sret" (ast-ty-mut-ptr enum-ty) 0)
        direct-params)]
    (and
      (not (opt-inline-multiblock-return-type-ok? direct-params enum-ty))
      (opt-inline-multiblock-return-type-ok? direct-params (AstType.I64))
      (opt-inline-multiblock-return-type-ok? direct-params (AstType.Unit))
      (opt-inline-multiblock-return-type-ok? sret-params enum-ty))))

(define (compiler-optimize-inline-self-test) : i64
  (let
    [symbols : OptInlineFrameTestSymbols (opt-inline-frame-test-symbols)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-frame-functions symbols) 2)]
    [devirt-direct : CompilerIrFunction
      (opt-devirt-known-function-function
        (opt-inline-known-indirect-caller symbols))]
    [devirt-dynamic : CompilerIrFunction
      (opt-devirt-known-function-function (opt-devirt-dynamic-caller))]
    [devirt-inlined : CompilerIrFunctionList
      (opt-inline-program-functions
        (opt-inline-known-indirect-functions symbols)
        2)]
    [devirt-reach : CompilerIrFunctionList
      (opt-program-functions
        (optimize-program-with-level (opt-devirt-reach-program) 2))]
    [valid-structure : bool
      (opt-inline-structure-ok?
        (opt-function-blocks (opt-inline-frame-caller symbols)))]
    [duplicate-def-structure : bool
      (opt-inline-structure-ok?
        (opt-function-blocks (opt-ssa-duplicate-def-function)))]
    [duplicate-label-revert : CompilerIrFunction
      (opt-inline-revert-or-keep
        (opt-inline-frame-caller symbols)
        (opt-ssa-duplicate-label-function))]
    [unknown-successor-revert : CompilerIrFunction
      (opt-inline-revert-or-keep
        (opt-inline-frame-caller symbols)
        (opt-ssa-unknown-successor-function))]
    [bad-phi-revert : CompilerIrFunction
      (opt-inline-revert-or-keep
        (opt-inline-frame-caller symbols)
        (opt-ssa-bad-phi-function))]
    [valid-keep : CompilerIrFunction
      (opt-inline-revert-or-keep
        (opt-inline-frame-caller symbols)
        (opt-inline-frame-callee symbols))]
    (match (opt-function-list-find optimized "main")
      [(OptMaybeFunction.Some main)
        (let
          [instrs : CompilerIrInstrList (opt-function-first-instrs main)]
          (begin
            (unless (= (opt-function-frame main) 4) (return 1))
            (unless (= (compiler-ir-instr-list-count instrs) 5) (return 2))
            (unless (= (opt-inline-count-binop-dst instrs 3) 1) (return 3))
            (unless (= (opt-inline-count-binop-dst instrs 5) 0) (return 4))
            (unless (opt-inline-mov-dst-src? instrs 2 3) (return 5))
            (unless
              (= (opt-count-direct-call-name instrs "inline_add") 0)
              (return 6))
            (unless
              (=
                (opt-count-direct-call-name
                  (opt-function-first-instrs devirt-direct)
                  "inline_add")
                1)
              (return 7))
            (unless
              (=
                (opt-count-indirect-call-instrs
                  (opt-function-first-instrs devirt-direct))
                0)
              (return 8))
            (unless
              (=
                (opt-count-indirect-call-instrs
                  (opt-function-first-instrs devirt-dynamic))
                1)
              (return 9))
            (unless
              (=
                (opt-count-direct-call-name
                  (opt-function-first-instrs devirt-dynamic)
                  "inline_add")
                0)
              (return 10))
            (match (opt-function-list-find devirt-inlined "main")
              [(OptMaybeFunction.Some indirect-main)
                (let
                  [indirect-instrs : CompilerIrInstrList
                    (opt-function-first-instrs indirect-main)]
                  (begin
                    (unless
                      (= (opt-function-frame indirect-main) 4)
                      (return 11))
                    (unless
                      (= (compiler-ir-instr-list-count indirect-instrs) 5)
                      (return 12))
                    (unless
                      (= (opt-inline-count-binop-dst indirect-instrs 3) 1)
                      (return 13))
                    (unless
                      (= (opt-count-indirect-call-instrs indirect-instrs) 0)
                      (return 14))
                    (unless
                      (opt-inline-mov-dst-src? indirect-instrs 2 3)
                      (return 15))
                    (unless
                      (= (compiler-ir-function-list-count devirt-reach) 1)
                      (return 16))
                    (unless
                      (opt-function-list-defines? devirt-reach "main")
                      (return 17))
                    (when
                      (opt-function-list-defines? devirt-reach "kept_target")
                      (return 18))
                    (when
                      (opt-function-list-defines? devirt-reach "dead")
                      (return 19))
                    (unless valid-structure (return 20))
                    (unless duplicate-def-structure (return 21))
                    (unless
                      (opt-function-eq
                        duplicate-label-revert
                        (opt-inline-frame-caller symbols))
                      (return 22))
                    (unless
                      (opt-function-eq
                        unknown-successor-revert
                        (opt-inline-frame-caller symbols))
                      (return 23))
                    (unless
                      (opt-function-eq
                        bad-phi-revert
                        (opt-inline-frame-caller symbols))
                      (return 24))
                    (unless
                      (opt-function-eq
                        valid-keep
                        (opt-inline-frame-callee symbols))
                      (return 25))
                    (unless
                      (compiler-optimize-inline-level-gate-ok?)
                      (return 26))
                    (unless
                      (compiler-optimize-inline-self-recursive-ok?)
                      (return 27))
                    (unless
                      (compiler-optimize-inline-large-callee-ok?)
                      (return 28))
                    (unless
                      (compiler-optimize-inline-bounds-callee-ok?)
                      (return 29))
                    (unless
                      (compiler-optimize-inline-bounds-labels-distinct-ok?)
                      (return 46))
                    (unless
                      (compiler-optimize-inline-bounds-label-guard-ok?)
                      (return 47))
                    (unless
                      (compiler-optimize-inline-bounds-leaf-body-gate-ok?)
                      (return 48))
                    (unless
                      (compiler-optimize-inline-multi-call-ok?)
                      (return 30))
                    (unless
                      (compiler-optimize-inline-census-direct-ok?)
                      (return 31))
                    (unless
                      (compiler-optimize-inline-census-address-ok?)
                      (return 32))
                    (unless
                      (compiler-optimize-inline-cost-model-ok?)
                      (return 33))
                    (unless
                      (compiler-optimize-inline-bottom-up-writeback-ok?)
                      (return 34))
                    (unless
                      (compiler-optimize-inline-mutual-scc-refusal-ok?)
                      (return 35))
                    (unless
                      (compiler-optimize-inline-pack-word-ok?)
                      (return 36))
                    (unless
                      (compiler-optimize-inline-multiblock-ok?)
                      (return 37))
                    (unless
                      (compiler-optimize-inline-multiblock-acyclic-ok?)
                      (return 39))
                    (unless
                      (compiler-optimize-inline-multiblock-bounds-ok?)
                      (return 46))
                    (unless
                      (compiler-optimize-inline-multiblock-switch-ok?)
                      (return 50))
                    (unless
                      (compiler-optimize-inline-multiblock-switch-cost-refusal-ok?)
                      (return 51))
                    (unless
                      (compiler-optimize-inline-mut-param-loop-ok?)
                      (return 44))
                    (unless
                      (compiler-optimize-inline-caller-phi-loop-ok?)
                      (return 45))
                    (unless
                      (compiler-optimize-inline-multiblock-nonleaf-ok?)
                      (return 40))
                    (unless
                      (compiler-optimize-inline-repeated-tiny-predicate-ok?)
                      (return 46))
                    (unless
                      (compiler-optimize-inline-repeated-nonleaf-predicate-refusal-ok?)
                      (return 47))
                    (unless
                      (compiler-optimize-inline-multiblock-return-gate-ok?)
                      (return 49))
                    42))]
              [(OptMaybeFunction.No) 41])))]
      [(OptMaybeFunction.No) 43])))

(define (opt-block-list-has-label? [blocks : CompilerIrBlockList] [label : i64]) : bool
  (match blocks
    [(CompilerIrBlockList.Nil) false]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block block-label _)
          (if (= block-label label)
            true
            (opt-block-list-has-label? (box-get rest) label))])]
    [(CompilerIrBlockList.Array seq)
      (opt-block-list-has-label? (compiler-ir-block-seq-to-list seq) label)]))

(define (opt-block-list-label-at?
  [blocks : CompilerIrBlockList]
  [index : i64]
  [label : i64]) : bool
  (match blocks
    [(CompilerIrBlockList.Nil) false]
    [(CompilerIrBlockList.Cons block rest)
      (if (= index 0)
        (match block
          [(CompilerIrBlock.Block block-label _) (= block-label label)])
        (opt-block-list-label-at? (box-get rest) (- index 1) label))]
    [(CompilerIrBlockList.Array seq)
      (opt-block-list-label-at? (compiler-ir-block-seq-to-list seq) index label)]))

(define (opt-count-branches-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-branches-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(CompilerIrInstr.Branch _ _ _) 1]
          [_ 0])))))

(define (opt-count-branches-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-branches-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-branches-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-branches-instr-seq instrs)
            (opt-count-branches-blocks (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-branches-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-count-jump-to-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [target : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-jump-to-instr-seq-from
      slots
      (+ index 1)
      count
      target
      (+
        acc
        (match (array-ref slots index)
          [(CompilerIrInstr.Jump label)
            (if (= label target)
              1
              0)]
          [_ 0])))))

(define (opt-count-jump-to-instr-seq
  [instrs : CompilerIrInstrSeq]
  [target : i64]) : i64
  (opt-count-jump-to-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    target
    0))

(define (opt-count-jump-to-blocks [blocks : CompilerIrBlockList] [target : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-jump-to-instr-seq instrs target)
            (opt-count-jump-to-blocks (box-get rest) target))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-jump-to-blocks (compiler-ir-block-seq-to-list seq) target)]))

(define (opt-count-tail-call-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-tail-call-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(CompilerIrInstr.TailCall _ _ _) 1]
          [_ 0])))))

(define (opt-count-tail-call-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-tail-call-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-tail-call-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-tail-call-instr-seq instrs)
            (opt-count-tail-call-blocks (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-tail-call-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-tailrec-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "a" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "b" (AstType.I64) 1)
      (CompilerIrParamList.Nil))))

(define (opt-tailrec-test-function) : CompilerIrFunction
  (let
    [name : i64 (opt-test-symbol "tail_swap")]
    (CompilerIrFunction.Function
      name
      (opt-tailrec-test-params)
      (AstType.I64)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.TailCall
              name
              (CompilerIrCallArgs.Two
                (CompilerIrValue.Var 1)
                (CompilerIrValue.Var 0))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
              (CompilerIrInstrList.Nil))))
        (CompilerIrBlockList.Nil)))))

(define (opt-tailrec-expected-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Mov 2 (CompilerIrValue.Var 1) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 3 (CompilerIrValue.Var 0) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 0 (CompilerIrValue.Var 2) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 1 (CompilerIrValue.Var 3) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "entry"))
            (CompilerIrInstrList.Nil)))))))

(define (compiler-optimize-tailrec-self-test) : i64
  (let
    [rewritten : CompilerIrFunction
      (opt-tailrec-function (opt-tailrec-test-function))]
    [once : CompilerIrFunction
      (optimize-function-once (opt-tailrec-test-function))]
    [rewritten-blocks : CompilerIrBlockList (opt-function-blocks rewritten)]
    [once-blocks : CompilerIrBlockList (opt-function-blocks once)]
    [rewritten-instrs : CompilerIrInstrList
      (opt-function-first-instrs rewritten)]
    (cond
      [(not (= (opt-function-frame rewritten) 4)) 1]
      [(not (opt-instr-list-eq rewritten-instrs (opt-tailrec-expected-instrs)))
        2]
      [(not (= (opt-count-tail-call-blocks rewritten-blocks) 0)) 3]
      [(not
          (=
            (opt-count-jump-to-blocks
              rewritten-blocks
              (compiler-ir-label "entry"))
            1))
        4]
      [(not (= (opt-count-tail-call-blocks once-blocks) 0)) 5]
      [(not
          (=
            (opt-count-jump-to-blocks once-blocks (compiler-ir-label "entry"))
            1))
        6]
      [else 42])))

(define (opt-count-phi-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-phi-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(CompilerIrInstr.Phi _ _ _) 1]
          [_ 0])))))

(define (opt-count-phi-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-phi-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-phi-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-phi-instr-seq instrs)
            (opt-count-phi-blocks (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-phi-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-count-mov-dst-instrs [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.Mov mov-dst _ _)
            (if (= mov-dst dst)
              1
              0)]
          [_ 0])
        (opt-count-mov-dst-instrs (box-get rest) dst))]))

(define (opt-count-mov-dst-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [dst : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-mov-dst-instr-seq-from
      slots
      (+ index 1)
      count
      dst
      (+
        acc
        (match (array-ref slots index)
          [(CompilerIrInstr.Mov mov-dst _ _)
            (if (= mov-dst dst)
              1
              0)]
          [_ 0])))))

(define (opt-count-mov-dst-instr-seq [instrs : CompilerIrInstrSeq] [dst : i64]) : i64
  (opt-count-mov-dst-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    dst
    0))

(define (opt-count-mov-dst-blocks [blocks : CompilerIrBlockList] [dst : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-mov-dst-instr-seq instrs dst)
            (opt-count-mov-dst-blocks (box-get rest) dst))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-mov-dst-blocks (compiler-ir-block-seq-to-list seq) dst)]))

(define (opt-count-arith-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-arith-instr-seq instrs)
            (opt-count-arith-blocks (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-arith-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-count-arith-label-blocks
  [blocks : CompilerIrBlockList]
  [label : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block block-label instrs)
          (if (= block-label label)
            (opt-count-arith-instr-seq instrs)
            (opt-count-arith-label-blocks (box-get rest) label))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-arith-label-blocks (compiler-ir-block-seq-to-list seq) label)]))

(define (opt-count-mul-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-mul-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(CompilerIrInstr.BinOp _ op _ _ _)
            (match op
              [(CompilerIrBinOp.Mul) 1]
              [_ 0])]
          [_ 0])))))

(define (opt-count-mul-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-mul-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-mul-label-blocks
  [blocks : CompilerIrBlockList]
  [label : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block block-label instrs)
          (if (= block-label label)
            (opt-count-mul-instr-seq instrs)
            (opt-count-mul-label-blocks (box-get rest) label))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-mul-label-blocks (compiler-ir-block-seq-to-list seq) label)]))

(define (opt-blocks-mov-dst-i64-value
  [blocks : CompilerIrBlockList]
  [dst : i64]
  [fallback : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) fallback]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (let
            [value : i64 (opt-mov-dst-i64-value-instr-seq instrs dst fallback)]
            (if (= value fallback)
              (opt-blocks-mov-dst-i64-value (box-get rest) dst fallback)
              value))])]
    [(CompilerIrBlockList.Array seq)
      (opt-blocks-mov-dst-i64-value
        (compiler-ir-block-seq-to-list seq)
        dst
        fallback)]))

(define (opt-count-cast-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-cast-instr-seq instrs)
            (opt-count-cast-blocks (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-cast-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-count-gep-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-gep-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(CompilerIrInstr.Gep _ _ _ _) 1]
          [_ 0])))))

(define (opt-count-gep-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-gep-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-gep-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-gep-instr-seq instrs)
            (opt-count-gep-blocks (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-gep-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-count-gep-label-blocks
  [blocks : CompilerIrBlockList]
  [label : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block block-label instrs)
          (if (= block-label label)
            (opt-count-gep-instr-seq instrs)
            (opt-count-gep-label-blocks (box-get rest) label))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-gep-label-blocks (compiler-ir-block-seq-to-list seq) label)]))

(define (opt-count-load-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.Load _ _ _) 1]
          [_ 0])
        (opt-count-load-instrs (box-get rest)))]))

(define (opt-count-load-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-load-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(CompilerIrInstr.Load _ _ _) 1]
          [_ 0])))))

(define (opt-count-load-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-load-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-load-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-count-load-instr-seq instrs)
            (opt-count-load-blocks (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-load-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-count-load-label-blocks
  [blocks : CompilerIrBlockList]
  [label : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block block-label instrs)
          (if (= block-label label)
            (opt-count-load-instr-seq instrs)
            (opt-count-load-label-blocks (box-get rest) label))])]
    [(CompilerIrBlockList.Array seq)
      (opt-count-load-label-blocks (compiler-ir-block-seq-to-list seq) label)]))

(define (opt-blocks-binop-lhs-var
  [blocks : CompilerIrBlockList]
  [dst : i64]
  [fallback : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) fallback]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (let
            [value : i64 (opt-copy-binop-lhs-var-instr-seq instrs dst)]
            (if (= value (- 0 1))
              (opt-blocks-binop-lhs-var (box-get rest) dst fallback)
              value))])]
    [(CompilerIrBlockList.Array seq)
      (opt-blocks-binop-lhs-var
        (compiler-ir-block-seq-to-list seq)
        dst
        fallback)]))

(define (opt-blocks-mov-src-var
  [blocks : CompilerIrBlockList]
  [dst : i64]
  [fallback : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) fallback]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (let
            [value : i64 (opt-mov-src-var-instr-seq instrs dst fallback)]
            (if (= value fallback)
              (opt-blocks-mov-src-var (box-get rest) dst fallback)
              value))])]
    [(CompilerIrBlockList.Array seq)
      (opt-blocks-mov-src-var (compiler-ir-block-seq-to-list seq) dst fallback)]))

(define (opt-mov-src-var
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [fallback : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) fallback]
    [(CompilerIrInstrList.Cons instr rest)
      (match instr
        [(CompilerIrInstr.Mov mov-dst (CompilerIrValue.Var src) _)
          (if (= mov-dst dst)
            src
            (opt-mov-src-var (box-get rest) dst fallback))]
        [_ (opt-mov-src-var (box-get rest) dst fallback)])]))

(define (opt-mov-src-var-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [dst : i64]
  [fallback : i64]) : i64
  (if (>= index count)
    fallback
    (match (array-ref slots index)
      [(CompilerIrInstr.Mov mov-dst (CompilerIrValue.Var src) _)
        (if (= mov-dst dst)
          src
          (opt-mov-src-var-instr-seq-from slots (+ index 1) count dst fallback))]
      [_ (opt-mov-src-var-instr-seq-from slots (+ index 1) count dst fallback)])))

(define (opt-mov-src-var-instr-seq
  [instrs : CompilerIrInstrSeq]
  [dst : i64]
  [fallback : i64]) : i64
  (opt-mov-src-var-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    dst
    fallback))

(define (opt-cfg-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "cfg")
    (CompilerIrParamList.Nil)
    (AstType.I64)
    16
    blocks))

(define (opt-sccp-cond-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 0)
    (CompilerIrParamList.Nil)))

(define (opt-sccp-loop-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 4)
    (CompilerIrParamList.Nil)))

(define (opt-gvn-scalar-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "lhs" (AstType.I64) 1)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "rhs" (AstType.I64) 2)
        (CompilerIrParamList.Nil)))))

(define (opt-gvn-pointer-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "ptr" (AstType.I64) 1)
    (CompilerIrParamList.Nil)))

(define (opt-gvn-pointer-cond-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "ptr" (AstType.I64) 1)
      (CompilerIrParamList.Nil))))

(define (opt-gvn-checked-ref-cond-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "read" (ast-ty-ref 0 (AstType.I64)) 1)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "write" (ast-ty-mut-ref 0 (AstType.I64)) 2)
        (CompilerIrParamList.Nil)))))

(define (opt-gvn-function
  [name : String]
  [params : CompilerIrParamList]
  [ret-ty : AstType]
  [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function (opt-test-symbol name) params ret-ty 16 blocks))

(define (opt-gvn-dominated-diamond-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          3
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.Var 2)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "then")
            (compiler-ir-label "else"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            4
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 2)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              5
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.Var 2)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "join")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Phi
                6
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 4)
                  (compiler-ir-label "then")
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.Var 5)
                    (compiler-ir-label "else")
                    (CompilerIrPhiInputList.Nil)))
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 6)))
                (CompilerIrInstrList.Nil))))
          (CompilerIrBlockList.Nil))))))

(define (opt-gvn-sibling-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 0)
          (compiler-ir-label "then")
          (compiler-ir-label "else"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            3
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 2)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.Var 2)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
              (CompilerIrInstrList.Nil))))
        (CompilerIrBlockList.Nil)))))

(define (opt-gvn-phi-loop-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            5
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 1)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 4)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              3
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 5)
              (CompilerIrValue.Var 2)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Var 0)
                (compiler-ir-label "body")
                (compiler-ir-label "exit"))
              (CompilerIrInstrList.Nil)))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 5)
              (CompilerIrValue.Var 2)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-gvn-load-barrier-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "use"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 4 (CompilerIrValue.Var 1) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
            (CompilerIrInstrList.Nil))))
      (CompilerIrBlockList.Nil))))

(define (opt-gvn-load-join-safe-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "then")
            (compiler-ir-label "else"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "join"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "join")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 4 (CompilerIrValue.Var 1) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                (CompilerIrInstrList.Nil))))
          (CompilerIrBlockList.Nil))))))

(define (opt-gvn-checked-ref-store-path-blocks [lose-root? : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "then")
            (compiler-ir-label "else"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (if lose-root?
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 99) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.StorePtr
                (CompilerIrValue.Var 2)
                (CompilerIrValue.I64 9)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "join"))
                (CompilerIrInstrList.Nil))))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 2)
              (CompilerIrValue.I64 9)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              (CompilerIrInstrList.Nil)))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "join")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 4 (CompilerIrValue.Var 1) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                (CompilerIrInstrList.Nil))))
          (CompilerIrBlockList.Nil))))))

(define (opt-gvn-load-store-path-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "then")
            (compiler-ir-label "else"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 9)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "join")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 4 (CompilerIrValue.Var 1) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                (CompilerIrInstrList.Nil))))
          (CompilerIrBlockList.Nil))))))

(define (opt-gvn-single-load-store-forward-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Alloc 0 (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            1
            (CompilerIrValue.Var 0)
            (CompilerIrValue.I64 0)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 9)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "use"))
              (CompilerIrInstrList.Nil))))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
            (CompilerIrInstrList.Nil))))
      (CompilerIrBlockList.Nil))))

(define (opt-gvn-load-call-path-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "then")
            (compiler-ir-label "else"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            9
            (opt-test-symbol "touch")
            (CompilerIrCallArgs.Nil)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "join")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 4 (CompilerIrValue.Var 1) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                (CompilerIrInstrList.Nil))))
          (CompilerIrBlockList.Nil))))))

(define (opt-gvn-load-address-redef-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "use"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 7) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 4 (CompilerIrValue.Var 1) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
              (CompilerIrInstrList.Nil)))))
      (CompilerIrBlockList.Nil))))

(define (opt-gvn-load-type-mismatch-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "use"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 4 (CompilerIrValue.Var 1) (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
            (CompilerIrInstrList.Nil))))
      (CompilerIrBlockList.Nil))))

(define (opt-gvn-copy-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 3 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "use"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            4
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 3)
            (CompilerIrValue.I64 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
            (CompilerIrInstrList.Nil))))
      (CompilerIrBlockList.Nil))))

(define (opt-gvn-cast-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Cast
          3
          (CompilerIrValue.Var 1)
          (AstType.I64)
          (AstType.I32))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "use"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Cast
            4
            (CompilerIrValue.Var 1)
            (AstType.I64)
            (AstType.I32))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
            (CompilerIrInstrList.Nil))))
      (CompilerIrBlockList.Nil))))

(define (opt-gvn-gep-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          3
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 8)
          (AstType.U8))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "use"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            4
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 8)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
            (CompilerIrInstrList.Nil))))
      (CompilerIrBlockList.Nil))))

(define (opt-global-expr-hash-collision-guard-ok?) : bool
  (let
    [key : OptGlobalExprKey
      (OptGlobalExprKey.BinKey
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 1)
        (CompilerIrValue.Var 2)
        (AstType.I64))]
    [other-key : OptGlobalExprKey
      (OptGlobalExprKey.BinKey
        (CompilerIrBinOp.Sub)
        (CompilerIrValue.Var 1)
        (CompilerIrValue.Var 2)
        (AstType.I64))]
    [buckets : (Array OptGlobalExprFacts)
      (array.make-array OptGlobalExprFacts 1)]
    [table : OptGlobalExprFactTable (OptGlobalExprFactTable buckets)]
    [doms : OptDomInfo
      (opt-cfg-dominators
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "entry")
            (CompilerIrInstrList.Nil))
          (CompilerIrBlockList.Nil)))]
    (begin
      (array-set!
        buckets
        0
        (OptGlobalExprFacts.Cons
          (OptGlobalExprFact.Fact key 7 0 1)
          (box (OptGlobalExprFacts.Nil))))
      (and
        (match (opt-global-expr-lookup table key 8 doms 0 2)
          [(CompilerIrMaybeValue.Some value)
            (match value
              [(CompilerIrValue.Var id) (= id 7)]
              [_ false])]
          [(CompilerIrMaybeValue.No) false])
        (match (opt-global-expr-lookup table other-key 8 doms 0 2)
          [(CompilerIrMaybeValue.No) true]
          [(CompilerIrMaybeValue.Some _) false])))))

(define (opt-gvn-hash-collision-guard-ok?) : bool
  (let
    [key : OptExprKey
      (OptExprKey.BinKey
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 1)
        (CompilerIrValue.Var 2)
        (AstType.I64))]
    [other-key : OptExprKey
      (OptExprKey.BinKey
        (CompilerIrBinOp.Sub)
        (CompilerIrValue.Var 1)
        (CompilerIrValue.Var 2)
        (AstType.I64))]
    [buckets : (Array OptGvnBucket) (array.make-array OptGvnBucket 1)]
    [table : OptGvnMap (OptGvnMap buckets)]
    (begin
      (array-set! buckets 0 (OptGvnBucket.Nil))
      (opt-gvn-table-insert! table (OptGvnEntry.Entry key 7 0))
      (and
        (= (opt-gvn-lookup table key) 7)
        (= (opt-gvn-lookup table other-key) (- 0 1))))))

(define (opt-gvn-nearest-scope-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          3
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.Var 2)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "mid"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "mid")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            4
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 2)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "use"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "use")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              5
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.Var 2)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 5)))
              (CompilerIrInstrList.Nil))))
        (CompilerIrBlockList.Nil)))))

(define (opt-gvn-scoped-nearest-dominator-ok?) : bool
  (let
    [out : CompilerIrBlockList
      (opt-gvn-blocks (opt-gvn-scalar-params) (opt-gvn-nearest-scope-blocks))]
    (and
      (= (opt-blocks-mov-src-var out 4 (- 0 1)) 3)
      (= (opt-blocks-mov-src-var out 5 (- 0 1)) 4))))

;; The Pack is in `entry`, while its Var-backed Word extraction is in the
;; dominated `use` block. Global forwarding must rewrite the binop operand to
;; parameter v1; the array DCE then removes both the Word copy and the now-dead
;; Pack.
(define (opt-global-pack-word-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Pack
          2
          (compiler-ir-value-cons
            (CompilerIrValue.Var 0)
            (compiler-ir-value-cons
              (CompilerIrValue.Var 1)
              CompilerIrValueList.Nil))
          (AstType.Struct (intern "Pair")))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "use"))
          CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "use")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Word 3 (CompilerIrValue.Var 2) 1 (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 3)
              (CompilerIrValue.I64 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
              CompilerIrInstrList.Nil))))
      CompilerIrBlockList.Nil)))

(define (opt-global-pack-word-forwarded-blocks) : CompilerIrBlockList
  (let
    [forwarded : CompilerIrFunction
      (opt-global-value-number-function
        (opt-gvn-function
          "global_pack_word"
          (opt-gvn-test-params)
          (AstType.I64)
          (opt-global-pack-word-blocks)))]
    [blocks : CompilerIrBlockList (opt-function-blocks forwarded)]
    [uses : (Array i64) (opt-collect-blocks-uses-array 16 blocks)]
    (opt-dce-block-list-array uses blocks)))

(define (compiler-optimize-global-value-number-self-test) : i64
  (let
    [dominated : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function
          (opt-gvn-function
            "gvn_dominated"
            (opt-gvn-scalar-params)
            (AstType.I64)
            (opt-gvn-dominated-diamond-blocks))))]
    [sibling : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function
          (opt-gvn-function
            "gvn_sibling"
            (opt-gvn-scalar-params)
            (AstType.I64)
            (opt-gvn-sibling-blocks))))]
    [loop : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function
          (opt-gvn-function
            "gvn_loop"
            (opt-gvn-scalar-params)
            (AstType.I64)
            (opt-gvn-phi-loop-blocks))))]
    [load-safe : CompilerIrBlockList
      (opt-gvn-blocks (opt-gvn-pointer-params) (opt-gvn-load-barrier-blocks))]
    [load-join-safe : CompilerIrBlockList
      (opt-gvn-blocks
        (opt-gvn-pointer-cond-params)
        (opt-gvn-load-join-safe-blocks))]
    [load-store-path : CompilerIrBlockList
      (opt-gvn-blocks
        (opt-gvn-pointer-cond-params)
        (opt-gvn-load-store-path-blocks))]
    [single-load-store-forward : CompilerIrBlockList
      (opt-gvn-blocks
        (CompilerIrParamList.Nil)
        (opt-gvn-single-load-store-forward-blocks))]
    [load-call-path : CompilerIrBlockList
      (opt-gvn-blocks
        (opt-gvn-pointer-cond-params)
        (opt-gvn-load-call-path-blocks))]
    [checked-ref-store-path : CompilerIrBlockList
      (opt-gvn-blocks
        (opt-gvn-checked-ref-cond-params)
        (opt-gvn-checked-ref-store-path-blocks false))]
    [checked-ref-root-loss : CompilerIrBlockList
      (opt-gvn-blocks
        (opt-gvn-checked-ref-cond-params)
        (opt-gvn-checked-ref-store-path-blocks true))]
    [load-address-redef : CompilerIrBlockList
      (opt-gvn-blocks
        (opt-gvn-pointer-params)
        (opt-gvn-load-address-redef-blocks))]
    [load-type-mismatch : CompilerIrBlockList
      (opt-gvn-blocks
        (opt-gvn-pointer-params)
        (opt-gvn-load-type-mismatch-blocks))]
    [copy : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function
          (opt-gvn-function
            "gvn_copy"
            (opt-gvn-pointer-params)
            (AstType.I64)
            (opt-gvn-copy-blocks))))]
    [cast : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function
          (opt-gvn-function
            "gvn_cast"
            (opt-gvn-pointer-params)
            (AstType.I32)
            (opt-gvn-cast-blocks))))]
    [gep : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function
          (opt-gvn-function
            "gvn_gep"
            (opt-gvn-pointer-params)
            (AstType.U8)
            (opt-gvn-gep-blocks))))]
    [global-gep : CompilerIrBlockList
      (opt-function-blocks
        (opt-global-value-number-function
          (opt-gvn-function
            "gvn_global_gep"
            (opt-gvn-scalar-params)
            (AstType.I64)
            (opt-gvn-global-gep-call-blocks))))]
    [pack-word : CompilerIrBlockList (opt-global-pack-word-forwarded-blocks)]
    (cond
      [(not (= (opt-count-arith-blocks dominated) 1)) 1]
      ;; The branch-local copies feed only phi edges. Edge-aware forwarding
      ;; rewrites both inputs to the dominating value, then DCE removes them.
      [(not (= (opt-blocks-mov-src-var dominated 4 (- 0 1)) (- 0 1))) 2]
      [(not (= (opt-blocks-mov-src-var dominated 5 (- 0 1)) (- 0 1))) 3]
      [(not (= (opt-count-arith-blocks sibling) 2)) 4]
      [(not (= (opt-count-arith-blocks loop) 1)) 5]
      [(not (= (opt-blocks-mov-src-var loop 4 (- 0 1)) (- 0 1))) 6]
      [(not (= (opt-count-load-blocks load-safe) 1)) 7]
      [(not (= (opt-blocks-mov-src-var load-safe 4 (- 0 1)) 3)) 8]
      [(not (= (opt-count-load-blocks load-join-safe) 1)) 9]
      [(not (= (opt-blocks-mov-src-var load-join-safe 4 (- 0 1)) 3)) 10]
      [(not (= (opt-count-load-blocks load-store-path) 2)) 11]
      [(not (= (opt-blocks-mov-src-var load-store-path 4 (- 0 1)) (- 0 1))) 12]
      [(not (= (opt-count-load-blocks load-call-path) 2)) 13]
      [(not (= (opt-blocks-mov-src-var load-call-path 4 (- 0 1)) (- 0 1))) 14]
      [(not (= (opt-count-load-blocks load-address-redef) 2)) 15]
      [(not (= (opt-blocks-mov-src-var load-address-redef 4 (- 0 1)) (- 0 1)))
        16]
      [(not (= (opt-count-load-blocks load-type-mismatch) 2)) 17]
      [(not (= (opt-blocks-binop-lhs-var copy 4 (- 0 1)) 1)) 18]
      [(not (= (opt-count-mov-dst-blocks copy 3) 0)) 19]
      [(not (= (opt-count-cast-blocks cast) 0)) 20]
      [(not (= (opt-count-mov-dst-blocks cast 4) 0)) 21]
      [(not (= (opt-count-gep-blocks gep) 1)) 22]
      [(not (= (opt-count-mov-dst-blocks gep 4) 0)) 23]
      [(not (opt-global-expr-hash-collision-guard-ok?)) 24]
      [(not (opt-gvn-hash-collision-guard-ok?)) 25]
      [(not (opt-gvn-scoped-nearest-dominator-ok?)) 26]
      [(not
          (=
            (opt-count-gep-label-blocks global-gep (compiler-ir-label "use"))
            1))
        27]
      [(match (opt-global-key-for-instr
          (CompilerIrInstr.Gep
            9
            (CompilerIrValue.Global (opt-test-symbol "pool"))
            (CompilerIrValue.I64 8)
            (AstType.I64)))
          [(OptMaybeGlobalExprKey.Some _) true]
          [(OptMaybeGlobalExprKey.No) false])
        28]
      [(not (= (opt-count-load-blocks checked-ref-store-path) 1)) 29]
      [(not (= (opt-blocks-mov-src-var checked-ref-store-path 4 (- 0 1)) 3)) 30]
      [(not (= (opt-count-load-blocks checked-ref-root-loss) 2)) 31]
      [(not
          (= (opt-blocks-mov-src-var checked-ref-root-loss 4 (- 0 1)) (- 0 1)))
        32]
      [(not (= (opt-count-load-blocks single-load-store-forward) 0)) 33]
      [(not
          (=
            (opt-blocks-mov-dst-i64-value single-load-store-forward 3 (- 0 1))
            9))
        34]
      [(not (= (opt-blocks-binop-lhs-var pack-word 4 (- 0 1)) 1)) 35]
      [(not (= (opt-count-words-blocks pack-word) 0)) 36]
      [(not (= (opt-count-packs-blocks pack-word) 0)) 37]
      [else 42])))

;; Regression fixture for the global-GVN stale-global-read miscompile: the
;; entry block computes a Gep off the CURRENT value of mutable global `pool`,
;; one branch calls a function that may replace `pool`, and the join block
;; recomputes the same Gep. Forwarding the entry Gep into the join would read
;; the pre-call array's capacity address (the opt2 self-build bounds abort in
;; `ty-node-push` once the node pool grew).
(define (opt-gvn-global-gep-call-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          3
          (CompilerIrValue.Global (opt-test-symbol "pool"))
          (CompilerIrValue.I64 8)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 4 (CompilerIrValue.Var 3) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "grow")
              (compiler-ir-label "use"))
            (CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "grow")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            5
            (opt-test-symbol "grow_pool")
            (CompilerIrCallArgs.Nil)
            (AstType.Unit))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "use"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "use")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              6
              (CompilerIrValue.Global (opt-test-symbol "pool"))
              (CompilerIrValue.I64 8)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 7 (CompilerIrValue.Var 6) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 7)))
                (CompilerIrInstrList.Nil)))))
        (CompilerIrBlockList.Nil)))))

(define (opt-sccp-cross-block-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 20) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "rhs"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "rhs")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            1
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.I64 22)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
            (CompilerIrInstrList.Nil))))
      (CompilerIrBlockList.Nil))))

(define (opt-sccp-diamond-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 0)
          (compiler-ir-label "then")
          (compiler-ir-label "else"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 7) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 7) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "join")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Phi
                3
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 1)
                  (compiler-ir-label "then")
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.Var 2)
                    (compiler-ir-label "else")
                    (CompilerIrPhiInputList.Nil)))
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                (CompilerIrInstrList.Nil))))
          (CompilerIrBlockList.Nil))))))

(define (opt-sccp-constant-branch-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 0 (CompilerIrValue.Bool true) (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "then")
            (compiler-ir-label "else"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.I64 1)))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 2)))
            (CompilerIrInstrList.Nil)))
        (CompilerIrBlockList.Nil)))))

(define (opt-sccp-loop-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            1
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 0)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 2)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 4)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              2
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-sccp-trap-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          1
          (CompilerIrBinOp.Div)
          (CompilerIrValue.I64 1)
          (CompilerIrValue.I64 0)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
          (CompilerIrInstrList.Nil))))
    (CompilerIrBlockList.Nil)))

;; SCCP is the first pass where the lowered constant-index dynamic-array access
;; has both bounds operands available as literals. Pin all three decisions: an
;; in-range literal check disappears, an out-of-range literal check remains a
;; trap, and a data-dependent check is untouched.
(define (opt-sccp-constant-bounds-blocks [index : i64] [length : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 index) (AstType.U64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 length) (AstType.U64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BoundsCheck
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 1)
              (compiler-ir-label "bounds_ok"))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
              (CompilerIrInstrList.Nil))))))
    (CompilerIrBlockList.Nil)))

(define (opt-sccp-dynamic-bounds-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "index" (AstType.U64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "length" (AstType.U64) 1)
      (CompilerIrParamList.Nil))))

(define (opt-sccp-dynamic-bounds-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BoundsCheck
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (compiler-ir-label "bounds_ok"))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
          (CompilerIrInstrList.Nil))))
    (CompilerIrBlockList.Nil)))

;; Regression guard: a branch conditioned on an IrInstrWord-extracted enum
;; tag. Pack/Word dsts must be bound Overdefined in the SCCP lattice; when they
;; stayed Unknown the branch marked NO successor executable and both arms were
;; folded away as unreachable (the -O2 stale-constant miscompile on matches over
;; 16-byte register-resident enums).
(define (opt-sccp-group-word-branch-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Pack
          0
          (compiler-ir-value-cons
            (CompilerIrValue.I64 1)
            (compiler-ir-value-cons
              (CompilerIrValue.I64 5)
              CompilerIrValueList.Nil))
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Word 1 (CompilerIrValue.Var 0) 0 (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              2
              (CompilerIrBinOp.Eq)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 0)
              (AstType.Bool))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Var 2)
                (compiler-ir-label "then")
                (compiler-ir-label "else"))
              (CompilerIrInstrList.Nil))))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 2) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "merge"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 3) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "merge"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "merge")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (compiler-optimize-sccp-self-test) : i64
  (let
    [cross : CompilerIrBlockList
      (opt-sccp-blocks (CompilerIrParamList.Nil) (opt-sccp-cross-block-blocks))]
    [diamond : CompilerIrBlockList
      (opt-sccp-blocks (opt-sccp-cond-params) (opt-sccp-diamond-blocks))]
    [branch-source : CompilerIrBlockList (opt-sccp-constant-branch-blocks)]
    [branch : CompilerIrBlockList
      (opt-sccp-blocks (CompilerIrParamList.Nil) branch-source)]
    [branch-context-result : OptBlockCtxResult
      (opt-sccp-blocks-with-context-result
        (opt-cfg-context-build branch-source)
        (CompilerIrParamList.Nil)
        branch-source)]
    [branch-context : CompilerIrBlockList
      (match branch-context-result
        [(OptBlockCtxResult.Result blocks _ _) blocks])]
    [branch-context-valid : bool
      (match branch-context-result
        [(OptBlockCtxResult.Result _ _ valid) valid])]
    [loop : CompilerIrBlockList
      (opt-sccp-blocks (opt-sccp-loop-params) (opt-sccp-loop-blocks))]
    [trap : CompilerIrBlockList
      (opt-sccp-blocks (CompilerIrParamList.Nil) (opt-sccp-trap-blocks))]
    [group : CompilerIrBlockList
      (opt-sccp-blocks
        (CompilerIrParamList.Nil)
        (opt-sccp-group-word-branch-blocks))]
    [in-range-bounds : CompilerIrBlockList
      (opt-sccp-blocks
        (CompilerIrParamList.Nil)
        (opt-sccp-constant-bounds-blocks 0 64))]
    [out-of-range-bounds : CompilerIrBlockList
      (opt-sccp-blocks
        (CompilerIrParamList.Nil)
        (opt-sccp-constant-bounds-blocks 64 64))]
    [dynamic-bounds : CompilerIrBlockList
      (opt-sccp-blocks
        (opt-sccp-dynamic-bounds-params)
        (opt-sccp-dynamic-bounds-blocks))]
    (cond
      [(not (= (opt-count-arith-blocks cross) 0)) 1]
      [(not (= (opt-blocks-mov-dst-i64-value cross 1 (- 0 999)) 42)) 2]
      [(not (= (opt-count-phi-blocks diamond) 0)) 3]
      [(not (= (opt-blocks-mov-dst-i64-value diamond 3 (- 0 999)) 7)) 4]
      [(not (= (compiler-ir-block-list-count branch) 2)) 5]
      [(opt-block-list-has-label? branch (compiler-ir-label "else")) 6]
      [(not (= (opt-count-branches-blocks branch) 0)) 7]
      [(not (= (opt-count-jump-to-blocks branch (compiler-ir-label "then")) 1))
        8]
      [(not (= (compiler-ir-block-list-count loop) 4)) 9]
      [(not (= (opt-count-phi-blocks loop) 1)) 10]
      [(not (= (opt-count-mov-dst-blocks loop 1) 0)) 11]
      [(not (= (opt-count-arith-blocks loop) 1)) 12]
      [(not (= (opt-count-arith-blocks trap) 1)) 13]
      [(not (= (opt-count-mov-dst-blocks trap 1) 0)) 14]
      [(not (= (compiler-ir-block-list-count group) 4)) 15]
      [(not (= (opt-count-branches-blocks group) 1)) 16]
      [(not (opt-block-list-has-label? group (compiler-ir-label "then"))) 17]
      [(not (opt-block-list-has-label? group (compiler-ir-label "else"))) 18]
      [(not (= (compiler-ir-block-list-count branch-context) 2)) 19]
      [(not branch-context-valid) 20]
      [(opt-block-list-has-label? branch-context (compiler-ir-label "else")) 21]
      [(not (= (opt-count-bounds-blocks in-range-bounds) 0)) 22]
      [(not (= (opt-count-bounds-blocks out-of-range-bounds) 1)) 23]
      [(not (= (opt-count-bounds-blocks dynamic-bounds) 1)) 24]
      [else 42])))

(define (opt-cfg-constant-if-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Bool true)
          (compiler-ir-label "then")
          (compiler-ir-label "else"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.I64 1)))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 2)))
            (CompilerIrInstrList.Nil)))
        (CompilerIrBlockList.Nil)))))

(define (opt-cfg-loop-guard-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Bool false)
            (compiler-ir-label "body")
            (compiler-ir-label "exit"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-cfg-phi-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Bool true)
          (compiler-ir-label "then")
          (compiler-ir-label "else"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 20) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "join")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Phi
                3
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 1)
                  (compiler-ir-label "then")
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.Var 2)
                    (compiler-ir-label "else")
                    (CompilerIrPhiInputList.Nil)))
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                (CompilerIrInstrList.Nil))))
          (CompilerIrBlockList.Nil))))))

;; Both entry and header remain reachable after folding entry's true branch,
;; but entry no longer has a direct edge to tail. The stale entry phi arm must
;; be removed based on tail's actual predecessors.
(define (opt-cfg-folded-edge-phi-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Bool true)
          (compiler-ir-label "header")
          (compiler-ir-label "tail"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "header")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "tail"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "tail")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              1
              (compiler-ir-phi-input-cons
                (CompilerIrValue.I64 10)
                (compiler-ir-label "entry")
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.I64 20)
                  (compiler-ir-label "header")
                  (CompilerIrPhiInputList.Nil)))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              (CompilerIrInstrList.Nil))))
        (CompilerIrBlockList.Nil)))))

(define (opt-cfg-trap-path-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 0)
          (compiler-ir-label "ok")
          (compiler-ir-label "trap"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "ok")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "trap")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Call
              9
              (opt-test-symbol "panic")
              (CompilerIrCallArgs.Nil)
              (AstType.Unit))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 1)))
              (CompilerIrInstrList.Nil))))
        (CompilerIrBlockList.Nil)))))

(define (opt-cfg-fallthrough-prune-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block (compiler-ir-label "entry") (CompilerIrInstrList.Nil))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "reachable-empty")
        (CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "exit")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 1)))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "dead-empty")
            (CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "dead-exit")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.I64 2)))
                (CompilerIrInstrList.Nil)))
            (CompilerIrBlockList.Nil)))))))

(define (opt-cfg-fallthrough-prune-ok? [blocks : CompilerIrBlockList]) : bool
  (and
    (= (compiler-ir-block-list-count blocks) 3)
    (opt-block-list-has-label? blocks (compiler-ir-label "entry"))
    (opt-block-list-has-label? blocks (compiler-ir-label "reachable-empty"))
    (opt-block-list-has-label? blocks (compiler-ir-label "exit"))
    (not (opt-block-list-has-label? blocks (compiler-ir-label "dead-empty")))
    (not (opt-block-list-has-label? blocks (compiler-ir-label "dead-exit")))
    (opt-cfg-successor-targets-known? blocks)
    (opt-verify-ok? (opt-verify-function (opt-cfg-test-function blocks)))))

(define (opt-bool-branch-test-blocks
  [condition : CompilerIrInstr]
  [reuse-condition? : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 0)
          (compiler-ir-label "compare")
          (compiler-ir-label "constant"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "compare")
        (compiler-ir-instr-cons
          condition
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "merge"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "constant")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "merge"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "merge")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Phi
                4
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 1)
                  (compiler-ir-label "compare")
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.Bool false)
                    (compiler-ir-label "constant")
                    (CompilerIrPhiInputList.Nil)))
                (AstType.Bool))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 4)
                  (compiler-ir-label "yes")
                  (compiler-ir-label "no"))
                (CompilerIrInstrList.Nil))))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "yes")
              (if reuse-condition?
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Mov 5 (CompilerIrValue.Var 4) (AstType.Bool))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return
                      (CompilerIrMaybeValue.Some (CompilerIrValue.I64 1)))
                    (CompilerIrInstrList.Nil)))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.I64 1)))
                  (CompilerIrInstrList.Nil))))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "no")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
                  (CompilerIrInstrList.Nil)))
              (CompilerIrBlockList.Nil))))))))

(define (opt-bool-branch-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "bool-branch")
    (opt-sccp-cond-params)
    (AstType.I64)
    16
    blocks))

(define (opt-bool-branch-two-cond-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "left" (AstType.Bool) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "right" (AstType.Bool) 1)
      (CompilerIrParamList.Nil))))

(define (opt-bool-branch-constant-phi-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 0)
          (compiler-ir-label "true-left")
          (compiler-ir-label "choose"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "choose")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 1)
            (compiler-ir-label "false-middle")
            (compiler-ir-label "true-right"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "true-left")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "merge"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "false-middle")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "merge"))
              (CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "true-right")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "merge"))
                (CompilerIrInstrList.Nil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "merge")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Phi
                    4
                    (compiler-ir-phi-input-cons
                      (CompilerIrValue.Bool true)
                      (compiler-ir-label "true-left")
                      (compiler-ir-phi-input-cons
                        (CompilerIrValue.Bool false)
                        (compiler-ir-label "false-middle")
                        (compiler-ir-phi-input-cons
                          (CompilerIrValue.Bool true)
                          (compiler-ir-label "true-right")
                          (CompilerIrPhiInputList.Nil))))
                    (AstType.Bool))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Branch
                      (CompilerIrValue.Var 4)
                      (compiler-ir-label "yes")
                      (compiler-ir-label "no"))
                    (CompilerIrInstrList.Nil))))
              (compiler-ir-block-cons
                (compiler-ir-block
                  (compiler-ir-label "yes")
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Phi
                      5
                      (compiler-ir-phi-input-cons
                        (CompilerIrValue.I64 11)
                        (compiler-ir-label "merge")
                        (CompilerIrPhiInputList.Nil))
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Return
                        (CompilerIrMaybeValue.Some (CompilerIrValue.Var 5)))
                      (CompilerIrInstrList.Nil))))
                (compiler-ir-block-cons
                  (compiler-ir-block
                    (compiler-ir-label "no")
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Phi
                        6
                        (compiler-ir-phi-input-cons
                          (CompilerIrValue.I64 22)
                          (compiler-ir-label "merge")
                          (CompilerIrPhiInputList.Nil))
                        (AstType.I64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Return
                          (CompilerIrMaybeValue.Some (CompilerIrValue.Var 6)))
                        (CompilerIrInstrList.Nil))))
                  (CompilerIrBlockList.Nil))))))))))

(define (opt-bool-branch-nonconstant-phi-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 0)
          (compiler-ir-label "left")
          (compiler-ir-label "right"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "left")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "merge"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "right")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "merge"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "merge")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Phi
                4
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 0)
                  (compiler-ir-label "left")
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.Var 1)
                    (compiler-ir-label "right")
                    (CompilerIrPhiInputList.Nil)))
                (AstType.Bool))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 4)
                  (compiler-ir-label "yes")
                  (compiler-ir-label "no"))
                (CompilerIrInstrList.Nil))))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "yes")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.I64 1)))
                (CompilerIrInstrList.Nil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "no")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
                  (CompilerIrInstrList.Nil)))
              (CompilerIrBlockList.Nil))))))))

(define (opt-bool-branch-multi-phi-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 0)
          (compiler-ir-label "left")
          (compiler-ir-label "right"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "left")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "merge"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "right")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "merge"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "merge")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Phi
                3
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.I64 11)
                  (compiler-ir-label "left")
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.I64 22)
                    (compiler-ir-label "right")
                    (CompilerIrPhiInputList.Nil)))
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Phi
                  4
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.Bool true)
                    (compiler-ir-label "left")
                    (compiler-ir-phi-input-cons
                      (CompilerIrValue.Bool false)
                      (compiler-ir-label "right")
                      (CompilerIrPhiInputList.Nil)))
                  (AstType.Bool))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Branch
                    (CompilerIrValue.Var 4)
                    (compiler-ir-label "yes")
                    (compiler-ir-label "no"))
                  (CompilerIrInstrList.Nil)))))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "yes")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                (CompilerIrInstrList.Nil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "no")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                  (CompilerIrInstrList.Nil)))
              (CompilerIrBlockList.Nil))))))))

(define (opt-bool-branch-constant-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "bool-branch-constant")
    (opt-bool-branch-two-cond-params)
    (AstType.I64)
    16
    blocks))

(define (opt-bool-branch-first-phi-has-label?
  [blocks : CompilerIrBlockList]
  [block-label : i64]
  [pred-label : i64]) : bool
  (match (opt-cfg-find-block blocks block-label)
    [(OptMaybeBlock.No) false]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (and
            (> (compiler-ir-instr-seq-count instrs) 0)
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.Phi _ inputs _)
                (opt-bool-branch-phi-input-has-label? inputs pred-label)]
              [_ false]))])]))

(define (opt-bool-branch-chain-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "a" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "b" (AstType.I64) 1)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "c" (AstType.I64) 2)
        (CompilerIrParamList.Nil)))))

;; mode 0: a three-comparison And tree; mode 1: its first And result also
;; escapes to a Mov and must block the rewrite; mode 2: an Or-mixed tree, which
;; is outside the first-cut transform.
(define (opt-bool-branch-chain-test-blocks [mode : i64]) : CompilerIrBlockList
  (let
    [first-op : CompilerIrBinOp
      (if (= mode 2)
        (CompilerIrBinOp.Or)
        (CompilerIrBinOp.And))]
    [after-first : CompilerIrInstrList
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          6
          first-op
          (CompilerIrValue.Var 3)
          (CompilerIrValue.Var 4)
          (AstType.Bool))
        (if (= mode 1)
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 8 (CompilerIrValue.Var 6) (AstType.Bool))
            (CompilerIrInstrList.Nil))
          (CompilerIrInstrList.Nil)))]
    [entry-tail : CompilerIrInstrList
      (opt-aggregate-instr-list-append
        after-first
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            7
            (CompilerIrBinOp.And)
            (CompilerIrValue.Var 6)
            (CompilerIrValue.Var 5)
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 7)
              (compiler-ir-label "yes")
              (compiler-ir-label "no"))
            (CompilerIrInstrList.Nil))))]
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            3
            (CompilerIrBinOp.Lt)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Ge)
              (CompilerIrValue.Var 2)
              (CompilerIrValue.I64 0)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                5
                (CompilerIrBinOp.Le)
                (CompilerIrValue.Var 1)
                (CompilerIrValue.Var 2)
                (AstType.I64))
              entry-tail))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "yes")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              9
              (compiler-ir-phi-input-cons
                (CompilerIrValue.I64 11)
                (compiler-ir-label "entry")
                (CompilerIrPhiInputList.Nil))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 9)))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "no")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Phi
                10
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.I64 22)
                  (compiler-ir-label "entry")
                  (CompilerIrPhiInputList.Nil))
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 10)))
                (CompilerIrInstrList.Nil))))
          (CompilerIrBlockList.Nil))))))

(define (opt-bool-branch-chain-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "bool-branch-chain")
    (opt-bool-branch-chain-test-params)
    (AstType.I64)
    16
    blocks))

(define (opt-bool-branch-chain-test-run [mode : i64]) : OptFunctionPassResult
  (let
    [blocks : CompilerIrBlockList (opt-bool-branch-chain-test-blocks mode)]
    [func : CompilerIrFunction (opt-bool-branch-chain-test-function blocks)]
    (opt-bool-branch-chain-function-with-context-result
      (opt-cfg-context-build blocks)
      false
      func)))

(define (opt-bool-branch-chain-compare-branch-block?
  [blocks : CompilerIrBlockList]
  [label : i64]) : bool
  (match (opt-cfg-find-block blocks label)
    [(OptMaybeBlock.No) false]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (and
            (= (compiler-ir-instr-seq-count instrs) 2)
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.BinOp dst op _ _ _)
                (and
                  (opt-bool-branch-compare-op? op)
                  (match (compiler-ir-instr-seq-ref instrs 1)
                    [(CompilerIrInstr.Branch (CompilerIrValue.Var cond) _ _)
                      (= dst cond)]
                    [_ false]))]
              [_ false]))])]))

(define (opt-cfg-switch-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Switch
          (CompilerIrValue.Var 0)
          1
          (compiler-ir-switch-case-cons
            1
            (compiler-ir-label "one")
            (compiler-ir-switch-case-cons
              2
              (compiler-ir-label "two")
              CompilerIrSwitchCaseList.Nil))
          (compiler-ir-label "other"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "one")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.I64 1)))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "two")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 2)))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "other")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

;: `opt-cfg-index-build` numbers blocks in block-list walk order, so for a walk
;: over the list the index was built from, the position *is* the id. Several
;: optimizer passes now rely on that instead of hashing the label to recover it
;: (refs #5718), and nothing else pins it: every other test here obtains an id
;: through `opt-cfg-index-id` and then uses it consistently, so renumbering the
;: index -- by reverse postorder, say, to make the dominator tables denser --
;: would leave those green while silently pointing the walk-position readers at
;: a different block. This asserts the numbering itself.
(define (opt-cfg-index-walk-order-ids-ok?
  [blocks : CompilerIrBlockList]
  [index : OptCfgIndex]
  [position : i64]) : bool
  (match blocks
    [(CompilerIrBlockList.Nil) true]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block label _)
          (and
            (match (opt-cfg-index-id index label)
              [(option_i64.Some id) (= id position)]
              [(option_i64.None) false])
            (opt-cfg-index-walk-order-ids-ok?
              (box-get rest)
              index
              (+ position 1)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-cfg-index-walk-order-ids-ok?
        (compiler-ir-block-seq-to-list seq)
        index
        position)]))

(define (opt-cfg-index-numbering-ok?) : bool
  (let
    [blocks : CompilerIrBlockList (opt-cfg-switch-blocks)]
    (opt-cfg-index-walk-order-ids-ok? blocks (opt-cfg-index-build blocks) 0)))

(define (opt-cfg-switch-successors-ok?) : bool
  (let
    [successors : OptLabelSet
      (opt-cfg-index-successors
        (opt-cfg-index-build (opt-cfg-switch-blocks))
        (compiler-ir-label "entry"))]
    (and
      (= (opt-label-count successors) 3)
      (opt-label-contains successors (compiler-ir-label "one"))
      (opt-label-contains successors (compiler-ir-label "two"))
      (opt-label-contains successors (compiler-ir-label "other")))))

(define (opt-ssa-cond-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 0)
    (CompilerIrParamList.Nil)))

(define (opt-ssa-loop-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "seed" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "cond" (AstType.Bool) 4)
      (CompilerIrParamList.Nil))))

(define (opt-ssa-diamond-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 0)
          (compiler-ir-label "then")
          (compiler-ir-label "else"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 20) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "join")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Phi
                3
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 1)
                  (compiler-ir-label "then")
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.Var 2)
                    (compiler-ir-label "else")
                    (CompilerIrPhiInputList.Nil)))
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                (CompilerIrInstrList.Nil))))
          (CompilerIrBlockList.Nil))))))

(define (opt-ssa-diamond-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_diamond")
    (opt-ssa-cond-params)
    (AstType.I64)
    16
    (opt-ssa-diamond-blocks)))

(define (opt-ssa-loop-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            1
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 0)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 2)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 4)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              2
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-ssa-loop-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_loop")
    (opt-ssa-loop-params)
    (AstType.I64)
    16
    (opt-ssa-loop-blocks)))

(define (opt-ssa-construct-diamond-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 0)
          (compiler-ir-label "then")
          (compiler-ir-label "else"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 20) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "join")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-ssa-construct-diamond-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_construct_diamond")
    (opt-ssa-cond-params)
    (AstType.I64)
    2
    (opt-ssa-construct-diamond-blocks)))

(define (opt-ssa-construct-loop-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 4)
    (CompilerIrParamList.Nil)))

(define (opt-ssa-construct-loop-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 4)
            (compiler-ir-label "body")
            (compiler-ir-label "exit"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              1
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-ssa-construct-loop-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_construct_loop")
    (opt-ssa-construct-loop-params)
    (AstType.I64)
    5
    (opt-ssa-construct-loop-blocks)))

(define (opt-ssa-construct-mutated-param-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "value" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "cond" (AstType.Bool) 1)
      (CompilerIrParamList.Nil))))

(define (opt-ssa-construct-mutated-param-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 1)
          (compiler-ir-label "then")
          (compiler-ir-label "else"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 10) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "join")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-ssa-construct-mutated-param-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_construct_mutated_param")
    (opt-ssa-construct-mutated-param-params)
    (AstType.I64)
    2
    (opt-ssa-construct-mutated-param-blocks)))

(define (opt-ssa-construct-address-taken-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.AddrOf 2 1)
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 2) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              (CompilerIrInstrList.Nil))))))
    (CompilerIrBlockList.Nil)))

(define (opt-ssa-construct-address-taken-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_construct_address_taken")
    (CompilerIrParamList.Nil)
    (AstType.I64)
    3
    (opt-ssa-construct-address-taken-blocks)))

;; The tail-recursion-to-loop shape: the back edge targets the function ENTRY
;; block and the latch reassigns the parameters. SSA construction must decline
;; this function (a phi at the entry block cannot see the implicit
;; function-entry edge that carries the initial parameter values).
(define (opt-ssa-entry-backedge-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "index" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "count" (AstType.I64) 1)
      (CompilerIrParamList.Nil))))

(define (opt-ssa-entry-backedge-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Lt)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.Var 1)
          (AstType.Bool))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 2)
            (compiler-ir-label "body")
            (compiler-ir-label "exit"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "body")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            3
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 0)
            (CompilerIrValue.I64 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 0 (CompilerIrValue.Var 3) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "entry"))
              (CompilerIrInstrList.Nil)))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "exit")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
            (CompilerIrInstrList.Nil)))
        (CompilerIrBlockList.Nil)))))

(define (opt-ssa-entry-backedge-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_entry_backedge")
    (opt-ssa-entry-backedge-params)
    (AstType.I64)
    4
    (opt-ssa-entry-backedge-blocks)))

(define (opt-natural-loop-nested-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "outer"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "outer")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "inner"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "inner")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 4)
              (compiler-ir-label "inner-body")
              (compiler-ir-label "outer-latch"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "inner-body")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "inner"))
              (CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "outer-latch")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 8)
                  (compiler-ir-label "outer")
                  (compiler-ir-label "exit"))
                (CompilerIrInstrList.Nil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
                  (CompilerIrInstrList.Nil)))
              (CompilerIrBlockList.Nil))))))))

(define (opt-natural-loop-irreducible-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Bool true)
          (compiler-ir-label "left")
          (compiler-ir-label "right"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "left")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "right"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "right")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Bool true)
              (compiler-ir-label "left")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-natural-loop-no-preheader-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Bool true)
          (compiler-ir-label "pre-one")
          (compiler-ir-label "pre-two"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "pre-one")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "pre-two")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "loop")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Bool true)
                (compiler-ir-label "body")
                (compiler-ir-label "exit"))
              (CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "body")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                (CompilerIrInstrList.Nil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
                  (CompilerIrInstrList.Nil)))
              (CompilerIrBlockList.Nil))))))))

(define (opt-natural-loop-multi-backedge-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Bool true)
            (compiler-ir-label "left")
            (compiler-ir-label "right"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "left")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "right")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-natural-loop-maybe-body-count [maybe : OptMaybeNaturalLoop]) : i64
  (match maybe
    [(OptMaybeNaturalLoop.No) 0]
    [(OptMaybeNaturalLoop.Some loop)
      (opt-label-count (opt-natural-loop-body loop))]))

(define (opt-natural-loop-maybe-body-block-count [maybe : OptMaybeNaturalLoop]) : i64
  (match maybe
    [(OptMaybeNaturalLoop.No) 0]
    [(OptMaybeNaturalLoop.Some loop)
      (compiler-ir-block-list-count (opt-natural-loop-body-blocks loop))]))

(define (opt-natural-loop-maybe-body-contains?
  [maybe : OptMaybeNaturalLoop]
  [label : i64]) : bool
  (match maybe
    [(OptMaybeNaturalLoop.No) false]
    [(OptMaybeNaturalLoop.Some loop)
      (opt-label-contains (opt-natural-loop-body loop) label)]))

(define (opt-natural-loop-maybe-body-contains-id?
  [index : OptCfgIndex]
  [maybe : OptMaybeNaturalLoop]
  [label : i64]) : bool
  (match maybe
    [(OptMaybeNaturalLoop.No) false]
    [(OptMaybeNaturalLoop.Some loop)
      (match (opt-cfg-index-id index label)
        [(option_i64.Some id) (opt-natural-loop-body-contains-id? loop id)]
        [(option_i64.None) false])]))

(define (opt-natural-loop-maybe-body-block-label-at?
  [maybe : OptMaybeNaturalLoop]
  [index : i64]
  [label : i64]) : bool
  (match maybe
    [(OptMaybeNaturalLoop.No) false]
    [(OptMaybeNaturalLoop.Some loop)
      (opt-block-list-label-at? (opt-natural-loop-body-blocks loop) index label)]))

(define (opt-natural-loop-maybe-preheader-label?
  [maybe : OptMaybeNaturalLoop]
  [label : i64]) : bool
  (match maybe
    [(OptMaybeNaturalLoop.No) false]
    [(OptMaybeNaturalLoop.Some loop)
      (match (opt-natural-loop-preheader loop)
        [(OptLoopPreheader.Some actual) (= actual label)]
        [(OptLoopPreheader.No) false])]))

(define (opt-natural-loop-maybe-no-preheader? [maybe : OptMaybeNaturalLoop]) : bool
  (match maybe
    [(OptMaybeNaturalLoop.No) false]
    [(OptMaybeNaturalLoop.Some loop)
      (match (opt-natural-loop-preheader loop)
        [(OptLoopPreheader.No) true]
        [(OptLoopPreheader.Some _) false])]))

(define (opt-loop-rotation-top-test-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            2
            (CompilerIrBinOp.Lt)
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 10)
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 2)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              1
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-loop-rotation-false-body-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            2
            (CompilerIrBinOp.Lt)
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 10)
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 2)
              (compiler-ir-label "exit")
              (compiler-ir-label "body"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              1
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-loop-rotation-successors?
  [blocks : CompilerIrBlockList]
  [label : i64]
  [left : i64]
  [right : i64]) : bool
  (let
    [successors : OptLabelSet
      (opt-cfg-index-successors (opt-cfg-index-build blocks) label)]
    (and
      (= (opt-label-count successors) 2)
      (opt-label-contains successors left)
      (opt-label-contains successors right))))

(define (opt-licm-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "lhs" (AstType.I64) 1)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "rhs" (AstType.I64) 2)
        (CompilerIrParamList.Nil)))))

(define (opt-licm-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "licm")
    (opt-licm-params)
    (AstType.I64)
    16
    blocks))

(define (opt-licm-optimized-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (opt-licm-function (opt-licm-test-function blocks)))

(define (opt-licm-array-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "array" (AstType.DynArray 0) 1)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "ptr" (AstType.U64) 2)
        (CompilerIrParamList.Nil)))))

(define (opt-licm-array-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "licm_array")
    (opt-licm-array-params)
    (AstType.I64)
    16
    blocks))

(define (opt-licm-array-optimized-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (opt-licm-function (opt-licm-array-test-function blocks)))

(define (opt-licm-array-optimized-function-with-direct-call-clean
  [blocks : CompilerIrBlockList]
  [direct-call-clean : opt_i64_i64_map.Map]) : CompilerIrFunction
  (opt-licm-function-with-direct-call-clean
    (opt-licm-array-test-function blocks)
    direct-call-clean))

(define (opt-licm-summary-for-instr [instr : CompilerIrInstr]) : OptLicmStoreSummary
  (opt-licm-store-summary-blocks
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "summary")
        (compiler-ir-instr-cons instr (CompilerIrInstrList.Nil)))
      (CompilerIrBlockList.Nil))
    (opt-licm-store-summary-empty)))

(define (opt-licm-arithmetic-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            4
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 3)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                CompilerIrPhiInputList.Nil))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              10
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.Var 2)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                11
                (CompilerIrBinOp.Mul)
                (CompilerIrValue.Var 10)
                (CompilerIrValue.I64 2)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 0)
                  (compiler-ir-label "body")
                  (compiler-ir-label "exit"))
                (CompilerIrInstrList.Nil))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              5
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 4)
              (CompilerIrValue.I64 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 11)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-licm-trap-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            10
            (CompilerIrBinOp.Div)
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 2)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 10)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-licm-call-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            8
            (opt-test-symbol "tl_noop")
            (CompilerIrCallArgs.Nil)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              10
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 8)
              (CompilerIrValue.Var 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Var 0)
                (compiler-ir-label "body")
                (compiler-ir-label "exit"))
              (CompilerIrInstrList.Nil)))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 10)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-licm-no-preheader-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 0)
          (compiler-ir-label "pre-one")
          (compiler-ir-label "pre-two"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "pre-one")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "pre-two")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "loop")
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                10
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 1)
                (CompilerIrValue.Var 2)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 0)
                  (compiler-ir-label "body")
                  (compiler-ir-label "exit"))
                (CompilerIrInstrList.Nil))))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "body")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                (CompilerIrInstrList.Nil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 10)))
                  (CompilerIrInstrList.Nil)))
              (CompilerIrBlockList.Nil))))))))

(define (opt-licm-nested-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "outer"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "outer")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "inner"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "inner")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              10
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.Var 2)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Var 0)
                (compiler-ir-label "inner-body")
                (compiler-ir-label "outer-latch"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "inner-body")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "inner"))
              (CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "outer-latch")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 0)
                  (compiler-ir-label "outer")
                  (compiler-ir-label "exit"))
                (CompilerIrInstrList.Nil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 10)))
                  (CompilerIrInstrList.Nil)))
              (CompilerIrBlockList.Nil))))))))

(define (opt-licm-load-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Alloc 6 (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 6)
              (CompilerIrValue.I64 99)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil))))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            4
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 3)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                CompilerIrPhiInputList.Nil))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              7
              (CompilerIrValue.Var 6)
              (CompilerIrValue.I64 0)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  5
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 4)
                  (CompilerIrValue.I64 1)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Branch
                    (CompilerIrValue.Var 0)
                    (compiler-ir-label "body")
                    (compiler-ir-label "exit"))
                  (CompilerIrInstrList.Nil)))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 8)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-licm-load-store-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Alloc 6 (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 6)
              (CompilerIrValue.I64 99)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil))))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            4
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 3)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                CompilerIrPhiInputList.Nil))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              7
              (CompilerIrValue.Var 6)
              (CompilerIrValue.I64 0)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.StorePtr
                  (CompilerIrValue.Var 7)
                  (CompilerIrValue.I64 100)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    5
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 4)
                    (CompilerIrValue.I64 1)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Branch
                      (CompilerIrValue.Var 0)
                      (compiler-ir-label "body")
                      (compiler-ir-label "exit"))
                    (CompilerIrInstrList.Nil))))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 8)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-licm-load-call-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Alloc 6 (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 6)
              (CompilerIrValue.I64 99)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil))))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            4
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 3)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                CompilerIrPhiInputList.Nil))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              7
              (CompilerIrValue.Var 6)
              (CompilerIrValue.I64 0)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Call
                  9
                  (opt-test-symbol "touch")
                  (CompilerIrCallArgs.Nil)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    5
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 4)
                    (CompilerIrValue.I64 1)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Branch
                      (CompilerIrValue.Var 0)
                      (compiler-ir-label "body")
                      (compiler-ir-label "exit"))
                    (CompilerIrInstrList.Nil))))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 8)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-licm-load-varying-address-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Alloc 6 (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 6)
              (CompilerIrValue.I64 99)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil))))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            4
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 3)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                CompilerIrPhiInputList.Nil))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              7
              (CompilerIrValue.Var 6)
              (CompilerIrValue.Var 4)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  5
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 4)
                  (CompilerIrValue.I64 1)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Branch
                    (CompilerIrValue.Var 0)
                    (compiler-ir-label "body")
                    (compiler-ir-label "exit"))
                  (CompilerIrInstrList.Nil)))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 8)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-licm-loop-blocks-with-body
  [body : CompilerIrInstrList]
  [ret-var : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            4
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 3)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                CompilerIrPhiInputList.Nil))
            (AstType.I64))
          body))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var ret-var)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-licm-loop-finish-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.BinOp
      5
      (CompilerIrBinOp.Add)
      (CompilerIrValue.Var 4)
      (CompilerIrValue.I64 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Branch
        (CompilerIrValue.Var 0)
        (compiler-ir-label "body")
        (compiler-ir-label "exit"))
      (CompilerIrInstrList.Nil))))

(define (opt-licm-header-load-element-store-blocks) : CompilerIrBlockList
  (opt-licm-loop-blocks-with-body
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        7
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            9
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 0)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 10 (CompilerIrValue.Var 9) (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                11
                (CompilerIrValue.Var 10)
                (CompilerIrValue.Var 4)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.StorePtr
                  (CompilerIrValue.Var 11)
                  (CompilerIrValue.I64 100)
                  (AstType.I64))
                (opt-licm-loop-finish-instrs)))))))
    8))

;; Hashmap slots add an inline-field Gep after the scaled slot-address Gep.
;; Both hops remain inside the separately allocated data buffer, so neither
;; store can change the descriptor's data/length fields.
(define (opt-licm-header-load-element-gep-chain-store-blocks) : CompilerIrBlockList
  (opt-licm-loop-blocks-with-body
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        7
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            9
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 0)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 10 (CompilerIrValue.Var 9) (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                11
                (CompilerIrValue.Var 10)
                (CompilerIrValue.Var 4)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Gep
                  12
                  (CompilerIrValue.Var 11)
                  (CompilerIrValue.I64 8)
                  (AstType.U8))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.StorePtr
                    (CompilerIrValue.Var 12)
                    (CompilerIrValue.I64 100)
                    (AstType.I64))
                  (opt-licm-loop-finish-instrs))))))))
    8))

(define (opt-licm-header-load-header-store-blocks) : CompilerIrBlockList
  (opt-licm-loop-blocks-with-body
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        7
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            9
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 0)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 7)
              (CompilerIrValue.I64 101)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.StorePtr
                (CompilerIrValue.Var 9)
                (CompilerIrValue.I64 102)
                (AstType.U64))
              (opt-licm-loop-finish-instrs))))))
    8))

(define (opt-licm-header-load-copybytes-blocks) : CompilerIrBlockList
  (opt-licm-loop-blocks-with-body
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        7
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.CopyBytes
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 2)
            8)
          (opt-licm-loop-finish-instrs))))
    8))

(defstruct OptLicmTestSymbols
  (touch i64)
  (probe i64)
  (writer i64)
  (leaf i64))

(define (opt-licm-test-symbols) : OptLicmTestSymbols
  (OptLicmTestSymbols
    (opt-test-symbol "touch")
    (opt-test-symbol "probe")
    (opt-test-symbol "writer")
    (opt-test-symbol "leaf")))

(define (opt-licm-header-load-call-blocks [symbols : OptLicmTestSymbols]) : CompilerIrBlockList
  (opt-licm-loop-blocks-with-body
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        7
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            9
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 0)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 10 (CompilerIrValue.Var 9) (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                11
                (CompilerIrValue.Var 10)
                (CompilerIrValue.Var 4)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.StorePtr
                  (CompilerIrValue.Var 11)
                  (CompilerIrValue.I64 100)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Call
                    12
                    (struct-get symbols touch)
                    (CompilerIrCallArgs.Nil)
                    (AstType.I64))
                  (opt-licm-loop-finish-instrs))))))))
    8))

(define (opt-licm-header-load-unknown-store-blocks) : CompilerIrBlockList
  (opt-licm-loop-blocks-with-body
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        7
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 103)
            (AstType.I64))
          (opt-licm-loop-finish-instrs))))
    8))

;; A Gep does not sanitize an unknown/escaped raw pointer. Its store remains a
;; full alias barrier for descriptor loads.
(define (opt-licm-header-load-unknown-gep-store-blocks) : CompilerIrBlockList
  (opt-licm-loop-blocks-with-body
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        7
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            9
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 8)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 9)
              (CompilerIrValue.I64 103)
              (AstType.I64))
            (opt-licm-loop-finish-instrs)))))
    8))

(define (opt-licm-element-load-element-store-blocks) : CompilerIrBlockList
  (opt-licm-loop-blocks-with-body
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        7
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 0)
        (AstType.U8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.U64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            9
            (CompilerIrValue.Var 8)
            (CompilerIrValue.Var 4)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 10 (CompilerIrValue.Var 9) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.StorePtr
                (CompilerIrValue.Var 9)
                (CompilerIrValue.I64 100)
                (AstType.I64))
              (opt-licm-loop-finish-instrs))))))
    10))

(define (opt-licm-direct-call-clean-test-functions
  [symbols : OptLicmTestSymbols]) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-test-function-symbol
      (struct-get symbols probe)
      (compiler-ir-instr-cons
        (CompilerIrInstr.Call
          90
          (struct-get symbols probe)
          (CompilerIrCallArgs.Nil)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 90)))
          (CompilerIrInstrList.Nil))))
    (compiler-ir-function-cons
      (opt-test-function-symbol
        (struct-get symbols writer)
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-function-cons
        (opt-test-function-symbol
          (struct-get symbols leaf)
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 7)))
            (CompilerIrInstrList.Nil)))
        (CompilerIrFunctionList.Nil)))))

(cfg
  test
  (define (opt-licm-checked-root-params
    [read-ty : AstType]
    [write-ty : AstType]
    [other-ty : AstType]) : CompilerIrParamList
    (compiler-ir-param-cons
      (CompilerIrParam.Param "cond" (AstType.Bool) 0)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "read" read-ty 1)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "write" write-ty 2)
          (compiler-ir-param-cons
            (CompilerIrParam.Param "raw" (AstType.U64) 3)
            (compiler-ir-param-cons
              (CompilerIrParam.Param "other" other-ty 4)
              (CompilerIrParamList.Nil))))))))

(cfg
  test
  (define (opt-licm-checked-root-function
    [read-ty : AstType]
    [write-ty : AstType]
    [other-ty : AstType]
    [blocks : CompilerIrBlockList]) : CompilerIrFunction
    (CompilerIrFunction.Function
      (opt-test-symbol "licm_checked_root")
      (opt-licm-checked-root-params read-ty write-ty other-ty)
      (AstType.I64)
      32
      blocks)))

(cfg
  test
  (define (opt-licm-checked-root-barrier [mode : i64]) : CompilerIrInstrList
    (cond
      [(= mode 1)
        (compiler-ir-instr-cons
          (CompilerIrInstr.CopyBytes
            (CompilerIrValue.Var 3)
            (CompilerIrValue.Var 3)
            8)
          (CompilerIrInstrList.Nil))]
      [(= mode 2)
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            11
            (opt-test-symbol "touch")
            (CompilerIrCallArgs.Nil)
            (AstType.I64))
          (CompilerIrInstrList.Nil))]
      [else (CompilerIrInstrList.Nil)])))

(cfg
  test
  (define (opt-licm-checked-root-loop-tail) : CompilerIrInstrList
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        7
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 6)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 0)
          (compiler-ir-label "body")
          (compiler-ir-label "exit"))
        (CompilerIrInstrList.Nil)))))

(cfg
  test
  (define (opt-licm-checked-root-blocks
    [load-base : i64]
    [store-base : i64]
    [barrier-mode : i64]) : CompilerIrBlockList
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 5 (CompilerIrValue.I64 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "loop")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              6
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "entry")
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 7)
                  (compiler-ir-label "body")
                  (CompilerIrPhiInputList.Nil)))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                8
                (CompilerIrValue.Var load-base)
                (CompilerIrValue.I64 0)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 9 (CompilerIrValue.Var 8) (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Gep
                    10
                    (CompilerIrValue.Var store-base)
                    (CompilerIrValue.I64 0)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.StorePtr
                      (CompilerIrValue.Var 10)
                      (CompilerIrValue.I64 9)
                      (AstType.I64))
                    (opt-aggregate-instr-list-append
                      (opt-licm-checked-root-barrier barrier-mode)
                      (opt-licm-checked-root-loop-tail))))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "body")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "exit")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 9)))
                (CompilerIrInstrList.Nil)))
            (CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (opt-licm-checked-root-fresh-blocks) : CompilerIrBlockList
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 5 (CompilerIrValue.I64 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Call
              12
              cbi.compiler-builtin-id-tl-alloc
              (CompilerIrCallArgs.Nil)
              (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil)))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "loop")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              6
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "entry")
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 7)
                  (compiler-ir-label "body")
                  (CompilerIrPhiInputList.Nil)))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                8
                (CompilerIrValue.Var 1)
                (CompilerIrValue.I64 0)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 9 (CompilerIrValue.Var 8) (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Gep
                    10
                    (CompilerIrValue.Var 12)
                    (CompilerIrValue.I64 0)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.StorePtr
                      (CompilerIrValue.Var 10)
                      (CompilerIrValue.I64 9)
                      (AstType.I64))
                    (opt-licm-checked-root-loop-tail)))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "body")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "exit")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 9)))
                (CompilerIrInstrList.Nil)))
            (CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (opt-licm-checked-root-fresh-header-blocks) : CompilerIrBlockList
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 5 (CompilerIrValue.I64 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Call
              12
              cbi.compiler-builtin-id-tl-alloc
              (CompilerIrCallArgs.One (CompilerIrValue.I64 16))
              (AstType.DynArray 0))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil)))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "loop")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              6
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "entry")
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 7)
                  (compiler-ir-label "body")
                  (CompilerIrPhiInputList.Nil)))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                8
                (CompilerIrValue.Var 12)
                (CompilerIrValue.I64 1)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 9 (CompilerIrValue.Var 8) (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Gep
                    10
                    (CompilerIrValue.Var 12)
                    (CompilerIrValue.I64 0)
                    (AstType.U8))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Load
                      11
                      (CompilerIrValue.Var 10)
                      (AstType.U64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Gep
                        13
                        (CompilerIrValue.Var 11)
                        (CompilerIrValue.Var 6)
                        (AstType.I64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.StorePtr
                          (CompilerIrValue.Var 13)
                          (CompilerIrValue.I64 9)
                          (AstType.I64))
                        (opt-licm-checked-root-loop-tail)))))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "body")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              (CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "exit")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 9)))
                (CompilerIrInstrList.Nil)))
            (CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (opt-licm-checked-root-join-blocks [mixed? : bool]) : CompilerIrBlockList
    (let
      [ref-ty : AstType (ast-ty-ref 0 (AstType.I64))]
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "left")
              (compiler-ir-label "right"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "left")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov 5 (CompilerIrValue.Var 1) ref-ty)
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "join"))
                (CompilerIrInstrList.Nil))))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "right")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Mov
                  6
                  (CompilerIrValue.Var
                    (if mixed?
                      4
                      1))
                  ref-ty)
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Jump (compiler-ir-label "join"))
                  (CompilerIrInstrList.Nil))))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "join")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Phi
                    7
                    (compiler-ir-phi-input-cons
                      (CompilerIrValue.Var 5)
                      (compiler-ir-label "left")
                      (compiler-ir-phi-input-cons
                        (CompilerIrValue.Var 6)
                        (compiler-ir-label "right")
                        (CompilerIrPhiInputList.Nil)))
                    ref-ty)
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Mov
                      8
                      (CompilerIrValue.I64 0)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                      (CompilerIrInstrList.Nil)))))
              (compiler-ir-block-cons
                (compiler-ir-block
                  (compiler-ir-label "loop")
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Phi
                      9
                      (compiler-ir-phi-input-cons
                        (CompilerIrValue.Var 8)
                        (compiler-ir-label "join")
                        (compiler-ir-phi-input-cons
                          (CompilerIrValue.Var 10)
                          (compiler-ir-label "body")
                          (CompilerIrPhiInputList.Nil)))
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Gep
                        11
                        (CompilerIrValue.Var 7)
                        (CompilerIrValue.I64 0)
                        (AstType.I64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Load
                          12
                          (CompilerIrValue.Var 11)
                          (AstType.I64))
                        (compiler-ir-instr-cons
                          (CompilerIrInstr.Gep
                            13
                            (CompilerIrValue.Var 2)
                            (CompilerIrValue.I64 0)
                            (AstType.I64))
                          (compiler-ir-instr-cons
                            (CompilerIrInstr.StorePtr
                              (CompilerIrValue.Var 13)
                              (CompilerIrValue.I64 9)
                              (AstType.I64))
                            (compiler-ir-instr-cons
                              (CompilerIrInstr.BinOp
                                10
                                (CompilerIrBinOp.Add)
                                (CompilerIrValue.Var 9)
                                (CompilerIrValue.I64 1)
                                (AstType.I64))
                              (compiler-ir-instr-cons
                                (CompilerIrInstr.Branch
                                  (CompilerIrValue.Var 0)
                                  (compiler-ir-label "body")
                                  (compiler-ir-label "exit"))
                                (CompilerIrInstrList.Nil)))))))))
                (compiler-ir-block-cons
                  (compiler-ir-block
                    (compiler-ir-label "body")
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                      (CompilerIrInstrList.Nil)))
                  (compiler-ir-block-cons
                    (compiler-ir-block
                      (compiler-ir-label "exit")
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Return
                          (CompilerIrMaybeValue.Some (CompilerIrValue.Var 12)))
                        (CompilerIrInstrList.Nil)))
                    (CompilerIrBlockList.Nil)))))))))))

(cfg
  test
  (define (opt-licm-summary-memory-barrier? [instr : CompilerIrInstr]) : bool
    (not (opt-licm-store-summary-clean? (opt-licm-summary-for-instr instr)))))

(cfg
  test
  (define (compiler-optimize-licm-checked-root-self-test) : i64
    (let
      [ref-ty : AstType (ast-ty-ref 0 (AstType.I64))]
      [mut-ref-ty : AstType (ast-ty-mut-ref 0 (AstType.I64))]
      [ref-distinct-func : CompilerIrFunction
        (opt-licm-function
          (opt-licm-checked-root-function
            ref-ty
            mut-ref-ty
            ref-ty
            (opt-licm-checked-root-blocks 1 2 0)))]
      [ref-distinct : CompilerIrBlockList
        (opt-function-blocks ref-distinct-func)]
      [mut-distinct-func : CompilerIrFunction
        (opt-licm-function
          (opt-licm-checked-root-function
            mut-ref-ty
            mut-ref-ty
            ref-ty
            (opt-licm-checked-root-blocks 1 2 0)))]
      [mut-distinct : CompilerIrBlockList
        (opt-function-blocks mut-distinct-func)]
      [same-func : CompilerIrFunction
        (opt-licm-function
          (opt-licm-checked-root-function
            mut-ref-ty
            mut-ref-ty
            ref-ty
            (opt-licm-checked-root-blocks 1 1 0)))]
      [same : CompilerIrBlockList (opt-function-blocks same-func)]
      [shared-store-func : CompilerIrFunction
        (opt-licm-function
          (opt-licm-checked-root-function
            ref-ty
            mut-ref-ty
            ref-ty
            (opt-licm-checked-root-blocks 1 4 0)))]
      [shared-store : CompilerIrBlockList
        (opt-function-blocks shared-store-func)]
      [raw-store-func : CompilerIrFunction
        (opt-licm-function
          (opt-licm-checked-root-function
            ref-ty
            mut-ref-ty
            ref-ty
            (opt-licm-checked-root-blocks 1 3 0)))]
      [raw-store : CompilerIrBlockList (opt-function-blocks raw-store-func)]
      [copybytes-func : CompilerIrFunction
        (opt-licm-function
          (opt-licm-checked-root-function
            ref-ty
            mut-ref-ty
            ref-ty
            (opt-licm-checked-root-blocks 1 2 1)))]
      [copybytes : CompilerIrBlockList (opt-function-blocks copybytes-func)]
      [call-func : CompilerIrFunction
        (opt-licm-function
          (opt-licm-checked-root-function
            ref-ty
            mut-ref-ty
            ref-ty
            (opt-licm-checked-root-blocks 1 2 2)))]
      [call-blocks : CompilerIrBlockList (opt-function-blocks call-func)]
      [fresh-func : CompilerIrFunction
        (opt-licm-function
          (opt-licm-checked-root-function
            ref-ty
            mut-ref-ty
            ref-ty
            (opt-licm-checked-root-fresh-blocks)))]
      [fresh : CompilerIrBlockList (opt-function-blocks fresh-func)]
      [fresh-header-func : CompilerIrFunction
        (opt-licm-function
          (opt-licm-checked-root-function
            ref-ty
            mut-ref-ty
            ref-ty
            (opt-licm-checked-root-fresh-header-blocks)))]
      [fresh-header : CompilerIrBlockList
        (opt-function-blocks fresh-header-func)]
      [join-func : CompilerIrFunction
        (opt-licm-function
          (opt-licm-checked-root-function
            ref-ty
            mut-ref-ty
            ref-ty
            (opt-licm-checked-root-join-blocks false)))]
      [join-blocks : CompilerIrBlockList (opt-function-blocks join-func)]
      [mixed-join-func : CompilerIrFunction
        (opt-licm-function
          (opt-licm-checked-root-function
            ref-ty
            mut-ref-ty
            ref-ty
            (opt-licm-checked-root-join-blocks true)))]
      [mixed-join : CompilerIrBlockList (opt-function-blocks mixed-join-func)]
      (cond
        [(not (opt-verify-ok? (opt-verify-function ref-distinct-func))) 1]
        [(not
            (=
              (opt-count-load-label-blocks
                ref-distinct
                (compiler-ir-label "entry"))
              1))
          2]
        [(not
            (=
              (opt-count-load-label-blocks
                ref-distinct
                (compiler-ir-label "loop"))
              0))
          3]
        [(not (opt-verify-ok? (opt-verify-function mut-distinct-func))) 4]
        [(not
            (=
              (opt-count-load-label-blocks
                mut-distinct
                (compiler-ir-label "entry"))
              1))
          5]
        [(not
            (=
              (opt-count-load-label-blocks
                mut-distinct
                (compiler-ir-label "loop"))
              0))
          6]
        [(not
            (= (opt-count-load-label-blocks same (compiler-ir-label "loop")) 1))
          7]
        [(not
            (=
              (opt-count-load-label-blocks
                shared-store
                (compiler-ir-label "loop"))
              1))
          8]
        [(not
            (=
              (opt-count-load-label-blocks raw-store (compiler-ir-label "loop"))
              1))
          9]
        [(not
            (=
              (opt-count-load-label-blocks copybytes (compiler-ir-label "loop"))
              1))
          10]
        [(not
            (=
              (opt-count-load-label-blocks
                call-blocks
                (compiler-ir-label "loop"))
              1))
          11]
        [(not (opt-verify-ok? (opt-verify-function fresh-func))) 12]
        [(not
            (=
              (opt-count-load-label-blocks fresh (compiler-ir-label "entry"))
              1))
          13]
        [(not
            (= (opt-count-load-label-blocks fresh (compiler-ir-label "loop")) 0))
          14]
        [(not (opt-verify-ok? (opt-verify-function join-func))) 15]
        [(not
            (=
              (opt-count-load-label-blocks
                join-blocks
                (compiler-ir-label "join"))
              1))
          16]
        [(not
            (=
              (opt-count-load-label-blocks
                join-blocks
                (compiler-ir-label "loop"))
              0))
          17]
        [(not
            (=
              (opt-count-load-label-blocks
                mixed-join
                (compiler-ir-label "loop"))
              1))
          18]
        [(not
            (opt-licm-summary-memory-barrier?
              (CompilerIrInstr.Store
                (opt-test-symbol "global")
                (CompilerIrValue.I64 1)
                (AstType.I64))))
          19]
        [(not
            (opt-licm-summary-memory-barrier?
              (ir-instr-vector-store
                (CompilerIrValue.Var 1)
                (CompilerIrValue.I64 0)
                (CompilerIrValue.I64 1)
                4
                (AstType.I64))))
          20]
        [(not
            (opt-licm-summary-memory-barrier?
              (ir-instr-predicated-store
                (CompilerIrValue.Var 1)
                (CompilerIrValue.I64 0)
                (CompilerIrValue.I64 1)
                (CompilerIrValue.I64 15)
                4
                (AstType.I64))))
          21]
        [(not
            (opt-licm-summary-memory-barrier?
              (CompilerIrInstr.Syscall 90 (CompilerIrCallArgs.Nil))))
          22]
        [(not (opt-verify-ok? (opt-verify-function fresh-header-func))) 23]
        [(not
            (=
              (opt-count-load-label-blocks
                fresh-header
                (compiler-ir-label "entry"))
              2))
          24]
        [(not
            (=
              (opt-count-load-label-blocks
                fresh-header
                (compiler-ir-label "loop"))
              0))
          25]
        [else 42]))))

(define (compiler-optimize-licm-self-test) : i64
  (let
    [symbols : OptLicmTestSymbols (opt-licm-test-symbols)]
    [arith-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-arithmetic-blocks))]
    [arith : CompilerIrBlockList (opt-function-blocks arith-func)]
    [trap-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-trap-blocks))]
    [trap : CompilerIrBlockList (opt-function-blocks trap-func)]
    [call-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-call-blocks))]
    [call-blocks : CompilerIrBlockList (opt-function-blocks call-func)]
    [no-preheader-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-no-preheader-blocks))]
    [no-preheader : CompilerIrBlockList (opt-function-blocks no-preheader-func)]
    [nested-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-nested-blocks))]
    [nested : CompilerIrBlockList (opt-function-blocks nested-func)]
    [load-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-load-blocks))]
    [load-blocks : CompilerIrBlockList (opt-function-blocks load-func)]
    [load-store-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-load-store-blocks))]
    [load-store : CompilerIrBlockList (opt-function-blocks load-store-func)]
    [load-call-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-load-call-blocks))]
    [load-call : CompilerIrBlockList (opt-function-blocks load-call-func)]
    [load-varying-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-load-varying-address-blocks))]
    [load-varying : CompilerIrBlockList (opt-function-blocks load-varying-func)]
    [header-element-func : CompilerIrFunction
      (opt-licm-array-optimized-function
        (opt-licm-header-load-element-store-blocks))]
    [header-element : CompilerIrBlockList
      (opt-function-blocks header-element-func)]
    [header-element-chain-func : CompilerIrFunction
      (opt-licm-array-optimized-function
        (opt-licm-header-load-element-gep-chain-store-blocks))]
    [header-element-chain : CompilerIrBlockList
      (opt-function-blocks header-element-chain-func)]
    [header-store-func : CompilerIrFunction
      (opt-licm-array-optimized-function
        (opt-licm-header-load-header-store-blocks))]
    [header-store : CompilerIrBlockList (opt-function-blocks header-store-func)]
    [copybytes-func : CompilerIrFunction
      (opt-licm-array-optimized-function
        (opt-licm-header-load-copybytes-blocks))]
    [copybytes-blocks : CompilerIrBlockList
      (opt-function-blocks copybytes-func)]
    [header-call-func : CompilerIrFunction
      (opt-licm-array-optimized-function
        (opt-licm-header-load-call-blocks symbols))]
    [header-call : CompilerIrBlockList (opt-function-blocks header-call-func)]
    [clean-touch-calls : opt_i64_i64_map.Map
      (let
        [map : opt_i64_i64_map.Map (opt_i64_i64_map.with-capacity 8)]
        (begin
          (opt_i64_i64_map.insert-ref!
            (&mut map)
            (compiler-ir-symbol-id (struct-get symbols touch))
            1)
          map))]
    [header-clean-call-func : CompilerIrFunction
      (opt-licm-array-optimized-function-with-direct-call-clean
        (opt-licm-header-load-call-blocks symbols)
        clean-touch-calls)]
    [header-clean-call : CompilerIrBlockList
      (opt-function-blocks header-clean-call-func)]
    [unknown-store-func : CompilerIrFunction
      (opt-licm-array-optimized-function
        (opt-licm-header-load-unknown-store-blocks))]
    [unknown-store : CompilerIrBlockList
      (opt-function-blocks unknown-store-func)]
    [unknown-gep-store-func : CompilerIrFunction
      (opt-licm-array-optimized-function
        (opt-licm-header-load-unknown-gep-store-blocks))]
    [unknown-gep-store : CompilerIrBlockList
      (opt-function-blocks unknown-gep-store-func)]
    [element-load-func : CompilerIrFunction
      (opt-licm-array-optimized-function
        (opt-licm-element-load-element-store-blocks))]
    [element-load : CompilerIrBlockList (opt-function-blocks element-load-func)]
    [raw-slot-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-header-load-element-store-blocks))]
    [raw-slot : CompilerIrBlockList (opt-function-blocks raw-slot-func)]
    [clean-summary : OptLicmStoreSummary
      (opt-licm-summary-for-instr
        (CompilerIrInstr.BinOp
          80
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 1)
          (CompilerIrValue.Var 2)
          (AstType.I64)))]
    [store-summary : OptLicmStoreSummary
      (opt-licm-summary-for-instr
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 6)
          (CompilerIrValue.I64 100)
          (AstType.I64)))]
    [call-summary : OptLicmStoreSummary
      (opt-licm-summary-for-instr
        (CompilerIrInstr.Call
          81
          (struct-get symbols touch)
          (CompilerIrCallArgs.Nil)
          (AstType.I64)))]
    [element-summary : OptLicmStoreSummary
      (opt-licm-store-summary-element-only-store)]
    [direct-clean-built : opt_i64_i64_map.Map
      (opt-loop-bce-direct-call-clean-map
        (opt-licm-direct-call-clean-test-functions symbols)
        8)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function arith-func))) 1]
      [(not
          (= (opt-count-arith-label-blocks arith (compiler-ir-label "entry")) 2))
        2]
      [(not
          (= (opt-count-arith-label-blocks arith (compiler-ir-label "loop")) 0))
        3]
      [(not
          (= (opt-count-arith-label-blocks arith (compiler-ir-label "body")) 1))
        4]
      [(not (opt-verify-ok? (opt-verify-function trap-func))) 5]
      [(not
          (= (opt-count-arith-label-blocks trap (compiler-ir-label "loop")) 1))
        6]
      [(not (opt-verify-ok? (opt-verify-function call-func))) 7]
      [(not
          (=
            (opt-count-arith-label-blocks
              call-blocks
              (compiler-ir-label "loop"))
            1))
        8]
      [(not (opt-verify-ok? (opt-verify-function no-preheader-func))) 9]
      [(not
          (=
            (opt-count-arith-label-blocks
              no-preheader
              (compiler-ir-label "loop"))
            1))
        10]
      [(not (= (opt-count-arith-blocks no-preheader) 1)) 11]
      [(not (opt-verify-ok? (opt-verify-function nested-func))) 12]
      [(not
          (=
            (opt-count-arith-label-blocks nested (compiler-ir-label "inner"))
            0))
        13]
      [(not (= (opt-count-arith-blocks nested) 1)) 14]
      [(not (opt-verify-ok? (opt-verify-function load-func))) 15]
      [(not
          (=
            (opt-count-gep-label-blocks load-blocks (compiler-ir-label "entry"))
            1))
        16]
      [(not
          (=
            (opt-count-load-label-blocks
              load-blocks
              (compiler-ir-label "entry"))
            1))
        17]
      [(not
          (=
            (opt-count-load-label-blocks load-blocks (compiler-ir-label "loop"))
            0))
        18]
      [(not (opt-verify-ok? (opt-verify-function load-store-func))) 19]
      [(not
          (=
            (opt-count-load-label-blocks load-store (compiler-ir-label "loop"))
            1))
        20]
      [(not
          (=
            (opt-count-load-label-blocks load-store (compiler-ir-label "entry"))
            0))
        21]
      [(not (opt-verify-ok? (opt-verify-function load-call-func))) 22]
      [(not
          (=
            (opt-count-load-label-blocks load-call (compiler-ir-label "loop"))
            1))
        23]
      [(not (opt-verify-ok? (opt-verify-function load-varying-func))) 24]
      [(not
          (=
            (opt-count-load-label-blocks
              load-varying
              (compiler-ir-label "loop"))
            1))
        25]
      [(opt-licm-value-invariant?
          (opt_i64_i64_map.with-capacity 4)
          (opt_i64_i64_map.with-capacity 4)
          (CompilerIrValue.Global (opt-test-symbol "g")))
        26]
      [(not (opt-licm-store-summary-clean? clean-summary)) 27]
      [(opt-licm-store-summary-clean? store-summary) 28]
      [(not (struct-get store-summary header-or-unknown-store?)) 29]
      [(struct-get store-summary call-or-unknown?) 30]
      [(opt-licm-store-summary-clean? call-summary) 31]
      [(not (struct-get call-summary call-or-unknown?)) 32]
      [(struct-get call-summary header-or-unknown-store?) 33]
      [(opt-licm-store-summary-clean? element-summary) 34]
      [(not (struct-get element-summary element-only-store?)) 35]
      [(not (opt-verify-ok? (opt-verify-function header-element-func))) 36]
      [(not
          (=
            (opt-count-load-label-blocks
              header-element
              (compiler-ir-label "entry"))
            2))
        37]
      [(not
          (=
            (opt-count-load-label-blocks
              header-element
              (compiler-ir-label "loop"))
            0))
        38]
      [(not
          (=
            (opt-count-gep-label-blocks
              header-element
              (compiler-ir-label "entry"))
            2))
        39]
      [(not (opt-verify-ok? (opt-verify-function header-store-func))) 40]
      [(not
          (=
            (opt-count-load-label-blocks
              header-store
              (compiler-ir-label "loop"))
            1))
        41]
      [(not
          (=
            (opt-count-load-label-blocks
              header-store
              (compiler-ir-label "entry"))
            0))
        43]
      [(not (opt-verify-ok? (opt-verify-function copybytes-func))) 44]
      [(not
          (=
            (opt-count-load-label-blocks
              copybytes-blocks
              (compiler-ir-label "loop"))
            1))
        45]
      [(not
          (=
            (opt-count-load-label-blocks
              copybytes-blocks
              (compiler-ir-label "entry"))
            0))
        46]
      [(not (opt-verify-ok? (opt-verify-function header-call-func))) 47]
      [(not
          (=
            (opt-count-load-label-blocks header-call (compiler-ir-label "loop"))
            2))
        48]
      [(not
          (=
            (opt-count-load-label-blocks
              header-call
              (compiler-ir-label "entry"))
            0))
        49]
      [(not (opt-verify-ok? (opt-verify-function header-clean-call-func))) 50]
      [(not
          (=
            (opt-count-load-label-blocks
              header-clean-call
              (compiler-ir-label "entry"))
            2))
        51]
      [(not
          (=
            (opt-count-load-label-blocks
              header-clean-call
              (compiler-ir-label "loop"))
            0))
        52]
      [(not (opt-verify-ok? (opt-verify-function unknown-store-func))) 53]
      [(not
          (=
            (opt-count-load-label-blocks
              unknown-store
              (compiler-ir-label "loop"))
            1))
        54]
      [(not
          (=
            (opt-count-load-label-blocks
              unknown-store
              (compiler-ir-label "entry"))
            0))
        55]
      [(not (opt-verify-ok? (opt-verify-function element-load-func))) 56]
      [(not
          (=
            (opt-count-load-label-blocks
              element-load
              (compiler-ir-label "entry"))
            1))
        57]
      [(not
          (=
            (opt-count-load-label-blocks
              element-load
              (compiler-ir-label "loop"))
            1))
        58]
      [(not (opt-verify-ok? (opt-verify-function raw-slot-func))) 59]
      [(not
          (=
            (opt-count-load-label-blocks raw-slot (compiler-ir-label "entry"))
            0))
        60]
      [(not
          (=
            (opt-count-load-label-blocks raw-slot (compiler-ir-label "loop"))
            2))
        61]
      [(not
          (opt_i64_i64_map.contains?
            (& direct-clean-built)
            (compiler-ir-symbol-id (struct-get symbols probe))))
        62]
      [(opt_i64_i64_map.contains?
          (& direct-clean-built)
          (compiler-ir-symbol-id (struct-get symbols writer)))
        63]
      [(opt_i64_i64_map.contains?
          (& direct-clean-built)
          (compiler-ir-symbol-id (struct-get symbols leaf)))
        64]
      ;; A descriptor load crosses the two-Gep data-buffer store chain.
      [(not (opt-verify-ok? (opt-verify-function header-element-chain-func)))
        65]
      [(not
          (=
            (opt-count-load-label-blocks
              header-element-chain
              (compiler-ir-label "entry"))
            2))
        66]
      [(not
          (=
            (opt-count-load-label-blocks
              header-element-chain
              (compiler-ir-label "loop"))
            0))
        67]
      ;; The corresponding unknown-pointer chain must remain a barrier.
      [(not (opt-verify-ok? (opt-verify-function unknown-gep-store-func))) 68]
      [(not
          (=
            (opt-count-load-label-blocks
              unknown-gep-store
              (compiler-ir-label "entry"))
            0))
        69]
      [(not
          (=
            (opt-count-load-label-blocks
              unknown-gep-store
              (compiler-ir-label "loop"))
            1))
        70]
      [else 42])))

(define (opt-induction-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "seed" (AstType.I64) 1)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "ptr" (AstType.I64) 2)
        (CompilerIrParamList.Nil)))))

(define (opt-induction-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "induction")
    (opt-induction-params)
    (AstType.I64)
    32
    blocks))

(define (opt-induction-optimized-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (opt-induction-function (opt-induction-test-function blocks)))

(define (opt-induction-offset-blocks [step : i64] [scale : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            3
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 1)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Mul)
              (CompilerIrValue.Var 3)
              (CompilerIrValue.I64 scale)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                6
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 4)
                (CompilerIrValue.I64 7)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  5
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 3)
                  (CompilerIrValue.I64 step)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                  (CompilerIrInstrList.Nil))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-induction-gep-blocks [step : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            3
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 1)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              4
              (CompilerIrValue.Var 2)
              (CompilerIrValue.Var 3)
              (AstType.U8))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 6 (CompilerIrValue.Var 4) (AstType.U8))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  5
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 3)
                  (CompilerIrValue.I64 step)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                  (CompilerIrInstrList.Nil))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-induction-offset-index-mul-blocks
  [step : i64]
  [op : CompilerIrBinOp]
  [offset : i64]
  [scale : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            3
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 1)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              op
              (CompilerIrValue.Var 3)
              (CompilerIrValue.I64 offset)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                6
                (CompilerIrBinOp.Mul)
                (CompilerIrValue.Var 4)
                (CompilerIrValue.I64 scale)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  7
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 6)
                  (CompilerIrValue.I64 7)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    5
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 3)
                    (CompilerIrValue.I64 step)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                    (CompilerIrInstrList.Nil)))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-induction-offset-index-gep-blocks
  [step : i64]
  [op : CompilerIrBinOp]
  [offset : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            3
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 1)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              op
              (CompilerIrValue.Var 3)
              (CompilerIrValue.I64 offset)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                6
                (CompilerIrValue.Var 2)
                (CompilerIrValue.Var 4)
                (AstType.U8))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 7 (CompilerIrValue.Var 6) (AstType.U8))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    5
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 3)
                    (CompilerIrValue.I64 step)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                    (CompilerIrInstrList.Nil)))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-induction-multi-offset-blocks [duplicate : bool]) : CompilerIrBlockList
  (let
    [second-scale : i64
      (if duplicate
        4
        8)]
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "loop")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              3
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 1)
                (compiler-ir-label "entry")
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 5)
                  (compiler-ir-label "body")
                  (CompilerIrPhiInputList.Nil)))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Var 0)
                (compiler-ir-label "body")
                (compiler-ir-label "exit"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "body")
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                4
                (CompilerIrBinOp.Mul)
                (CompilerIrValue.Var 3)
                (CompilerIrValue.I64 4)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  6
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 4)
                  (CompilerIrValue.I64 7)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    7
                    (CompilerIrBinOp.Mul)
                    (CompilerIrValue.Var 3)
                    (CompilerIrValue.I64 second-scale)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.BinOp
                      8
                      (CompilerIrBinOp.Add)
                      (CompilerIrValue.Var 7)
                      (CompilerIrValue.I64 11)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.BinOp
                        5
                        (CompilerIrBinOp.Add)
                        (CompilerIrValue.Var 3)
                        (CompilerIrValue.I64 1)
                        (AstType.I64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                        (CompilerIrInstrList.Nil))))))))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "exit")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                (CompilerIrInstrList.Nil)))
            (CompilerIrBlockList.Nil)))))))

(define (opt-induction-multi-gep-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            3
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 1)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              4
              (CompilerIrValue.Var 2)
              (CompilerIrValue.Var 3)
              (AstType.U8))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 6 (CompilerIrValue.Var 4) (AstType.U8))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Gep
                  7
                  (CompilerIrValue.Global (opt-test-symbol "other_base"))
                  (CompilerIrValue.Var 3)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.BinOp
                      5
                      (CompilerIrBinOp.Add)
                      (CompilerIrValue.Var 3)
                      (CompilerIrValue.I64 1)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                      (CompilerIrInstrList.Nil))))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-induction-unsupported-step-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            3
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 1)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Mul)
              (CompilerIrValue.Var 3)
              (CompilerIrValue.I64 4)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                6
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 4)
                (CompilerIrValue.I64 7)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  5
                  (CompilerIrBinOp.Mul)
                  (CompilerIrValue.Var 3)
                  (CompilerIrValue.I64 2)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                  (CompilerIrInstrList.Nil))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-induction-call-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            3
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 1)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Mul)
              (CompilerIrValue.Var 3)
              (CompilerIrValue.I64 4)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Call
                7
                (opt-test-symbol "tl_noop")
                (CompilerIrCallArgs.Nil)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  6
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 4)
                  (CompilerIrValue.I64 7)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    5
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 3)
                    (CompilerIrValue.I64 1)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                    (CompilerIrInstrList.Nil)))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

;; A loop whose latch recurrence reaches the phi through a copy (`%7 = mov %5`)
;; with a `gep data, (mul i, 16)` fetch: the copy chain is chased to find the
;; fact, and the non-folding 16-byte stride gets a scaled address IV.
(define (opt-induction-mov-latch-scaled-gep-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            3
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 1)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 7)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Mul)
              (CompilerIrValue.Var 3)
              (CompilerIrValue.I64 16)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                6
                (CompilerIrValue.Var 2)
                (CompilerIrValue.Var 4)
                (AstType.U8))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 8 (CompilerIrValue.Var 6) (AstType.U8))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    5
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 3)
                    (CompilerIrValue.I64 1)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Mov
                      7
                      (CompilerIrValue.Var 5)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                      (CompilerIrInstrList.Nil))))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-induction-store-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            3
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 1)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Mul)
              (CompilerIrValue.Var 3)
              (CompilerIrValue.I64 4)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Store
                (opt-test-symbol "sink")
                (CompilerIrValue.Var 4)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  5
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 3)
                  (CompilerIrValue.I64 1)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                  (CompilerIrInstrList.Nil))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-induction-loop-local-base-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            3
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 1)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 7 (CompilerIrValue.I64 100) (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                4
                (CompilerIrValue.Var 7)
                (CompilerIrValue.Var 3)
                (AstType.U8))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 6 (CompilerIrValue.Var 4) (AstType.U8))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    5
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 3)
                    (CompilerIrValue.I64 1)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                    (CompilerIrInstrList.Nil)))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-induction-no-preheader-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Branch
          (CompilerIrValue.Var 0)
          (compiler-ir-label "pre-one")
          (compiler-ir-label "pre-two"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "pre-one")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "pre-two")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "loop")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Phi
                3
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 1)
                  (compiler-ir-label "pre-one")
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.Var 1)
                    (compiler-ir-label "pre-two")
                    (compiler-ir-phi-input-cons
                      (CompilerIrValue.Var 5)
                      (compiler-ir-label "body")
                      (CompilerIrPhiInputList.Nil))))
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 0)
                  (compiler-ir-label "body")
                  (compiler-ir-label "exit"))
                (CompilerIrInstrList.Nil))))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "body")
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  4
                  (CompilerIrBinOp.Mul)
                  (CompilerIrValue.Var 3)
                  (CompilerIrValue.I64 4)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    6
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 4)
                    (CompilerIrValue.I64 7)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.BinOp
                      5
                      (CompilerIrBinOp.Add)
                      (CompilerIrValue.Var 3)
                      (CompilerIrValue.I64 1)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                      (CompilerIrInstrList.Nil))))))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                  (CompilerIrInstrList.Nil)))
              (CompilerIrBlockList.Nil))))))))

(define (compiler-optimize-induction-self-test) : i64
  (let
    [blocks : CompilerIrBlockList (opt-induction-offset-blocks 1 4)]
    [func : CompilerIrFunction (opt-induction-optimized-function blocks)]
    [out : CompilerIrBlockList (opt-function-blocks func)]
    [nonunit-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-offset-blocks 3 4))]
    [nonunit : CompilerIrBlockList (opt-function-blocks nonunit-func)]
    [negative-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-offset-blocks (- 0 2) 4))]
    [negative : CompilerIrBlockList (opt-function-blocks negative-func)]
    [gep-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-gep-blocks 1))]
    [gep : CompilerIrBlockList (opt-function-blocks gep-func)]
    [unsupported-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-unsupported-step-blocks))]
    [unsupported : CompilerIrBlockList (opt-function-blocks unsupported-func)]
    [call-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-call-blocks))]
    [call-blocks : CompilerIrBlockList (opt-function-blocks call-func)]
    [store-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-store-blocks))]
    [store-blocks : CompilerIrBlockList (opt-function-blocks store-func)]
    [local-base-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-loop-local-base-blocks))]
    [local-base : CompilerIrBlockList (opt-function-blocks local-base-func)]
    [no-preheader-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-no-preheader-blocks))]
    [no-preheader : CompilerIrBlockList (opt-function-blocks no-preheader-func)]
    [multi-offset-func : CompilerIrFunction
      (opt-induction-optimized-function
        (opt-induction-multi-offset-blocks false))]
    [multi-offset : CompilerIrBlockList (opt-function-blocks multi-offset-func)]
    [duplicate-offset-func : CompilerIrFunction
      (opt-induction-optimized-function
        (opt-induction-multi-offset-blocks true))]
    [duplicate-offset : CompilerIrBlockList
      (opt-function-blocks duplicate-offset-func)]
    [multi-gep-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-multi-gep-blocks))]
    [multi-gep : CompilerIrBlockList (opt-function-blocks multi-gep-func)]
    [offset-add-mul-func : CompilerIrFunction
      (opt-induction-optimized-function
        (opt-induction-offset-index-mul-blocks 2 (CompilerIrBinOp.Add) 3 4))]
    [offset-add-mul : CompilerIrBlockList
      (opt-function-blocks offset-add-mul-func)]
    [offset-sub-mul-func : CompilerIrFunction
      (opt-induction-optimized-function
        (opt-induction-offset-index-mul-blocks 2 (CompilerIrBinOp.Sub) 1 4))]
    [offset-sub-mul : CompilerIrBlockList
      (opt-function-blocks offset-sub-mul-func)]
    [offset-gep-func : CompilerIrFunction
      (opt-induction-optimized-function
        (opt-induction-offset-index-gep-blocks 2 (CompilerIrBinOp.Add) 2))]
    [offset-gep : CompilerIrBlockList (opt-function-blocks offset-gep-func)]
    [unsupported-offset-func : CompilerIrFunction
      (opt-induction-optimized-function
        (opt-induction-offset-index-mul-blocks
          2
          (CompilerIrBinOp.Add)
          1000001
          4))]
    [unsupported-offset : CompilerIrBlockList
      (opt-function-blocks unsupported-offset-func)]
    [mov-scaled-func : CompilerIrFunction
      (opt-induction-optimized-function
        (opt-induction-mov-latch-scaled-gep-blocks))]
    [mov-scaled : CompilerIrBlockList (opt-function-blocks mov-scaled-func)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function func))) 1]
      [(not (= (opt-count-phi-blocks out) 2)) 2]
      [(not (= (opt-blocks-mov-src-var out 4 (- 0 1)) 33)) 3]
      [(not (= (opt-count-mul-label-blocks out (compiler-ir-label "body")) 0))
        4]
      [(not (opt-verify-ok? (opt-verify-function nonunit-func))) 5]
      [(not (= (opt-blocks-mov-src-var nonunit 4 (- 0 1)) 33)) 6]
      [(not
          (= (opt-count-mul-label-blocks nonunit (compiler-ir-label "body")) 0))
        7]
      [(not (opt-verify-ok? (opt-verify-function negative-func))) 8]
      [(not (= (opt-blocks-mov-src-var negative 4 (- 0 1)) 33)) 9]
      [(not
          (= (opt-count-mul-label-blocks negative (compiler-ir-label "body")) 0))
        10]
      [(not (opt-verify-ok? (opt-verify-function gep-func))) 11]
      ;; A scale-1 gep folds into the x86 addressing mode, so an address IV
      ;; only costs a latch add: the affine Gep derived no longer fires.
      [(not (= (opt-count-gep-label-blocks gep (compiler-ir-label "body")) 1))
        12]
      [(not (= (opt-blocks-mov-src-var gep 4 (- 0 1)) (- 0 1))) 13]
      [(not (opt-verify-ok? (opt-verify-function unsupported-func))) 14]
      [(not (= (opt-blocks-mov-src-var unsupported 4 (- 0 1)) (- 0 1))) 15]
      [(not
          (=
            (opt-count-mul-label-blocks unsupported (compiler-ir-label "body"))
            2))
        16]
      [(not (opt-verify-ok? (opt-verify-function call-func))) 17]
      ;; A loop with a call keeps its plain recurrence: a derived phi would be
      ;; loop-live across the call and spill more than the mul costs.
      [(not (= (opt-blocks-mov-src-var call-blocks 4 (- 0 1)) (- 0 1))) 18]
      [(not
          (=
            (opt-count-mul-label-blocks call-blocks (compiler-ir-label "body"))
            1))
        19]
      [(not (= (opt-count-direct-call-name-blocks call-blocks "tl_noop") 1)) 20]
      [(not (opt-verify-ok? (opt-verify-function store-func))) 21]
      [(not (= (opt-blocks-mov-src-var store-blocks 4 (- 0 1)) 33)) 22]
      [(not
          (=
            (opt-count-mul-label-blocks store-blocks (compiler-ir-label "body"))
            0))
        23]
      [(not (opt-verify-ok? (opt-verify-function local-base-func))) 24]
      [(not (= (opt-blocks-mov-src-var local-base 4 (- 0 1)) (- 0 1))) 25]
      [(not
          (=
            (opt-count-gep-label-blocks local-base (compiler-ir-label "body"))
            1))
        26]
      [(not (opt-verify-ok? (opt-verify-function no-preheader-func))) 27]
      [(not (= (opt-count-phi-blocks no-preheader) 1)) 28]
      [(not
          (=
            (opt-count-mul-label-blocks no-preheader (compiler-ir-label "body"))
            1))
        29]
      [(not (opt-verify-ok? (opt-verify-function multi-offset-func))) 30]
      [(not (= (opt-function-frame multi-offset-func) 38)) 31]
      [(not (= (opt-count-phi-blocks multi-offset) 3)) 32]
      [(not (= (opt-blocks-mov-src-var multi-offset 4 (- 0 1)) 33)) 33]
      [(not (= (opt-blocks-mov-src-var multi-offset 7 (- 0 1)) 36)) 34]
      [(not
          (=
            (opt-count-mul-label-blocks multi-offset (compiler-ir-label "body"))
            0))
        35]
      [(not (opt-verify-ok? (opt-verify-function duplicate-offset-func))) 36]
      [(not (= (opt-function-frame duplicate-offset-func) 35)) 37]
      [(not (= (opt-count-phi-blocks duplicate-offset) 2)) 38]
      [(not (= (opt-blocks-mov-src-var duplicate-offset 4 (- 0 1)) 33)) 39]
      [(not (= (opt-blocks-mov-src-var duplicate-offset 7 (- 0 1)) 33)) 40]
      [(not
          (=
            (opt-count-mul-label-blocks
              duplicate-offset
              (compiler-ir-label "body"))
            0))
        41]
      [(not (opt-verify-ok? (opt-verify-function multi-gep-func))) 42]
      ;; Both geps fold (u8 and i64 elements), so no address IVs fire.
      [(not (= (opt-function-frame multi-gep-func) 32)) 43]
      [(not (= (opt-count-phi-blocks multi-gep) 1)) 44]
      [(not (= (opt-blocks-mov-src-var multi-gep 4 (- 0 1)) (- 0 1))) 45]
      [(not (= (opt-blocks-mov-src-var multi-gep 7 (- 0 1)) (- 0 1))) 46]
      [(not
          (=
            (opt-count-gep-label-blocks multi-gep (compiler-ir-label "body"))
            2))
        47]
      [(not (opt-verify-ok? (opt-verify-function offset-add-mul-func))) 48]
      [(not (= (opt-function-frame offset-add-mul-func) 36)) 49]
      [(not (= (opt-count-phi-blocks offset-add-mul) 2)) 50]
      [(not (= (opt-blocks-mov-src-var offset-add-mul 6 (- 0 1)) 34)) 51]
      [(not
          (=
            (opt-count-mul-label-blocks
              offset-add-mul
              (compiler-ir-label "body"))
            0))
        52]
      [(not (opt-verify-ok? (opt-verify-function offset-sub-mul-func))) 53]
      [(not (= (opt-function-frame offset-sub-mul-func) 36)) 54]
      [(not (= (opt-count-phi-blocks offset-sub-mul) 2)) 55]
      [(not (= (opt-blocks-mov-src-var offset-sub-mul 6 (- 0 1)) 34)) 56]
      [(not
          (=
            (opt-count-mul-label-blocks
              offset-sub-mul
              (compiler-ir-label "body"))
            0))
        57]
      [(not (opt-verify-ok? (opt-verify-function offset-gep-func))) 58]
      ;; The affine u8 gep folds, so no address IV fires.
      [(not (= (opt-function-frame offset-gep-func) 32)) 59]
      [(not (= (opt-count-phi-blocks offset-gep) 1)) 60]
      [(not (= (opt-blocks-mov-src-var offset-gep 6 (- 0 1)) (- 0 1))) 61]
      [(not
          (=
            (opt-count-gep-label-blocks offset-gep (compiler-ir-label "body"))
            1))
        62]
      [(not (opt-verify-ok? (opt-verify-function unsupported-offset-func))) 63]
      [(not (= (opt-function-frame unsupported-offset-func) 32)) 64]
      [(not (= (opt-blocks-mov-src-var unsupported-offset 6 (- 0 1)) (- 0 1)))
        65]
      [(not
          (=
            (opt-count-mul-label-blocks
              unsupported-offset
              (compiler-ir-label "body"))
            1))
        66]
      [(not (opt-verify-ok? (opt-verify-function mov-scaled-func))) 67]
      [(not (= (opt-function-frame mov-scaled-func) 36)) 68]
      [(not (= (opt-count-phi-blocks mov-scaled) 2)) 69]
      ;; The copy-chased fact plus the 16-byte stride produce a scaled
      ;; address IV at var 34; the fetch gep rewrites to a copy of it.
      [(not (= (opt-blocks-mov-src-var mov-scaled 6 (- 0 1)) 34)) 70]
      [(not
          (=
            (opt-count-mul-label-blocks mov-scaled (compiler-ir-label "body"))
            1))
        71]
      [(not
          (=
            (opt-count-gep-label-blocks mov-scaled (compiler-ir-label "body"))
            1))
        72]
      [else 42])))

(define (opt-unroll-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "n" (AstType.I64) 0)
    (CompilerIrParamList.Nil)))

;; entry -> body (self-loop: i/acc phis, acc += i, i += step, i' < n) -> exit.
;; step 1 is the canonical counted shape; any other step must be rejected.
(define (opt-unroll-test-blocks [step : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "body"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "body")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            2
            (compiler-ir-phi-input-cons
              (CompilerIrValue.I64 0)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              3
              (compiler-ir-phi-input-cons
                (CompilerIrValue.I64 0)
                (compiler-ir-label "entry")
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 4)
                  (compiler-ir-label "body")
                  (CompilerIrPhiInputList.Nil)))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                4
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 3)
                (CompilerIrValue.Var 2)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  5
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 2)
                  (CompilerIrValue.I64 step)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    6
                    (CompilerIrBinOp.Lt)
                    (CompilerIrValue.Var 5)
                    (CompilerIrValue.Var 0)
                    (AstType.Bool))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Branch
                      (CompilerIrValue.Var 6)
                      (compiler-ir-label "body")
                      (compiler-ir-label "exit"))
                    (CompilerIrInstrList.Nil))))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "exit")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
            (CompilerIrInstrList.Nil)))
        (CompilerIrBlockList.Nil)))))

(define (opt-unroll-vector-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "n" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "base" (AstType.I64) 1)
      (CompilerIrParamList.Nil))))

;; A canonical counted reduction whose store-free body covers every SIMD form
;; admitted by the straight-line unroller. Dependencies deliberately chain
;; through the vector forms so clone remapping must be correct.
(define (opt-unroll-vector-test-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "body"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "body")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            2
            (compiler-ir-phi-input-cons
              (CompilerIrValue.I64 0)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 13)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              3
              (compiler-ir-phi-input-cons
                (CompilerIrValue.I64 0)
                (compiler-ir-label "entry")
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 12)
                  (compiler-ir-label "body")
                  (CompilerIrPhiInputList.Nil)))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.LaneId 4 4 (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Splat
                  5
                  (CompilerIrValue.Var 2)
                  4
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.VectorLoad
                    6
                    (CompilerIrValue.Var 1)
                    (CompilerIrValue.Var 2)
                    4
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (ir-instr-vector-bin-op
                      7
                      (CompilerIrBinOp.Add)
                      (CompilerIrValue.Var 6)
                      (CompilerIrValue.Var 4)
                      4
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (ir-instr-vector-compare
                        8
                        (CompilerIrBinOp.Lt)
                        (CompilerIrValue.Var 7)
                        (CompilerIrValue.Var 5)
                        4
                        (AstType.I64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.MaskBinOp
                          9
                          (CompilerIrMaskBinOp.And)
                          (CompilerIrValue.Var 8)
                          (CompilerIrValue.Var 8)
                          4)
                        (compiler-ir-instr-cons
                          (ir-instr-select
                            10
                            (CompilerIrValue.Var 9)
                            (CompilerIrValue.Var 7)
                            (CompilerIrValue.Var 6)
                            4
                            (AstType.I64))
                          (compiler-ir-instr-cons
                            (CompilerIrInstr.VectorReduce
                              11
                              (CompilerIrVectorReduceOp.Sum)
                              (CompilerIrValue.Var 10)
                              4
                              (AstType.I64))
                            (compiler-ir-instr-cons
                              (CompilerIrInstr.BinOp
                                12
                                (CompilerIrBinOp.Add)
                                (CompilerIrValue.Var 3)
                                (CompilerIrValue.Var 11)
                                (AstType.I64))
                              (compiler-ir-instr-cons
                                (CompilerIrInstr.BinOp
                                  13
                                  (CompilerIrBinOp.Add)
                                  (CompilerIrValue.Var 2)
                                  (CompilerIrValue.I64 1)
                                  (AstType.I64))
                                (compiler-ir-instr-cons
                                  (CompilerIrInstr.BinOp
                                    14
                                    (CompilerIrBinOp.Lt)
                                    (CompilerIrValue.Var 13)
                                    (CompilerIrValue.Var 0)
                                    (AstType.Bool))
                                  (compiler-ir-instr-cons
                                    (CompilerIrInstr.Branch
                                      (CompilerIrValue.Var 14)
                                      (compiler-ir-label "body")
                                      (compiler-ir-label "exit"))
                                    (CompilerIrInstrList.Nil))))))))))))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "exit")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
            (CompilerIrInstrList.Nil)))
        (CompilerIrBlockList.Nil)))))

;; The SPMD lowerer keeps vectors mutable instead of placing them in SSA phis.
;; After loop rotation its gang loop is one self-loop block with the next
;; vector index already computed on entry, then a `mov/add/le` latch.
(define (opt-unroll-mutable-vector-test-blocks [loop-local-base? : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Splat 3 (CompilerIrValue.I64 0) 4 (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 2)
              (CompilerIrValue.I64 4)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                5
                (CompilerIrBinOp.Le)
                (CompilerIrValue.Var 4)
                (CompilerIrValue.Var 0)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 5)
                  (compiler-ir-label "body")
                  (compiler-ir-label "exit"))
                (CompilerIrInstrList.Nil)))))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "body")
        (compiler-ir-instr-cons
          ;; A body-local base is valid mutable IR, but cannot be hoisted into
          ;; the unrolled block's leading shared Gep.
          (CompilerIrInstr.Mov 9 (CompilerIrValue.Var 1) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.VectorLoad
              6
              (if loop-local-base?
                (CompilerIrValue.Var 9)
                (CompilerIrValue.Var 1))
              (CompilerIrValue.Var 2)
              4
              (AstType.I64))
            (compiler-ir-instr-cons
              (ir-instr-vector-bin-op
                7
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 6)
                (CompilerIrValue.Var 3)
                4
                (AstType.I64))
              (compiler-ir-instr-cons
                (ir-instr-vector-bin-op
                  3
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 3)
                  (CompilerIrValue.Var 7)
                  4
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Mov 2 (CompilerIrValue.Var 4) (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.BinOp
                      4
                      (CompilerIrBinOp.Add)
                      (CompilerIrValue.Var 2)
                      (CompilerIrValue.I64 4)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.BinOp
                        5
                        (CompilerIrBinOp.Le)
                        (CompilerIrValue.Var 4)
                        (CompilerIrValue.Var 0)
                        (AstType.I64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Branch
                          (CompilerIrValue.Var 5)
                          (compiler-ir-label "body")
                          (compiler-ir-label "exit"))
                        (CompilerIrInstrList.Nil))))))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "exit")
          (compiler-ir-instr-cons
            (CompilerIrInstr.VectorReduce
              8
              (CompilerIrVectorReduceOp.Sum)
              (CompilerIrValue.Var 3)
              4
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 8)))
              (CompilerIrInstrList.Nil))))
        (CompilerIrBlockList.Nil)))))

(define (opt-unroll-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "unroll_fixture")
    (opt-unroll-test-params)
    (AstType.I64)
    7
    blocks))

(define (opt-unroll-vector-test-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "unroll_vector_fixture")
    (opt-unroll-vector-test-params)
    (AstType.I64)
    15
    (opt-unroll-vector-test-blocks)))

(define (opt-unroll-mutable-vector-test-function [loop-local-base? : bool]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "unroll_mutable_vector_fixture")
    (opt-unroll-vector-test-params)
    (AstType.I64)
    10
    (opt-unroll-mutable-vector-test-blocks loop-local-base?)))

(define (opt-unroll-test-count-add-instr-seq
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [acc : i64]) : i64
  (if (>= index (compiler-ir-instr-seq-count instrs))
    acc
    (opt-unroll-test-count-add-instr-seq
      instrs
      (+ index 1)
      (+
        acc
        (match (compiler-ir-instr-seq-ref instrs index)
          [(CompilerIrInstr.BinOp _ op _ _ _)
            (match op
              [(CompilerIrBinOp.Add) 1]
              [_ 0])]
          [_ 0])))))

(define (opt-unroll-test-count-vector-instr-seq
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [acc : i64]) : i64
  (if (>= index (compiler-ir-instr-seq-count instrs))
    acc
    (opt-unroll-test-count-vector-instr-seq
      instrs
      (+ index 1)
      (+
        acc
        (match (compiler-ir-instr-seq-ref instrs index)
          [(CompilerIrInstr.LaneId _ _ _) 1]
          [(CompilerIrInstr.Splat _ _ _ _) 1]
          [(CompilerIrInstr.VectorBinOp _) 1]
          [(CompilerIrInstr.VectorReduce _ _ _ _ _) 1]
          [(CompilerIrInstr.VectorCompare _) 1]
          [(CompilerIrInstr.MaskBinOp _ _ _ _ _) 1]
          [(CompilerIrInstr.Select _) 1]
          [(CompilerIrInstr.VectorLoad _ _ _ _ _) 1]
          [_ 0])))))

(define (opt-unroll-test-count-vector-in-block
  [blocks : CompilerIrBlockList]
  [label : i64]) : i64
  (match (opt-cfg-find-block blocks label)
    [(OptMaybeBlock.No) (- 0 1)]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (opt-unroll-test-count-vector-instr-seq instrs 0 0)])]))

(define (opt-unroll-test-count-add-in-block
  [blocks : CompilerIrBlockList]
  [label : i64]) : i64
  (match (opt-cfg-find-block blocks label)
    [(OptMaybeBlock.No) (- 0 1)]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (opt-unroll-test-count-add-instr-seq instrs 0 0)])]))

(define (compiler-optimize-unroll-self-test) : i64
  (let
    [func : CompilerIrFunction
      (opt-unroll-function
        (opt-unroll-test-function (opt-unroll-test-blocks 1)))]
    [out : CompilerIrBlockList (opt-function-blocks func)]
    [nonunit-func : CompilerIrFunction
      (opt-unroll-function
        (opt-unroll-test-function (opt-unroll-test-blocks 2)))]
    [nonunit : CompilerIrBlockList (opt-function-blocks nonunit-func)]
    [vector-func : CompilerIrFunction
      (opt-unroll-function (opt-unroll-vector-test-function))]
    [vector-out : CompilerIrBlockList (opt-function-blocks vector-func)]
    [mutable-vector-func : CompilerIrFunction
      (opt-unroll-function (opt-unroll-mutable-vector-test-function false))]
    [mutable-vector-out : CompilerIrBlockList
      (opt-function-blocks mutable-vector-func)]
    [local-base-func : CompilerIrFunction
      (opt-unroll-function (opt-unroll-mutable-vector-test-function true))]
    [local-base-out : CompilerIrBlockList (opt-function-blocks local-base-func)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function func))) 1]
      ;; entry, guard, unrolled body, remainder loop, exit.
      [(not (= (compiler-ir-block-list-count out) 5)) 2]
      ;; sixteen acc adds + sixteen counter adds.
      [(<
          (opt-unroll-test-count-add-in-block
            out
            (compiler-ir-label "body__unroll_body"))
          32)
        3]
      ;; a non-unit counter step is not canonical: blocks stay untouched.
      [(not (= (compiler-ir-block-list-count nonunit) 3)) 4]
      ;; Bounds-check labels must remain unique at the sixteen-copy factor.
      [(not (string.eq (opt-unroll-copy-suffix 15) "__u15")) 5]
      [(string.eq (opt-unroll-copy-suffix 3) (opt-unroll-copy-suffix 15)) 6]
      [(not (opt-verify-ok? (opt-verify-function vector-func))) 7]
      [(not (= (compiler-ir-block-list-count vector-out) 5)) 8]
      ;; Eight admitted SIMD instructions across all sixteen body copies.
      [(not
          (=
            (opt-unroll-test-count-vector-in-block
              vector-out
              (compiler-ir-label "body__unroll_body"))
            128))
        9]
      ;; Store-bearing SIMD loops remain outside this unroller.
      [(opt-unroll-body-instr-ok?
          (ir-instr-vector-store
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 2)
            (CompilerIrValue.Var 10)
            4
            (AstType.I64)))
        10]
      [(not (opt-verify-ok? (opt-verify-final-function mutable-vector-func)))
        11]
      [(not (= (compiler-ir-block-list-count mutable-vector-out) 6)) 12]
      ;; Three vector instructions across all sixteen mutable body copies.
      [(not
          (=
            (opt-unroll-test-count-vector-in-block
              mutable-vector-out
              (compiler-ir-label "body__unroll_body"))
            48))
        13]
      ;; A base defined inside the loop cannot feed the shared pre-body Gep.
      [(not (opt-verify-ok? (opt-verify-final-function local-base-func))) 14]
      [(not (= (compiler-ir-block-list-count local-base-out) 3)) 15]
      [else 42])))

;; --- bounds-check loop versioning self-test ------------------------------------
(define (opt-bce-version-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "n" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "len" (AstType.I64) 1)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "base" (AstType.I64) 2)
        (CompilerIrParamList.Nil)))))

;; entry -> loop (i phi, acc phi, bounds check on i, acc += i, i += 1) -> exit
;; (acc merged through an exit phi). `derivable` false swaps the check's index
;; for the ADD result, which is neither counter, invariant, nor mask.
(define (opt-bce-version-test-blocks [derivable : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            3
            (compiler-ir-phi-input-cons
              (CompilerIrValue.I64 0)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 6)
                (compiler-ir-label "loop")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              4
              (compiler-ir-phi-input-cons
                (CompilerIrValue.I64 0)
                (compiler-ir-label "entry")
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 5)
                  (compiler-ir-label "loop")
                  (CompilerIrPhiInputList.Nil)))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                5
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 4)
                (CompilerIrValue.Var 3)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BoundsCheck
                  (if derivable
                    (CompilerIrValue.Var 3)
                    (CompilerIrValue.Var 5))
                  (CompilerIrValue.Var 1)
                  (compiler-ir-label "bce_version_ok"))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    6
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 3)
                    (CompilerIrValue.I64 1)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.BinOp
                      7
                      (CompilerIrBinOp.Lt)
                      (CompilerIrValue.Var 6)
                      (CompilerIrValue.Var 0)
                      (AstType.Bool))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Branch
                        (CompilerIrValue.Var 7)
                        (compiler-ir-label "loop")
                        (compiler-ir-label "done"))
                      (CompilerIrInstrList.Nil)))))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "done")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              8
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "loop")
                (CompilerIrPhiInputList.Nil))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 8)))
              (CompilerIrInstrList.Nil))))
        (CompilerIrBlockList.Nil)))))

(define (opt-bce-version-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "bce_version_fixture")
    (opt-bce-version-test-params)
    (AstType.I64)
    9
    blocks))

(define (opt-bce-version-test-block-checks
  [blocks : CompilerIrBlockList]
  [label-want : i64]) : i64
  (match (opt-cfg-find-block blocks label-want)
    [(OptMaybeBlock.No) (- 0 1)]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (opt-bce-version-check-count
            instrs
            0
            (compiler-ir-instr-seq-count instrs)
            0)])]))

(define (opt-bce-version-test-exit-phi-inputs
  [blocks : CompilerIrBlockList]
  [label-want : i64]) : i64
  (match (opt-cfg-find-block blocks label-want)
    [(OptMaybeBlock.No) (- 0 1)]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (match (compiler-ir-instr-seq-ref instrs 0)
            [(CompilerIrInstr.Phi _ inputs _) (opt-phi-input-count inputs)]
            [_ (- 0 1)])])]))

(define (compiler-optimize-bce-version-self-test) : i64
  (let
    [versioned : CompilerIrFunction
      (opt-bce-version-function
        (opt-bce-version-test-function (opt-bce-version-test-blocks true)))]
    [out : CompilerIrBlockList (opt-function-blocks versioned)]
    [unchanged : CompilerIrFunction
      (opt-bce-version-function
        (opt-bce-version-test-function (opt-bce-version-test-blocks false)))]
    [unchanged-out : CompilerIrBlockList (opt-function-blocks unchanged)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function versioned))) 1]
      ;; entry, guard, fast, slow loop, exit.
      [(not (= (compiler-ir-block-list-count out) 5)) 2]
      ;; the fast clone dropped its check; the slow loop keeps it.
      [(not
          (=
            (opt-bce-version-test-block-checks
              out
              (compiler-ir-label "loop__bce_fast"))
            0))
        3]
      [(not
          (=
            (opt-bce-version-test-block-checks out (compiler-ir-label "loop"))
            1))
        4]
      ;; the exit phi gained the parallel fast-edge input.
      [(not
          (=
            (opt-bce-version-test-exit-phi-inputs
              out
              (compiler-ir-label "done"))
            2))
        5]
      ;; a non-derivable index rejects: blocks stay untouched.
      [(not (= (compiler-ir-block-list-count unchanged-out) 3)) 6]
      [else 42])))

;; Full-pipeline integration: a lowered while loop with a checked array read
;; must version (rotation in iteration 1, versioning + unrolling of the fast
;; clone in iteration 2), leaving every fast-derived block check-free.
(define (opt-bce-version-while-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 4 (CompilerIrValue.I64 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "header"))
            (CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "header")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            5
            (CompilerIrBinOp.Lt)
            (CompilerIrValue.Var 4)
            (CompilerIrValue.Var 0)
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 5)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BoundsCheck
              (CompilerIrValue.Var 4)
              (CompilerIrValue.Var 1)
              (compiler-ir-label "bce_while_ok"))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                6
                (CompilerIrValue.Var 2)
                (CompilerIrValue.Var 4)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 7 (CompilerIrValue.Var 6) (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    8
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 3)
                    (CompilerIrValue.Var 7)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Mov
                      3
                      (CompilerIrValue.Var 8)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.BinOp
                        9
                        (CompilerIrBinOp.Add)
                        (CompilerIrValue.Var 4)
                        (CompilerIrValue.I64 1)
                        (AstType.I64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Mov
                          4
                          (CompilerIrValue.Var 9)
                          (AstType.I64))
                        (compiler-ir-instr-cons
                          (CompilerIrInstr.Jump (compiler-ir-label "header"))
                          (CompilerIrInstrList.Nil))))))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil)))
          (CompilerIrBlockList.Nil))))))

(define (opt-bce-version-test-prefix-from?
  [label : String]
  [prefix : String]
  [index : i64]) : bool
  (if (>= index (string.string-length prefix))
    true
    (if (=
      (cast (string.string-ref label index) : i64)
      (cast (string.string-ref prefix index) : i64))
      (opt-bce-version-test-prefix-from? label prefix (+ index 1))
      false)))

(define (opt-bce-version-test-has-prefix? [label : i64] [prefix : String]) : bool
  (let
    [text : String (compiler-ir-label-text label)]
    (and
      (>= (string.string-length text) (string.string-length prefix))
      (opt-bce-version-test-prefix-from? text prefix 0))))

(define (opt-bce-version-test-prefix-checks
  [blocks : CompilerIrBlockList]
  [prefix : String]
  [acc : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) acc]
    [(CompilerIrBlockList.Cons block rest)
      (opt-bce-version-test-prefix-checks
        (box-get rest)
        prefix
        (match block
          [(CompilerIrBlock.Block label instrs)
            (if (opt-bce-version-test-has-prefix? label prefix)
              (+
                acc
                (opt-bce-version-check-count
                  instrs
                  0
                  (compiler-ir-instr-seq-count instrs)
                  0))
              acc)]))]
    [(CompilerIrBlockList.Array seq)
      (opt-bce-version-test-prefix-checks
        (compiler-ir-block-seq-to-list seq)
        prefix
        acc)]))

(define (compiler-optimize-bce-version-pipeline-self-test) : i64
  (let
    [optimized : CompilerIrFunction
      (optimize-function
        (CompilerIrFunction.Function
          (opt-test-symbol "bce_version_while_fixture")
          (opt-bce-version-test-params)
          (AstType.I64)
          10
          (opt-bce-version-while-blocks)))]
    [blocks : CompilerIrBlockList (opt-function-blocks optimized)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function optimized))) 1]
      ;; the fast clone exists ...
      [(match (opt-cfg-find-block blocks (compiler-ir-label "body__bce_fast"))
          [(OptMaybeBlock.No) true]
          [(OptMaybeBlock.Some _) false])
        2]
      ;; ... every fast-derived block (clone + its unroll copies) is
      ;; check-free ...
      [(not
          (= (opt-bce-version-test-prefix-checks blocks "body__bce_fast" 0) 0))
        3]
      ;; ... and the slow original keeps its per-iteration check.
      [(<
          (opt-bce-version-test-block-checks blocks (compiler-ir-label "body"))
          1)
        4]
      [else 42])))

;; --- multi-block bce-version self-tests -------------------------------------------
;;
;; The quicksort-partition shape: a counted scan loop (body) whose body splits
;; into a swap path (then: store++) and a skip path (else) before merging back
;; into the incrementing latch (merge). `variant` mutates one detail each: 1
;; makes the swap check's index underivable (store+1 used directly) -- which
;; PARTIALLY versions now (the counter check still derives, the swap check
;; stays in the fast clone) -- 2 puts a call in the swap block, 3 makes the
;; counter step +2 -- the latter two must leave the function untouched. Variant
;; 4 gives the header a total-switch terminator so cloning exercises every
;; switch edge, including the compiler trap default. Variant 5 uses the late
;; total-enum marker and must remain unversioned by the profitability gate.
;; Variants 6-9 cover late pairing; 10 lets the smaller affine value escape
;; through a phi so the paired rewrite must fail verification and roll back.
(define (opt-bce-mb-test-header-block [variant : i64]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Phi
        3
        (compiler-ir-phi-input-cons
          (CompilerIrValue.I64 0)
          (compiler-ir-label "entry")
          (compiler-ir-phi-input-cons
            (CompilerIrValue.Var 8)
            (compiler-ir-label "merge")
            (CompilerIrPhiInputList.Nil)))
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Phi
          4
          (compiler-ir-phi-input-cons
            (CompilerIrValue.I64 0)
            (compiler-ir-label "entry")
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 7)
              (compiler-ir-label "merge")
              (CompilerIrPhiInputList.Nil)))
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BoundsCheck
            (CompilerIrValue.Var 3)
            (CompilerIrValue.Var 1)
            (compiler-ir-label "mb_ok0"))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              5
              (CompilerIrBinOp.Lt)
              (CompilerIrValue.Var 3)
              (CompilerIrValue.I64 4)
              (AstType.Bool))
            (compiler-ir-instr-cons
              (if (or
                (= variant 4)
                (= variant 5)
                (= variant 6)
                (= variant 7)
                (= variant 8)
                (= variant 9)
                (= variant 10))
                (CompilerIrInstr.Switch
                  (CompilerIrValue.Var 5)
                  0
                  (compiler-ir-switch-case-cons
                    0
                    (compiler-ir-label "else")
                    (compiler-ir-switch-case-cons
                      1
                      (compiler-ir-label "then")
                      CompilerIrSwitchCaseList.Nil))
                  (if (or
                    (= variant 5)
                    (= variant 6)
                    (= variant 7)
                    (= variant 8)
                    (= variant 9)
                    (= variant 10))
                    (compiler-ir-label "match_total_enum_default")
                    (compiler-ir-label "match_total_trap")))
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 5)
                  (compiler-ir-label "then")
                  (compiler-ir-label "else")))
              (CompilerIrInstrList.Nil))))))))

(define (opt-bce-mb-test-then-block [variant : i64]) : CompilerIrBlock
  (if (or
    (= variant 6)
    (= variant 7)
    (= variant 8)
    (= variant 9)
    (= variant 10))
    ;; Adjacent affine checks on phi-1 / phi-2. Variant 6 is the positive
    ;; total-enum-dispatch case; 7 inserts a store between the checks and 8
    ;; gives the second check a different invariant length.
    (compiler-ir-block
      (compiler-ir-label "then")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          6
          (CompilerIrBinOp.Sub)
          (CompilerIrValue.Var 4)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BoundsCheck
            (CompilerIrValue.Var 6)
            (CompilerIrValue.Var 1)
            (compiler-ir-label "mb_pair_ok0"))
          (compiler-ir-instr-cons
            (if (= variant 7)
              (CompilerIrInstr.StorePtr
                (CompilerIrValue.Var 2)
                (CompilerIrValue.Var 6)
                (AstType.I64))
              (CompilerIrInstr.Mov 11 (CompilerIrValue.Var 6) (AstType.I64)))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                13
                (CompilerIrBinOp.Sub)
                (CompilerIrValue.Var 4)
                (CompilerIrValue.I64 2)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BoundsCheck
                  (CompilerIrValue.Var 13)
                  (if (= variant 8)
                    (CompilerIrValue.Var 2)
                    (CompilerIrValue.Var 1))
                  (compiler-ir-label "mb_pair_ok1"))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Jump (compiler-ir-label "merge"))
                  (CompilerIrInstrList.Nil))))))))
    (if (= variant 1)
      ;; The underivable-but-clean partial case: check store+1, defined before
      ;; the check. The counter check in "body" still derives, so the loop
      ;; partially versions and this check STAYS in the fast clone.
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            6
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 4)
            (CompilerIrValue.I64 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BoundsCheck
              (CompilerIrValue.Var 6)
              (CompilerIrValue.Var 1)
              (compiler-ir-label "mb_ok1"))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov 11 (CompilerIrValue.I64 0) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "merge"))
                (CompilerIrInstrList.Nil))))))
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BoundsCheck
            (CompilerIrValue.Var 4)
            (CompilerIrValue.Var 1)
            (compiler-ir-label "mb_ok1"))
          (compiler-ir-instr-cons
            (if (= variant 2)
              (CompilerIrInstr.Call
                11
                (opt-test-symbol "mb_callee")
                (CompilerIrCallArgs.Nil)
                (AstType.I64))
              (CompilerIrInstr.Mov 11 (CompilerIrValue.I64 0) (AstType.I64)))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                6
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 4)
                (CompilerIrValue.I64 1)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "merge"))
                (CompilerIrInstrList.Nil)))))))))

(define (opt-bce-mb-test-else-block) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "else")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Jump (compiler-ir-label "merge"))
      (CompilerIrInstrList.Nil))))

(define (opt-bce-mb-test-merge-block [variant : i64]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "merge")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Phi
        7
        (compiler-ir-phi-input-cons
          (CompilerIrValue.Var
            (if (= variant 10)
              13
              6))
          (compiler-ir-label "then")
          (compiler-ir-phi-input-cons
            (CompilerIrValue.Var 4)
            (compiler-ir-label "else")
            (CompilerIrPhiInputList.Nil)))
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          8
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 3)
          (CompilerIrValue.I64
            (if (= variant 3)
              2
              1))
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            9
            (CompilerIrBinOp.Lt)
            (CompilerIrValue.Var 8)
            (CompilerIrValue.Var 0)
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 9)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil)))))))

(define (opt-bce-mb-test-exit-block) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "exit")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Phi
        10
        (compiler-ir-phi-input-cons
          (CompilerIrValue.Var 7)
          (compiler-ir-label "merge")
          (CompilerIrPhiInputList.Nil))
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Return
          (CompilerIrMaybeValue.Some (CompilerIrValue.Var 10)))
        (CompilerIrInstrList.Nil)))))

(define (opt-bce-mb-test-total-trap-block [variant : i64]) : CompilerIrBlock
  (let
    ;; Every marked Switch default must name a real final-arm block. The shared
    ;; verifier now checks Switch successors before SSA dominance/use facts.
    [label : i64
      (if (or
        (= variant 5)
        (= variant 6)
        (= variant 7)
        (= variant 8)
        (= variant 9)
        (= variant 10))
        (compiler-ir-label "match_total_enum_default")
        (compiler-ir-label "match_total_trap"))]
    (compiler-ir-block
      label
      (compiler-ir-instr-cons
        (CompilerIrInstr.Call
          12
          cbi.compiler-builtin-id-tl-oob-abort
          (CompilerIrCallArgs.Nil)
          (AstType.Unit))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump label)
          CompilerIrInstrList.Nil)))))

(define (opt-bce-mb-test-blocks [variant : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (if (= variant 9)
          ;; A valid single-predecessor loop preheader whose final terminator
          ;; cannot be extended in place by the late pass: the no-fact case.
          (CompilerIrInstr.Switch
            (CompilerIrValue.I64 0)
            0
            CompilerIrSwitchCaseList.Nil
            (compiler-ir-label "body"))
          (CompilerIrInstr.Jump (compiler-ir-label "body")))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (opt-bce-mb-test-header-block variant)
      (compiler-ir-block-cons
        (opt-bce-mb-test-then-block variant)
        (compiler-ir-block-cons
          (opt-bce-mb-test-else-block)
          (compiler-ir-block-cons
            (opt-bce-mb-test-merge-block variant)
            (compiler-ir-block-cons
              (opt-bce-mb-test-exit-block)
              (if (or
                (= variant 4)
                (= variant 5)
                (= variant 6)
                (= variant 7)
                (= variant 8)
                (= variant 9)
                (= variant 10))
                (compiler-ir-block-cons
                  (opt-bce-mb-test-total-trap-block variant)
                  CompilerIrBlockList.Nil)
                CompilerIrBlockList.Nil))))))))

(define (opt-bce-mb-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "bce_version_mb_fixture")
    (opt-bce-version-test-params)
    (AstType.I64)
    14
    blocks))

(define (opt-bce-mb-test-jump-block [label : i64] [target : i64]) : CompilerIrBlock
  (compiler-ir-block
    label
    (compiler-ir-instr-cons
      (CompilerIrInstr.Jump target)
      (CompilerIrInstrList.Nil))))

;; Nine loop blocks -- one over the multi-block cap -- so even a fully
;; derivable counted loop must stay unversioned.
(define (opt-bce-mb-test-chain-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (opt-bce-mb-test-jump-block
      (compiler-ir-label "entry")
      (compiler-ir-label "body"))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "body")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            3
            (compiler-ir-phi-input-cons
              (CompilerIrValue.I64 0)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 8)
                (compiler-ir-label "latch")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BoundsCheck
              (CompilerIrValue.Var 3)
              (CompilerIrValue.Var 1)
              (compiler-ir-label "mb_chain_ok"))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "b1"))
              (CompilerIrInstrList.Nil)))))
      (compiler-ir-block-cons
        (opt-bce-mb-test-jump-block
          (compiler-ir-label "b1")
          (compiler-ir-label "b2"))
        (compiler-ir-block-cons
          (opt-bce-mb-test-jump-block
            (compiler-ir-label "b2")
            (compiler-ir-label "b3"))
          (compiler-ir-block-cons
            (opt-bce-mb-test-jump-block
              (compiler-ir-label "b3")
              (compiler-ir-label "b4"))
            (compiler-ir-block-cons
              (opt-bce-mb-test-jump-block
                (compiler-ir-label "b4")
                (compiler-ir-label "b5"))
              (compiler-ir-block-cons
                (opt-bce-mb-test-jump-block
                  (compiler-ir-label "b5")
                  (compiler-ir-label "b6"))
                (compiler-ir-block-cons
                  (opt-bce-mb-test-jump-block
                    (compiler-ir-label "b6")
                    (compiler-ir-label "b7"))
                  (compiler-ir-block-cons
                    (opt-bce-mb-test-jump-block
                      (compiler-ir-label "b7")
                      (compiler-ir-label "latch"))
                    (compiler-ir-block-cons
                      (compiler-ir-block
                        (compiler-ir-label "latch")
                        (compiler-ir-instr-cons
                          (CompilerIrInstr.BinOp
                            8
                            (CompilerIrBinOp.Add)
                            (CompilerIrValue.Var 3)
                            (CompilerIrValue.I64 1)
                            (AstType.I64))
                          (compiler-ir-instr-cons
                            (CompilerIrInstr.BinOp
                              9
                              (CompilerIrBinOp.Lt)
                              (CompilerIrValue.Var 8)
                              (CompilerIrValue.Var 0)
                              (AstType.Bool))
                            (compiler-ir-instr-cons
                              (CompilerIrInstr.Branch
                                (CompilerIrValue.Var 9)
                                (compiler-ir-label "body")
                                (compiler-ir-label "exit"))
                              (CompilerIrInstrList.Nil)))))
                      (compiler-ir-block-cons
                        (compiler-ir-block
                          (compiler-ir-label "exit")
                          (compiler-ir-instr-cons
                            (CompilerIrInstr.Return
                              (CompilerIrMaybeValue.Some
                                (CompilerIrValue.I64 0)))
                            (CompilerIrInstrList.Nil)))
                        (CompilerIrBlockList.Nil)))))))))))))

(define (compiler-optimize-bce-version-mb-self-test) : i64
  (let
    [versioned : CompilerIrFunction
      (opt-bce-version-function
        (opt-bce-mb-test-function (opt-bce-mb-test-blocks 0)))]
    [out : CompilerIrBlockList (opt-function-blocks versioned)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function versioned))) 1]
      ;; entry + guard + four fast clones + four slow blocks + exit
      [(not (= (compiler-ir-block-list-count out) 11)) 2]
      ;; the fast region dropped every check ...
      [(not
          (=
            (opt-bce-version-test-block-checks
              out
              (compiler-ir-label "body__bce_fast"))
            0))
        3]
      [(not
          (=
            (opt-bce-version-test-block-checks
              out
              (compiler-ir-label "then__bce_fast"))
            0))
        4]
      [(match (opt-cfg-find-block out (compiler-ir-label "merge__bce_fast"))
          [(OptMaybeBlock.No) true]
          [(OptMaybeBlock.Some _) false])
        5]
      [(match (opt-cfg-find-block out (compiler-ir-label "body__bce_guard"))
          [(OptMaybeBlock.No) true]
          [(OptMaybeBlock.Some _) false])
        6]
      ;; ... while the slow loop keeps both of its checks.
      [(not
          (=
            (opt-bce-version-test-block-checks out (compiler-ir-label "body"))
            1))
        7]
      [(not
          (=
            (opt-bce-version-test-block-checks out (compiler-ir-label "then"))
            1))
        8]
      ;; the exit phi gained the parallel fast-edge input.
      [(not
          (=
            (opt-bce-version-test-exit-phi-inputs
              out
              (compiler-ir-label "exit"))
            2))
        9]
      [else 42])))

(define (opt-bce-mb-test-cloned-switch-cases-ok?
  [cases : CompilerIrSwitchCaseList]) : bool
  (match (compiler-ir-switch-case-list-force-cons cases)
    [(CompilerIrSwitchCaseList.Cons first first-rest)
      (match first
        [(CompilerIrSwitchCase.Case first-tag first-label)
          (and
            (= first-tag 0)
            (= first-label (compiler-ir-label "else__bce_fast"))
            (match (compiler-ir-switch-case-list-force-cons
              (box-get first-rest))
              [(CompilerIrSwitchCaseList.Cons second second-rest)
                (match second
                  [(CompilerIrSwitchCase.Case second-tag second-label)
                    (and
                      (= second-tag 1)
                      (= second-label (compiler-ir-label "then__bce_fast"))
                      (match (compiler-ir-switch-case-list-force-cons
                        (box-get second-rest))
                        [(CompilerIrSwitchCaseList.Nil) true]
                        [_ false]))])]
              [_ false]))])]
    [_ false]))

(define (opt-bce-mb-test-cloned-switch-ok? [blocks : CompilerIrBlockList]) : bool
  (match (opt-cfg-find-block blocks (compiler-ir-label "body__bce_fast"))
    [(OptMaybeBlock.No) false]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (let
            [count : i64 (compiler-ir-instr-seq-count instrs)]
            (if (< count 1)
              false
              (match (compiler-ir-instr-seq-ref instrs (- count 1))
                [(CompilerIrInstr.Switch index base cases default-label)
                  (and
                    (= base 0)
                    (match index
                      [(CompilerIrValue.Var id) (not (= id 5))]
                      [_ false])
                    (opt-bce-mb-test-cloned-switch-cases-ok? cases)
                    ;; The no-return trap is outside the natural loop and stays
                    ;; shared; all in-loop case targets are remapped above.
                    (= default-label (compiler-ir-label "match_total_trap")))]
                [_ false])))])]))

(define (compiler-optimize-bce-version-mb-switch-self-test) : i64
  (let
    [versioned : CompilerIrFunction
      (opt-bce-version-function
        (opt-bce-mb-test-function (opt-bce-mb-test-blocks 4)))]
    [out : CompilerIrBlockList (opt-function-blocks versioned)]
    [marked : CompilerIrFunction
      (opt-bce-version-function
        (opt-bce-mb-test-function (opt-bce-mb-test-blocks 5)))]
    [marked-out : CompilerIrBlockList (opt-function-blocks marked)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function versioned))) 1]
      ;; Original seven blocks + guard + four fast loop blocks.
      [(not (= (compiler-ir-block-list-count out) 12)) 2]
      [(not (opt-bce-mb-test-cloned-switch-ok? out)) 3]
      [(not
          (=
            (opt-bce-version-test-block-checks
              out
              (compiler-ir-label "body__bce_fast"))
            0))
        4]
      ;; A lowering-proven exhaustive enum dispatch is totalized after BCE;
      ;; cloning its high-fanout loop here would collapse vm_run allocation.
      [(not (opt-verify-ok? (opt-verify-function marked))) 5]
      [(not (= (compiler-ir-block-list-count marked-out) 7)) 6]
      [(opt-block-list-has-label?
          marked-out
          (compiler-ir-label "body__bce_fast"))
        7]
      [else 42])))

(define (opt-bce-mb-pair-test-guard-has-len-fact-from?
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : bool
  (if (>= index (compiler-ir-instr-seq-count instrs))
    false
    (match (compiler-ir-instr-seq-ref instrs index)
      [(CompilerIrInstr.BinOp _ op lhs rhs _)
        (match op
          [(CompilerIrBinOp.Ge)
            (or
              (and
                (opt-value-eq lhs (CompilerIrValue.Var 1))
                (opt-value-eq rhs (CompilerIrValue.I64 1)))
              (opt-bce-mb-pair-test-guard-has-len-fact-from? instrs (+ index 1)))]
          [_ (opt-bce-mb-pair-test-guard-has-len-fact-from? instrs (+ index 1))])]
      [_ (opt-bce-mb-pair-test-guard-has-len-fact-from? instrs (+ index 1))])))

(define (opt-bce-mb-pair-test-guard-short-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : CompilerIrMaybeValue
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (CompilerIrMaybeValue.No)
    (match (compiler-ir-instr-seq-ref instrs index)
      [(CompilerIrInstr.BinOp dst op lhs rhs _)
        (match op
          [(CompilerIrBinOp.Sub)
            (if (and
              (opt-value-eq lhs (CompilerIrValue.Var 1))
              (match rhs
                [(CompilerIrValue.Var _) true]
                [_ false]))
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var dst))
              (opt-bce-mb-pair-test-guard-short-from instrs (+ index 1)))]
          [_ (opt-bce-mb-pair-test-guard-short-from instrs (+ index 1))])]
      [_ (opt-bce-mb-pair-test-guard-short-from instrs (+ index 1))])))

(define (opt-bce-mb-pair-test-guard-has-len-fact?
  [blocks : CompilerIrBlockList]) : bool
  (match (opt-cfg-find-block blocks (compiler-ir-label "entry"))
    [(OptMaybeBlock.No) false]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (opt-bce-mb-pair-test-guard-has-len-fact-from? instrs 0)])]))

(define (opt-bce-mb-pair-test-guard-short [blocks : CompilerIrBlockList]) : CompilerIrMaybeValue
  (match (opt-cfg-find-block blocks (compiler-ir-label "entry"))
    [(OptMaybeBlock.No) (CompilerIrMaybeValue.No)]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (opt-bce-mb-pair-test-guard-short-from instrs 0)])]))

(define (opt-bce-mb-pair-test-block-uses-length-from?
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [length : CompilerIrValue]) : bool
  (if (>= index (compiler-ir-instr-seq-count instrs))
    false
    (match (compiler-ir-instr-seq-ref instrs index)
      [(CompilerIrInstr.BoundsCheck _ check-length _)
        (or
          (opt-value-eq check-length length)
          (opt-bce-mb-pair-test-block-uses-length-from?
            instrs
            (+ index 1)
            length))]
      [_
        (opt-bce-mb-pair-test-block-uses-length-from? instrs (+ index 1) length)])))

(define (opt-bce-mb-pair-test-body-uses-length?
  [blocks : CompilerIrBlockList]
  [length : CompilerIrValue]) : bool
  (match (opt-cfg-find-block blocks (compiler-ir-label "then"))
    [(OptMaybeBlock.No) false]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (opt-bce-mb-pair-test-block-uses-length-from? instrs 0 length)])]))

;; Positive: the sp-1/sp-2 pair combines after the optimizer fixpoint, in the
;; existing total-enum loop. Its preheader owns len>=1 and the saturated len-1
;; used by the single replacement check. No blocks or loop versions are made.
;; Negatives retain both checks when separated by a store, when their lengths
;; differ, or when the existing preheader cannot establish the required fact.
;; The rollback case lets the removed affine definition escape through a phi;
;; the verifier gate must reject that candidate and preserve both checks.
(define (compiler-optimize-bce-version-mb-paired-self-test) : i64
  (let
    [positive : CompilerIrFunction
      (opt-late-bounds-pair-function
        (opt-bce-mb-test-function (opt-bce-mb-test-blocks 6)))]
    [positive-out : CompilerIrBlockList (opt-function-blocks positive)]
    [stored : CompilerIrFunction
      (opt-late-bounds-pair-function
        (opt-bce-mb-test-function (opt-bce-mb-test-blocks 7)))]
    [stored-out : CompilerIrBlockList (opt-function-blocks stored)]
    [different : CompilerIrFunction
      (opt-late-bounds-pair-function
        (opt-bce-mb-test-function (opt-bce-mb-test-blocks 8)))]
    [different-out : CompilerIrBlockList (opt-function-blocks different)]
    [no-fact : CompilerIrFunction
      (opt-late-bounds-pair-function
        (opt-bce-mb-test-function (opt-bce-mb-test-blocks 9)))]
    [no-fact-out : CompilerIrBlockList (opt-function-blocks no-fact)]
    [rollback : CompilerIrFunction
      (opt-late-bounds-pair-function
        (opt-bce-mb-test-function (opt-bce-mb-test-blocks 10)))]
    [rollback-out : CompilerIrBlockList (opt-function-blocks rollback)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function positive))) 1]
      [(not (= (compiler-ir-block-list-count positive-out) 7)) 2]
      [(opt-block-list-has-label?
          positive-out
          (compiler-ir-label "body__bce_fast"))
        3]
      [(not
          (=
            (opt-bce-version-test-block-checks
              positive-out
              (compiler-ir-label "then"))
            1))
        4]
      [(not (opt-bce-mb-pair-test-guard-has-len-fact? positive-out)) 5]
      [(match (opt-bce-mb-pair-test-guard-short positive-out)
          [(CompilerIrMaybeValue.Some short-length)
            (not
              (opt-bce-mb-pair-test-body-uses-length? positive-out short-length))]
          [(CompilerIrMaybeValue.No) true])
        6]
      [(not (opt-verify-ok? (opt-verify-function stored))) 7]
      [(not (= (compiler-ir-block-list-count stored-out) 7)) 8]
      [(not
          (=
            (opt-bce-version-test-block-checks
              stored-out
              (compiler-ir-label "then"))
            2))
        9]
      [(opt-bce-mb-pair-test-guard-has-len-fact? stored-out) 10]
      [(not (opt-verify-ok? (opt-verify-function different))) 11]
      [(not (= (compiler-ir-block-list-count different-out) 7)) 12]
      [(not
          (=
            (opt-bce-version-test-block-checks
              different-out
              (compiler-ir-label "then"))
            2))
        13]
      [(opt-bce-mb-pair-test-guard-has-len-fact? different-out) 14]
      [(not (opt-verify-ok? (opt-verify-function no-fact))) 15]
      [(not (= (compiler-ir-block-list-count no-fact-out) 7)) 16]
      [(not
          (=
            (opt-bce-version-test-block-checks
              no-fact-out
              (compiler-ir-label "then"))
            2))
        17]
      [(opt-bce-mb-pair-test-guard-has-len-fact? no-fact-out) 18]
      [(not (opt-verify-ok? (opt-verify-function rollback))) 19]
      [(not (= (compiler-ir-block-list-count rollback-out) 7)) 20]
      [(not
          (=
            (opt-bce-version-test-block-checks
              rollback-out
              (compiler-ir-label "then"))
            2))
        21]
      [(opt-bce-mb-pair-test-guard-has-len-fact? rollback-out) 22]
      ;; Common-base offsets identify var6 (phi-1) / var13 (phi-2), with the
      ;; later operand as the smaller index.
      [(match (opt-bce-mb-affine-pair
          (opt-bce-mb-test-blocks 6)
          (CompilerIrValue.Var 6)
          (CompilerIrValue.Var 13))
          [(OptBceMbAffinePair.Some first-smaller) first-smaller]
          [(OptBceMbAffinePair.No) true])
        23]
      [else 42])))

(define (compiler-optimize-bce-version-mb-negative-self-test) : i64
  (let
    [with-call : CompilerIrBlockList
      (opt-function-blocks
        (opt-bce-version-function
          (opt-bce-mb-test-function (opt-bce-mb-test-blocks 2))))]
    [step-two : CompilerIrBlockList
      (opt-function-blocks
        (opt-bce-version-function
          (opt-bce-mb-test-function (opt-bce-mb-test-blocks 3))))]
    [too-big : CompilerIrBlockList
      (opt-function-blocks
        (opt-bce-version-function
          (CompilerIrFunction.Function
            (opt-test-symbol "bce_version_mb_chain_fixture")
            (opt-bce-version-test-params)
            (AstType.I64)
            10
            (opt-bce-mb-test-chain-blocks))))]
    (cond
      ;; every rejection leaves the function untouched.
      [(not (= (compiler-ir-block-list-count with-call) 6)) 1]
      [(not (= (compiler-ir-block-list-count step-two) 6)) 2]
      [(not (= (compiler-ir-block-list-count too-big) 11)) 3]
      [else 42])))

;; Partial versioning: the swap check's store+1 index does not derive, but the
;; body's counter check does -- the loop versions, the fast clone drops only
;; the counter check and KEEPS the swap check (remapped).
(define (compiler-optimize-bce-version-mb-partial-self-test) : i64
  (let
    [versioned : CompilerIrFunction
      (opt-bce-version-function
        (opt-bce-mb-test-function (opt-bce-mb-test-blocks 1)))]
    [out : CompilerIrBlockList (opt-function-blocks versioned)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function versioned))) 1]
      ;; entry + guard + four fast clones + four slow blocks + exit
      [(not (= (compiler-ir-block-list-count out) 11)) 2]
      ;; the derivable counter check is gone from the fast header...
      [(not
          (=
            (opt-bce-version-test-block-checks
              out
              (compiler-ir-label "body__bce_fast"))
            0))
        3]
      ;; ... while the underivable swap check STAYS in the fast clone ...
      [(not
          (=
            (opt-bce-version-test-block-checks
              out
              (compiler-ir-label "then__bce_fast"))
            1))
        4]
      ;; ... and the slow loop keeps both of its checks.
      [(not
          (=
            (opt-bce-version-test-block-checks out (compiler-ir-label "body"))
            1))
        5]
      [(not
          (=
            (opt-bce-version-test-block-checks out (compiler-ir-label "then"))
            1))
        6]
      ;; the exit phi gained the parallel fast-edge input.
      [(not
          (=
            (opt-bce-version-test-exit-phi-inputs
              out
              (compiler-ir-label "exit"))
            2))
        7]
      [else 42])))

;; --- Gep use-splitting self-tests --------------------------------------------
(define (opt-gep-split-test-gep-count-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [acc : i64]) : i64
  (if (>= index (compiler-ir-instr-seq-count instrs))
    acc
    (opt-gep-split-test-gep-count-from
      instrs
      (+ index 1)
      (+
        acc
        (match (compiler-ir-instr-seq-ref instrs index)
          [(CompilerIrInstr.Gep _ _ _ _) 1]
          [_ 0])))))

(define (opt-gep-split-test-gep-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (opt-gep-split-test-gep-count-from instrs 0 0)
            (opt-gep-split-test-gep-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (opt-gep-split-test-gep-count (compiler-ir-block-seq-to-list seq))]))

;; One shared Gep feeding a Load and a StorePtr (the quicksort swap shape);
;; `other-use` adds a BinOp consumer, which must leave the Gep untouched.
(define (opt-gep-split-test-shared-blocks [other-use : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          3
          (CompilerIrValue.Var 1)
          (CompilerIrValue.Var 0)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 4 (CompilerIrValue.Var 3) (AstType.I64))
          (compiler-ir-instr-cons
            (if other-use
              (CompilerIrInstr.BinOp
                5
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 3)
                (CompilerIrValue.I64 1)
                (AstType.I64))
              (CompilerIrInstr.Mov 5 (CompilerIrValue.I64 0) (AstType.I64)))
            (compiler-ir-instr-cons
              (CompilerIrInstr.StorePtr
                (CompilerIrValue.Var 3)
                (CompilerIrValue.Var 0)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                (CompilerIrInstrList.Nil)))))))
    (CompilerIrBlockList.Nil)))

;; Lowering can wrap a field/index address in `Gep address, 0 : u8` before a
;; memory operation. The wrapper must inherit the inner Gep recipe so the dead
;; inner definition can be removed and the backend sees one fusible Gep.
(define (opt-gep-split-test-chain-blocks
  [offset : CompilerIrValue]
  [elem-ty : AstType]
  [other-use : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep 3 (CompilerIrValue.Var 2) offset elem-ty)
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            4
            (CompilerIrValue.Var 3)
            (CompilerIrValue.I64 0)
            (AstType.U8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 4)
              (CompilerIrValue.Var 1)
              (AstType.I64))
            (compiler-ir-instr-cons
              (if other-use
                (CompilerIrInstr.BinOp
                  5
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 3)
                  (CompilerIrValue.I64 1)
                  (AstType.I64))
                (CompilerIrInstr.Mov 5 (CompilerIrValue.I64 0) (AstType.I64)))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
                (CompilerIrInstrList.Nil)))))))
    (CompilerIrBlockList.Nil)))

(define (opt-gep-split-test-chain-function
  [offset : CompilerIrValue]
  [elem-ty : AstType]
  [other-use : bool]) : CompilerIrFunction
  (opt-gep-split-function
    (CompilerIrFunction.Function
      (opt-test-symbol "gep_split_chain")
      (opt-bce-version-test-params)
      (AstType.I64)
      6
      (opt-gep-split-test-chain-blocks offset elem-ty other-use))))

(define (opt-gep-split-test-chain-shape?
  [func : CompilerIrFunction]
  [expected-base : CompilerIrValue]
  [expected-offset : CompilerIrValue]
  [expected-ty : AstType]) : bool
  (match (opt-function-blocks func)
    [(CompilerIrBlockList.Cons block _)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (if (> (compiler-ir-instr-seq-count instrs) 1)
            (match (compiler-ir-instr-seq-ref instrs 1)
              [(CompilerIrInstr.Gep dst base offset elem-ty)
                (and
                  (= dst 4)
                  (opt-value-eq base expected-base)
                  (opt-value-eq offset expected-offset)
                  (opt-type-eq elem-ty expected-ty))]
              [_ false])
            false)])]
    [_ false]))

(define (compiler-optimize-gep-split-self-test) : i64
  (let
    [split : CompilerIrFunction
      (opt-gep-split-function
        (CompilerIrFunction.Function
          (opt-test-symbol "gep_split_shared")
          (opt-bce-version-test-params)
          (AstType.I64)
          8
          (opt-gep-split-test-shared-blocks false)))]
    [split-blocks : CompilerIrBlockList (opt-function-blocks split)]
    [untouched : CompilerIrFunction
      (opt-gep-split-function
        (CompilerIrFunction.Function
          (opt-test-symbol "gep_split_other_use")
          (opt-bce-version-test-params)
          (AstType.I64)
          8
          (opt-gep-split-test-shared-blocks true)))]
    [chain-zero : CompilerIrFunction
      (opt-gep-split-test-chain-function
        (CompilerIrValue.I64 0)
        (AstType.U8)
        false)]
    [chain-disp : CompilerIrFunction
      (opt-gep-split-test-chain-function
        (CompilerIrValue.I64 8)
        (AstType.U8)
        false)]
    [chain-index : CompilerIrFunction
      (opt-gep-split-test-chain-function
        (CompilerIrValue.Var 0)
        (AstType.I64)
        false)]
    [chain-other-use : CompilerIrFunction
      (opt-gep-split-test-chain-function
        (CompilerIrValue.I64 8)
        (AstType.U8)
        true)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function split))) 1]
      ;; the shared Gep is cloned per use (Load + StorePtr get one fresh
      ;; single-use Gep each); the dead original is left for the pipeline's
      ;; DCE, so the block holds 2 fresh + 1 dead = 3 Geps.
      [(not (= (opt-gep-split-test-gep-count split-blocks) 3)) 2]
      ;; a Gep with a non-address consumer (the BinOp) is not split.
      [(not
          (= (opt-gep-split-test-gep-count (opt-function-blocks untouched)) 1))
        3]
      [(not (opt-verify-ok? (opt-verify-function untouched))) 4]
      [(not
          (opt-gep-split-test-chain-shape?
            chain-zero
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 0)
            (AstType.U8)))
        5]
      [(not
          (opt-gep-split-test-chain-shape?
            chain-disp
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 8)
            (AstType.U8)))
        6]
      [(not
          (opt-gep-split-test-chain-shape?
            chain-index
            (CompilerIrValue.Var 2)
            (CompilerIrValue.Var 0)
            (AstType.I64)))
        7]
      ;; A non-memory use of the inner address rejects the collapse; the outer
      ;; Gep still reads var 3 and therefore remains materialized by the backend.
      [(not
          (opt-gep-split-test-chain-shape?
            chain-other-use
            (CompilerIrValue.Var 3)
            (CompilerIrValue.I64 0)
            (AstType.U8)))
        8]
      [(not (opt-verify-ok? (opt-verify-function chain-zero))) 9]
      [(not (opt-verify-ok? (opt-verify-function chain-disp))) 10]
      [(not (opt-verify-ok? (opt-verify-function chain-index))) 11]
      [(not (opt-verify-ok? (opt-verify-function chain-other-use))) 12]
      [else 42])))

;; --- multi-block versioning pipeline self-test --------------------------------------
;; Full-pipeline integration: a lowered while loop whose body splits into a
;; store++ path and a skip path (the quicksort partition shape) must rotate
;; into a multi-block counted loop, version, and leave every fast-derived
;; block check-free while the slow original keeps its per-iteration checks.
(define (opt-bce-mb-pipeline-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 0) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 4 (CompilerIrValue.I64 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "header"))
            (CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "header")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            5
            (CompilerIrBinOp.Lt)
            (CompilerIrValue.Var 3)
            (CompilerIrValue.Var 0)
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 5)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BoundsCheck
              (CompilerIrValue.Var 3)
              (CompilerIrValue.Var 1)
              (compiler-ir-label "mbp_ok0"))
            (compiler-ir-instr-cons
              (CompilerIrInstr.StorePtr
                (CompilerIrValue.Var 2)
                (CompilerIrValue.Var 4)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  6
                  (CompilerIrBinOp.Lt)
                  (CompilerIrValue.Var 4)
                  (CompilerIrValue.I64 4)
                  (AstType.Bool))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Branch
                    (CompilerIrValue.Var 6)
                    (compiler-ir-label "then")
                    (compiler-ir-label "else"))
                  (CompilerIrInstrList.Nil))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "then")
            (compiler-ir-instr-cons
              (CompilerIrInstr.BoundsCheck
                (CompilerIrValue.Var 4)
                (CompilerIrValue.Var 1)
                (compiler-ir-label "mbp_ok1"))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  7
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 4)
                  (CompilerIrValue.I64 1)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Mov 4 (CompilerIrValue.Var 7) (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Jump (compiler-ir-label "merge"))
                    (CompilerIrInstrList.Nil))))))
          (compiler-ir-block-cons
            (opt-bce-mb-test-jump-block
              (compiler-ir-label "else")
              (compiler-ir-label "merge"))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "merge")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    8
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 3)
                    (CompilerIrValue.I64 1)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Mov
                      3
                      (CompilerIrValue.Var 8)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Jump (compiler-ir-label "header"))
                      (CompilerIrInstrList.Nil)))))
              (compiler-ir-block-cons
                (compiler-ir-block
                  (compiler-ir-label "exit")
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return
                      (CompilerIrMaybeValue.Some (CompilerIrValue.Var 4)))
                    (CompilerIrInstrList.Nil)))
                (CompilerIrBlockList.Nil)))))))))

(define (opt-bce-mb-test-matches-at?
  [label : String]
  [needle : String]
  [off : i64]
  [index : i64]) : bool
  (if (>= index (string.string-length needle))
    true
    (if (=
      (cast (string.string-ref label (+ off index)) : i64)
      (cast (string.string-ref needle index) : i64))
      (opt-bce-mb-test-matches-at? label needle off (+ index 1))
      false)))

(define (opt-bce-mb-test-label-contains-from?
  [label : String]
  [needle : String]
  [off : i64]) : bool
  (if (> (+ off (string.string-length needle)) (string.string-length label))
    false
    (if (opt-bce-mb-test-matches-at? label needle off 0)
      true
      (opt-bce-mb-test-label-contains-from? label needle (+ off 1)))))

(define (opt-bce-mb-test-label-contains? [label : i64] [needle : String]) : bool
  (opt-bce-mb-test-label-contains-from? (compiler-ir-label-text label) needle 0))

;; Count blocks whose label contains needle.
(define (opt-bce-mb-test-matching-blocks
  [blocks : CompilerIrBlockList]
  [needle : String]
  [acc : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) acc]
    [(CompilerIrBlockList.Cons block rest)
      (opt-bce-mb-test-matching-blocks
        (box-get rest)
        needle
        (match block
          [(CompilerIrBlock.Block label _)
            (if (opt-bce-mb-test-label-contains? label needle)
              (+ acc 1)
              acc)]))]
    [(CompilerIrBlockList.Array seq)
      (opt-bce-mb-test-matching-blocks
        (compiler-ir-block-seq-to-list seq)
        needle
        acc)]))

;; Total BoundsChecks in blocks whose label contains needle.
(define (opt-bce-mb-test-matching-checks
  [blocks : CompilerIrBlockList]
  [needle : String]
  [acc : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) acc]
    [(CompilerIrBlockList.Cons block rest)
      (opt-bce-mb-test-matching-checks
        (box-get rest)
        needle
        (match block
          [(CompilerIrBlock.Block label instrs)
            (if (opt-bce-mb-test-label-contains? label needle)
              (+
                acc
                (opt-bce-version-check-count
                  instrs
                  0
                  (compiler-ir-instr-seq-count instrs)
                  0))
              acc)]))]
    [(CompilerIrBlockList.Array seq)
      (opt-bce-mb-test-matching-checks
        (compiler-ir-block-seq-to-list seq)
        needle
        acc)]))

(define (compiler-optimize-bce-version-mb-pipeline-self-test) : i64
  (let
    [optimized : CompilerIrFunction
      (optimize-function
        (CompilerIrFunction.Function
          (opt-test-symbol "bce_version_mb_while_fixture")
          (opt-bce-version-test-params)
          (AstType.I64)
          9
          (opt-bce-mb-pipeline-blocks)))]
    [blocks : CompilerIrBlockList (opt-function-blocks optimized)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function optimized))) 1]
      ;; the fast region exists ...
      [(< (opt-bce-mb-test-matching-blocks blocks "__bce_fast" 0) 2) 2]
      ;; ... every fast-derived block is check-free ...
      [(not (= (opt-bce-mb-test-matching-checks blocks "__bce_fast" 0) 0)) 3]
      ;; ... and the slow original keeps its per-iteration checks ("" is a
      ;; prefix of every label, so this counts checks function-wide).
      [(< (opt-bce-version-test-prefix-checks blocks "" 0) 2) 4]
      [else 42])))

(define (opt-unroll-mb-read-only-test-body) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "read_only")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 9 (CompilerIrValue.Var 2) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "read_only_exit"))
          (CompilerIrInstrList.Nil))))
    (CompilerIrBlockList.Nil)))

;; Build the exact CFG fragment produced by the production multiblock clone at
;; an absorbed call site, then leave a self tail call in its continuation. The
;; optimizer turns that tail call into an entry backedge. This combines the two
;; shapes that exposed the regression: a cloned, bounds-carrying inner loop and
;; an enclosing caller loop whose header is the function entry.
(define (opt-merged-loop-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "n" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "len" (AstType.I64) 1)
      (compiler-ir-param-cons
        ;; Model the unchanged aggregate carried by the real absorbed-call
        ;; shape. Scalar SSA deliberately does not rename this slot.
        (CompilerIrParam.Param "base" (AstType.DynArray 0) 2)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "rounds" (AstType.I64) 3)
          (CompilerIrParamList.Nil))))))

(define (opt-merged-loop-test-callee-args) : CompilerIrCallArgs
  (let
    [args : (Array CompilerIrValue) (array.make-array CompilerIrValue 3)]
    (begin
      (array-set! args 0 (CompilerIrValue.Var 0))
      (array-set! args 1 (CompilerIrValue.Var 1))
      (array-set! args 2 (CompilerIrValue.Var 2))
      (CompilerIrCallArgs.Array args))))

(define (opt-merged-loop-test-tail-args [rounds : i64]) : CompilerIrCallArgs
  (let
    [args : (Array CompilerIrValue) (array.make-array CompilerIrValue 4)]
    (begin
      ;; The first three arguments are unchanged. Tail-recursion conversion
      ;; must not materialize identity writes for them.
      (array-set! args 0 (CompilerIrValue.Var 0))
      (array-set! args 1 (CompilerIrValue.Var 1))
      (array-set! args 2 (CompilerIrValue.Var 2))
      (array-set! args 3 (CompilerIrValue.Var rounds))
      (CompilerIrCallArgs.Array args))))

(define (opt-merged-loop-test-callee-blocks) : CompilerIrBlockList
  (opt-function-blocks
    (opt-ssa-construct-function
      (CompilerIrFunction.Function
        (opt-test-symbol "merged_loop_callee")
        (opt-bce-version-test-params)
        (AstType.I64)
        9
        (opt-bce-mb-pipeline-blocks)))))

(define (opt-merged-loop-test-function) : CompilerIrFunction
  (let
    [name : i64 (opt-test-symbol "merged_loop_caller")]
    [prefix : String "inl.absorbed.0"]
    [cont : i64 (compiler-ir-label "inl.absorbed.0.cont")]
    (match (opt-inline-clone-multiblock-blocks
      (opt-merged-loop-test-callee-blocks)
      prefix
      cont
      (opt-merged-loop-test-callee-args)
      3
      5)
      [(OptInlineMultiClone.Clone cloned return-inputs)
        (let
          [entry-blocks : CompilerIrBlockList
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "entry")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    4
                    (CompilerIrBinOp.Gt)
                    (CompilerIrValue.Var 3)
                    (CompilerIrValue.I64 0)
                    (AstType.Bool))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Branch
                      (CompilerIrValue.Var 4)
                      (compiler-ir-label "call_site")
                      (compiler-ir-label "caller_exit"))
                    (CompilerIrInstrList.Nil))))
              (compiler-ir-block-cons
                (opt-bce-mb-test-jump-block
                  (compiler-ir-label "call_site")
                  (compiler-ir-label "inl.absorbed.0.entry"))
                (CompilerIrBlockList.Nil)))]
          [tail-blocks : CompilerIrBlockList
            (compiler-ir-block-cons
              (compiler-ir-block
                cont
                (compiler-ir-instr-cons
                  (opt-inline-cont-result-instr 100 return-inputs (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.BinOp
                      101
                      (CompilerIrBinOp.Sub)
                      (CompilerIrValue.Var 3)
                      (CompilerIrValue.I64 1)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.TailCall
                        name
                        (opt-merged-loop-test-tail-args 101)
                        (AstType.I64))
                      (CompilerIrInstrList.Nil)))))
              (compiler-ir-block-cons
                (compiler-ir-block
                  (compiler-ir-label "caller_exit")
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return
                      (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
                    (CompilerIrInstrList.Nil)))
                (CompilerIrBlockList.Nil)))]
          (CompilerIrFunction.Function
            name
            (opt-merged-loop-test-params)
            (AstType.I64)
            102
            (opt-inline-block-append
              entry-blocks
              (opt-inline-block-append cloned tail-blocks))))])))

;; The unroller's multi-block companion must pick up the check-free versioned
;; diamond on a later optimizer iteration (after its dedicated preheader has
;; been synthesized), peel the odd iteration, and emit exactly two body copies.
(define (compiler-optimize-unroll-mb-self-test) : i64
  (let
    [optimized : CompilerIrFunction
      (optimize-function
        (CompilerIrFunction.Function
          (opt-test-symbol "unroll_mb_while_fixture")
          (opt-bce-version-test-params)
          (AstType.I64)
          9
          (opt-bce-mb-pipeline-blocks)))]
    [blocks : CompilerIrBlockList (opt-function-blocks optimized)]
    [merged : CompilerIrFunction
      (optimize-function (opt-merged-loop-test-function))]
    [merged-blocks : CompilerIrBlockList (opt-function-blocks merged)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function optimized))) 1]
      [(not
          (opt-block-list-has-label?
            blocks
            (compiler-ir-label "body__bce_fast__unroll2_guard")))
        2]
      ;; Arm-local swap/update work is deliberately not if-converted: both
      ;; four-block unrolled diamonds remain intact.
      [(not (= (opt-bce-mb-test-matching-blocks blocks "__unroll2_0" 0) 4)) 3]
      [(not (= (opt-bce-mb-test-matching-blocks blocks "__unroll2_1" 0) 4)) 4]
      ;; The original fast peel and both pair copies remain check-free; the
      ;; slow original still carries both aborting checks.
      [(not (= (opt-bce-mb-test-matching-checks blocks "__unroll2" 0) 0)) 5]
      [(not (= (opt-bce-mb-test-matching-checks blocks "__bce_fast" 0) 0)) 6]
      [(< (opt-bce-version-test-prefix-checks blocks "" 0) 2) 7]
      ;; The profitability gate rejects read-only diamonds; StorePtr is
      ;; admitted only on this proven-fast path, while calls and checks
      ;; themselves remain outside the cloning whitelist.
      [(not
          (= (opt-unroll-mb-body-status (opt-unroll-mb-read-only-test-body)) 0))
        8]
      [(not
          (opt-unroll-mb-body-instr-ok?
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 1)
              (AstType.I64))))
        9]
      [(opt-unroll-mb-body-instr-ok?
          (CompilerIrInstr.Call
            0
            (opt-test-symbol "unroll_mb_callee")
            (CompilerIrCallArgs.Nil)
            (AstType.I64)))
        10]
      [(opt-unroll-mb-body-instr-ok?
          (CompilerIrInstr.BoundsCheck
            (CompilerIrValue.Var 0)
            (CompilerIrValue.Var 1)
            (compiler-ir-label "unroll_mb_check")))
        11]
      [(not (opt-verify-ok? (opt-verify-function merged))) 12]
      [(not
          (opt-block-list-has-label?
            merged-blocks
            (compiler-ir-label "entry__ssa_entry")))
        13]
      [(not
          (opt-block-list-has-label?
            merged-blocks
            (compiler-ir-label "inl.absorbed.0.body__bce_fast__unroll2_guard")))
        14]
      [(not
          (= (opt-bce-mb-test-matching-blocks merged-blocks "__unroll2_0" 0) 4))
        15]
      [(not
          (= (opt-bce-mb-test-matching-blocks merged-blocks "__unroll2_1" 0) 4))
        16]
      [(not
          (= (opt-bce-mb-test-matching-checks merged-blocks "__bce_fast" 0) 0))
        17]
      [else 42])))

;; --- pre-existing-phi SSA construction self-test --------------------------------
;; A value-if join lowers to a Phi while `set!` locals stay multi-def Movs, so
;; the function reaches SSA construction with BOTH pre-existing phis and rename
;; candidates. Construction must rename the phi's inputs per edge; a phi whose
;; DST is itself multi-def must reject (function left non-SSA).
(define (opt-ssa-preexisting-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "cond" (AstType.Bool) 0)
    (CompilerIrParamList.Nil)))

(define (opt-ssa-preexisting-test-blocks [dup-phi-dst : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 5) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov
            (if dup-phi-dst
              4
              5)
            (CompilerIrValue.I64 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 0)
              (compiler-ir-label "then")
              (compiler-ir-label "else"))
            (CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "then")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 7) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "join"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "else")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 11) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "join")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Phi
                4
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 3)
                  (compiler-ir-label "then")
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.Var 3)
                    (compiler-ir-label "else")
                    (CompilerIrPhiInputList.Nil)))
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 9) (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    6
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 4)
                    (CompilerIrValue.Var 2)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return
                      (CompilerIrMaybeValue.Some (CompilerIrValue.Var 6)))
                    (CompilerIrInstrList.Nil))))))
          (CompilerIrBlockList.Nil))))))

(define (opt-ssa-preexisting-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_preexisting_phi")
    (opt-ssa-preexisting-test-params)
    (AstType.I64)
    7
    blocks))

(define (opt-ssa-preexisting-test-first-phi-inputs
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [count : i64]) : CompilerIrValueList
  (if (>= index count)
    (CompilerIrValueList.Nil)
    (match (compiler-ir-instr-seq-ref instrs index)
      [(CompilerIrInstr.Phi _ inputs _)
        (match (compiler-ir-phi-input-list-force-cons inputs)
          [(CompilerIrPhiInputList.Cons a _ rest)
            (match (box-get rest)
              [(CompilerIrPhiInputList.Cons b _ _)
                (compiler-ir-value-cons
                  a
                  (compiler-ir-value-cons b (CompilerIrValueList.Nil)))]
              [_ (CompilerIrValueList.Nil)])]
          [_ (CompilerIrValueList.Nil)])]
      [_ (opt-ssa-preexisting-test-first-phi-inputs instrs (+ index 1) count)])))

;; The join block's first phi's two inputs; Nil when missing.
(define (opt-ssa-preexisting-test-phi-inputs [blocks : CompilerIrBlockList]) : CompilerIrValueList
  (match (opt-cfg-find-block blocks (compiler-ir-label "join"))
    [(OptMaybeBlock.No) (CompilerIrValueList.Nil)]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (opt-ssa-preexisting-test-first-phi-inputs
            instrs
            0
            (compiler-ir-instr-seq-count instrs))])]))

(define (compiler-optimize-ssa-preexisting-phi-self-test) : i64
  (let
    [constructed : CompilerIrFunction
      (opt-ssa-construct-function
        (opt-ssa-preexisting-test-function
          (opt-ssa-preexisting-test-blocks false)))]
    [rejected : CompilerIrFunction
      (opt-ssa-construct-function
        (opt-ssa-preexisting-test-function
          (opt-ssa-preexisting-test-blocks true)))]
    (cond
      [(not (opt-verify-ok? (opt-verify-function constructed))) 1]
      ;; the pre-existing join phi reads the then/else VERSIONS of var 3: two
      ;; Var inputs that differ from each other (unrewritten would be 3 == 3).
      [(match (compiler-ir-value-list-force-cons
          (opt-ssa-preexisting-test-phi-inputs
            (opt-function-blocks constructed)))
          [(CompilerIrValueList.Cons a rest)
            (match (box-get rest)
              [(CompilerIrValueList.Cons b _)
                (match a
                  [(CompilerIrValue.Var av)
                    (match b
                      [(CompilerIrValue.Var bv) (= av bv)]
                      [_ true])]
                  [_ true])]
              [_ true])]
          [_ true])
        2]
      ;; a multi-def phi DST rejects: the function stays non-SSA.
      [(opt-verify-ok? (opt-verify-function rejected)) 3]
      [else 42])))

;; --- multi-exit loop LICM self-test ---------------------------------------------
;; A probe-shaped search loop (guarded header, bounds check, early-return side
;; exit) must still hoist its loop-invariant ptr/len loads; adding an in-loop
;; store must block the hoist.
(define (opt-licm-multi-exit-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "map" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "key" (AstType.I64) 1)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "limit" (AstType.I64) 2)
        (CompilerIrParamList.Nil)))))

(define (opt-licm-multi-exit-header-block) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "header")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Phi
        3
        (compiler-ir-phi-input-cons
          (CompilerIrValue.I64 0)
          (compiler-ir-label "entry")
          (compiler-ir-phi-input-cons
            (CompilerIrValue.Var 10)
            (compiler-ir-label "next")
            (CompilerIrPhiInputList.Nil)))
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Phi
          4
          (compiler-ir-phi-input-cons
            (CompilerIrValue.I64 0)
            (compiler-ir-label "entry")
            (compiler-ir-phi-input-cons
              (CompilerIrValue.Var 11)
              (compiler-ir-label "next")
              (CompilerIrPhiInputList.Nil)))
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            5
            (CompilerIrBinOp.Lt)
            (CompilerIrValue.Var 4)
            (CompilerIrValue.Var 2)
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 5)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil)))))))

(define (opt-licm-multi-exit-body-tail [mode : i64]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      12
      (CompilerIrValue.Var 9)
      (CompilerIrValue.Var 3)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 13 (CompilerIrValue.Var 12) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          14
          (CompilerIrBinOp.Eq)
          (CompilerIrValue.Var 13)
          (CompilerIrValue.Var 1)
          (AstType.Bool))
        (compiler-ir-instr-cons
          (if (= mode 0)
            (CompilerIrInstr.Jump (compiler-ir-label "next"))
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 14)
              (compiler-ir-label "found")
              (compiler-ir-label "next")))
          (CompilerIrInstrList.Nil))))))

(define (opt-licm-multi-exit-body-block [mode : i64]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "body")
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        6
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 7 (CompilerIrValue.Var 6) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BoundsCheck
            (CompilerIrValue.Var 3)
            (CompilerIrValue.Var 7)
            (compiler-ir-label "licm_multi_exit_ok"))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              8
              (CompilerIrValue.Var 0)
              (CompilerIrValue.I64 0)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 9 (CompilerIrValue.Var 8) (AstType.I64))
              (opt-licm-multi-exit-body-tail mode))))))))

(define (opt-licm-multi-exit-next-block [with-store : bool]) : CompilerIrBlock
  (compiler-ir-block
    (compiler-ir-label "next")
    (compiler-ir-instr-cons
      (CompilerIrInstr.BinOp
        10
        (CompilerIrBinOp.Add)
        (CompilerIrValue.Var 3)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          11
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 4)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        (if with-store
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 12)
              (CompilerIrValue.I64 0)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "header"))
              (CompilerIrInstrList.Nil)))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "header"))
            (CompilerIrInstrList.Nil)))))))

(define (opt-licm-multi-exit-found-block [mode : i64]) : CompilerIrBlock
  (if (= mode 1)
    ;; return-shaped side exit: a found handler locates the slot (bounded
    ;; memory work) and returns -- still a short-trip SEARCH, so the invariant
    ;; load hoist is suppressed (the put! shape: gep/load/store then return).
    (compiler-ir-block
      (compiler-ir-label "found")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 16 (CompilerIrValue.Var 12) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 12)
            (CompilerIrValue.Var 16)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 16)))
            (CompilerIrInstrList.Nil)))))
    ;; break-shaped side exit: the continuation calls out to unbounded work,
    ;; marking a long-trip kernel -- the hoist stays.
    (compiler-ir-block
      (compiler-ir-label "found")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Call
          16
          (opt-test-symbol "licm_multi_exit_callee")
          (CompilerIrCallArgs.Nil)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 16)))
          (CompilerIrInstrList.Nil))))))

(define (opt-licm-multi-exit-tail-blocks [mode : i64]) : CompilerIrBlockList
  (let
    [exit-block : CompilerIrBlock
      (compiler-ir-block
        (compiler-ir-label "exit")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
          (CompilerIrInstrList.Nil)))]
    (if (= mode 0)
      (compiler-ir-block-cons exit-block (CompilerIrBlockList.Nil))
      (compiler-ir-block-cons
        (opt-licm-multi-exit-found-block mode)
        (compiler-ir-block-cons exit-block (CompilerIrBlockList.Nil))))))

(define (opt-licm-multi-exit-test-blocks [mode : i64] [with-store : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "header"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (opt-licm-multi-exit-header-block)
      (compiler-ir-block-cons
        (opt-licm-multi-exit-body-block mode)
        (compiler-ir-block-cons
          (opt-licm-multi-exit-next-block with-store)
          (opt-licm-multi-exit-tail-blocks mode))))))

(define (opt-licm-multi-exit-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "licm_multi_exit")
    (opt-licm-multi-exit-test-params)
    (AstType.I64)
    17
    blocks))

(define (opt-licm-multi-exit-count-loads-seq
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-licm-multi-exit-count-loads-seq
      instrs
      (+ index 1)
      count
      (match (compiler-ir-instr-seq-ref instrs index)
        [(CompilerIrInstr.Load _ _ _) (+ acc 1)]
        [_ acc]))))

(define (opt-licm-multi-exit-count-loads
  [blocks : CompilerIrBlockList]
  [label-want : i64]) : i64
  (match (opt-cfg-find-block blocks label-want)
    [(OptMaybeBlock.No) (- 0 1)]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (opt-licm-multi-exit-count-loads-seq
            instrs
            0
            (compiler-ir-instr-seq-count instrs)
            0)])]))

(define (compiler-optimize-licm-multi-exit-self-test) : i64
  (let
    [single : CompilerIrFunction
      (opt-licm-function
        (opt-licm-multi-exit-test-function
          (opt-licm-multi-exit-test-blocks 0 false)))]
    [single-blocks : CompilerIrBlockList (opt-function-blocks single)]
    [ret-exit : CompilerIrFunction
      (opt-licm-function
        (opt-licm-multi-exit-test-function
          (opt-licm-multi-exit-test-blocks 1 false)))]
    [ret-blocks : CompilerIrBlockList (opt-function-blocks ret-exit)]
    [brk-exit : CompilerIrFunction
      (opt-licm-function
        (opt-licm-multi-exit-test-function
          (opt-licm-multi-exit-test-blocks 2 false)))]
    [brk-blocks : CompilerIrBlockList (opt-function-blocks brk-exit)]
    [stored : CompilerIrFunction
      (opt-licm-function
        (opt-licm-multi-exit-test-function
          (opt-licm-multi-exit-test-blocks 0 true)))]
    [stored-blocks : CompilerIrBlockList (opt-function-blocks stored)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function single))) 1]
      ;; single-exit search loop: the invariant ptr/len loads hoist; only the
      ;; varying element load stays in the body.
      [(not
          (=
            (opt-licm-multi-exit-count-loads
              single-blocks
              (compiler-ir-label "body"))
            1))
        2]
      [(not
          (=
            (opt-licm-multi-exit-count-loads
              single-blocks
              (compiler-ir-label "entry"))
            2))
        3]
      ;; a RETURN-SHAPED side exit (early-return probe that does bounded
      ;; gep/load/store work then returns -- the put! shape) suppresses the
      ;; load hoist: short trips make it pure register pressure (see the
      ;; measured note at opt-licm-apply-loop).
      [(not
          (=
            (opt-licm-multi-exit-count-loads
              ret-blocks
              (compiler-ir-label "body"))
            3))
        4]
      ;; a BREAK-shaped side exit (continuation calls out to unbounded work)
      ;; marks a long-trip kernel: the hoist stays.
      [(not
          (=
            (opt-licm-multi-exit-count-loads
              brk-blocks
              (compiler-ir-label "body"))
            1))
        5]
      [(not
          (=
            (opt-licm-multi-exit-count-loads
              brk-blocks
              (compiler-ir-label "entry"))
            2))
        6]
      ;; an in-loop store blocks the hoist entirely.
      [(not
          (=
            (opt-licm-multi-exit-count-loads
              stored-blocks
              (compiler-ir-label "body"))
            3))
        7]
      [else 42])))

;; --- affine chain folding self-test -------------------------------------------
;; Emulates the x4 unroller's output: an LCG chain `((x*5+3)*5+3)*5+3` must
;; collapse so the last pair reads `x*125` and `+93`, and a counter chain
;; `((x+1)+1)-? ` must rebase every link onto x. Negative: a two-use mul stays.
(define (opt-affine-test-binop-shape?
  [block : CompilerIrBlock]
  [index : i64]
  [want-dst : i64]
  [want-mul : bool]
  [want-src : i64]
  [want-const : i64]) : bool
  (match block
    [(CompilerIrBlock.Block _ instrs)
      (match (compiler-ir-instr-seq-ref instrs index)
        [(CompilerIrInstr.BinOp dst op lhs rhs _)
          (and
            (= dst want-dst)
            (match op
              [(CompilerIrBinOp.Mul) want-mul]
              [(CompilerIrBinOp.Add) (not want-mul)]
              [_ false])
            (match lhs
              [(CompilerIrValue.Var v) (= v want-src)]
              [_ false])
            (match rhs
              [(CompilerIrValue.I64 k) (= k want-const)]
              [_ false]))]
        [_ false])]))

(define (opt-affine-test-first-block [blocks : CompilerIrBlockList]) : CompilerIrBlock
  (match blocks
    [(CompilerIrBlockList.Cons block _) block]
    [_
      (compiler-ir-block
        (compiler-ir-label "missing")
        (CompilerIrInstrList.Nil))]))

(define (opt-affine-lcg-test-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Mul)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.I64 5)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            3
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 3)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Mul)
              (CompilerIrValue.Var 3)
              (CompilerIrValue.I64 5)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                5
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 4)
                (CompilerIrValue.I64 3)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  6
                  (CompilerIrBinOp.Mul)
                  (CompilerIrValue.Var 5)
                  (CompilerIrValue.I64 5)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    7
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 6)
                    (CompilerIrValue.I64 3)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return
                      (CompilerIrMaybeValue.Some (CompilerIrValue.Var 7)))
                    (CompilerIrInstrList.Nil)))))))))
    (CompilerIrBlockList.Nil)))

(define (opt-affine-counter-test-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          1
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            2
            (CompilerIrBinOp.Add)
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              3
              (CompilerIrBinOp.Sub)
              (CompilerIrValue.Var 2)
              (CompilerIrValue.I64 5)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
              (CompilerIrInstrList.Nil))))))
    (CompilerIrBlockList.Nil)))

;; Var 4 (the mul) feeds TWO adds, so the value-changing pair rewrite must not
;; fire: the mul and both adds stay exactly as written.
(define (opt-affine-two-use-test-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Add)
          (CompilerIrValue.Var 0)
          (CompilerIrValue.I64 3)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            4
            (CompilerIrBinOp.Mul)
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 5)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              5
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 4)
              (CompilerIrValue.I64 7)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                6
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 4)
                (CompilerIrValue.I64 9)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  7
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 5)
                  (CompilerIrValue.Var 6)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 7)))
                  (CompilerIrInstrList.Nil))))))))
    (CompilerIrBlockList.Nil)))

;; Full-pipeline integration fixture: `while (i < n) { acc = acc*5 + 3; i++ }`
;; in SSA form. After optimize-function the x16 unroller versions the loop and
;; the affine pass must collapse the sixteen chained pairs so the unrolled body
;; multiplies by 5^16 = 152587890625 exactly once.
(define (opt-affine-lcg-loop-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "body"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "body")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            2
            (compiler-ir-phi-input-cons
              (CompilerIrValue.I64 0)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 5)
                (compiler-ir-label "body")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              3
              (compiler-ir-phi-input-cons
                (CompilerIrValue.I64 1)
                (compiler-ir-label "entry")
                (compiler-ir-phi-input-cons
                  (CompilerIrValue.Var 7)
                  (compiler-ir-label "body")
                  (CompilerIrPhiInputList.Nil)))
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                6
                (CompilerIrBinOp.Mul)
                (CompilerIrValue.Var 3)
                (CompilerIrValue.I64 5)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  7
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 6)
                  (CompilerIrValue.I64 3)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    5
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 2)
                    (CompilerIrValue.I64 1)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.BinOp
                      8
                      (CompilerIrBinOp.Lt)
                      (CompilerIrValue.Var 5)
                      (CompilerIrValue.Var 0)
                      (AstType.Bool))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Branch
                        (CompilerIrValue.Var 8)
                        (compiler-ir-label "body")
                        (compiler-ir-label "exit"))
                      (CompilerIrInstrList.Nil)))))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "exit")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 7)))
            (CompilerIrInstrList.Nil)))
        (CompilerIrBlockList.Nil)))))

(define (opt-affine-test-seq-count-mul
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [acc : i64]) : i64
  (if (>= index (compiler-ir-instr-seq-count instrs))
    acc
    (opt-affine-test-seq-count-mul
      instrs
      (+ index 1)
      (+
        acc
        (match (compiler-ir-instr-seq-ref instrs index)
          [(CompilerIrInstr.BinOp _ op _ _ _)
            (match op
              [(CompilerIrBinOp.Mul) 1]
              [_ 0])]
          [_ 0])))))

(define (opt-affine-test-seq-has-mul-by?
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [want : i64]) : bool
  (if (>= index (compiler-ir-instr-seq-count instrs))
    false
    (match (compiler-ir-instr-seq-ref instrs index)
      [(CompilerIrInstr.BinOp _ op _ rhs _)
        (match op
          [(CompilerIrBinOp.Mul)
            (match rhs
              [(CompilerIrValue.I64 k)
                (if (= k want)
                  true
                  (opt-affine-test-seq-has-mul-by? instrs (+ index 1) want))]
              [_ (opt-affine-test-seq-has-mul-by? instrs (+ index 1) want)])]
          [_ (opt-affine-test-seq-has-mul-by? instrs (+ index 1) want)])]
      [_ (opt-affine-test-seq-has-mul-by? instrs (+ index 1) want)])))

;; The same recurrence as lowering emits it: a top-tested pre-SSA while loop
;; with Mov writebacks, entering the pipeline before SSA/rotation/unroll.
(define (opt-affine-lcg-while-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "header"))
            (CompilerIrInstrList.Nil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "header")
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            3
            (CompilerIrBinOp.Lt)
            (CompilerIrValue.Var 2)
            (CompilerIrValue.Var 0)
            (AstType.Bool))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Var 3)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            (CompilerIrInstrList.Nil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Mul)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 5)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                5
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 4)
                (CompilerIrValue.I64 3)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Mov 1 (CompilerIrValue.Var 5) (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    6
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 2)
                    (CompilerIrValue.I64 1)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Mov
                      2
                      (CompilerIrValue.Var 6)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Jump (compiler-ir-label "header"))
                      (CompilerIrInstrList.Nil))))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                7
                (CompilerIrBinOp.BitAnd)
                (CompilerIrValue.Var 1)
                (CompilerIrValue.I64 255)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 7)))
                (CompilerIrInstrList.Nil))))
          (CompilerIrBlockList.Nil))))))

(define (opt-affine-pipeline-check
  [optimized : CompilerIrFunction]
  [fail-missing : i64]
  [fail-mul : i64]
  [fail-count : i64]) : i64
  (let
    [blocks : CompilerIrBlockList (opt-function-blocks optimized)]
    (match (opt-cfg-find-block blocks (compiler-ir-label "body__unroll_body"))
      [(OptMaybeBlock.No) fail-missing]
      [(OptMaybeBlock.Some block)
        (match block
          [(CompilerIrBlock.Block _ instrs)
            (cond
              ;; the sixteen chained *5 collapse into one *152587890625 ...
              [(not (opt-affine-test-seq-has-mul-by? instrs 0 152587890625))
                fail-mul]
              ;; ... and DCE drops the orphaned intermediate pairs.
              [(> (opt-affine-test-seq-count-mul instrs 0 0) 1) fail-count]
              [else 42])])])))

(define (compiler-optimize-affine-pipeline-self-test) : i64
  (let
    [ssa-result : i64
      (opt-affine-pipeline-check
        (optimize-function
          (CompilerIrFunction.Function
            (opt-test-symbol "affine_loop_fixture")
            (opt-unroll-test-params)
            (AstType.I64)
            9
            (opt-affine-lcg-loop-blocks)))
        1
        2
        3)]
    [while-result : i64
      (opt-affine-pipeline-check
        (optimize-function
          (CompilerIrFunction.Function
            (opt-test-symbol "affine_while_fixture")
            (opt-unroll-test-params)
            (AstType.I64)
            8
            (opt-affine-lcg-while-blocks)))
        4
        5
        6)]
    (if (= ssa-result 42)
      while-result
      ssa-result)))

(define (compiler-optimize-affine-self-test) : i64
  (let
    [lcg : CompilerIrBlockList
      (opt-affine-fold-blocks 16 (opt-affine-lcg-test-blocks))]
    [lcg-block : CompilerIrBlock (opt-affine-test-first-block lcg)]
    [counter : CompilerIrBlockList
      (opt-affine-fold-blocks 16 (opt-affine-counter-test-blocks))]
    [counter-block : CompilerIrBlock (opt-affine-test-first-block counter)]
    [two-use : CompilerIrBlockList
      (opt-affine-fold-blocks 16 (opt-affine-two-use-test-blocks))]
    [two-use-block : CompilerIrBlock (opt-affine-test-first-block two-use)]
    (cond
      ;; ((x*5+3)*5+3)*5+3 == x*125 + 93: the second pair reads x*25 + 18 ...
      [(not (opt-affine-test-binop-shape? lcg-block 2 4 true 0 25)) 1]
      [(not (opt-affine-test-binop-shape? lcg-block 3 5 false 4 18)) 2]
      ;; ... and the last pair reads x*125 + 93.
      [(not (opt-affine-test-binop-shape? lcg-block 4 6 true 0 125)) 3]
      [(not (opt-affine-test-binop-shape? lcg-block 5 7 false 6 93)) 4]
      ;; (x+1)+1 rebases to x+2; the Sub then folds to x-3 (emitted as Add).
      [(not (opt-affine-test-binop-shape? counter-block 1 2 false 0 2)) 5]
      [(not (opt-affine-test-binop-shape? counter-block 2 3 false 0 (- 0 3))) 6]
      ;; two-use mul: v4 = (x+3)*5 must stay untouched ...
      [(not (opt-affine-test-binop-shape? two-use-block 1 4 true 2 5)) 7]
      ;; ... and both adds keep reading it.
      [(not (opt-affine-test-binop-shape? two-use-block 2 5 false 4 7)) 8]
      [(not (opt-affine-test-binop-shape? two-use-block 3 6 false 4 9)) 9]
      [else 42])))

(define (opt-ssa-unreachable-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Return
          (CompilerIrMaybeValue.Some (CompilerIrValue.I64 1)))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "dead")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.I64 2)))
          (CompilerIrInstrList.Nil)))
      (CompilerIrBlockList.Nil))))

(define (opt-ssa-unreachable-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_unreachable")
    (CompilerIrParamList.Nil)
    (AstType.I64)
    0
    (opt-ssa-unreachable-blocks)))

(define (opt-ssa-bad-phi-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_bad_phi")
    (opt-ssa-cond-params)
    (AstType.I64)
    16
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "then")
            (compiler-ir-label "else"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "then")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "else")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 20) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "join"))
                (CompilerIrInstrList.Nil))))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "join")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Phi
                  3
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.Var 1)
                    (compiler-ir-label "then")
                    (compiler-ir-phi-input-cons
                      (CompilerIrValue.Var 2)
                      (compiler-ir-label "ghost")
                      (CompilerIrPhiInputList.Nil)))
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                  (CompilerIrInstrList.Nil))))
            (CompilerIrBlockList.Nil)))))))

(define (opt-ssa-duplicate-label-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_duplicate_label")
    (CompilerIrParamList.Nil)
    (AstType.I64)
    0
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.I64 1)))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 2)))
            (CompilerIrInstrList.Nil)))
        (CompilerIrBlockList.Nil)))))

(define (opt-ssa-unknown-successor-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_unknown_successor")
    (CompilerIrParamList.Nil)
    (AstType.I64)
    0
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "missing"))
          (CompilerIrInstrList.Nil)))
      (CompilerIrBlockList.Nil))))

(define (opt-ssa-duplicate-def-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_duplicate_def")
    (CompilerIrParamList.Nil)
    (AstType.I64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 1) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 2) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
              (CompilerIrInstrList.Nil)))))
      (CompilerIrBlockList.Nil))))

(define (opt-ssa-out-of-range-def-function [var : i64] [vars : i64]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_out_of_range_def")
    (CompilerIrParamList.Nil)
    (AstType.I64)
    vars
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov var (CompilerIrValue.I64 1) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.I64 1)))
            (CompilerIrInstrList.Nil))))
      (CompilerIrBlockList.Nil))))

(define (opt-ssa-use-before-def-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_use_before_def")
    (CompilerIrParamList.Nil)
    (AstType.I64)
    0
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Return
            (CompilerIrMaybeValue.Some (CompilerIrValue.Var 9)))
          (CompilerIrInstrList.Nil)))
      (CompilerIrBlockList.Nil))))

(define (opt-ssa-dominance-fail-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_dominance_fail")
    (opt-ssa-cond-params)
    (AstType.I64)
    16
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Branch
            (CompilerIrValue.Var 0)
            (compiler-ir-label "then")
            (compiler-ir-label "else"))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "then")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 10) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "else")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "join"))
              (CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "join")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
                (CompilerIrInstrList.Nil)))
            (CompilerIrBlockList.Nil)))))))

(define (compiler-optimize-natural-loop-self-test) : i64
  (let
    [single-index : OptCfgIndex (opt-cfg-index-build (opt-ssa-loop-blocks))]
    [single-loops : OptNaturalLoopList
      (opt-cfg-natural-loops (opt-ssa-loop-blocks))]
    [single : OptMaybeNaturalLoop
      (opt-natural-loop-find
        single-loops
        (compiler-ir-label "loop")
        (compiler-ir-label "body"))]
    [nested-index : OptCfgIndex
      (opt-cfg-index-build (opt-natural-loop-nested-blocks))]
    [nested-loops : OptNaturalLoopList
      (opt-cfg-natural-loops (opt-natural-loop-nested-blocks))]
    [inner : OptMaybeNaturalLoop
      (opt-natural-loop-find
        nested-loops
        (compiler-ir-label "inner")
        (compiler-ir-label "inner-body"))]
    [outer : OptMaybeNaturalLoop
      (opt-natural-loop-find
        nested-loops
        (compiler-ir-label "outer")
        (compiler-ir-label "outer-latch"))]
    [diamond-loops : OptNaturalLoopList
      (opt-cfg-natural-loops (opt-ssa-diamond-blocks))]
    [irreducible-loops : OptNaturalLoopList
      (opt-cfg-natural-loops (opt-natural-loop-irreducible-blocks))]
    [no-preheader-loops : OptNaturalLoopList
      (opt-cfg-natural-loops (opt-natural-loop-no-preheader-blocks))]
    [no-preheader : OptMaybeNaturalLoop
      (opt-natural-loop-find
        no-preheader-loops
        (compiler-ir-label "loop")
        (compiler-ir-label "body"))]
    [multi-index : OptCfgIndex
      (opt-cfg-index-build (opt-natural-loop-multi-backedge-blocks))]
    [multi-loops : OptNaturalLoopList
      (opt-cfg-natural-loops (opt-natural-loop-multi-backedge-blocks))]
    [multi-left : OptMaybeNaturalLoop
      (opt-natural-loop-find
        multi-loops
        (compiler-ir-label "loop")
        (compiler-ir-label "left"))]
    [multi-right : OptMaybeNaturalLoop
      (opt-natural-loop-find
        multi-loops
        (compiler-ir-label "loop")
        (compiler-ir-label "right"))]
    [preheadered-single-blocks : CompilerIrBlockList
      (opt-loop-preheaders-blocks (opt-ssa-loop-blocks))]
    [preheadered-nested-blocks : CompilerIrBlockList
      (opt-loop-preheaders-blocks (opt-natural-loop-nested-blocks))]
    [preheadered-multi-blocks : CompilerIrBlockList
      (opt-loop-preheaders-blocks (opt-natural-loop-multi-backedge-blocks))]
    [synth-blocks : CompilerIrBlockList
      (opt-loop-preheaders-blocks (opt-natural-loop-no-preheader-blocks))]
    [synth-index : OptCfgIndex (opt-cfg-index-build synth-blocks)]
    [synth-loops : OptNaturalLoopList (opt-cfg-natural-loops synth-blocks)]
    [synth-loop : OptMaybeNaturalLoop
      (opt-natural-loop-find
        synth-loops
        (compiler-ir-label "loop")
        (compiler-ir-label "body"))]
    [preheadered-induction : CompilerIrFunction
      (opt-loop-preheaders-function
        (opt-induction-test-function (opt-induction-no-preheader-blocks)))]
    [preheadered-induction-blocks : CompilerIrBlockList
      (opt-function-blocks preheadered-induction)]
    [induction-after-preheader : CompilerIrFunction
      (opt-induction-function preheadered-induction)]
    [induction-after-preheader-blocks : CompilerIrBlockList
      (opt-function-blocks induction-after-preheader)]
    (cond
      [(not (= (opt-natural-loop-list-count single-loops) 1)) 1]
      [(not (= (opt-natural-loop-maybe-body-count single) 2)) 2]
      [(not
          (opt-natural-loop-maybe-body-contains?
            single
            (compiler-ir-label "loop")))
        3]
      [(not
          (opt-natural-loop-maybe-body-contains?
            single
            (compiler-ir-label "body")))
        4]
      [(not
          (opt-natural-loop-maybe-preheader-label?
            single
            (compiler-ir-label "entry")))
        5]
      [(not (= (opt-natural-loop-list-count nested-loops) 2)) 6]
      [(not (= (opt-natural-loop-maybe-body-count inner) 2)) 7]
      [(not
          (opt-natural-loop-maybe-body-contains?
            inner
            (compiler-ir-label "inner")))
        8]
      [(not
          (opt-natural-loop-maybe-body-contains?
            inner
            (compiler-ir-label "inner-body")))
        9]
      [(not
          (opt-natural-loop-maybe-preheader-label?
            inner
            (compiler-ir-label "outer")))
        10]
      [(not (= (opt-natural-loop-maybe-body-count outer) 4)) 11]
      [(not
          (opt-natural-loop-maybe-body-contains?
            outer
            (compiler-ir-label "outer")))
        12]
      [(not
          (opt-natural-loop-maybe-body-contains?
            outer
            (compiler-ir-label "inner")))
        13]
      [(not
          (opt-natural-loop-maybe-body-contains?
            outer
            (compiler-ir-label "inner-body")))
        14]
      [(not
          (opt-natural-loop-maybe-body-contains?
            outer
            (compiler-ir-label "outer-latch")))
        15]
      [(not
          (opt-natural-loop-maybe-preheader-label?
            outer
            (compiler-ir-label "entry")))
        16]
      [(not (= (opt-natural-loop-list-count diamond-loops) 0)) 17]
      [(not (= (opt-natural-loop-list-count irreducible-loops) 0)) 18]
      [(not (= (opt-natural-loop-list-count no-preheader-loops) 1)) 19]
      [(not (= (opt-natural-loop-maybe-body-count no-preheader) 2)) 20]
      [(not (opt-natural-loop-maybe-no-preheader? no-preheader)) 21]
      [(not (= (opt-natural-loop-list-count multi-loops) 2)) 22]
      [(not (= (opt-natural-loop-maybe-body-count multi-left) 2)) 23]
      [(not
          (opt-natural-loop-maybe-body-contains?
            multi-left
            (compiler-ir-label "left")))
        24]
      [(not
          (opt-natural-loop-maybe-body-contains?
            multi-left
            (compiler-ir-label "loop")))
        25]
      [(not (= (opt-natural-loop-maybe-body-count multi-right) 2)) 26]
      [(not
          (opt-natural-loop-maybe-body-contains?
            multi-right
            (compiler-ir-label "right")))
        27]
      [(not
          (opt-natural-loop-maybe-body-contains?
            multi-right
            (compiler-ir-label "loop")))
        28]
      [(not (= (opt-natural-loop-maybe-body-block-count single) 2)) 29]
      [(not
          (opt-natural-loop-maybe-body-block-label-at?
            single
            0
            (compiler-ir-label "loop")))
        30]
      [(not
          (opt-natural-loop-maybe-body-block-label-at?
            single
            1
            (compiler-ir-label "body")))
        31]
      [(not
          (opt-natural-loop-maybe-body-contains-id?
            single-index
            single
            (compiler-ir-label "loop")))
        32]
      [(not
          (opt-natural-loop-maybe-body-contains-id?
            single-index
            single
            (compiler-ir-label "body")))
        33]
      [(opt-natural-loop-maybe-body-contains-id?
          single-index
          single
          (compiler-ir-label "entry"))
        34]
      [(not (= (opt-natural-loop-maybe-body-block-count outer) 4)) 35]
      [(not
          (opt-natural-loop-maybe-body-block-label-at?
            outer
            0
            (compiler-ir-label "outer")))
        36]
      [(not
          (opt-natural-loop-maybe-body-block-label-at?
            outer
            1
            (compiler-ir-label "inner")))
        37]
      [(not
          (opt-natural-loop-maybe-body-block-label-at?
            outer
            2
            (compiler-ir-label "inner-body")))
        38]
      [(not
          (opt-natural-loop-maybe-body-block-label-at?
            outer
            3
            (compiler-ir-label "outer-latch")))
        39]
      [(not
          (opt-natural-loop-maybe-body-contains-id?
            nested-index
            outer
            (compiler-ir-label "outer-latch")))
        40]
      [(not (= (opt-natural-loop-maybe-body-block-count multi-left) 2)) 41]
      [(not
          (opt-natural-loop-maybe-body-block-label-at?
            multi-left
            0
            (compiler-ir-label "loop")))
        43]
      [(not
          (opt-natural-loop-maybe-body-block-label-at?
            multi-left
            1
            (compiler-ir-label "left")))
        44]
      [(not (= (opt-natural-loop-maybe-body-block-count multi-right) 2)) 45]
      [(not
          (opt-natural-loop-maybe-body-block-label-at?
            multi-right
            0
            (compiler-ir-label "loop")))
        46]
      [(not
          (opt-natural-loop-maybe-body-block-label-at?
            multi-right
            1
            (compiler-ir-label "right")))
        47]
      [(not
          (opt-natural-loop-maybe-body-contains-id?
            multi-index
            multi-right
            (compiler-ir-label "right")))
        48]
      [(not (opt-block-list-eq preheadered-single-blocks (opt-ssa-loop-blocks)))
        49]
      [(not
          (opt-block-list-eq
            preheadered-nested-blocks
            (opt-natural-loop-nested-blocks)))
        50]
      [(not
          (opt-block-list-eq
            preheadered-multi-blocks
            (opt-natural-loop-multi-backedge-blocks)))
        51]
      [(not (= (compiler-ir-block-list-count synth-blocks) 7)) 52]
      [(not
          (opt-block-list-has-label?
            synth-blocks
            (compiler-ir-label "loop__preheader")))
        53]
      [(not
          (opt-natural-loop-maybe-preheader-label?
            synth-loop
            (compiler-ir-label "loop__preheader")))
        54]
      [(not
          (opt-label-contains
            (opt-cfg-index-successors synth-index (compiler-ir-label "pre-one"))
            (compiler-ir-label "loop__preheader")))
        55]
      [(opt-label-contains
          (opt-cfg-index-successors synth-index (compiler-ir-label "pre-one"))
          (compiler-ir-label "loop"))
        56]
      [(not
          (opt-label-contains
            (opt-cfg-index-successors
              synth-index
              (compiler-ir-label "loop__preheader"))
            (compiler-ir-label "loop")))
        57]
      [(not
          (opt-verify-ok?
            (opt-verify-function (opt-cfg-test-function synth-blocks))))
        58]
      [(not (opt-verify-ok? (opt-verify-function preheadered-induction))) 59]
      [(not
          (opt-block-list-has-label?
            preheadered-induction-blocks
            (compiler-ir-label "loop__preheader")))
        60]
      [(not
          (=
            (opt-count-mul-label-blocks
              induction-after-preheader-blocks
              (compiler-ir-label "body"))
            0))
        61]
      [else 42])))

(define (compiler-optimize-loop-rotation-self-test) : i64
  (let
    [raw : CompilerIrBlockList (opt-loop-rotation-top-test-blocks)]
    [rotated : CompilerIrBlockList (opt-loop-rotation-blocks raw)]
    [false-body-rotated : CompilerIrBlockList
      (opt-loop-rotation-blocks (opt-loop-rotation-false-body-blocks))]
    [ssa : CompilerIrFunction
      (opt-ssa-construct-function (opt-cfg-test-function rotated))]
    [ssa-blocks : CompilerIrBlockList (opt-function-blocks ssa)]
    [optimized : CompilerIrFunction
      (optimize-function (opt-cfg-test-function raw))]
    [optimized-blocks : CompilerIrBlockList (opt-function-blocks optimized)]
    [no-preheader : CompilerIrBlockList (opt-natural-loop-no-preheader-blocks)]
    [multi-backedge : CompilerIrBlockList
      (opt-natural-loop-multi-backedge-blocks)]
    [with-phi : CompilerIrBlockList (opt-ssa-loop-blocks)]
    (cond
      [(not (= (compiler-ir-block-list-count rotated) 3)) 1]
      [(opt-block-list-has-label? rotated (compiler-ir-label "loop")) 2]
      [(not
          (opt-loop-rotation-successors?
            rotated
            (compiler-ir-label "entry")
            (compiler-ir-label "body")
            (compiler-ir-label "exit")))
        3]
      [(not
          (opt-loop-rotation-successors?
            rotated
            (compiler-ir-label "body")
            (compiler-ir-label "body")
            (compiler-ir-label "exit")))
        4]
      [(not (= (opt-count-jump-to-blocks rotated (compiler-ir-label "loop")) 0))
        5]
      [(not (= (opt-count-branches-blocks rotated) 2)) 6]
      [(opt-block-list-has-label? false-body-rotated (compiler-ir-label "loop"))
        7]
      [(not
          (opt-loop-rotation-successors?
            false-body-rotated
            (compiler-ir-label "entry")
            (compiler-ir-label "body")
            (compiler-ir-label "exit")))
        8]
      [(not (opt-verify-ok? (opt-verify-function ssa))) 9]
      [(not (> (opt-count-phi-blocks ssa-blocks) 0)) 10]
      [(opt-block-list-has-label? optimized-blocks (compiler-ir-label "loop"))
        11]
      [(not (opt-cfg-successor-targets-known? optimized-blocks)) 12]
      [(not
          (opt-block-list-eq
            (opt-loop-rotation-blocks no-preheader)
            no-preheader))
        13]
      [(not
          (opt-block-list-eq
            (opt-loop-rotation-blocks multi-backedge)
            multi-backedge))
        14]
      [(not (opt-block-list-eq (opt-loop-rotation-blocks with-phi) with-phi))
        15]
      [else 42])))

;; Nested-loop SSA fixture: the inner-loop counter/accumulator phis at the
;; OUTER header have no definition on the function-entry path. Before the
;; dead-path zero-input fix in opt-ssa-phi-inputs, materialization named the
;; ORIGINAL var on those inputs, the use-before-definition verify rejected the
;; result, and SSA construction silently fell back -- disabling every SSA-gated
;; pass (GVN, load-GVN, preheaders, LICM, induction, loop-BCE) for any function
;; containing a nested loop. The fixture mirrors a lowered nested array-sum:
;; handle-field geps/loads in the inner body must hoist once SSA succeeds.
(define (opt-ssa-nested-loop-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "rounds" (AstType.I64) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "n" (AstType.I64) 1)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "arr" (AstType.DynArray 0) 2)
        (CompilerIrParamList.Nil)))))

(define (opt-ssa-nested-loop-inner-body) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      10
      (CompilerIrValue.Var 2)
      (CompilerIrValue.I64 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 11 (CompilerIrValue.Var 10) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          12
          (CompilerIrValue.Var 2)
          (CompilerIrValue.I64 0)
          (AstType.U8))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 13 (CompilerIrValue.Var 12) (AstType.U64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              14
              (CompilerIrValue.Var 13)
              (CompilerIrValue.Var 5)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 15 (CompilerIrValue.Var 14) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  16
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 3)
                  (CompilerIrValue.Var 15)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    19
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 16)
                    (CompilerIrValue.Var 11)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Mov
                      3
                      (CompilerIrValue.Var 19)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.BinOp
                        17
                        (CompilerIrBinOp.Add)
                        (CompilerIrValue.Var 5)
                        (CompilerIrValue.I64 1)
                        (AstType.I64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Mov
                          5
                          (CompilerIrValue.Var 17)
                          (AstType.I64))
                        (compiler-ir-instr-cons
                          (CompilerIrInstr.Jump
                            (compiler-ir-label "inner_head"))
                          (CompilerIrInstrList.Nil))))))))))))))

(define (opt-ssa-nested-loop-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "ssa_nested_loop")
    (opt-ssa-nested-loop-params)
    (AstType.I64)
    32
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 3 (CompilerIrValue.I64 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov 4 (CompilerIrValue.I64 0) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "outer_head"))
              (CompilerIrInstrList.Nil)))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "outer_head")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              6
              (CompilerIrBinOp.Lt)
              (CompilerIrValue.Var 4)
              (CompilerIrValue.Var 0)
              (AstType.Bool))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Var 6)
                (compiler-ir-label "outer_body")
                (compiler-ir-label "exit"))
              (CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "outer_body")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov 5 (CompilerIrValue.I64 0) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "inner_head"))
                (CompilerIrInstrList.Nil))))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "inner_head")
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  7
                  (CompilerIrBinOp.Lt)
                  (CompilerIrValue.Var 5)
                  (CompilerIrValue.Var 1)
                  (AstType.Bool))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Branch
                    (CompilerIrValue.Var 7)
                    (compiler-ir-label "inner_body")
                    (compiler-ir-label "outer_latch"))
                  (CompilerIrInstrList.Nil))))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "inner_body")
                (opt-ssa-nested-loop-inner-body))
              (compiler-ir-block-cons
                (compiler-ir-block
                  (compiler-ir-label "outer_latch")
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.BinOp
                      18
                      (CompilerIrBinOp.Add)
                      (CompilerIrValue.Var 4)
                      (CompilerIrValue.I64 1)
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Mov
                        4
                        (CompilerIrValue.Var 18)
                        (AstType.I64))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Jump (compiler-ir-label "outer_head"))
                        (CompilerIrInstrList.Nil)))))
                (compiler-ir-block-cons
                  (compiler-ir-block
                    (compiler-ir-label "exit")
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Return
                        (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                      (CompilerIrInstrList.Nil)))
                  (CompilerIrBlockList.Nil))))))))))

;; Fixture for the post-SSA rotation pass: `entry` is the single-successor
;; preheader, `header` carries one loop phi plus a pure guard and the loop
;; branch, `body` increments the phi, `latch` jumps back unconditionally, and
;; `exit` returns the phi (exercising the exit-phi path). With `side-exit`
;; the body branches straight to `exit`, which must reject the rotation.
(define (opt-rotate-ssa-test-blocks [side-exit : bool]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "header"))
        (CompilerIrInstrList.Nil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "header")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Phi
            1
            (compiler-ir-phi-input-cons
              (CompilerIrValue.I64 0)
              (compiler-ir-label "entry")
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 2)
                (compiler-ir-label "latch")
                (CompilerIrPhiInputList.Nil)))
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              3
              (CompilerIrBinOp.Lt)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.Var 0)
              (AstType.Bool))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Var 3)
                (compiler-ir-label "body")
                (compiler-ir-label "exit"))
              (CompilerIrInstrList.Nil)))))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              2
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 1)
              (AstType.I64))
            (if side-exit
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Bool true)
                  (compiler-ir-label "latch")
                  (compiler-ir-label "exit"))
                (CompilerIrInstrList.Nil))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "latch"))
                (CompilerIrInstrList.Nil)))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "latch")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "header"))
              (CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "exit")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
                (CompilerIrInstrList.Nil)))
            (CompilerIrBlockList.Nil)))))))

(define (opt-rotate-ssa-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "rotate_ssa")
    (compiler-ir-param-cons
      (CompilerIrParam.Param "n" (AstType.I64) 0)
      (CompilerIrParamList.Nil))
    (AstType.I64)
    4
    blocks))

(define (opt-rotate-ssa-test-run [side-exit : bool]) : CompilerIrFunction
  (let
    [blocks : CompilerIrBlockList (opt-rotate-ssa-test-blocks side-exit)]
    (match (opt-rotate-ssa-function-with-context-result
      (opt-cfg-context-build blocks)
      false
      (opt-rotate-ssa-test-function blocks))
      [(OptFunctionCtxResult.Result next _) next])))

(define (opt-rotate-ssa-test-starts-with-phi?
  [blocks : CompilerIrBlockList]
  [label : i64]) : bool
  (match (opt-cfg-find-block blocks label)
    [(OptMaybeBlock.No) false]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (if (<= (compiler-ir-instr-seq-count instrs) 0)
            false
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.Phi _ _ _) true]
              [_ false]))])]))

(define (opt-rotate-ssa-test-single-jump-to?
  [blocks : CompilerIrBlockList]
  [label : i64]
  [target : i64]) : bool
  (match (opt-cfg-find-block blocks label)
    [(OptMaybeBlock.No) false]
    [(OptMaybeBlock.Some block)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (if (= (compiler-ir-instr-seq-count instrs) 1)
            (match (compiler-ir-instr-seq-ref instrs 0)
              [(CompilerIrInstr.Jump jump-target) (= jump-target target)]
              [_ false])
            false)])]))

(define (compiler-optimize-rotate-ssa-self-test) : i64
  (let
    [rotated : CompilerIrFunction (opt-rotate-ssa-test-run false)]
    [rotated-blocks : CompilerIrBlockList (opt-function-blocks rotated)]
    [side-exit : CompilerIrFunction (opt-rotate-ssa-test-run true)]
    [side-exit-blocks : CompilerIrBlockList (opt-function-blocks side-exit)]
    (cond
      [(not (opt-verify-ok? (opt-verify-function rotated))) 1]
      [(opt-block-list-has-label? rotated-blocks (compiler-ir-label "header"))
        2]
      [(not (= (compiler-ir-block-list-count rotated-blocks) 5)) 3]
      [(not
          (opt-rotate-ssa-test-starts-with-phi?
            rotated-blocks
            (compiler-ir-label "exit")))
        4]
      [(not
          (opt-rotate-ssa-test-starts-with-phi?
            rotated-blocks
            (compiler-ir-label "body")))
        5]
      [(not
          (opt-rotate-ssa-test-single-jump-to?
            rotated-blocks
            (compiler-ir-label "header__rotate_land")
            (compiler-ir-label "body")))
        6]
      [(not (> (opt-function-frame rotated) 4)) 7]
      [(not
          (opt-block-list-eq side-exit-blocks (opt-rotate-ssa-test-blocks true)))
        8]
      [(not (= (compiler-ir-block-list-count side-exit-blocks) 5)) 9]
      [(not
          (opt-block-list-has-label?
            side-exit-blocks
            (compiler-ir-label "header")))
        10]
      [else 42])))

(define (compiler-optimize-ssa-self-test) : i64
  (let
    [diamond-blocks : CompilerIrBlockList (opt-ssa-diamond-blocks)]
    [diamond-index : OptCfgIndex (opt-cfg-index-build diamond-blocks)]
    [diamond-doms : OptDomInfo (opt-cfg-dominators diamond-blocks)]
    [then-frontier : OptLabelSet
      (opt-cfg-dominance-frontier diamond-blocks (compiler-ir-label "then"))]
    [else-frontier : OptLabelSet
      (opt-cfg-dominance-frontier diamond-blocks (compiler-ir-label "else"))]
    [loop-blocks : CompilerIrBlockList (opt-ssa-loop-blocks)]
    [loop-index : OptCfgIndex (opt-cfg-index-build loop-blocks)]
    [loop-doms : OptDomInfo (opt-cfg-dominators loop-blocks)]
    [loop-frontier : OptLabelSet
      (opt-cfg-dominance-frontier loop-blocks (compiler-ir-label "loop"))]
    [unreachable-index : OptCfgIndex
      (opt-cfg-index-build (opt-ssa-unreachable-blocks))]
    [unreachable-order : CompilerIrBlockList
      (opt-cfg-reachable-block-order (opt-ssa-unreachable-blocks))]
    [constructed-diamond : CompilerIrFunction
      (opt-ssa-construct-function (opt-ssa-construct-diamond-function))]
    [constructed-diamond-blocks : CompilerIrBlockList
      (opt-function-blocks constructed-diamond)]
    [constructed-loop : CompilerIrFunction
      (opt-ssa-construct-function (opt-ssa-construct-loop-function))]
    [constructed-loop-blocks : CompilerIrBlockList
      (opt-function-blocks constructed-loop)]
    [constructed-param : CompilerIrFunction
      (opt-ssa-construct-function (opt-ssa-construct-mutated-param-function))]
    [constructed-param-blocks : CompilerIrBlockList
      (opt-function-blocks constructed-param)]
    [address-taken : CompilerIrFunction
      (opt-ssa-construct-address-taken-function)]
    [address-taken-out : CompilerIrFunction
      (opt-ssa-construct-function address-taken)]
    [existing-phi : CompilerIrFunction
      (opt-cfg-test-function (opt-cfg-phi-blocks))]
    [existing-phi-out : CompilerIrFunction
      (opt-ssa-construct-function existing-phi)]
    [pipeline-loop : CompilerIrFunction
      (optimize-function-once (opt-ssa-construct-loop-function))]
    [pipeline-loop-blocks : CompilerIrBlockList
      (opt-function-blocks pipeline-loop)]
    [entry-backedge : CompilerIrFunction (opt-ssa-entry-backedge-function)]
    [entry-backedge-out : CompilerIrFunction
      (opt-ssa-construct-function entry-backedge)]
    [constructed-nested : CompilerIrFunction
      (opt-ssa-construct-function (opt-ssa-nested-loop-function))]
    [constructed-nested-blocks : CompilerIrBlockList
      (opt-function-blocks constructed-nested)]
    [pipeline-nested : CompilerIrFunction
      (optimize-function-once (opt-ssa-nested-loop-function))]
    [pipeline-nested-blocks : CompilerIrBlockList
      (opt-function-blocks pipeline-nested)]
    (cond
      [(not
          (=
            (opt-label-count
              (opt-cfg-predecessors diamond-blocks (compiler-ir-label "join")))
            2))
        1]
      [(not (= (opt-cfg-index-block-count diamond-index) 4)) 2]
      [(not (opt-verify-ok? (opt-verify-function (opt-ssa-diamond-function))))
        3]
      [(not
          (opt-label-set-eq?
            (opt-cfg-index-predecessors
              diamond-index
              (compiler-ir-label "join"))
            (opt-cfg-predecessors-scan
              diamond-blocks
              (compiler-ir-label "join"))))
        4]
      [(not
          (opt-label-set-eq?
            (opt-cfg-index-successors diamond-index (compiler-ir-label "entry"))
            (opt-cfg-blocks-successors-scan
              diamond-blocks
              (compiler-ir-label "entry"))))
        5]
      [(not (= (struct-get unreachable-index reach-count) 1)) 6]
      [(not
          (opt-cfg-index-reachable?
            unreachable-index
            (compiler-ir-label "entry")))
        7]
      [(opt-cfg-index-reachable? unreachable-index (compiler-ir-label "dead"))
        8]
      [(not
          (=
            (opt-cfg-index-rpo-label unreachable-index 0)
            (compiler-ir-label "entry")))
        9]
      [(not
          (= (opt-cfg-index-rpo-label loop-index 0) (compiler-ir-label "entry")))
        10]
      [(not
          (opt-dom-dominates?
            diamond-doms
            (compiler-ir-label "entry")
            (compiler-ir-label "join")))
        11]
      [(opt-dom-dominates?
          diamond-doms
          (compiler-ir-label "then")
          (compiler-ir-label "join"))
        12]
      [(not (opt-label-contains then-frontier (compiler-ir-label "join"))) 13]
      [(not (opt-label-contains else-frontier (compiler-ir-label "join"))) 14]
      [(not
          (opt-dom-dominates?
            loop-doms
            (compiler-ir-label "loop")
            (compiler-ir-label "body")))
        15]
      [(not (opt-label-contains loop-frontier (compiler-ir-label "loop"))) 16]
      [(not (= (compiler-ir-block-list-count unreachable-order) 1)) 17]
      [(not
          (opt-block-list-has-label?
            unreachable-order
            (compiler-ir-label "entry")))
        18]
      [(not (opt-verify-ok? (opt-verify-function (opt-ssa-loop-function)))) 19]
      [(not
          (opt-verify-ok? (opt-verify-function (opt-ssa-unreachable-function))))
        20]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-duplicate-label-function))
            "optimizer verify: duplicate block label"))
        21]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-unknown-successor-function))
            "optimizer verify: unknown successor label"))
        22]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-bad-phi-function))
            "optimizer verify: phi predecessor mismatch"))
        23]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-duplicate-def-function))
            "optimizer verify: duplicate var definition"))
        24]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-use-before-def-function))
            "optimizer verify: use before definition"))
        25]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-dominance-fail-function))
            "optimizer verify: use is not dominated by definition"))
        26]
      [(not
          (=
            (opt-cfg-index-rpo-num
              loop-index
              (opt-cfg-index-rpo-id loop-index 0))
            0))
        27]
      [(not (opt-cfg-dominators-match-legacy? diamond-blocks)) 28]
      [(not (opt-cfg-dominators-match-legacy? loop-blocks)) 29]
      [(not (opt-cfg-dominators-match-legacy? (opt-ssa-unreachable-blocks))) 30]
      [(not
          (opt-cfg-dominators-match-legacy?
            (opt-natural-loop-irreducible-blocks)))
        31]
      [(not (opt-cfg-dominators-match-bitset? diamond-blocks)) 32]
      [(not (opt-cfg-dominators-match-bitset? loop-blocks)) 33]
      [(not (opt-cfg-dominators-match-bitset? (opt-ssa-unreachable-blocks))) 34]
      [(not
          (opt-cfg-dominators-match-bitset?
            (opt-natural-loop-irreducible-blocks)))
        35]
      [(not (opt-verify-ok? (opt-verify-function constructed-diamond))) 36]
      [(not (= (opt-count-phi-blocks constructed-diamond-blocks) 1)) 37]
      [(not (= (opt-count-mov-dst-blocks constructed-diamond-blocks 1) 0)) 38]
      [(not (opt-verify-ok? (opt-verify-function constructed-loop))) 39]
      [(not (= (opt-count-phi-blocks constructed-loop-blocks) 1)) 40]
      [(not (= (opt-count-mov-dst-blocks constructed-loop-blocks 1) 0)) 41]
      [(not (opt-verify-ok? (opt-verify-function constructed-param))) 46]
      [(not (= (opt-count-phi-blocks constructed-param-blocks) 1)) 47]
      [(not (= (opt-count-mov-dst-blocks constructed-param-blocks 0) 0)) 48]
      [(not (opt-function-eq address-taken address-taken-out)) 49]
      [(not (opt-function-eq existing-phi existing-phi-out)) 50]
      [(not (opt-verify-ok? (opt-verify-function pipeline-loop))) 51]
      [(not (= (opt-count-mov-dst-blocks pipeline-loop-blocks 1) 0)) 52]
      [(not (opt-function-eq entry-backedge entry-backedge-out)) 53]
      [(not (opt-verify-ok? (opt-verify-function constructed-nested))) 54]
      [(not (> (opt-count-phi-blocks constructed-nested-blocks) 0)) 55]
      [(not (opt-verify-ok? (opt-verify-function pipeline-nested))) 56]
      [(not
          (=
            (opt-count-load-label-blocks
              pipeline-nested-blocks
              (compiler-ir-label "inner_body"))
            1))
        57]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-out-of-range-def-function -1 1))
            "optimizer verify: duplicate var definition"))
        58]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-out-of-range-def-function 1 1))
            "optimizer verify: duplicate var definition"))
        59]
      [else 42])))

(define (compiler-optimize-cfg-self-test) : i64
  (let
    [constant-if : CompilerIrBlockList
      (opt-cfg-simplify-blocks (opt-cfg-constant-if-blocks))]
    [loop-guard : CompilerIrBlockList
      (opt-cfg-simplify-blocks (opt-cfg-loop-guard-blocks))]
    [phi-cfg : CompilerIrBlockList
      (opt-cfg-simplify-blocks (opt-cfg-phi-blocks))]
    [folded-edge-phi : CompilerIrBlockList
      (opt-cfg-simplify-blocks (opt-cfg-folded-edge-phi-blocks))]
    [phi-blocks : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function (opt-cfg-test-function (opt-cfg-phi-blocks))))]
    [trap-blocks : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function (opt-cfg-test-function (opt-cfg-trap-path-blocks))))]
    [fallthrough-blocks : CompilerIrBlockList
      (opt-cfg-simplify-blocks (opt-cfg-fallthrough-prune-blocks))]
    [bool-branch-result : OptBlockListPassResult
      (opt-bool-branch-fuse-blocks
        (opt-bool-branch-test-blocks
          (CompilerIrInstr.BinOp
            1
            (CompilerIrBinOp.Eq)
            (CompilerIrValue.I64 1)
            (CompilerIrValue.I64 2)
            (AstType.Bool))
          false)
        16
        16)]
    [bool-branch-blocks : CompilerIrBlockList
      (match bool-branch-result
        [(OptBlockListPassResult.Result blocks _) blocks])]
    [bool-branch-changed : bool
      (match bool-branch-result
        [(OptBlockListPassResult.Result _ changed) changed])]
    [call-branch-result : OptBlockListPassResult
      (opt-bool-branch-fuse-blocks
        (opt-bool-branch-test-blocks
          (CompilerIrInstr.Call
            1
            (opt-test-symbol "predicate")
            (CompilerIrCallArgs.Nil)
            (AstType.Bool))
          false)
        16
        16)]
    [call-branch-blocks : CompilerIrBlockList
      (match call-branch-result
        [(OptBlockListPassResult.Result blocks _) blocks])]
    [call-branch-changed : bool
      (match call-branch-result
        [(OptBlockListPassResult.Result _ changed) changed])]
    [reused-branch-result : OptBlockListPassResult
      (opt-bool-branch-fuse-blocks
        (opt-bool-branch-test-blocks
          (CompilerIrInstr.BinOp
            1
            (CompilerIrBinOp.Eq)
            (CompilerIrValue.I64 1)
            (CompilerIrValue.I64 2)
            (AstType.Bool))
          true)
        16
        16)]
    [reused-branch-blocks : CompilerIrBlockList
      (match reused-branch-result
        [(OptBlockListPassResult.Result blocks _) blocks])]
    [reused-branch-changed : bool
      (match reused-branch-result
        [(OptBlockListPassResult.Result _ changed) changed])]
    [constant-phi-source : CompilerIrBlockList
      (opt-bool-branch-constant-phi-blocks)]
    [constant-phi-function : CompilerIrFunction
      (opt-bool-branch-constant-test-function constant-phi-source)]
    [constant-phi-result : OptFunctionPassResult
      (opt-bool-branch-function-with-context-result
        (opt-cfg-context-build constant-phi-source)
        false
        constant-phi-function)]
    [constant-phi-optimized : CompilerIrFunction
      (match constant-phi-result
        [(OptFunctionPassResult.Result func _) func])]
    [constant-phi-changed : bool
      (match constant-phi-result
        [(OptFunctionPassResult.Result _ changed) changed])]
    [constant-phi-blocks : CompilerIrBlockList
      (opt-function-blocks constant-phi-optimized)]
    [nonconstant-phi-source : CompilerIrBlockList
      (opt-bool-branch-nonconstant-phi-blocks)]
    [nonconstant-phi-function : CompilerIrFunction
      (opt-bool-branch-constant-test-function nonconstant-phi-source)]
    [nonconstant-phi-result : OptFunctionPassResult
      (opt-bool-branch-function-with-context-result
        (opt-cfg-context-build nonconstant-phi-source)
        false
        nonconstant-phi-function)]
    [nonconstant-phi-optimized : CompilerIrFunction
      (match nonconstant-phi-result
        [(OptFunctionPassResult.Result func _) func])]
    [nonconstant-phi-changed : bool
      (match nonconstant-phi-result
        [(OptFunctionPassResult.Result _ changed) changed])]
    [multi-phi-source : CompilerIrBlockList (opt-bool-branch-multi-phi-blocks)]
    [multi-phi-function : CompilerIrFunction
      (opt-bool-branch-constant-test-function multi-phi-source)]
    [multi-phi-result : OptFunctionPassResult
      (opt-bool-branch-function-with-context-result
        (opt-cfg-context-build multi-phi-source)
        false
        multi-phi-function)]
    [multi-phi-optimized : CompilerIrFunction
      (match multi-phi-result
        [(OptFunctionPassResult.Result func _) func])]
    [multi-phi-changed : bool
      (match multi-phi-result
        [(OptFunctionPassResult.Result _ changed) changed])]
    [and-chain-result : OptFunctionPassResult
      (opt-bool-branch-chain-test-run 0)]
    [and-chain-function : CompilerIrFunction
      (match and-chain-result
        [(OptFunctionPassResult.Result func _) func])]
    [and-chain-blocks : CompilerIrBlockList
      (opt-function-blocks and-chain-function)]
    [and-chain-changed : bool
      (match and-chain-result
        [(OptFunctionPassResult.Result _ changed) changed])]
    [and-chain-reused-result : OptFunctionPassResult
      (opt-bool-branch-chain-test-run 1)]
    [and-chain-reused-function : CompilerIrFunction
      (match and-chain-reused-result
        [(OptFunctionPassResult.Result func _) func])]
    [and-chain-reused-changed : bool
      (match and-chain-reused-result
        [(OptFunctionPassResult.Result _ changed) changed])]
    [and-chain-or-result : OptFunctionPassResult
      (opt-bool-branch-chain-test-run 2)]
    [and-chain-or-function : CompilerIrFunction
      (match and-chain-or-result
        [(OptFunctionPassResult.Result func _) func])]
    [and-chain-or-changed : bool
      (match and-chain-or-result
        [(OptFunctionPassResult.Result _ changed) changed])]
    (begin
      (unless (= (compiler-ir-block-list-count constant-if) 2) (return 1))
      (unless
        (not (opt-block-list-has-label? constant-if (compiler-ir-label "else")))
        (return 2))
      (unless
        (= (opt-count-jump-to-blocks constant-if (compiler-ir-label "then")) 1)
        (return 3))
      (unless (= (opt-count-branches-blocks constant-if) 0) (return 4))
      (unless (= (compiler-ir-block-list-count loop-guard) 3) (return 5))
      (unless
        (not (opt-block-list-has-label? loop-guard (compiler-ir-label "body")))
        (return 6))
      (unless
        (= (opt-count-jump-to-blocks loop-guard (compiler-ir-label "exit")) 1)
        (return 7))
      (unless (= (compiler-ir-block-list-count phi-blocks) 3) (return 8))
      (unless
        (not (opt-block-list-has-label? phi-blocks (compiler-ir-label "else")))
        (return 9))
      (unless (= (opt-count-phi-blocks phi-blocks) 0) (return 10))
      (unless (= (opt-count-mov-dst-blocks phi-cfg 3) 1) (return 11))
      (unless (= (compiler-ir-block-list-count trap-blocks) 3) (return 12))
      (unless
        (opt-block-list-has-label? trap-blocks (compiler-ir-label "trap"))
        (return 13))
      (unless (= (opt-count-branches-blocks trap-blocks) 1) (return 14))
      (unless (opt-cfg-fallthrough-prune-ok? fallthrough-blocks) (return 15))
      (unless (opt-cfg-switch-successors-ok?) (return 16))
      (unless (opt-cfg-index-numbering-ok?) (return 40))
      (unless bool-branch-changed (return 17))
      (unless
        (not
          (opt-block-list-has-label?
            bool-branch-blocks
            (compiler-ir-label "merge")))
        (return 18))
      (unless (= (opt-count-branches-blocks bool-branch-blocks) 2) (return 19))
      (unless (not call-branch-changed) (return 20))
      (unless
        (opt-block-list-has-label?
          call-branch-blocks
          (compiler-ir-label "merge"))
        (return 21))
      (unless (= (opt-count-branches-blocks call-branch-blocks) 2) (return 22))
      (unless
        (opt-verify-ok?
          (opt-verify-function
            (opt-bool-branch-test-function bool-branch-blocks)))
        (return 23))
      (unless
        (opt-verify-ok?
          (opt-verify-function
            (opt-bool-branch-test-function call-branch-blocks)))
        (return 24))
      (unless (not reused-branch-changed) (return 25))
      (unless
        (opt-block-list-has-label?
          reused-branch-blocks
          (compiler-ir-label "merge"))
        (return 26))
      (unless
        (opt-verify-ok?
          (opt-verify-function
            (opt-bool-branch-test-function reused-branch-blocks)))
        (return 27))
      (unless (= (opt-count-phi-blocks folded-edge-phi) 0) (return 28))
      (unless (= (opt-count-mov-dst-blocks folded-edge-phi 1) 1) (return 29))
      (unless
        (opt-verify-ok?
          (opt-verify-function (opt-cfg-test-function folded-edge-phi)))
        (return 30))
      (unless constant-phi-changed (return 31))
      (unless
        (not
          (opt-block-list-has-label?
            constant-phi-blocks
            (compiler-ir-label "merge")))
        (return 32))
      (unless
        (=
          (opt-count-jump-to-blocks
            constant-phi-blocks
            (compiler-ir-label "yes"))
          2)
        (return 33))
      (unless
        (=
          (opt-count-jump-to-blocks
            constant-phi-blocks
            (compiler-ir-label "no"))
          1)
        (return 34))
      (unless (= (opt-count-phi-blocks constant-phi-blocks) 1) (return 35))
      (unless
        (opt-bool-branch-first-phi-has-label?
          constant-phi-blocks
          (compiler-ir-label "yes")
          (compiler-ir-label "true-left"))
        (return 36))
      (unless
        (opt-bool-branch-first-phi-has-label?
          constant-phi-blocks
          (compiler-ir-label "yes")
          (compiler-ir-label "true-right"))
        (return 37))
      (unless
        (opt-verify-ok? (opt-verify-function constant-phi-optimized))
        (return 38))
      (unless (not nonconstant-phi-changed) (return 39))
      (unless
        (opt-block-list-has-label?
          (opt-function-blocks nonconstant-phi-optimized)
          (compiler-ir-label "merge"))
        (return 40))
      (unless
        (opt-function-eq nonconstant-phi-function nonconstant-phi-optimized)
        (return 41))
      (unless (not multi-phi-changed) (return 42))
      (unless
        (and
          (opt-block-list-has-label?
            (opt-function-blocks multi-phi-optimized)
            (compiler-ir-label "merge"))
          (= (opt-count-phi-blocks (opt-function-blocks multi-phi-optimized)) 2)
          (opt-function-eq multi-phi-function multi-phi-optimized))
        (return 43))
      (unless
        (and
          (opt-verify-ok? (opt-verify-function nonconstant-phi-optimized))
          (opt-verify-ok? (opt-verify-function multi-phi-optimized)))
        (return 44))
      (unless and-chain-changed (return 46))
      (unless (= (compiler-ir-block-list-count and-chain-blocks) 5) (return 47))
      (unless (= (opt-count-branches-blocks and-chain-blocks) 3) (return 48))
      (unless
        (= (opt-count-binop-op-blocks and-chain-blocks (CompilerIrBinOp.And)) 0)
        (return 49))
      (unless
        (and
          (opt-bool-branch-chain-compare-branch-block?
            and-chain-blocks
            (compiler-ir-label "entry"))
          (opt-bool-branch-chain-compare-branch-block?
            and-chain-blocks
            (compiler-ir-label "entry__bool_and.0"))
          (opt-bool-branch-chain-compare-branch-block?
            and-chain-blocks
            (compiler-ir-label "entry__bool_and.1")))
        (return 50))
      (unless
        (and
          (opt-bool-branch-first-phi-has-label?
            and-chain-blocks
            (compiler-ir-label "yes")
            (compiler-ir-label "entry__bool_and.1"))
          (not
            (opt-bool-branch-first-phi-has-label?
              and-chain-blocks
              (compiler-ir-label "yes")
              (compiler-ir-label "entry")))
          (opt-bool-branch-first-phi-has-label?
            and-chain-blocks
            (compiler-ir-label "no")
            (compiler-ir-label "entry"))
          (opt-bool-branch-first-phi-has-label?
            and-chain-blocks
            (compiler-ir-label "no")
            (compiler-ir-label "entry__bool_and.0"))
          (opt-bool-branch-first-phi-has-label?
            and-chain-blocks
            (compiler-ir-label "no")
            (compiler-ir-label "entry__bool_and.1")))
        (return 51))
      (unless
        (opt-verify-ok? (opt-verify-function and-chain-function))
        (return 52))
      (unless
        (and
          (not and-chain-reused-changed)
          (opt-function-eq
            and-chain-reused-function
            (opt-bool-branch-chain-test-function
              (opt-bool-branch-chain-test-blocks 1))))
        (return 53))
      (unless
        (and
          (not and-chain-or-changed)
          (opt-function-eq
            and-chain-or-function
            (opt-bool-branch-chain-test-function
              (opt-bool-branch-chain-test-blocks 2))))
        (return 54))
      42)))

(define (compiler-optimize-fixed-point-self-test) : i64
  (let
    [func : CompilerIrFunction (opt-test-function (opt-fixed-point-instrs))]
    [once : CompilerIrFunction (optimize-function-once func)]
    [fixed : CompilerIrFunction (optimize-function func)]
    [once-instrs : CompilerIrInstrList (opt-function-first-instrs once)]
    [fixed-instrs : CompilerIrInstrList (opt-function-first-instrs fixed)]
    [optimized-program : CompilerIrProgram
      (optimize-program-with-level
        (opt-test-program (opt-fixed-point-instrs))
        3)]
    [again-program : CompilerIrProgram
      (optimize-program-with-level optimized-program 3)]
    (cond
      [(not (= (compiler-ir-instr-list-count once-instrs) 4)) 1]
      [(not (= (opt-count-arith-instrs once-instrs) 3)) 2]
      [(not (= (compiler-ir-instr-list-count fixed-instrs) 3)) 3]
      [(not (= (opt-count-arith-instrs fixed-instrs) 2)) 4]
      [(not (opt-program-eq optimized-program again-program)) 5]
      [else 42])))

;; --- implicit scratch-region self-tests -------------------------------------
(define (opt-scratch-test-alloc) : CompilerIrInstr
  (CompilerIrInstr.Call
    1
    cbi.compiler-builtin-id-tl-alloc
    (CompilerIrCallArgs.One (CompilerIrValue.I64 32))
    (AstType.U64)))

(define (opt-scratch-test-ir-alloc) : CompilerIrInstr
  (CompilerIrInstr.Alloc 1 (AstType.I64)))

(define (opt-scratch-test-return-zero) : CompilerIrInstr
  (CompilerIrInstr.Return (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0))))

(define (opt-scratch-test-one-block [middle : CompilerIrInstr]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-scratch-test-alloc)
    (compiler-ir-instr-cons
      middle
      (compiler-ir-instr-cons
        (opt-scratch-test-return-zero)
        CompilerIrInstrList.Nil))))

(define (opt-scratch-positive-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-scratch-test-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        2
        (CompilerIrValue.Var 1)
        (CompilerIrValue.I64 0)
        (AstType.U64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 2)
          (CompilerIrValue.I64 7)
          (AstType.U64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.U64))
          (compiler-ir-instr-cons
            (opt-scratch-test-return-zero)
            CompilerIrInstrList.Nil))))))

(define (opt-scratch-loop-candidate-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
        CompilerIrInstrList.Nil))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "loop")
        (compiler-ir-instr-cons
          (opt-scratch-test-alloc)
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Bool true)
              (compiler-ir-label "body")
              (compiler-ir-label "exit"))
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "body")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "loop"))
            CompilerIrInstrList.Nil))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "exit")
            (compiler-ir-instr-cons
              (opt-scratch-test-return-zero)
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(define (opt-scratch-loop-list-has-candidate? [loops : OptNaturalLoopList]) : bool
  (match loops
    [(OptNaturalLoopList.Nil) false]
    [(OptNaturalLoopList.Cons loop rest)
      (or
        (opt-scratch-report-candidate?
          (opt-scratch-scope-report-blocks (opt-natural-loop-body-blocks loop))
          1
          32)
        (opt-scratch-loop-list-has-candidate? (box-get rest)))]))

(define (opt-scratch-reset-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "scratch_reset_test")
    CompilerIrParamList.Nil
    (AstType.I64)
    10
    blocks))

(define (opt-scratch-reset-header-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Branch
      (CompilerIrValue.Bool true)
      (compiler-ir-label "body")
      (compiler-ir-label "exit"))
    CompilerIrInstrList.Nil))

(define (opt-scratch-reset-body-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-scratch-test-ir-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Jump (compiler-ir-label "loop"))
      CompilerIrInstrList.Nil)))

(define (opt-scratch-reset-unknown-alloc) : CompilerIrInstr
  (CompilerIrInstr.Call
    1
    cbi.compiler-builtin-id-tl-alloc
    (CompilerIrCallArgs.One (CompilerIrValue.Var 0))
    (AstType.U64)))

(define (opt-scratch-reset-unknown-body-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-scratch-reset-unknown-alloc)
    (compiler-ir-instr-cons
      (CompilerIrInstr.Jump (compiler-ir-label "loop"))
      CompilerIrInstrList.Nil)))

(define (opt-scratch-reset-blocks-with-body [body-instrs : CompilerIrInstrList]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "preheader"))
        CompilerIrInstrList.Nil))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "preheader")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "loop")
          (opt-scratch-reset-header-instrs))
        (compiler-ir-block-cons
          (compiler-ir-block (compiler-ir-label "body") body-instrs)
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "exit")
              (compiler-ir-instr-cons
                (opt-scratch-test-return-zero)
                CompilerIrInstrList.Nil))
            CompilerIrBlockList.Nil))))))

(define (opt-scratch-reset-positive-blocks) : CompilerIrBlockList
  (opt-scratch-reset-blocks-with-body (opt-scratch-reset-body-instrs)))

(define (opt-scratch-reset-level-blocks) : CompilerIrBlockList
  (opt-scratch-reset-blocks-with-body (opt-scratch-reset-unknown-body-instrs)))

(define (opt-scratch-reset-level-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (opt-test-symbol "main")
    (compiler-ir-param-cons
      (CompilerIrParam.Param "n" (AstType.I64) 0)
      CompilerIrParamList.Nil)
    (AstType.I64)
    10
    (opt-scratch-reset-level-blocks)))

(define (opt-scratch-reset-level-program) : CompilerIrProgram
  (CompilerIrProgram.Program
    (CompilerIrGlobalList.Nil)
    (compiler-ir-function-cons
      (opt-scratch-reset-level-function)
      (CompilerIrFunctionList.Nil))
    (CompilerIrExternList.Nil)))

(define (opt-scratch-reset-call-blocked-blocks) : CompilerIrBlockList
  (opt-scratch-reset-blocks-with-body
    (compiler-ir-instr-cons
      (opt-scratch-test-ir-alloc)
      (compiler-ir-instr-cons
        (CompilerIrInstr.Call
          2
          (opt-test-symbol "touch")
          (CompilerIrCallArgs.Nil)
          (AstType.Unit))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          CompilerIrInstrList.Nil)))))

(define (opt-scratch-reset-header-alloc-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "preheader"))
        CompilerIrInstrList.Nil))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "preheader")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "loop")
          (compiler-ir-instr-cons
            (opt-scratch-test-ir-alloc)
            (opt-scratch-reset-header-instrs)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "body")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "exit")
              (compiler-ir-instr-cons
                (opt-scratch-test-return-zero)
                CompilerIrInstrList.Nil))
            CompilerIrBlockList.Nil))))))

(define (opt-scratch-reset-early-exit-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      (compiler-ir-label "entry")
      (compiler-ir-instr-cons
        (CompilerIrInstr.Jump (compiler-ir-label "preheader"))
        CompilerIrInstrList.Nil))
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "preheader")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
          CompilerIrInstrList.Nil))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "loop")
          (opt-scratch-reset-header-instrs))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "body")
            (compiler-ir-instr-cons
              (opt-scratch-test-ir-alloc)
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Bool true)
                  (compiler-ir-label "ret")
                  (compiler-ir-label "latch"))
                CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "latch")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                CompilerIrInstrList.Nil))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "ret")
                (compiler-ir-instr-cons
                  (opt-scratch-test-return-zero)
                  CompilerIrInstrList.Nil))
              (compiler-ir-block-cons
                (compiler-ir-block
                  (compiler-ir-label "exit")
                  (compiler-ir-instr-cons
                    (opt-scratch-test-return-zero)
                    CompilerIrInstrList.Nil))
                CompilerIrBlockList.Nil))))))))

(define (opt-scratch-reset-rewrite [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (opt-scratch-reset-function (opt-scratch-reset-test-function blocks)))

(define (opt-scratch-reset-call-count
  [func : CompilerIrFunction]
  [name : String]) : i64
  (opt-count-direct-call-name-blocks (opt-function-blocks func) name))

(define (opt-scratch-reset-level-program-call-count
  [level : i64]
  [name : String]) : i64
  (match (optimize-program-with-level (opt-scratch-reset-level-program) level)
    [(CompilerIrProgram.Program _ functions _)
      (match (opt-function-list-find functions "main")
        [(OptMaybeFunction.No) (- 0 1)]
        [(OptMaybeFunction.Some func) (opt-scratch-reset-call-count func name)])]))

(define (opt-scratch-reset-emitted? [func : CompilerIrFunction]) : bool
  (and
    (= (opt-scratch-reset-call-count func "tl_region_mark") 1)
    (= (opt-scratch-reset-call-count func "tl_region_reset") 1)))

(define (opt-scratch-reset-not-emitted? [func : CompilerIrFunction]) : bool
  (and
    (= (opt-scratch-reset-call-count func "tl_region_mark") 0)
    (= (opt-scratch-reset-call-count func "tl_region_reset") 0)))

(define (opt-scratch-reset-runtime-ids-canonical?) : bool
  (match (opt-scratch-reset-mark-instr 10)
    [(CompilerIrInstr.Call _ mark-id _ _)
      (match (opt-scratch-reset-reset-instr 11 10)
        [(CompilerIrInstr.Call _ reset-id _ _)
          (and
            (= mark-id cbi.compiler-builtin-id-tl-region-mark)
            (= reset-id cbi.compiler-builtin-id-tl-region-reset))]
        [_ false])]
    [_ false]))

(define (compiler-optimize-scratch-region-self-test) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [positive : OptScratchScopeReport
        (opt-scratch-scope-report-instrs (opt-scratch-positive-instrs))]
      [loop-positive : bool
        (opt-scratch-loop-list-has-candidate?
          (opt-cfg-natural-loops (opt-scratch-loop-candidate-blocks)))]
      [call-blocked : OptScratchScopeReport
        (opt-scratch-scope-report-instrs
          (opt-scratch-test-one-block
            (CompilerIrInstr.Call
              9
              (opt-test-symbol "touch")
              (CompilerIrCallArgs.Nil)
              (AstType.Unit))))]
      [extern-blocked : OptScratchScopeReport
        (opt-scratch-scope-report-instrs
          (opt-scratch-test-one-block
            (CompilerIrInstr.CallIndirectC
              9
              (CompilerIrValue.Function (opt-test-symbol "ffi_touch"))
              (CompilerIrCallArgs.Nil)
              (AstType.I64))))]
      [raw-blocked : OptScratchScopeReport
        (opt-scratch-scope-report-instrs
          (opt-scratch-test-one-block (CompilerIrInstr.AddrOf 2 1)))]
      ;; The scratch analysis records its roots with `opt-alias-mark-unique`, so
      ;; the fixture builds the fact the same way instead of hand-encoding it.
      [store-blocked : OptScratchScopeReport
        (let
          [roots : OptScratchRootList
            (opt-scratch-root-list-add (OptScratchRootList.Nil) 1)]
          (OptScratchScopeReport.Report
            1
            32
            (opt-scratch-blocker-reason
              roots
              (opt-alias-mark-unique (opt-alias-empty) 1 0)
              (CompilerIrInstr.StorePtr
                (CompilerIrValue.Var 99)
                (CompilerIrValue.Var 1)
                (AstType.U64)))))]
      [arena-blocked : OptScratchScopeReport
        (opt-scratch-scope-report-instrs
          (opt-scratch-test-one-block
            (CompilerIrInstr.Call
              9
              cbi.compiler-builtin-id-tl-region-mark
              (CompilerIrCallArgs.Nil)
              (AstType.I64))))]
      [return-blocked : OptScratchScopeReport
        (let
          [roots : OptScratchRootList
            (opt-scratch-root-list-add (OptScratchRootList.Nil) 1)]
          (OptScratchScopeReport.Report
            1
            32
            (opt-scratch-blocker-reason
              roots
              (opt-alias-mark-unique (opt-alias-empty) 1 0)
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1))))))]
      [reset-positive : CompilerIrFunction
        (opt-scratch-reset-rewrite (opt-scratch-reset-positive-blocks))]
      [reset-call-blocked : CompilerIrFunction
        (opt-scratch-reset-rewrite (opt-scratch-reset-call-blocked-blocks))]
      [reset-header-alloc : CompilerIrFunction
        (opt-scratch-reset-rewrite (opt-scratch-reset-header-alloc-blocks))]
      [reset-early-exit : CompilerIrFunction
        (opt-scratch-reset-rewrite (opt-scratch-reset-early-exit-blocks))]
      [reset-pre-ssa : CompilerIrFunction
        (match (opt-scratch-reset-pre-ssa-function-with-context-result
          (opt-scratch-reset-level-function))
          [(OptFunctionCtxResult.Result f _) f])]
      [level0-mark-count : i64
        (opt-scratch-reset-level-program-call-count 0 "tl_region_mark")]
      [level0-reset-count : i64
        (opt-scratch-reset-level-program-call-count 0 "tl_region_reset")]
      [level1-mark-count : i64
        (opt-scratch-reset-level-program-call-count 1 "tl_region_mark")]
      [level1-reset-count : i64
        (opt-scratch-reset-level-program-call-count 1 "tl_region_reset")]
      [level2-mark-count : i64
        (opt-scratch-reset-level-program-call-count 2 "tl_region_mark")]
      [level2-reset-count : i64
        (opt-scratch-reset-level-program-call-count 2 "tl_region_reset")]
      (cond
        [(not (opt-scratch-report-candidate? positive 1 32)) 1]
        [(not loop-positive) 2]
        [(not (opt-scratch-report-blocked? call-blocked 1 32 "call")) 3]
        [(not (opt-scratch-report-blocked? extern-blocked 1 32 "extern_call"))
          4]
        [(not (opt-scratch-report-blocked? raw-blocked 1 32 "raw_pointer")) 5]
        [(not (opt-scratch-report-blocked? store-blocked 1 32 "store_outer")) 6]
        [(not (opt-scratch-report-blocked? arena-blocked 1 32 "arena_helper"))
          7]
        [(not (opt-scratch-report-blocked? return-blocked 1 32 "return_escape"))
          8]
        [(not (opt-scratch-reset-emitted? reset-positive)) 9]
        [(not (= (opt-function-frame reset-positive) 12)) 10]
        [(not (opt-scratch-reset-not-emitted? reset-call-blocked)) 11]
        [(not (opt-scratch-reset-not-emitted? reset-header-alloc)) 12]
        [(not (opt-scratch-reset-not-emitted? reset-early-exit)) 13]
        [(not (opt-scratch-reset-emitted? reset-pre-ssa)) 14]
        [(not (= level0-mark-count 0)) 15]
        [(not (= level0-reset-count 0)) 16]
        [(not (= level1-mark-count 0)) 17]
        [(not (= level1-reset-count 0)) 18]
        [(not (= level2-mark-count 1)) 19]
        [(not (= level2-reset-count 1)) 20]
        [(not (opt-scratch-reset-runtime-ids-canonical?)) 21]
        [else 42]))))

;; --- noalias fact model self-test -------------------------------------------
(define (opt-alias-test-unique-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 8)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.BinOp
          2
          (CompilerIrBinOp.Add)
          (CompilerIrValue.I64 1)
          (CompilerIrValue.I64 2)
          (AstType.I64))
        (CompilerIrInstrList.Nil)))))

(define (opt-alias-test-transitive-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 8)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          2
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 8)
          (AstType.I64))
        (CompilerIrInstrList.Nil)))))

(define (opt-alias-test-load-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 1 (CompilerIrValue.Var 0) (AstType.I64))
      (CompilerIrInstrList.Nil))))

(define (opt-alias-test-store-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.StorePtr
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 5)
        (AstType.I64))
      (CompilerIrInstrList.Nil))))

(define (opt-alias-test-call-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call
        9
        (opt-test-symbol "tl_noop")
        (CompilerIrCallArgs.Nil)
        (AstType.I64))
      (CompilerIrInstrList.Nil))))

(define (opt-alias-test-copy-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 1 (CompilerIrValue.Var 0) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 7) (AstType.I64))
        (CompilerIrInstrList.Nil)))))

(define (opt-alias-join-facts-a) : OptAliasFacts
  (opt-alias-bind
    (opt-alias-bind
      (opt-alias-bind (opt-alias-empty) 0 (OptAliasKind.Unique 0))
      1
      (OptAliasKind.Derived 0))
    2
    (OptAliasKind.MayAlias)))

(define (opt-alias-join-facts-b) : OptAliasFacts
  (opt-alias-bind
    (opt-alias-bind
      (opt-alias-bind (opt-alias-empty) 0 (OptAliasKind.Unique 0))
      1
      (OptAliasKind.MayAlias))
    3
    (OptAliasKind.Unique 0)))

(define (opt-alias-sample-store) : CompilerIrInstr
  (CompilerIrInstr.StorePtr
    (CompilerIrValue.Var 0)
    (CompilerIrValue.I64 5)
    (AstType.I64)))

(define (opt-alias-sample-tail-call) : CompilerIrInstr
  (CompilerIrInstr.TailCall
    (opt-test-symbol "tl_noop")
    (CompilerIrCallArgs.Nil)
    (AstType.I64)))

(define (opt-alias-sample-binop) : CompilerIrInstr
  (CompilerIrInstr.BinOp
    9
    (CompilerIrBinOp.Add)
    (CompilerIrValue.I64 1)
    (CompilerIrValue.I64 2)
    (AstType.I64)))

(define (compiler-optimize-alias-self-test) : i64
  (let
    [unique : OptAliasFacts
      (opt-alias-run (opt-alias-empty) (opt-alias-test-unique-instrs))]
    [transitive : OptAliasFacts
      (opt-alias-run (opt-alias-empty) (opt-alias-test-transitive-instrs))]
    [loaded : OptAliasFacts
      (opt-alias-run (opt-alias-empty) (opt-alias-test-load-instrs))]
    [stored : OptAliasFacts
      (opt-alias-run (opt-alias-empty) (opt-alias-test-store-instrs))]
    [called : OptAliasFacts
      (opt-alias-run (opt-alias-empty) (opt-alias-test-call-instrs))]
    [copied : OptAliasFacts
      (opt-alias-run (opt-alias-empty) (opt-alias-test-copy-instrs))]
    [joined : OptAliasFacts
      (opt-alias-intersect (opt-alias-join-facts-a) (opt-alias-join-facts-b))]
    [invalidated : OptAliasFacts
      (opt-alias-mark-invalidated
        (opt-alias-mark-unique (opt-alias-empty) 0 0)
        0)]
    [seeded : OptAliasFacts
      (opt-alias-seed-params (opt-load-cse-mixed-ref-params))]
    (cond
      [(not (opt-alias-contains? unique 0 (OptAliasKind.Unique 0))) 1]
      [(not (opt-alias-contains? unique 1 (OptAliasKind.Derived 0))) 2]
      [(not (opt-alias-absent? unique 2)) 3]
      [(not (= (opt-alias-facts-len unique) 2)) 4]
      [(not (opt-alias-contains? transitive 2 (OptAliasKind.Derived 0))) 5]
      [(not (opt-alias-contains? loaded 0 (OptAliasKind.Unique 0))) 6]
      [(not (opt-alias-contains? loaded 1 (OptAliasKind.MayAlias))) 7]
      [(not (= (opt-alias-facts-len stored) 0)) 8]
      [(not (opt-alias-instr-clears-all? (opt-alias-sample-store))) 9]
      [(not (= (opt-alias-facts-len called) 0)) 10]
      [(not (opt-alias-instr-clears-all? (opt-alias-sample-tail-call))) 11]
      [(not (opt-alias-contains? copied 1 (OptAliasKind.Derived 0))) 12]
      [(not (opt-alias-contains? copied 2 (OptAliasKind.MayAlias))) 13]
      [(not (= (opt-alias-facts-len joined) 1)) 14]
      [(not (opt-alias-contains? joined 0 (OptAliasKind.Unique 0))) 15]
      [(opt-alias-contains? joined 1 (OptAliasKind.Derived 0)) 16]
      [(opt-alias-instr-clears-all? (opt-alias-sample-binop)) 17]
      [(not (opt-alias-contains? invalidated 0 (OptAliasKind.Invalidated))) 18]
      [(not (opt-alias-contains? seeded 0 (OptAliasKind.SharedRef))) 19]
      [(not (opt-alias-contains? seeded 1 (OptAliasKind.ExclusiveRef))) 20]
      ;; Allocation epochs survive the packed encoding, distinguish otherwise
      ;; identical Unique roots, and the retired -1 code stays conservative.
      [(not
          (opt-alias-kind-eq
            (opt-alias-kind-decode
              (opt-alias-kind-encode (OptAliasKind.Unique 7)))
            (OptAliasKind.Unique 7)))
        21]
      [(opt-alias-kind-eq (OptAliasKind.Unique 0) (OptAliasKind.Unique 1)) 22]
      [(not
          (opt-alias-kind-eq
            (opt-alias-kind-decode -1)
            (OptAliasKind.Invalidated)))
        23]
      [else 42])))

(define (opt-load-cse-run [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (opt-load-cse-instrs
    (opt-load-header-set-empty)
    (opt-load-cse-empty-state-for-size (compiler-ir-instr-list-count instrs))
    instrs))

;; Run with header-typed handle params (vars 0 and 1 are (Array i64)
;; descriptors) so the descriptor/element granularity rules can be exercised.
(define (opt-load-cse-run-with-array-param [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (opt-load-cse-instrs
    (opt-load-header-set-from-function
      (compiler-ir-param-cons
        (CompilerIrParam.Param "xs" (AstType.DynArray 0) 0)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "ys" (AstType.DynArray 0) 1)
          (CompilerIrParamList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block (compiler-ir-label "entry") instrs)
        (CompilerIrBlockList.Nil)))
    (opt-load-cse-empty-state-for-size (compiler-ir-instr-list-count instrs))
    instrs))

(define (opt-load-cse-run-with-params
  [params : CompilerIrParamList]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (opt-load-cse-instrs
    (opt-load-header-set-from-function
      params
      (compiler-ir-block-cons
        (compiler-ir-block (compiler-ir-label "entry") instrs)
        (CompilerIrBlockList.Nil)))
    (opt-load-cse-state-with-caps-and-facts
      (opt-load-cse-table-cap-for-size (compiler-ir-instr-list-count instrs))
      (opt-load-cse-kinds-cap-for-size (compiler-ir-instr-list-count instrs))
      (opt-alias-seed-params params))
    instrs))

(define (opt-load-cse-run-with-params-and-call-memory
  [params : CompilerIrParamList]
  [call-memory : opt_i64_i64_map.Map]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (opt-load-cse-instrs-from
    (opt-load-header-set-from-function
      params
      (compiler-ir-block-cons
        (compiler-ir-block (compiler-ir-label "entry") instrs)
        (CompilerIrBlockList.Nil)))
    (opt_i64_i64_map.with-capacity 1)
    call-memory
    (opt-load-cse-state-with-caps-and-facts
      (opt-load-cse-table-cap-for-size (compiler-ir-instr-list-count instrs))
      (opt-load-cse-kinds-cap-for-size (compiler-ir-instr-list-count instrs))
      (opt-alias-seed-params params))
    instrs))

(define (opt-load-cse-mixed-ref-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "read" (ast-ty-ref 0 (AstType.I64)) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "write" (ast-ty-mut-ref 0 (AstType.I64)) 1)
      (CompilerIrParamList.Nil))))

(define (opt-load-cse-shared-ref-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "left" (ast-ty-ref 0 (AstType.I64)) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "right" (ast-ty-ref 0 (AstType.I64)) 1)
      (CompilerIrParamList.Nil))))

(define (opt-load-cse-exclusive-ref-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param "left" (ast-ty-mut-ref 0 (AstType.I64)) 0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "right" (ast-ty-mut-ref 0 (AstType.I64)) 1)
      (CompilerIrParamList.Nil))))

(define (opt-load-cse-descriptor-ref-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (CompilerIrParam.Param
      "xs"
      (ast-ty-mut-ref 0 (ast-ty-dyn-array (AstType.I64)))
      0)
    (compiler-ir-param-cons
      (CompilerIrParam.Param "write" (ast-ty-mut-ref 0 (AstType.I64)) 1)
      (CompilerIrParamList.Nil))))

(define (opt-dead-store-run-with-array-param [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (compiler-ir-instr-seq-to-list
    (opt-dead-store-instr-seq
      (opt-load-header-set-from-function
        (compiler-ir-param-cons
          (CompilerIrParam.Param "xs" (AstType.DynArray 0) 0)
          (compiler-ir-param-cons
            (CompilerIrParam.Param "ys" (AstType.DynArray 0) 1)
            (CompilerIrParamList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block (compiler-ir-label "entry") instrs)
          (CompilerIrBlockList.Nil)))
      (compiler-ir-instr-seq-from-list instrs))))

(define (opt-count-mov-dst-i64-src
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [src : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.Mov mov-dst mov-src _)
            (if (= mov-dst dst)
              (match mov-src
                [(CompilerIrValue.I64 value)
                  (if (= value src)
                    1
                    0)]
                [_ 0])
              0)]
          [_ 0])
        (opt-count-mov-dst-i64-src (box-get rest) dst src))]))

(define (opt-count-mov-dst-var-src
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [src : i64]
  [ty : AstType]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.Mov mov-dst mov-src mov-ty)
            (if (and (= mov-dst dst) (opt-type-eq mov-ty ty))
              (match mov-src
                [(CompilerIrValue.Var value)
                  (if (= value src)
                    1
                    0)]
                [_ 0])
              0)]
          [_ 0])
        (opt-count-mov-dst-var-src (box-get rest) dst src ty))]))

(define (opt-count-mov-dst-bool-src
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [src : bool]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.Mov mov-dst mov-src mov-ty)
            (if (and (= mov-dst dst) (opt-type-eq mov-ty (AstType.Bool)))
              (match mov-src
                [(CompilerIrValue.Bool value)
                  (if (= value src)
                    1
                    0)]
                [_ 0])
              0)]
          [_ 0])
        (opt-count-mov-dst-bool-src (box-get rest) dst src))]))

(define (opt-count-storeptr-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.StorePtr _ _ _) 1]
          [_ 0])
        (opt-count-storeptr-instrs (box-get rest)))]))

(define (opt-count-storeptr-i64-value
  [instrs : CompilerIrInstrList]
  [want : i64]) : i64
  (match instrs
    [(CompilerIrInstrList.Nil) 0]
    [(CompilerIrInstrList.Cons instr rest)
      (+
        (match instr
          [(CompilerIrInstr.StorePtr _ value ty)
            (if (opt-type-eq ty (AstType.I64))
              (match value
                [(CompilerIrValue.I64 actual)
                  (if (= actual want)
                    1
                    0)]
                [_ 0])
              0)]
          [_ 0])
        (opt-count-storeptr-i64-value (box-get rest) want))]))

(define (opt-dead-store-overwritten-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.StorePtr
        (CompilerIrValue.Var 2)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 2)
          (CompilerIrValue.I64 2)
          (AstType.I64))
        (CompilerIrInstrList.Nil)))))

(define (opt-dead-store-load-blocked-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.StorePtr
        (CompilerIrValue.Var 2)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 2)
            (AstType.I64))
          (CompilerIrInstrList.Nil))))))

(define (opt-dead-store-disjoint-field-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        3
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 2)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 2)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 3)
            (CompilerIrValue.I64 9)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 2)
              (CompilerIrValue.I64 2)
              (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

(define (opt-dead-store-call-blocked-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.StorePtr
        (CompilerIrValue.Var 2)
        (CompilerIrValue.I64 1)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Call
          4
          (opt-test-symbol "touch")
          (CompilerIrCallArgs.Nil)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 2)
            (CompilerIrValue.I64 2)
            (AstType.I64))
          (CompilerIrInstrList.Nil))))))

(define (compiler-optimize-dead-store-self-test) : i64
  (let
    [overwritten : CompilerIrInstrList
      (opt-dead-store-run-with-array-param (opt-dead-store-overwritten-instrs))]
    [load-blocked : CompilerIrInstrList
      (opt-dead-store-run-with-array-param (opt-dead-store-load-blocked-instrs))]
    [disjoint-field : CompilerIrInstrList
      (opt-dead-store-run-with-array-param
        (opt-dead-store-disjoint-field-instrs))]
    [call-blocked : CompilerIrInstrList
      (opt-dead-store-run-with-array-param (opt-dead-store-call-blocked-instrs))]
    [pipeline : CompilerIrBlock
      (optimize-block
        (compiler-ir-block
          (compiler-ir-label "entry")
          (opt-dead-store-overwritten-instrs)))]
    [pipeline-instrs : CompilerIrInstrList
      (match pipeline
        [(CompilerIrBlock.Block _ instrs)
          (compiler-ir-instr-seq-to-list instrs)])]
    (cond
      [(not (= (opt-count-storeptr-instrs overwritten) 1)) 1]
      [(not (= (opt-count-storeptr-i64-value overwritten 2) 1)) 2]
      [(not (= (opt-count-storeptr-i64-value overwritten 1) 0)) 3]
      [(not (= (opt-count-storeptr-instrs load-blocked) 2)) 4]
      [(not (= (opt-count-load-instrs load-blocked) 1)) 5]
      [(not (= (opt-count-storeptr-instrs disjoint-field) 2)) 6]
      [(not (= (opt-count-storeptr-i64-value disjoint-field 9) 1)) 7]
      [(not (= (opt-count-storeptr-i64-value disjoint-field 2) 1)) 8]
      [(not (= (opt-count-storeptr-instrs call-blocked) 2)) 9]
      [(not (= (opt-count-storeptr-instrs pipeline-instrs) 1)) 10]
      [else 42])))

(define (opt-load-cse-positive-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            4
            (CompilerIrBinOp.Add)
            (CompilerIrValue.I64 1)
            (CompilerIrValue.I64 2)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

(define (opt-load-cse-barrier-instrs [barrier : CompilerIrInstr]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          barrier
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

(define (opt-load-cse-address-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 7) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

(define (opt-load-cse-result-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 7) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

(define (opt-load-cse-type-mismatch-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.Bool))
          (CompilerIrInstrList.Nil))))))

(define (opt-load-cse-different-address-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          4
          (CompilerIrValue.Var 0)
          (CompilerIrValue.I64 8)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 3 (CompilerIrValue.Var 4) (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

(define (opt-load-cse-vector-data-pointer-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Load 2 (CompilerIrValue.Var 0) (AstType.U64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.VectorLoad
        4
        (CompilerIrValue.Var 2)
        (CompilerIrValue.Var 1)
        4
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 3 (CompilerIrValue.Var 0) (AstType.U64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.VectorLoad
            5
            (CompilerIrValue.Var 3)
            (CompilerIrValue.Var 1)
            4
            (AstType.I64))
          (CompilerIrInstrList.Nil))))))

(define (opt-load-cse-barrier-blocked? [barrier : CompilerIrInstr]) : bool
  (let
    [optimized : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-barrier-instrs barrier))]
    (and
      (= (opt-count-load-instrs optimized) 2)
      (= (opt-count-mov-dst-instrs optimized 3) 0))))

;; GAP4: store-to-load forwarding -- the load after the store becomes a Mov of
;; the stored literal (and the pre-store entry is provably dropped: the Mov's
;; source is 9, not var 2).
(define (opt-load-cse-store-forward-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 1)
            (CompilerIrValue.I64 9)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

;; Sub-word constant stores forward only after normalizing to the load type.
(define (opt-load-cse-subword-const-forward-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I32))
      (compiler-ir-instr-cons
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 7)
          (AstType.I32))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I32))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              3
              (CompilerIrValue.Var 0)
              (CompilerIrValue.I64 4)
              (AstType.Bool))
            (compiler-ir-instr-cons
              (CompilerIrInstr.StorePtr
                (CompilerIrValue.Var 3)
                (CompilerIrValue.Bool true)
                (AstType.Bool))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 4 (CompilerIrValue.Var 3) (AstType.Bool))
                (CompilerIrInstrList.Nil)))))))))

;; A value read by a same-type sub-word load is canonical and can be forwarded.
(define (opt-load-cse-subword-load-forward-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I32))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I32))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 1)
            (CompilerIrValue.Var 2)
            (AstType.I32))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 3 (CompilerIrValue.Var 1) (AstType.I32))
            (CompilerIrInstrList.Nil)))))))

;; Arbitrary sub-word vars are still not known canonical and must reload.
(define (opt-load-cse-subword-unknown-var-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I32))
      (compiler-ir-instr-cons
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 1)
          (CompilerIrValue.Var 9)
          (AstType.I32))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I32))
          (CompilerIrInstrList.Nil))))))

;; GAP4: canonical keys -- two DISTINCT gep temps of the same (base, offset)
;; slot must CSE (the audit's bounds-chain miss shape).
(define (opt-load-cse-canonical-gep-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            3
            (CompilerIrValue.Var 0)
            (CompilerIrValue.I64 0)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 4 (CompilerIrValue.Var 3) (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

;; GAP4: an ELEMENT store (through the loaded data pointer) must keep
;; descriptor-field entries; the re-load through a FRESH len gep still hits.
;; Var 0 is a header-typed param (opt-load-cse-run-with-array-param).
(define (opt-load-cse-element-store-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          4
          (CompilerIrValue.Var 0)
          (CompilerIrValue.I64 0)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 5 (CompilerIrValue.Var 4) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              6
              (CompilerIrValue.Var 5)
              (CompilerIrValue.I64 2)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.StorePtr
                (CompilerIrValue.Var 6)
                (CompilerIrValue.I64 7)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Gep
                  7
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.I64 1)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Load 8 (CompilerIrValue.Var 7) (AstType.I64))
                  (CompilerIrInstrList.Nil))))))))))

;; GAP4: an element store MUST drop element-load entries (same buffer).
(define (opt-load-cse-element-invalidate-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 0)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          4
          (CompilerIrValue.Var 3)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 5 (CompilerIrValue.Var 4) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              6
              (CompilerIrValue.Var 3)
              (CompilerIrValue.I64 2)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.StorePtr
                (CompilerIrValue.Var 6)
                (CompilerIrValue.I64 7)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 7 (CompilerIrValue.Var 4) (AstType.I64))
                (CompilerIrInstrList.Nil)))))))))

;; GAP4 MUST-INVALIDATE: a descriptor-field store through ANOTHER handle (var
;; 1) may alias var 0's descriptor -- the len re-load must stay a load.
(define (opt-load-cse-other-base-store-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          4
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 1)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 4)
            (CompilerIrValue.I64 5)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 6 (CompilerIrValue.Var 2) (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

;; GAP4: same base, provably disjoint byte ranges (data slot store vs len
;; entry) -- the len entry survives.
(define (opt-load-cse-same-base-disjoint-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          4
          (CompilerIrValue.Var 0)
          (CompilerIrValue.I64 0)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 4)
            (CompilerIrValue.I64 5)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 6 (CompilerIrValue.Var 2) (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

(define (opt-load-cse-copybytes-forward-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            3
            (CompilerIrValue.Var 0)
            (CompilerIrValue.I64 1)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.CopyBytes
              (CompilerIrValue.Var 3)
              (CompilerIrValue.Var 1)
              8)
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                4
                (CompilerIrValue.Var 0)
                (CompilerIrValue.I64 1)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 5 (CompilerIrValue.Var 4) (AstType.I64))
                (CompilerIrInstrList.Nil)))))))))

(define (opt-load-cse-copybytes-overlap-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 0 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        1
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I8))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 2 (CompilerIrValue.Var 1) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            3
            (CompilerIrValue.Var 0)
            (CompilerIrValue.I64 4)
            (AstType.I8))
          (compiler-ir-instr-cons
            (CompilerIrInstr.CopyBytes
              (CompilerIrValue.Var 3)
              (CompilerIrValue.Var 1)
              8)
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                4
                (CompilerIrValue.Var 0)
                (CompilerIrValue.I64 4)
                (AstType.I8))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 5 (CompilerIrValue.Var 4) (AstType.I64))
                (CompilerIrInstrList.Nil)))))))))

(define (opt-load-cse-disjoint-checked-root-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 0)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          4
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 4)
            (CompilerIrValue.I64 9)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 5 (CompilerIrValue.Var 2) (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

(define (opt-load-cse-same-checked-root-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 0)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          4
          (CompilerIrValue.Var 0)
          (CompilerIrValue.I64 0)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.StorePtr
            (CompilerIrValue.Var 4)
            (CompilerIrValue.I64 9)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 5 (CompilerIrValue.Var 2) (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

(define (opt-load-cse-fresh-tl-alloc-root-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Call
      4
      cbi.compiler-builtin-id-tl-alloc
      (CompilerIrCallArgs.Nil)
      (AstType.U64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        5
        (CompilerIrValue.Var 4)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          2
          (CompilerIrValue.Var 0)
          (CompilerIrValue.I64 0)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 5)
              (CompilerIrValue.I64 9)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 6 (CompilerIrValue.Var 2) (AstType.I64))
              (CompilerIrInstrList.Nil))))))))

;; Fresh-allocation epoch rule: var 0 carries no alias fact, so the cached load
;; of var 2 has a NoRoot key that root-identity disjointness cannot save. It was
;; still cached BEFORE var 4 was allocated, so the store through var 4's storage
;; provably misses it and the re-load forwards.
(define (opt-load-cse-fresh-alloc-epoch-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 0)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Alloc 4 (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            5
            (CompilerIrValue.Var 4)
            (CompilerIrValue.I64 0)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 5)
              (CompilerIrValue.I64 9)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 6 (CompilerIrValue.Var 2) (AstType.I64))
              (CompilerIrInstrList.Nil))))))))

;; Same shape with the allocation moved FIRST: the cached load now happens in
;; var 4's epoch, so it may address that very allocation and the store must
;; still drop it. Guards the strict `<` in the epoch comparison.
(define (opt-load-cse-fresh-alloc-epoch-tie-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Alloc 4 (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        2
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Gep
            5
            (CompilerIrValue.Var 4)
            (CompilerIrValue.I64 0)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 5)
              (CompilerIrValue.I64 9)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Load 6 (CompilerIrValue.Var 2) (AstType.I64))
              (CompilerIrInstrList.Nil))))))))

(define (opt-load-cse-disjoint-copybytes-root-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 0)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          4
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.CopyBytes
            (CompilerIrValue.Var 4)
            (CompilerIrValue.Var 99)
            8)
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load 5 (CompilerIrValue.Var 2) (AstType.I64))
            (CompilerIrInstrList.Nil)))))))

(define (opt-load-cse-cast-derived-store-root-instrs) : CompilerIrInstrList
  (let
    [ref-ty : AstType (ast-ty-mut-ref 0 (AstType.I64))]
    (compiler-ir-instr-cons
      (CompilerIrInstr.Gep
        2
        (CompilerIrValue.Var 0)
        (CompilerIrValue.I64 0)
        (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 4 (CompilerIrValue.Var 1) ref-ty)
          (compiler-ir-instr-cons
            (CompilerIrInstr.Bitcast
              5
              (CompilerIrValue.Var 4)
              ref-ty
              (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                6
                (CompilerIrValue.Var 5)
                (CompilerIrValue.I64 0)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.StorePtr
                  (CompilerIrValue.Var 6)
                  (CompilerIrValue.I64 9)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Load 7 (CompilerIrValue.Var 2) (AstType.I64))
                  (CompilerIrInstrList.Nil))))))))))

(define (opt-load-cse-descriptor-data-root-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 0)
      (AstType.U64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.U64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          4
          (CompilerIrValue.Var 3)
          (CompilerIrValue.I64 0)
          (AstType.I64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 5 (CompilerIrValue.Var 4) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              6
              (CompilerIrValue.Var 1)
              (CompilerIrValue.I64 0)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.StorePtr
                (CompilerIrValue.Var 6)
                (CompilerIrValue.I64 9)
                (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Load 7 (CompilerIrValue.Var 4) (AstType.I64))
                (CompilerIrInstrList.Nil)))))))))

;; Hashmap slot stores use a scaled data-buffer Gep followed by an unscaled
;; inline-field Gep. The latter must retain element provenance so it preserves
;; cached descriptor-field loads while still invalidating buffer loads.
(define (opt-load-cse-element-gep-chain-store-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Gep
      2
      (CompilerIrValue.Var 0)
      (CompilerIrValue.I64 1)
      (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Load 3 (CompilerIrValue.Var 2) (AstType.I64))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Gep
          4
          (CompilerIrValue.Var 0)
          (CompilerIrValue.I64 0)
          (AstType.U64))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Load 5 (CompilerIrValue.Var 4) (AstType.U64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              6
              (CompilerIrValue.Var 5)
              (CompilerIrValue.Var 3)
              (AstType.U8))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Gep
                7
                (CompilerIrValue.Var 6)
                (CompilerIrValue.I64 8)
                (AstType.U8))
              (compiler-ir-instr-cons
                (CompilerIrInstr.StorePtr
                  (CompilerIrValue.Var 7)
                  (CompilerIrValue.I64 9)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Gep
                    8
                    (CompilerIrValue.Var 0)
                    (CompilerIrValue.I64 1)
                    (AstType.I64))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Load
                      9
                      (CompilerIrValue.Var 8)
                      (AstType.I64))
                    (CompilerIrInstrList.Nil)))))))))))

(define (opt-load-cse-cap-self-test?) : bool
  (let
    [key0 : OptLoadKey
      (OptLoadKey.Raw (CompilerIrValue.Var 0) (AstType.I64) false)]
    [key1 : OptLoadKey
      (OptLoadKey.Raw (CompilerIrValue.Var 1) (AstType.I64) false)]
    [table1 : OptLoadTable
      (opt-load-table-bind (OptLoadTable.Nil) 1 key0 (CompilerIrValue.Var 10) 0)]
    [table2 : OptLoadTable
      (opt-load-table-bind table1 1 key1 (CompilerIrValue.Var 11) 0)]
    [table-updated : OptLoadTable
      (opt-load-table-bind table2 1 key0 (CompilerIrValue.Var 12) 0)]
    [kinds1 : OptLoadPtrKinds
      (opt-load-kinds-bind
        (opt-load-kinds-empty-with-cap 1)
        1
        (OptLoadLocElement))]
    [kinds2 : OptLoadPtrKinds
      (opt-load-kinds-bind kinds1 2 (OptLoadLocElement))]
    [field-ok : OptLoadLocKind
      (opt-load-loc-field-checked
        (- opt-load-loc-field-base-limit 1)
        (- opt-load-loc-field-offset-limit 1)
        (- opt-load-loc-field-width-limit 1)
        true)]
    [field-bad : OptLoadLocKind
      (opt-load-loc-field-checked opt-load-loc-field-base-limit 0 8 false)]
    (and
      (= (opt-load-cse-table-cap-for-size 8) opt-load-cse-table-cap-floor)
      (= (opt-load-cse-kinds-cap-for-size 8) opt-load-cse-kinds-cap-floor)
      (=
        (opt-load-cse-table-cap-for-size
          (* opt-load-cse-cap-hard-max (* opt-load-cse-cap-scale-divisor 2)))
        opt-load-cse-cap-hard-max)
      (= (opt-load-table-len table2) 1)
      (match (opt-load-table-lookup table2 key1)
        [(CompilerIrMaybeValue.No) true]
        [_ false])
      (match (opt-load-table-lookup table-updated key0)
        [(CompilerIrMaybeValue.Some value)
          (match value
            [(CompilerIrValue.Var id) (= id 12)]
            [_ false])]
        [(CompilerIrMaybeValue.No) false])
      (match (opt-load-kinds-lookup kinds2 1)
        [(OptLoadLocElement) true]
        [_ false])
      (match (opt-load-kinds-lookup kinds2 2)
        [(OptLoadLocUnknown) true]
        [_ false])
      (match field-ok
        [(OptLoadLocField base off width header?)
          (and
            (= base (- opt-load-loc-field-base-limit 1))
            (= off (- opt-load-loc-field-offset-limit 1))
            (= width (- opt-load-loc-field-width-limit 1))
            header?)]
        [_ false])
      (match field-bad
        [(OptLoadLocUnknown) true]
        [_ false]))))

(define (opt-call-memory-test-map [name : i64] [summary : i64]) : opt_i64_i64_map.Map
  (let
    [map : opt_i64_i64_map.Map (opt_i64_i64_map.with-capacity 8)]
    (begin
      (opt_i64_i64_map.insert-ref!
        (&mut map)
        (compiler-ir-symbol-id name)
        summary)
      map)))

(define (opt-call-memory-test-call-instrs [name : i64] [arg : CompilerIrValue]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (CompilerIrInstr.Load 3 (CompilerIrValue.Var 0) (AstType.I64))
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call 4 name (CompilerIrCallArgs.One arg) (AstType.Unit))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Load 5 (CompilerIrValue.Var 0) (AstType.I64))
        (CompilerIrInstrList.Nil)))))

(define (opt-call-memory-test-function
  [name : i64]
  [params : CompilerIrParamList]
  [instrs : CompilerIrInstrList]) : CompilerIrFunction
  (CompilerIrFunction.Function
    name
    params
    (AstType.Unit)
    16
    (compiler-ir-block-cons
      (compiler-ir-block (compiler-ir-label "entry") instrs)
      (CompilerIrBlockList.Nil))))

(define (opt-call-memory-test-functions
  [wrapper : i64]
  [leaf : i64]
  [global-writer : i64]
  [raw-writer : i64]
  [indirect-writer : i64]
  [recursive : i64]
  [clean : i64]) : CompilerIrFunctionList
  (let
    [params : CompilerIrParamList (opt-load-cse-mixed-ref-params)]
    (compiler-ir-function-cons
      ;; Wrapper precedes its leaf so the leaf-to-caller fixed point needs a
      ;; later round; leaf param 0 is wrapper argument/root 1.
      (opt-call-memory-test-function
        wrapper
        params
        (compiler-ir-instr-cons
          (CompilerIrInstr.Call
            3
            leaf
            (CompilerIrCallArgs.Two
              (CompilerIrValue.Var 1)
              (CompilerIrValue.Var 0))
            (AstType.Unit))
          (CompilerIrInstrList.Nil)))
      (compiler-ir-function-cons
        (opt-call-memory-test-function
          leaf
          params
          (compiler-ir-instr-cons
            (CompilerIrInstr.StorePtr
              (CompilerIrValue.Var 0)
              (CompilerIrValue.I64 9)
              (AstType.I64))
            (CompilerIrInstrList.Nil)))
        (compiler-ir-function-cons
          (opt-call-memory-test-function
            global-writer
            params
            (compiler-ir-instr-cons
              (CompilerIrInstr.Store
                (opt-test-symbol "call_memory_global")
                (CompilerIrValue.I64 9)
                (AstType.I64))
              (CompilerIrInstrList.Nil)))
          (compiler-ir-function-cons
            (opt-call-memory-test-function
              raw-writer
              params
              (compiler-ir-instr-cons
                (CompilerIrInstr.StorePtr
                  (CompilerIrValue.Var 99)
                  (CompilerIrValue.I64 9)
                  (AstType.I64))
                (CompilerIrInstrList.Nil)))
            (compiler-ir-function-cons
              (opt-call-memory-test-function
                indirect-writer
                params
                (compiler-ir-instr-cons
                  (CompilerIrInstr.CallIndirect
                    3
                    (CompilerIrValue.Function leaf)
                    (CompilerIrCallArgs.Nil)
                    (AstType.Unit))
                  (CompilerIrInstrList.Nil)))
              (compiler-ir-function-cons
                (opt-call-memory-test-function
                  recursive
                  params
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Call
                      3
                      recursive
                      (CompilerIrCallArgs.Two
                        (CompilerIrValue.Var 0)
                        (CompilerIrValue.Var 1))
                      (AstType.Unit))
                    (CompilerIrInstrList.Nil)))
                (compiler-ir-function-cons
                  (opt-call-memory-test-function
                    clean
                    params
                    (CompilerIrInstrList.Nil))
                  (CompilerIrFunctionList.Nil))))))))))

(define (opt-call-memory-summary-is?
  [summaries : opt_i64_i64_map.Map]
  [name : i64]
  [expected : i64]) : bool
  (match (opt_i64_i64_map.get (& summaries) (compiler-ir-symbol-id name))
    [(opt_i64_i64_map.LookupFound summary) (= summary expected)]
    [(opt_i64_i64_map.LookupMissing) false]))

(define (opt-call-memory-summary-has?
  [summaries : opt_i64_i64_map.Map]
  [name : i64]
  [flag : i64]) : bool
  (match (opt_i64_i64_map.get (& summaries) (compiler-ir-symbol-id name))
    [(opt_i64_i64_map.LookupFound summary) (not (= (bit-and summary flag) 0))]
    [(opt_i64_i64_map.LookupMissing) false]))

(define (compiler-optimize-load-cse-self-test) : i64
  (let
    [positive : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-positive-instrs))]
    [call-touch : i64 (opt-test-symbol "call_memory_touch")]
    [call-write-param : opt_i64_i64_map.Map
      (opt-call-memory-test-map call-touch 1)]
    [call-disjoint : CompilerIrInstrList
      (opt-load-cse-run-with-params-and-call-memory
        (opt-load-cse-mixed-ref-params)
        call-write-param
        (opt-call-memory-test-call-instrs call-touch (CompilerIrValue.Var 1)))]
    [call-same-root : CompilerIrInstrList
      (opt-load-cse-run-with-params-and-call-memory
        (opt-load-cse-mixed-ref-params)
        call-write-param
        (opt-call-memory-test-call-instrs call-touch (CompilerIrValue.Var 0)))]
    [call-global : CompilerIrInstrList
      (opt-load-cse-run-with-params-and-call-memory
        (opt-load-cse-mixed-ref-params)
        (opt-call-memory-test-map call-touch (opt-call-memory-global-bit))
        (opt-call-memory-test-call-instrs call-touch (CompilerIrValue.Var 1)))]
    [call-unknown : CompilerIrInstrList
      (opt-load-cse-run-with-params-and-call-memory
        (opt-load-cse-mixed-ref-params)
        (opt-call-memory-test-map call-touch (opt-call-memory-unknown-bit))
        (opt-call-memory-test-call-instrs call-touch (CompilerIrValue.Var 1)))]
    [summary-wrapper : i64 (opt-test-symbol "call_memory_wrapper")]
    [summary-leaf : i64 (opt-test-symbol "call_memory_leaf")]
    [summary-global : i64 (opt-test-symbol "call_memory_global_writer")]
    [summary-raw : i64 (opt-test-symbol "call_memory_raw_writer")]
    [summary-indirect : i64 (opt-test-symbol "call_memory_indirect_writer")]
    [summary-recursive : i64 (opt-test-symbol "call_memory_recursive")]
    [summary-clean : i64 (opt-test-symbol "call_memory_clean")]
    [call-summaries : opt_i64_i64_map.Map
      (opt-call-memory-build
        (opt-call-memory-test-functions
          summary-wrapper
          summary-leaf
          summary-global
          summary-raw
          summary-indirect
          summary-recursive
          summary-clean)
        32)]
    ;; GAP4: a store through an UNKNOWN pointer still clears everything.
    [store : bool
      (opt-load-cse-barrier-blocked?
        (CompilerIrInstr.StorePtr
          (CompilerIrValue.Var 99)
          (CompilerIrValue.I64 9)
          (AstType.I64)))]
    [store-forward : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-store-forward-instrs))]
    [subword-const-forward : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-subword-const-forward-instrs))]
    [subword-load-forward : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-subword-load-forward-instrs))]
    [subword-unknown-var : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-subword-unknown-var-instrs))]
    [canonical-gep : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-canonical-gep-instrs))]
    [element-store : CompilerIrInstrList
      (opt-load-cse-run-with-array-param (opt-load-cse-element-store-instrs))]
    [element-invalidate : CompilerIrInstrList
      (opt-load-cse-run-with-array-param
        (opt-load-cse-element-invalidate-instrs))]
    [other-base-store : CompilerIrInstrList
      (opt-load-cse-run-with-array-param (opt-load-cse-other-base-store-instrs))]
    [same-base-disjoint : CompilerIrInstrList
      (opt-load-cse-run-with-array-param
        (opt-load-cse-same-base-disjoint-instrs))]
    [copybytes-forward : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-copybytes-forward-instrs))]
    [copybytes-overlap : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-copybytes-overlap-instrs))]
    [checked-distinct : CompilerIrInstrList
      (opt-load-cse-run-with-params
        (opt-load-cse-mixed-ref-params)
        (opt-load-cse-disjoint-checked-root-instrs))]
    [checked-shared-alias : CompilerIrInstrList
      (opt-load-cse-run-with-params
        (opt-load-cse-shared-ref-params)
        (opt-load-cse-disjoint-checked-root-instrs))]
    [checked-same-root : CompilerIrInstrList
      (opt-load-cse-run-with-params
        (opt-load-cse-exclusive-ref-params)
        (opt-load-cse-same-checked-root-instrs))]
    [fresh-tl-alloc-root : CompilerIrInstrList
      (opt-load-cse-run-with-params
        (opt-load-cse-mixed-ref-params)
        (opt-load-cse-fresh-tl-alloc-root-instrs))]
    [fresh-alloc-epoch : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-fresh-alloc-epoch-instrs))]
    [fresh-alloc-epoch-tie : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-fresh-alloc-epoch-tie-instrs))]
    [checked-copybytes : CompilerIrInstrList
      (opt-load-cse-run-with-params
        (opt-load-cse-mixed-ref-params)
        (opt-load-cse-disjoint-copybytes-root-instrs))]
    [checked-cast-root : CompilerIrInstrList
      (opt-load-cse-run-with-params
        (opt-load-cse-mixed-ref-params)
        (opt-load-cse-cast-derived-store-root-instrs))]
    [descriptor-data-root : CompilerIrInstrList
      (opt-load-cse-run-with-params
        (opt-load-cse-descriptor-ref-params)
        (opt-load-cse-descriptor-data-root-instrs))]
    [element-gep-chain-store : CompilerIrInstrList
      (opt-load-cse-run-with-array-param
        (opt-load-cse-element-gep-chain-store-instrs))]
    [global-store : bool
      (opt-load-cse-barrier-blocked?
        (CompilerIrInstr.Store
          (opt-test-symbol "g")
          (CompilerIrValue.I64 9)
          (AstType.I64)))]
    [vector-store : bool
      (opt-load-cse-barrier-blocked?
        (ir-instr-vector-store
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (CompilerIrValue.I64 9)
          4
          (AstType.I64)))]
    [pred-store : bool
      (opt-load-cse-barrier-blocked?
        (ir-instr-predicated-store
          (CompilerIrValue.Var 1)
          (CompilerIrValue.I64 0)
          (CompilerIrValue.I64 9)
          (CompilerIrValue.Bool true)
          4
          (AstType.I64)))]
    [direct-call : bool
      (opt-load-cse-barrier-blocked?
        (CompilerIrInstr.Call
          9
          (opt-test-symbol "touch")
          (CompilerIrCallArgs.Nil)
          (AstType.I64)))]
    [indirect-call : bool
      (opt-load-cse-barrier-blocked?
        (CompilerIrInstr.CallIndirect
          9
          (CompilerIrValue.Function (opt-test-symbol "touch"))
          (CompilerIrCallArgs.Nil)
          (AstType.I64)))]
    [extern-call : bool
      (opt-load-cse-barrier-blocked?
        (CompilerIrInstr.CallIndirectC
          9
          (CompilerIrValue.Function (opt-test-symbol "ffi_touch"))
          (CompilerIrCallArgs.Nil)
          (AstType.I64)))]
    [volatile-call : bool
      (opt-load-cse-barrier-blocked?
        (CompilerIrInstr.Call
          9
          (opt-test-symbol "tl_volatile_i64_load_ptr")
          (CompilerIrCallArgs.One (CompilerIrValue.Var 0))
          (AstType.I64)))]
    [atomic-call : bool
      (opt-load-cse-barrier-blocked?
        (CompilerIrInstr.Call
          9
          (opt-test-symbol "tl_atomic_i64_load_ptr")
          (CompilerIrCallArgs.One (CompilerIrValue.Var 0))
          (AstType.I64)))]
    [tail-call : bool
      (opt-load-cse-barrier-blocked?
        (CompilerIrInstr.TailCall
          (opt-test-symbol "touch")
          (CompilerIrCallArgs.Nil)
          (AstType.I64)))]
    [syscall : bool
      (opt-load-cse-barrier-blocked?
        (CompilerIrInstr.Syscall 9 (CompilerIrCallArgs.Nil)))]
    [address-redef : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-address-redef-instrs))]
    [result-redef : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-result-redef-instrs))]
    [type-mismatch : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-type-mismatch-instrs))]
    [different-address : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-different-address-instrs))]
    [vector-data-pointer : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-vector-data-pointer-instrs))]
    [pipeline : CompilerIrBlock
      (optimize-block
        (compiler-ir-block
          (compiler-ir-label "entry")
          (opt-load-cse-positive-instrs)))]
    ;; Self-test inspection of optimize-block output, not a hot pass path.
    [pipeline-instrs : CompilerIrInstrList
      (match pipeline
        [(CompilerIrBlock.Block _ instrs)
          (compiler-ir-instr-seq-to-list instrs)])]
    (cond
      [(not (= (opt-count-load-instrs positive) 1)) 1]
      [(not (= (opt-count-mov-dst-instrs positive 3) 1)) 2]
      [(not store) 3]
      [(not global-store) 4]
      [(not vector-store) 5]
      [(not pred-store) 6]
      [(not direct-call) 7]
      [(not indirect-call) 8]
      [(not tail-call) 9]
      [(not syscall) 10]
      [(not (= (opt-count-load-instrs address-redef) 2)) 11]
      [(not (= (opt-count-mov-dst-instrs address-redef 3) 0)) 12]
      [(not (= (opt-count-load-instrs result-redef) 2)) 13]
      [(not (= (opt-count-mov-dst-instrs result-redef 3) 0)) 14]
      [(not (= (opt-count-load-instrs type-mismatch) 2)) 15]
      [(not (= (opt-count-load-instrs different-address) 2)) 16]
      [(not (= (opt-count-load-instrs vector-data-pointer) 1)) 17]
      [(not (= (opt-count-mov-dst-instrs vector-data-pointer 3) 1)) 18]
      [(not (= (opt-count-load-instrs pipeline-instrs) 1)) 19]
      [(not (= (opt-count-mov-dst-instrs pipeline-instrs 3) 1)) 20]
      ;; GAP4 additions.
      [(not (= (opt-count-load-instrs store-forward) 1)) 21]
      [(not (= (opt-count-mov-dst-i64-src store-forward 3 9) 1)) 22]
      [(not (= (opt-count-load-instrs canonical-gep) 1)) 23]
      [(not (= (opt-count-mov-dst-instrs canonical-gep 4) 1)) 24]
      [(not (= (opt-count-load-instrs element-store) 2)) 25]
      [(not (= (opt-count-mov-dst-instrs element-store 8) 1)) 26]
      [(not (= (opt-count-load-instrs element-invalidate) 3)) 27]
      [(not (= (opt-count-mov-dst-instrs element-invalidate 7) 0)) 28]
      [(not (= (opt-count-load-instrs other-base-store) 2)) 29]
      [(not (= (opt-count-mov-dst-instrs other-base-store 6) 0)) 30]
      [(not (= (opt-count-load-instrs same-base-disjoint) 1)) 31]
      [(not (= (opt-count-mov-dst-instrs same-base-disjoint 6) 1)) 32]
      [(not (= (opt-count-load-instrs subword-const-forward) 0)) 33]
      [(not (= (opt-count-mov-dst-i64-src subword-const-forward 2 7) 1)) 34]
      [(not (= (opt-count-mov-dst-bool-src subword-const-forward 4 true) 1)) 35]
      [(not (= (opt-count-load-instrs subword-load-forward) 1)) 36]
      [(not
          (=
            (opt-count-mov-dst-var-src subword-load-forward 3 2 (AstType.I32))
            1))
        37]
      [(not (= (opt-count-load-instrs subword-unknown-var) 1)) 38]
      [(not (= (opt-count-mov-dst-instrs subword-unknown-var 2) 0)) 39]
      [(not (= (opt-count-load-instrs copybytes-forward) 1)) 40]
      [(not
          (= (opt-count-mov-dst-var-src copybytes-forward 5 2 (AstType.I64)) 1))
        41]
      [(not (= (opt-count-load-instrs copybytes-overlap) 2)) 42]
      [(not (= (opt-count-mov-dst-instrs copybytes-overlap 5) 0)) 43]
      [(not (opt-load-cse-cap-self-test?)) 45]
      [(not (= (opt-count-load-instrs checked-distinct) 1)) 46]
      [(not
          (= (opt-count-mov-dst-var-src checked-distinct 5 3 (AstType.I64)) 1))
        47]
      [(not (= (opt-count-load-instrs checked-shared-alias) 2)) 48]
      [(not (= (opt-count-mov-dst-instrs checked-shared-alias 5) 0)) 49]
      [(not (= (opt-count-load-instrs checked-same-root) 1)) 50]
      [(not (= (opt-count-mov-dst-i64-src checked-same-root 5 9) 1)) 51]
      [(not (= (opt-count-load-instrs fresh-tl-alloc-root) 1)) 52]
      [(not
          (=
            (opt-count-mov-dst-var-src fresh-tl-alloc-root 6 3 (AstType.I64))
            1))
        53]
      [(not (= (opt-count-load-instrs checked-copybytes) 1)) 54]
      [(not
          (= (opt-count-mov-dst-var-src checked-copybytes 5 3 (AstType.I64)) 1))
        55]
      [(not (= (opt-count-load-instrs checked-cast-root) 1)) 56]
      [(not
          (= (opt-count-mov-dst-var-src checked-cast-root 7 3 (AstType.I64)) 1))
        57]
      [(not (= (opt-count-load-instrs descriptor-data-root) 2)) 58]
      [(not
          (=
            (opt-count-mov-dst-var-src descriptor-data-root 7 5 (AstType.I64))
            1))
        59]
      [(not (= (opt-count-load-instrs call-disjoint) 1)) 60]
      [(not (= (opt-count-mov-dst-var-src call-disjoint 5 3 (AstType.I64)) 1))
        61]
      [(not (= (opt-count-load-instrs call-same-root) 2)) 62]
      [(not (= (opt-count-mov-dst-instrs call-same-root 5) 0)) 63]
      [(not (= (opt-count-load-instrs call-global) 2)) 64]
      [(not (= (opt-count-load-instrs call-unknown) 2)) 65]
      [(not (opt-call-memory-summary-is? call-summaries summary-leaf 1)) 66]
      [(not (opt-call-memory-summary-is? call-summaries summary-wrapper 2)) 67]
      [(not
          (opt-call-memory-summary-has?
            call-summaries
            summary-global
            (opt-call-memory-global-bit)))
        68]
      [(not
          (opt-call-memory-summary-has?
            call-summaries
            summary-raw
            (opt-call-memory-unknown-bit)))
        69]
      [(not
          (opt-call-memory-summary-has?
            call-summaries
            summary-indirect
            (opt-call-memory-unknown-bit)))
        70]
      [(opt_i64_i64_map.contains?
          (& call-summaries)
          (compiler-ir-symbol-id summary-recursive))
        71]
      [(not (opt-call-memory-summary-is? call-summaries summary-clean 0)) 72]
      [(not extern-call) 73]
      [(not volatile-call) 74]
      [(not atomic-call) 75]
      [(not (= (opt-count-load-instrs element-gep-chain-store) 2)) 76]
      [(not
          (=
            (opt-count-mov-dst-var-src
              element-gep-chain-store
              9
              3
              (AstType.I64))
            1))
        77]
      ;; Fresh-allocation epoch ordering: an entry cached before the allocation
      ;; survives a store through it; one cached in the same epoch does not.
      [(not (= (opt-count-load-instrs fresh-alloc-epoch) 1)) 78]
      [(not
          (= (opt-count-mov-dst-var-src fresh-alloc-epoch 6 3 (AstType.I64)) 1))
        79]
      [(not (= (opt-count-load-instrs fresh-alloc-epoch-tie) 2)) 80]
      [(not (= (opt-count-mov-dst-instrs fresh-alloc-epoch-tie 6) 0)) 81]
      [else 44])))