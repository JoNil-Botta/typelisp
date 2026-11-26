;; Bidirectional conversion between lowered TypeLisp IR (`CompilerIr*`) and
;; `.tli` v3 `compact_ir` wire records (`TliCompact*`), plus the producer-side
;; `tli-attach-compact-ir!` helper shared by stdlib sysroot and package `.tli`
;; builders. Free of stdlib-only symbol assumptions.
(import compiler_ast_types as ast)
(import compiler_intern as intern)
(import compiler_ir_types as ir)
(import compiler_optimize as opt)
(import compiler_tli_codec as codec)
(import compiler_tli_hydrate as hydrate)
(import compiler_tli_types as tli)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as i64_map)
(import (hashmap.hashmap String i64) as str_map)
(import stdlib.iterator)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64_vec)
(import (vector.vector String) as str_vec)
(import (vector.vector opt.OptExternalFnSummary core) as ext_sum_vec)
(import (vector.vector tli.TliCompactBodyEntry core) as body_vec)
(import (vector.vector tli.TliCompactExternRef core) as ext_ref_vec)
(import (vector.vector tli.TliCompactGlobal core) as global_vec)

(define (tli-compact-bytes-from-string [text : (& str)]) : (__tl_dyn-array u8)
  (let
    [n : i64 (string.string-length text)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    (for [i (iterator.range 0 n)]
      (set! (array-ref out i) (cast (string.string-ref text i) : u8)))
    out))

(define (tli-compact-string-from-bytes [raw : (& (__tl_dyn-array u8))]) : String
  (unsafe
    (string-from-bytes
      (ptr-cast (__tl_array-data (deref raw)) : (Ptr u8))
      (array-length (deref raw)))))

;; --- AstType <-> TliType (for lowered IR types, no type variables) ---
(define (tli-compact-lifetimes-from-ast
  [_interns : (& intern.InternCompatState)]
  [items : (& ast.AstLifetimeList)]) : (__tl_dyn-array String)
  (let
    [n : i64 (ast.ast-lifetime-list-len items)]
    [out : (__tl_dyn-array String) (__tl_make-array String n)]
    (for [i (iterator.range 0 n)]
      (let
        [id : i64 (ast.ast-lifetime-list-get items i 0)]
        (set!
          (array-ref out i)
          (string.copy (ast.ast-nominal-name-id-display id)))))
    out))

(define (tli-compact-type-list-from-ast
  [pools : ast.AstNodePoolContext]
  [interns : (& intern.InternCompatState)]
  [items : (& ast.AstTypeList)]) : (__tl_dyn-array tli.TliType)
  (let
    [n : i64 (ast.ast-type-list-len items)]
    [out : (__tl_dyn-array tli.TliType) (__tl_make-array tli.TliType n)]
    (for [i (iterator.range 0 n)]
      (let
        [tid : i64 (ast.ast-type-list-get items i (ast.ast-type-id-fallback))]
        [t : ast.AstType (ast.ast-node-pool-context-type-get pools tid)]
        (set! (array-ref out i) (tli-compact-type-from-ast pools interns (& t)))))
    out))

(define (tli-compact-nominal-name-from-ast
  [_interns : (& intern.InternCompatState)]
  [key : i64]) : String
  (string.copy (ast.ast-nominal-name-id-display key)))

(define (tli-compact-type-from-ast
  [pools : ast.AstNodePoolContext]
  [interns : (& intern.InternCompatState)]
  [ty : (& ast.AstType)]) : tli.TliType
  (match ty
    [(ast.AstType.I64) (tli.TliType.I64)]
    [(ast.AstType.I32) (tli.TliType.I32)]
    [(ast.AstType.I16) (tli.TliType.I16)]
    [(ast.AstType.I8) (tli.TliType.I8)]
    [(ast.AstType.U64) (tli.TliType.U64)]
    [(ast.AstType.U32) (tli.TliType.U32)]
    [(ast.AstType.U16) (tli.TliType.U16)]
    [(ast.AstType.U8) (tli.TliType.U8)]
    [(ast.AstType.F64) (tli.TliType.F64)]
    [(ast.AstType.F32) (tli.TliType.F32)]
    [(ast.AstType.Bool) (tli.TliType.Bool)]
    [(ast.AstType.Char) (tli.TliType.Char)]
    [(ast.AstType.String) (tli.TliType.String)]
    [(ast.AstType.Str) (tli.TliType.Str)]
    [(ast.AstType.Bytes) (tli.TliType.Bytes)]
    [(ast.AstType.Unit) (tli.TliType.Unit)]
    [(ast.AstType.Never) (tli.TliType.Never)]
    [(ast.AstType.Expr) (tli.TliType.Expr)]
    [(ast.AstType.ExprList) (tli.TliType.ExprList)]
    [(ast.AstType.Func params-box ret-id)
      (let
        [ret-t : ast.AstType (ast.ast-node-pool-context-type-get pools ret-id)]
        (tli.TliType.Func
          (tli-compact-type-list-from-ast pools interns (& (deref params-box)))
          (box (tli-compact-type-from-ast pools interns (& ret-t)))))]
    [(ast.AstType.Tuple items-box)
      (tli.TliType.Tuple
        (tli-compact-type-list-from-ast pools interns (& (deref items-box))))]
    [(ast.AstType.Array elem-id len)
      (let
        [et : ast.AstType (ast.ast-node-pool-context-type-get pools elem-id)]
        (tli.TliType.Array
          (box (tli-compact-type-from-ast pools interns (& et)))
          len))]
    [(ast.AstType.DynArray elem-id)
      (let
        [et : ast.AstType (ast.ast-node-pool-context-type-get pools elem-id)]
        (tli.TliType.DynArray
          (box (tli-compact-type-from-ast pools interns (& et)))))]
    [(ast.AstType.Box elem-id)
      (let
        [et : ast.AstType (ast.ast-node-pool-context-type-get pools elem-id)]
        (tli.TliType.Box (box (tli-compact-type-from-ast pools interns (& et)))))]
    [(ast.AstType.Region life inner-id)
      (let
        [it : ast.AstType (ast.ast-node-pool-context-type-get pools inner-id)]
        (tli.TliType.Region
          (string.copy (ast.ast-nominal-name-id-display life))
          (box (tli-compact-type-from-ast pools interns (& it)))))]
    [(ast.AstType.Ref life inner-id)
      (let
        [it : ast.AstType (ast.ast-node-pool-context-type-get pools inner-id)]
        (tli.TliType.Ref
          (string.copy (ast.ast-nominal-name-id-display life))
          (box (tli-compact-type-from-ast pools interns (& it)))))]
    [(ast.AstType.MutRef life inner-id)
      (let
        [it : ast.AstType (ast.ast-node-pool-context-type-get pools inner-id)]
        (tli.TliType.MutRef
          (string.copy (ast.ast-nominal-name-id-display life))
          (box (tli-compact-type-from-ast pools interns (& it)))))]
    [(ast.AstType.Invalidate life inner-id)
      (let
        [it : ast.AstType (ast.ast-node-pool-context-type-get pools inner-id)]
        (tli.TliType.Invalidate
          (string.copy (ast.ast-nominal-name-id-display life))
          (box (tli-compact-type-from-ast pools interns (& it)))))]
    [(ast.AstType.Enum key)
      (tli.TliType.Enum (tli-compact-nominal-name-from-ast interns key))]
    [(ast.AstType.EnumArgs key lives-box)
      (tli.TliType.EnumArgs
        (tli-compact-nominal-name-from-ast interns key)
        (tli-compact-lifetimes-from-ast interns (& (deref lives-box))))]
    [(ast.AstType.Struct key)
      (tli.TliType.Struct (tli-compact-nominal-name-from-ast interns key))]
    [(ast.AstType.StructArgs key lives-box)
      (tli.TliType.StructArgs
        (tli-compact-nominal-name-from-ast interns key)
        (tli-compact-lifetimes-from-ast interns (& (deref lives-box))))]
    [(ast.AstType.Var key)
      (tli.TliType.Var (tli-compact-nominal-name-from-ast interns key))]
    [(ast.AstType.VarArgs key lives-box)
      (tli.TliType.VarArgs
        (tli-compact-nominal-name-from-ast interns key)
        (tli-compact-lifetimes-from-ast interns (& (deref lives-box))))]
    [(ast.AstType.Ptr elem-id)
      (let
        [et : ast.AstType (ast.ast-node-pool-context-type-get pools elem-id)]
        (tli.TliType.Ptr (box (tli-compact-type-from-ast pools interns (& et)))))]
    [(ast.AstType.MutPtr elem-id)
      (let
        [et : ast.AstType (ast.ast-node-pool-context-type-get pools elem-id)]
        (tli.TliType.MutPtr
          (box (tli-compact-type-from-ast pools interns (& et)))))]
    [(ast.AstType.Slice elem-id)
      (let
        [et : ast.AstType (ast.ast-node-pool-context-type-get pools elem-id)]
        (tli.TliType.Slice
          (box (tli-compact-type-from-ast pools interns (& et)))))]
    [(ast.AstType.CFunc sig-id mode)
      (let
        [st : ast.AstType (ast.ast-node-pool-context-type-get pools sig-id)]
        [mode-tag : i64
          (match mode
            [(ast.AstCFunctionMode.Nullable) 0]
            [(ast.AstCFunctionMode.NonNull) 1]
            [(ast.AstCFunctionMode.UnsafeNullable) 2]
            [(ast.AstCFunctionMode.UnsafeNonNull) 3])]
        (tli.TliType.CFunc
          (box (tli-compact-type-from-ast pools interns (& st)))
          mode-tag))]))

(define (tli-compact-lifetimes-to-ast [names : (& (__tl_dyn-array String))]) : ast.AstLifetimeList
  (let
    [n : i64 (array-length (deref names))]
    [out : ast.AstLifetimeList (ast.ast-lifetime-list-with-capacity n)]
    (for [i (iterator.range 0 n)]
      (ast.ast-lifetime-list-push
        (&mut out)
        (intern.intern (string.copy (& (array-ref (deref names) i))))))
    out))

(define (tli-compact-type-id-to-ast
  [pools : ast.AstNodePoolContext]
  [ty : (& tli.TliType)]) : i64
  (ast.ast-node-pool-context-type-push pools (tli-compact-type-to-ast pools ty)))

(define (tli-compact-type-list-to-ast
  [pools : ast.AstNodePoolContext]
  [items : (& (__tl_dyn-array tli.TliType))]) : ast.AstTypeList
  (let
    [n : i64 (array-length (deref items))]
    [out : ast.AstTypeList (ast.ast-type-list-with-capacity n)]
    (for [i (iterator.range 0 n)]
      (ast.ast-type-list-push
        (&mut out)
        (tli-compact-type-id-to-ast pools (& (array-ref (deref items) i)))))
    out))

(define (tli-compact-nominal-name-to-ast [name : (& str)]) : i64
  (ast.ast-nominal-name-id-key (intern.intern (string.copy name))))

(define (tli-compact-type-to-ast
  [pools : ast.AstNodePoolContext]
  [ty : (& tli.TliType)]) : ast.AstType
  (match ty
    [(tli.TliType.I64) (ast.AstType.I64)]
    [(tli.TliType.I32) (ast.AstType.I32)]
    [(tli.TliType.I16) (ast.AstType.I16)]
    [(tli.TliType.I8) (ast.AstType.I8)]
    [(tli.TliType.U64) (ast.AstType.U64)]
    [(tli.TliType.U32) (ast.AstType.U32)]
    [(tli.TliType.U16) (ast.AstType.U16)]
    [(tli.TliType.U8) (ast.AstType.U8)]
    [(tli.TliType.F64) (ast.AstType.F64)]
    [(tli.TliType.F32) (ast.AstType.F32)]
    [(tli.TliType.Bool) (ast.AstType.Bool)]
    [(tli.TliType.Char) (ast.AstType.Char)]
    [(tli.TliType.String) (ast.AstType.String)]
    [(tli.TliType.Str) (ast.AstType.Str)]
    [(tli.TliType.Bytes) (ast.AstType.Bytes)]
    [(tli.TliType.Unit) (ast.AstType.Unit)]
    [(tli.TliType.Never) (ast.AstType.Never)]
    [(tli.TliType.Expr) (ast.AstType.Expr)]
    [(tli.TliType.ExprList) (ast.AstType.ExprList)]
    [(tli.TliType.Func args ret)
      (ast.AstType.Func
        (box (tli-compact-type-list-to-ast pools args))
        (tli-compact-type-id-to-ast pools (& (deref ret))))]
    [(tli.TliType.Tuple items)
      (ast.AstType.Tuple (box (tli-compact-type-list-to-ast pools items)))]
    [(tli.TliType.Array elem len)
      (ast.AstType.Array
        (tli-compact-type-id-to-ast pools (& (deref elem)))
        len)]
    [(tli.TliType.DynArray elem)
      (ast.AstType.DynArray (tli-compact-type-id-to-ast pools (& (deref elem))))]
    [(tli.TliType.Box elem)
      (ast.AstType.Box (tli-compact-type-id-to-ast pools (& (deref elem))))]
    [(tli.TliType.Region life inner)
      (ast.AstType.Region
        (intern.intern (string.copy life))
        (tli-compact-type-id-to-ast pools (& (deref inner))))]
    [(tli.TliType.Ref life inner)
      (ast.AstType.Ref
        (intern.intern (string.copy life))
        (tli-compact-type-id-to-ast pools (& (deref inner))))]
    [(tli.TliType.MutRef life inner)
      (ast.AstType.MutRef
        (intern.intern (string.copy life))
        (tli-compact-type-id-to-ast pools (& (deref inner))))]
    [(tli.TliType.Invalidate life inner)
      (ast.ast-ty-invalidate-id
        (intern.intern (string.copy life))
        (tli-compact-type-id-to-ast pools (& (deref inner))))]
    [(tli.TliType.Enum name)
      (ast.AstType.Enum (tli-compact-nominal-name-to-ast name))]
    [(tli.TliType.EnumArgs name lives)
      (ast.ast-ty-enum-args
        (tli-compact-nominal-name-to-ast name)
        (tli-compact-lifetimes-to-ast lives))]
    [(tli.TliType.Struct name)
      (ast.AstType.Struct (tli-compact-nominal-name-to-ast name))]
    [(tli.TliType.StructArgs name lives)
      (ast.ast-ty-struct-args
        (tli-compact-nominal-name-to-ast name)
        (tli-compact-lifetimes-to-ast lives))]
    [(tli.TliType.Var name)
      (ast.AstType.Var (tli-compact-nominal-name-to-ast name))]
    [(tli.TliType.VarArgs name lives)
      (ast.ast-ty-var-args
        (tli-compact-nominal-name-to-ast name)
        (tli-compact-lifetimes-to-ast lives))]
    [(tli.TliType.Ptr elem)
      (ast.AstType.Ptr (tli-compact-type-id-to-ast pools (& (deref elem))))]
    [(tli.TliType.MutPtr elem)
      (ast.AstType.MutPtr (tli-compact-type-id-to-ast pools (& (deref elem))))]
    [(tli.TliType.Slice elem)
      (ast.AstType.Slice (tli-compact-type-id-to-ast pools (& (deref elem))))]
    [(tli.TliType.CFunc sig mode)
      (ast.AstType.CFunc
        (tli-compact-type-id-to-ast pools (& (deref sig)))
        (match mode
          [0 (ast.AstCFunctionMode.Nullable)]
          [1 (ast.AstCFunctionMode.NonNull)]
          [2 (ast.AstCFunctionMode.UnsafeNullable)]
          [_ (ast.AstCFunctionMode.UnsafeNonNull)]))]))

;; --- ReturnStorage <-> TliCompactReturnStorage ---
(define (tli-compact-return-storage-from-ir
  [pools : ast.AstNodePoolContext]
  [interns : (& intern.InternCompatState)]
  [storage : (& ir.CompilerIrReturnStorage)]) : tli.TliCompactReturnStorage
  (match storage
    [(ir.CompilerIrReturnStorage.None) (tli.TliCompactReturnStorage.None)]
    [(ir.CompilerIrReturnStorage.Some abi-box)
      (tli-compact-return-storage-abi-from-ir pools interns (& (deref abi-box)))]))

(define (tli-compact-return-storage-abi-from-ir
  [pools : ast.AstNodePoolContext]
  [interns : (& intern.InternCompatState)]
  [abi : (& ir.CompilerIrReturnStorageAbi)]) : tli.TliCompactReturnStorage
  (let
    [conv : i64
      (match (& abi.convention)
        [(ir.CompilerIrReturnStorageConvention.InternalLeading) 0]
        [(ir.CompilerIrReturnStorageConvention.SysV) 2]
        [(ir.CompilerIrReturnStorageConvention.Win64) 3])]
    (tli.TliCompactReturnStorage.Some
      conv
      abi.index
      abi.bytes
      abi.alignment
      (tli-compact-type-from-ast pools interns (& abi.output))
      (tli-compact-type-from-ast pools interns (& abi.physical-result))
      (tli-compact-type-list-from-ast pools interns (& abi.physical-params))
      (tli-compact-type-from-ast pools interns (& abi.source-signature)))))

(define (tli-compact-return-storage-to-ir
  [pools : ast.AstNodePoolContext]
  [storage : (& tli.TliCompactReturnStorage)]) : ir.CompilerIrReturnStorage
  (match storage
    [(tli.TliCompactReturnStorage.None) (ir.CompilerIrReturnStorage.None)]
    [(tli.TliCompactReturnStorage.Some
        conv
        index
        bytes
        alignment
        output
        physical-result
        physical-params
        source-sig)
      (let
        [conv-ir : ir.CompilerIrReturnStorageConvention
          (match conv
            [0 (ir.CompilerIrReturnStorageConvention.InternalLeading)]
            [2 (ir.CompilerIrReturnStorageConvention.SysV)]
            [_ (ir.CompilerIrReturnStorageConvention.Win64)])]
        (ir.CompilerIrReturnStorage.Some
          (box
            (ir.CompilerIrReturnStorageAbi
              conv-ir
              index
              bytes
              alignment
              (tli-compact-type-to-ast pools output)
              (tli-compact-type-to-ast pools physical-result)
              (tli-compact-type-list-to-ast pools physical-params)
              (tli-compact-type-to-ast pools source-sig)))))]))

;; --- Producer: CompilerIrFunction -> TliCompactIrBody ---
(defstruct TliIrEncodeTables
  (fn-id-to-idx i64_map.Map)
  (gl-id-to-idx i64_map.Map)
  (ex-id-to-idx i64_map.Map)
  (fn-skip (__tl_dyn-array bool))
  (gl-private (__tl_dyn-array bool))
  (gl-literal (__tl_dyn-array bool))
  ;; The global's cell is its inline aggregate, so a body's read of it is the
  ;; symbol's address.
  (gl-inline (__tl_dyn-array bool))
  (fn-link-syms (__tl_dyn-array String))
  (gl-link-syms (__tl_dyn-array String)))

(defstruct TliIrBodyEncodeState
  (self-fn-idx i64)
  (ok? bool)
  (has-call? bool)
  (label-map i64_map.Map)
  (next-label i64)
  (ref-fns-seen i64_map.Map)
  (ref-fns i64_vec.Vec)
  (ref-gls-seen i64_map.Map)
  (ref-gls i64_vec.Vec)
  (ref-exs-seen i64_map.Map)
  (ref-exs i64_vec.Vec))

(define (tli-ir-enc-label! [st : (&mut TliIrBodyEncodeState)] [raw-label : i64]) : i64
  (if (< raw-label 0)
    -1
    (match (i64_map.get (& st.label-map) raw-label)
      [(LookupFound dense) dense]
      [(LookupMissing)
        (let
          [dense : i64 st.next-label]
          (i64_map.insert-ref! (&mut st.label-map) raw-label dense)
          (set! st.next-label (+ dense 1))
          dense)])))

(define (tli-ir-enc-fn-symbol!
  [tables : (& TliIrEncodeTables)]
  [interns : (& intern.InternCompatState)]
  [st : (&mut TliIrBodyEncodeState)]
  [whole-externs : (& ir.CompilerIrExternSeq)]
  [sym-id : i64]) : String
  (let
    [sid : i64 (ir.compiler-ir-symbol-id sym-id)]
    (match (i64_map.get (& tables.fn-id-to-idx) sid)
      [(LookupFound fidx)
        ;; A self-reference would encode this body's own link symbol with no
        ;; extern-ref, which hydration cannot rename; reject recursive bodies.
        (when
          (or (array-ref tables.fn-skip fidx) (= fidx st.self-fn-idx))
          (set! st.ok? false))
        (when
          (and
            (!= fidx st.self-fn-idx)
            (not (i64_map.contains? (& st.ref-fns-seen) fidx)))
          (i64_map.insert-ref! (&mut st.ref-fns-seen) fidx 1)
          (i64_vec.push-ref! (&mut st.ref-fns) fidx))
        (string.copy (& (array-ref tables.fn-link-syms fidx)))]
      [(LookupMissing)
        (match (i64_map.get (& tables.ex-id-to-idx) sid)
          [(LookupFound eidx)
            (unless
              (i64_map.contains? (& st.ref-exs-seen) eidx)
              (i64_map.insert-ref! (&mut st.ref-exs-seen) eidx 1)
              (i64_vec.push-ref! (&mut st.ref-exs) eidx))
            (match (ir.compiler-ir-extern-seq-borrow whole-externs eidx)
              [(ir.CompilerIrExtern.Extern _ _ _ _ abi link-id _ _ _ _ _)
                (match abi
                  [(ast.AstExternAbi.CVarargsTyped _) (set! st.ok? false)]
                  [_ unit])
                (if (ast.ast-extern-abi-c? abi)
                  (ir.compiler-ir-symbol-text sym-id)
                  (string.copy (intern.intern-compat-state-str interns link-id)))])]
          [(LookupMissing)
            ;; Builtin/runtime symbol (not defined in this library or extern table).
            (ir.compiler-ir-symbol-text sym-id)])])))

(define (tli-ir-enc-global-symbol!
  [tables : (& TliIrEncodeTables)]
  [interns : (& intern.InternCompatState)]
  [st : (&mut TliIrBodyEncodeState)]
  [whole-externs : (& ir.CompilerIrExternSeq)]
  [sym-id : i64]) : String
  (let
    [sid : i64 (ir.compiler-ir-symbol-id sym-id)]
    (match (i64_map.get (& tables.gl-id-to-idx) sid)
      [(LookupFound gidx)
        (if (array-ref tables.gl-private gidx)
          (begin
            (unless (array-ref tables.gl-literal gidx) (set! st.ok? false))
            (ir.compiler-ir-symbol-text sym-id))
          (begin
            (unless
              (i64_map.contains? (& st.ref-gls-seen) gidx)
              (i64_map.insert-ref! (&mut st.ref-gls-seen) gidx 1)
              (i64_vec.push-ref! (&mut st.ref-gls) gidx))
            (string.copy (& (array-ref tables.gl-link-syms gidx)))))]
      [(LookupMissing)
        (match (i64_map.get (& tables.fn-id-to-idx) sid)
          [(LookupFound fidx)
            (when
              (or (array-ref tables.fn-skip fidx) (= fidx st.self-fn-idx))
              (set! st.ok? false))
            (when
              (and
                (!= fidx st.self-fn-idx)
                (not (i64_map.contains? (& st.ref-fns-seen) fidx)))
              (i64_map.insert-ref! (&mut st.ref-fns-seen) fidx 1)
              (i64_vec.push-ref! (&mut st.ref-fns) fidx))
            (string.copy (& (array-ref tables.fn-link-syms fidx)))]
          [(LookupMissing)
            (match (i64_map.get (& tables.ex-id-to-idx) sid)
              [(LookupFound eidx)
                (unless
                  (i64_map.contains? (& st.ref-exs-seen) eidx)
                  (i64_map.insert-ref! (&mut st.ref-exs-seen) eidx 1)
                  (i64_vec.push-ref! (&mut st.ref-exs) eidx))
                (match (ir.compiler-ir-extern-seq-borrow whole-externs eidx)
                  [(ir.CompilerIrExtern.Extern _ _ _ _ abi link-id _ _ _ _ _)
                    (if (ast.ast-extern-abi-c? abi)
                      (ir.compiler-ir-symbol-text sym-id)
                      (string.copy
                        (intern.intern-compat-state-str interns link-id)))])]
              [(LookupMissing) (ir.compiler-ir-symbol-text sym-id)])])])))

;; A consumer sees this library's cells through word-storage externs, so a
;; read of an inline cell travels as its address (the same value it has here).
(define (tli-ir-enc-inline-cell?
  [tables : (& TliIrEncodeTables)]
  [whole-externs : (& ir.CompilerIrExternSeq)]
  [sym-id : i64]) : bool
  (let
    [sid : i64 (ir.compiler-ir-symbol-id sym-id)]
    (match (i64_map.get (& tables.gl-id-to-idx) sid)
      [(LookupFound gidx) (array-ref tables.gl-inline gidx)]
      [(LookupMissing)
        (match (i64_map.get (& tables.ex-id-to-idx) sid)
          [(LookupFound eidx)
            (match (ir.compiler-ir-extern-seq-borrow whole-externs eidx)
              [(ir.CompilerIrExtern.Extern _ _ _ _ _ _ _ _ _ _ storage)
                (> (ir.compiler-ir-global-storage-inline-size (& storage)) 0)])]
          [(LookupMissing) false])])))

(define (tli-ir-enc-value!
  [tables : (& TliIrEncodeTables)]
  [interns : (& intern.InternCompatState)]
  [st : (&mut TliIrBodyEncodeState)]
  [whole-externs : (& ir.CompilerIrExternSeq)]
  [value : (& ir.CompilerIrValue)]) : tli.TliCompactValue
  (match value
    [(ir.CompilerIrValue.Var v) (tli.TliCompactValue.Var v)]
    [(ir.CompilerIrValue.Global g)
      (if (tli-ir-enc-inline-cell? tables whole-externs g)
        (tli.TliCompactValue.GlobalAddr
          (tli-ir-enc-global-symbol! tables interns st whole-externs g))
        (tli.TliCompactValue.Global
          (tli-ir-enc-global-symbol! tables interns st whole-externs g)))]
    [(ir.CompilerIrValue.GlobalAddr g)
      (tli.TliCompactValue.GlobalAddr
        (tli-ir-enc-global-symbol! tables interns st whole-externs g))]
    [(ir.CompilerIrValue.Function f)
      (tli.TliCompactValue.Function
        (tli-ir-enc-fn-symbol! tables interns st whole-externs f))]
    [(ir.CompilerIrValue.I64 n) (tli.TliCompactValue.I64 n)]
    [(ir.CompilerIrValue.F64 bits)
      (tli.TliCompactValue.F64Bits (cast bits : i64))]
    [(ir.CompilerIrValue.Bool b) (tli.TliCompactValue.Bool b)]
    [(ir.CompilerIrValue.Char c) (tli.TliCompactValue.Char (cast c : i64))]
    [(ir.CompilerIrValue.String s) (tli.TliCompactValue.String (string.copy s))]
    [(ir.CompilerIrValue.Bytes s)
      (tli.TliCompactValue.Bytes (tli-compact-bytes-from-string s))]
    [(ir.CompilerIrValue.Unit) (tli.TliCompactValue.Unit)]
    [(ir.CompilerIrValue.StaticArray s)
      (tli.TliCompactValue.StaticArray (tli-compact-bytes-from-string s))]
    [(ir.CompilerIrValue.RuntimeGlobal _)
      (set! st.ok? false)
      (tli.TliCompactValue.Unit)]))

(define (tli-ir-enc-call-args!
  [tables : (& TliIrEncodeTables)]
  [interns : (& intern.InternCompatState)]
  [st : (&mut TliIrBodyEncodeState)]
  [whole-externs : (& ir.CompilerIrExternSeq)]
  [args : (& ir.CompilerIrCallArgs)]) : tli.TliCompactCallArgs
  (match args
    [(ir.CompilerIrCallArgs.Nil)
      (tli.TliCompactCallArgs (__tl_make-array tli.TliCompactValue 0) -1)]
    [(ir.CompilerIrCallArgs.One v)
      (let
        [out : (__tl_dyn-array tli.TliCompactValue)
          (__tl_make-array tli.TliCompactValue 1)]
        (set!
          (array-ref out 0)
          (tli-ir-enc-value! tables interns st whole-externs v))
        (tli.TliCompactCallArgs out -1))]
    [(ir.CompilerIrCallArgs.Two a b)
      (let
        [out : (__tl_dyn-array tli.TliCompactValue)
          (__tl_make-array tli.TliCompactValue 2)]
        (set!
          (array-ref out 0)
          (tli-ir-enc-value! tables interns st whole-externs a))
        (set!
          (array-ref out 1)
          (tli-ir-enc-value! tables interns st whole-externs b))
        (tli.TliCompactCallArgs out -1))]
    [(ir.CompilerIrCallArgs.Array vals)
      (let
        [n : i64 (array-length vals)]
        [out : (__tl_dyn-array tli.TliCompactValue)
          (__tl_make-array tli.TliCompactValue n)]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref out i)
            (tli-ir-enc-value!
              tables
              interns
              st
              whole-externs
              (& (array-ref vals i)))))
        (tli.TliCompactCallArgs out -1))]
    [(ir.CompilerIrCallArgs.Sret vals sret-idx)
      (let
        [n : i64 (array-length vals)]
        [out : (__tl_dyn-array tli.TliCompactValue)
          (__tl_make-array tli.TliCompactValue n)]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref out i)
            (tli-ir-enc-value!
              tables
              interns
              st
              whole-externs
              (& (array-ref vals i)))))
        (tli.TliCompactCallArgs out sret-idx))]))

