;; .tli v2 is a standalone wire format. Callers own the arena in which they
;; open a directory and decode its records.
(import compiler_tli_types as tli)
(import compiler_incremental_binary as binary)
(import compiler_abort as abort)
(import stdlib.byte_buf_core as buf)
(import stdlib.byte_le as le)
(import stdlib.byte_reader as cursor)
(import stdlib.crypto_sha256 as sha256)
(import stdlib.iterator)
(import stdlib.sort)
(import stdlib.string)
(import stdlib.vector)
(import (stdlib.vector.vector String) as strings)
(import (stdlib.sort.vec String) as string_sort)

(define tli-max-file-bytes : i64
  67108864)
(define tli-max-owned-bytes : i64
  268435456)
(define tli-max-string-bytes : i64
  1048576)
(define tli-max-work : i64
  268435456)
(define tli-max-count : i64
  1048576)

;; Hash only proven ranges, without making temporary copies of whole sections.
(define (tli-hash-range!
  [state : (&mut state sha256.Sha256State)]
  [bytes : (& bytes (__tl_dyn-array u8))]
  [start : i64]
  [length : i64]) : unit
  (when
    (cursor.range-present? (array-length bytes) start length)
    (match (unsafe
      (sha256.update-from-pointer!
        state
        (ptr-offset (ptr-cast (__tl_array-data (deref bytes)) : (Ptr u8)) start)
        length))
      [(Sha256UpdateOk) unit]
      [(Sha256UpdateErr _)
        (abort.compiler-abort
          "TLI hash range: rejected a checked SHA-256 update\n")])))

(define (tli-finish-hash! [state : (&mut state sha256.Sha256State)]) : (Array
    u8
    32)
  (match (sha256.finalize! state)
    [(Sha256FinalizeOk digest) (sha256.digest-bytes (& digest))]
    [(Sha256FinalizeErr _)
      (abort.compiler-abort "TLI hash digest: rejected a fresh SHA-256 state\n")]))

(define (tli-module-digest
  [bytes : (& bytes (__tl_dyn-array u8))]
  [start : i64]
  [length : i64]) : (Array u8 32)
  (let
    [state : sha256.Sha256State (sha256.new)]
    (tli-hash-range! (&mut state) bytes start length)
    (tli-finish-hash! (&mut state))))

(define (tli-content-digest [bytes : (& bytes (__tl_dyn-array u8))]) : (Array
    u8
    32)
  (let
    [state : sha256.Sha256State (sha256.new)]
    (tli-hash-range! (&mut state) bytes 0 tli.tli-content-digest-offset)
    (tli-hash-range!
      (&mut state)
      bytes
      tli.tli-index-digest-offset
      (- (array-length bytes) tli.tli-index-digest-offset))
    (tli-finish-hash! (&mut state))))

;; `index_sha256` covers the header outside both digests, the string pool and
;; the module directory: everything a lazy open reads before any record.
(define (tli-index-digest
  [bytes : (& bytes (__tl_dyn-array u8))]
  [index-end : i64]) : (Array u8 32)
  (let
    [state : sha256.Sha256State (sha256.new)]
    (tli-hash-range! (&mut state) bytes 0 tli.tli-content-digest-offset)
    (tli-hash-range!
      (&mut state)
      bytes
      tli.tli-header-size
      (- index-end tli.tli-header-size))
    (tli-finish-hash! (&mut state))))

(define (tli-digest-eq?
  [left : (& left (Array u8 32))]
  [right : (& right (Array u8 32))]) : bool
  (let
    [index : i64 0]
    (while (and (< index 32) (= (array-ref left index) (array-ref right index)))
      (+= index 1))
    (= index 32)))

(defstruct TliWriteContext
  (collecting? bool)
  (pool strings.Vec)
  (out buf.ByteBufBuilder))

(define (tli-write-u8! [ctx : (&mut ctx TliWriteContext)] [value : i64]) : unit
  (when
    (not ctx.collecting?)
    (binary.compiler-incremental-binary-push-u8! (&mut ctx.out) value)))

(define (tli-write-u32! [ctx : (&mut ctx TliWriteContext)] [value : i64]) : unit
  (when (not ctx.collecting?) (le.push-u32! (&mut ctx.out) value)))

(define (tli-write-u64! [ctx : (&mut ctx TliWriteContext)] [value : i64]) : unit
  (when (not ctx.collecting?) (le.push-u64! (&mut ctx.out) value)))

(define (tli-write-digest!
  [ctx : (&mut ctx TliWriteContext)]
  [digest : (& digest (Array u8 32))]) : unit
  (when
    (not ctx.collecting?)
    (for [index (iterator.range 0 32)]
      (buf.byte-buf-builder-push (&mut ctx.out) (array-ref digest index)))))

(define (tli-find-string [pool : (& pool strings.Vec)] [name : (& name str)]) : i64
  (let
    [low : i64 0]
    [high : i64 (strings.len pool)]
    [slots (strings.slots pool)]
    (while (< low high)
      (let
        [mid : i64 (+ low (/ (- high low) 2))]
        [candidate (& (array-ref slots mid))]
        (if (sort.string-less-borrowed? candidate name)
          (set! low (+ mid 1))
          (set! high mid))))
    low))

(define (tli-write-name!
  [ctx : (&mut ctx TliWriteContext)]
  [name : (& name str)]) : unit
  (if ctx.collecting?
    (strings.push-ref! (&mut ctx.pool) (string.copy name))
    (le.push-u32! (&mut ctx.out) (tli-find-string (& ctx.pool) name))))

(define (tli-write-names!
  [ctx : (&mut ctx TliWriteContext)]
  [names : (& names (__tl_dyn-array String))]) : unit
  (tli-write-u32! ctx (array-length names))
  (for [index (iterator.range 0 (array-length names))]
    (tli-write-name! ctx (& (array-ref names index)))))

;; Table keys use the same byte order as the pool. Keep only scalar sort keys
;; so canonicalization never clones a declaration or changes caller storage.
(defstruct TliOrderKey
  (name i64)
  (kind i64)
  (symbol i64)
  (index i64))

(import (stdlib.vector.vector TliOrderKey) as keys)
(import (stdlib.sort.vec TliOrderKey) as key_sort)

(define (tli-key-less? [a : TliOrderKey] [b : TliOrderKey]) : bool
  (cond
    [(not (= a.name b.name)) (< a.name b.name)]
    [(not (= a.kind b.kind)) (< a.kind b.kind)]
    [else (< a.symbol b.symbol)]))

(define (tli-order-key
  [ctx : (& ctx TliWriteContext)]
  [name : (& name str)]
  [kind : i64]
  [symbol : (& symbol str)]
  [index : i64]) : TliOrderKey
  (TliOrderKey
    (tli-find-string (& ctx.pool) name)
    kind
    (tli-find-string (& ctx.pool) symbol)
    index))

(define (tli-key-eq? [a : TliOrderKey] [b : TliOrderKey]) : bool
  (and (= a.name b.name) (= a.kind b.kind) (= a.symbol b.symbol)))

;; The wire keys can tie (for instance two import rows with the same module
;; and kind). Order ties by their actual encoded bytes, so shuffling such
;; rows is still deterministic. Only runs with tied keys need scratch bytes.
(define (tli-sort-tied-rows!
  [out : (&mut out buf.ByteBufBuilder)]
  [order : (& order (__tl_dyn-array TliOrderKey))]
  [starts : (& starts (__tl_dyn-array i64))]
  [count : i64]) : unit
  (let
    [first : i64 0]
    [end : i64 out.len]
    (while (< first count)
      (let
        [next : i64 (+ first 1)]
        [key : TliOrderKey (array-ref order first)]
        (while (and (< next count) (tli-key-eq? key (array-ref order next)))
          (+= next 1))
        (when
          (> (- next first) 1)
          (let
            [rows : strings.Vec (strings.with-capacity (- next first))]
            (for [slot (iterator.range first next)]
              (let
                [start : i64 (array-ref starts slot)]
                [length : i64 (- (array-ref starts (+ slot 1)) start)]
                [row : (__tl_dyn-array u8)
                  (buf.byte-buf-builder-copy-range out start length)]
                (strings.push-ref!
                  (&mut rows)
                  (unsafe
                    (string-from-bytes
                      (ptr-cast (__tl_array-data row) : (Ptr u8))
                      length)))))
            (string_sort.sort! (&mut rows) sort.string-less?)
            (set! out.len (array-ref starts first))
            (let
              [slots (strings.slots (& rows))]
              (for [slot (iterator.range 0 (strings.len (& rows)))]
                (let
                  [text (& (array-ref slots slot))]
                  (buf.byte-buf-builder-append-string out (string.copy text)))))
            (set! out.len end)))
        (set! first next)))))

(define (tli-write-bool! [ctx : (&mut ctx TliWriteContext)] [value : bool]) : unit
  (tli-write-u8!
    ctx
    (if value
      1
      0)))

(define (tli-write-types!
  [ctx : (&mut ctx TliWriteContext)]
  [items : (& items (__tl_dyn-array tli.TliType))]) : unit
  (tli-write-u32! ctx (array-length items))
  (for [index (iterator.range 0 (array-length items))]
    (tli-write-type! ctx (& (array-ref items index)))))

