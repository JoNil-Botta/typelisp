;; Standalone interface hydration. Callers open and use the catalog within a
;; dedicated with-arena extent. Only projected semantic ids can escape it.
(import compiler_tli_types as tli)
(import compiler_tli_codec as codec)
(import compiler_abi as cabi)
(import compiler_ast_types as ast)
(import compiler_cfg_core as cfg_core)
(import compiler_float as cfloat)
(import compiler_intern as intern)
(import compiler_symbols as csym)
(import tlci_core as tlci)
(import sym_i64_env)
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.byte_buf_core as buf)
(import stdlib.byte_le as le)
(import stdlib.crypto_sha256 as sha256)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as tli_i64_map)
(import (hashmap.hashmap String i64) as tli_str_map)
(import stdlib.iterator)
(import stdlib.math)
(import stdlib.sort)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.text_buf_borrowed)
(import stdlib.vector)
(import (vector.vector i64) as tli_i64_vec)
(import (vector.vector String) as tli_svec)

(defstruct TliCatalog
  (directory codec.TliDirectory)
  (cfg-digest (Array u8 32))
  (records (__tl_dyn-array tli.TliModuleRecord))
  (states (__tl_dyn-array i64))
  (stack (__tl_dyn-array i64))
  (next-edge (__tl_dyn-array i64))
  (startup-order (__tl_dyn-array i64))
  (ready-count i64)
  (owned-bytes i64)
  (failed bool))

(defenum TliCatalogResult
  (Ok TliCatalog)
  (Err tli.TliDecodeFailure))

(defenum TliHydrateResult
  (Ok i64)
  (Err tli.TliDecodeFailure))

(define (tli-catalog-open-directory
  [bytes : (& bytes (__tl_dyn-array u8))]
  [build : (& build str)]
  [target : (& target str)]) : codec.TliDirectoryResult
  (codec.tli-decode-directory-for bytes build target))

(define (tli-catalog-open-from-directory
  [directory-result : codec.TliDirectoryResult]
  [cfg-digest : (& (Array u8 32))]) : TliCatalogResult
  (match directory-result
    [(Err failure) (Err failure)]
    [(Ok directory)
      (let
        [count : i64 (array-length directory.entries)]
        [owned : i64
          (+
            directory.owned-bytes
            80
            (* count (+ 32 (comptime (size-of (type tli.TliModuleRecord))))))]
        (if (> owned codec.tli-max-owned-bytes)
          (Err
            (tli.TliDecodeFailure
              (tli.TliDecodeError.Limit)
              0
              "TLI catalog exceeds the owned-byte limit"))
          (Ok
            (TliCatalog
              directory
              (deref cfg-digest)
              (__tl_make-array tli.TliModuleRecord count)
              (__tl_make-array i64 count)
              (__tl_make-array i64 count)
              (__tl_make-array i64 count)
              (__tl_make-array i64 count)
              0
              owned
              false))))]))

(define (tli-catalog-open
  [bytes : (& bytes (__tl_dyn-array u8))]
  [build : (& build str)]
  [target : (& target str)]
  [cfg-digest : (& (Array u8 32))]) : TliCatalogResult
  (tli-catalog-open-from-directory
    (tli-catalog-open-directory bytes build target)
    cfg-digest))

(define (tli-catalog-open-lazy
  [bytes : (& bytes (__tl_dyn-array u8))]
  [build : (& build str)]
  [target : (& target str)]
  [cfg-digest : (& (Array u8 32))]) : TliCatalogResult
  (tli-catalog-open-from-directory
    (codec.tli-decode-directory-for-lazy bytes build target)
    cfg-digest))

(define (tli-catalog-directory [catalog : (& catalog TliCatalog)]) : (&
    catalog
    codec.TliDirectory)
  (& catalog.directory))

(define (tli-catalog-ready-count [catalog : (& TliCatalog)]) : i64
  (if catalog.failed
    0
    catalog.ready-count))

(cfg
  test
  (define (tli-catalog-owned-bytes [catalog : (& TliCatalog)]) : i64
    catalog.owned-bytes))

(define (tli-catalog-find
  [directory : (& directory codec.TliDirectory)]
  [name : (& name str)]) : i64
  (let
    [first : i64 0]
    [last : i64 (array-length directory.entries)]
    (while (< first last)
      (let
        [mid : i64 (+ first (/ (- last first) 2))]
        [candidate (& (array-ref directory.entries mid).name)]
        (cond
          [(string.eq name candidate) (return mid)]
          [(sort.string-less-borrowed? name candidate) (set! last mid)]
          [else (set! first (+ mid 1))])))
    -1))

(define (tli-catalog-fail!
  [failed : (&mut bool)]
  [kind : tli.TliDecodeError]
  [offset : i64]
  [message : String]) : TliHydrateResult
  (set! (deref failed) true)
  (Err (tli.TliDecodeFailure kind offset message)))

;; Postorder DFS over the directory. Pending rows are never exposed, even
;; when their own digest and cfg have already passed. The directory bounds
;; the explicit stack regardless of import depth in the input.
(define (tli-catalog-hydrate!
  [catalog : (&mut catalog TliCatalog)]
  [name : (& name str)]) : TliHydrateResult
  (when
    catalog.failed
    (return
      (Err
        (tli.TliDecodeFailure
          (tli.TliDecodeError.UnknownTag)
          0
          "TLI catalog has a previously rejected record"))))
  (let
    [root : i64 (tli-catalog-find (& catalog.directory) name)]
    (when
      (< root 0)
      (return
        (Err
          (tli.TliDecodeFailure
            (tli.TliDecodeError.UnknownTag)
            0
            "TLI module is missing from the directory"))))
    (when (= (array-ref catalog.states root) 2) (return (Ok root)))
    (let
      [depth : i64 1]
      (set! (array-ref catalog.stack 0) root)
      (while (> depth 0)
        (let
          [top : i64 (- depth 1)]
          [index : i64 (array-ref catalog.stack top)]
          [offset : i64
            (array-ref catalog.directory.entries index).record-offset]
          (when
            (= (array-ref catalog.states index) 0)
            (match (codec.tli-decode-record-at
              (& catalog.directory)
              index
              catalog.owned-bytes)
              [(Err failure)
                (set! catalog.failed true)
                (return (Err failure))]
              [(Ok record used)
                (unless
                  (codec.tli-digest-eq?
                    (& record.cfg-fingerprint-sha256)
                    (& catalog.cfg-digest))
                  (return
                    (tli-catalog-fail!
                      (&mut catalog.failed)
                      (tli.TliDecodeError.CfgFingerprintMismatch)
                      (+ offset 40)
                      "TLI configuration fingerprint mismatch")))
                (set! (array-ref catalog.records index) record)
                (set! catalog.owned-bytes used)
                (set! (array-ref catalog.states index) 1)
                (set! (array-ref catalog.next-edge top) 0)]))
          (let
            [next : i64 (array-ref catalog.next-edge top)]
            (if (=
              next
              (array-length (array-ref catalog.records index).imports))
              (begin
                (set! (array-ref catalog.states index) 2)
                (set!
                  (array-ref catalog.startup-order catalog.ready-count)
                  index)
                (+= catalog.ready-count 1)
                (-= depth 1))
              (let
                [dependency : i64
                  (tli-catalog-find
                    (& catalog.directory)
                    (&
                      (array-ref (array-ref catalog.records index).imports next).module-name))]
                (when
                  (< dependency 0)
                  (return
                    (tli-catalog-fail!
                      (&mut catalog.failed)
                      (tli.TliDecodeError.UnknownTag)
                      offset
                      "TLI import is missing from the directory")))
                (unless
                  (codec.tli-digest-eq?
                    (&
                      (array-ref (array-ref catalog.records index).imports next).interface-sha256)
                    (&
                      (array-ref catalog.directory.entries dependency).module-sha256))
                  (return
                    (tli-catalog-fail!
                      (&mut catalog.failed)
                      (tli.TliDecodeError.DigestMismatch)
                      offset
                      "TLI import SHA-256 mismatch")))
                (+= (array-ref catalog.next-edge top) 1)
                (match (array-ref catalog.states dependency)
                  [0
                    (set! (array-ref catalog.stack depth) dependency)
                    (+= depth 1)]
                  [1
                    (return
                      (tli-catalog-fail!
                        (&mut catalog.failed)
                        (tli.TliDecodeError.UnknownTag)
                        offset
                        "TLI import cycle"))]
                  [_ unit]))))))
      (Ok root))))

(defenum TliCatalogRecord
  (:lifetimes catalog)
  (Some (& catalog tli.TliModuleRecord))
  (None))

(define (tli-catalog-record [catalog : (& catalog TliCatalog)] [index : i64]) : (TliCatalogRecord
    catalog)
  (if (and
    (not catalog.failed)
    (>= index 0)
    (< index (array-length catalog.states))
    (= (array-ref catalog.states index) 2))
    (Some (& (array-ref catalog.records index)))
    None))

(define (tli-catalog-startup-symbols [catalog : (& TliCatalog)]) : (__tl_dyn-array
    i64)
  (let
    [count : i64 0]
    (when catalog.failed (return (__tl_make-array i64 0)))
    (for [position (iterator.range 0 catalog.ready-count)]
      (+=
        count
        (array-length
          (array-ref catalog.records (array-ref catalog.startup-order position)).global-inits)))
    (let
      [symbols : (__tl_dyn-array i64) (__tl_make-array i64 count)]
      [next : i64 0]
      (for [position (iterator.range 0 catalog.ready-count)]
        (let
          [module-index : i64 (array-ref catalog.startup-order position)]
          [count : i64
            (array-length (array-ref catalog.records module-index).global-inits)]
          (for [index (iterator.range 0 count)]
            (set!
              (array-ref symbols next)
              (tli-hydrate-name
                (&
                  (array-ref
                    (array-ref catalog.records module-index).global-inits
                    index))))
            (+= next 1))))
      symbols)))

(define (tli-hydrate-name [text : (& str)]) : i64
  (intern.intern-slice text 0 (string.string-length text)))

(defstruct TliHydratedImport
  (module-name i64)
  (kind i64)
  (alias i64)
  (item i64))

(define (tli-hydrate-import [row : (& tli.TliImport)]) : TliHydratedImport
  (TliHydratedImport
    (tli-hydrate-name (& row.module-name))
    row.kind
    (tli-hydrate-name (& row.alias))
    (tli-hydrate-name (& row.item))))

(define (tli-hydrate-nominal-name [name : (& str)]) : i64
  (ast.ast-nominal-name-id-key (tli-hydrate-name name)))

(define (tli-hydrate-lifetimes [names : (& names (__tl_dyn-array String))]) : ast.AstLifetimeList
  (let
    [out : ast.AstLifetimeList
      (ast.ast-lifetime-list-with-capacity (array-length names))]
    (for [index (iterator.range 0 (array-length names))]
      (ast.ast-lifetime-list-push
        (&mut out)
        (tli-hydrate-name (& (array-ref names index)))))
    out))

(define (tli-hydrate-type-list [types : (& types (__tl_dyn-array tli.TliType))]) : ast.AstTypeList
  (let
    [out : ast.AstTypeList
      (ast.ast-type-list-with-capacity (array-length types))]
    (for [index (iterator.range 0 (array-length types))]
      (ast.ast-type-list-push
        (&mut out)
        (tli-hydrate-type-id (& (array-ref types index)))))
    out))

(define (tli-hydrate-type-id [ty : (& tli.TliType)]) : i64
  (ast.ty-node-push (& (tli-hydrate-type ty))))

(define (tli-hydrate-type [ty : (& tli.TliType)]) : ast.AstType
  (match ty
    [(I64) (ast.AstType.I64)]
    [(I32) (ast.AstType.I32)]
    [(I16) (ast.AstType.I16)]
    [(I8) (ast.AstType.I8)]
    [(U64) (ast.AstType.U64)]
    [(U32) (ast.AstType.U32)]
    [(U16) (ast.AstType.U16)]
    [(U8) (ast.AstType.U8)]
    [(F64) (ast.AstType.F64)]
    [(F32) (ast.AstType.F32)]
    [(Bool) (ast.AstType.Bool)]
    [(Char) (ast.AstType.Char)]
    [(String) (ast.AstType.String)]
    [(Str) (ast.AstType.Str)]
    [(Bytes) (ast.AstType.Bytes)]
    [(Unit) (ast.AstType.Unit)]
    [(Never) (ast.AstType.Never)]
    [(Expr) (ast.AstType.Expr)]
    [(ExprList) (ast.AstType.ExprList)]
    [(Func args ret)
      (ast.AstType.Func
        (box (tli-hydrate-type-list args))
        (tli-hydrate-type-id (& (deref ret))))]
    [(Tuple items) (ast.AstType.Tuple (box (tli-hydrate-type-list items)))]
    [(Array elem len)
      (ast.AstType.Array (tli-hydrate-type-id (& (deref elem))) len)]
    [(DynArray elem)
      (ast.AstType.DynArray (tli-hydrate-type-id (& (deref elem))))]
    [(Box elem) (ast.AstType.Box (tli-hydrate-type-id (& (deref elem))))]
    [(Region life inner)
      (ast.AstType.Region
        (tli-hydrate-name life)
        (tli-hydrate-type-id (& (deref inner))))]
    [(Ref life inner)
      (ast.AstType.Ref
        (tli-hydrate-name life)
        (tli-hydrate-type-id (& (deref inner))))]
    [(MutRef life inner)
      (ast.AstType.MutRef
        (tli-hydrate-name life)
        (tli-hydrate-type-id (& (deref inner))))]
    [(Invalidate life inner)
      (ast.ast-ty-invalidate-id
        (tli-hydrate-name life)
        (tli-hydrate-type-id (& (deref inner))))]
    [(Enum name) (ast.AstType.Enum (tli-hydrate-nominal-name name))]
    [(EnumArgs name lives)
      (ast.ast-ty-enum-args
        (tli-hydrate-nominal-name name)
        (tli-hydrate-lifetimes lives))]
    [(Struct name) (ast.AstType.Struct (tli-hydrate-nominal-name name))]
    [(StructArgs name lives)
      (ast.ast-ty-struct-args
        (tli-hydrate-nominal-name name)
        (tli-hydrate-lifetimes lives))]
    [(Var name) (ast.AstType.Var (tli-hydrate-nominal-name name))]
    [(VarArgs name lives)
      (ast.ast-ty-var-args
        (tli-hydrate-nominal-name name)
        (tli-hydrate-lifetimes lives))]
    [(Ptr elem) (ast.AstType.Ptr (tli-hydrate-type-id (& (deref elem))))]
    [(MutPtr elem) (ast.AstType.MutPtr (tli-hydrate-type-id (& (deref elem))))]
    [(Slice elem) (ast.AstType.Slice (tli-hydrate-type-id (& (deref elem))))]
    [(CFunc signature mode)
      (ast.AstType.CFunc
        (tli-hydrate-type-id (& (deref signature)))
        (match mode
          [0 (ast.AstCFunctionMode.Nullable)]
          [1 (ast.AstCFunctionMode.NonNull)]
          [2 (ast.AstCFunctionMode.UnsafeNullable)]
          [_ (ast.AstCFunctionMode.UnsafeNonNull)]))]))