(define (tli-ir-enc-binop
  [pools : ast.AstNodePoolContext]
  [interns : (& intern.InternCompatState)]
  [op : (& ir.CompilerIrBinOp)]) : tli.TliCompactBinOp
  (match op
    [(ir.CompilerIrBinOp.Add) (tli.TliCompactBinOp.Add)]
    [(ir.CompilerIrBinOp.Sub) (tli.TliCompactBinOp.Sub)]
    [(ir.CompilerIrBinOp.Mul) (tli.TliCompactBinOp.Mul)]
    [(ir.CompilerIrBinOp.Div) (tli.TliCompactBinOp.Div)]
    [(ir.CompilerIrBinOp.Mod) (tli.TliCompactBinOp.Mod)]
    [(ir.CompilerIrBinOp.SafeDiv) (tli.TliCompactBinOp.SafeDiv)]
    [(ir.CompilerIrBinOp.SafeMod) (tli.TliCompactBinOp.SafeMod)]
    [(ir.CompilerIrBinOp.Eq) (tli.TliCompactBinOp.Eq)]
    [(ir.CompilerIrBinOp.Ne) (tli.TliCompactBinOp.Ne)]
    [(ir.CompilerIrBinOp.Lt) (tli.TliCompactBinOp.Lt)]
    [(ir.CompilerIrBinOp.Le) (tli.TliCompactBinOp.Le)]
    [(ir.CompilerIrBinOp.Gt) (tli.TliCompactBinOp.Gt)]
    [(ir.CompilerIrBinOp.Ge) (tli.TliCompactBinOp.Ge)]
    [(ir.CompilerIrBinOp.BitTestEq) (tli.TliCompactBinOp.BitTestEq)]
    [(ir.CompilerIrBinOp.BitTestNe) (tli.TliCompactBinOp.BitTestNe)]
    [(ir.CompilerIrBinOp.And) (tli.TliCompactBinOp.And)]
    [(ir.CompilerIrBinOp.Or) (tli.TliCompactBinOp.Or)]
    [(ir.CompilerIrBinOp.BitAnd) (tli.TliCompactBinOp.BitAnd)]
    [(ir.CompilerIrBinOp.BitOr) (tli.TliCompactBinOp.BitOr)]
    [(ir.CompilerIrBinOp.BitXor) (tli.TliCompactBinOp.BitXor)]
    [(ir.CompilerIrBinOp.Shl ty)
      (tli.TliCompactBinOp.Shl (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrBinOp.Shr ty)
      (tli.TliCompactBinOp.Shr (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrBinOp.Rotr) (tli.TliCompactBinOp.Rotr)]))

(define (tli-ir-enc-unop [op : (& ir.CompilerIrUnOp)]) : tli.TliCompactUnOp
  (match op
    [(ir.CompilerIrUnOp.Neg) (tli.TliCompactUnOp.Neg)]
    [(ir.CompilerIrUnOp.Not) (tli.TliCompactUnOp.Not)]
    [(ir.CompilerIrUnOp.BitNot) (tli.TliCompactUnOp.BitNot)]
    [(ir.CompilerIrUnOp.Sqrt) (tli.TliCompactUnOp.Sqrt)]
    [(ir.CompilerIrUnOp.BitLength) (tli.TliCompactUnOp.BitLength)]))

(define (tli-ir-enc-instr!
  [pools : ast.AstNodePoolContext]
  [tables : (& TliIrEncodeTables)]
  [interns : (& intern.InternCompatState)]
  [st : (&mut TliIrBodyEncodeState)]
  [whole-externs : (& ir.CompilerIrExternSeq)]
  [instr : (& ir.CompilerIrInstr)]) : tli.TliCompactInstr
  (match instr
    [(ir.CompilerIrInstr.Mov dst v ty)
      (tli.TliCompactInstr.Mov
        dst
        (tli-ir-enc-value! tables interns st whole-externs v)
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.Alloc dst ty)
      (tli.TliCompactInstr.Alloc
        dst
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.AddrOf dst src words)
      (tli.TliCompactInstr.AddrOf dst src words)]
    [(ir.CompilerIrInstr.Gep dst base idx ty)
      (tli.TliCompactInstr.Gep
        dst
        (tli-ir-enc-value! tables interns st whole-externs base)
        (tli-ir-enc-value! tables interns st whole-externs idx)
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.Load dst ptr ty)
      (tli.TliCompactInstr.Load
        dst
        (tli-ir-enc-value! tables interns st whole-externs ptr)
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.StoreOwned dst v ty)
      (tli.TliCompactInstr.StoreOwned
        (tli-ir-enc-value! tables interns st whole-externs dst)
        (tli-ir-enc-value! tables interns st whole-externs v)
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.StorePtr dst v ty)
      (tli.TliCompactInstr.StorePtr
        (tli-ir-enc-value! tables interns st whole-externs dst)
        (tli-ir-enc-value! tables interns st whole-externs v)
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.CopyBytes dst src bytes)
      (tli.TliCompactInstr.CopyBytes
        (tli-ir-enc-value! tables interns st whole-externs dst)
        (tli-ir-enc-value! tables interns st whole-externs src)
        bytes)]
    [(ir.CompilerIrInstr.BoundsCheck idx len ok-label)
      (tli.TliCompactInstr.BoundsCheck
        (tli-ir-enc-value! tables interns st whole-externs idx)
        (tli-ir-enc-value! tables interns st whole-externs len)
        (tli-ir-enc-label! st ok-label))]
    [(ir.CompilerIrInstr.Cast dst v from-ty to-ty)
      (tli.TliCompactInstr.Cast
        dst
        (tli-ir-enc-value! tables interns st whole-externs v)
        (tli-compact-type-from-ast pools interns from-ty)
        (tli-compact-type-from-ast pools interns to-ty))]
    [(ir.CompilerIrInstr.Bitcast dst v from-ty to-ty)
      (tli.TliCompactInstr.Bitcast
        dst
        (tli-ir-enc-value! tables interns st whole-externs v)
        (tli-compact-type-from-ast pools interns from-ty)
        (tli-compact-type-from-ast pools interns to-ty))]
    [(ir.CompilerIrInstr.BinOp dst op a b ty)
      (tli.TliCompactInstr.BinOp
        dst
        (tli-ir-enc-binop pools interns op)
        (tli-ir-enc-value! tables interns st whole-externs a)
        (tli-ir-enc-value! tables interns st whole-externs b)
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.UnOp dst op v ty)
      (tli.TliCompactInstr.UnOp
        dst
        (tli-ir-enc-unop op)
        (tli-ir-enc-value! tables interns st whole-externs v)
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.Call dst callee args ty)
      (set! st.has-call? true)
      (tli.TliCompactInstr.Call
        dst
        (tli-ir-enc-fn-symbol! tables interns st whole-externs callee)
        (tli-ir-enc-call-args! tables interns st whole-externs args)
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.CallIndirect dst callee args ty)
      (set! st.has-call? true)
      (tli.TliCompactInstr.CallIndirect
        dst
        (tli-ir-enc-value! tables interns st whole-externs callee)
        (tli-ir-enc-call-args! tables interns st whole-externs args)
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.CallIndirectC dst callee args ty)
      (set! st.has-call? true)
      (tli.TliCompactInstr.CallIndirectC
        dst
        (tli-ir-enc-value! tables interns st whole-externs callee)
        (tli-ir-enc-call-args! tables interns st whole-externs args)
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.TailCall callee args ty)
      (set! st.has-call? true)
      (tli.TliCompactInstr.TailCall
        (tli-ir-enc-fn-symbol! tables interns st whole-externs callee)
        (tli-ir-enc-call-args! tables interns st whole-externs args)
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.Store g v ty)
      (tli.TliCompactInstr.Store
        (tli-ir-enc-global-symbol! tables interns st whole-externs g)
        (tli-ir-enc-value! tables interns st whole-externs v)
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.Jump lbl)
      (tli.TliCompactInstr.Jump (tli-ir-enc-label! st lbl))]
    [(ir.CompilerIrInstr.Branch cond t-lbl f-lbl)
      (tli.TliCompactInstr.Branch
        (tli-ir-enc-value! tables interns st whole-externs cond)
        (tli-ir-enc-label! st t-lbl)
        (tli-ir-enc-label! st f-lbl))]
    [(ir.CompilerIrInstr.TotalEnumBranch cond t-lbl f-lbl)
      (tli.TliCompactInstr.TotalEnumBranch
        (tli-ir-enc-value! tables interns st whole-externs cond)
        (tli-ir-enc-label! st t-lbl)
        (tli-ir-enc-label! st f-lbl))]
    [(ir.CompilerIrInstr.Return maybe-v)
      (match maybe-v
        [(ir.CompilerIrMaybeValue.Some v)
          (tli.TliCompactInstr.Return
            true
            (tli-ir-enc-value! tables interns st whole-externs v))]
        [(ir.CompilerIrMaybeValue.No)
          (tli.TliCompactInstr.Return false (tli.TliCompactValue.Unit))])]
    [(ir.CompilerIrInstr.Phi dst inputs ty)
      (let
        [n : i64 (ir.compiler-ir-phi-input-seq-count inputs)]
        [out : (__tl_dyn-array tli.TliCompactPhiInput)
          (__tl_make-array tli.TliCompactPhiInput n)]
        (for [i (iterator.range 0 n)]
          (let
            [inp : ir.CompilerIrPhiInput
              (ir.compiler-ir-phi-input-seq-ref inputs i)]
            (set!
              (array-ref out i)
              (tli.TliCompactPhiInput
                (tli-ir-enc-value!
                  tables
                  interns
                  st
                  whole-externs
                  (& inp.value))
                (tli-ir-enc-label! st inp.label)))))
        (tli.TliCompactInstr.Phi
          dst
          out
          (tli-compact-type-from-ast pools interns ty)))]
    [(ir.CompilerIrInstr.Pack dst vals ty)
      (let
        [n : i64 (ir.compiler-ir-value-seq-count vals)]
        [out : (__tl_dyn-array tli.TliCompactValue)
          (__tl_make-array tli.TliCompactValue n)]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref out i)
            (tli-ir-enc-value!
              tables
              interns
              st
              whole-externs
              (ir.compiler-ir-value-seq-borrow vals i))))
        (tli.TliCompactInstr.Pack
          dst
          out
          (tli-compact-type-from-ast pools interns ty)))]
    [(ir.CompilerIrInstr.Word dst v idx ty)
      (tli.TliCompactInstr.Word
        dst
        (tli-ir-enc-value! tables interns st whole-externs v)
        idx
        (tli-compact-type-from-ast pools interns ty))]
    [(ir.CompilerIrInstr.Switch v def-lbl cases disc-bytes)
      (let
        [n : i64 (ir.compiler-ir-switch-case-seq-count cases)]
        [out : (__tl_dyn-array tli.TliCompactSwitchCase)
          (__tl_make-array tli.TliCompactSwitchCase n)]
        (for [i (iterator.range 0 n)]
          (match (ir.compiler-ir-switch-case-seq-borrow cases i)
            [(ir.CompilerIrSwitchCase.Case cv cl)
              (set!
                (array-ref out i)
                (tli.TliCompactSwitchCase cv (tli-ir-enc-label! st cl)))]))
        (tli.TliCompactInstr.Switch
          (tli-ir-enc-value! tables interns st whole-externs v)
          (tli-ir-enc-label! st def-lbl)
          out
          disc-bytes))]
    [(ir.CompilerIrInstr.TotalEnumSwitch v def-lbl cases disc-bytes trap-lbl)
      (let
        [n : i64 (ir.compiler-ir-switch-case-seq-count cases)]
        [out : (__tl_dyn-array tli.TliCompactSwitchCase)
          (__tl_make-array tli.TliCompactSwitchCase n)]
        (for [i (iterator.range 0 n)]
          (match (ir.compiler-ir-switch-case-seq-borrow cases i)
            [(ir.CompilerIrSwitchCase.Case cv cl)
              (set!
                (array-ref out i)
                (tli.TliCompactSwitchCase cv (tli-ir-enc-label! st cl)))]))
        (tli.TliCompactInstr.TotalEnumSwitch
          (tli-ir-enc-value! tables interns st whole-externs v)
          (tli-ir-enc-label! st def-lbl)
          out
          disc-bytes
          (tli-ir-enc-label! st trap-lbl)))]
    [_
      (set! st.ok? false)
      (tli.TliCompactInstr.Jump 0)]))