(define (tli-write-type!
  [ctx : (&mut ctx TliWriteContext)]
  [ty : (& ty tli.TliType)]) : unit
  (match ty
    [(tli.TliType.I64) (tli-write-u8! ctx 0)]
    [(tli.TliType.I32) (tli-write-u8! ctx 1)]
    [(tli.TliType.I16) (tli-write-u8! ctx 2)]
    [(tli.TliType.I8) (tli-write-u8! ctx 3)]
    [(tli.TliType.U64) (tli-write-u8! ctx 4)]
    [(tli.TliType.U32) (tli-write-u8! ctx 5)]
    [(tli.TliType.U16) (tli-write-u8! ctx 6)]
    [(tli.TliType.U8) (tli-write-u8! ctx 7)]
    [(tli.TliType.F64) (tli-write-u8! ctx 8)]
    [(tli.TliType.F32) (tli-write-u8! ctx 9)]
    [(tli.TliType.Bool) (tli-write-u8! ctx 10)]
    [(tli.TliType.Char) (tli-write-u8! ctx 11)]
    [(tli.TliType.String) (tli-write-u8! ctx 12)]
    [(tli.TliType.Str) (tli-write-u8! ctx 13)]
    [(tli.TliType.Bytes) (tli-write-u8! ctx 14)]
    [(tli.TliType.Unit) (tli-write-u8! ctx 15)]
    [(tli.TliType.Never) (tli-write-u8! ctx 16)]
    [(tli.TliType.Expr) (tli-write-u8! ctx 17)]
    [(tli.TliType.ExprList) (tli-write-u8! ctx 18)]
    [(tli.TliType.Func params ret)
      (tli-write-u8! ctx 19)
      (tli-write-types! ctx params)
      (tli-write-type! ctx (& (deref ret)))]
    [(tli.TliType.Tuple items)
      (tli-write-u8! ctx 20)
      (tli-write-types! ctx items)]
    [(tli.TliType.Array elem len)
      (tli-write-u8! ctx 21)
      (tli-write-type! ctx (& (deref elem)))
      (tli-write-u64! ctx len)]
    [(tli.TliType.DynArray inner)
      (tli-write-u8! ctx 22)
      (tli-write-type! ctx (& (deref inner)))]
    [(tli.TliType.Box inner)
      (tli-write-u8! ctx 23)
      (tli-write-type! ctx (& (deref inner)))]
    [(tli.TliType.Region name inner)
      (tli-write-u8! ctx 24)
      (tli-write-name! ctx name)
      (tli-write-type! ctx (& (deref inner)))]
    [(tli.TliType.Ref name inner)
      (tli-write-u8! ctx 25)
      (tli-write-name! ctx name)
      (tli-write-type! ctx (& (deref inner)))]
    [(tli.TliType.MutRef name inner)
      (tli-write-u8! ctx 26)
      (tli-write-name! ctx name)
      (tli-write-type! ctx (& (deref inner)))]
    [(tli.TliType.Enum name)
      (tli-write-u8! ctx 27)
      (tli-write-name! ctx name)]
    [(tli.TliType.EnumArgs name lifetimes)
      (tli-write-u8! ctx 28)
      (tli-write-name! ctx name)
      (tli-write-names! ctx lifetimes)]
    [(tli.TliType.Struct name)
      (tli-write-u8! ctx 29)
      (tli-write-name! ctx name)]
    [(tli.TliType.StructArgs name lifetimes)
      (tli-write-u8! ctx 30)
      (tli-write-name! ctx name)
      (tli-write-names! ctx lifetimes)]
    [(tli.TliType.Var name)
      (tli-write-u8! ctx 31)
      (tli-write-name! ctx name)]
    [(tli.TliType.VarArgs name lifetimes)
      (tli-write-u8! ctx 32)
      (tli-write-name! ctx name)
      (tli-write-names! ctx lifetimes)]
    [(tli.TliType.Ptr inner)
      (tli-write-u8! ctx 33)
      (tli-write-type! ctx (& (deref inner)))]
    [(tli.TliType.MutPtr inner)
      (tli-write-u8! ctx 34)
      (tli-write-type! ctx (& (deref inner)))]
    [(tli.TliType.Slice inner)
      (tli-write-u8! ctx 35)
      (tli-write-type! ctx (& (deref inner)))]
    [(tli.TliType.CFunc inner mode)
      (tli-write-u8! ctx 36)
      (tli-write-type! ctx (& (deref inner)))
      (tli-write-u8! ctx mode)]
    [(tli.TliType.Invalidate name inner)
      (tli-write-u8! ctx 37)
      (tli-write-name! ctx name)
      (tli-write-type! ctx (& (deref inner)))]))

(define (tli-write-cleanup!
  [ctx : (&mut ctx TliWriteContext)]
  [cleanup : (& cleanup tli.TliCleanup)]) : unit
  (match cleanup
    [(tli.TliCleanup.No) (tli-write-u8! ctx 0)]
    [(tli.TliCleanup.Fn symbol)
      (tli-write-u8! ctx 1)
      (tli-write-name! ctx symbol)]
    [(tli.TliCleanup.Owned) (tli-write-u8! ctx 2)]))

(define (tli-type-kind [body : (& body tli.TliTypeBody)]) : i64
  (match body
    [(tli.TliTypeBody.Struct _) 0]
    [(tli.TliTypeBody.Enum _) 1]))

(define (tli-write-field!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliField)]) : unit
  (tli-write-name! ctx (& row.name))
  (tli-write-type! ctx (& row.ty))
  (tli-write-cleanup! ctx (& row.cleanup))
  (tli-write-u64! ctx row.byte-offset)
  (tli-write-u64! ctx row.explicit-align))

(define (tli-write-payload!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliPayload)]) : unit
  (tli-write-type! ctx (& row.ty))
  (tli-write-cleanup! ctx (& row.cleanup)))

(define (tli-write-variant!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliVariant)]) : unit
  (tli-write-name! ctx (& row.name))
  (tli-write-u32! ctx (array-length row.payloads))
  (for [index (iterator.range 0 (array-length row.payloads))]
    (tli-write-payload! ctx (& (array-ref row.payloads index)))))

(define (tli-write-type-decl!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliTypeDecl)]) : unit
  (tli-write-u8! ctx (tli-type-kind (& row.body)))
  (tli-write-name! ctx (& row.name))
  (tli-write-name! ctx (& row.module-name))
  (tli-write-u32! ctx row.flags)
  (tli-write-u64! ctx row.layout-size)
  (tli-write-u64! ctx row.layout-align)
  (tli-write-u8! ctx row.repr-kind)
  (tli-write-u64! ctx row.repr-align)
  (tli-write-cleanup! ctx (& row.cleanup))
  (tli-write-names! ctx (& row.lifetimes))
  (match (& row.body)
    [(tli.TliTypeBody.Struct fields)
      (tli-write-u32! ctx (array-length fields))
      (for [index (iterator.range 0 (array-length fields))]
        (tli-write-field! ctx (& (array-ref fields index))))]
    [(tli.TliTypeBody.Enum variants)
      (tli-write-u32! ctx (array-length variants))
      (for [index (iterator.range 0 (array-length variants))]
        (tli-write-variant! ctx (& (array-ref variants index))))]))

(define (tli-write-import!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliImport)]) : unit
  (tli-write-name! ctx (& row.module-name))
  (tli-write-u8! ctx row.kind)
  (tli-write-name! ctx (& row.alias))
  (tli-write-name! ctx (& row.item))
  (tli-write-digest! ctx (& row.interface-sha256)))

(define (tli-write-extern-link-input!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliExternLinkInput)]) : unit
  (tli-write-u8! ctx row.kind)
  (tli-write-name! ctx (& row.name)))

(define (tli-write-param!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliParam)]) : unit
  (tli-write-name! ctx (& row.name))
  (tli-write-type! ctx (& row.ty))
  (tli-write-bool! ctx row.is-mut))

(define (tli-write-global-write!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliGlobalWrite)]) : unit
  (tli-write-name! ctx (& row.symbol))
  (tli-write-u8! ctx (cast row.flags : i64)))

(define (tli-write-summary!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliFnSummary)]) : unit
  (tli-write-u32! ctx row.effect-flags)
  (tli-write-u64! ctx row.arena-arg-store-mask)
  (tli-write-u32! ctx (array-length row.arena-arg-store-extra))
  (for [index (iterator.range 0 (array-length row.arena-arg-store-extra))]
    (tli-write-u32! ctx (array-ref row.arena-arg-store-extra index)))
  (let
    [count : i64 (array-length row.global-writes)]
    [order : keys.Vec
      (keys.with-capacity
        (if ctx.collecting?
          0
          count))]
    [starts : (__tl_dyn-array i64)
      (__tl_make-array
        i64
        (if ctx.collecting?
          0
          (+ count 1)))]
    (tli-write-u32! ctx count)
    (if ctx.collecting?
      (for [index (iterator.range 0 count)]
        (tli-write-global-write! ctx (& (array-ref row.global-writes index))))
      (begin
        (for [index (iterator.range 0 count)]
          (let
            [item (& (array-ref row.global-writes index))]
            (keys.push-ref!
              (&mut order)
              (tli-order-key ctx (& item.symbol) 0 "" index))))
        (key_sort.sort! (&mut order) tli-key-less?)
        (let
          [slots (keys.slots (& order))]
          (for [slot (iterator.range 0 count)]
            (let
              [key : TliOrderKey (array-ref slots slot)]
              (set! (array-ref starts slot) ctx.out.len)
              (tli-write-global-write!
                ctx
                (& (array-ref row.global-writes key.index)))))
          (set! (array-ref starts count) ctx.out.len)
          (tli-sort-tied-rows! (&mut ctx.out) slots (& starts) count)))))
  (tli-write-u64! ctx row.inline-ir-offset)
  (tli-write-u32! ctx row.inline-ir-len))

(define (tli-write-fn-decl!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliFnDecl)]) : unit
  (tli-write-name! ctx (& row.name))
  (tli-write-name! ctx (& row.module-name))
  (tli-write-name! ctx (& row.link-symbol))
  (tli-write-u8! ctx row.abi)
  (tli-write-u8! ctx row.meta-kind)
  (tli-write-name! ctx (& row.export-symbol))
  (tli-write-bool! ctx row.is-extern)
  (tli-write-u64! ctx row.extern-flags)
  (tli-write-u32! ctx (array-length row.extern-link-inputs))
  (for [index (iterator.range 0 (array-length row.extern-link-inputs))]
    (tli-write-extern-link-input!
      ctx
      (& (array-ref row.extern-link-inputs index))))
  (tli-write-u32! ctx (array-length row.params))
  (for [index (iterator.range 0 (array-length row.params))]
    (tli-write-param! ctx (& (array-ref row.params index))))
  (tli-write-type! ctx (& row.return-type))
  (tli-write-summary! ctx (& row.summary)))

(define (tli-write-const!
  [ctx : (&mut ctx TliWriteContext)]
  [value : (& value tli.TliConst)]) : unit
  (match value
    [(tli.TliConst.None) (tli-write-u8! ctx 0)]
    [(tli.TliConst.I64 bits)
      (tli-write-u8! ctx 1)
      (tli-write-u64! ctx bits)]
    [(tli.TliConst.U64 bits)
      (tli-write-u8! ctx 2)
      (tli-write-u64! ctx bits)]
    [(tli.TliConst.F64Bits bits)
      (tli-write-u8! ctx 3)
      (tli-write-u64! ctx bits)]
    [(tli.TliConst.Bool boolean)
      (tli-write-u8! ctx 4)
      (tli-write-bool! ctx boolean)]
    [(tli.TliConst.String text)
      (tli-write-u8! ctx 5)
      (when
        (not ctx.collecting?)
        (binary.compiler-incremental-binary-push-string! (&mut ctx.out) text))]
    [(tli.TliConst.Bytes bytes)
      (tli-write-u8! ctx 6)
      (tli-write-u32! ctx (array-length bytes))
      (when
        (not ctx.collecting?)
        (buf.byte-buf-builder-append-array (&mut ctx.out) bytes))]))

(define (tli-write-value-decl!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliValueDecl)]) : unit
  (tli-write-name! ctx (& row.name))
  (tli-write-name! ctx (& row.module-name))
  (tli-write-name! ctx (& row.link-symbol))
  (tli-write-type! ctx (& row.ty))
  (tli-write-u32! ctx row.flags)
  (tli-write-bool! ctx row.is-extern)
  (tli-write-u32! ctx (array-length row.extern-link-inputs))
  (for [index (iterator.range 0 (array-length row.extern-link-inputs))]
    (tli-write-extern-link-input!
      ctx
      (& (array-ref row.extern-link-inputs index))))
  (tli-write-const! ctx (& row.const-value)))

(define (tli-write-macro-param!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliMacroParam)]) : unit
  (tli-write-name! ctx (& row.name))
  (tli-write-type! ctx (& row.ty))
  (tli-write-bool! ctx row.is-by-ref)
  (tli-write-u32! ctx (array-length row.type-kinds))
  (when
    (not ctx.collecting?)
    (buf.byte-buf-builder-append-array (&mut ctx.out) (& row.type-kinds))))

(define (tli-write-macro-handle!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliMacroHandle)]) : unit
  (tli-write-name! ctx (& row.name))
  (tli-write-name! ctx (& row.module-name))
  (tli-write-name! ctx (& row.identity))
  (tli-write-u32! ctx row.flags)
  (tli-write-u8! ctx (cast row.result-kind : i64))
  (tli-write-u32! ctx (array-length row.params))
  (for [index (iterator.range 0 (array-length row.params))]
    (tli-write-macro-param! ctx (& (array-ref row.params index))))
  (tli-write-u64! ctx row.tlci-entry-index)
  (tli-write-digest! ctx (& row.tlci-catalog-sha256)))