(defenum TliHydratedCleanup
  (No)
  (Fn i64)
  (Owned))

(define (tli-hydrate-cleanup [row : (& tli.TliCleanup)]) : TliHydratedCleanup
  (match row
    [(No) No]
    [(Fn name) (Fn (tli-hydrate-name name))]
    [(Owned) Owned]))

(defstruct TliHydratedType
  (name i64)
  (module-name i64)
  (nominal-name i64)
  (flags i64)
  (size i64)
  (align i64)
  (repr-kind i64)
  (repr-align i64)
  (cleanup TliHydratedCleanup)
  (lifetimes ast.AstLifetimeList))

(define (tli-hydrate-type-decl [row : (& tli.TliTypeDecl)]) : TliHydratedType
  (let
    [name : i64 (tli-hydrate-name (& row.name))]
    [owner : i64 (tli-hydrate-name (& row.module-name))]
    [nominal : i64
      (if (= (string.string-length (& row.module-name)) 0)
        name
        (intern.intern-composite-pair-id owner name))]
    (TliHydratedType
      name
      owner
      nominal
      row.flags
      row.layout-size
      row.layout-align
      row.repr-kind
      row.repr-align
      (tli-hydrate-cleanup (& row.cleanup))
      (tli-hydrate-lifetimes (& row.lifetimes)))))

(defstruct TliHydratedField
  (name i64)
  (type-id i64)
  (cleanup TliHydratedCleanup)
  (byte-offset i64)
  (explicit-align i64))

(define (tli-hydrate-field [row : (& tli.TliField)]) : TliHydratedField
  (TliHydratedField
    (tli-hydrate-name (& row.name))
    (tli-hydrate-type-id (& row.ty))
    (tli-hydrate-cleanup (& row.cleanup))
    row.byte-offset
    row.explicit-align))

(defstruct TliHydratedPayload
  (type-id i64)
  (cleanup TliHydratedCleanup))

(define (tli-hydrate-payload [row : (& tli.TliPayload)]) : TliHydratedPayload
  (TliHydratedPayload
    (tli-hydrate-type-id (& row.ty))
    (tli-hydrate-cleanup (& row.cleanup))))

(defstruct TliHydratedFunction
  (name i64)
  (module-name i64)
  (link-symbol i64)
  (signature-id i64)
  (abi ast.AstExternAbi)
  (effect-flags i64))

(define (tli-hydrate-function [row : (& tli.TliFnDecl)]) : TliHydratedFunction
  (let
    [count : i64 (array-length row.params)]
    [fixed-count : i64
      (if (= row.abi 3)
        (- count 1)
        count)]
    [params : ast.AstTypeList (ast.ast-type-list-with-capacity fixed-count)]
    (for [index (iterator.range 0 fixed-count)]
      (ast.ast-type-list-push
        (&mut params)
        (tli-hydrate-type-id (& (array-ref row.params index).ty))))
    (let
      [abi : ast.AstExternAbi
        (match row.abi
          [0 (ast.AstExternAbi.TypeLisp)]
          [1 (ast.AstExternAbi.C)]
          [2 (ast.AstExternAbi.CVarargsOpen)]
          [_
            (ast.AstExternAbi.CVarargsTyped
              (ast.ty-node-get
                (tli-hydrate-type-id (& (array-ref row.params fixed-count).ty))))])]
      (TliHydratedFunction
        (tli-hydrate-name (& row.name))
        (tli-hydrate-name (& row.module-name))
        (tli-hydrate-name (& row.link-symbol))
        (ast.ty-node-push
          (&
            (ast.AstType.Func
              (box params)
              (tli-hydrate-type-id (& row.return-type)))))
        abi
        row.summary.effect-flags))))

(define (tli-hydrate-arena-arg-store?
  [summary : (& tli.TliFnSummary)]
  [index : i64]) : bool
  (cond
    [(< index 0) false]
    [(< index 64) (!= 0 (bit-and summary.arena-arg-store-mask (shl 1 index)))]
    [else
      (for [slot
        (iterator.range 0 (array-length summary.arena-arg-store-extra))]
        (let
          [stored : i64 (array-ref summary.arena-arg-store-extra slot)]
          (when (= stored index) (return true))))
      false]))

(define (tli-hydrate-global-write [row : (& tli.TliGlobalWrite)]) : (Tuple
    i64
    u8)
  (tuple (tli-hydrate-name (& row.symbol)) row.flags))

(defstruct TliHydratedValue
  (name i64)
  (module-name i64)
  (link-symbol i64)
  (type-id i64)
  (flags i64)
  (is-extern bool))

(define (tli-hydrate-value [row : (& tli.TliValueDecl)]) : TliHydratedValue
  (TliHydratedValue
    (tli-hydrate-name (& row.name))
    (tli-hydrate-name (& row.module-name))
    (tli-hydrate-name (& row.link-symbol))
    (tli-hydrate-type-id (& row.ty))
    row.flags
    row.is-extern))

(define (tli-hydrate-const [row : (& row tli.TliValueDecl)]) : (&
    row
    tli.TliConst)
  (& row.const-value))

(defenum TliNativeMacro
  (Native i64 i64 u8)
  (Unavailable))

;; The resolver supplies the digest of the exact native image it has opened
;; and the index returned by its normal identity lookup in that image.
(define (tli-hydrate-native-macro
  [row : (& tli.TliMacroHandle)]
  [actual-entry : i64]
  [catalog-digest : (& (Array u8 32))]) : TliNativeMacro
  (if (and
    (!= 0 (bit-and row.flags 1))
    (= 0 (bit-and row.flags 2))
    (>= actual-entry 0)
    (= actual-entry row.tlci-entry-index)
    (codec.tli-digest-eq? (& row.tlci-catalog-sha256) catalog-digest))
    (Native (tli-hydrate-name (& row.identity)) actual-entry row.result-kind)
    Unavailable))

(define (tli-hydrate-str-lt? [a : (& str)] [b : (& str)]) : bool
  (let
    [na : i64 (string.string-length a)]
    [nb : i64 (string.string-length b)]
    [limit : i64
      (if (< na nb)
        na
        nb)]
    [i : i64 0]
    (while (< i limit)
      (let
        [ca : char (string.string-ref a i)]
        [cb : char (string.string-ref b i)]
        (when (!= ca cb) (return (< ca cb))))
      (+= i 1))
    (< na nb)))