(defenum TliEncodeCompactIrBodyResult
  (No)
  (Ok tli.TliCompactIrBody))

(define (tli-compact-physical-fn-sig
  [pools : ast.AstNodePoolContext]
  [interns : (& intern.InternCompatState)]
  [params : (& ir.CompilerIrParamSeq)]
  [ret : (& ast.AstType)]) : tli.TliType
  (let
    [n : i64 (ir.compiler-ir-param-seq-count params)]
    [ptypes : (__tl_dyn-array tli.TliType) (__tl_make-array tli.TliType n)]
    (for [i (iterator.range 0 n)]
      (match (ir.compiler-ir-param-seq-borrow params i)
        [(ir.CompilerIrParam.Param _ pty _)
          (set!
            (array-ref ptypes i)
            (tli-compact-type-from-ast pools interns pty))]))
    (tli.TliType.Func
      ptypes
      (box (tli-compact-type-from-ast pools interns ret)))))

(define (tli-encode-compact-ir-function
  [pools : ast.AstNodePoolContext]
  [tables : (& TliIrEncodeTables)]
  [interns : (& intern.InternCompatState)]
  [whole-globals : (& ir.CompilerIrGlobalSeq)]
  [whole-functions : (& ir.CompilerIrFunctionSeq)]
  [whole-externs : (& ir.CompilerIrExternSeq)]
  [fn-idx : i64]) : TliEncodeCompactIrBodyResult
  (if (not
    (opt.opt-inline-compact-ir-eligible?
      (ir.compiler-ir-function-seq-borrow whole-functions fn-idx)))
    (No)
    (match (ir.compiler-ir-function-seq-borrow whole-functions fn-idx)
      [(ir.CompilerIrFunction.Function _ params ret-ty next-var blocks abi)
        (match blocks
          [(ir.CompilerIrBlockList.Array bseq)
            (let
              [bcount : i64 (ir.compiler-ir-block-seq-count bseq)]
              [pcount : i64 (ir.compiler-ir-param-seq-count params)]
              [st : TliIrBodyEncodeState
                (TliIrBodyEncodeState
                  fn-idx
                  true
                  false
                  (i64_map.with-capacity (* (+ bcount 4) 2))
                  0
                  (i64_map.with-capacity 16)
                  (i64_vec.new)
                  (i64_map.with-capacity 8)
                  (i64_vec.new)
                  (i64_map.with-capacity 8)
                  (i64_vec.new))]
              [out-params : (__tl_dyn-array tli.TliCompactParam)
                (__tl_make-array tli.TliCompactParam pcount)]
              [out-blocks : (__tl_dyn-array tli.TliCompactBlock)
                (__tl_make-array tli.TliCompactBlock bcount)]
              [total-instrs : i64 0]
              ;; Assign dense labels 0..bcount-1 to blocks in order first.
              (for [bi (iterator.range 0 bcount)]
                (match (ir.compiler-ir-block-seq-borrow bseq bi)
                  [(ir.CompilerIrBlock.Block blbl _)
                    (tli-ir-enc-label! (&mut st) blbl)]))
              (for [pi (iterator.range 0 pcount)]
                (match (ir.compiler-ir-param-seq-borrow params pi)
                  [(ir.CompilerIrParam.Param pname pty pvar)
                    (set!
                      (array-ref out-params pi)
                      (tli.TliCompactParam
                        (string.copy pname)
                        (tli-compact-type-from-ast pools interns pty)
                        pvar))]))
              (for [bi (iterator.range 0 bcount)]
                (match (ir.compiler-ir-block-seq-borrow bseq bi)
                  [(ir.CompilerIrBlock.Block blbl iseq)
                    (let
                      [icount : i64 (ir.compiler-ir-instr-seq-count iseq)]
                      [out-instrs : (__tl_dyn-array tli.TliCompactInstr)
                        (__tl_make-array tli.TliCompactInstr icount)]
                      (set! total-instrs (+ total-instrs icount))
                      (for [ii (iterator.range 0 icount)]
                        (set!
                          (array-ref out-instrs ii)
                          (tli-ir-enc-instr!
                            pools
                            tables
                            interns
                            (&mut st)
                            whole-externs
                            (ir.compiler-ir-instr-seq-borrow iseq ii))))
                      (set!
                        (array-ref out-blocks bi)
                        (tli.TliCompactBlock
                          (tli-ir-enc-label! (&mut st) blbl)
                          out-instrs)))]))
              (if (not st.ok?)
                (No)
                (let
                  [rs : tli.TliCompactReturnStorage
                    (match abi
                      [(ir.CompilerIrFunctionAbi.Ordinary)
                        (tli.TliCompactReturnStorage.None)]
                      [(ir.CompilerIrFunctionAbi.ReturnStorage rs-box)
                        (tli-compact-return-storage-abi-from-ir
                          pools
                          interns
                          (& (deref rs-box)))]
                      [_ (tli.TliCompactReturnStorage.None)])]
                  [refs : ext_ref_vec.Vec (ext_ref_vec.new)]
                  (for [ri (iterator.range 0 (i64_vec.len (& st.ref-fns)))]
                    (let
                      [cidx : i64 (i64_vec.get (& st.ref-fns) ri 0)]
                      (match (ir.compiler-ir-function-seq-borrow
                        whole-functions
                        cidx)
                        [(ir.CompilerIrFunction.Function
                            _
                            cparams
                            cret
                            _
                            _
                            cabi)
                          (let
                            [lsym : String
                              (string.copy
                                (& (array-ref tables.fn-link-syms cidx)))]
                            [crs : tli.TliCompactReturnStorage
                              (match cabi
                                [(ir.CompilerIrFunctionAbi.ReturnStorage rbox)
                                  (tli-compact-return-storage-abi-from-ir
                                    pools
                                    interns
                                    (& (deref rbox)))]
                                [_ (tli.TliCompactReturnStorage.None)])]
                            (ext_ref_vec.push-ref!
                              (&mut refs)
                              (tli.TliCompactExternRef
                                (string.copy (& lsym))
                                0
                                lsym
                                (tli-compact-physical-fn-sig
                                  pools
                                  interns
                                  cparams
                                  cret)
                                crs)))])))
                  (for [ri (iterator.range 0 (i64_vec.len (& st.ref-gls)))]
                    (let
                      [gidx : i64 (i64_vec.get (& st.ref-gls) ri 0)]
                      (match (ir.compiler-ir-global-seq-borrow
                        whole-globals
                        gidx)
                        [(ir.CompilerIrGlobal.Global _ gty _ _)
                          (let
                            [lsym : String
                              (string.copy
                                (& (array-ref tables.gl-link-syms gidx)))]
                            (ext_ref_vec.push-ref!
                              (&mut refs)
                              (tli.TliCompactExternRef
                                (string.copy (& lsym))
                                0
                                lsym
                                (tli-compact-type-from-ast pools interns gty)
                                (tli.TliCompactReturnStorage.None))))])))
                  (for [ri (iterator.range 0 (i64_vec.len (& st.ref-exs)))]
                    (let
                      [eidx : i64 (i64_vec.get (& st.ref-exs) ri 0)]
                      (match (ir.compiler-ir-extern-seq-borrow
                        whole-externs
                        eidx)
                        [(ir.CompilerIrExtern.Extern
                            ename
                            _
                            _
                            ety
                            eabi
                            elink
                            _
                            _
                            estorage
                            _
                            _)
                          (let
                            [abi-tag : i64
                              (match eabi
                                [(ast.AstExternAbi.TypeLisp) 0]
                                [(ast.AstExternAbi.C) 1]
                                [(ast.AstExternAbi.CVarargsOpen) 2]
                                [_ 1])]
                            [link-str : String
                              (string.copy
                                (intern.intern-compat-state-str interns elink))]
                            [sym-str : String
                              (if (ast.ast-extern-abi-c? eabi)
                                (ir.compiler-ir-symbol-text ename)
                                (string.copy (& link-str)))]
                            (ext_ref_vec.push-ref!
                              (&mut refs)
                              (tli.TliCompactExternRef
                                sym-str
                                abi-tag
                                link-str
                                (tli-compact-type-from-ast pools interns ety)
                                (tli-compact-return-storage-from-ir
                                  pools
                                  interns
                                  estorage))))])))
                  (let
                    [rcount : i64 (ext_ref_vec.len (& refs))]
                    [out-refs : (__tl_dyn-array tli.TliCompactExternRef)
                      (__tl_make-array tli.TliCompactExternRef rcount)]
                    (for [i (iterator.range 0 rcount)]
                      (set!
                        (array-ref out-refs i)
                        (tli-clone-compact-extern-ref
                          (& (array-ref refs.slots i)))))
                    (Ok
                      (tli.TliCompactIrBody
                        (if st.has-call?
                          0
                          tli.tli-compact-ir-call-free)
                        total-instrs
                        out-params
                        (tli-compact-type-from-ast pools interns ret-ty)
                        next-var
                        out-blocks
                        rs
                        out-refs))))))])])))

;; Attach packed optimizer facts, `HAS_IR` compact IR bodies, and available-
;; externally `compact_globals` to `bundle` from a lowered library program.
(define (tli-attach-compact-ir!
  [bundle : (&mut bundle tli.TliBundle)]
  [pools : ast.AstNodePoolContext]
  [interns : (& intern.InternCompatState)]
  [whole-globals : (& ir.CompilerIrGlobalSeq)]
  [whole-functions : (& ir.CompilerIrFunctionSeq)]
  [whole-externs : (& ir.CompilerIrExternSeq)]
  [fn-skip : (& (__tl_dyn-array bool))]
  [fn-link-syms : (& (__tl_dyn-array String))]
  [gl-link-syms : (& (__tl_dyn-array String))]
  [gl-private : (& (__tl_dyn-array bool))]) : unit
  (let
    [fn-count : i64 whole-functions.len]
    [gl-count : i64 whole-globals.len]
    [ex-count : i64 whole-externs.len]
    [type-segment-bases : i64
      (ast.ast-node-pool-context-type-segment-bases (& pools))]
    [lib-summaries : opt.OptLibrarySummaries
      (opt.opt-build-library-summaries
        type-segment-bases
        whole-globals
        whole-externs
        whole-functions)]
    [fn-id-to-idx : i64_map.Map (i64_map.with-capacity (* (+ fn-count 1) 2))]
    [fn-logical-to-idx : str_map.Map
      (str_map.with-capacity (* (+ fn-count 1) 2))]
    [fn-link-to-idx : str_map.Map (str_map.with-capacity (* (+ fn-count 1) 2))]
    [gl-id-to-idx : i64_map.Map (i64_map.with-capacity (* (+ gl-count 1) 2))]
    [ex-id-to-idx : i64_map.Map (i64_map.with-capacity (* (+ ex-count 1) 2))]
    [fn-skip-copy : (__tl_dyn-array bool) (__tl_make-array bool fn-count)]
    [fn-links-copy : (__tl_dyn-array String) (__tl_make-array String fn-count)]
    [gl-priv-copy : (__tl_dyn-array bool) (__tl_make-array bool gl-count)]
    [gl-lit-copy : (__tl_dyn-array bool) (__tl_make-array bool gl-count)]
    [gl-inline-copy : (__tl_dyn-array bool) (__tl_make-array bool gl-count)]
    [gl-links-copy : (__tl_dyn-array String) (__tl_make-array String gl-count)]
    [out-globals : global_vec.Vec (global_vec.new)]
    (for [i (iterator.range 0 fn-count)]
      (set! (array-ref fn-skip-copy i) (array-ref (deref fn-skip) i))
      (set!
        (array-ref fn-links-copy i)
        (string.copy (& (array-ref (deref fn-link-syms) i))))
      (match (ir.compiler-ir-function-seq-borrow whole-functions i)
        [(ir.CompilerIrFunction.Function fn-name _ _ _ _ _)
          (i64_map.insert-ref!
            (&mut fn-id-to-idx)
            (ir.compiler-ir-symbol-id fn-name)
            i)
          (unless
            (array-ref fn-skip-copy i)
            (str_map.insert-ref!
              (&mut fn-logical-to-idx)
              (ir.compiler-ir-symbol-text fn-name)
              i)
            (str_map.insert-ref!
              (&mut fn-link-to-idx)
              (string.copy (& (array-ref fn-links-copy i)))
              i))]))
    (for [i (iterator.range 0 ex-count)]
      (match (ir.compiler-ir-extern-seq-borrow whole-externs i)
        [(ir.CompilerIrExtern.Extern ename _ _ _ _ _ _ provided _ _ _)
          (unless
            provided
            (i64_map.insert-ref!
              (&mut ex-id-to-idx)
              (ir.compiler-ir-symbol-id ename)
              i))]))
    (for [i (iterator.range 0 gl-count)]
      (set! (array-ref gl-priv-copy i) (array-ref (deref gl-private) i))
      (set!
        (array-ref gl-links-copy i)
        (string.copy (& (array-ref (deref gl-link-syms) i))))
      (match (ir.compiler-ir-global-seq-borrow whole-globals i)
        [(ir.CompilerIrGlobal.Global gl-name gl-ty gl-init gl-storage)
          (let
            [gid : i64 (ir.compiler-ir-symbol-id gl-name)]
            [written? : bool
              (i64_map.contains? (& lib-summaries.written-globals) gid)]
            (set!
              (array-ref gl-inline-copy i)
              (> (ir.compiler-ir-global-storage-inline-size (& gl-storage)) 0))
            (i64_map.insert-ref! (&mut gl-id-to-idx) gid i)
            (when
              (not written?)
              (let
                [lit-ok? : bool
                  (match gl-init
                    [(or (ir.CompilerIrValue.I64 _) (ir.CompilerIrValue.F64 _)
                         (ir.CompilerIrValue.Bool _) (ir.CompilerIrValue.Char _)
                         (ir.CompilerIrValue.String _)
                         (ir.CompilerIrValue.Bytes _) (ir.CompilerIrValue.Unit)
                         (ir.CompilerIrValue.StaticArray _))
                      true]
                    [_ false])]
                (when
                  lit-ok?
                  (set! (array-ref gl-lit-copy i) true)
                  (let
                    [gsym : String
                      (if (array-ref gl-priv-copy i)
                        (ir.compiler-ir-symbol-text gl-name)
                        (string.copy (& (array-ref gl-links-copy i))))]
                    [gval : tli.TliCompactValue
                      (match gl-init
                        [(ir.CompilerIrValue.I64 n) (tli.TliCompactValue.I64 n)]
                        [(ir.CompilerIrValue.F64 bits)
                          (tli.TliCompactValue.F64Bits (cast bits : i64))]
                        [(ir.CompilerIrValue.Bool b)
                          (tli.TliCompactValue.Bool b)]
                        [(ir.CompilerIrValue.Char c)
                          (tli.TliCompactValue.Char (cast c : i64))]
                        [(ir.CompilerIrValue.String s)
                          (tli.TliCompactValue.String (string.copy s))]
                        [(ir.CompilerIrValue.Bytes s)
                          (tli.TliCompactValue.Bytes
                            (tli-compact-bytes-from-string s))]
                        [(ir.CompilerIrValue.StaticArray s)
                          (tli.TliCompactValue.StaticArray
                            (tli-compact-bytes-from-string s))]
                        [_ (tli.TliCompactValue.Unit)])]
                    (global_vec.push-ref!
                      (&mut out-globals)
                      (tli.TliCompactGlobal
                        gsym
                        (tli-compact-type-from-ast pools interns gl-ty)
                        tli.tli-compact-global-never-written
                        gval)))))))]))
    ;; Index existing SPMD compact-body entries by "mod\0fn\0link" so
    ;; functions eligible for both IR and SPMD merge into kind=3.
    (let
      [tables : TliIrEncodeTables
        (TliIrEncodeTables
          fn-id-to-idx
          gl-id-to-idx
          ex-id-to-idx
          fn-skip-copy
          gl-priv-copy
          gl-lit-copy
          gl-inline-copy
          fn-links-copy
          gl-links-copy)]
      [existing-count : i64 (array-length bundle.compact-bodies)]
      [body-by-key : str_map.Map
        (str_map.with-capacity (* (+ existing-count fn-count 1) 2))]
      [out-bodies : body_vec.Vec
        (body_vec.with-capacity (+ existing-count fn-count))]
      ;; Compute exact whole-library reachability to modules with runtime
      ;; `global-inits` so consumers can prune unused `__tl_mod_init_*` calls
      ;; in O(1) without conservatively dragging in transitive imports.
      [fn-needs-init : (__tl_dyn-array bool) (__tl_make-array bool fn-count)]
      [fn-sym-ids : (__tl_dyn-array i64) (__tl_make-array i64 fn-count)]
      [needs-init-syms : i64_map.Map
        (i64_map.with-capacity (* (+ fn-count gl-count 1) 2))]
      [edge-starts : (__tl_dyn-array i64) (__tl_make-array i64 (+ fn-count 1))]
      [edge-targets : i64_vec.Vec (i64_vec.new)]
      (for [i (iterator.range 0 fn-count)]
        (set! (array-ref fn-needs-init i) false)
        (match (ir.compiler-ir-function-seq-borrow whole-functions i)
          [(ir.CompilerIrFunction.Function fn-name _ _ _ blocks _)
            (set! (array-ref fn-sym-ids i) (ir.compiler-ir-symbol-id fn-name))
            (set! (array-ref edge-starts i) (i64_vec.len (& edge-targets)))
            (let
              [frefs : i64_map.Map (i64_map.with-capacity 16)]
              (match blocks
                [(ir.CompilerIrBlockList.Array bseq)
                  (for [bi
                    (iterator.range 0 (ir.compiler-ir-block-seq-count bseq))]
                    (match (ir.compiler-ir-block-seq-borrow bseq bi)
                      [(ir.CompilerIrBlock.Block _ iseq)
                        (for [ii
                          (iterator.range
                            0
                            (ir.compiler-ir-instr-seq-count iseq))]
                          (tli-compact-scan-ir-all-syms-instr!
                            (ir.compiler-ir-instr-seq-ref iseq ii)
                            (&mut frefs)
                            (&mut edge-targets)))]))])
              unit)]))
      (set! (array-ref edge-starts fn-count) (i64_vec.len (& edge-targets)))
      ;; Seed with every runtime-initialized global (`RuntimeGlobal`), matching
      ;; source-stdlib dead-global pruning: a function that cannot transitively
      ;; reach any runtime-initialized global never observes module startup inits.
      (for [gi (iterator.range 0 gl-count)]
        (match (ir.compiler-ir-global-seq-borrow whole-globals gi)
          [(ir.CompilerIrGlobal.Global gl-name _ gl-init _)
            (match gl-init
              [(ir.CompilerIrValue.RuntimeGlobal _)
                (i64_map.insert-ref!
                  (&mut needs-init-syms)
                  (ir.compiler-ir-symbol-id gl-name)
                  1)]
              [_ unit])]))
      ;; Propagate backwards until fixed point. A global whose initializer names
      ;; a function or global (a stored callback or address) reaches whatever
      ;; that symbol reaches, so it joins the graph as one more edge.
      (let
        [changed? : bool true]
        (while changed?
          (set! changed? false)
          (for [gi (iterator.range 0 gl-count)]
            (match (ir.compiler-ir-global-seq-borrow whole-globals gi)
              [(ir.CompilerIrGlobal.Global gl-name _ gl-init _)
                (let
                  [gsid : i64 (ir.compiler-ir-symbol-id gl-name)]
                  (unless
                    (i64_map.contains? (& needs-init-syms) gsid)
                    (match gl-init
                      [(or (ir.CompilerIrValue.Function sym)
                           (ir.CompilerIrValue.Global sym)
                           (ir.CompilerIrValue.GlobalAddr sym))
                        (when
                          (i64_map.contains?
                            (& needs-init-syms)
                            (ir.compiler-ir-symbol-id sym))
                          (i64_map.insert-ref! (&mut needs-init-syms) gsid 1)
                          (set! changed? true))]
                      [_ unit])))]))
          (for [i (iterator.range 0 fn-count)]
            (unless
              (array-ref fn-needs-init i)
              (let
                [s : i64 (array-ref edge-starts i)]
                [e : i64 (array-ref edge-starts (+ i 1))]
                [hit? : bool false]
                (for [k (iterator.range s e)]
                  (when
                    (and
                      (not hit?)
                      (i64_map.contains?
                        (& needs-init-syms)
                        (i64_vec.get (& edge-targets) k 0)))
                    (set! hit? true)))
                (when
                  hit?
                  (set! (array-ref fn-needs-init i) true)
                  (i64_map.insert-ref!
                    (&mut needs-init-syms)
                    (array-ref fn-sym-ids i)
                    1)
                  (set! changed? true)))))))
      (for [bi (iterator.range 0 existing-count)]
        (let
          [key : String
            (str_cat.str-cat
              (string.copy (& (array-ref bundle.compact-bodies bi).module-name))
              "|"
              (string.copy (& (array-ref bundle.compact-bodies bi).fn-name))
              "|"
              (string.copy (& (array-ref bundle.compact-bodies bi).link-symbol)))]
          (str_map.insert-ref! (&mut body-by-key) key bi)
          (body_vec.push-ref!
            (&mut out-bodies)
            (tli-clone-compact-body-entry
              (& (array-ref bundle.compact-bodies bi))))))
      (for [mi (iterator.range 0 (array-length bundle.modules))]
        (let
          [mod-name : String
            (string.copy (& (array-ref bundle.modules mi).name))]
          [mod-source-path : String
            (string.copy (& (array-ref bundle.modules mi).source-path))]
          [mfn-count : i64
            (array-length (array-ref bundle.modules mi).functions)]
          (for [fi (iterator.range 0 mfn-count)]
            (let
              [is-ext : bool
                (array-ref (array-ref bundle.modules mi).functions fi).is-extern]
              [lsym : String
                (string.copy
                  (&
                    (array-ref (array-ref bundle.modules mi).functions fi).link-symbol))]
              [exp-sym : String
                (string.copy
                  (&
                    (array-ref (array-ref bundle.modules mi).functions fi).export-symbol))]
              [fname : String
                (string.copy
                  (&
                    (array-ref (array-ref bundle.modules mi).functions fi).name))]
              (unless
                is-ext
                (let
                  [qual-key : String
                    (cond
                      [(> (string.string-length (& mod-source-path)) 0)
                        (str_cat.str-cat
                          (string.copy (& mod-source-path))
                          "::"
                          (string.copy (& lsym)))]
                      [(> (string.string-length (& mod-name)) 0)
                        (str_cat.str-cat
                          (string.copy (& mod-name))
                          "/"
                          (string.copy (& lsym)))]
                      [else (string.copy (& lsym))])]
                  [fidx0 : i64
                    (str_map.get-value-or (& fn-logical-to-idx) qual-key -1)]
                  [fidx1 : i64
                    (if (>= fidx0 0)
                      fidx0
                      (str_map.get-value-or
                        (& fn-logical-to-idx)
                        (string.copy (& lsym))
                        -1))]
                  [fidx2 : i64
                    (if (>= fidx1 0)
                      fidx1
                      (str_map.get-value-or
                        (& fn-link-to-idx)
                        (string.copy (& lsym))
                        -1))]
                  [fidx : i64
                    (if (or
                      (>= fidx2 0)
                      (= (string.string-length (& exp-sym)) 0))
                      fidx2
                      (str_map.get-value-or
                        (& fn-link-to-idx)
                        (string.copy (& exp-sym))
                        -1))]
                  (when
                    (>= fidx 0)
                    (let
                      [fsym-id : i64
                        (match (ir.compiler-ir-function-seq-borrow
                          whole-functions
                          fidx)
                          [(ir.CompilerIrFunction.Function fn-name _ _ _ _ _)
                            (ir.compiler-ir-symbol-id fn-name)])]
                      [cm : i64
                        (i64_map.get-value-or
                          (& lib-summaries.call-memory)
                          fsym-id
                          -1)]
                      [cc : i64
                        (i64_map.get-value-or
                          (& lib-summaries.direct-call-clean)
                          fsym-id
                          0)]
                      [ra : i64
                        (i64_map.get-value-or
                          (& lib-summaries.return-alias)
                          fsym-id
                          0)]
                      (set!
                        (array-ref (array-ref bundle.modules mi).functions fi).summary.call-memory
                        cm)
                      (set!
                        (array-ref (array-ref bundle.modules mi).functions fi).summary.call-clean
                        (cast (bit-and cc 15) : u8))
                      (set!
                        (array-ref (array-ref bundle.modules mi).functions fi).summary.return-alias
                        ra)
                      (unless
                        (array-ref fn-needs-init fidx)
                        (set!
                          (array-ref (array-ref bundle.modules mi).functions fi).summary.effect-flags
                          (bit-or
                            (array-ref
                              (array-ref bundle.modules mi).functions
                              fi).summary.effect-flags
                            tli.tli-fn-no-module-inits)))
                      (match (tli-encode-compact-ir-function
                        pools
                        (& tables)
                        interns
                        whole-globals
                        whole-functions
                        whole-externs
                        fidx)
                        [(No) unit]
                        [(Ok ir-body)
                          (let
                            [flags : i64
                              (array-ref
                                (array-ref bundle.modules mi).functions
                                fi).summary.effect-flags]
                            [key : String
                              (str_cat.str-cat
                                (string.copy (& mod-name))
                                "|"
                                (string.copy (& fname))
                                "|"
                                (string.copy (& lsym)))]
                            [existing-idx : i64
                              (str_map.get-value-or (& body-by-key) key -1)]
                            (set!
                              (array-ref
                                (array-ref bundle.modules mi).functions
                                fi).summary.effect-flags
                              (bit-or flags tli.tli-fn-has-inline-ir))
                            (if (>= existing-idx 0)
                              (begin
                                (set!
                                  (array-ref out-bodies.slots existing-idx).body.kind
                                  (bit-or
                                    (array-ref out-bodies.slots existing-idx).body.kind
                                    tli.tli-compact-body-has-ir))
                                (set!
                                  (array-ref out-bodies.slots existing-idx).body.ir-body
                                  ir-body))
                              (begin
                                (str_map.insert-ref!
                                  (&mut body-by-key)
                                  (str_cat.str-cat
                                    (string.copy (& mod-name))
                                    "|"
                                    (string.copy (& fname))
                                    "|"
                                    (string.copy (& lsym)))
                                  (body_vec.len (& out-bodies)))
                                (body_vec.push-ref!
                                  (&mut out-bodies)
                                  (tli.TliCompactBodyEntry
                                    (string.copy (& mod-name))
                                    fname
                                    lsym
                                    (tli.TliCompactBody
                                      tli.tli-compact-body-has-ir
                                      ir-body
                                      (tli.tli-spmd-expr-empty)))))))])))))))))
      (let
        [gcount : i64 (global_vec.len (& out-globals))]
        [bcount : i64 (body_vec.len (& out-bodies))]
        [final-globals : (__tl_dyn-array tli.TliCompactGlobal)
          (__tl_make-array tli.TliCompactGlobal gcount)]
        [final-bodies : (__tl_dyn-array tli.TliCompactBodyEntry)
          (__tl_make-array tli.TliCompactBodyEntry bcount)]
        (for [i (iterator.range 0 gcount)]
          (set!
            (array-ref final-globals i)
            (tli-clone-compact-global (& (array-ref out-globals.slots i)))))
        (for [i (iterator.range 0 bcount)]
          (set!
            (array-ref final-bodies i)
            (tli-clone-compact-body-entry (& (array-ref out-bodies.slots i)))))
        (set! bundle.compact-globals final-globals)
        (set! bundle.compact-bodies final-bodies)
        (when
          (or (> gcount 0) (> bcount 0))
          (set! bundle.flags (bit-or bundle.flags tli.tli-has-compact-ir)))))))