(define (tli-write-dispatch!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliDispatchDecl)]) : unit
  (tli-write-name! ctx (& row.name))
  (tli-write-name! ctx (& row.module-name))
  (tli-write-name! ctx (& row.link-symbol))
  (tli-write-u32! ctx row.flags))

(define (tli-write-module!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliModuleRecord)]) : unit
  (tli-write-name! ctx (& row.name))
  (tli-write-name! ctx (& row.source-path))
  (tli-write-digest! ctx (& row.source-sha256))
  (tli-write-digest! ctx (& row.cfg-fingerprint-sha256))
  (tli-write-u32! ctx row.flags)
  (let
    [count : i64 (array-length row.imports)]
    [order : keys.Vec
      (keys.with-capacity
        (if ctx.collecting?
          0
          count))]
    [starts : (__tl_dyn-array i64)
      (__tl_make-array
        i64
        (if ctx.collecting?
          0
          (+ count 1)))]
    (tli-write-u32! ctx count)
    (if ctx.collecting?
      (for [index (iterator.range 0 count)]
        (tli-write-import! ctx (& (array-ref row.imports index))))
      (begin
        (for [index (iterator.range 0 count)]
          (let
            [item (& (array-ref row.imports index))]
            (keys.push-ref!
              (&mut order)
              (tli-order-key
                ctx
                (& item.module-name)
                item.kind
                (& item.alias)
                index))))
        (key_sort.sort! (&mut order) tli-key-less?)
        (let
          [slots (keys.slots (& order))]
          (for [slot (iterator.range 0 count)]
            (let
              [key : TliOrderKey (array-ref slots slot)]
              (set! (array-ref starts slot) ctx.out.len)
              (tli-write-import! ctx (& (array-ref row.imports key.index)))))
          (set! (array-ref starts count) ctx.out.len)
          (tli-sort-tied-rows! (&mut ctx.out) slots (& starts) count)))))
  (tli-write-names! ctx (& row.global-inits))
  (let
    [count : i64 (array-length row.types)]
    [order : keys.Vec
      (keys.with-capacity
        (if ctx.collecting?
          0
          count))]
    [starts : (__tl_dyn-array i64)
      (__tl_make-array
        i64
        (if ctx.collecting?
          0
          (+ count 1)))]
    (tli-write-u32! ctx count)
    (if ctx.collecting?
      (for [index (iterator.range 0 count)]
        (tli-write-type-decl! ctx (& (array-ref row.types index))))
      (begin
        (for [index (iterator.range 0 count)]
          (let
            [item (& (array-ref row.types index))]
            (keys.push-ref!
              (&mut order)
              (tli-order-key
                ctx
                (& item.name)
                (tli-type-kind (& item.body))
                ""
                index))))
        (key_sort.sort! (&mut order) tli-key-less?)
        (let
          [slots (keys.slots (& order))]
          (for [slot (iterator.range 0 count)]
            (let
              [key : TliOrderKey (array-ref slots slot)]
              (set! (array-ref starts slot) ctx.out.len)
              (tli-write-type-decl! ctx (& (array-ref row.types key.index)))))
          (set! (array-ref starts count) ctx.out.len)
          (tli-sort-tied-rows! (&mut ctx.out) slots (& starts) count)))))
  (let
    [count : i64 (array-length row.functions)]
    [order : keys.Vec
      (keys.with-capacity
        (if ctx.collecting?
          0
          count))]
    [starts : (__tl_dyn-array i64)
      (__tl_make-array
        i64
        (if ctx.collecting?
          0
          (+ count 1)))]
    (tli-write-u32! ctx count)
    (if ctx.collecting?
      (for [index (iterator.range 0 count)]
        (tli-write-fn-decl! ctx (& (array-ref row.functions index))))
      (begin
        (for [index (iterator.range 0 count)]
          (let
            [item (& (array-ref row.functions index))]
            (keys.push-ref!
              (&mut order)
              (tli-order-key ctx (& item.name) 0 (& item.link-symbol) index))))
        (key_sort.sort! (&mut order) tli-key-less?)
        (let
          [slots (keys.slots (& order))]
          (for [slot (iterator.range 0 count)]
            (let
              [key : TliOrderKey (array-ref slots slot)]
              (set! (array-ref starts slot) ctx.out.len)
              (tli-write-fn-decl! ctx (& (array-ref row.functions key.index)))))
          (set! (array-ref starts count) ctx.out.len)
          (tli-sort-tied-rows! (&mut ctx.out) slots (& starts) count)))))
  (let
    [count : i64 (array-length row.values)]
    [order : keys.Vec
      (keys.with-capacity
        (if ctx.collecting?
          0
          count))]
    [starts : (__tl_dyn-array i64)
      (__tl_make-array
        i64
        (if ctx.collecting?
          0
          (+ count 1)))]
    (tli-write-u32! ctx count)
    (if ctx.collecting?
      (for [index (iterator.range 0 count)]
        (tli-write-value-decl! ctx (& (array-ref row.values index))))
      (begin
        (for [index (iterator.range 0 count)]
          (let
            [item (& (array-ref row.values index))]
            (keys.push-ref!
              (&mut order)
              (tli-order-key ctx (& item.name) 0 (& item.link-symbol) index))))
        (key_sort.sort! (&mut order) tli-key-less?)
        (let
          [slots (keys.slots (& order))]
          (for [slot (iterator.range 0 count)]
            (let
              [key : TliOrderKey (array-ref slots slot)]
              (set! (array-ref starts slot) ctx.out.len)
              (tli-write-value-decl! ctx (& (array-ref row.values key.index)))))
          (set! (array-ref starts count) ctx.out.len)
          (tli-sort-tied-rows! (&mut ctx.out) slots (& starts) count)))))
  (let
    [count : i64 (array-length row.macros)]
    [order : keys.Vec
      (keys.with-capacity
        (if ctx.collecting?
          0
          count))]
    [starts : (__tl_dyn-array i64)
      (__tl_make-array
        i64
        (if ctx.collecting?
          0
          (+ count 1)))]
    (tli-write-u32! ctx count)
    (if ctx.collecting?
      (for [index (iterator.range 0 count)]
        (tli-write-macro-handle! ctx (& (array-ref row.macros index))))
      (begin
        (for [index (iterator.range 0 count)]
          (let
            [item (& (array-ref row.macros index))]
            (keys.push-ref!
              (&mut order)
              (tli-order-key ctx (& item.name) 0 (& item.identity) index))))
        (key_sort.sort! (&mut order) tli-key-less?)
        (let
          [slots (keys.slots (& order))]
          (for [slot (iterator.range 0 count)]
            (let
              [key : TliOrderKey (array-ref slots slot)]
              (set! (array-ref starts slot) ctx.out.len)
              (tli-write-macro-handle! ctx (& (array-ref row.macros key.index)))))
          (set! (array-ref starts count) ctx.out.len)
          (tli-sort-tied-rows! (&mut ctx.out) slots (& starts) count)))))
  (let
    [count : i64 (array-length row.dispatches)]
    [order : keys.Vec
      (keys.with-capacity
        (if ctx.collecting?
          0
          count))]
    [starts : (__tl_dyn-array i64)
      (__tl_make-array
        i64
        (if ctx.collecting?
          0
          (+ count 1)))]
    (tli-write-u32! ctx count)
    (if ctx.collecting?
      (for [index (iterator.range 0 count)]
        (tli-write-dispatch! ctx (& (array-ref row.dispatches index))))
      (begin
        (for [index (iterator.range 0 count)]
          (let
            [item (& (array-ref row.dispatches index))]
            (keys.push-ref!
              (&mut order)
              (tli-order-key ctx (& item.name) 0 (& item.link-symbol) index))))
        (key_sort.sort! (&mut order) tli-key-less?)
        (let
          [slots (keys.slots (& order))]
          (for [slot (iterator.range 0 count)]
            (let
              [key : TliOrderKey (array-ref slots slot)]
              (set! (array-ref starts slot) ctx.out.len)
              (tli-write-dispatch! ctx (& (array-ref row.dispatches key.index)))))
          (set! (array-ref starts count) ctx.out.len)
          (tli-sort-tied-rows! (&mut ctx.out) slots (& starts) count))))))

(define (tli-collect-pool [bundle : (& bundle tli.TliBundle)]) : strings.Vec
  (let
    [ctx : TliWriteContext
      (TliWriteContext true (strings.new) (buf.byte-buf-builder-new))]
    [pool : strings.Vec (strings.new)]
    (strings.push-ref! (&mut ctx.pool) "")
    (tli-write-name! (&mut ctx) (& bundle.compiler-build))
    (tli-write-name! (&mut ctx) (& bundle.target-triple))
    (for [index (iterator.range 0 (array-length bundle.modules))]
      (tli-write-module! (&mut ctx) (& (array-ref bundle.modules index))))
    (string_sort.sort! (&mut ctx.pool) sort.string-less?)
    (let
      [slots (strings.slots (& ctx.pool))]
      (for [index (iterator.range 0 (strings.len (& ctx.pool)))]
        (let
          [text (& (array-ref slots index))]
          (when
            (or
              (= index 0)
              (not (string.eq (& (array-ref slots (- index 1))) text)))
            (strings.push-ref! (&mut pool) (string.copy text))))))
    pool))

(define (tli-copy-digest!
  [out : (&mut out (__tl_dyn-array u8))]
  [offset : i64]
  [digest : (& digest (Array u8 32))]) : unit
  (for [index (iterator.range 0 32)]
    (set! (array-ref out (+ offset index)) (array-ref digest index))))