;; Configuration fingerprint shared by sysroot validation and extraction:
;; canonicalize to the sorted deduplicated set of active (`value != 0`) cfg
;; names so shadowing, removed zero bindings, and insertion order do not
;; cause spurious mismatches.
(define (tli-hydrate-cfg-digest [cfgs : sym_i64_env.SymI64Env]) : (Array u8 32)
  (let
    [snapshot : cfg_core.CompilerCfgSnapshot
      (cfg_core.compiler-cfg-snapshot-from-env cfgs)]
    [seen-names : (__tl_dyn-array String) (__tl_make-array String snapshot.len)]
    [seen-count : i64 0]
    [active-names : (__tl_dyn-array String)
      (__tl_make-array String snapshot.len)]
    [active-values : (__tl_dyn-array i64) (__tl_make-array i64 snapshot.len)]
    [active-count : i64 0]
    (for [index (iterator.range 0 snapshot.len)]
      (let
        [name (& (array-ref snapshot.slots index))]
        [val : i64 (array-ref snapshot.values index)]
        (when
          (> (string.string-length name) 0)
          (let
            [dup? : bool false]
            (for [j (iterator.range 0 seen-count)]
              (when
                (string.eq (& (array-ref seen-names j)) name)
                (set! dup? true)))
            (unless
              dup?
              (set! (array-ref seen-names seen-count) (string.copy name))
              (+= seen-count 1)
              (when
                (!= val 0)
                (set! (array-ref active-names active-count) (string.copy name))
                (set! (array-ref active-values active-count) val)
                (+= active-count 1)))))))
    ;; Insertion-sort active cfg entries by name.
    (for [i (iterator.range 1 active-count)]
      (let
        [key-name : String (string.copy (& (array-ref active-names i)))]
        [key-val : i64 (array-ref active-values i)]
        [j : i64 (- i 1)]
        (while (and
          (>= j 0)
          (tli-hydrate-str-lt? (& key-name) (& (array-ref active-names j))))
          (set!
            (array-ref active-names (+ j 1))
            (string.copy (& (array-ref active-names j))))
          (set! (array-ref active-values (+ j 1)) (array-ref active-values j))
          (-= j 1))
        (set! (array-ref active-names (+ j 1)) key-name)
        (set! (array-ref active-values (+ j 1)) key-val)))
    (let
      [out : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
      (for [index (iterator.range 0 active-count)]
        (let
          [name (& (array-ref active-names index))]
          (le.push-u64! (&mut out) (string.string-length name))
          (buf.byte-buf-builder-append-string (&mut out) (string.copy name))
          (le.push-u64! (&mut out) (array-ref active-values index))))
      (let
        [owner : byte_buf.ByteBuf
          (byte_buf.from-array (buf.byte-buf-builder-finish-array (& out)))]
        (match (sha256.digest (byte_buf.as-bytes (& owner)))
          [(Sha256FinalizeOk digest) (sha256.digest-bytes (& digest))]
          [(Sha256FinalizeErr _) (make-array u8 32)])))))

;; Archive symbol mangling matching `compiler-backend-user-symbol-uncached`
;; without pulling backend state into the frontend/loader import graph.
(define (tli-hydrate-hex-digit [n : i64]) : String
  (cond
    [(= n 0) "0"]
    [(= n 1) "1"]
    [(= n 2) "2"]
    [(= n 3) "3"]
    [(= n 4) "4"]
    [(= n 5) "5"]
    [(= n 6) "6"]
    [(= n 7) "7"]
    [(= n 8) "8"]
    [(= n 9) "9"]
    [(= n 10) "a"]
    [(= n 11) "b"]
    [(= n 12) "c"]
    [(= n 13) "d"]
    [(= n 14) "e"]
    [else "f"]))

(define (tli-hydrate-hex-byte [n : i64]) : String
  (str_cat.str-cat
    (tli-hydrate-hex-digit (/ n 16))
    (tli-hydrate-hex-digit (% n 16))))

(define (tli-hydrate-symbol-safe-char? [c : char]) : bool
  (or
    (and (>= c 'A') (<= c 'Z'))
    (and (>= c 'a') (<= c 'z'))
    (and (>= c '0') (<= c '9'))
    (= c '_')))

(define (tli-hydrate-symbol-separator? [c : char]) : bool
  (or (= c '/') (= c '\\') (= c ':') (= c '.')))

(define (tli-hydrate-symbol-tl-ext-at? [name : (& name str)] [idx : i64]) : bool
  (let
    [n : i64 (string.string-length name)]
    [after : i64 (+ idx 3)]
    (and
      (<= after n)
      (= (string.string-ref name idx) '.')
      (= (string.string-ref name (+ idx 1)) 't')
      (= (string.string-ref name (+ idx 2)) 'l')
      (or
        (= after n)
        (tli-hydrate-symbol-separator? (string.string-ref name after))))))

(define (tli-hydrate-symbol-char [text : (& text str)] [idx : i64] [c : char]) : String
  (cond
    [(tli-hydrate-symbol-safe-char? c) (string.substring text idx 1)]
    [(= c '-') "_"]
    [(= c '?') "_question"]
    [(= c '!') "_bang"]
    [(= c '+') "_plus"]
    [(= c '*') "_star"]
    [(= c '/') "_slash"]
    [(= c '=') "_eq"]
    [(= c '<') "_lt"]
    [(= c '>') "_gt"]
    [(= c ':') "_colon"]
    [else (str_cat.str-cat "_u" (tli-hydrate-hex-byte (cast c : i64)))]))

(define (tli-hydrate-archive-user-symbol [name : (& name str)]) : String
  (if (string.eq name "main")
    "main"
    (let
      [i : i64 0]
      [n : i64 (string.string-length name)]
      [run-start : i64 0]
      [buf : (text_buf_borrowed.TextBufBorrowed name)
        (text_buf_borrowed.empty-like name)]
      [emitted : bool false]
      [pending-separator : bool false]
      (while (< i n)
        (if (tli-hydrate-symbol-tl-ext-at? name i)
          (begin
            (when
              (> i run-start)
              (set!
                buf
                (text_buf_borrowed.append-slice
                  buf
                  name
                  run-start
                  (- i run-start)))
              (set! emitted true))
            (+= i 3)
            (set! run-start i))
          (let
            [c : char (string.string-ref name i)]
            (if (tli-hydrate-symbol-separator? c)
              (begin
                (when
                  (> i run-start)
                  (set!
                    buf
                    (text_buf_borrowed.append-slice
                      buf
                      name
                      run-start
                      (- i run-start)))
                  (set! emitted true))
                (when emitted (set! pending-separator true))
                (+= i 1)
                (set! run-start i))
              (if (tli-hydrate-symbol-safe-char? c)
                (begin
                  (when
                    (and pending-separator (= i run-start))
                    (set! buf (text_buf_borrowed.append-owned buf "_"))
                    (set! pending-separator false))
                  (+= i 1))
                (begin
                  (when
                    (> i run-start)
                    (set!
                      buf
                      (text_buf_borrowed.append-slice
                        buf
                        name
                        run-start
                        (- i run-start)))
                    (set! emitted true))
                  (when
                    pending-separator
                    (set! buf (text_buf_borrowed.append-owned buf "_"))
                    (set! pending-separator false))
                  (set!
                    buf
                    (text_buf_borrowed.append-owned
                      buf
                      (tli-hydrate-symbol-char name i c)))
                  (set! emitted true)
                  (+= i 1)
                  (set! run-start i)))))))
      (when
        (> n run-start)
        (set!
          buf
          (text_buf_borrowed.append-slice buf name run-start (- n run-start))))
      (str_cat.str-cat "_tl_" (text_buf_borrowed.render buf)))))

(define (tli-hydrate-symbol-leaf [name : (& name str)]) : String
  (let
    [n : i64 (string.string-length name)]
    [slash : i64 (- n 1)]
    (while (and (>= slash 0) (not (= (string.string-ref name slash) '/')))
      (-= slash 1))
    (if (< slash 0)
      (string.copy name)
      (string.substring name (+ slash 1) (- n (+ slash 1))))))

(define (tli-hydrate-runtime-prelude-helper-symbol
  [module-name : (& str)]
  [leaf : (& str)]) : String
  (if (not (string.eq module-name "stdlib.runtime"))
    ""
    (cond
      [(string.eq leaf "int-to-string") "tl_int_to_string"]
      [(string.eq leaf "substring") "tl_substring"]
      [(string.eq leaf "str-view") "tl_str_view"]
      [(string.eq leaf "string-concat") "tl_string_concat"]
      [(string.eq leaf "string-concat3") "tl_string_concat3"]
      [(string.eq leaf "string-concat4") "tl_string_concat4"]
      [(string.eq leaf "string-concat5") "tl_string_concat5"]
      [(string.eq leaf "atomic-i64-load-ptr") "tl_atomic_i64_load_ptr"]
      [(string.eq leaf "atomic-i64-store-ptr!") "tl_atomic_i64_store_ptr"]
      [(string.eq leaf "atomic-i64-add-ptr!") "tl_atomic_i64_add_ptr"]
      [(string.eq leaf "atomic-i64-fetch-add-ptr!")
        "tl_atomic_i64_fetch_add_ptr"]
      [(string.eq leaf "atomic-i64-cas-ptr!") "tl_atomic_i64_cas_ptr"]
      [(string.eq leaf "atomic-i32-load-ptr") "tl_atomic_i32_load_ptr"]
      [(string.eq leaf "atomic-i32-store-ptr!") "tl_atomic_i32_store_ptr"]
      [(string.eq leaf "atomic-i32-add-ptr!") "tl_atomic_i32_add_ptr"]
      [(string.eq leaf "atomic-i32-fetch-add-ptr!")
        "tl_atomic_i32_fetch_add_ptr"]
      [(string.eq leaf "atomic-i32-cas-ptr!") "tl_atomic_i32_cas_ptr"]
      [else ""])))

(define (tli-hydrate-archive-qualified-symbol
  [source-path : (& str)]
  [module-name : (& str)]
  [link-symbol : (& str)]) : String
  (cond
    [(> (string.string-length source-path) 0)
      (let
        [qualified : String
          (str_cat.str-cat
            (string.copy source-path)
            "::"
            (string.copy link-symbol))]
        (tli-hydrate-archive-user-symbol (& qualified)))]
    [(> (string.string-length module-name) 0)
      (let
        [qualified : String
          (str_cat.str-cat
            (string.copy module-name)
            "/"
            (string.copy link-symbol))]
        (tli-hydrate-archive-user-symbol (& qualified)))]
    [else (tli-hydrate-archive-user-symbol link-symbol)]))

(define (tli-hydrate-archive-fn-symbol-with-mode
  [is-stdlib : bool]
  [source-path : (& str)]
  [row : (& tli.TliFnDecl)]) : String
  (cond
    [row.is-extern (string.copy (& row.link-symbol))]
    [(and
        (= row.meta-kind 1)
        (> (string.string-length (& row.export-symbol)) 0))
      (cabi.compiler-abi-c-export-body-symbol
        (string.copy (& row.export-symbol)))]
    [(not is-stdlib) (string.copy (& row.link-symbol))]
    [else
      (let
        [rt-sym : String
          (tli-hydrate-runtime-prelude-helper-symbol
            (& row.module-name)
            (& row.name))]
        (if (> (string.string-length (& rt-sym)) 0)
          rt-sym
          (tli-hydrate-archive-qualified-symbol
            source-path
            (& row.module-name)
            (& row.link-symbol))))]))

(define (tli-hydrate-archive-fn-symbol
  [source-path : (& str)]
  [row : (& tli.TliFnDecl)]) : String
  (tli-hydrate-archive-fn-symbol-with-mode true source-path row))

(define (tli-catalog-startup-archive-symbols [catalog : (& TliCatalog)]) : (__tl_dyn-array
    String)
  (let
    [count : i64 0]
    (when catalog.failed (return (__tl_make-array String 0)))
    (for [position (iterator.range 0 catalog.ready-count)]
      (+=
        count
        (array-length
          (array-ref catalog.records (array-ref catalog.startup-order position)).global-inits)))
    (let
      [symbols : (__tl_dyn-array String) (__tl_make-array String count)]
      [next : i64 0]
      (for [position (iterator.range 0 catalog.ready-count)]
        (let
          [module-index : i64 (array-ref catalog.startup-order position)]
          [init-count : i64
            (array-length (array-ref catalog.records module-index).global-inits)]
          (for [index (iterator.range 0 init-count)]
            (set!
              (array-ref symbols next)
              (tli-hydrate-archive-user-symbol
                (&
                  (array-ref
                    (array-ref catalog.records module-index).global-inits
                    index))))
            (+= next 1))))
      symbols)))

(define (tli-hydrate-archive-value-symbol-with-mode
  [is-stdlib : bool]
  [source-path : (& str)]
  [row : (& tli.TliValueDecl)]) : String
  (if (or row.is-extern (not is-stdlib))
    (string.copy (& row.link-symbol))
    (tli-hydrate-archive-qualified-symbol
      source-path
      (& row.module-name)
      (& row.link-symbol))))

(define (tli-hydrate-archive-value-symbol
  [source-path : (& str)]
  [row : (& tli.TliValueDecl)]) : String
  (tli-hydrate-archive-value-symbol-with-mode true source-path row))

;; Compact sidecar facts projected alongside body-less interface ASTs.
(defstruct TliHydratedGlobalWrite
  (symbol-id i64)
  (flags u8))

(defstruct TliHydratedFnSummaryRow
  (effect-flags i64)
  (arena-arg-store-mask i64)
  (arena-arg-store-extra (__tl_dyn-array i64))
  (global-writes (__tl_dyn-array TliHydratedGlobalWrite)))

(defstruct TliHydratedMacroEntry
  (identity-id i64)
  (flags i64)
  (result-kind u8)
  (tlci-entry-index i64)
  (tlci-catalog-sha256 (Array u8 32))
  ;; The interpreted fallback re-reads the defining source: only the module,
  ;; source digest and cfgs this interface was produced from select its body.
  (module-id i64)
  (source-sha256 (Array u8 32))
  (source-cfg-names (__tl_dyn-array String)))

(defstruct TliHydratedTypeLayout
  (is-struct bool)
  (size i64)
  (align i64)
  (field-names (__tl_dyn-array i64))
  (field-offsets (__tl_dyn-array i64)))

(import (vector.vector TliHydratedFnSummaryRow core) as fn_summary_vec)
(import (vector.vector TliHydratedMacroEntry core) as macro_vec)
(import (vector.vector TliHydratedTypeLayout core) as layout_vec)

(defstruct TliHydratedFacts
  (owner-arena i64)
  (emitted (__tl_dyn-array bool))
  (hydrated-module-count i64)
  (hydrated-modules tli_i64_map.Map)
  (fn-summary-slots tli_i64_map.Map)
  (fn-summaries fn_summary_vec.Vec)
  (macro-slots tli_i64_map.Map)
  (macros macro_vec.Vec)
  (type-layout-slots tli_i64_map.Map)
  (type-layouts layout_vec.Vec))

(define (tli-hydrated-facts-new [module-count : i64]) : TliHydratedFacts
  (TliHydratedFacts
    (arena.tl_arena_current)
    (__tl_make-array bool module-count)
    0
    (tli_i64_map.with-capacity 32)
    (tli_i64_map.with-capacity 256)
    (fn_summary_vec.new)
    (tli_i64_map.with-capacity 64)
    (macro_vec.new)
    (tli_i64_map.with-capacity 128)
    (layout_vec.new)))

(define (tli-hydrated-facts-module-hydrated?
  [facts : (& TliHydratedFacts)]
  [module-id : i64]) : bool
  (tli_i64_map.contains? (& facts.hydrated-modules) module-id))

(define (tli-hydrated-facts-fn-summary-slot
  [facts : (& TliHydratedFacts)]
  [symbol-id : i64]) : i64
  (tli_i64_map.get-value-or (& facts.fn-summary-slots) symbol-id -1))

(define (tli-hydrated-facts-fn-summary-at
  [facts : (& facts TliHydratedFacts)]
  [slot : i64]) : (& facts TliHydratedFnSummaryRow)
  (& (array-ref facts.fn-summaries.slots slot)))

(define (tli-hydrated-fn-summary-arena-arg-store?
  [row : (& TliHydratedFnSummaryRow)]
  [index : i64]) : bool
  (cond
    [(< index 0) false]
    [(< index 64) (!= 0 (bit-and row.arena-arg-store-mask (shl 1 index)))]
    [else
      (for [slot (iterator.range 0 (array-length row.arena-arg-store-extra))]
        (when
          (= (array-ref row.arena-arg-store-extra slot) index)
          (return true)))
      false]))

(define (tli-hydrated-facts-macro-slot
  [facts : (& TliHydratedFacts)]
  [identity-id : i64]) : i64
  (tli_i64_map.get-value-or (& facts.macro-slots) identity-id -1))

(define (tli-hydrated-facts-macro-at
  [facts : (& facts TliHydratedFacts)]
  [slot : i64]) : (& facts TliHydratedMacroEntry)
  (& (array-ref facts.macros.slots slot)))

(define (tli-hydrated-facts-macro-uses-expr-type?
  [facts : (& TliHydratedFacts)]
  [identity-id : i64]) : bool
  (let
    [slot : i64 (tli-hydrated-facts-macro-slot facts identity-id)]
    (if (< slot 0)
      false
      (!=
        0
        (bit-and
          (tli-hydrated-facts-macro-at facts slot).flags
          tli.tli-macro-uses-expr-type)))))

;; What the interpreted fallback needs to re-read a hydrated macro's body.
(defstruct TliHydratedMacroSource
  (module-id i64)
  (source-sha256 (Array u8 32))
  (source-cfg-names (__tl_dyn-array String)))

(define (tli-hydrated-facts-macro-source
  [facts : (& TliHydratedFacts)]
  [slot : i64]) : TliHydratedMacroSource
  (let
    [digest : (Array u8 32) (make-array u8 32)]
    (for [index (iterator.range 0 32)]
      (set!
        (array-ref digest index)
        (array-ref (tli-hydrated-facts-macro-at facts slot).source-sha256 index)))
    (TliHydratedMacroSource
      (tli-hydrated-facts-macro-at facts slot).module-id
      digest
      (tli-hydrate-string-array-copy
        (& (array-ref facts.macros.slots slot).source-cfg-names)))))

;; The fallback may read a body only from the exact source text the interface
;; was produced from.
(define (tli-hydrated-macro-source-matches?
  [source : (& TliHydratedMacroSource)]
  [text : (& str)]) : bool
  (match (sha256.digest (byte_buf.str-as-bytes text))
    [(Sha256FinalizeOk digest)
      (let
        [actual : (Array u8 32) (sha256.digest-bytes (& digest))]
        (codec.tli-digest-eq? (& actual) (& source.source-sha256)))]
    [_ false]))

(define (tli-hydrated-macro-validate
  [entry : (& TliHydratedMacroEntry)]
  [actual-entry : i64]
  [catalog-digest : (& (Array u8 32))]) : TliNativeMacro
  (if (and
    (!= 0 (bit-and entry.flags 1))
    (= 0 (bit-and entry.flags 2))
    (>= actual-entry 0)
    (= actual-entry entry.tlci-entry-index)
    (codec.tli-digest-eq? (& entry.tlci-catalog-sha256) catalog-digest))
    (Native entry.identity-id actual-entry entry.result-kind)
    Unavailable))

(define (tli-hydrated-facts-type-layout-slot
  [facts : (& TliHydratedFacts)]
  [nominal-id : i64]) : i64
  (tli_i64_map.get-value-or (& facts.type-layout-slots) nominal-id -1))

(define (tli-hydrated-facts-type-layout-at
  [facts : (& facts TliHydratedFacts)]
  [slot : i64]) : (& facts TliHydratedTypeLayout)
  (& (array-ref facts.type-layouts.slots slot)))

(define (tli-hydrate-decl-meta [comptime-only : bool] [markers : i64]) : ast.AstDeclMeta
  (if comptime-only
    (ast.AstDeclMeta (box (ast.AstDeclMetaValue.Comptime No markers)))
    (ast.ast-decl-meta-runtime-with-aggregate-markers markers)))

(define (tli-hydrate-wrap-unsafe [unsafe-decl : bool] [decl : ast.AstDecl]) : ast.AstDecl
  (if unsafe-decl
    (ast.AstDecl.Unsafe (box decl))
    decl))

(define (tli-hydrate-link-inputs
  [items : (& items (__tl_dyn-array tli.TliExternLinkInput))]) : ast.AstExternLinkInputList
  (let
    [count : i64 (array-length items)]
    [slots : (__tl_dyn-array ast.AstExternLinkInput)
      (__tl_make-array ast.AstExternLinkInput count)]
    (for [index (iterator.range 0 count)]
      (let
        [row (& (array-ref items index))]
        (set!
          (array-ref slots index)
          (match row.kind
            [0 (ast.AstExternLinkInput.Lib (string.copy (& row.name)))]
            [1 (ast.AstExternLinkInput.Search (string.copy (& row.name)))]
            [_ (ast.AstExternLinkInput.Arg (string.copy (& row.name)))]))))
    (ast.AstExternLinkInputList slots count)))

(define (tli-hydrate-const-expr
  [pools : ast.AstNodePoolContext]
  [value : (& tli.TliConst)]
  [ty : (& tli.TliType)]) : i64
  (let
    [node : ast.AstExpr
      (match value
        [(I64 n) (ast.AstExpr.Literal (ast.ast-lit-int n))]
        [(U64 n)
          (match ty
            [(Char) (ast.AstExpr.Literal (ast.AstLiteral.Char (cast n : char)))]
            [_ (ast.AstExpr.Literal (ast.ast-lit-int n))])]
        [(F64Bits bits)
          (ast.AstExpr.Literal
            (ast.AstLiteral.Float
              (cfloat.compiler-float-format-f64
                (math.f64-from-bits (cast bits : u64)))))]
        [(Bool b) (ast.AstExpr.Literal (ast.AstLiteral.Bool b))]
        [(String s)
          (ast.AstExpr.Literal (ast.ast-lit-generated-string (string.copy s)))]
        [(Bytes raw)
          (let
            [n : i64 (array-length raw)]
            [copy : (__tl_dyn-array u8) (__tl_make-array u8 n)]
            (for [i (iterator.range 0 n)]
              (set! (array-ref copy i) (array-ref raw i)))
            (ast.AstExpr.BinaryData
              (byte_buf.to-string (byte_buf.from-array copy))))]
        [_ (ast.AstExpr.Literal (ast.AstLiteral.Unit))])]
    (ast.ast-node-pool-context-expr-push pools node)))

(define (tli-hydrate-push-decl!
  [decls : (&mut ast.AstDeclList)]
  [paths : (&mut ast.AstDeclPathList)]
  [modules : (&mut ast.AstDeclModuleList)]
  [decl : ast.AstDecl]
  [source-path : (& str)]
  [owner-id : i64]
  [provenance-id : i64]) : unit
  (ast.ast-decl-list-push decls decl)
  (ast.ast-decl-path-list-push-with-owner-and-provenance-id
    paths
    (string.copy source-path)
    owner-id
    provenance-id)
  (ast.ast-decl-module-list-push-id modules owner-id))

(define (tli-hydrate-struct-cleanup [row : (& tli.TliCleanup)]) : ast.AstStructCleanup
  (match row
    [(Fn full-name)
      (let
        [leaf : String (tli-hydrate-symbol-leaf full-name)]
        (ast.AstStructCleanup.Fn
          (intern.intern-syntax-id-from-raw (tli-hydrate-name (& leaf)))))]
    [_ (ast.AstStructCleanup.No)]))

(define (tli-hydrate-enum-cleanup [row : (& tli.TliCleanup)]) : ast.AstEnumCleanup
  (match row
    [(Fn full-name)
      (let
        [leaf : String (tli-hydrate-symbol-leaf full-name)]
        (ast.AstEnumCleanup.Fn
          (intern.intern-syntax-id-from-raw (tli-hydrate-name (& leaf)))))]
    [_ (ast.AstEnumCleanup.No)]))

(define (tli-hydrate-field-cleanup [row : (& tli.TliCleanup)]) : ast.AstFieldCleanup
  (match row
    [(No) (ast.AstFieldCleanup.No)]
    [(Owned) (ast.AstFieldCleanup.Owned)]
    [(Fn full-name)
      (ast.AstFieldCleanup.Fn
        (intern.intern-syntax-id-from-raw (tli-hydrate-name full-name)))]))

(define (tli-hydrate-payload-cleanup [row : (& tli.TliCleanup)]) : ast.AstVariantPayloadCleanup
  (match row
    [(No) (ast.AstVariantPayloadCleanup.No)]
    [(Owned) (ast.AstVariantPayloadCleanup.Owned)]
    [(Fn full-name)
      (ast.AstVariantPayloadCleanup.Fn
        (intern.intern-syntax-id-from-raw (tli-hydrate-name full-name)))]))

(define (tli-hydrate-field-aligns
  [fields : (& fields (__tl_dyn-array tli.TliField))]) : ast.AstFieldAligns
  (let
    [last : i64 -1]
    (for [i (iterator.range 0 (array-length fields))]
      (when (> (array-ref fields i).explicit-align 0) (set! last i)))
    (let
      [len : i64 (+ last 1)]
      [out : (__tl_dyn-array i64) (__tl_make-array i64 len)]
      (for [i (iterator.range 0 len)]
        (set! (array-ref out i) (array-ref fields i).explicit-align))
      (ast.AstFieldAligns out))))

(define (tli-hydrate-variant-def [v : (& tli.TliVariant)]) : ast.AstVariantDef
  (let
    [pcount : i64 (array-length v.payloads)]
    [ptypes : ast.AstTypeList (ast.ast-type-list-with-capacity pcount)]
    [pcleanups : (__tl_dyn-array ast.AstVariantPayloadCleanup)
      (__tl_make-array ast.AstVariantPayloadCleanup pcount)]
    (for [p (iterator.range 0 pcount)]
      (ast.ast-type-list-push
        (&mut ptypes)
        (tli-hydrate-type-id (& (array-ref v.payloads p).ty)))
      (set!
        (array-ref pcleanups p)
        (tli-hydrate-payload-cleanup (& (array-ref v.payloads p).cleanup))))
    (ast.AstVariantDef.Def
      (tli-hydrate-name (& v.name))
      ptypes
      (ast.AstVariantPayloadCleanupList pcleanups pcount))))

(define (tli-hydrate-project-type!
  [facts : (&mut TliHydratedFacts)]
  [decls : (&mut ast.AstDeclList)]
  [paths : (&mut ast.AstDeclPathList)]
  [modules : (&mut ast.AstDeclModuleList)]
  [row : (& tli.TliTypeDecl)]
  [source-path : (& str)]
  [mod-id : i64]
  [prov-id : i64]) : unit
  (let
    [name-id : i64 (tli-hydrate-name (& row.name))]
    [nominal-id : i64
      (if (= (string.string-length (& row.module-name)) 0)
        name-id
        (ast.ast-nominal-name-id-key
          (csym.compiler-symbol-module-key-id-by-id mod-id name-id)))]
    [markers : i64 (bit-and row.flags 3)]
    [comptime-only : bool
      (and
        (!= (bit-and row.flags 4) 0)
        (not (string.eq (& row.module-name) "stdlib.comptime")))]
    [unsafe-decl : bool (!= (bit-and row.flags 8) 0)]
    [meta : ast.AstDeclMeta (tli-hydrate-decl-meta comptime-only markers)]
    [lifetimes : ast.AstLifetimeList (tli-hydrate-lifetimes (& row.lifetimes))]
    (match (& row.body)
      [(Struct fields)
        (let
          [fcount : i64 (array-length fields)]
          [fslots : (__tl_dyn-array ast.AstFieldDef)
            (__tl_make-array ast.AstFieldDef fcount)]
          [fnames : (__tl_dyn-array i64) (__tl_make-array i64 fcount)]
          [foffsets : (__tl_dyn-array i64) (__tl_make-array i64 fcount)]
          (for [i (iterator.range 0 fcount)]
            (let
              [fname-id : i64 (tli-hydrate-name (& (array-ref fields i).name))]
              [fty-id : i64 (tli-hydrate-type-id (& (array-ref fields i).ty))]
              (set! (array-ref fnames i) fname-id)
              (set! (array-ref foffsets i) (array-ref fields i).byte-offset)
              (set!
                (array-ref fslots i)
                (ast.AstFieldDef.Def
                  (intern.intern-syntax-id-from-raw fname-id)
                  (ast.ty-node-get fty-id)
                  (tli-hydrate-field-cleanup (& (array-ref fields i).cleanup))))))
          (let
            [repr : ast.AstStructRepr
              (if (= row.repr-kind 1)
                (ast.AstStructRepr.C
                  row.repr-align
                  (tli-hydrate-field-aligns fields))
                (ast.AstStructRepr.Default))]
            [cleanup : ast.AstStructCleanup
              (tli-hydrate-struct-cleanup (& row.cleanup))]
            [flist : ast.AstFieldDefList (ast.AstFieldDefList fslots fcount)]
            [decl : ast.AstDecl
              (tli-hydrate-wrap-unsafe
                unsafe-decl
                (if (= lifetimes.len 0)
                  (ast.AstDecl.DefStruct meta name-id repr cleanup flist)
                  (ast.AstDecl.DefStructLifetimes
                    meta
                    name-id
                    lifetimes
                    repr
                    cleanup
                    flist)))]
            (tli-hydrate-push-decl!
              decls
              paths
              modules
              decl
              source-path
              mod-id
              prov-id)
            (when
              (or (> row.layout-size 0) (> row.layout-align 0))
              (in-arena
                (unsafe
                  (arena.Arena facts.owner-arena))
                (let
                  [fnames-copy : (__tl_dyn-array i64)
                    (__tl_make-array i64 fcount)]
                  [foffsets-copy : (__tl_dyn-array i64)
                    (__tl_make-array i64 fcount)]
                  [slot : i64 (layout_vec.len (& facts.type-layouts))]
                  (for [i (iterator.range 0 fcount)]
                    (set! (array-ref fnames-copy i) (array-ref fnames i))
                    (set! (array-ref foffsets-copy i) (array-ref foffsets i)))
                  (layout_vec.push-ref!
                    (&mut facts.type-layouts)
                    (TliHydratedTypeLayout
                      true
                      row.layout-size
                      row.layout-align
                      fnames-copy
                      foffsets-copy))
                  (tli_i64_map.insert-ref!
                    (&mut facts.type-layout-slots)
                    nominal-id
                    slot))))))]
      [(Enum variants)
        (let
          [vcount : i64 (array-length variants)]
          [vslots : (__tl_dyn-array ast.AstVariantDef)
            (__tl_make-array ast.AstVariantDef vcount)]
          (for [i (iterator.range 0 vcount)]
            (set!
              (array-ref vslots i)
              (tli-hydrate-variant-def (& (array-ref variants i)))))
          (let
            [cleanup : ast.AstEnumCleanup
              (tli-hydrate-enum-cleanup (& row.cleanup))]
            [vlist : ast.AstVariantDefList
              (ast.AstVariantDefList vslots vcount)]
            [decl : ast.AstDecl
              (tli-hydrate-wrap-unsafe
                unsafe-decl
                (if (= lifetimes.len 0)
                  (ast.AstDecl.DefEnum meta name-id cleanup vlist)
                  (ast.AstDecl.DefEnumLifetimes
                    meta
                    name-id
                    lifetimes
                    cleanup
                    vlist)))]
            (tli-hydrate-push-decl!
              decls
              paths
              modules
              decl
              source-path
              mod-id
              prov-id)))])))

(define (tli-hydrate-imported-spmd-specializations
  [items : (& tlci.TlciSpmdSpecializations)]) : ast.AstImportedSpmdSpecializationList
  (let
    [out : ast.AstImportedSpmdSpecializationList
      (ast.ast-imported-spmd-specialization-list-new)]
    [count : i64 (tlci.tlci-spmd-specializations-len items)]
    (for [index (iterator.range 0 count)]
      (let
        [item : tlci.TlciSpmdSpecialization
          (tlci.tlci-spmd-specializations-ref items index)]
        (ast.ast-imported-spmd-specialization-list-push
          (&mut out)
          (ast.AstImportedSpmdSpecialization
            (intern.intern-id-from-renderable
              (intern.intern-generated-canonical-name item.abi))
            (intern.intern-id-from-renderable
              (intern.intern-generated-canonical-name item.backend))
            item.lanes
            (intern.intern-id-from-renderable
              (intern.intern-generated-canonical-name item.args))
            (intern.intern-id-from-renderable
              (intern.intern-generated-canonical-name item.result))
            item.index-param
            (intern.intern-id-from-renderable
              (intern.intern-generated-canonical-name item.symbol))))))
    out))

(define (tli-hydrate-imported-spmd-callables-for
  [canonical-name : (& str)]
  [items : (& tlci.TlciSpmdCallables)]) : ast.AstImportedSpmdCallableList
  (let
    [out : ast.AstImportedSpmdCallableList
      (ast.ast-imported-spmd-callable-list-new)]
    [count : i64 (tlci.tlci-spmd-callables-len items)]
    (for [index (iterator.range 0 count)]
      (let
        [item : tlci.TlciSpmdCallable
          (tlci.tlci-spmd-callables-ref items index)]
        (when
          (string.eq (& item.name) canonical-name)
          (ast.ast-imported-spmd-callable-list-push
            (&mut out)
            (ast.AstImportedSpmdCallable
              (intern.intern-id-from-renderable
                (intern.intern-generated-canonical-name item.signature))
              (tli-hydrate-imported-spmd-specializations
                (& item.specializations)))))))
    out))

(define (tli-hydrate-imported-spmd-metadata
  [is-stdlib : bool]
  [package-name : (& str)]
  [package-version : (& str)]
  [spmd-callables : (& tlci.TlciSpmdCallables)]
  [row : (& tli.TliFnDecl)]) : ast.AstImportedSpmdMetadata
  (if (or is-stdlib row.is-extern (= (string.string-length package-name) 0))
    (ast.AstImportedSpmdMetadata.No)
    (let
      [canonical : String
        (if (> (string.string-length (& row.module-name)) 0)
          (str_cat.str-cat
            (string.copy (& row.module-name))
            "/"
            (string.copy (& row.name)))
          (str_cat.str-cat
            (string.copy package-name)
            "/"
            (string.copy (& row.name))))]
      [callables : ast.AstImportedSpmdCallableList
        (if (= row.meta-kind 2)
          (tli-hydrate-imported-spmd-callables-for (& canonical) spmd-callables)
          (ast.ast-imported-spmd-callable-list-new))]
      (ast.AstImportedSpmdMetadata.Package
        (string.copy package-name)
        (string.copy package-version)
        (intern.intern-id-from-renderable
          (intern.intern-generated-canonical-name canonical))
        (box callables)))))

(define (tli-hydrate-project-fn-with-context!
  [facts : (&mut TliHydratedFacts)]
  [decls : (&mut ast.AstDeclList)]
  [paths : (&mut ast.AstDeclPathList)]
  [modules : (&mut ast.AstDeclModuleList)]
  [row : (& tli.TliFnDecl)]
  [is-stdlib : bool]
  [package-name : (& str)]
  [package-version : (& str)]
  [spmd-callables : (& tlci.TlciSpmdCallables)]
  [source-path : (& str)]
  [mod-id : i64]
  [prov-id : i64]) : unit
  (let
    [fn-info : TliHydratedFunction (tli-hydrate-function row)]
    [eflags : i64 row.summary.effect-flags]
    [unsafe-decl : bool (!= (bit-and eflags 1) 0)]
    [comptime-only : bool (!= (bit-and eflags 2) 0)]
    [must-use : bool (!= (bit-and eflags 128) 0)]
    [markers : i64
      (if must-use
        1
        0)]
    [meta : ast.AstDeclMeta (tli-hydrate-decl-meta comptime-only markers)]
    [archive-sym : String
      (tli-hydrate-archive-fn-symbol-with-mode is-stdlib source-path row)]
    [archive-sym-id : i64 (tli-hydrate-name (& archive-sym))]
    [ext-flags : i64
      (if row.is-extern
        row.extern-flags
        (ast.ast-extern-metadata-flags
          false
          (string.eq (& archive-sym) (& row.name))))]
    [spmd-meta : ast.AstImportedSpmdMetadata
      (tli-hydrate-imported-spmd-metadata
        is-stdlib
        package-name
        package-version
        spmd-callables
        row)]
    [ext-meta : ast.AstExternMetadata
      (ast.AstExternMetadata.Metadata
        fn-info.abi
        (intern.intern-id-from-renderable archive-sym-id)
        (tli-hydrate-link-inputs (& row.extern-link-inputs))
        ext-flags
        spmd-meta)]
    [decl : ast.AstDecl
      (tli-hydrate-wrap-unsafe
        unsafe-decl
        (ast.AstDecl.Extern
          meta
          fn-info.name
          (ast.AstExternKind.Function)
          (box ext-meta)
          (ast.ty-node-get fn-info.signature-id)))]
    (tli-hydrate-push-decl! decls paths modules decl source-path mod-id prov-id)
    (in-arena
      (unsafe
        (arena.Arena facts.owner-arena))
      (let
        [canonical-id : i64
          (csym.compiler-symbol-module-key-id-by-id mod-id fn-info.name)]
        [slot : i64 (fn_summary_vec.len (& facts.fn-summaries))]
        (fn_summary_vec.push-ref!
          (&mut facts.fn-summaries)
          (tli-hydrate-summary-row (& row.summary)))
        (tli_i64_map.insert-ref!
          (&mut facts.fn-summary-slots)
          canonical-id
          slot)))))

(define (tli-hydrate-summary-row [summary : (& tli.TliFnSummary)]) : TliHydratedFnSummaryRow
  (let
    [extra-len : i64 (array-length summary.arena-arg-store-extra)]
    [extra-copy : (__tl_dyn-array i64) (__tl_make-array i64 extra-len)]
    [w-len : i64 (array-length summary.global-writes)]
    [w-copy : (__tl_dyn-array TliHydratedGlobalWrite)
      (__tl_make-array TliHydratedGlobalWrite w-len)]
    (for [i (iterator.range 0 extra-len)]
      (set!
        (array-ref extra-copy i)
        (array-ref summary.arena-arg-store-extra i)))
    (for [i (iterator.range 0 w-len)]
      (set!
        (array-ref w-copy i)
        (TliHydratedGlobalWrite
          (tli-hydrate-name (& (array-ref summary.global-writes i).symbol))
          (array-ref summary.global-writes i).flags)))
    (TliHydratedFnSummaryRow
      summary.effect-flags
      summary.arena-arg-store-mask
      extra-copy
      w-copy)))

(define (tli-hydrate-project-dispatch!
  [facts : (&mut TliHydratedFacts)]
  [decls : (&mut ast.AstDeclList)]
  [paths : (&mut ast.AstDeclPathList)]
  [modules : (&mut ast.AstDeclModuleList)]
  [row : (& tli.TliDispatchDecl)]
  [is-stdlib : bool]
  [package-name : (& str)]
  [package-version : (& str)]
  [source-path : (& str)]
  [mod-id : i64]
  [prov-id : i64]) : unit
  (let
    [name-id : i64 (tli-hydrate-name (& row.name))]
    [unsafe-decl : bool (!= (bit-and row.flags 1) 0)]
    [meta : ast.AstDeclMeta (tli-hydrate-decl-meta false 0)]
    [archive-sym : String
      (if is-stdlib
        (tli-hydrate-archive-qualified-symbol
          source-path
          (& row.module-name)
          (& row.link-symbol))
        (string.copy (& row.link-symbol)))]
    [archive-sym-id : i64 (tli-hydrate-name (& archive-sym))]
    [ext-flags : i64
      (ast.ast-extern-metadata-flags
        false
        (string.eq (& archive-sym) (& row.name)))]
    [spmd-meta : ast.AstImportedSpmdMetadata
      (if (or is-stdlib (= (string.string-length package-name) 0))
        (ast.AstImportedSpmdMetadata.No)
        (let
          [canonical : String
            (if (> (string.string-length (& row.module-name)) 0)
              (str_cat.str-cat
                (string.copy (& row.module-name))
                "/"
                (string.copy (& row.name)))
              (str_cat.str-cat
                (string.copy package-name)
                "/"
                (string.copy (& row.name))))]
          (ast.AstImportedSpmdMetadata.Package
            (string.copy package-name)
            (string.copy package-version)
            (intern.intern-id-from-renderable
              (intern.intern-generated-canonical-name canonical))
            (box (ast.ast-imported-spmd-callable-list-new)))))]
    [ext-meta : ast.AstExternMetadata
      (ast.AstExternMetadata.Metadata
        (ast.AstExternAbi.TypeLisp)
        (intern.intern-id-from-renderable archive-sym-id)
        (ast.ast-extern-link-input-list-new)
        ext-flags
        spmd-meta)]
    [sig : ast.AstType (tli-hydrate-type (& row.signature))]
    [decl : ast.AstDecl
      (tli-hydrate-wrap-unsafe
        unsafe-decl
        (ast.AstDecl.Extern
          meta
          name-id
          (ast.AstExternKind.Function)
          (box ext-meta)
          sig))]
    (tli-hydrate-push-decl! decls paths modules decl source-path mod-id prov-id)
    (in-arena
      (unsafe
        (arena.Arena facts.owner-arena))
      (let
        [canonical-id : i64
          (csym.compiler-symbol-module-key-id-by-id mod-id name-id)]
        [slot : i64 (fn_summary_vec.len (& facts.fn-summaries))]
        (fn_summary_vec.push-ref!
          (&mut facts.fn-summaries)
          (tli-hydrate-summary-row (& row.summary)))
        (tli_i64_map.insert-ref!
          (&mut facts.fn-summary-slots)
          canonical-id
          slot)))))

(define (tli-hydrate-project-fn!
  [facts : (&mut TliHydratedFacts)]
  [decls : (&mut ast.AstDeclList)]
  [paths : (&mut ast.AstDeclPathList)]
  [modules : (&mut ast.AstDeclModuleList)]
  [row : (& tli.TliFnDecl)]
  [source-path : (& str)]
  [mod-id : i64]
  [prov-id : i64]) : unit
  (let
    [empty-spmd : tlci.TlciSpmdCallables (tlci.tlci-spmd-callables-empty)]
    (tli-hydrate-project-fn-with-context!
      facts
      decls
      paths
      modules
      row
      true
      ""
      ""
      (& empty-spmd)
      source-path
      mod-id
      prov-id)))

(define (tli-hydrate-project-value-with-mode!
  [pools : ast.AstNodePoolContext]
  [decls : (&mut ast.AstDeclList)]
  [paths : (&mut ast.AstDeclPathList)]
  [modules : (&mut ast.AstDeclModuleList)]
  [row : (& tli.TliValueDecl)]
  [is-stdlib : bool]
  [source-path : (& str)]
  [mod-id : i64]
  [prov-id : i64]) : unit
  (let
    [val-info : TliHydratedValue (tli-hydrate-value row)]
    [comptime-only : bool (!= (bit-and row.flags 1) 0)]
    [unsafe-decl : bool (!= (bit-and row.flags 2) 0)]
    [has-const : bool
      (match (& row.const-value)
        [(None) false]
        [_ true])]
    [meta : ast.AstDeclMeta (tli-hydrate-decl-meta comptime-only 0)]
    [ty : ast.AstType (ast.ty-node-get val-info.type-id)]
    (if (and comptime-only has-const (not row.is-extern))
      (let
        [expr-id : i64
          (tli-hydrate-const-expr pools (& row.const-value) (& row.ty))]
        [decl : ast.AstDecl
          (tli-hydrate-wrap-unsafe
            unsafe-decl
            (ast.AstDecl.Def meta val-info.name (Some ty) expr-id))]
        (tli-hydrate-push-decl!
          decls
          paths
          modules
          decl
          source-path
          mod-id
          prov-id))
      (let
        [archive-sym : String
          (tli-hydrate-archive-value-symbol-with-mode is-stdlib source-path row)]
        [archive-sym-id : i64 (tli-hydrate-name (& archive-sym))]
        [abi : ast.AstExternAbi
          (if row.is-extern
            (ast.AstExternAbi.C)
            (ast.AstExternAbi.TypeLisp))]
        [ext-meta : ast.AstExternMetadata
          (ast.AstExternMetadata.Metadata
            abi
            (intern.intern-id-from-renderable archive-sym-id)
            (tli-hydrate-link-inputs (& row.extern-link-inputs))
            (ast.ast-extern-metadata-flags
              false
              (string.eq (& archive-sym) (& row.name)))
            (ast.AstImportedSpmdMetadata.No))]
        [decl : ast.AstDecl
          (tli-hydrate-wrap-unsafe
            unsafe-decl
            (ast.AstDecl.Extern
              meta
              val-info.name
              (ast.AstExternKind.Value)
              (box ext-meta)
              ty))]
        (tli-hydrate-push-decl!
          decls
          paths
          modules
          decl
          source-path
          mod-id
          prov-id)))))

(define (tli-hydrate-project-value!
  [pools : ast.AstNodePoolContext]
  [decls : (&mut ast.AstDeclList)]
  [paths : (&mut ast.AstDeclPathList)]
  [modules : (&mut ast.AstDeclModuleList)]
  [row : (& tli.TliValueDecl)]
  [source-path : (& str)]
  [mod-id : i64]
  [prov-id : i64]) : unit
  (tli-hydrate-project-value-with-mode!
    pools
    decls
    paths
    modules
    row
    true
    source-path
    mod-id
    prov-id))

(define (tli-hydrate-macro-param [p : (& tli.TliMacroParam)]) : ast.AstMacroParam
  (let
    [kcount : i64 (array-length p.type-kinds)]
    [kslots : (__tl_dyn-array i64) (__tl_make-array i64 kcount)]
    (for [k (iterator.range 0 kcount)]
      (set!
        (array-ref kslots k)
        (tli-hydrate-name
          (& (tli.tli-macro-type-kind-name (array-ref p.type-kinds k))))))
    (ast.AstMacroParam.Param
      (tli-hydrate-name (& p.name))
      (tli-hydrate-type (& p.ty))
      p.is-by-ref
      (ast.AstMacroTypeKindList kslots kcount))))

(define (tli-hydrate-project-macro!
  [facts : (&mut TliHydratedFacts)]
  [dummy-body-id : i64]
  [decls : (&mut ast.AstDeclList)]
  [paths : (&mut ast.AstDeclPathList)]
  [modules : (&mut ast.AstDeclModuleList)]
  [row : (& tli.TliMacroHandle)]
  [source-sha256 : (& (Array u8 32))]
  [source-cfg-names : (& (__tl_dyn-array String))]
  [source-path : (& str)]
  [mod-id : i64]
  [prov-id : i64]) : unit
  (let
    [pcount : i64 (array-length row.params)]
    [pslots : (__tl_dyn-array ast.AstMacroParam)
      (__tl_make-array ast.AstMacroParam pcount)]
    (for [i (iterator.range 0 pcount)]
      (set!
        (array-ref pslots i)
        (tli-hydrate-macro-param (& (array-ref row.params i)))))
    (let
      [name-id : i64 (tli-hydrate-name (& row.name))]
      [ret-ty : ast.AstType
        (cond
          [(= row.result-kind (cast 2 : u8))
            (ast.AstType.Var (tli-hydrate-name "Module"))]
          [(= row.result-kind (cast 1 : u8))
            (ast.AstType.Var (tli-hydrate-name "Decls"))]
          [else (ast.AstType.Expr)])]
      [decl : ast.AstDecl
        (ast.AstDecl.DefMacro
          (ast.ast-decl-meta-runtime-with-aggregate-markers 0)
          name-id
          (ast.AstMacroParamList pslots pcount)
          ret-ty
          dummy-body-id)]
      [identity-id : i64 (tli-hydrate-name (& row.identity))]
      [slot : i64 (macro_vec.len (& facts.macros))]
      (tli-hydrate-push-decl!
        decls
        paths
        modules
        decl
        source-path
        mod-id
        prov-id)
      (in-arena
        (unsafe
          (arena.Arena facts.owner-arena))
        (macro_vec.push-ref!
          (&mut facts.macros)
          (TliHydratedMacroEntry
            identity-id
            row.flags
            row.result-kind
            row.tlci-entry-index
            row.tlci-catalog-sha256
            mod-id
            (deref source-sha256)
            (tli-hydrate-string-array-copy source-cfg-names)))
        (tli_i64_map.insert-ref! (&mut facts.macro-slots) identity-id slot)))))

(define (tli-hydrate-default-module-alias [module-name : (& str)]) : String
  (let
    [n : i64 (string.string-length module-name)]
    [dot : i64 (- n 1)]
    (while (and (>= dot 0) (not (= (string.string-ref module-name dot) '.')))
      (-= dot 1))
    (if (< dot 0)
      (string.copy module-name)
      (string.substring module-name (+ dot 1) (- n (+ dot 1))))))

(define (tli-hydrate-project-import!
  [decls : (&mut ast.AstDeclList)]
  [paths : (&mut ast.AstDeclPathList)]
  [modules : (&mut ast.AstDeclModuleList)]
  [imp : (& tli.TliImport)]
  [source-path : (& str)]
  [mod-id : i64]
  [prov-id : i64]) : unit
  (when
    (and (>= imp.kind 0) (<= imp.kind 2))
    (let
      [target-id : i64 (tli-hydrate-name (& imp.module-name))]
      [kind : ast.AstImportKind
        (cond
          [(= imp.kind 1) (ast.AstImportKind.ModuleAll)]
          [(= imp.kind 2)
            (ast.AstImportKind.ModuleItem (tli-hydrate-name (& imp.item)))]
          [else (ast.AstImportKind.Module)])]
      [alias : ast.AstMaybeImportAlias
        (cond
          [(> (string.string-length (& imp.alias)) 0)
            (Some (tli-hydrate-name (& imp.alias)))]
          [(= imp.kind 1) (Some (tli-hydrate-name ""))]
          [(= imp.kind 2) (Some (tli-hydrate-name (& imp.item)))]
          [else
            (let
              [def-alias : String
                (tli-hydrate-default-module-alias (& imp.module-name))]
              (if (> (string.string-length (& def-alias)) 0)
                (Some (tli-hydrate-name (& def-alias)))
                No))])]
      [decl : ast.AstDecl
        (ast.AstDecl.Import
          (ast.ast-decl-meta-runtime-with-aggregate-markers 0)
          (ast.AstImportSpec.Spec
            kind
            (string.copy (& imp.module-name))
            (Some target-id)
            alias
            (box (ast.AstSourceSpan 0 0 0 0))))]
      (tli-hydrate-push-decl!
        decls
        paths
        modules
        decl
        source-path
        mod-id
        prov-id))))

(define (tli-hydrate-string-starts-with? [text : (& str)] [prefix : (& str)]) : bool
  (let
    [tlen : i64 (string.string-length text)]
    [plen : i64 (string.string-length prefix)]
    (if (< tlen plen)
      false
      (begin
        (for [i (iterator.range 0 plen)]
          (when
            (!= (string.string-ref text i) (string.string-ref prefix i))
            (return false)))
        true))))

(define (tli-hydrate-physical-path
  [is-stdlib : bool]
  [package-name : (& str)]
  [package-root : (& str)]
  [source-path : (& str)]) : String
  (let
    [root-len : i64 (string.string-length package-root)]
    [pkg-len : i64 (string.string-length package-name)]
    [src-len : i64 (string.string-length source-path)]
    (if (or is-stdlib (= root-len 0) (= pkg-len 0))
      (string.copy source-path)
      (if (and
        (> src-len (+ pkg-len 1))
        (tli-hydrate-string-starts-with? source-path package-name)
        (= (string.string-ref source-path pkg-len) '/'))
        (let
          [rel : String
            (string.substring
              source-path
              (+ pkg-len 1)
              (- src-len (+ pkg-len 1)))]
          [last : char (string.string-ref package-root (- root-len 1))]
          (if (or (= last '/') (= last '\\'))
            (str_cat.str-cat (string.copy package-root) rel)
            (str_cat.str-cat (string.copy package-root) "/" rel)))
        (string.copy source-path)))))

(define (tli-hydrate-project-record-with-context!
  [facts : (&mut TliHydratedFacts)]
  [pools : ast.AstNodePoolContext]
  [dummy-body-id : i64]
  [decls : (&mut ast.AstDeclList)]
  [paths : (&mut ast.AstDeclPathList)]
  [modules : (&mut ast.AstDeclModuleList)]
  [record : (& tli.TliModuleRecord)]
  [slot-index : i64]
  [is-stdlib : bool]
  [package-name : (& str)]
  [package-version : (& str)]
  [package-root : (& str)]
  [spmd-callables : (& tlci.TlciSpmdCallables)]
  [source-cfg-names : (& (__tl_dyn-array String))]) : unit
  (let
    [mod-id : i64 (tli-hydrate-name (& record.name))]
    [source-path : String (string.copy (& record.source-path))]
    [physical-path : String
      (tli-hydrate-physical-path
        is-stdlib
        package-name
        package-root
        (& source-path))]
    [prov-id : i64 (tli-hydrate-name (& physical-path))]
    (in-arena
      (unsafe
        (arena.Arena facts.owner-arena))
      (tli_i64_map.insert-ref! (&mut facts.hydrated-modules) mod-id slot-index))
    (tli-hydrate-push-decl!
      decls
      paths
      modules
      (ast.ast-decl-module-id mod-id)
      (& physical-path)
      mod-id
      prov-id)
    (for [i (iterator.range 0 (array-length record.imports))]
      (tli-hydrate-project-import!
        decls
        paths
        modules
        (& (array-ref record.imports i))
        (& physical-path)
        mod-id
        prov-id))
    (for [i (iterator.range 0 (array-length record.types))]
      (tli-hydrate-project-type!
        facts
        decls
        paths
        modules
        (& (array-ref record.types i))
        (& physical-path)
        mod-id
        prov-id))
    (for [i (iterator.range 0 (array-length record.functions))]
      (tli-hydrate-project-fn-with-context!
        facts
        decls
        paths
        modules
        (& (array-ref record.functions i))
        is-stdlib
        package-name
        package-version
        spmd-callables
        (& physical-path)
        mod-id
        prov-id))
    (for [i (iterator.range 0 (array-length record.dispatches))]
      (tli-hydrate-project-dispatch!
        facts
        decls
        paths
        modules
        (& (array-ref record.dispatches i))
        is-stdlib
        package-name
        package-version
        (& physical-path)
        mod-id
        prov-id))
    (for [i (iterator.range 0 (array-length record.values))]
      (tli-hydrate-project-value-with-mode!
        pools
        decls
        paths
        modules
        (& (array-ref record.values i))
        is-stdlib
        (& physical-path)
        mod-id
        prov-id))
    (for [i (iterator.range 0 (array-length record.macros))]
      (tli-hydrate-project-macro!
        facts
        dummy-body-id
        decls
        paths
        modules
        (& (array-ref record.macros i))
        (& record.source-sha256)
        source-cfg-names
        (& physical-path)
        mod-id
        prov-id))))

(define (tli-hydrate-project-record!
  [facts : (&mut TliHydratedFacts)]
  [pools : ast.AstNodePoolContext]
  [dummy-body-id : i64]
  [decls : (&mut ast.AstDeclList)]
  [paths : (&mut ast.AstDeclPathList)]
  [modules : (&mut ast.AstDeclModuleList)]
  [record : (& tli.TliModuleRecord)]
  [slot-index : i64]) : unit
  (let
    [empty-spmd : tlci.TlciSpmdCallables (tlci.tlci-spmd-callables-empty)]
    (tli-hydrate-project-record-with-context!
      facts
      pools
      dummy-body-id
      decls
      paths
      modules
      record
      slot-index
      true
      ""
      ""
      ""
      (& empty-spmd)
      (& (__tl_make-array String 0)))))

(defenum TliProjectClosureResult
  (Ok
    ast.AstDeclList
    ast.AstDeclPathList
    ast.AstDeclModuleList
    sym_i64_env.SymI64Env)
  (Err tli.TliDecodeFailure))

;; Hydrate `module-name` and its transitive closure from `catalog`, projecting
;; only newly-ready modules not yet emitted into `decls`/`paths`/`modules`.
(define (tli-hydrate-project-closure!
  [catalog : (&mut TliCatalog)]
  [facts : (&mut TliHydratedFacts)]
  [module-name : (& str)]
  [seen : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [tli-arena : i64]) : TliProjectClosureResult
  (let
    [hydrated : TliHydrateResult
      (in-arena
        (unsafe
          (arena.Arena tli-arena))
        (tli-catalog-hydrate! catalog module-name))]
    (match hydrated
      [(Err failure) (Err failure)]
      [(Ok _)
        (let
          [decls : ast.AstDeclList (ast.ast-decl-list-new)]
          [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
          [modules : ast.AstDeclModuleList (ast.ast-decl-module-list-new)]
          [out-seen : sym_i64_env.SymI64Env seen]
          [dummy-body-id : i64 -1]
          (for [pos (iterator.range 0 catalog.ready-count)]
            (let
              [idx : i64 (array-ref catalog.startup-order pos)]
              (when
                (not (array-ref facts.emitted idx))
                (set! (array-ref facts.emitted idx) true)
                (+= facts.hydrated-module-count 1)
                (let
                  [mod-id : i64
                    (tli-hydrate-name (& (array-ref catalog.records idx).name))]
                  [path-id : i64
                    (tli-hydrate-name
                      (& (array-ref catalog.records idx).source-path))]
                  (when
                    (and
                      (< dummy-body-id 0)
                      (>
                        (array-length (array-ref catalog.records idx).macros)
                        0))
                    (set!
                      dummy-body-id
                      (ast.ast-node-pool-context-expr-push
                        pools
                        (ast.AstExpr.Literal (ast.AstLiteral.Unit)))))
                  (tli-hydrate-project-record!
                    facts
                    pools
                    dummy-body-id
                    (&mut decls)
                    (&mut paths)
                    (&mut modules)
                    (& (array-ref catalog.records idx))
                    idx)
                  (set!
                    out-seen
                    (sym_i64_env.sym-i64-bind-id out-seen path-id 1))
                  (set!
                    out-seen
                    (sym_i64_env.sym-i64-bind-id out-seen mod-id path-id))))))
          (Ok decls paths modules out-seen))])))

(defenum TliOptionalDigest
  (Some (Array u8 32))
  (None))

(defenum TliMultiAttachResult
  (Ok i64)
  (Err String))

(defstruct TliMultiBundle
  (arena i64)
  (is-stdlib bool)
  (package-name String)
  (package-version String)
  (package-root String)
  (archive-path String)
  (spmd-callables tlci.TlciSpmdCallables)
  (directory codec.TliDirectory)
  (cfg-digest (Array u8 32))
  (cfg-names (__tl_dyn-array String))
  (records (__tl_dyn-array tli.TliModuleRecord))
  (owned-bytes i64)
  (hydrated-any bool)
  (base-gid i64))

(import (vector.vector TliMultiBundle core) as tli_bundle_vec)

(defstruct TliMultiCatalog
  (root-arena i64)
  (bundles tli_bundle_vec.Vec)
  (has-stdlib-bundle bool)
  (stdlib-bundle-index i64)
  (module-to-gid tli_str_map.Map)
  (gid-bundle tli_i64_vec.Vec)
  (gid-local tli_i64_vec.Vec)
  (states tli_i64_vec.Vec)
  (startup-order tli_i64_vec.Vec)
  (projected-cursor i64)
  (pending-source-stdlib tli_svec.Vec)
  (failed bool))

(define (tli-hydrate-digest-zero? [digest : (& (Array u8 32))]) : bool
  (for [i (iterator.range 0 32)]
    (when (!= (array-ref (deref digest) i) (cast 0 : u8)) (return false)))
  true)

(define (tli-multi-catalog-new [root-arena : i64]) : TliMultiCatalog
  (in-arena
    (unsafe
      (arena.Arena root-arena))
    (TliMultiCatalog
      root-arena
      (tli_bundle_vec.new)
      false
      -1
      (tli_str_map.with-capacity 256)
      (tli_i64_vec.new)
      (tli_i64_vec.new)
      (tli_i64_vec.new)
      (tli_i64_vec.new)
      0
      (tli_svec.new)
      false)))

;; The active cfg names a bundle was opened under, owned by the catalog arena.
(define (tli-hydrate-cfg-names [cfgs : sym_i64_env.SymI64Env]) : (__tl_dyn-array
    String)
  (let
    [snapshot : cfg_core.CompilerCfgSnapshot
      (cfg_core.compiler-cfg-snapshot-from-env cfgs)]
    [active : i64 0]
    (for [index (iterator.range 0 snapshot.len)]
      (when (!= (array-ref snapshot.values index) 0) (+= active 1)))
    (let
      [out : (__tl_dyn-array String) (__tl_make-array String active)]
      [slot : i64 0]
      (for [index (iterator.range 0 snapshot.len)]
        (when
          (!= (array-ref snapshot.values index) 0)
          (set!
            (array-ref out slot)
            (string.copy (& (array-ref snapshot.slots index))))
          (+= slot 1)))
      out)))

(define (tli-hydrate-string-array-copy [items : (& (__tl_dyn-array String))]) : (__tl_dyn-array
    String)
  (let
    [n : i64 (array-length (deref items))]
    [out : (__tl_dyn-array String) (__tl_make-array String n)]
    (for [index (iterator.range 0 n)]
      (set!
        (array-ref out index)
        (string.copy (& (array-ref (deref items) index)))))
    out))

(define (tli-multi-catalog-attach-bundle!
  [multi : (&mut TliMultiCatalog)]
  [bundle-arena : i64]
  [is-stdlib : bool]
  [package-name : String]
  [package-version : String]
  [package-root : String]
  [archive-path : String]
  [spmd-callables : tlci.TlciSpmdCallables]
  [directory : codec.TliDirectory]
  [cfg-digest : (& (Array u8 32))]
  [cfgs : sym_i64_env.SymI64Env]) : TliMultiAttachResult
  (when
    (and is-stdlib multi.has-stdlib-bundle)
    (return (TliMultiAttachResult.Err "duplicate stdlib TLI bundle")))
  (let
    [count : i64 (array-length directory.entries)]
    (for [local (iterator.range 0 count)]
      (let
        [mod-name (& (array-ref directory.entries local).name)]
        (when
          (tli_str_map.contains? (& multi.module-to-gid) (string.copy mod-name))
          (return
            (TliMultiAttachResult.Err
              (str_cat.str-cat
                "duplicate TLI module name: "
                (string.copy mod-name)))))))
    (let
      [owned : i64
        (+
          directory.owned-bytes
          80
          (* count (+ 32 (comptime (size-of (type tli.TliModuleRecord))))))]
      (when
        (> owned codec.tli-max-owned-bytes)
        (return
          (TliMultiAttachResult.Err "TLI catalog exceeds the owned-byte limit")))
      (let
        [records : (__tl_dyn-array tli.TliModuleRecord)
          (in-arena
            (unsafe
              (arena.Arena bundle-arena))
            (__tl_make-array tli.TliModuleRecord count))]
        [base-gid : i64 (tli_i64_vec.len (& multi.gid-bundle))]
        [bundle-index : i64 (tli_bundle_vec.len (& multi.bundles))]
        (in-arena
          (unsafe
            (arena.Arena multi.root-arena))
          (for [local (iterator.range 0 count)]
            (let
              [mod-name : String
                (string.copy (& (array-ref directory.entries local).name))]
              (tli_str_map.insert-ref!
                (&mut multi.module-to-gid)
                mod-name
                (+ base-gid local))
              (tli_i64_vec.push-ref! (&mut multi.gid-bundle) bundle-index)
              (tli_i64_vec.push-ref! (&mut multi.gid-local) local)
              (tli_i64_vec.push-ref! (&mut multi.states) 0)))
          (tli_bundle_vec.push-ref!
            (&mut multi.bundles)
            (TliMultiBundle
              bundle-arena
              is-stdlib
              (string.copy (& package-name))
              (string.copy (& package-version))
              (string.copy (& package-root))
              (string.copy (& archive-path))
              spmd-callables
              directory
              (deref cfg-digest)
              (tli-hydrate-cfg-names cfgs)
              records
              owned
              false
              base-gid))
          (when
            is-stdlib
            (set! multi.has-stdlib-bundle true)
            (set! multi.stdlib-bundle-index bundle-index)))
        (TliMultiAttachResult.Ok bundle-index)))))

(define (tli-multi-catalog-find-module
  [multi : (& TliMultiCatalog)]
  [module-name : (& str)]) : i64
  (tli_str_map.get-value-or
    (& multi.module-to-gid)
    (string.copy module-name)
    -1))

(define (tli-multi-catalog-has-module?
  [multi : (& TliMultiCatalog)]
  [module-name : (& str)]) : bool
  (>= (tli-multi-catalog-find-module multi module-name) 0))

(define (tli-multi-catalog-module-name-at
  [multi : (& TliMultiCatalog)]
  [gid : i64]) : String
  (if (or (< gid 0) (>= gid (tli_i64_vec.len (& multi.gid-bundle))))
    ""
    (let
      [b-idx : i64 (array-ref multi.gid-bundle.slots gid)]
      [local : i64 (array-ref multi.gid-local.slots gid)]
      (string.copy
        (&
          (array-ref
            (array-ref multi.bundles.slots b-idx).directory.entries
            local).name)))))

(define (tli-multi-catalog-module-sha256
  [multi : (& TliMultiCatalog)]
  [module-name : (& str)]) : TliOptionalDigest
  (let
    [gid : i64 (tli-multi-catalog-find-module multi module-name)]
    (if (< gid 0)
      (TliOptionalDigest.None)
      (let
        [b-idx : i64 (array-ref multi.gid-bundle.slots gid)]
        [local : i64 (array-ref multi.gid-local.slots gid)]
        (TliOptionalDigest.Some
          (array-ref
            (array-ref multi.bundles.slots b-idx).directory.entries
            local).module-sha256)))))

(define (tli-multi-catalog-find-package-bundle
  [multi : (& TliMultiCatalog)]
  [package-root : (& str)]) : i64
  (let
    [count : i64 (tli_bundle_vec.len (& multi.bundles))]
    (for [i (iterator.range 0 count)]
      (when
        (and
          (not (array-ref multi.bundles.slots i).is-stdlib)
          (string.eq
            (& (array-ref multi.bundles.slots i).package-root)
            package-root))
        (return i)))
    -1))

(define (tli-multi-catalog-has-package-root?
  [multi : (& TliMultiCatalog)]
  [package-root : (& str)]) : bool
  (>= (tli-multi-catalog-find-package-bundle multi package-root) 0))

(define (tli-multi-catalog-find-package-gids
  [multi : (& TliMultiCatalog)]
  [package-root : (& str)]
  [owned-path : (& str)]
  [candidate-module : (& str)]) : (__tl_dyn-array i64)
  (let
    [b-idx : i64 (tli-multi-catalog-find-package-bundle multi package-root)]
    (when (< b-idx 0) (return (__tl_make-array i64 0)))
    (let
      [count : i64
        (array-length (array-ref multi.bundles.slots b-idx).directory.entries)]
      [base-gid : i64 (array-ref multi.bundles.slots b-idx).base-gid]
      [cand-local : i64
        (if (> (string.string-length candidate-module) 0)
          (tli-catalog-find
            (& (array-ref multi.bundles.slots b-idx).directory)
            candidate-module)
          -1)]
      [cand-matches : bool false]
      [matches : tli_i64_vec.Vec (tli_i64_vec.new)]
      (when
        (>= cand-local 0)
        (let
          [sp : String
            (codec.tli-peek-record-source-path-at
              (& (array-ref multi.bundles.slots b-idx).directory)
              cand-local)]
          (when
            (or
              (= (string.string-length owned-path) 0)
              (string.eq (& sp) owned-path))
            (set! cand-matches true)
            (tli_i64_vec.push-ref! (&mut matches) (+ base-gid cand-local)))))
      (when
        (> (string.string-length owned-path) 0)
        (for [local (iterator.range 0 count)]
          (when
            (or (not cand-matches) (!= local cand-local))
            (let
              [sp : String
                (codec.tli-peek-record-source-path-at
                  (& (array-ref multi.bundles.slots b-idx).directory)
                  local)]
              (when
                (string.eq (& sp) owned-path)
                (tli_i64_vec.push-ref! (&mut matches) (+ base-gid local)))))))
      (let
        [n : i64 (tli_i64_vec.len (& matches))]
        [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
        (for [i (iterator.range 0 n)]
          (set! (array-ref out i) (array-ref matches.slots i)))
        out))))

(define (tli-multi-push-pending-source-stdlib!
  [multi : (&mut TliMultiCatalog)]
  [module-name : (& str)]) : unit
  (let
    [count : i64 (tli_svec.len (& multi.pending-source-stdlib))]
    (for [i (iterator.range 0 count)]
      (when
        (string.eq
          (& (array-ref multi.pending-source-stdlib.slots i))
          module-name)
        (return unit)))
    (in-arena
      (unsafe
        (arena.Arena multi.root-arena))
      (tli_svec.push-ref!
        (&mut multi.pending-source-stdlib)
        (string.copy module-name)))))

(define (tli-multi-catalog-hydrate-gid!
  [multi : (&mut TliMultiCatalog)]
  [root-gid : i64]) : TliHydrateResult
  (when
    multi.failed
    (return
      (Err
        (tli.TliDecodeFailure
          (tli.TliDecodeError.UnknownTag)
          0
          "TLI catalog has a previously rejected record"))))
  (when
    (or (< root-gid 0) (>= root-gid (tli_i64_vec.len (& multi.states))))
    (return
      (Err
        (tli.TliDecodeFailure
          (tli.TliDecodeError.UnknownTag)
          0
          "TLI module is missing from the directory"))))
  (when (>= (array-ref multi.states.slots root-gid) 2) (return (Ok root-gid)))
  (let
    [stack : tli_i64_vec.Vec (tli_i64_vec.new)]
    [next-edge : tli_i64_vec.Vec (tli_i64_vec.new)]
    [depth : i64 1]
    (tli_i64_vec.push-ref! (&mut stack) root-gid)
    (tli_i64_vec.push-ref! (&mut next-edge) 0)
    (while (> depth 0)
      (let
        [top : i64 (- depth 1)]
        [gid : i64 (array-ref stack.slots top)]
        [b-idx : i64 (array-ref multi.gid-bundle.slots gid)]
        [local : i64 (array-ref multi.gid-local.slots gid)]
        [offset : i64
          (array-ref
            (array-ref multi.bundles.slots b-idx).directory.entries
            local).record-offset]
        (when
          (= (array-ref multi.states.slots gid) 0)
          (let
            [b-arena : i64 (array-ref multi.bundles.slots b-idx).arena]
            [decoded : codec.TliBudgetedModuleResult
              (in-arena
                (unsafe
                  (arena.Arena b-arena))
                (codec.tli-decode-record-at
                  (& (array-ref multi.bundles.slots b-idx).directory)
                  local
                  (array-ref multi.bundles.slots b-idx).owned-bytes))]
            (match decoded
              [(Err failure)
                (set! multi.failed true)
                (return (Err failure))]
              [(Ok record used)
                (unless
                  (codec.tli-digest-eq?
                    (& record.cfg-fingerprint-sha256)
                    (& (array-ref multi.bundles.slots b-idx).cfg-digest))
                  (return
                    (tli-catalog-fail!
                      (&mut multi.failed)
                      (tli.TliDecodeError.CfgFingerprintMismatch)
                      (+ offset 40)
                      "TLI configuration fingerprint mismatch")))
                (set!
                  (array-ref
                    (array-ref multi.bundles.slots b-idx).records
                    local)
                  record)
                (set! (array-ref multi.bundles.slots b-idx).owned-bytes used)
                (set! (array-ref multi.states.slots gid) 1)
                (set! (array-ref next-edge.slots top) 0)])))
        (let
          [next : i64 (array-ref next-edge.slots top)]
          [imp-count : i64
            (array-length
              (array-ref (array-ref multi.bundles.slots b-idx).records local).imports)]
          (if (= next imp-count)
            (begin
              (set! (array-ref multi.states.slots gid) 2)
              (set! (array-ref multi.bundles.slots b-idx).hydrated-any true)
              (in-arena
                (unsafe
                  (arena.Arena multi.root-arena))
                (tli_i64_vec.push-ref! (&mut multi.startup-order) gid))
              (-= depth 1))
            (let
              [src-is-stdlib : bool
                (array-ref multi.bundles.slots b-idx).is-stdlib]
              [imp-name : String
                (string.copy
                  (&
                    (array-ref
                      (array-ref
                        (array-ref multi.bundles.slots b-idx).records
                        local).imports
                      next).module-name))]
              [imp-sha : (Array u8 32)
                (array-ref
                  (array-ref
                    (array-ref multi.bundles.slots b-idx).records
                    local).imports
                  next).interface-sha256]
              [dep-gid : i64 (tli-multi-catalog-find-module multi (& imp-name))]
              (if (< dep-gid 0)
                (if (and
                  (not src-is-stdlib)
                  (not multi.has-stdlib-bundle)
                  (tli-hydrate-string-starts-with? (& imp-name) "stdlib."))
                  (begin
                    (tli-multi-push-pending-source-stdlib! multi (& imp-name))
                    (+= (array-ref next-edge.slots top) 1))
                  (return
                    (tli-catalog-fail!
                      (&mut multi.failed)
                      (tli.TliDecodeError.UnknownTag)
                      offset
                      "TLI import is missing from the directory")))
                (let
                  [dst-b-idx : i64 (array-ref multi.gid-bundle.slots dep-gid)]
                  [dst-local : i64 (array-ref multi.gid-local.slots dep-gid)]
                  [dst-is-stdlib : bool
                    (array-ref multi.bundles.slots dst-b-idx).is-stdlib]
                  [digest-ok : bool
                    (or
                      (codec.tli-digest-eq?
                        (& imp-sha)
                        (&
                          (array-ref
                            (array-ref multi.bundles.slots dst-b-idx).directory.entries
                            dst-local).module-sha256))
                      (and
                        (not src-is-stdlib)
                        dst-is-stdlib
                        (tli-hydrate-digest-zero? (& imp-sha))))]
                  (unless
                    digest-ok
                    (return
                      (tli-catalog-fail!
                        (&mut multi.failed)
                        (tli.TliDecodeError.DigestMismatch)
                        offset
                        "TLI import SHA-256 mismatch")))
                  (+= (array-ref next-edge.slots top) 1)
                  (match (array-ref multi.states.slots dep-gid)
                    [0
                      (if (< depth (tli_i64_vec.len (& stack)))
                        (begin
                          (set! (array-ref stack.slots depth) dep-gid)
                          (set! (array-ref next-edge.slots depth) 0))
                        (begin
                          (tli_i64_vec.push-ref! (&mut stack) dep-gid)
                          (tli_i64_vec.push-ref! (&mut next-edge) 0)))
                      (+= depth 1)]
                    [1
                      (return
                        (tli-catalog-fail!
                          (&mut multi.failed)
                          (tli.TliDecodeError.UnknownTag)
                          offset
                          "TLI import cycle"))]
                    [_ unit]))))))))
    (Ok root-gid)))

(define (tli-multi-project-gids-closure!
  [multi : (&mut TliMultiCatalog)]
  [facts : (&mut TliHydratedFacts)]
  [gids : (& (__tl_dyn-array i64))]
  [seen : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : TliProjectClosureResult
  (for [i (iterator.range 0 (array-length (deref gids)))]
    (match (tli-multi-catalog-hydrate-gid! multi (array-ref (deref gids) i))
      [(Err failure) (return (Err failure))]
      [(Ok _) unit]))
  (let
    [decls : ast.AstDeclList (ast.ast-decl-list-new)]
    [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
    [modules : ast.AstDeclModuleList (ast.ast-decl-module-list-new)]
    [out-seen : sym_i64_env.SymI64Env seen]
    [dummy-body-id : i64 -1]
    [ready-count : i64 (tli_i64_vec.len (& multi.startup-order))]
    (for [pos (iterator.range multi.projected-cursor ready-count)]
      (let
        [gid : i64 (array-ref multi.startup-order.slots pos)]
        (when
          (= (array-ref multi.states.slots gid) 2)
          (set! (array-ref multi.states.slots gid) 3)
          (+= facts.hydrated-module-count 1)
          (let
            [b-idx : i64 (array-ref multi.gid-bundle.slots gid)]
            [local : i64 (array-ref multi.gid-local.slots gid)]
            (set! (array-ref multi.bundles.slots b-idx).hydrated-any true)
            (let
              [mod-id : i64
                (tli-hydrate-name
                  (&
                    (array-ref
                      (array-ref multi.bundles.slots b-idx).records
                      local).name))]
              [phys-path : String
                (tli-hydrate-physical-path
                  (array-ref multi.bundles.slots b-idx).is-stdlib
                  (& (array-ref multi.bundles.slots b-idx).package-name)
                  (& (array-ref multi.bundles.slots b-idx).package-root)
                  (&
                    (array-ref
                      (array-ref multi.bundles.slots b-idx).records
                      local).source-path))]
              [prov-id : i64 (tli-hydrate-name (& phys-path))]
              (when
                (and
                  (< dummy-body-id 0)
                  (>
                    (array-length
                      (array-ref
                        (array-ref multi.bundles.slots b-idx).records
                        local).macros)
                    0))
                (set!
                  dummy-body-id
                  (ast.ast-node-pool-context-expr-push
                    pools
                    (ast.AstExpr.Literal (ast.AstLiteral.Unit)))))
              (tli-hydrate-project-record-with-context!
                facts
                pools
                dummy-body-id
                (&mut decls)
                (&mut paths)
                (&mut modules)
                (&
                  (array-ref
                    (array-ref multi.bundles.slots b-idx).records
                    local))
                gid
                (array-ref multi.bundles.slots b-idx).is-stdlib
                (& (array-ref multi.bundles.slots b-idx).package-name)
                (& (array-ref multi.bundles.slots b-idx).package-version)
                (& (array-ref multi.bundles.slots b-idx).package-root)
                (& (array-ref multi.bundles.slots b-idx).spmd-callables)
                (& (array-ref multi.bundles.slots b-idx).cfg-names))
              (set! out-seen (sym_i64_env.sym-i64-bind-id out-seen prov-id 1))
              (set!
                out-seen
                (sym_i64_env.sym-i64-bind-id out-seen mod-id prov-id)))))))
    (set! multi.projected-cursor ready-count)
    (Ok decls paths modules out-seen)))

(define (tli-multi-project-module-closure!
  [multi : (&mut TliMultiCatalog)]
  [facts : (&mut TliHydratedFacts)]
  [module-name : (& str)]
  [seen : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : TliProjectClosureResult
  (let
    [gid : i64 (tli-multi-catalog-find-module multi module-name)]
    (if (< gid 0)
      (Err
        (tli.TliDecodeFailure
          (tli.TliDecodeError.UnknownTag)
          0
          "TLI module is missing from the directory"))
      (let
        [gids : (__tl_dyn-array i64) (__tl_make-array gid)]
        (tli-multi-project-gids-closure! multi facts (& gids) seen pools)))))

(define (tli-multi-startup-archive-symbols [multi : (& TliMultiCatalog)]) : (__tl_dyn-array
    String)
  (when multi.failed (return (__tl_make-array String 0)))
  (let
    [ready-count : i64 (tli_i64_vec.len (& multi.startup-order))]
    [count : i64 0]
    (for [pos (iterator.range 0 ready-count)]
      (let
        [gid : i64 (array-ref multi.startup-order.slots pos)]
        [b-idx : i64 (array-ref multi.gid-bundle.slots gid)]
        [local : i64 (array-ref multi.gid-local.slots gid)]
        (+=
          count
          (array-length
            (array-ref (array-ref multi.bundles.slots b-idx).records local).global-inits))))
    (let
      [symbols : (__tl_dyn-array String) (__tl_make-array String count)]
      [next : i64 0]
      (for [pos (iterator.range 0 ready-count)]
        (let
          [gid : i64 (array-ref multi.startup-order.slots pos)]
          [b-idx : i64 (array-ref multi.gid-bundle.slots gid)]
          [local : i64 (array-ref multi.gid-local.slots gid)]
          [init-count : i64
            (array-length
              (array-ref (array-ref multi.bundles.slots b-idx).records local).global-inits)]
          (for [index (iterator.range 0 init-count)]
            (set!
              (array-ref symbols next)
              (tli-hydrate-archive-user-symbol
                (&
                  (array-ref
                    (array-ref
                      (array-ref multi.bundles.slots b-idx).records
                      local).global-inits
                    index))))
            (+= next 1))))
      symbols)))

;; Reverse topological order of hydrated package archives, followed by the
;; stdlib archive last (single-pass linker order: consumer -> dep -> stdlib).
(define (tli-multi-hydrated-archive-paths [multi : (& TliMultiCatalog)]) : (__tl_dyn-array
    String)
  (when multi.failed (return (__tl_make-array String 0)))
  (let
    [bcount : i64 (tli_bundle_vec.len (& multi.bundles))]
    [out : tli_svec.Vec (tli_svec.new)]
    [idx : i64 (- bcount 1)]
    (while (>= idx 0)
      (when
        (and
          (not (array-ref multi.bundles.slots idx).is-stdlib)
          (array-ref multi.bundles.slots idx).hydrated-any
          (>
            (string.string-length
              (& (array-ref multi.bundles.slots idx).archive-path))
            0))
        (tli_svec.push-ref!
          (&mut out)
          (string.copy (& (array-ref multi.bundles.slots idx).archive-path))))
      (-= idx 1))
    (when
      (and multi.has-stdlib-bundle (>= multi.stdlib-bundle-index 0))
      (when
        (and
          (array-ref multi.bundles.slots multi.stdlib-bundle-index).hydrated-any
          (>
            (string.string-length
              (&
                (array-ref multi.bundles.slots multi.stdlib-bundle-index).archive-path))
            0))
        (tli_svec.push-ref!
          (&mut out)
          (string.copy
            (&
              (array-ref multi.bundles.slots multi.stdlib-bundle-index).archive-path)))))
    (let
      [n : i64 (tli_svec.len (& out))]
      [arr : (__tl_dyn-array String) (__tl_make-array String n)]
      (for [i (iterator.range 0 n)]
        (set! (array-ref arr i) (string.copy (& (array-ref out.slots i)))))
      arr)))

(define (tli-multi-take-pending-source-stdlib! [multi : (&mut TliMultiCatalog)]) : (__tl_dyn-array
    String)
  (let
    [n : i64 (tli_svec.len (& multi.pending-source-stdlib))]
    [out : (__tl_dyn-array String) (__tl_make-array String n)]
    (for [i (iterator.range 0 n)]
      (set!
        (array-ref out i)
        (string.copy (& (array-ref multi.pending-source-stdlib.slots i)))))
    (set! multi.pending-source-stdlib.len 0)
    out))

(define (tli-multi-bundle-count [multi : (& TliMultiCatalog)]) : i64
  (tli_bundle_vec.len (& multi.bundles)))

;; The sysroot stdlib bundle supplied a hydrated module, so its archive (which
;; references the native runtime) joins the link.
(define (tli-multi-stdlib-hydrated? [multi : (& TliMultiCatalog)]) : bool
  (and
    multi.has-stdlib-bundle
    (>= multi.stdlib-bundle-index 0)
    (array-ref multi.bundles.slots multi.stdlib-bundle-index).hydrated-any))

(define (tli-multi-hydrated-package-bundle-count [multi : (& TliMultiCatalog)]) : i64
  (let
    [bcount : i64 (tli_bundle_vec.len (& multi.bundles))]
    [count : i64 0]
    (for [i (iterator.range 0 bcount)]
      (when
        (and
          (not (array-ref multi.bundles.slots i).is-stdlib)
          (array-ref multi.bundles.slots i).hydrated-any)
        (+= count 1)))
    count))

(define (tli-multi-catalog-arenas [multi : (& TliMultiCatalog)]) : (__tl_dyn-array
    i64)
  (let
    [bcount : i64 (tli_bundle_vec.len (& multi.bundles))]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 (+ bcount 1))]
    (set! (array-ref out 0) multi.root-arena)
    (for [i (iterator.range 0 bcount)]
      (set! (array-ref out (+ i 1)) (array-ref multi.bundles.slots i).arena))
    out))

(define (tli-multi-catalog-release! [multi : (& TliMultiCatalog)]) : unit
  (let
    [root-arena : i64 multi.root-arena]
    [bcount : i64 (tli_bundle_vec.len (& multi.bundles))]
    [bundle-arenas : (__tl_dyn-array i64) (__tl_make-array i64 bcount)]
    (for [i (iterator.range 0 bcount)]
      (set! (array-ref bundle-arenas i) (array-ref multi.bundles.slots i).arena))
    (for [i (iterator.range 0 bcount)]
      (let
        [ba : i64 (array-ref bundle-arenas i)]
        (when
          (and (> ba 0) (!= ba root-arena))
          (unsafe
            ;; lint-allow: raw-arena-op -- releases job-owned bundle arena deterministically.
            (arena.tl_arena_destroy ba)))))
    (when
      (> root-arena 0)
      (unsafe
        ;; lint-allow: raw-arena-op -- releases job-owned multi-catalog root arena deterministically.
        (arena.tl_arena_destroy root-arena)))))