;; --- Deep clones for compact wire types (used when transferring Vec -> Array) ---
(define (tli-clone-type [ty : (& tli.TliType)]) : tli.TliType
  (match ty
    [(tli.TliType.I64) (tli.TliType.I64)]
    [(tli.TliType.I32) (tli.TliType.I32)]
    [(tli.TliType.I16) (tli.TliType.I16)]
    [(tli.TliType.I8) (tli.TliType.I8)]
    [(tli.TliType.U64) (tli.TliType.U64)]
    [(tli.TliType.U32) (tli.TliType.U32)]
    [(tli.TliType.U16) (tli.TliType.U16)]
    [(tli.TliType.U8) (tli.TliType.U8)]
    [(tli.TliType.F64) (tli.TliType.F64)]
    [(tli.TliType.F32) (tli.TliType.F32)]
    [(tli.TliType.Bool) (tli.TliType.Bool)]
    [(tli.TliType.Char) (tli.TliType.Char)]
    [(tli.TliType.String) (tli.TliType.String)]
    [(tli.TliType.Str) (tli.TliType.Str)]
    [(tli.TliType.Bytes) (tli.TliType.Bytes)]
    [(tli.TliType.Unit) (tli.TliType.Unit)]
    [(tli.TliType.Never) (tli.TliType.Never)]
    [(tli.TliType.Expr) (tli.TliType.Expr)]
    [(tli.TliType.ExprList) (tli.TliType.ExprList)]
    [(tli.TliType.Func args ret)
      (tli.TliType.Func
        (tli-clone-types args)
        (box (tli-clone-type (& (deref ret)))))]
    [(tli.TliType.Tuple items) (tli.TliType.Tuple (tli-clone-types items))]
    [(tli.TliType.Array elem len)
      (tli.TliType.Array (box (tli-clone-type (& (deref elem)))) len)]
    [(tli.TliType.DynArray elem)
      (tli.TliType.DynArray (box (tli-clone-type (& (deref elem)))))]
    [(tli.TliType.Box elem)
      (tli.TliType.Box (box (tli-clone-type (& (deref elem)))))]
    [(tli.TliType.Region l inner)
      (tli.TliType.Region
        (string.copy l)
        (box (tli-clone-type (& (deref inner)))))]
    [(tli.TliType.Ref l inner)
      (tli.TliType.Ref (string.copy l) (box (tli-clone-type (& (deref inner)))))]
    [(tli.TliType.MutRef l inner)
      (tli.TliType.MutRef
        (string.copy l)
        (box (tli-clone-type (& (deref inner)))))]
    [(tli.TliType.Invalidate l inner)
      (tli.TliType.Invalidate
        (string.copy l)
        (box (tli-clone-type (& (deref inner)))))]
    [(tli.TliType.Enum s) (tli.TliType.Enum (string.copy s))]
    [(tli.TliType.EnumArgs s ls)
      (tli.TliType.EnumArgs (string.copy s) (tli-clone-strings ls))]
    [(tli.TliType.Struct s) (tli.TliType.Struct (string.copy s))]
    [(tli.TliType.StructArgs s ls)
      (tli.TliType.StructArgs (string.copy s) (tli-clone-strings ls))]
    [(tli.TliType.Var s) (tli.TliType.Var (string.copy s))]
    [(tli.TliType.VarArgs s ls)
      (tli.TliType.VarArgs (string.copy s) (tli-clone-strings ls))]
    [(tli.TliType.Ptr elem)
      (tli.TliType.Ptr (box (tli-clone-type (& (deref elem)))))]
    [(tli.TliType.MutPtr elem)
      (tli.TliType.MutPtr (box (tli-clone-type (& (deref elem)))))]
    [(tli.TliType.Slice elem)
      (tli.TliType.Slice (box (tli-clone-type (& (deref elem)))))]
    [(tli.TliType.CFunc sig mode)
      (tli.TliType.CFunc (box (tli-clone-type (& (deref sig)))) mode)]))

(define (tli-clone-types [items : (& (__tl_dyn-array tli.TliType))]) : (__tl_dyn-array
    tli.TliType)
  (let
    [n : i64 (array-length (deref items))]
    [out : (__tl_dyn-array tli.TliType) (__tl_make-array tli.TliType n)]
    (for [i (iterator.range 0 n)]
      (set! (array-ref out i) (tli-clone-type (& (array-ref (deref items) i)))))
    out))

(define (tli-clone-strings [items : (& (__tl_dyn-array String))]) : (__tl_dyn-array
    String)
  (let
    [n : i64 (array-length (deref items))]
    [out : (__tl_dyn-array String) (__tl_make-array String n)]
    (for [i (iterator.range 0 n)]
      (set! (array-ref out i) (string.copy (& (array-ref (deref items) i)))))
    out))

(define (tli-clone-u8-array [raw : (& (__tl_dyn-array u8))]) : (__tl_dyn-array
    u8)
  (let
    [n : i64 (array-length (deref raw))]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    (for [i (iterator.range 0 n)]
      (set! (array-ref out i) (array-ref (deref raw) i)))
    out))

(define (tli-clone-compact-value [v : (& tli.TliCompactValue)]) : tli.TliCompactValue
  (match v
    [(tli.TliCompactValue.Var id) (tli.TliCompactValue.Var id)]
    [(tli.TliCompactValue.Global s)
      (tli.TliCompactValue.Global (string.copy s))]
    [(tli.TliCompactValue.GlobalAddr s)
      (tli.TliCompactValue.GlobalAddr (string.copy s))]
    [(tli.TliCompactValue.Function s)
      (tli.TliCompactValue.Function (string.copy s))]
    [(tli.TliCompactValue.I64 n) (tli.TliCompactValue.I64 n)]
    [(tli.TliCompactValue.F64Bits b) (tli.TliCompactValue.F64Bits b)]
    [(tli.TliCompactValue.Bool b) (tli.TliCompactValue.Bool b)]
    [(tli.TliCompactValue.Char c) (tli.TliCompactValue.Char c)]
    [(tli.TliCompactValue.String s)
      (tli.TliCompactValue.String (string.copy s))]
    [(tli.TliCompactValue.Bytes b)
      (tli.TliCompactValue.Bytes (tli-clone-u8-array b))]
    [(tli.TliCompactValue.Unit) (tli.TliCompactValue.Unit)]
    [(tli.TliCompactValue.StaticArray b)
      (tli.TliCompactValue.StaticArray (tli-clone-u8-array b))]))

(define (tli-clone-compact-global [g : (& tli.TliCompactGlobal)]) : tli.TliCompactGlobal
  (tli.TliCompactGlobal
    (string.copy (& g.symbol))
    (tli-clone-type (& g.ty))
    g.flags
    (tli-clone-compact-value (& g.init))))

(define (tli-clone-compact-call-args [args : (& tli.TliCompactCallArgs)]) : tli.TliCompactCallArgs
  (let
    [n : i64 (array-length args.args)]
    [out : (__tl_dyn-array tli.TliCompactValue)
      (__tl_make-array tli.TliCompactValue n)]
    (for [i (iterator.range 0 n)]
      (set!
        (array-ref out i)
        (tli-clone-compact-value (& (array-ref args.args i)))))
    (tli.TliCompactCallArgs out args.sret-index)))

(define (tli-clone-compact-binop [op : (& tli.TliCompactBinOp)]) : tli.TliCompactBinOp
  (match op
    [(tli.TliCompactBinOp.Add) (tli.TliCompactBinOp.Add)]
    [(tli.TliCompactBinOp.Sub) (tli.TliCompactBinOp.Sub)]
    [(tli.TliCompactBinOp.Mul) (tli.TliCompactBinOp.Mul)]
    [(tli.TliCompactBinOp.Div) (tli.TliCompactBinOp.Div)]
    [(tli.TliCompactBinOp.Mod) (tli.TliCompactBinOp.Mod)]
    [(tli.TliCompactBinOp.SafeDiv) (tli.TliCompactBinOp.SafeDiv)]
    [(tli.TliCompactBinOp.SafeMod) (tli.TliCompactBinOp.SafeMod)]
    [(tli.TliCompactBinOp.Eq) (tli.TliCompactBinOp.Eq)]
    [(tli.TliCompactBinOp.Ne) (tli.TliCompactBinOp.Ne)]
    [(tli.TliCompactBinOp.Lt) (tli.TliCompactBinOp.Lt)]
    [(tli.TliCompactBinOp.Le) (tli.TliCompactBinOp.Le)]
    [(tli.TliCompactBinOp.Gt) (tli.TliCompactBinOp.Gt)]
    [(tli.TliCompactBinOp.Ge) (tli.TliCompactBinOp.Ge)]
    [(tli.TliCompactBinOp.BitTestEq) (tli.TliCompactBinOp.BitTestEq)]
    [(tli.TliCompactBinOp.BitTestNe) (tli.TliCompactBinOp.BitTestNe)]
    [(tli.TliCompactBinOp.And) (tli.TliCompactBinOp.And)]
    [(tli.TliCompactBinOp.Or) (tli.TliCompactBinOp.Or)]
    [(tli.TliCompactBinOp.BitAnd) (tli.TliCompactBinOp.BitAnd)]
    [(tli.TliCompactBinOp.BitOr) (tli.TliCompactBinOp.BitOr)]
    [(tli.TliCompactBinOp.BitXor) (tli.TliCompactBinOp.BitXor)]
    [(tli.TliCompactBinOp.Shl ty) (tli.TliCompactBinOp.Shl (tli-clone-type ty))]
    [(tli.TliCompactBinOp.Shr ty) (tli.TliCompactBinOp.Shr (tli-clone-type ty))]
    [(tli.TliCompactBinOp.Rotr) (tli.TliCompactBinOp.Rotr)]))

(define (tli-clone-compact-unop [op : (& tli.TliCompactUnOp)]) : tli.TliCompactUnOp
  (match op
    [(tli.TliCompactUnOp.Neg) (tli.TliCompactUnOp.Neg)]
    [(tli.TliCompactUnOp.Not) (tli.TliCompactUnOp.Not)]
    [(tli.TliCompactUnOp.BitNot) (tli.TliCompactUnOp.BitNot)]
    [(tli.TliCompactUnOp.Sqrt) (tli.TliCompactUnOp.Sqrt)]
    [(tli.TliCompactUnOp.BitLength) (tli.TliCompactUnOp.BitLength)]))