;; Encode from checked semantic facts. Table canonicalization leaves the
;; input arrays and the order of global initializers untouched.
(define (tli-encode-bundle [bundle : (& bundle tli.TliBundle)]) : (__tl_dyn-array
    u8)
  (let
    [ctx : TliWriteContext
      (TliWriteContext
        false
        (tli-collect-pool bundle)
        (buf.byte-buf-builder-new))]
    [count : i64 (array-length bundle.modules)]
    [order : keys.Vec (keys.with-capacity count)]
    (for [index (iterator.range 0 count)]
      (let
        [module (& (array-ref bundle.modules index))]
        (keys.push-ref!
          (&mut order)
          (tli-order-key (& ctx) (& module.name) 0 "" index))))
    (key_sort.sort! (&mut order) tli-key-less?)
    (for [_ (iterator.range 0 tli.tli-header-size)]
      (tli-write-u8! (&mut ctx) 0))
    (tli-write-u32! (&mut ctx) (strings.len (& ctx.pool)))
    (let
      [slots (strings.slots (& ctx.pool))]
      [offset : i64 0]
      (le.push-u32! (&mut ctx.out) 0)
      (for [index (iterator.range 0 (strings.len (& ctx.pool)))]
        (+= offset (string.string-length (& (array-ref slots index))))
        (le.push-u32! (&mut ctx.out) offset))
      (for [index (iterator.range 0 (strings.len (& ctx.pool)))]
        (buf.byte-buf-builder-append-string
          (&mut ctx.out)
          (string.copy (& (array-ref slots index))))))
    (let
      [dir-offset : i64 ctx.out.len]
      [dir-len : i64 (* count tli.tli-directory-entry-size)]
      [slots (keys.slots (& order))]
      (for [_ (iterator.range 0 dir-len)]
        (tli-write-u8! (&mut ctx) 0))
      (for [index (iterator.range 0 count)]
        (let
          [entry : i64 (+ dir-offset (* index tli.tli-directory-entry-size))]
          [key : TliOrderKey (array-ref slots index)]
          [module (& (array-ref bundle.modules key.index))]
          [start : i64 ctx.out.len]
          (tli-write-module! (&mut ctx) module)
          (let
            [length : i64 (- ctx.out.len start)]
            [digest : (Array u8 32)
              (tli-module-digest (& ctx.out.slots) start length)]
            (le.set-u32! (&mut ctx.out.slots) entry key.name)
            (le.set-u32! (&mut ctx.out.slots) (+ entry 4) module.flags)
            (le.set-u64! (&mut ctx.out.slots) (+ entry 8) start)
            (le.set-u64! (&mut ctx.out.slots) (+ entry 16) length)
            (tli-copy-digest! (&mut ctx.out.slots) (+ entry 24) (& digest)))))
      (let
        [bytes : (__tl_dyn-array u8)
          (buf.byte-buf-builder-finish-array (& ctx.out))]
        (le.set-u32! (&mut bytes) 0 tli.tli-magic)
        (le.set-u32! (&mut bytes) 4 tli.tli-schema-version)
        (le.set-u32! (&mut bytes) 8 bundle.flags)
        (le.set-u32! (&mut bytes) 12 count)
        (le.set-u64! (&mut bytes) 16 (array-length bytes))
        (le.set-u64! (&mut bytes) 24 tli.tli-header-size)
        (le.set-u64! (&mut bytes) 32 (- dir-offset tli.tli-header-size))
        (le.set-u64! (&mut bytes) 40 dir-offset)
        (le.set-u64! (&mut bytes) 48 dir-len)
        (le.set-u32!
          (&mut bytes)
          72
          (tli-find-string (& ctx.pool) (& bundle.compiler-build)))
        (le.set-u32!
          (&mut bytes)
          76
          (tli-find-string (& ctx.pool) (& bundle.target-triple)))
        (let
          [index : (Array u8 32)
            (tli-index-digest (& bytes) (+ dir-offset dir-len))]
          (tli-copy-digest! (&mut bytes) tli.tli-index-digest-offset (& index)))
        (let
          [digest : (Array u8 32) (tli-content-digest (& bytes))]
          (tli-copy-digest!
            (&mut bytes)
            tli.tli-content-digest-offset
            (& digest)))
        bytes))))

;; Reader failures are sticky. The binary reader uses codes 7/8 for its string
;; and owned-byte limits, and ByteReader reserves the negative codes.
(define tli-error-magic : i64
  20)
(define tli-error-schema : i64
  21)
(define tli-error-flags : i64
  22)
(define tli-error-offset : i64
  23)
(define tli-error-overlap : i64
  24)
(define tli-error-utf8 : i64
  25)
(define tli-error-limit : i64
  26)
(define tli-error-string-id : i64
  27)
(define tli-error-tag : i64
  28)
(define tli-error-digest : i64
  29)
(define tli-error-trailing : i64
  30)

(define (tli-read-error
  [rd : (& rd binary.CompilerIncrementalBinaryReader)]
  [base : i64]) : tli.TliDecodeFailure
  (tli.TliDecodeFailure
    (cond
      [(= rd.cursor.error-code cursor.error-truncated)
        (tli.TliDecodeError.Truncated)]
      [(= rd.cursor.error-code tli-error-magic) (tli.TliDecodeError.Magic)]
      [(= rd.cursor.error-code tli-error-schema)
        (tli.TliDecodeError.SchemaVersion)]
      [(= rd.cursor.error-code tli-error-flags) (tli.TliDecodeError.Flags)]
      [(= rd.cursor.error-code tli-error-offset)
        (tli.TliDecodeError.OffsetOutOfRange)]
      [(= rd.cursor.error-code tli-error-overlap) (tli.TliDecodeError.Overlap)]
      [(= rd.cursor.error-code tli-error-utf8) (tli.TliDecodeError.Utf8)]
      [(= rd.cursor.error-code tli-error-string-id)
        (tli.TliDecodeError.StringIdOutOfRange)]
      [(= rd.cursor.error-code tli-error-tag) (tli.TliDecodeError.UnknownTag)]
      [(= rd.cursor.error-code tli-error-digest)
        (tli.TliDecodeError.DigestMismatch)]
      [(= rd.cursor.error-code tli-error-trailing)
        (tli.TliDecodeError.TrailingBytes)]
      [else (tli.TliDecodeError.Limit)])
    (+ base rd.cursor.error-offset)
    (string.copy (& rd.cursor.error-message))))

(define (tli-fail!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [code : i64]
  [message : String]) : unit
  (let
    [offset : i64 rd.cursor.offset]
    (binary.compiler-incremental-binary-fail! rd code offset message)))

(define (tli-reserve!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [bytes : i64]) : bool
  (cond
    [(not rd.cursor.ok?) false]
    [(> bytes (- rd.max-owned-bytes rd.owned-bytes))
      (tli-fail! rd tli-error-limit "TLI owned-byte limit exceeded")
      false]
    [else
      (+= rd.owned-bytes bytes)
      true]))

;; Check count, minimum encoded size and total allocation before making the
;; output array. Charge output initialization too, including zero-length arrays.
(define (tli-check-count!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [count : i64]
  [wire-size : i64]
  [owned-size : i64]) : i64
  (cond
    [(not rd.cursor.ok?) 0]
    [(> count tli-max-count)
      (tli-fail! rd tli-error-limit "TLI count limit exceeded")
      0]
    [(not (cursor.available? (& rd.cursor) (* count wire-size)))
      (tli-fail! rd cursor.error-truncated "TLI list is truncated")
      0]
    [(not (tli-reserve! rd (+ 16 (* count owned-size)))) 0]
    [else count]))

(define (tli-read-count!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [wire-size : i64]
  [owned-size : i64]) : i64
  (let
    [count : i64 (cursor.read-u32! (&mut rd.cursor))]
    (tli-check-count! rd count wire-size owned-size)))

(define (tli-read-digest!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]) : (Array u8 32)
  (let
    [digest : (Array u8 32) (make-array u8 32)]
    (when
      (cursor.consume! (&mut rd.cursor) 32)
      (for [index (iterator.range 0 32)]
        (set!
          (array-ref digest index)
          (array-ref rd.cursor.bytes (+ rd.cursor.offset index))))
      (cursor.skip! (&mut rd.cursor) 32))
    digest))

;; The incremental identity format excludes NUL. In TLI it is valid UTF-8,
;; so run the shared scalar validator on each non-NUL segment.
(define tli-ascii-word-mask : u64
  0x8080808080808080)

;; ASCII ranges, including NUL, are valid TLI text. Check them a word at a time
;; (the last word may overlap). `base` must be readable for `start + length`.
(define (tli-ascii-range? [base : (Ptr u8)] [start : i64] [length : i64]) : bool
  (let
    [end : i64 (+ start length)]
    [index : i64 start]
    (if (< length 8)
      (while (< index end)
        (when
          (>=
            (unsafe
              (ptr-read (ptr-offset base index)))
            (cast 0x80 : u8))
          (return false))
        (+= index 1))
      (while (< index end)
        (when (> (+ index 8) end) (set! index (- end 8)))
        (when
          (!=
            (bit-and
              (unsafe
                (ptr-read (ptr-cast (ptr-offset base index) : (Ptr u64))))
              tli-ascii-word-mask)
            (cast 0 : u64))
          (return false))
        (+= index 8)))
    true))

(define (tli-utf8-valid?
  [bytes : (& bytes (__tl_dyn-array u8))]
  [start : i64]
  [length : i64]) : bool
  (when
    (and
      (cursor.range-present? (array-length bytes) start length)
      (tli-ascii-range?
        (unsafe
          (ptr-cast (__tl_array-data (deref bytes)) : (Ptr u8)))
        start
        length))
    (return true))
  (let
    [end : i64 (+ start length)]
    [segment : i64 start]
    [index : i64 start]
    [ok? : bool true]
    (while (and ok? (< index end))
      (when
        (= (array-ref bytes index) (cast 0 : u8))
        (set!
          ok?
          (binary.compiler-incremental-binary-utf8-range-valid?
            bytes
            segment
            (- index segment)))
        (set! segment (+ index 1)))
      (+= index 1))
    (and
      ok?
      (binary.compiler-incremental-binary-utf8-range-valid?
        bytes
        segment
        (- end segment)))))

(define (tli-read-text! [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]) : String
  (let
    [length : i64 (cursor.read-u32! (&mut rd.cursor))]
    [start : i64 rd.cursor.offset]
    (cond
      [(not rd.cursor.ok?) ""]
      [(> length rd.max-string-bytes)
        (tli-fail! rd tli-error-limit "TLI string limit exceeded")
        ""]
      [(not (cursor.consume! (&mut rd.cursor) length)) ""]
      [(not (tli-utf8-valid? (& rd.cursor.bytes) start length))
        (tli-fail! rd tli-error-utf8 "TLI text is not valid UTF-8")
        ""]
      [(not (tli-reserve! rd (+ length 16))) ""]
      [(= length 0) ""]
      [else
        (let
          [bytes : (__tl_dyn-array u8) (__tl_make-array u8 length)]
          (for [index (iterator.range 0 length)]
            (set!
              (array-ref bytes index)
              (array-ref rd.cursor.bytes (+ start index))))
          (cursor.skip! (&mut rd.cursor) length)
          (unsafe
            (string-from-bytes
              (ptr-cast (__tl_array-data bytes) : (Ptr u8))
              length)))])))

(define (tli-read-blob! [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]) : (__tl_dyn-array
    u8)
  (let
    [count : i64 (tli-read-count! rd 1 1)]
    [start : i64 rd.cursor.offset]
    (if (cursor.consume! (&mut rd.cursor) count)
      (let
        [out : (__tl_dyn-array u8) (__tl_make-array u8 count)]
        (for [index (iterator.range 0 count)]
          (set!
            (array-ref out index)
            (array-ref rd.cursor.bytes (+ start index))))
        (cursor.skip! (&mut rd.cursor) count)
        out)
      (__tl_make-array u8 0))))

;; A decoded string pool. An eager pool holds every string. A lazy pool leaves
;; `strings` empty and keeps where the pool's offset table and text lie in the
;; file bytes that the enclosing `TliDirectory` owns (`base`);
;; `tli-read-name!` reads an entry's two offsets, then validates, charges and
;; copies its text only when a record uses it, so opening a file reads no entry.
(defstruct TliPool
  (strings (__tl_dyn-array String))
  (lazy? bool)
  (count i64)
  (table i64)
  (text i64)
  (text-len i64)
  (base (Ptr u8)))

(define (tli-pool-offset-at [pool : (& pool TliPool)] [id : i64]) : i64
  (let
    [at : i64 (+ pool.table (* 4 id))]
    [value : i64 0]
    (for [byte (iterator.range 0 4)]
      (set!
        value
        (bit-or
          value
          (shl
            (cast
              (unsafe
                (ptr-read (ptr-offset pool.base (+ at byte))))
              : i64)
            (* 8 byte)))))
    value))

