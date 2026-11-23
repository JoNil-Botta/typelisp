;; Standalone interface hydration. Callers open and use the catalog within a
;; dedicated with-arena extent. Only projected semantic ids can escape it.
(import compiler_tli_types as tli)
(import compiler_tli_codec as codec)
(import compiler_ast_types as ast)
(import compiler_intern as intern)
(import stdlib.iterator)
(import stdlib.sort)
(import stdlib.string)

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

(define (tli-catalog-open
  [bytes : (& bytes (__tl_dyn-array u8))]
  [build : (& build str)]
  [target : (& target str)]
  [cfg-digest : (& (Array u8 32))]) : TliCatalogResult
  (match (tli-catalog-open-directory bytes build target)
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