(define (tli-clone-compact-instr [ins : (& tli.TliCompactInstr)]) : tli.TliCompactInstr
  (match ins
    [(tli.TliCompactInstr.Mov d v t)
      (tli.TliCompactInstr.Mov d (tli-clone-compact-value v) (tli-clone-type t))]
    [(tli.TliCompactInstr.Alloc d t)
      (tli.TliCompactInstr.Alloc d (tli-clone-type t))]
    [(tli.TliCompactInstr.AddrOf d s w) (tli.TliCompactInstr.AddrOf d s w)]
    [(tli.TliCompactInstr.Gep d b i t)
      (tli.TliCompactInstr.Gep
        d
        (tli-clone-compact-value b)
        (tli-clone-compact-value i)
        (tli-clone-type t))]
    [(tli.TliCompactInstr.Load d p t)
      (tli.TliCompactInstr.Load
        d
        (tli-clone-compact-value p)
        (tli-clone-type t))]
    [(tli.TliCompactInstr.StoreOwned d v t)
      (tli.TliCompactInstr.StoreOwned
        (tli-clone-compact-value d)
        (tli-clone-compact-value v)
        (tli-clone-type t))]
    [(tli.TliCompactInstr.StorePtr d v t)
      (tli.TliCompactInstr.StorePtr
        (tli-clone-compact-value d)
        (tli-clone-compact-value v)
        (tli-clone-type t))]
    [(tli.TliCompactInstr.CopyBytes d s n)
      (tli.TliCompactInstr.CopyBytes
        (tli-clone-compact-value d)
        (tli-clone-compact-value s)
        n)]
    [(tli.TliCompactInstr.BoundsCheck i l ok)
      (tli.TliCompactInstr.BoundsCheck
        (tli-clone-compact-value i)
        (tli-clone-compact-value l)
        ok)]
    [(tli.TliCompactInstr.Cast d v f t)
      (tli.TliCompactInstr.Cast
        d
        (tli-clone-compact-value v)
        (tli-clone-type f)
        (tli-clone-type t))]
    [(tli.TliCompactInstr.Bitcast d v f t)
      (tli.TliCompactInstr.Bitcast
        d
        (tli-clone-compact-value v)
        (tli-clone-type f)
        (tli-clone-type t))]
    [(tli.TliCompactInstr.BinOp d op a b t)
      (tli.TliCompactInstr.BinOp
        d
        (tli-clone-compact-binop op)
        (tli-clone-compact-value a)
        (tli-clone-compact-value b)
        (tli-clone-type t))]
    [(tli.TliCompactInstr.UnOp d op v t)
      (tli.TliCompactInstr.UnOp
        d
        (tli-clone-compact-unop op)
        (tli-clone-compact-value v)
        (tli-clone-type t))]
    [(tli.TliCompactInstr.Call d s a t)
      (tli.TliCompactInstr.Call
        d
        (string.copy s)
        (tli-clone-compact-call-args a)
        (tli-clone-type t))]
    [(tli.TliCompactInstr.CallIndirect d c a t)
      (tli.TliCompactInstr.CallIndirect
        d
        (tli-clone-compact-value c)
        (tli-clone-compact-call-args a)
        (tli-clone-type t))]
    [(tli.TliCompactInstr.CallIndirectC d c a t)
      (tli.TliCompactInstr.CallIndirectC
        d
        (tli-clone-compact-value c)
        (tli-clone-compact-call-args a)
        (tli-clone-type t))]
    [(tli.TliCompactInstr.TailCall s a t)
      (tli.TliCompactInstr.TailCall
        (string.copy s)
        (tli-clone-compact-call-args a)
        (tli-clone-type t))]
    [(tli.TliCompactInstr.Store g v t)
      (tli.TliCompactInstr.Store
        (string.copy g)
        (tli-clone-compact-value v)
        (tli-clone-type t))]
    [(tli.TliCompactInstr.Jump l) (tli.TliCompactInstr.Jump l)]
    [(tli.TliCompactInstr.Branch c t f)
      (tli.TliCompactInstr.Branch (tli-clone-compact-value c) t f)]
    [(tli.TliCompactInstr.TotalEnumBranch c t f)
      (tli.TliCompactInstr.TotalEnumBranch (tli-clone-compact-value c) t f)]
    [(tli.TliCompactInstr.Return has v)
      (tli.TliCompactInstr.Return has (tli-clone-compact-value v))]
    [(tli.TliCompactInstr.Phi d inputs t)
      (let
        [n : i64 (array-length inputs)]
        [out : (__tl_dyn-array tli.TliCompactPhiInput)
          (__tl_make-array tli.TliCompactPhiInput n)]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref out i)
            (tli.TliCompactPhiInput
              (tli-clone-compact-value (& (array-ref inputs i).value))
              (array-ref inputs i).label)))
        (tli.TliCompactInstr.Phi d out (tli-clone-type t)))]
    [(tli.TliCompactInstr.Pack d vals t)
      (let
        [n : i64 (array-length vals)]
        [out : (__tl_dyn-array tli.TliCompactValue)
          (__tl_make-array tli.TliCompactValue n)]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref out i)
            (tli-clone-compact-value (& (array-ref vals i)))))
        (tli.TliCompactInstr.Pack d out (tli-clone-type t)))]
    [(tli.TliCompactInstr.Word d v idx t)
      (tli.TliCompactInstr.Word
        d
        (tli-clone-compact-value v)
        idx
        (tli-clone-type t))]
    [(tli.TliCompactInstr.Switch v def cases b)
      (let
        [n : i64 (array-length cases)]
        [out : (__tl_dyn-array tli.TliCompactSwitchCase)
          (__tl_make-array tli.TliCompactSwitchCase n)]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref out i)
            (tli.TliCompactSwitchCase
              (array-ref cases i).value
              (array-ref cases i).label)))
        (tli.TliCompactInstr.Switch (tli-clone-compact-value v) def out b))]
    [(tli.TliCompactInstr.TotalEnumSwitch v def cases b trap)
      (let
        [n : i64 (array-length cases)]
        [out : (__tl_dyn-array tli.TliCompactSwitchCase)
          (__tl_make-array tli.TliCompactSwitchCase n)]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref out i)
            (tli.TliCompactSwitchCase
              (array-ref cases i).value
              (array-ref cases i).label)))
        (tli.TliCompactInstr.TotalEnumSwitch
          (tli-clone-compact-value v)
          def
          out
          b
          trap))]))

(define (tli-clone-compact-return-storage
  [rs : (& tli.TliCompactReturnStorage)]) : tli.TliCompactReturnStorage
  (match rs
    [(tli.TliCompactReturnStorage.None) (tli.TliCompactReturnStorage.None)]
    [(tli.TliCompactReturnStorage.Some c idx b a o pr pp ss)
      (tli.TliCompactReturnStorage.Some
        c
        idx
        b
        a
        (tli-clone-type o)
        (tli-clone-type pr)
        (tli-clone-types pp)
        (tli-clone-type ss))]))

(define (tli-clone-compact-extern-ref [r : (& tli.TliCompactExternRef)]) : tli.TliCompactExternRef
  (tli.TliCompactExternRef
    (string.copy (& r.symbol))
    r.abi
    (string.copy (& r.link-symbol))
    (tli-clone-type (& r.ty))
    (tli-clone-compact-return-storage (& r.return-storage))))

(define (tli-clone-compact-ir-body [b : (& tli.TliCompactIrBody)]) : tli.TliCompactIrBody
  (let
    [pn : i64 (array-length b.params)]
    [bn : i64 (array-length b.blocks)]
    [rn : i64 (array-length b.extern-refs)]
    [params : (__tl_dyn-array tli.TliCompactParam)
      (__tl_make-array tli.TliCompactParam pn)]
    [blocks : (__tl_dyn-array tli.TliCompactBlock)
      (__tl_make-array tli.TliCompactBlock bn)]
    [refs : (__tl_dyn-array tli.TliCompactExternRef)
      (__tl_make-array tli.TliCompactExternRef rn)]
    (for [i (iterator.range 0 pn)]
      (set!
        (array-ref params i)
        (tli.TliCompactParam
          (string.copy (& (array-ref b.params i).name))
          (tli-clone-type (& (array-ref b.params i).ty))
          (array-ref b.params i).var-id)))
    (for [i (iterator.range 0 bn)]
      (let
        [in : i64 (array-length (array-ref b.blocks i).instrs)]
        [ins : (__tl_dyn-array tli.TliCompactInstr)
          (__tl_make-array tli.TliCompactInstr in)]
        (for [j (iterator.range 0 in)]
          (set!
            (array-ref ins j)
            (tli-clone-compact-instr
              (& (array-ref (array-ref b.blocks i).instrs j)))))
        (set!
          (array-ref blocks i)
          (tli.TliCompactBlock (array-ref b.blocks i).label ins))))
    (for [i (iterator.range 0 rn)]
      (set!
        (array-ref refs i)
        (tli.TliCompactExternRef
          (string.copy (& (array-ref b.extern-refs i).symbol))
          (array-ref b.extern-refs i).abi
          (string.copy (& (array-ref b.extern-refs i).link-symbol))
          (tli-clone-type (& (array-ref b.extern-refs i).ty))
          (tli-clone-compact-return-storage
            (& (array-ref b.extern-refs i).return-storage)))))
    (tli.TliCompactIrBody
      b.ir-flags
      b.instr-count
      params
      (tli-clone-type (& b.ret-type))
      b.next-var
      blocks
      (tli-clone-compact-return-storage (& b.return-storage))
      refs)))

(define (tli-clone-spmd-literal [lit : (& tli.TliSpmdLiteral)]) : tli.TliSpmdLiteral
  (match lit
    [(tli.TliSpmdLiteral.Int n s) (tli.TliSpmdLiteral.Int n (string.copy s))]
    [(tli.TliSpmdLiteral.Float s) (tli.TliSpmdLiteral.Float (string.copy s))]
    [(tli.TliSpmdLiteral.Bool b) (tli.TliSpmdLiteral.Bool b)]
    [(tli.TliSpmdLiteral.Char c) (tli.TliSpmdLiteral.Char c)]
    [(tli.TliSpmdLiteral.String s) (tli.TliSpmdLiteral.String (string.copy s))]
    [(tli.TliSpmdLiteral.Unit) (tli.TliSpmdLiteral.Unit)]))

(define (tli-clone-spmd-exprs [items : (& (__tl_dyn-array tli.TliSpmdExpr))]) : (__tl_dyn-array
    tli.TliSpmdExpr)
  (let
    [n : i64 (array-length (deref items))]
    [out : (__tl_dyn-array tli.TliSpmdExpr) (__tl_make-array tli.TliSpmdExpr n)]
    (for [i (iterator.range 0 n)]
      (set!
        (array-ref out i)
        (tli-clone-spmd-expr (& (array-ref (deref items) i)))))
    out))

(define (tli-clone-spmd-expr [expr : (& tli.TliSpmdExpr)]) : tli.TliSpmdExpr
  (match expr
    [(tli.TliSpmdExpr.Literal l)
      (tli.TliSpmdExpr.Literal (tli-clone-spmd-literal l))]
    [(tli.TliSpmdExpr.Var s) (tli.TliSpmdExpr.Var (string.copy s))]
    [(tli.TliSpmdExpr.Unary op inner)
      (tli.TliSpmdExpr.Unary op (box (tli-clone-spmd-expr (& (deref inner)))))]
    [(tli.TliSpmdExpr.Binary op l r)
      (tli.TliSpmdExpr.Binary
        op
        (box (tli-clone-spmd-expr (& (deref l))))
        (box (tli-clone-spmd-expr (& (deref r)))))]
    [(tli.TliSpmdExpr.Call f args)
      (tli.TliSpmdExpr.Call
        (box (tli-clone-spmd-expr (& (deref f))))
        (tli-clone-spmd-exprs args))]
    [(tli.TliSpmdExpr.If c t e)
      (tli.TliSpmdExpr.If
        (box (tli-clone-spmd-expr (& (deref c))))
        (box (tli-clone-spmd-expr (& (deref t))))
        (box (tli-clone-spmd-expr (& (deref e)))))]
    [(tli.TliSpmdExpr.Let bindings body)
      (let
        [n : i64 (array-length bindings)]
        [out : (__tl_dyn-array tli.TliSpmdLetBinding)
          (__tl_make-array tli.TliSpmdLetBinding n)]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref out i)
            (tli.TliSpmdLetBinding
              (string.copy (& (array-ref bindings i).name))
              (array-ref bindings i).has-type
              (tli-clone-type (& (array-ref bindings i).ty))
              (box
                (tli-clone-spmd-expr (& (deref (array-ref bindings i).init)))))))
        (tli.TliSpmdExpr.Let out (box (tli-clone-spmd-expr (& (deref body))))))]
    [(tli.TliSpmdExpr.Begin items)
      (tli.TliSpmdExpr.Begin (tli-clone-spmd-exprs items))]
    [(tli.TliSpmdExpr.Ann e ty)
      (tli.TliSpmdExpr.Ann
        (box (tli-clone-spmd-expr (& (deref e))))
        (tli-clone-type ty))]
    [(tli.TliSpmdExpr.Cast e ty)
      (tli.TliSpmdExpr.Cast
        (box (tli-clone-spmd-expr (& (deref e))))
        (tli-clone-type ty))]
    [(tli.TliSpmdExpr.ArrayRef a idx)
      (tli.TliSpmdExpr.ArrayRef
        (box (tli-clone-spmd-expr (& (deref a))))
        (box (tli-clone-spmd-expr (& (deref idx)))))]
    [(tli.TliSpmdExpr.ArraySet a idx v)
      (tli.TliSpmdExpr.ArraySet
        (box (tli-clone-spmd-expr (& (deref a))))
        (box (tli-clone-spmd-expr (& (deref idx))))
        (box (tli-clone-spmd-expr (& (deref v)))))]
    [(tli.TliSpmdExpr.StructGet e f)
      (tli.TliSpmdExpr.StructGet
        (box (tli-clone-spmd-expr (& (deref e))))
        (string.copy f))]
    [(tli.TliSpmdExpr.StructSet e f v)
      (tli.TliSpmdExpr.StructSet
        (box (tli-clone-spmd-expr (& (deref e))))
        (string.copy f)
        (box (tli-clone-spmd-expr (& (deref v)))))]
    [(tli.TliSpmdExpr.Tuple items)
      (tli.TliSpmdExpr.Tuple (tli-clone-spmd-exprs items))]
    [(tli.TliSpmdExpr.TupleRef e idx)
      (tli.TliSpmdExpr.TupleRef (box (tli-clone-spmd-expr (& (deref e)))) idx)]
    [(tli.TliSpmdExpr.Set p v)
      (tli.TliSpmdExpr.Set
        (box (tli-clone-spmd-expr (& (deref p))))
        (box (tli-clone-spmd-expr (& (deref v)))))]
    [(tli.TliSpmdExpr.Borrow is-mut life e)
      (tli.TliSpmdExpr.Borrow
        is-mut
        (string.copy life)
        (box (tli-clone-spmd-expr (& (deref e)))))]))

(define (tli-clone-compact-body-entry [entry : (& tli.TliCompactBodyEntry)]) : tli.TliCompactBodyEntry
  (tli.TliCompactBodyEntry
    (string.copy (& entry.module-name))
    (string.copy (& entry.fn-name))
    (string.copy (& entry.link-symbol))
    (tli.TliCompactBody
      entry.body.kind
      (tli-clone-compact-ir-body (& entry.body.ir-body))
      (tli-clone-spmd-expr (& entry.body.spmd-expr)))))

;; --- Consumer: TliCompactIrBody -> CompilerIrFunction & Externs ---
(define (tli-compact-dec-label [dense : i64]) : i64
  (if (< dense 0)
    (ir.compiler-ir-label-none)
    (let
      [name : String (str_cat.str-cat "__tli_b" (string.int->string dense))]
      (ir.compiler-ir-label (& name)))))

(define (tli-compact-dec-symbol [name : (& str)]) : i64
  (intern.intern (string.copy name)))

(define (tli-compact-dec-value [v : (& tli.TliCompactValue)]) : ir.CompilerIrValue
  (match v
    [(tli.TliCompactValue.Var id) (ir.CompilerIrValue.Var id)]
    [(tli.TliCompactValue.Global s)
      (ir.CompilerIrValue.Global (tli-compact-dec-symbol s))]
    [(tli.TliCompactValue.GlobalAddr s)
      (ir.CompilerIrValue.GlobalAddr (tli-compact-dec-symbol s))]
    [(tli.TliCompactValue.Function s)
      (ir.CompilerIrValue.Function (tli-compact-dec-symbol s))]
    [(tli.TliCompactValue.I64 n) (ir.CompilerIrValue.I64 n)]
    [(tli.TliCompactValue.F64Bits bits)
      (ir.CompilerIrValue.F64 (cast bits : u64))]
    [(tli.TliCompactValue.Bool b) (ir.CompilerIrValue.Bool b)]
    [(tli.TliCompactValue.Char c) (ir.CompilerIrValue.Char (cast c : char))]
    [(tli.TliCompactValue.String s) (ir.CompilerIrValue.String (string.copy s))]
    [(tli.TliCompactValue.Bytes raw)
      (ir.CompilerIrValue.Bytes (tli-compact-string-from-bytes raw))]
    [(tli.TliCompactValue.Unit) (ir.CompilerIrValue.Unit)]
    [(tli.TliCompactValue.StaticArray raw)
      (ir.CompilerIrValue.StaticArray (tli-compact-string-from-bytes raw))]))

(define (tli-compact-dec-call-args [args : (& tli.TliCompactCallArgs)]) : ir.CompilerIrCallArgs
  (let
    [n : i64 (array-length args.args)]
    (if (>= args.sret-index 0)
      (let
        [out : (__tl_dyn-array ir.CompilerIrValue)
          (__tl_make-array ir.CompilerIrValue n)]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref out i)
            (tli-compact-dec-value (& (array-ref args.args i)))))
        (ir.CompilerIrCallArgs.Sret out args.sret-index))
      (cond
        [(= n 0) (ir.CompilerIrCallArgs.Nil)]
        [(= n 1)
          (ir.CompilerIrCallArgs.One
            (tli-compact-dec-value (& (array-ref args.args 0))))]
        [(= n 2)
          (ir.CompilerIrCallArgs.Two
            (tli-compact-dec-value (& (array-ref args.args 0)))
            (tli-compact-dec-value (& (array-ref args.args 1))))]
        [else
          (let
            [out : (__tl_dyn-array ir.CompilerIrValue)
              (__tl_make-array ir.CompilerIrValue n)]
            (for [i (iterator.range 0 n)]
              (set!
                (array-ref out i)
                (tli-compact-dec-value (& (array-ref args.args i)))))
            (ir.CompilerIrCallArgs.Array out))]))))

(define (tli-compact-dec-binop
  [pools : ast.AstNodePoolContext]
  [op : (& tli.TliCompactBinOp)]) : ir.CompilerIrBinOp
  (match op
    [(tli.TliCompactBinOp.Add) (ir.CompilerIrBinOp.Add)]
    [(tli.TliCompactBinOp.Sub) (ir.CompilerIrBinOp.Sub)]
    [(tli.TliCompactBinOp.Mul) (ir.CompilerIrBinOp.Mul)]
    [(tli.TliCompactBinOp.Div) (ir.CompilerIrBinOp.Div)]
    [(tli.TliCompactBinOp.Mod) (ir.CompilerIrBinOp.Mod)]
    [(tli.TliCompactBinOp.SafeDiv) (ir.CompilerIrBinOp.SafeDiv)]
    [(tli.TliCompactBinOp.SafeMod) (ir.CompilerIrBinOp.SafeMod)]
    [(tli.TliCompactBinOp.Eq) (ir.CompilerIrBinOp.Eq)]
    [(tli.TliCompactBinOp.Ne) (ir.CompilerIrBinOp.Ne)]
    [(tli.TliCompactBinOp.Lt) (ir.CompilerIrBinOp.Lt)]
    [(tli.TliCompactBinOp.Le) (ir.CompilerIrBinOp.Le)]
    [(tli.TliCompactBinOp.Gt) (ir.CompilerIrBinOp.Gt)]
    [(tli.TliCompactBinOp.Ge) (ir.CompilerIrBinOp.Ge)]
    [(tli.TliCompactBinOp.BitTestEq) (ir.CompilerIrBinOp.BitTestEq)]
    [(tli.TliCompactBinOp.BitTestNe) (ir.CompilerIrBinOp.BitTestNe)]
    [(tli.TliCompactBinOp.And) (ir.CompilerIrBinOp.And)]
    [(tli.TliCompactBinOp.Or) (ir.CompilerIrBinOp.Or)]
    [(tli.TliCompactBinOp.BitAnd) (ir.CompilerIrBinOp.BitAnd)]
    [(tli.TliCompactBinOp.BitOr) (ir.CompilerIrBinOp.BitOr)]
    [(tli.TliCompactBinOp.BitXor) (ir.CompilerIrBinOp.BitXor)]
    [(tli.TliCompactBinOp.Shl ty)
      (ir.CompilerIrBinOp.Shl (tli-compact-type-to-ast pools ty))]
    [(tli.TliCompactBinOp.Shr ty)
      (ir.CompilerIrBinOp.Shr (tli-compact-type-to-ast pools ty))]
    [(tli.TliCompactBinOp.Rotr) (ir.CompilerIrBinOp.Rotr)]))

(define (tli-compact-dec-unop [op : (& tli.TliCompactUnOp)]) : ir.CompilerIrUnOp
  (match op
    [(tli.TliCompactUnOp.Neg) (ir.CompilerIrUnOp.Neg)]
    [(tli.TliCompactUnOp.Not) (ir.CompilerIrUnOp.Not)]
    [(tli.TliCompactUnOp.BitNot) (ir.CompilerIrUnOp.BitNot)]
    [(tli.TliCompactUnOp.Sqrt) (ir.CompilerIrUnOp.Sqrt)]
    [(tli.TliCompactUnOp.BitLength) (ir.CompilerIrUnOp.BitLength)]))