(define (tli-read-lazy-name!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [id : i64]) : String
  (let
    [first : i64 (tli-pool-offset-at pool id)]
    [last : i64 (tli-pool-offset-at pool (+ id 1))]
    [start : i64 (+ pool.text first)]
    [length : i64 (- last first)]
    (cond
      [(or (< length 0) (> last pool.text-len))
        (tli-fail!
          rd
          tli-error-offset
          "TLI string lies outside its pool section")
        ""]
      [(> length tli-max-string-bytes)
        (tli-fail! rd tli-error-limit "TLI string length limit exceeded")
        ""]
      [(not
        (or
          (tli-ascii-range? pool.base start length)
          (let
            [text : (__tl_dyn-array u8) (__tl_make-array u8 length)]
            (for [index (iterator.range 0 length)]
              (set!
                (array-ref text index)
                (unsafe
                  (ptr-read (ptr-offset pool.base (+ start index))))))
            (tli-utf8-valid? (& text) 0 length))))
        (tli-fail! rd tli-error-utf8 "TLI text is not valid UTF-8")
        ""]
      [(not (tli-reserve! rd (+ 16 length))) ""]
      [else
        (unsafe
          (string-from-bytes (ptr-offset pool.base start) length))])))

(define (tli-read-name!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : String
  (let
    [id : i64 (cursor.read-u32! (&mut rd.cursor))]
    (cond
      [(not rd.cursor.ok?) ""]
      [(>= id pool.count)
        (tli-fail! rd tli-error-string-id "TLI string id is out of range")
        ""]
      [(= id 0) ""]
      [pool.lazy? (tli-read-lazy-name! rd pool id)]
      [else
        (let
          [text (& (array-ref pool.strings id))]
          (if (tli-reserve! rd (+ 16 (string.string-length text)))
            (string.copy text)
            ""))])))

(define (tli-read-flags!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [mask : i64]) : i64
  (let
    [flags : i64 (cursor.read-u32! (&mut rd.cursor))]
    (when
      (not (= flags (bit-and flags mask)))
      (tli-fail! rd tli-error-flags "TLI flags contain reserved bits"))
    flags))

(define (tli-read-tag!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [max-tag : i64]) : i64
  (let
    [tag : i64 (cursor.read-u8! (&mut rd.cursor))]
    (if (> tag max-tag)
      (begin
        (tli-fail! rd tli-error-tag "TLI tag is out of range")
        0)
      tag)))

(define (tli-read-bool! [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]) : bool
  (= (tli-read-tag! rd 1) 1))

(define (tli-read-names!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : (__tl_dyn-array String)
  (let
    [count : i64 (tli-read-count! rd 4 (comptime (size-of (type String))))]
    [names : (__tl_dyn-array String) (__tl_make-array String count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref names index) (tli-read-name! rd pool))
      (+= index 1))
    names))

(define (tli-check-order!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [previous : (& previous str)]
  [previous-kind : i64]
  [previous-symbol : (& previous-symbol str)]
  [name : (& name str)]
  [kind : i64]
  [symbol : (& symbol str)]) : unit
  (when
    (and
      rd.cursor.ok?
      (or
        (sort.string-less-borrowed? name previous)
        (and
          (string.eq name previous)
          (or
            (< kind previous-kind)
            (and
              (= kind previous-kind)
              (sort.string-less-borrowed? symbol previous-symbol))))))
    (tli-fail! rd tli-error-tag "TLI table is out of canonical order")))

(define (tli-read-types!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [comptime? : bool]
  [depth : i64]) : (__tl_dyn-array tli.TliType)
  (let
    [count : i64 (tli-read-count! rd 1 (comptime (size-of (type tli.TliType))))]
    [items : (__tl_dyn-array tli.TliType) (__tl_make-array tli.TliType count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-type! rd pool comptime? depth))
      (+= index 1))
    items))

(define (tli-read-type-box!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [comptime? : bool]
  [depth : i64]) : (Box tli.TliType)
  (box (tli-read-type! rd pool comptime? depth)))

(define (tli-read-type!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [comptime? : bool]
  [depth : i64]) : tli.TliType
  (when
    (> depth tli.tli-max-type-depth)
    (tli-fail! rd tli-error-limit "TLI type nesting limit exceeded")
    (return (tli.TliType.Unit)))
  (let
    [tag : i64 (tli-read-tag! rd 37)]
    [next : i64 (+ depth 1)]
    (when
      (and (not comptime?) (or (= tag 17) (= tag 18)))
      (tli-fail!
        rd
        tli-error-tag
        "TLI expression type requires a comptime declaration"))
    (when
      (and
        (or (= tag 19) (and (>= tag 21) (<= tag 26)) (>= tag 33))
        (not (tli-reserve! rd (+ 16 (comptime (size-of (type tli.TliType)))))))
      (return (tli.TliType.Unit)))
    (match tag
      [0 (tli.TliType.I64)]
      [1 (tli.TliType.I32)]
      [2 (tli.TliType.I16)]
      [3 (tli.TliType.I8)]
      [4 (tli.TliType.U64)]
      [5 (tli.TliType.U32)]
      [6 (tli.TliType.U16)]
      [7 (tli.TliType.U8)]
      [8 (tli.TliType.F64)]
      [9 (tli.TliType.F32)]
      [10 (tli.TliType.Bool)]
      [11 (tli.TliType.Char)]
      [12 (tli.TliType.String)]
      [13 (tli.TliType.Str)]
      [14 (tli.TliType.Bytes)]
      [15 (tli.TliType.Unit)]
      [16 (tli.TliType.Never)]
      [17 (tli.TliType.Expr)]
      [18 (tli.TliType.ExprList)]
      [19
        (tli.TliType.Func
          (tli-read-types! rd pool comptime? next)
          (tli-read-type-box! rd pool comptime? next))]
      [20 (tli.TliType.Tuple (tli-read-types! rd pool comptime? next))]
      [21
        (tli.TliType.Array
          (tli-read-type-box! rd pool comptime? next)
          (cursor.read-u64! (&mut rd.cursor)))]
      [22 (tli.TliType.DynArray (tli-read-type-box! rd pool comptime? next))]
      [23 (tli.TliType.Box (tli-read-type-box! rd pool comptime? next))]
      [24
        (tli.TliType.Region
          (tli-read-name! rd pool)
          (tli-read-type-box! rd pool comptime? next))]
      [25
        (tli.TliType.Ref
          (tli-read-name! rd pool)
          (tli-read-type-box! rd pool comptime? next))]
      [26
        (tli.TliType.MutRef
          (tli-read-name! rd pool)
          (tli-read-type-box! rd pool comptime? next))]
      [27 (tli.TliType.Enum (tli-read-name! rd pool))]
      [28
        (tli.TliType.EnumArgs
          (tli-read-name! rd pool)
          (tli-read-names! rd pool))]
      [29 (tli.TliType.Struct (tli-read-name! rd pool))]
      [30
        (tli.TliType.StructArgs
          (tli-read-name! rd pool)
          (tli-read-names! rd pool))]
      [31 (tli.TliType.Var (tli-read-name! rd pool))]
      [32
        (tli.TliType.VarArgs (tli-read-name! rd pool) (tli-read-names! rd pool))]
      [33 (tli.TliType.Ptr (tli-read-type-box! rd pool comptime? next))]
      [34 (tli.TliType.MutPtr (tli-read-type-box! rd pool comptime? next))]
      [35 (tli.TliType.Slice (tli-read-type-box! rd pool comptime? next))]
      [36
        (tli.TliType.CFunc
          (tli-read-type-box! rd pool comptime? next)
          (tli-read-tag! rd 3))]
      [37
        (tli.TliType.Invalidate
          (tli-read-name! rd pool)
          (tli-read-type-box! rd pool comptime? next))]
      [_ (tli.TliType.Unit)])))

(define (tli-read-cleanup!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [field? : bool]) : tli.TliCleanup
  (match (tli-read-tag!
    rd
    (if field?
      2
      1))
    [1 (tli.TliCleanup.Fn (tli-read-name! rd pool))]
    [2 (tli.TliCleanup.Owned)]
    [_ (tli.TliCleanup.No)]))

(define (tli-read-field!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [comptime? : bool]) : tli.TliField
  (tli.TliField
    (tli-read-name! rd pool)
    (tli-read-type! rd pool comptime? 1)
    (tli-read-cleanup! rd pool true)
    (cursor.read-u64! (&mut rd.cursor))
    (cursor.read-u64! (&mut rd.cursor))))

(define (tli-read-fields!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [comptime? : bool]) : (__tl_dyn-array tli.TliField)
  (let
    [count : i64
      (tli-read-count! rd 22 (comptime (size-of (type tli.TliField))))]
    [items : (__tl_dyn-array tli.TliField) (__tl_make-array tli.TliField count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-field! rd pool comptime?))
      (+= index 1))
    items))

(define (tli-read-payload!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [comptime? : bool]) : tli.TliPayload
  (tli.TliPayload
    (tli-read-type! rd pool comptime? 1)
    (tli-read-cleanup! rd pool true)))

(define (tli-read-payloads!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [comptime? : bool]) : (__tl_dyn-array tli.TliPayload)
  (let
    [count : i64
      (tli-read-count! rd 2 (comptime (size-of (type tli.TliPayload))))]
    [items : (__tl_dyn-array tli.TliPayload)
      (__tl_make-array tli.TliPayload count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-payload! rd pool comptime?))
      (+= index 1))
    items))

(define (tli-read-variant!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [comptime? : bool]) : tli.TliVariant
  (tli.TliVariant
    (tli-read-name! rd pool)
    (tli-read-payloads! rd pool comptime?)))

(define (tli-read-variants!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [comptime? : bool]) : (__tl_dyn-array tli.TliVariant)
  (let
    [count : i64
      (tli-read-count! rd 8 (comptime (size-of (type tli.TliVariant))))]
    [items : (__tl_dyn-array tli.TliVariant)
      (__tl_make-array tli.TliVariant count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-variant! rd pool comptime?))
      (+= index 1))
    items))

(define (tli-read-type-decl!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliTypeDecl
  (let
    [kind : i64 (tli-read-tag! rd 1)]
    [name : String (tli-read-name! rd pool)]
    [module-name : String (tli-read-name! rd pool)]
    [flags : i64 (tli-read-flags! rd 31)]
    [comptime? : bool (not (= 0 (bit-and flags 4)))]
    (tli.TliTypeDecl
      name
      module-name
      flags
      (cursor.read-u64! (&mut rd.cursor))
      (cursor.read-u64! (&mut rd.cursor))
      (tli-read-tag! rd 1)
      (cursor.read-u64! (&mut rd.cursor))
      (tli-read-cleanup! rd pool false)
      (tli-read-names! rd pool)
      (if (= kind 0)
        (tli.TliTypeBody.Struct (tli-read-fields! rd pool comptime?))
        (tli.TliTypeBody.Enum (tli-read-variants! rd pool comptime?))))))

(define (tli-read-type-decls!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : (__tl_dyn-array tli.TliTypeDecl)
  (let
    [count : i64
      (tli-read-count! rd 47 (comptime (size-of (type tli.TliTypeDecl))))]
    [items : (__tl_dyn-array tli.TliTypeDecl)
      (__tl_make-array tli.TliTypeDecl count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-type-decl! rd pool))
      (when
        (> index 0)
        (let
          [previous (& (array-ref items (- index 1)))]
          [item (& (array-ref items index))]
          (tli-check-order!
            rd
            (& previous.name)
            (tli-type-kind (& previous.body))
            ""
            (& item.name)
            (tli-type-kind (& item.body))
            "")))
      (+= index 1))
    items))

(define (tli-read-import!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliImport
  (let
    [name : String (tli-read-name! rd pool)]
    [kind : i64 (tli-read-tag! rd 4)]
    [alias : String (tli-read-name! rd pool)]
    [item : String (tli-read-name! rd pool)]
    (when
      (!= (= kind 2) (> (string.string-length (& item)) 0))
      (tli-fail! rd tli-error-tag "TLI import item disagrees with import kind"))
    (tli.TliImport name kind alias item (tli-read-digest! rd))))

(define (tli-read-imports!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : (__tl_dyn-array tli.TliImport)
  (let
    [count : i64
      (tli-read-count! rd 45 (comptime (size-of (type tli.TliImport))))]
    [items : (__tl_dyn-array tli.TliImport)
      (__tl_make-array tli.TliImport count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-import! rd pool))
      (when
        (> index 0)
        (let
          [previous (& (array-ref items (- index 1)))]
          [item (& (array-ref items index))]
          (tli-check-order!
            rd
            (& previous.module-name)
            previous.kind
            (& previous.alias)
            (& item.module-name)
            item.kind
            (& item.alias))))
      (+= index 1))
    items))

(define (tli-read-extern-link-input!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliExternLinkInput
  (tli.TliExternLinkInput (tli-read-tag! rd 2) (tli-read-name! rd pool)))

(define (tli-read-extern-link-inputs!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : (__tl_dyn-array tli.TliExternLinkInput)
  (let
    [count : i64
      (tli-read-count! rd 5 (comptime (size-of (type tli.TliExternLinkInput))))]
    [items : (__tl_dyn-array tli.TliExternLinkInput)
      (__tl_make-array tli.TliExternLinkInput count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-extern-link-input! rd pool))
      (+= index 1))
    items))

(define (tli-read-param!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [comptime? : bool]) : tli.TliParam
  (tli.TliParam
    (tli-read-name! rd pool)
    (tli-read-type! rd pool comptime? 1)
    (tli-read-bool! rd)))

(define (tli-read-params!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [comptime? : bool]) : (__tl_dyn-array tli.TliParam)
  (let
    [count : i64
      (tli-read-count! rd 6 (comptime (size-of (type tli.TliParam))))]
    [items : (__tl_dyn-array tli.TliParam) (__tl_make-array tli.TliParam count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-param! rd pool comptime?))
      (+= index 1))
    items))

(define (tli-read-global-write!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliGlobalWrite
  (tli.TliGlobalWrite
    (tli-read-name! rd pool)
    (cast (cursor.read-u8! (&mut rd.cursor)) : u8)))

(define (tli-read-global-writes!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : (__tl_dyn-array tli.TliGlobalWrite)
  (let
    [count : i64
      (tli-read-count! rd 5 (comptime (size-of (type tli.TliGlobalWrite))))]
    [items : (__tl_dyn-array tli.TliGlobalWrite)
      (__tl_make-array tli.TliGlobalWrite count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-global-write! rd pool))
      (when
        (> index 0)
        (let
          [previous (& (array-ref items (- index 1)))]
          [item (& (array-ref items index))]
          (tli-check-order! rd (& previous.symbol) 0 "" (& item.symbol) 0 "")))
      (+= index 1))
    items))

(define (tli-read-arena-extra!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]) : i64
  (let
    [index : i64 (cursor.read-u32! (&mut rd.cursor))]
    (when
      (< index 64)
      (tli-fail! rd tli-error-tag "TLI extra arena argument index is below 64"))
    index))

(define (tli-read-arena-extras!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]) : (__tl_dyn-array
    i64)
  (let
    [count : i64 (tli-read-count! rd 4 (comptime (size-of (type i64))))]
    [items : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-arena-extra! rd))
      (+= index 1))
    items))

(define (tli-read-summary-tail!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [effect-flags : i64]) : tli.TliFnSummary
  (let
    [mask : i64 (cursor.read-u64! (&mut rd.cursor))]
    [extra : (__tl_dyn-array i64) (tli-read-arena-extras! rd)]
    [writes : (__tl_dyn-array tli.TliGlobalWrite)
      (tli-read-global-writes! rd pool)]
    [offset : i64 (cursor.read-u64! (&mut rd.cursor))]
    [length : i64 (cursor.read-u32! (&mut rd.cursor))]
    (when
      (or (not (= offset 0)) (not (= length 0)))
      (tli-fail! rd tli-error-offset "TLI v2 reserves inline IR offsets"))
    (tli.TliFnSummary effect-flags mask extra writes offset length)))

(define (tli-read-fn-decl!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliFnDecl
  (let
    [name : String (tli-read-name! rd pool)]
    [module-name : String (tli-read-name! rd pool)]
    [symbol : String (tli-read-name! rd pool)]
    [abi : i64 (tli-read-tag! rd 3)]
    [meta : i64 (tli-read-tag! rd 2)]
    [export-symbol : String (tli-read-name! rd pool)]
    [extern? : bool (tli-read-bool! rd)]
    [extern-flags : i64 (cursor.read-u64! (&mut rd.cursor))]
    [extern-inputs : (__tl_dyn-array tli.TliExternLinkInput)
      (tli-read-extern-link-inputs! rd pool)]
    [params : (__tl_dyn-array tli.TliParam) (tli-read-params! rd pool true)]
    [ret : tli.TliType (tli-read-type! rd pool true 1)]
    [effect-flags : i64
      (tli-read-flags! rd (bit-or 191 tli.tli-fn-stores-ambient-arena-arg))]
    (when
      (and (= abi 3) (= (array-length params) 0))
      (tli-fail! rd tli-error-tag "TLI typed varargs function has no tail type"))
    (when
      (= 0 (bit-and effect-flags 2))
      (tli-check-runtime-signature! rd (& params) (& ret)))
    (tli.TliFnDecl
      name
      module-name
      symbol
      abi
      meta
      export-symbol
      extern?
      extern-flags
      extern-inputs
      params
      ret
      (tli-read-summary-tail! rd pool effect-flags))))

(define (tli-read-fn-decls!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : (__tl_dyn-array tli.TliFnDecl)
  (let
    [count : i64
      (tli-read-count! rd 68 (comptime (size-of (type tli.TliFnDecl))))]
    [items : (__tl_dyn-array tli.TliFnDecl)
      (__tl_make-array tli.TliFnDecl count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-fn-decl! rd pool))
      (when
        (> index 0)
        (let
          [previous (& (array-ref items (- index 1)))]
          [item (& (array-ref items index))]
          (tli-check-order!
            rd
            (& previous.name)
            0
            (& previous.link-symbol)
            (& item.name)
            0
            (& item.link-symbol))))
      (+= index 1))
    items))

(define (tli-read-const!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]) : tli.TliConst
  (match (tli-read-tag! rd 6)
    [1 (tli.TliConst.I64 (cursor.read-u64! (&mut rd.cursor)))]
    [2 (tli.TliConst.U64 (cursor.read-u64! (&mut rd.cursor)))]
    [3 (tli.TliConst.F64Bits (cursor.read-u64! (&mut rd.cursor)))]
    [4 (tli.TliConst.Bool (tli-read-bool! rd))]
    [5 (tli.TliConst.String (tli-read-text! rd))]
    [6 (tli.TliConst.Bytes (tli-read-blob! rd))]
    [_ (tli.TliConst.None)]))