(define (tli-compact-dec-instr
  [pools : ast.AstNodePoolContext]
  [ins : (& tli.TliCompactInstr)]) : ir.CompilerIrInstr
  (match ins
    [(tli.TliCompactInstr.Mov d v t)
      (ir.CompilerIrInstr.Mov
        d
        (tli-compact-dec-value v)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.Alloc d t)
      (ir.CompilerIrInstr.Alloc d (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.AddrOf d s w) (ir.CompilerIrInstr.AddrOf d s w)]
    [(tli.TliCompactInstr.Gep d b i t)
      (ir.CompilerIrInstr.Gep
        d
        (tli-compact-dec-value b)
        (tli-compact-dec-value i)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.Load d p t)
      (ir.CompilerIrInstr.Load
        d
        (tli-compact-dec-value p)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.StoreOwned d v t)
      (ir.CompilerIrInstr.StoreOwned
        (tli-compact-dec-value d)
        (tli-compact-dec-value v)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.StorePtr d v t)
      (ir.CompilerIrInstr.StorePtr
        (tli-compact-dec-value d)
        (tli-compact-dec-value v)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.CopyBytes d s n)
      (ir.CompilerIrInstr.CopyBytes
        (tli-compact-dec-value d)
        (tli-compact-dec-value s)
        n)]
    [(tli.TliCompactInstr.BoundsCheck i l ok)
      (ir.CompilerIrInstr.BoundsCheck
        (tli-compact-dec-value i)
        (tli-compact-dec-value l)
        (tli-compact-dec-label ok))]
    [(tli.TliCompactInstr.Cast d v f t)
      (ir.CompilerIrInstr.Cast
        d
        (tli-compact-dec-value v)
        (tli-compact-type-to-ast pools f)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.Bitcast d v f t)
      (ir.CompilerIrInstr.Bitcast
        d
        (tli-compact-dec-value v)
        (tli-compact-type-to-ast pools f)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.BinOp d op a b t)
      (ir.CompilerIrInstr.BinOp
        d
        (tli-compact-dec-binop pools op)
        (tli-compact-dec-value a)
        (tli-compact-dec-value b)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.UnOp d op v t)
      (ir.CompilerIrInstr.UnOp
        d
        (tli-compact-dec-unop op)
        (tli-compact-dec-value v)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.Call d s a t)
      (ir.CompilerIrInstr.Call
        d
        (tli-compact-dec-symbol s)
        (tli-compact-dec-call-args a)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.CallIndirect d c a t)
      (ir.CompilerIrInstr.CallIndirect
        d
        (tli-compact-dec-value c)
        (tli-compact-dec-call-args a)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.CallIndirectC d c a t)
      (ir.CompilerIrInstr.CallIndirectC
        d
        (tli-compact-dec-value c)
        (tli-compact-dec-call-args a)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.TailCall s a t)
      (ir.CompilerIrInstr.TailCall
        (tli-compact-dec-symbol s)
        (tli-compact-dec-call-args a)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.Store g v t)
      (ir.CompilerIrInstr.Store
        (tli-compact-dec-symbol g)
        (tli-compact-dec-value v)
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.Jump l)
      (ir.CompilerIrInstr.Jump (tli-compact-dec-label l))]
    [(tli.TliCompactInstr.Branch c t f)
      (ir.CompilerIrInstr.Branch
        (tli-compact-dec-value c)
        (tli-compact-dec-label t)
        (tli-compact-dec-label f))]
    [(tli.TliCompactInstr.TotalEnumBranch c t f)
      (ir.CompilerIrInstr.TotalEnumBranch
        (tli-compact-dec-value c)
        (tli-compact-dec-label t)
        (tli-compact-dec-label f))]
    [(tli.TliCompactInstr.Return has v)
      (ir.CompilerIrInstr.Return
        (if has
          (ir.CompilerIrMaybeValue.Some (tli-compact-dec-value v))
          (ir.CompilerIrMaybeValue.No)))]
    [(tli.TliCompactInstr.Phi d inputs t)
      (let
        [n : i64 (array-length inputs)]
        [slots : (__tl_dyn-array ir.CompilerIrPhiInput)
          (__tl_make-array ir.CompilerIrPhiInput n)]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref slots i)
            (ir.CompilerIrPhiInput
              (tli-compact-dec-value (& (array-ref inputs i).value))
              (tli-compact-dec-label (array-ref inputs i).label))))
        (ir.CompilerIrInstr.Phi
          d
          (ir.CompilerIrPhiInputSeq slots 0 n)
          (tli-compact-type-to-ast pools t)))]
    [(tli.TliCompactInstr.Pack d vals t)
      (let
        [n : i64 (array-length vals)]
        [slots : (__tl_dyn-array ir.CompilerIrValue)
          (__tl_make-array ir.CompilerIrValue n)]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref slots i)
            (tli-compact-dec-value (& (array-ref vals i)))))
        (ir.CompilerIrInstr.Pack
          d
          (ir.CompilerIrValueSeq slots n)
          (tli-compact-type-to-ast pools t)))]
    [(tli.TliCompactInstr.Word d v idx t)
      (ir.CompilerIrInstr.Word
        d
        (tli-compact-dec-value v)
        idx
        (tli-compact-type-to-ast pools t))]
    [(tli.TliCompactInstr.Switch v def cases b)
      (let
        [n : i64 (array-length cases)]
        [slots : (__tl_dyn-array ir.CompilerIrSwitchCase)
          (__tl_make-array ir.CompilerIrSwitchCase n)]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref slots i)
            (ir.CompilerIrSwitchCase.Case
              (array-ref cases i).value
              (tli-compact-dec-label (array-ref cases i).label))))
        (ir.CompilerIrInstr.Switch
          (tli-compact-dec-value v)
          (tli-compact-dec-label def)
          (ir.CompilerIrSwitchCaseSeq slots n)
          b))]
    [(tli.TliCompactInstr.TotalEnumSwitch v def cases b trap)
      (let
        [n : i64 (array-length cases)]
        [slots : (__tl_dyn-array ir.CompilerIrSwitchCase)
          (__tl_make-array ir.CompilerIrSwitchCase n)]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref slots i)
            (ir.CompilerIrSwitchCase.Case
              (array-ref cases i).value
              (tli-compact-dec-label (array-ref cases i).label))))
        (ir.CompilerIrInstr.TotalEnumSwitch
          (tli-compact-dec-value v)
          (tli-compact-dec-label def)
          (ir.CompilerIrSwitchCaseSeq slots n)
          b
          (tli-compact-dec-label trap)))]))

(define (tli-compact-ir-body-to-function
  [pools : ast.AstNodePoolContext]
  [target-name-id : i64]
  [body : (& tli.TliCompactIrBody)]) : ir.CompilerIrFunction
  (let
    [pn : i64 (array-length body.params)]
    [bn : i64 (array-length body.blocks)]
    [pslots : (__tl_dyn-array ir.CompilerIrParam)
      (__tl_make-array ir.CompilerIrParam pn)]
    [bslots : (__tl_dyn-array ir.CompilerIrBlock)
      (__tl_make-array ir.CompilerIrBlock bn)]
    (for [i (iterator.range 0 pn)]
      (set!
        (array-ref pslots i)
        (ir.CompilerIrParam.Param
          (string.copy (& (array-ref body.params i).name))
          (tli-compact-type-to-ast pools (& (array-ref body.params i).ty))
          (array-ref body.params i).var-id)))
    (for [bi (iterator.range 0 bn)]
      (let
        [in : i64 (array-length (array-ref body.blocks bi).instrs)]
        [islots : (__tl_dyn-array ir.CompilerIrInstr)
          (__tl_make-array ir.CompilerIrInstr in)]
        (for [ii (iterator.range 0 in)]
          (set!
            (array-ref islots ii)
            (tli-compact-dec-instr
              pools
              (& (array-ref (array-ref body.blocks bi).instrs ii)))))
        (set!
          (array-ref bslots bi)
          (ir.CompilerIrBlock.Block
            (tli-compact-dec-label (array-ref body.blocks bi).label)
            (ir.CompilerIrInstrSeq islots in)))))
    (let
      [abi : ir.CompilerIrFunctionAbi
        (match (tli-compact-return-storage-to-ir pools (& body.return-storage))
          [(ir.CompilerIrReturnStorage.None)
            (ir.CompilerIrFunctionAbi.Ordinary)]
          [(ir.CompilerIrReturnStorage.Some rs-box)
            (ir.CompilerIrFunctionAbi.ReturnStorage rs-box)])]
      (ir.CompilerIrFunction.Function
        target-name-id
        (ir.CompilerIrParamSeq pslots pn)
        (tli-compact-type-to-ast pools (& body.ret-type))
        body.next-var
        (ir.CompilerIrBlockList.Array (ir.CompilerIrBlockSeq bslots bn))
        abi))))

(define (tli-compact-extern-ref-to-ir
  [pools : ast.AstNodePoolContext]
  [ref : (& tli.TliCompactExternRef)]) : ir.CompilerIrExtern
  (let
    [sym-id : i64 (tli-compact-dec-symbol (& ref.symbol))]
    [link-id : i64
      (if (and (= ref.abi 0) (string.eq (& ref.symbol) (& ref.link-symbol)))
        sym-id
        (intern.intern (string.copy (& ref.link-symbol))))]
    [abi : ast.AstExternAbi
      (match ref.abi
        [0 (ast.AstExternAbi.TypeLisp)]
        [1 (ast.AstExternAbi.C)]
        [_ (ast.AstExternAbi.CVarargsOpen)])]
    (ir.CompilerIrExtern.Extern
      sym-id
      sym-id
      (string.copy (& ref.symbol))
      (tli-compact-type-to-ast pools (& ref.ty))
      abi
      link-id
      (ast.ast-extern-link-input-list-new)
      false
      (tli-compact-return-storage-to-ir pools (& ref.return-storage))
      false
      (ir.CompilerIrGlobalStorage.Word))))

(define (tli-compact-global-to-ir
  [pools : ast.AstNodePoolContext]
  [g : (& tli.TliCompactGlobal)]) : ir.CompilerIrGlobal
  ;; Only never-written literal globals travel as compact globals, and a
  ;; literal cell is one word.
  (ir.CompilerIrGlobal.Global
    (tli-compact-dec-symbol (& g.symbol))
    (tli-compact-type-to-ast pools (& g.ty))
    (tli-compact-dec-value (& g.init))
    (ir.CompilerIrGlobalStorage.Word)))

;; --- Consumer: O1/O2 compact_ir hydration into CompilerIrProgram ---
(defstruct TliStartupInitDep
  (sym-id i64)
  (init-indices (__tl_dyn-array i64)))

(defstruct TliStartupInitPlan
  (init-symbols (__tl_dyn-array String))
  (deps (__tl_dyn-array TliStartupInitDep)))

;; `TliStartupInitDep.sym-id` of inits that run whether or not any program
;; symbol references them.
(define tli-startup-init-always : i64
  -1)

(define (tli-startup-init-plan-empty) : TliStartupInitPlan
  (TliStartupInitPlan
    (__tl_make-array String 0)
    (__tl_make-array TliStartupInitDep 0)))

(defstruct TliHydratedCompactProgram
  (program ir.CompilerIrProgram)
  (external-summaries opt.OptExternalSummaries)
  (startup-plan TliStartupInitPlan))

(define (tli-compact-scan-ir-value!
  [v : (& ir.CompilerIrValue)]
  [fn-syms : (&mut i64_vec.Vec)]
  [fn-seen : (&mut i64_map.Map)]
  [gl-syms : (&mut str_map.Map)]) : unit
  (match v
    [(ir.CompilerIrValue.Function sym)
      (let
        [sid : i64 (ir.compiler-ir-symbol-id sym)]
        (unless
          (i64_map.contains? fn-seen sid)
          (i64_map.insert-ref! fn-seen sid 1)
          (i64_vec.push-ref! fn-syms sid)))]
    [(or (ir.CompilerIrValue.Global sym) (ir.CompilerIrValue.GlobalAddr sym))
      (str_map.insert-ref! gl-syms (ir.compiler-ir-symbol-text sym) 1)]
    [_ unit]))

(define (tli-compact-scan-ir-use!
  [fn-syms : (&mut i64_vec.Vec)]
  [fn-seen : (&mut i64_map.Map)]
  [gl-syms : (&mut str_map.Map)]
  [_role : ir.CompilerIrOperandRole]
  [v : ir.CompilerIrValue]) : unit
  (tli-compact-scan-ir-value! (& v) fn-syms fn-seen gl-syms))

(define (tli-compact-scan-ir-instr!
  [ins : ir.CompilerIrInstr]
  [fn-syms : (&mut i64_vec.Vec)]
  [fn-seen : (&mut i64_map.Map)]
  [gl-syms : (&mut str_map.Map)]) : unit
  (match (& ins)
    [(ir.CompilerIrInstr.Store g _ _)
      (str_map.insert-ref! gl-syms (ir.compiler-ir-symbol-text g) 1)]
    [_
      (let
        [named : i64 (tli-compact-ir-instr-named-symbol (& ins))]
        (when
          (>= named 0)
          (let
            [sid : i64 (ir.compiler-ir-symbol-id named)]
            (unless
              (i64_map.contains? fn-seen sid)
              (i64_map.insert-ref! fn-seen sid 1)
              (i64_vec.push-ref! fn-syms sid)))))])
  (ir.compiler-ir-instr-visit-uses
    ins
    tli-compact-scan-ir-use!
    fn-syms
    fn-seen
    gl-syms))

(define (tli-compact-scan-wire-value!
  [v : (& tli.TliCompactValue)]
  [gl-syms : (&mut str_map.Map)]) : unit
  (match v
    [(or (tli.TliCompactValue.Global s) (tli.TliCompactValue.GlobalAddr s))
      (str_map.insert-ref! gl-syms (string.copy s) 1)]
    [_ unit]))

(define (tli-compact-scan-wire-call-args!
  [args : (& tli.TliCompactCallArgs)]
  [gl-syms : (&mut str_map.Map)]) : unit
  (for [i (iterator.range 0 (array-length args.args))]
    (tli-compact-scan-wire-value! (& (array-ref args.args i)) gl-syms)))

(define (tli-compact-scan-wire-body-globals!
  [body : (& tli.TliCompactIrBody)]
  [gl-syms : (&mut str_map.Map)]) : unit
  (for [bi (iterator.range 0 (array-length body.blocks))]
    (let
      [icount : i64 (array-length (array-ref body.blocks bi).instrs)]
      (for [ii (iterator.range 0 icount)]
        (match (& (array-ref (array-ref body.blocks bi).instrs ii))
          [(or (tli.TliCompactInstr.Mov _ v _) (tli.TliCompactInstr.Load _ v _)
               (tli.TliCompactInstr.Cast _ v _ _)
               (tli.TliCompactInstr.Bitcast _ v _ _)
               (tli.TliCompactInstr.UnOp _ _ v _)
               (tli.TliCompactInstr.Branch v _ _)
               (tli.TliCompactInstr.TotalEnumBranch v _ _)
               (tli.TliCompactInstr.Word _ v _ _)
               (tli.TliCompactInstr.Switch v _ _ _)
               (tli.TliCompactInstr.TotalEnumSwitch v _ _ _ _))
            (tli-compact-scan-wire-value! v gl-syms)]
          [(or (tli.TliCompactInstr.Gep _ a b _)
               (tli.TliCompactInstr.StoreOwned a b _)
               (tli.TliCompactInstr.StorePtr a b _)
               (tli.TliCompactInstr.CopyBytes a b _)
               (tli.TliCompactInstr.BoundsCheck a b _)
               (tli.TliCompactInstr.BinOp _ _ a b _))
            (tli-compact-scan-wire-value! a gl-syms)
            (tli-compact-scan-wire-value! b gl-syms)]
          [(tli.TliCompactInstr.Store g v _)
            (str_map.insert-ref! gl-syms (string.copy g) 1)
            (tli-compact-scan-wire-value! v gl-syms)]
          [(or (tli.TliCompactInstr.Call _ _ args _)
               (tli.TliCompactInstr.TailCall _ args _))
            (tli-compact-scan-wire-call-args! args gl-syms)]
          [(or (tli.TliCompactInstr.CallIndirect _ c args _)
               (tli.TliCompactInstr.CallIndirectC _ c args _))
            (tli-compact-scan-wire-value! c gl-syms)
            (tli-compact-scan-wire-call-args! args gl-syms)]
          [(tli.TliCompactInstr.Return has v)
            (when has (tli-compact-scan-wire-value! v gl-syms))]
          [(tli.TliCompactInstr.Phi _ inputs _)
            (for [pi (iterator.range 0 (array-length inputs))]
              (tli-compact-scan-wire-value!
                (& (array-ref inputs pi).value)
                gl-syms))]
          [(tli.TliCompactInstr.Pack _ vals _)
            (for [pi (iterator.range 0 (array-length vals))]
              (tli-compact-scan-wire-value! (& (array-ref vals pi)) gl-syms))]
          [_ unit])))))

;; Lazily hydrate called `.tli` v3 `compact_ir` bodies, referenced `compact_globals`,
;; and packed `OptExternalSummaries` into `program` before `tli-arena` retires.
;; - O0: no-op.
;; - O1: startup-init pruning plan only (no `HAS_IR` compact IR body hydration;
;;       `HAS_SPMD_EXPR` hydrates on demand during `foreach` at all opt levels).
;; - O2: full transitive closure of `HAS_IR` callees + `compact_globals` +
;;       packed `OptExternalSummaries` for remaining out-of-line externs.
(define (tli-compact-scan-ir-all-syms-add!
  [sid : i64]
  [syms : (&mut i64_map.Map)]
  [out : (&mut i64_vec.Vec)]) : unit
  (unless
    (i64_map.contains? syms sid)
    (i64_map.insert-ref! syms sid 1)
    (i64_vec.push-ref! out sid)))

(define (tli-compact-scan-ir-all-syms-value!
  [v : (& ir.CompilerIrValue)]
  [syms : (&mut i64_map.Map)]
  [out : (&mut i64_vec.Vec)]) : unit
  (match v
    [(or (ir.CompilerIrValue.Function sym) (ir.CompilerIrValue.Global sym)
         (ir.CompilerIrValue.GlobalAddr sym))
      (tli-compact-scan-ir-all-syms-add!
        (ir.compiler-ir-symbol-id sym)
        syms
        out)]
    [_ unit]))

(define (tli-compact-scan-ir-all-syms-use!
  [syms : (&mut i64_map.Map)]
  [out : (&mut i64_vec.Vec)]
  [_role : ir.CompilerIrOperandRole]
  [v : ir.CompilerIrValue]) : unit
  (tli-compact-scan-ir-all-syms-value! (& v) syms out))

;; The symbol an instruction names outside its value operands (a direct callee
;; or a stored global), or -1.
(define (tli-compact-ir-instr-named-symbol [ins : (& ir.CompilerIrInstr)]) : i64
  (match ins
    [(or (ir.CompilerIrInstr.Call _ callee _ _)
         (ir.CompilerIrInstr.TailCall callee _ _)
         (ir.CompilerIrInstr.Store callee _ _))
      callee]
    [(ir.CompilerIrInstr.CallCAbiStoreResult payload-box)
      (deref payload-box).name]
    [(ir.CompilerIrInstr.SpmdCall payload-box) (deref payload-box).callee]
    [_ -1]))

;; Every function/global symbol `ins` references, through the IR's canonical
;; use walk so no instruction kind is missed.
(define (tli-compact-scan-ir-all-syms-instr!
  [ins : ir.CompilerIrInstr]
  [syms : (&mut i64_map.Map)]
  [out : (&mut i64_vec.Vec)]) : unit
  (let
    [named : i64 (tli-compact-ir-instr-named-symbol (& ins))]
    (when
      (>= named 0)
      (tli-compact-scan-ir-all-syms-add!
        (ir.compiler-ir-symbol-id named)
        syms
        out))
    (ir.compiler-ir-instr-visit-uses
      ins
      tli-compact-scan-ir-all-syms-use!
      syms
      out)))

(define (tli-compact-scan-program-syms
  [functions : (& ir.CompilerIrFunctionSeq)]
  [globals : (& ir.CompilerIrGlobalSeq)]) : i64_map.Map
  (let
    [syms : i64_map.Map (i64_map.with-capacity 128)]
    [unused : i64_vec.Vec (i64_vec.new)]
    (for [fi (iterator.range 0 functions.len)]
      (match (ir.compiler-ir-function-seq-borrow functions fi)
        [(ir.CompilerIrFunction.Function _ _ _ _ blocks _)
          (match blocks
            [(ir.CompilerIrBlockList.Array bseq)
              (for [bi (iterator.range 0 (ir.compiler-ir-block-seq-count bseq))]
                (match (ir.compiler-ir-block-seq-borrow bseq bi)
                  [(ir.CompilerIrBlock.Block _ iseq)
                    (for [ii
                      (iterator.range 0 (ir.compiler-ir-instr-seq-count iseq))]
                      (tli-compact-scan-ir-all-syms-instr!
                        (ir.compiler-ir-instr-seq-ref iseq ii)
                        (&mut syms)
                        (&mut unused)))]))])]))
    (for [gi (iterator.range 0 globals.len)]
      (match (ir.compiler-ir-global-seq-borrow globals gi)
        [(ir.CompilerIrGlobal.Global _ _ ginit _)
          (tli-compact-scan-ir-all-syms-value! ginit (&mut syms) (&mut unused))]))
    syms))

;; Owning bundle of hydrated summary row `slot`, or `-1` when the row's bundle
;; carries no `compact_ir` section (package bundles and dispatch rows).
(define (tli-compact-slot-bundle
  [multi : (& hydrate.TliMultiCatalog)]
  [facts : (& hydrate.TliHydratedFacts)]
  [slot : i64]) : i64
  (if (< slot 0)
    -1
    (hydrate.tli-multi-gid-bundle-index
      multi
      (array-ref facts.fn-summaries.slots slot).record-index)))

;; The summary slot of archive symbol `link-id` when its owning bundle carries
;; `compact_ir`; `-1` otherwise.
(define (tli-compact-ir-slot-by-link
  [multi : (& hydrate.TliMultiCatalog)]
  [facts : (& hydrate.TliHydratedFacts)]
  [link-id : i64]) : i64
  (let
    [slot : i64
      (hydrate.tli-hydrated-facts-fn-summary-slot-by-link facts link-id)]
    (if (< (tli-compact-slot-bundle multi facts slot) 0)
      -1
      slot)))

(define (tli-multi-has-compact-ir? [multi : (& hydrate.TliMultiCatalog)]) : bool
  (for [bi (iterator.range 0 multi.bundles.len)]
    (when
      (!=
        (bit-and
          (array-ref multi.bundles.slots bi).directory.flags
          tli.tli-has-compact-ir)
        0)
      (return true)))
  false)

(define (tli-build-startup-init-plan
  [multi : (& multi hydrate.TliMultiCatalog)]
  [facts : (& hydrate.TliHydratedFacts)]
  [functions : (& ir.CompilerIrFunctionSeq)]
  [globals : (& ir.CompilerIrGlobalSeq)]
  [externs : (& ir.CompilerIrExternSeq)]
  [extern-link-by-name : (& i64_map.Map)]
  [defined-gls : (& i64_map.Map)]) : TliStartupInitPlan
  (let
    [init-count : i64 0]
    (when multi.failed (return (tli-startup-init-plan-empty)))
    (for [pos (iterator.range 0 multi.startup-order.len)]
      (let
        [mi : i64 (array-ref multi.startup-order.slots pos)]
        [rec
          (&
            (array-ref
              (array-ref
                multi.bundles.slots
                (array-ref multi.gid-bundle.slots mi)).records
              (array-ref multi.gid-local.slots mi)))]
        (+= init-count (array-length rec.global-inits))))
    (when (= init-count 0) (return (tli-startup-init-plan-empty)))
    (let
      [mod-count : i64 multi.gid-bundle.len]
      [init-symbols : (__tl_dyn-array String)
        (__tl_make-array String init-count)]
      [mod-init-start : (__tl_dyn-array i64) (__tl_make-array i64 mod-count)]
      [mod-init-len : (__tl_dyn-array i64) (__tl_make-array i64 mod-count)]
      [mod-name-to-idx : str_map.Map
        (str_map.with-capacity (* (+ multi.startup-order.len 1) 2))]
      [sym-to-mod : str_map.Map (str_map.with-capacity 512)]
      [next-init : i64 0]
      (for [mi (iterator.range 0 mod-count)]
        (set! (array-ref mod-init-start mi) 0)
        (set! (array-ref mod-init-len mi) 0))
      (for [pos (iterator.range 0 multi.startup-order.len)]
        (let
          [mi : i64 (array-ref multi.startup-order.slots pos)]
          [rec
            (&
              (array-ref
                (array-ref
                  multi.bundles.slots
                  (array-ref multi.gid-bundle.slots mi)).records
                (array-ref multi.gid-local.slots mi)))]
          [mi-stdlib : bool
            (array-ref
              multi.bundles.slots
              (array-ref multi.gid-bundle.slots mi)).is-stdlib]
          [ic : i64 (array-length rec.global-inits)]
          (str_map.insert-ref!
            (&mut mod-name-to-idx)
            (string.copy (& rec.name))
            mi)
          (set! (array-ref mod-init-start mi) next-init)
          (set! (array-ref mod-init-len mi) ic)
          (for [k (iterator.range 0 ic)]
            (set!
              (array-ref init-symbols next-init)
              (hydrate.tli-hydrate-archive-user-symbol
                (& (array-ref rec.global-inits k))))
            (+= next-init 1))
          (let
            [fn-count : i64 (array-length rec.functions)]
            [val-count : i64 (array-length rec.values)]
            (for [fi (iterator.range 0 fn-count)]
              (unless
                (array-ref rec.functions fi).is-extern
                (let
                  [asym : String
                    (hydrate.tli-hydrate-archive-fn-symbol-with-mode
                      mi-stdlib
                      (& rec.source-path)
                      (& (array-ref rec.functions fi)))]
                  (str_map.insert-ref! (&mut sym-to-mod) asym mi))))
            (for [vi (iterator.range 0 val-count)]
              (unless
                (array-ref rec.values vi).is-extern
                (let
                  [asym : String
                    (hydrate.tli-hydrate-archive-value-symbol-with-mode
                      mi-stdlib
                      (& rec.source-path)
                      (& (array-ref rec.values vi)))]
                  (str_map.insert-ref! (&mut sym-to-mod) asym mi))))
            ;; A dispatch call reaches one of its module's variants, so it
            ;; needs that module's inits like a direct function call.
            (for [di (iterator.range 0 (array-length rec.dispatches))]
              (let
                [asym : String
                  (hydrate.tli-hydrate-archive-dispatch-symbol-with-mode
                    mi-stdlib
                    (& rec.source-path)
                    (& (array-ref rec.dispatches di)))]
                (str_map.insert-ref! (&mut sym-to-mod) asym mi))))))
      ;; Precompute transitive module-import init reachability.
      ;; `multi.startup-order` is already topological (imports before importers).
      (let
        [mod-trans : (__tl_dyn-array bool)
          (__tl_make-array bool (* mod-count init-count))]
        [ref-syms : i64_map.Map
          (tli-compact-scan-program-syms functions globals)]
        [interns : intern.InternCompatState
          (intern.intern-compat-state-capture-active)]
        [cand-sids : i64_vec.Vec (i64_vec.new)]
        [cand-strs : str_vec.Vec (str_vec.new)]
        [cand-seen : i64_map.Map (i64_map.with-capacity 128)]
        (for [i (iterator.range 0 (* mod-count init-count))]
          (set! (array-ref mod-trans i) false))
        (for [pos (iterator.range 0 multi.startup-order.len)]
          (let
            [mi : i64 (array-ref multi.startup-order.slots pos)]
            [rec
              (&
                (array-ref
                  (array-ref
                    multi.bundles.slots
                    (array-ref multi.gid-bundle.slots mi)).records
                  (array-ref multi.gid-local.slots mi)))]
            [base : i64 (* mi init-count)]
            [istart : i64 (array-ref mod-init-start mi)]
            [ilen : i64 (array-ref mod-init-len mi)]
            (for [k (iterator.range 0 ilen)]
              (set! (array-ref mod-trans (+ base istart k)) true))
            (let
              [imp-count : i64 (array-length rec.imports)]
              (for [ii (iterator.range 0 imp-count)]
                (match (str_map.get
                  (& mod-name-to-idx)
                  (string.copy (& (array-ref rec.imports ii).module-name)))
                  [(LookupFound dep-mi)
                    (let
                      [dep-base : i64 (* dep-mi init-count)]
                      (for [k (iterator.range 0 init-count)]
                        (when
                          (array-ref mod-trans (+ dep-base k))
                          (set! (array-ref mod-trans (+ base k)) true))))]
                  [(LookupMissing) unit])))))
        ;; Collect all referenced non-provided externs (both out-of-line and
        ;; body-available, since un-inlined bodies revert to externs).
        (for [ei (iterator.range 0 externs.len)]
          (match (ir.compiler-ir-extern-seq-borrow externs ei)
            [(ir.CompilerIrExtern.Extern ename _ _ _ _ elink _ prov _ _ _)
              (unless
                prov
                (let
                  [sid : i64 (ir.compiler-ir-symbol-id ename)]
                  (when
                    (and
                      (i64_map.contains? (& ref-syms) sid)
                      (not (i64_map.contains? defined-gls sid))
                      (not (i64_map.contains? (& cand-seen) sid)))
                    (let
                      [lid : i64
                        (i64_map.get-value-or extern-link-by-name sid elink)]
                      [arch : String
                        (if (= lid sid)
                          (ir.compiler-ir-symbol-text ename)
                          (string.copy
                            (intern.intern-compat-state-str (& interns) lid)))]
                      (when
                        (str_map.contains?
                          (& sym-to-mod)
                          (string.copy (& arch)))
                        (i64_map.insert-ref! (&mut cand-seen) sid 1)
                        (i64_vec.push-ref! (&mut cand-sids) sid)
                        (str_vec.push-ref! (&mut cand-strs) arch))))))]))
        ;; Also check referenced globals directly belonging to hydrated modules
        ;; that have `global-inits` (in case accessed without an extern entry).
        (for [pos (iterator.range 0 multi.startup-order.len)]
          (let
            [mi : i64 (array-ref multi.startup-order.slots pos)]
            [rec
              (&
                (array-ref
                  (array-ref
                    multi.bundles.slots
                    (array-ref multi.gid-bundle.slots mi)).records
                  (array-ref multi.gid-local.slots mi)))]
            [mi-stdlib : bool
              (array-ref
                multi.bundles.slots
                (array-ref multi.gid-bundle.slots mi)).is-stdlib]
            (when
              (> (array-ref mod-init-len mi) 0)
              (let
                [val-count : i64 (array-length rec.values)]
                (for [vi (iterator.range 0 val-count)]
                  (let
                    [asym : String
                      (hydrate.tli-hydrate-archive-value-symbol-with-mode
                        mi-stdlib
                        (& rec.source-path)
                        (& (array-ref rec.values vi)))]
                    [sid : i64
                      (ir.compiler-ir-symbol-id
                        (tli-compact-dec-symbol (& asym)))]
                    (when
                      (and
                        (i64_map.contains? (& ref-syms) sid)
                        (not (i64_map.contains? defined-gls sid))
                        (not (i64_map.contains? (& cand-seen) sid)))
                      (i64_map.insert-ref! (&mut cand-seen) sid 1)
                      (i64_vec.push-ref! (&mut cand-sids) sid)
                      (str_vec.push-ref! (&mut cand-strs) asym))))))))
        (let
          [cand-count : i64 (i64_vec.len (& cand-sids))]
          [deps-tmp : (__tl_dyn-array TliStartupInitDep)
            (__tl_make-array TliStartupInitDep (+ cand-count 1))]
          [dep-count : i64 0]
          (for [ci (iterator.range 0 cand-count)]
            (let
              [sid : i64 (i64_vec.get (& cand-sids) ci 0)]
              [needed : (__tl_dyn-array bool) (__tl_make-array bool init-count)]
              [bfs : str_vec.Vec (str_vec.new)]
              [seen : str_map.Map (str_map.with-capacity 32)]
              [cursor : i64 0]
              (for [k (iterator.range 0 init-count)]
                (set! (array-ref needed k) false))
              (let
                [root-s : String
                  (string.copy (& (array-ref cand-strs.slots ci)))]
                (str_map.insert-ref! (&mut seen) (string.copy (& root-s)) 1)
                (str_vec.push-ref! (&mut bfs) root-s))
              (while (< cursor (str_vec.len (& bfs)))
                (let
                  [cur : String (string.copy (& (array-ref bfs.slots cursor)))]
                  (+= cursor 1)
                  (match (str_map.get (& sym-to-mod) (string.copy (& cur)))
                    [(LookupFound mi)
                      (let
                        [cur-lid : i64 (intern.intern (string.copy (& cur)))]
                        [slot : i64
                          (tli-compact-ir-slot-by-link multi facts cur-lid)]
                        [no-inits? : bool
                          (and
                            (>= slot 0)
                            (!=
                              (bit-and
                                (array-ref facts.fn-summaries.slots slot).effect-flags
                                tli.tli-fn-no-module-inits)
                              0))]
                        (unless
                          no-inits?
                          (let
                            [istart : i64 (array-ref mod-init-start mi)]
                            [ilen : i64 (array-ref mod-init-len mi)]
                            (for [k (iterator.range 0 ilen)]
                              (set! (array-ref needed (+ istart k)) true)))
                          (let
                            [expanded? : bool false]
                            (when
                              (>= slot 0)
                              (let
                                [eflags : i64
                                  (array-ref facts.fn-summaries.slots slot).effect-flags]
                                [ir-off : i64
                                  (array-ref facts.fn-summaries.slots slot).inline-ir-offset]
                                [ir-len : i64
                                  (array-ref facts.fn-summaries.slots slot).inline-ir-len]
                                [ir-sha : (Array u8 32)
                                  (array-ref facts.fn-summaries.slots slot).inline-ir-sha256]
                                (when
                                  (and
                                    (!=
                                      (bit-and eflags tli.tli-fn-has-inline-ir)
                                      0)
                                    (> ir-len 0))
                                  (match (codec.tli-decode-compact-body-at
                                    (&
                                      (array-ref
                                        multi.bundles.slots
                                        (tli-compact-slot-bundle
                                          multi
                                          facts
                                          slot)).directory)
                                    ir-off
                                    ir-len
                                    (& ir-sha))
                                    [(codec.TliCompactBodyResult.Ok body)
                                      (when
                                        (!=
                                          (bit-and
                                            body.kind
                                            tli.tli-compact-body-has-ir)
                                          0)
                                        (set! expanded? true)
                                        (for [ri
                                          (iterator.range
                                            0
                                            (array-length
                                              body.ir-body.extern-refs))]
                                          (let
                                            [next-s : String
                                              (string.copy
                                                (&
                                                  (array-ref
                                                    body.ir-body.extern-refs
                                                    ri).link-symbol))]
                                            ;; A TypeLisp reference outside every
                                            ;; catalogued module cannot be
                                            ;; followed: keep the import closure.
                                            (when
                                              (and
                                                (=
                                                  (array-ref
                                                    body.ir-body.extern-refs
                                                    ri).abi
                                                  0)
                                                (not
                                                  (str_map.contains?
                                                    (& sym-to-mod)
                                                    (string.copy (& next-s)))))
                                              (set! expanded? false))
                                            (unless
                                              (str_map.contains?
                                                (& seen)
                                                (string.copy (& next-s)))
                                              (str_map.insert-ref!
                                                (&mut seen)
                                                (string.copy (& next-s))
                                                1)
                                              (str_vec.push-ref!
                                                (&mut bfs)
                                                next-s)))))]
                                    [(codec.TliCompactBodyResult.Err _) unit]))))
                            (unless
                              expanded?
                              (let
                                [base : i64 (* mi init-count)]
                                (for [k (iterator.range 0 init-count)]
                                  (when
                                    (array-ref mod-trans (+ base k))
                                    (set! (array-ref needed k) true))))))))]
                    [(LookupMissing) unit])))
              (let
                [nc : i64 0]
                (for [k (iterator.range 0 init-count)]
                  (when (array-ref needed k) (+= nc 1)))
                (when
                  (> nc 0)
                  (let
                    [idxs : (__tl_dyn-array i64) (__tl_make-array i64 nc)]
                    [pos : i64 0]
                    (for [k (iterator.range 0 init-count)]
                      (when
                        (array-ref needed k)
                        (set! (array-ref idxs pos) k)
                        (+= pos 1)))
                    (set!
                      (array-ref deps-tmp dep-count)
                      (TliStartupInitDep sid idxs))
                    (+= dep-count 1))))))
          ;; Package-bundle modules keep source-mode startup semantics: their
          ;; inits, and every init they import, always run. Only stdlib inits
          ;; are pruned to the referenced closure.
          (let
            [always : (__tl_dyn-array bool) (__tl_make-array bool init-count)]
            [nc : i64 0]
            (for [k (iterator.range 0 init-count)]
              (set! (array-ref always k) false))
            (for [pos (iterator.range 0 multi.startup-order.len)]
              (let
                [mi : i64 (array-ref multi.startup-order.slots pos)]
                [base : i64 (* mi init-count)]
                (unless
                  (array-ref
                    multi.bundles.slots
                    (array-ref multi.gid-bundle.slots mi)).is-stdlib
                  (for [k (iterator.range 0 init-count)]
                    (when
                      (array-ref mod-trans (+ base k))
                      (set! (array-ref always k) true))))))
            (for [k (iterator.range 0 init-count)]
              (when (array-ref always k) (+= nc 1)))
            (when
              (> nc 0)
              (let
                [idxs : (__tl_dyn-array i64) (__tl_make-array i64 nc)]
                [pos : i64 0]
                (for [k (iterator.range 0 init-count)]
                  (when
                    (array-ref always k)
                    (set! (array-ref idxs pos) k)
                    (+= pos 1)))
                (set!
                  (array-ref deps-tmp dep-count)
                  (TliStartupInitDep tli-startup-init-always idxs))
                (+= dep-count 1))))
          (let
            [deps : (__tl_dyn-array TliStartupInitDep)
              (__tl_make-array TliStartupInitDep dep-count)]
            (for [di (iterator.range 0 dep-count)]
              (let
                [dn : i64 (array-length (array-ref deps-tmp di).init-indices)]
                [icopy : (__tl_dyn-array i64) (__tl_make-array i64 dn)]
                (for [k (iterator.range 0 dn)]
                  (set!
                    (array-ref icopy k)
                    (array-ref (array-ref deps-tmp di).init-indices k)))
                (set!
                  (array-ref deps di)
                  (TliStartupInitDep (array-ref deps-tmp di).sym-id icopy))))
            (TliStartupInitPlan init-symbols deps)))))))

(define (tli-filter-startup-init-symbols
  [plan : (& TliStartupInitPlan)]
  [program : (& ir.CompilerIrProgram)]) : (__tl_dyn-array String)
  (let
    [icount : i64 (array-length plan.init-symbols)]
    (when (= icount 0) (return (__tl_make-array String 0)))
    (match program
      [(ir.CompilerIrProgram.Program globals functions _ _)
        (let
          [dcount : i64 (array-length plan.deps)]
          [needed : (__tl_dyn-array bool) (__tl_make-array bool icount)]
          [ref-syms : i64_map.Map
            (tli-compact-scan-program-syms functions globals)]
          [kept : i64 0]
          (for [k (iterator.range 0 icount)]
            (set! (array-ref needed k) false))
          (for [di (iterator.range 0 dcount)]
            (when
              (or
                (= (array-ref plan.deps di).sym-id tli-startup-init-always)
                (i64_map.contains? (& ref-syms) (array-ref plan.deps di).sym-id))
              (let
                [kn : i64 (array-length (array-ref plan.deps di).init-indices)]
                (for [k (iterator.range 0 kn)]
                  (let
                    [idx : i64
                      (array-ref (array-ref plan.deps di).init-indices k)]
                    (when
                      (and (>= idx 0) (< idx icount))
                      (set! (array-ref needed idx) true)))))))
          (for [k (iterator.range 0 icount)]
            (when (array-ref needed k) (+= kept 1)))
          (let
            [out : (__tl_dyn-array String) (__tl_make-array String kept)]
            [pos : i64 0]
            (for [k (iterator.range 0 icount)]
              (when
                (array-ref needed k)
                (set!
                  (array-ref out pos)
                  (string.copy (& (array-ref plan.init-symbols k))))
                (+= pos 1)))
            out))])))