(define (tli-read-value-decl!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliValueDecl
  (let
    [name : String (tli-read-name! rd pool)]
    [module-name : String (tli-read-name! rd pool)]
    [symbol : String (tli-read-name! rd pool)]
    [ty : tli.TliType (tli-read-type! rd pool true 1)]
    [flags : i64 (tli-read-flags! rd 15)]
    (when (= 0 (bit-and flags 1)) (tli-check-runtime-type! rd (& ty)))
    (let
      [is-extern : bool (tli-read-bool! rd)]
      [links : (__tl_dyn-array tli.TliExternLinkInput)
        (tli-read-extern-link-inputs! rd pool)]
      (when
        (and (not is-extern) (> (array-length links) 0))
        (tli-fail! rd tli-error-tag "TLI local value has extern link inputs"))
      (tli.TliValueDecl
        name
        module-name
        symbol
        ty
        flags
        is-extern
        links
        (tli-read-const! rd)))))

(define (tli-read-value-decls!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : (__tl_dyn-array tli.TliValueDecl)
  (let
    [count : i64
      (tli-read-count! rd 23 (comptime (size-of (type tli.TliValueDecl))))]
    [items : (__tl_dyn-array tli.TliValueDecl)
      (__tl_make-array tli.TliValueDecl count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-value-decl! rd pool))
      (when
        (> index 0)
        (let
          [previous (& (array-ref items (- index 1)))]
          [item (& (array-ref items index))]
          (tli-check-order!
            rd
            (& previous.name)
            0
            (& previous.link-symbol)
            (& item.name)
            0
            (& item.link-symbol))))
      (+= index 1))
    items))

(define (tli-read-macro-param!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliMacroParam
  (tli.TliMacroParam
    (tli-read-name! rd pool)
    (tli-read-type! rd pool true 1)
    (tli-read-bool! rd)
    (tli-read-blob! rd)))

(define (tli-read-macro-params!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : (__tl_dyn-array tli.TliMacroParam)
  (let
    [count : i64
      (tli-read-count! rd 10 (comptime (size-of (type tli.TliMacroParam))))]
    [items : (__tl_dyn-array tli.TliMacroParam)
      (__tl_make-array tli.TliMacroParam count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-macro-param! rd pool))
      (+= index 1))
    items))

(define (tli-read-macro-handle!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliMacroHandle
  (let
    [name : String (tli-read-name! rd pool)]
    [module-name : String (tli-read-name! rd pool)]
    [identity : String (tli-read-name! rd pool)]
    [flags : i64 (tli-read-flags! rd 31)]
    [result-kind : i64 (tli-read-tag! rd 2)]
    [params : (__tl_dyn-array tli.TliMacroParam)
      (tli-read-macro-params! rd pool)]
    [entry : i64 (cursor.read-u64! (&mut rd.cursor))]
    (when
      (or
        (= (bit-and flags 3) 3)
        (!= (!= (bit-and flags 8) 0) (!= result-kind 0)))
      (tli-fail! rd tli-error-tag "TLI macro flags disagree with its kind"))
    (when
      (if (= 0 (bit-and flags 1))
        (not (= entry -1))
        (< entry 0))
      (tli-fail! rd tli-error-tag "TLI macro entry index disagrees with flags"))
    (tli.TliMacroHandle
      name
      module-name
      identity
      flags
      (cast result-kind : u8)
      params
      entry
      (tli-read-digest! rd))))

(define (tli-read-macro-handles!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : (__tl_dyn-array tli.TliMacroHandle)
  (let
    [count : i64
      (tli-read-count! rd 61 (comptime (size-of (type tli.TliMacroHandle))))]
    [items : (__tl_dyn-array tli.TliMacroHandle)
      (__tl_make-array tli.TliMacroHandle count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-macro-handle! rd pool))
      (when
        (> index 0)
        (let
          [previous (& (array-ref items (- index 1)))]
          [item (& (array-ref items index))]
          (tli-check-order!
            rd
            (& previous.name)
            0
            (& previous.identity)
            (& item.name)
            0
            (& item.identity))))
      (+= index 1))
    items))

(define (tli-read-dispatch!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliDispatchDecl
  (tli.TliDispatchDecl
    (tli-read-name! rd pool)
    (tli-read-name! rd pool)
    (tli-read-name! rd pool)
    (tli-read-flags! rd 0)))

(define (tli-read-dispatches!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : (__tl_dyn-array tli.TliDispatchDecl)
  (let
    [count : i64
      (tli-read-count! rd 16 (comptime (size-of (type tli.TliDispatchDecl))))]
    [items : (__tl_dyn-array tli.TliDispatchDecl)
      (__tl_make-array tli.TliDispatchDecl count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-dispatch! rd pool))
      (when
        (> index 0)
        (let
          [previous (& (array-ref items (- index 1)))]
          [item (& (array-ref items index))]
          (tli-check-order!
            rd
            (& previous.name)
            0
            (& previous.link-symbol)
            (& item.name)
            0
            (& item.link-symbol))))
      (+= index 1))
    items))

;; The fn and value flags follow the types on the wire. Check their decoded
;; trees once the declaration's comptime bit is known.
(define (tli-check-runtime-types!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [items : (& items (__tl_dyn-array tli.TliType))]) : unit
  (let
    [index : i64 0]
    (while (and rd.cursor.ok? (< index (array-length items)))
      (tli-check-runtime-type! rd (& (array-ref items index)))
      (+= index 1))))

(define (tli-check-runtime-type!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [ty : (& ty tli.TliType)]) : unit
  (when
    rd.cursor.ok?
    (match ty
      [(tli.TliType.Expr)
        (tli-fail!
          rd
          tli-error-tag
          "TLI expression type requires a comptime declaration")]
      [(tli.TliType.ExprList)
        (tli-fail!
          rd
          tli-error-tag
          "TLI expression type requires a comptime declaration")]
      [(tli.TliType.Func params ret)
        (tli-check-runtime-types! rd params)
        (tli-check-runtime-type! rd (& (deref ret)))]
      [(tli.TliType.Tuple items) (tli-check-runtime-types! rd items)]
      [(tli.TliType.Array inner _)
        (tli-check-runtime-type! rd (& (deref inner)))]
      [(tli.TliType.DynArray inner)
        (tli-check-runtime-type! rd (& (deref inner)))]
      [(tli.TliType.Box inner) (tli-check-runtime-type! rd (& (deref inner)))]
      [(tli.TliType.Region _ inner)
        (tli-check-runtime-type! rd (& (deref inner)))]
      [(tli.TliType.Ref _ inner) (tli-check-runtime-type! rd (& (deref inner)))]
      [(tli.TliType.MutRef _ inner)
        (tli-check-runtime-type! rd (& (deref inner)))]
      [(tli.TliType.Ptr inner) (tli-check-runtime-type! rd (& (deref inner)))]
      [(tli.TliType.MutPtr inner)
        (tli-check-runtime-type! rd (& (deref inner)))]
      [(tli.TliType.Slice inner) (tli-check-runtime-type! rd (& (deref inner)))]
      [(tli.TliType.CFunc inner _)
        (tli-check-runtime-type! rd (& (deref inner)))]
      [(tli.TliType.Invalidate _ inner)
        (tli-check-runtime-type! rd (& (deref inner)))]
      [_ unit])))

(define (tli-check-runtime-signature!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [params : (& params (__tl_dyn-array tli.TliParam))]
  [ret : (& ret tli.TliType)]) : unit
  (let
    [index : i64 0]
    (while (and rd.cursor.ok? (< index (array-length params)))
      (let
        [param (& (array-ref params index))]
        (tli-check-runtime-type! rd (& param.ty)))
      (+= index 1))
    (tli-check-runtime-type! rd ret)))

(defstruct TliDirectory
  (schema-version i64)
  (flags i64)
  (compiler-build String)
  (target-triple String)
  (content-sha256 (Array u8 32))
  (entries (__tl_dyn-array tli.TliDirectoryEntry))
  (pool TliPool)
  (bytes (__tl_dyn-array u8))
  (owned-bytes i64))

(defenum TliDirectoryResult
  (Ok TliDirectory)
  (Err tli.TliDecodeFailure))

(defenum TliModuleResult
  (Ok tli.TliModuleRecord)
  (Err tli.TliDecodeFailure))

(defenum TliBundleResult
  (Ok tli.TliBundle)
  (Err tli.TliDecodeFailure))

(define (tli-check-section!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [start : i64]
  [length : i64]
  [expected : i64]) : unit
  (cond
    [(not (cursor.range-present? (array-length rd.cursor.bytes) start length))
      (tli-fail! rd tli-error-offset "TLI section lies outside the file")]
    [(< start expected)
      (tli-fail!
        rd
        tli-error-overlap
        "TLI sections overlap or are out of order")]
    [(> start expected)
      (tli-fail! rd tli-error-offset "TLI sections have a gap")]
    [else unit]))

(define (tli-check-end! [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]) : unit
  (when
    (and rd.cursor.ok? (not (cursor.at-end? (& rd.cursor))))
    (tli-fail! rd tli-error-trailing "TLI section has trailing bytes")))

;; The pool section is `u32 count`, `u32 offsets[count + 1]` relative to the
;; text that follows them, then the text. Entry zero is the empty string and
;; the last offset ends the section. Returns the pool header with no entry read.
(define (tli-read-pool-header!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [lazy? : bool]) : TliPool
  (let
    [section-end : i64 rd.cursor.end]
    [count : i64 (cursor.read-u32! (&mut rd.cursor))]
    [table : i64 rd.cursor.offset]
    [text : i64 (+ table (* 4 (+ count 1)))]
    [pool : TliPool
      (TliPool
        (__tl_make-array String 0)
        lazy?
        0
        table
        text
        0
        (unsafe
          (ptr-cast (__tl_array-data rd.cursor.bytes) : (Ptr u8))))]
    (cond
      [(not rd.cursor.ok?) pool]
      [(or (= count 0) (> count tli-max-count))
        (tli-fail!
          rd
          tli-error-tag
          "TLI string pool must start with an empty string")
        pool]
      [(> text section-end)
        (tli-fail!
          rd
          cursor.error-truncated
          "TLI string pool offsets lie outside its section")
        pool]
      [else
        (set! pool.count count)
        (set! pool.text-len (- section-end text))
        (when
          (or
            (!= (tli-pool-offset-at (& pool) 0) 0)
            (!= (tli-pool-offset-at (& pool) 1) 0)
            (!= (tli-pool-offset-at (& pool) count) pool.text-len))
          (tli-fail!
            rd
            tli-error-tag
            "TLI string pool offsets do not span its text"))
        pool])))

(define (tli-read-pool-lazy!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]) : TliPool
  (tli-read-pool-header! rd true))

(define (tli-read-pool! [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]) : TliPool
  (let
    [pool : TliPool (tli-read-pool-header! rd false)]
    [strings : (__tl_dyn-array String)
      (__tl_make-array
        String
        (if rd.cursor.ok?
          pool.count
          0))]
    [index : i64 1]
    (when
      (and
        rd.cursor.ok?
        (tli-reserve! rd (* pool.count (comptime (size-of (type String))))))
      (while (and rd.cursor.ok? (< index pool.count))
        (let
          [text : String (tli-read-lazy-name! rd (& pool) index)]
          (when
            (and
              rd.cursor.ok?
              (not
                (sort.string-less-borrowed?
                  (& (array-ref strings (- index 1)))
                  (& text))))
            (tli-fail!
              rd
              tli-error-tag
              "TLI string pool is not in strict canonical order"))
          (set! (array-ref strings index) text))
        (+= index 1)))
    (set! pool.strings strings)
    pool))

(define (tli-read-entries!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [count : i64]
  [records-start : i64]) : (__tl_dyn-array tli.TliDirectoryEntry)
  (let
    [length : i64
      (tli-check-count!
        rd
        count
        tli.tli-directory-entry-size
        (comptime (size-of (type tli.TliDirectoryEntry))))]
    [entries : (__tl_dyn-array tli.TliDirectoryEntry)
      (__tl_make-array tli.TliDirectoryEntry length)]
    [record-end : i64 records-start]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index length))
      (let
        [name : String (tli-read-name! rd pool)]
        [flags : i64 (tli-read-flags! rd 31)]
        [start : i64 (cursor.read-u64! (&mut rd.cursor))]
        [size : i64 (cursor.read-u64! (&mut rd.cursor))]
        [digest : (Array u8 32) (tli-read-digest! rd)]
        (when
          (or
            (= (string.string-length (& name)) 0)
            (and
              (> index 0)
              (let
                [previous (& (array-ref entries (- index 1)))]
                (not (sort.string-less-borrowed? (& previous.name) (& name))))))
          (tli-fail!
            rd
            tli-error-tag
            "TLI module names are not in strict canonical order"))
        (tli-check-section! rd start size record-end)
        (when
          rd.cursor.ok?
          (set! record-end (+ start size))
          (set!
            (array-ref entries index)
            (tli.TliDirectoryEntry name flags start size digest))))
      (+= index 1))
    (tli-check-end! rd)
    (when
      (not (= record-end (array-length rd.cursor.bytes)))
      (tli-fail!
        rd
        tli-error-trailing
        "TLI file has bytes after its last module"))
    entries))