(define (tli-hydrate-compact-ir-into-program!
  [multi : (& multi hydrate.TliMultiCatalog)]
  [facts : (& hydrate.TliHydratedFacts)]
  [pools : ast.AstNodePoolContext]
  [program : ir.CompilerIrProgram]
  [opt-level : i64]) : TliHydratedCompactProgram
  (if (or (= opt-level 0) (= facts.hydrated-module-count 0))
    (TliHydratedCompactProgram
      program
      (opt.opt-external-summaries-empty)
      (tli-startup-init-plan-empty))
    (match program
      [(ir.CompilerIrProgram.Program globals functions externs authority)
        (let
          [o2? : bool (>= opt-level 2)]
          (if (not o2?)
            ;; At O1, skip hydrating `HAS_IR` compact IR bodies and optimizer
            ;; external summaries; only build the startup-init pruning plan.
            (let
              [defined-gls : i64_map.Map
                (i64_map.with-capacity (* (+ globals.len 1) 2))]
              [extern-link-by-name : i64_map.Map
                (i64_map.with-capacity (* (+ externs.len 1) 2))]
              (for [i (iterator.range 0 globals.len)]
                (match (ir.compiler-ir-global-seq-borrow (& globals) i)
                  [(ir.CompilerIrGlobal.Global gname _ _ _)
                    (i64_map.insert-ref!
                      (&mut defined-gls)
                      (ir.compiler-ir-symbol-id gname)
                      1)]))
              (for [i (iterator.range 0 externs.len)]
                (match (ir.compiler-ir-extern-seq-borrow (& externs) i)
                  [(ir.CompilerIrExtern.Extern
                      ename
                      _
                      _
                      _
                      _
                      elink
                      _
                      provided
                      _
                      _
                      _)
                    (unless
                      provided
                      (i64_map.insert-ref!
                        (&mut extern-link-by-name)
                        (ir.compiler-ir-symbol-id ename)
                        elink))]))
              (let
                [startup-plan : TliStartupInitPlan
                  (tli-build-startup-init-plan
                    multi
                    facts
                    (& functions)
                    (& globals)
                    (& externs)
                    (& extern-link-by-name)
                    (& defined-gls))]
                (TliHydratedCompactProgram
                  (ir.CompilerIrProgram.Program
                    globals
                    functions
                    externs
                    authority)
                  (opt.opt-external-summaries-empty)
                  startup-plan)))
            (let
              [has-compact? : bool (tli-multi-has-compact-ir? multi)]
              [defined-fns : i64_map.Map
                (i64_map.with-capacity (* (+ functions.len 1) 2))]
              [defined-gls : i64_map.Map
                (i64_map.with-capacity (* (+ globals.len 1) 2))]
              [extern-by-name : i64_map.Map
                (i64_map.with-capacity (* (+ externs.len 1) 2))]
              [extern-link-by-name : i64_map.Map
                (i64_map.with-capacity (* (+ externs.len 1) 2))]
              [init-fn-syms : i64_vec.Vec (i64_vec.new)]
              [init-fn-seen : i64_map.Map (i64_map.with-capacity 128)]
              [ref-globals : str_map.Map (str_map.with-capacity 64)]
              (for [i (iterator.range 0 functions.len)]
                (match (ir.compiler-ir-function-seq-borrow (& functions) i)
                  [(ir.CompilerIrFunction.Function fname _ _ _ blocks _)
                    (i64_map.insert-ref!
                      (&mut defined-fns)
                      (ir.compiler-ir-symbol-id fname)
                      1)
                    (match blocks
                      [(ir.CompilerIrBlockList.Array bseq)
                        (for [bi
                          (iterator.range
                            0
                            (ir.compiler-ir-block-seq-count bseq))]
                          (match (ir.compiler-ir-block-seq-borrow bseq bi)
                            [(ir.CompilerIrBlock.Block _ iseq)
                              (for [ii
                                (iterator.range
                                  0
                                  (ir.compiler-ir-instr-seq-count iseq))]
                                (tli-compact-scan-ir-instr!
                                  (ir.compiler-ir-instr-seq-ref iseq ii)
                                  (&mut init-fn-syms)
                                  (&mut init-fn-seen)
                                  (&mut ref-globals)))]))])]))
              (for [i (iterator.range 0 globals.len)]
                (match (ir.compiler-ir-global-seq-borrow (& globals) i)
                  [(ir.CompilerIrGlobal.Global gname _ ginit _)
                    (i64_map.insert-ref!
                      (&mut defined-gls)
                      (ir.compiler-ir-symbol-id gname)
                      1)
                    (tli-compact-scan-ir-value!
                      ginit
                      (&mut init-fn-syms)
                      (&mut init-fn-seen)
                      (&mut ref-globals))]))
              (for [i (iterator.range 0 externs.len)]
                (match (ir.compiler-ir-extern-seq-borrow (& externs) i)
                  [(ir.CompilerIrExtern.Extern
                      ename
                      _
                      _
                      _
                      _
                      elink
                      _
                      provided
                      _
                      _
                      _)
                    (unless
                      provided
                      (let
                        [nid : i64 (ir.compiler-ir-symbol-id ename)]
                        (i64_map.insert-ref! (&mut extern-by-name) nid i)
                        (i64_map.insert-ref!
                          (&mut extern-link-by-name)
                          nid
                          elink)))]))
              ;; Seed worklist from direct calls/refs to hydrated externs.
              (let
                [wl-names : i64_vec.Vec (i64_vec.new)]
                [wl-slots : i64_vec.Vec (i64_vec.new)]
                [wl-seen : i64_map.Map (i64_map.with-capacity 128)]
                [avail-names : i64_map.Map (i64_map.with-capacity 128)]
                [fn-builder : ir.CompilerIrFunctionBuilder
                  (ir.compiler-ir-function-builder-with-capacity
                    (+ functions.len 32))]
                [gl-builder : ir.CompilerIrGlobalBuilder
                  (ir.compiler-ir-global-builder-with-capacity
                    (+ globals.len 16))]
                [ex-builder : ir.CompilerIrExternBuilder
                  (ir.compiler-ir-extern-builder-with-capacity
                    (+ externs.len 32))]
                [added-fns : i64 0]
                [added-gls : i64 0]
                [added-exs : i64 0]
                [body-ref-globals : str_map.Map (str_map.with-capacity 32)]
                (for [i (iterator.range 0 functions.len)]
                  (ir.compiler-ir-function-builder-push!
                    (&mut fn-builder)
                    (ir.compiler-ir-function-seq-ref (& functions) i)))
                (for [i (iterator.range 0 globals.len)]
                  (ir.compiler-ir-global-builder-push!
                    (&mut gl-builder)
                    (ir.compiler-ir-global-seq-ref (& globals) i)))
                (when
                  has-compact?
                  (for [i (iterator.range 0 (i64_vec.len (& init-fn-syms)))]
                    (let
                      [sid : i64 (i64_vec.get (& init-fn-syms) i 0)]
                      (when
                        (and
                          (not (i64_map.contains? (& defined-fns) sid))
                          (not (i64_map.contains? (& wl-seen) sid)))
                        (let
                          [link-id : i64
                            (i64_map.get-value-or
                              (& extern-link-by-name)
                              sid
                              -1)]
                          (when
                            (>= link-id 0)
                            (let
                              [slot : i64
                                (tli-compact-ir-slot-by-link
                                  multi
                                  facts
                                  link-id)]
                              (when
                                (>= slot 0)
                                (i64_map.insert-ref! (&mut wl-seen) sid 1)
                                (i64_vec.push-ref! (&mut wl-names) sid)
                                (i64_vec.push-ref! (&mut wl-slots) slot))))))))
                  (let
                    [cursor : i64 0]
                    (while (< cursor (i64_vec.len (& wl-names)))
                      (let
                        [target-name : i64 (i64_vec.get (& wl-names) cursor 0)]
                        [slot : i64 (i64_vec.get (& wl-slots) cursor 0)]
                        [eflags : i64
                          (array-ref facts.fn-summaries.slots slot).effect-flags]
                        [ir-off : i64
                          (array-ref facts.fn-summaries.slots slot).inline-ir-offset]
                        [ir-len : i64
                          (array-ref facts.fn-summaries.slots slot).inline-ir-len]
                        [ir-sha : (Array u8 32)
                          (array-ref facts.fn-summaries.slots slot).inline-ir-sha256]
                        (+= cursor 1)
                        (when
                          (and
                            (!= (bit-and eflags tli.tli-fn-has-inline-ir) 0)
                            (> ir-len 0))
                          (match (codec.tli-decode-compact-body-at
                            (&
                              (array-ref
                                multi.bundles.slots
                                (tli-compact-slot-bundle multi facts slot)).directory)
                            ir-off
                            ir-len
                            (& ir-sha))
                            [(codec.TliCompactBodyResult.Err _) unit]
                            [(codec.TliCompactBodyResult.Ok body)
                              (when
                                (!=
                                  (bit-and
                                    body.kind
                                    tli.tli-compact-body-has-ir)
                                  0)
                                (ir.compiler-ir-function-builder-push!
                                  (&mut fn-builder)
                                  (tli-compact-ir-body-to-function
                                    pools
                                    target-name
                                    (& body.ir-body)))
                                (+= added-fns 1)
                                (i64_map.insert-ref!
                                  (&mut avail-names)
                                  target-name
                                  1)
                                (i64_map.insert-ref!
                                  (&mut defined-fns)
                                  target-name
                                  1)
                                (tli-compact-scan-wire-body-globals!
                                  (& body.ir-body)
                                  (&mut body-ref-globals))
                                ;; Add missing extern refs and enqueue transitive O2 callees.
                                (for [ri
                                  (iterator.range
                                    0
                                    (array-length body.ir-body.extern-refs))]
                                  (let
                                    [ref-sym : i64
                                      (tli-compact-dec-symbol
                                        (&
                                          (array-ref
                                            body.ir-body.extern-refs
                                            ri).symbol))]
                                    [ref-link : i64
                                      (intern.intern
                                        (string.copy
                                          (&
                                            (array-ref
                                              body.ir-body.extern-refs
                                              ri).link-symbol)))]
                                    (unless
                                      (i64_map.contains?
                                        (& extern-by-name)
                                        ref-sym)
                                      (let
                                        [new-ext : ir.CompilerIrExtern
                                          (tli-compact-extern-ref-to-ir
                                            pools
                                            (&
                                              (array-ref
                                                body.ir-body.extern-refs
                                                ri)))]
                                        (i64_map.insert-ref!
                                          (&mut extern-by-name)
                                          ref-sym
                                          (+ externs.len added-exs))
                                        (i64_map.insert-ref!
                                          (&mut extern-link-by-name)
                                          ref-sym
                                          ref-link)
                                        (ir.compiler-ir-extern-builder-push!
                                          (&mut ex-builder)
                                          new-ext)
                                        (+= added-exs 1)))
                                    (when
                                      (and
                                        (not
                                          (i64_map.contains?
                                            (& defined-fns)
                                            ref-sym))
                                        (not
                                          (i64_map.contains?
                                            (& wl-seen)
                                            ref-sym)))
                                      (let
                                        [cslot : i64
                                          (tli-compact-ir-slot-by-link
                                            multi
                                            facts
                                            ref-link)]
                                        (when
                                          (>= cslot 0)
                                          (i64_map.insert-ref!
                                            (&mut wl-seen)
                                            ref-sym
                                            1)
                                          (i64_vec.push-ref!
                                            (&mut wl-names)
                                            ref-sym)
                                          (i64_vec.push-ref!
                                            (&mut wl-slots)
                                            cslot)))))))])))))
                  ;; Inject referenced never-written literal `compact_globals`.
                  (when
                    (or
                      (> (str_map.len (& body-ref-globals)) 0)
                      (and o2? (> (str_map.len (& ref-globals)) 0)))
                    (for [cb (iterator.range 0 multi.bundles.len)]
                      (when
                        (!=
                          (bit-and
                            (array-ref multi.bundles.slots cb).directory.flags
                            tli.tli-has-compact-ir)
                          0)
                        (match (codec.tli-decode-compact-globals
                          (& (array-ref multi.bundles.slots cb).directory))
                          [(codec.TliCompactGlobalsResult.Err _) unit]
                          [(codec.TliCompactGlobalsResult.Ok cglobals)
                            (for [gi (iterator.range 0 (array-length cglobals))]
                              (let
                                [flags : i64 (array-ref cglobals gi).flags]
                                [sym-copy : String
                                  (string.copy
                                    (& (array-ref cglobals gi).symbol))]
                                [needed? : bool
                                  (or
                                    (str_map.contains?
                                      (& body-ref-globals)
                                      (string.copy (& sym-copy)))
                                    (and
                                      o2?
                                      (str_map.contains?
                                        (& ref-globals)
                                        sym-copy)))]
                                (when
                                  (and
                                    needed?
                                    (!=
                                      (bit-and
                                        flags
                                        tli.tli-compact-global-never-written)
                                      0))
                                  (let
                                    [gid : i64
                                      (tli-compact-dec-symbol
                                        (& (array-ref cglobals gi).symbol))]
                                    (unless
                                      (i64_map.contains? (& defined-gls) gid)
                                      (ir.compiler-ir-global-builder-push!
                                        (&mut gl-builder)
                                        (tli-compact-global-to-ir
                                          pools
                                          (& (array-ref cglobals gi))))
                                      (+= added-gls 1)
                                      (i64_map.insert-ref!
                                        (&mut defined-gls)
                                        gid
                                        1)
                                      (when
                                        (i64_map.contains?
                                          (& extern-by-name)
                                          gid)
                                        (i64_map.insert-ref!
                                          (&mut avail-names)
                                          gid
                                          1)))))))])))))
                ;; Assemble final extern sequence with `body-available` updated.
                (let
                  [final-ex-builder : ir.CompilerIrExternBuilder
                    (ir.compiler-ir-extern-builder-with-capacity
                      (+ externs.len added-exs))]
                  [added-ex-seq : ir.CompilerIrExternSeq
                    (ir.compiler-ir-extern-builder-snapshot-seq (& ex-builder))]
                  (for [i (iterator.range 0 externs.len)]
                    (match (ir.compiler-ir-extern-seq-ref (& externs) i)
                      [(ir.CompilerIrExtern.Extern
                          nid
                          snid
                          nm
                          ty
                          abi
                          lid
                          links
                          prov
                          storage
                          ba
                          cell)
                        (let
                          [avail? : bool
                            (or
                              ba
                              (and
                                (not prov)
                                (i64_map.contains?
                                  (& avail-names)
                                  (ir.compiler-ir-symbol-id nid))))]
                          (ir.compiler-ir-extern-builder-push!
                            (&mut final-ex-builder)
                            (ir.CompilerIrExtern.Extern
                              nid
                              snid
                              nm
                              ty
                              abi
                              lid
                              links
                              prov
                              storage
                              avail?
                              cell)))]))
                  (for [i (iterator.range 0 added-ex-seq.len)]
                    (match (ir.compiler-ir-extern-seq-ref (& added-ex-seq) i)
                      [(ir.CompilerIrExtern.Extern
                          nid
                          snid
                          nm
                          ty
                          abi
                          lid
                          links
                          prov
                          storage
                          _
                          cell)
                        (let
                          [avail? : bool
                            (i64_map.contains?
                              (& avail-names)
                              (ir.compiler-ir-symbol-id nid))]
                          (ir.compiler-ir-extern-builder-push!
                            (&mut final-ex-builder)
                            (ir.CompilerIrExtern.Extern
                              nid
                              snid
                              nm
                              ty
                              abi
                              lid
                              links
                              prov
                              storage
                              avail?
                              cell)))]))
                  (let
                    [final-globals : ir.CompilerIrGlobalSeq
                      (ir.compiler-ir-global-builder-snapshot-seq
                        (& gl-builder))]
                    [final-functions : ir.CompilerIrFunctionSeq
                      (ir.compiler-ir-function-builder-to-seq fn-builder)]
                    [final-externs : ir.CompilerIrExternSeq
                      (ir.compiler-ir-extern-builder-snapshot-seq
                        (& final-ex-builder))]
                    ;; Refresh ReturnStorageAuthority if we added bodies or externs.
                    [final-authority : ir.CompilerIrReturnStorageAuthority
                      (if (and (= added-fns 0) (= added-exs 0))
                        authority
                        (match authority
                          [(ir.CompilerIrReturnStorageAuthority.Captured boxed)
                            (let
                              [target : i64 (deref boxed).target]
                              [interns : intern.InternCompatState
                                (intern.intern-compat-state-capture-active)]
                              [bases : i64
                                (ast.ast-node-pool-context-type-segment-bases
                                  (& pools))]
                              [type-count : i64
                                (match (ast.ast-node-pool-context-type-stamp
                                  pools)
                                  [(ast.AstMaybeTypePoolStamp.Some stamp)
                                    stamp.count]
                                  [(ast.AstMaybeTypePoolStamp.No) 0])]
                              [claims : ir.CompilerIrReturnStorageIndex
                                (ir.compiler-ir-return-storage-index-claims
                                  bases
                                  type-count
                                  (& final-functions)
                                  (& final-externs))]
                              (ir.compiler-ir-return-storage-authority-capture
                                pools
                                (& interns)
                                target
                                (& claims)))]
                          [_ authority]))]
                    ;; Build OptExternalSummaries at O2 for remaining out-of-line externs.
                    [ext-summaries : opt.OptExternalSummaries
                      (if (not o2?)
                        (opt.opt-external-summaries-empty)
                        (let
                          [sum-vec : ext_sum_vec.Vec (ext_sum_vec.new)]
                          [seen-links : i64_map.Map (i64_map.with-capacity 64)]
                          (for [ei (iterator.range 0 final-externs.len)]
                            (match (ir.compiler-ir-extern-seq-borrow
                              (& final-externs)
                              ei)
                              [(ir.CompilerIrExtern.Extern
                                  nid
                                  _
                                  _
                                  _
                                  _
                                  elink
                                  _
                                  prov
                                  _
                                  _
                                  _)
                                (when
                                  (and
                                    (not prov)
                                    (not
                                      (i64_map.contains? (& seen-links) elink)))
                                  (let
                                    [lookup-link : i64
                                      (i64_map.get-value-or
                                        (& extern-link-by-name)
                                        (ir.compiler-ir-symbol-id nid)
                                        elink)]
                                    [slot : i64
                                      (hydrate.tli-hydrated-facts-fn-summary-slot-by-link
                                        facts
                                        lookup-link)]
                                    (when
                                      (>= slot 0)
                                      (i64_map.insert-ref!
                                        (&mut seen-links)
                                        elink
                                        1)
                                      (let
                                        [gw-len : i64
                                          (array-length
                                            (array-ref
                                              facts.fn-summaries.slots
                                              slot).global-writes)]
                                        [gw-ids : (__tl_dyn-array i64)
                                          (__tl_make-array i64 gw-len)]
                                        (for [wi (iterator.range 0 gw-len)]
                                          (set!
                                            (array-ref gw-ids wi)
                                            (array-ref
                                              (array-ref
                                                facts.fn-summaries.slots
                                                slot).global-writes
                                              wi).symbol-id))
                                        (ext_sum_vec.push-ref!
                                          (&mut sum-vec)
                                          (opt.OptExternalFnSummary
                                            elink
                                            (array-ref
                                              facts.fn-summaries.slots
                                              slot).effect-flags
                                            (array-ref
                                              facts.fn-summaries.slots
                                              slot).call-memory
                                            (cast
                                              (array-ref
                                                facts.fn-summaries.slots
                                                slot).call-clean
                                              : i64)
                                            (array-ref
                                              facts.fn-summaries.slots
                                              slot).return-alias
                                            gw-ids))))))]))
                          (let
                            [scount : i64 (ext_sum_vec.len (& sum-vec))]
                            [out : (__tl_dyn-array opt.OptExternalFnSummary)
                              (__tl_make-array opt.OptExternalFnSummary scount)]
                            (for [si (iterator.range 0 scount)]
                              (let
                                [gn : i64
                                  (array-length
                                    (array-ref sum-vec.slots si).global-write-ids)]
                                [gcopy : (__tl_dyn-array i64)
                                  (__tl_make-array i64 gn)]
                                (for [gi (iterator.range 0 gn)]
                                  (set!
                                    (array-ref gcopy gi)
                                    (array-ref
                                      (array-ref sum-vec.slots si).global-write-ids
                                      gi)))
                                (set!
                                  (array-ref out si)
                                  (opt.OptExternalFnSummary
                                    (array-ref sum-vec.slots si).link-id
                                    (array-ref sum-vec.slots si).effect-flags
                                    (array-ref sum-vec.slots si).call-memory
                                    (array-ref sum-vec.slots si).call-clean
                                    (array-ref sum-vec.slots si).return-alias
                                    gcopy))))
                            (opt.OptExternalSummaries out))))]
                    [startup-plan : TliStartupInitPlan
                      (tli-build-startup-init-plan
                        multi
                        facts
                        (& final-functions)
                        (& final-globals)
                        (& final-externs)
                        (& extern-link-by-name)
                        (& defined-gls))]
                    (TliHydratedCompactProgram
                      (ir.CompilerIrProgram.Program
                        final-globals
                        final-functions
                        final-externs
                        final-authority)
                      ext-summaries
                      startup-plan)))))))])))

(define (tli-hydrate-compact-ir-from-ptrs!
  [catalog-ptr : i64]
  [facts-ptr : i64]
  [pools : ast.AstNodePoolContext]
  [program : ir.CompilerIrProgram]
  [opt-level : i64]) : TliHydratedCompactProgram
  (if (or (= catalog-ptr 0) (= facts-ptr 0) (= opt-level 0))
    (TliHydratedCompactProgram
      program
      (opt.opt-external-summaries-empty)
      (tli-startup-init-plan-empty))
    (unsafe
      (let
        [multi : hydrate.TliMultiCatalog
          (ptr-read
            (int->ptr (cast catalog-ptr : u64) : (Ptr hydrate.TliMultiCatalog)))]
        [facts : hydrate.TliHydratedFacts
          (ptr-read
            (int->ptr (cast facts-ptr : u64) : (Ptr hydrate.TliHydratedFacts)))]
        (tli-hydrate-compact-ir-into-program!
          (& multi)
          (& facts)
          pools
          program
          opt-level)))))