;; Open only the envelope, verifying its content hash (when requested) and all
;; packed ranges. The snapshot cannot be changed through the original input array.
(define (tli-decode-directory-inner
  [bytes : (& bytes (__tl_dyn-array u8))]
  [verify-content-digest? : bool]) : TliDirectoryResult
  (let
    [length : i64 (array-length bytes)]
    (when
      (> length tli-max-file-bytes)
      (return
        (TliDirectoryResult.Err
          (tli.TliDecodeFailure
            (tli.TliDecodeError.Limit)
            0
            "TLI file limit exceeded"))))
    (let
      [rd : binary.CompilerIncrementalBinaryReader
        (binary.compiler-incremental-binary-reader
          bytes
          tli-max-work
          tli-max-owned-bytes
          tli-max-string-bytes)]
      [magic : i64 (cursor.read-u32! (&mut rd.cursor))]
      (when
        (not (= magic tli.tli-magic))
        (tli-fail! (&mut rd) tli-error-magic "incorrect TLI magic"))
      (let
        [version : i64 (cursor.read-u32! (&mut rd.cursor))]
        (when
          (not (= version tli.tli-schema-version))
          (tli-fail!
            (&mut rd)
            tli-error-schema
            "unsupported TLI schema version"))
        (let
          [flags : i64
            (tli-read-flags!
              (&mut rd)
              (bit-or tli.tli-is-stdlib-bundle tli.tli-has-tlci-companion))]
          [count : i64 (cursor.read-u32! (&mut rd.cursor))]
          [total : i64 (cursor.read-u64! (&mut rd.cursor))]
          [pool-start : i64 (cursor.read-u64! (&mut rd.cursor))]
          [pool-size : i64 (cursor.read-u64! (&mut rd.cursor))]
          [dir-start : i64 (cursor.read-u64! (&mut rd.cursor))]
          [dir-size : i64 (cursor.read-u64! (&mut rd.cursor))]
          [ir-start : i64 (cursor.read-u64! (&mut rd.cursor))]
          [ir-size : i64 (cursor.read-u64! (&mut rd.cursor))]
          [_build-id : i64 (cursor.read-u32! (&mut rd.cursor))]
          [_target-id : i64 (cursor.read-u32! (&mut rd.cursor))]
          [digest : (Array u8 32) (tli-read-digest! (&mut rd))]
          [index-digest : (Array u8 32) (tli-read-digest! (&mut rd))]
          (cond
            [(> total length)
              (tli-fail!
                (&mut rd)
                cursor.error-truncated
                "TLI file is shorter than its header declares")]
            [(< total 0)
              (tli-fail!
                (&mut rd)
                tli-error-offset
                "TLI file length exceeds supported range")]
            [(< total length)
              (tli-fail!
                (&mut rd)
                tli-error-trailing
                "TLI file exceeds its declared length")]
            [(or (not (= ir-start 0)) (not (= ir-size 0)))
              (tli-fail!
                (&mut rd)
                tli-error-offset
                "TLI v2 reserves the compact IR range")]
            [(> count tli-max-count)
              (tli-fail!
                (&mut rd)
                tli-error-limit
                "TLI module count limit exceeded")]
            [(not (= dir-size (* count tli.tli-directory-entry-size)))
              (tli-fail!
                (&mut rd)
                tli-error-offset
                "TLI directory length disagrees with module count")]
            [else unit])
          (tli-check-section!
            (&mut rd)
            pool-start
            pool-size
            tli.tli-header-size)
          (when
            rd.cursor.ok?
            (tli-check-section!
              (&mut rd)
              dir-start
              dir-size
              (+ pool-start pool-size)))
          (when
            (not rd.cursor.ok?)
            (return (TliDirectoryResult.Err (tli-read-error (& rd) 0))))
          (unless
            (tli-digest-eq?
              (& index-digest)
              (& (tli-index-digest (& rd.cursor.bytes) (+ dir-start dir-size))))
            (tli-fail! (&mut rd) tli-error-digest "TLI index SHA-256 mismatch")
            (return (TliDirectoryResult.Err (tli-read-error (& rd) 0))))
          (when
            verify-content-digest?
            (let
              [computed : (Array u8 32)
                (tli-content-digest (& rd.cursor.bytes))]
              (when
                (not (tli-digest-eq? (& digest) (& computed)))
                (tli-fail!
                  (&mut rd)
                  tli-error-digest
                  "TLI content SHA-256 mismatch")
                (return (TliDirectoryResult.Err (tli-read-error (& rd) 0))))))
          (set! rd.cursor.offset pool-start)
          (set! rd.cursor.end (+ pool-start pool-size))
          (let
            [pool : TliPool
              (if verify-content-digest?
                (tli-read-pool! (&mut rd))
                (tli-read-pool-lazy! (&mut rd)))]
            (when
              (not rd.cursor.ok?)
              (return (TliDirectoryResult.Err (tli-read-error (& rd) 0))))
            (set! rd.cursor.offset 72)
            (set! rd.cursor.end 80)
            (let
              [build : String (tli-read-name! (&mut rd) (& pool))]
              [target : String (tli-read-name! (&mut rd) (& pool))]
              [record-start : i64 (+ dir-start dir-size)]
              (set! rd.cursor.offset dir-start)
              (set! rd.cursor.end record-start)
              (let
                [entries : (__tl_dyn-array tli.TliDirectoryEntry)
                  (tli-read-entries! (&mut rd) (& pool) count record-start)]
                (if rd.cursor.ok?
                  (TliDirectoryResult.Ok
                    (TliDirectory
                      version
                      flags
                      build
                      target
                      digest
                      entries
                      pool
                      rd.cursor.bytes
                      rd.owned-bytes))
                  (TliDirectoryResult.Err (tli-read-error (& rd) 0)))))))))))

(define (tli-decode-directory [bytes : (& bytes (__tl_dyn-array u8))]) : TliDirectoryResult
  (tli-decode-directory-inner bytes true))

(define (tli-decode-directory-for-inner
  [bytes : (& bytes (__tl_dyn-array u8))]
  [expected-build : (& expected-build str)]
  [expected-target : (& expected-target str)]
  [verify-content-digest? : bool]) : TliDirectoryResult
  (match (tli-decode-directory-inner bytes verify-content-digest?)
    [(TliDirectoryResult.Err error) (TliDirectoryResult.Err error)]
    [(TliDirectoryResult.Ok directory)
      (cond
        [(not (string.eq (& directory.compiler-build) expected-build))
          (TliDirectoryResult.Err
            (tli.TliDecodeFailure
              (tli.TliDecodeError.CompilerBuildMismatch)
              72
              "TLI compiler build mismatch"))]
        [(not (string.eq (& directory.target-triple) expected-target))
          (TliDirectoryResult.Err
            (tli.TliDecodeFailure
              (tli.TliDecodeError.TargetMismatch)
              76
              "TLI target mismatch"))]
        [else (TliDirectoryResult.Ok directory)])]))

(define (tli-decode-directory-for
  [bytes : (& bytes (__tl_dyn-array u8))]
  [expected-build : (& expected-build str)]
  [expected-target : (& expected-target str)]) : TliDirectoryResult
  (tli-decode-directory-for-inner bytes expected-build expected-target true))

;; Lazy open for compiler-job hydration: skips hashing unhydrated module bytes
;; and decoding unused pool strings up front. Every string a record uses is
;; validated as UTF-8 and charged when it is read, and every hydrated module
;; verifies its exact per-module SHA-256 and import interface SHA-256.
(define (tli-decode-directory-for-lazy
  [bytes : (& bytes (__tl_dyn-array u8))]
  [expected-build : (& expected-build str)]
  [expected-target : (& expected-target str)]) : TliDirectoryResult
  (tli-decode-directory-for-inner bytes expected-build expected-target false))

(define (tli-read-record!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [entry : (& entry tli.TliDirectoryEntry)]) : tli.TliModuleRecord
  (let
    [name : String (tli-read-name! rd pool)]
    [source : String (tli-read-name! rd pool)]
    [source-hash : (Array u8 32) (tli-read-digest! rd)]
    [cfg-hash : (Array u8 32) (tli-read-digest! rd)]
    [flags : i64 (tli-read-flags! rd 31)]
    (when
      (not (and (= flags entry.flags) (string.eq (& name) (& entry.name))))
      (tli-fail!
        rd
        tli-error-tag
        "TLI record name or flags disagree with its directory entry"))
    (tli.TliModuleRecord
      name
      source
      source-hash
      cfg-hash
      flags
      (tli-read-imports! rd pool)
      (tli-read-names! rd pool)
      (tli-read-type-decls! rd pool)
      (tli-read-fn-decls! rd pool)
      (tli-read-value-decls! rd pool)
      (tli-read-macro-handles! rd pool)
      (tli-read-dispatches! rd pool))))

(defenum TliBudgetedModuleResult
  (Ok tli.TliModuleRecord i64)
  (Err tli.TliDecodeFailure))

(define (tli-decode-record-at
  [directory : (& directory TliDirectory)]
  [index : i64]
  [owned-bytes : i64]) : TliBudgetedModuleResult
  (when
    (or (< index 0) (>= index (array-length directory.entries)))
    (return
      (TliBudgetedModuleResult.Err
        (tli.TliDecodeFailure
          (tli.TliDecodeError.OffsetOutOfRange)
          0
          "TLI module index is out of range"))))
  (let
    [entry (& (array-ref directory.entries index))]
    [start : i64 entry.record-offset]
    [length : i64 entry.record-len]
    (cond
      [(not (cursor.range-present? (array-length directory.bytes) start length))
        (TliBudgetedModuleResult.Err
          (tli.TliDecodeFailure
            (tli.TliDecodeError.OffsetOutOfRange)
            start
            "TLI record lies outside the file"))]
      [(> length (- tli-max-owned-bytes owned-bytes))
        (TliBudgetedModuleResult.Err
          (tli.TliDecodeFailure
            (tli.TliDecodeError.Limit)
            start
            "TLI owned-byte limit exceeded"))]
      [else
        (let
          [computed : (Array u8 32)
            (tli-module-digest (& directory.bytes) start length)]
          (when
            (not (tli-digest-eq? (& computed) (& entry.module-sha256)))
            (return
              (TliBudgetedModuleResult.Err
                (tli.TliDecodeFailure
                  (tli.TliDecodeError.DigestMismatch)
                  start
                  "TLI module SHA-256 mismatch"))))
          (let
            [record-bytes : (__tl_dyn-array u8) (__tl_make-array u8 length)]
            (for [i (iterator.range 0 length)]
              (set!
                (array-ref record-bytes i)
                (array-ref directory.bytes (+ start i))))
            (let
              [rd : binary.CompilerIncrementalBinaryReader
                (binary.CompilerIncrementalBinaryReader
                  (cursor.new record-bytes tli-max-work)
                  (+ owned-bytes length)
                  tli-max-owned-bytes
                  tli-max-string-bytes)]
              [record : tli.TliModuleRecord
                (tli-read-record! (&mut rd) (& directory.pool) entry)]
              (tli-check-end! (&mut rd))
              (if rd.cursor.ok?
                (TliBudgetedModuleResult.Ok record rd.owned-bytes)
                (TliBudgetedModuleResult.Err (tli-read-error (& rd) start))))))])))

(define (tli-decode-module-at
  [directory : (& directory TliDirectory)]
  [index : i64]) : TliModuleResult
  (match (tli-decode-record-at directory index directory.owned-bytes)
    [(TliBudgetedModuleResult.Ok record _) (TliModuleResult.Ok record)]
    [(TliBudgetedModuleResult.Err error) (TliModuleResult.Err error)]))

(define (tli-decode-module-at-for
  [directory : (& directory TliDirectory)]
  [index : i64]
  [expected-cfg : (& expected-cfg (Array u8 32))]) : TliModuleResult
  (match (tli-decode-module-at directory index)
    [(TliModuleResult.Err error) (TliModuleResult.Err error)]
    [(TliModuleResult.Ok record)
      (if (tli-digest-eq? (& record.cfg-fingerprint-sha256) expected-cfg)
        (TliModuleResult.Ok record)
        (let
          [entry (& (array-ref directory.entries index))]
          (TliModuleResult.Err
            (tli.TliDecodeFailure
              (tli.TliDecodeError.CfgFingerprintMismatch)
              (+ entry.record-offset 40)
              "TLI configuration fingerprint mismatch"))))]))

(define (tli-decode-bundle [bytes : (& bytes (__tl_dyn-array u8))]) : TliBundleResult
  (match (tli-decode-directory bytes)
    [(TliDirectoryResult.Err error) (TliBundleResult.Err error)]
    [(TliDirectoryResult.Ok directory)
      (let
        [count : i64 (array-length directory.entries)]
        [owned : i64
          (+
            directory.owned-bytes
            16
            (* count (comptime (size-of (type tli.TliModuleRecord)))))]
        (when
          (> owned tli-max-owned-bytes)
          (return
            (TliBundleResult.Err
              (tli.TliDecodeFailure
                (tli.TliDecodeError.Limit)
                0
                "TLI owned-byte limit exceeded"))))
        (let
          [modules : (__tl_dyn-array tli.TliModuleRecord)
            (__tl_make-array tli.TliModuleRecord count)]
          (for [index (iterator.range 0 count)]
            (match (tli-decode-record-at (& directory) index owned)
              [(TliBudgetedModuleResult.Err error)
                (return (TliBundleResult.Err error))]
              [(TliBudgetedModuleResult.Ok record used)
                (set! (array-ref modules index) record)
                (set! owned used)]))
          (TliBundleResult.Ok
            (tli.TliBundle
              directory.flags
              directory.compiler-build
              directory.target-triple
              modules))))]))