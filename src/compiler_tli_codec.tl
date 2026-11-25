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

(defstruct TliCompactBodyMeta
  (module-name String)
  (fn-name String)
  (link-symbol String)
  (offset i64)
  (length i64)
  (sha256 (Array u8 32)))

(defstruct TliWriteContext
  (collecting? bool)
  (pool strings.Vec)
  (out buf.ByteBufBuilder)
  (body-metas (__tl_dyn-array TliCompactBodyMeta)))

(define (tli-body-meta-less?
  [a-mod : (& str)]
  [a-fn : (& str)]
  [a-sym : (& str)]
  [b-mod : (& str)]
  [b-fn : (& str)]
  [b-sym : (& str)]) : bool
  (cond
    [(not (string.eq a-mod b-mod)) (sort.string-less-borrowed? a-mod b-mod)]
    [(not (string.eq a-fn b-fn)) (sort.string-less-borrowed? a-fn b-fn)]
    [else (sort.string-less-borrowed? a-sym b-sym)]))

(define (tli-find-body-meta
  [metas : (& metas (__tl_dyn-array TliCompactBodyMeta))]
  [module-name : (& str)]
  [fn-name : (& str)]
  [link-symbol : (& str)]) : i64
  (let
    [low : i64 0]
    [high : i64 (array-length metas)]
    (while (< low high)
      (let
        [mid : i64 (+ low (/ (- high low) 2))]
        [row (& (array-ref metas mid))]
        (cond
          [(and
              (string.eq (& row.module-name) module-name)
              (string.eq (& row.fn-name) fn-name)
              (string.eq (& row.link-symbol) link-symbol))
            (return mid)]
          [(tli-body-meta-less?
              (& row.module-name)
              (& row.fn-name)
              (& row.link-symbol)
              module-name
              fn-name
              link-symbol)
            (set! low (+ mid 1))]
          [else (set! high mid)])))
    -1))

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
  [module-name : (& str)]
  [fn-name : (& str)]
  [link-symbol : (& str)]
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
  (tli-write-u64! ctx row.call-memory)
  (tli-write-u8! ctx (cast row.call-clean : i64))
  (tli-write-u64! ctx row.return-alias)
  (let
    [meta-idx : i64
      (if ctx.collecting?
        -1
        (tli-find-body-meta (& ctx.body-metas) module-name fn-name link-symbol))]
    (if (>= meta-idx 0)
      (let
        [offset : i64 (array-ref ctx.body-metas meta-idx).offset]
        [length : i64 (array-ref ctx.body-metas meta-idx).length]
        [digest : (Array u8 32) (make-array u8 32)]
        (for [i (iterator.range 0 32)]
          (set!
            (array-ref digest i)
            (array-ref (array-ref ctx.body-metas meta-idx).sha256 i)))
        (tli-write-u64! ctx offset)
        (tli-write-u32! ctx length)
        (tli-write-digest! ctx (& digest)))
      (begin
        (tli-write-u64! ctx row.inline-ir-offset)
        (tli-write-u32! ctx row.inline-ir-len)
        (tli-write-digest! ctx (& row.inline-ir-sha256))))))

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
  (tli-write-summary!
    ctx
    (& row.module-name)
    (& row.name)
    (& row.link-symbol)
    (& row.summary)))

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

(define (tli-write-compact-value!
  [ctx : (&mut ctx TliWriteContext)]
  [val : (& val tli.TliCompactValue)]) : unit
  (match val
    [(tli.TliCompactValue.Var id)
      (tli-write-u8! ctx 0)
      (tli-write-u32! ctx id)]
    [(tli.TliCompactValue.Global sym)
      (tli-write-u8! ctx 1)
      (tli-write-name! ctx sym)]
    [(tli.TliCompactValue.GlobalAddr sym)
      (tli-write-u8! ctx 2)
      (tli-write-name! ctx sym)]
    [(tli.TliCompactValue.Function sym)
      (tli-write-u8! ctx 3)
      (tli-write-name! ctx sym)]
    [(tli.TliCompactValue.I64 n)
      (tli-write-u8! ctx 4)
      (tli-write-u64! ctx n)]
    [(tli.TliCompactValue.F64Bits bits)
      (tli-write-u8! ctx 5)
      (tli-write-u64! ctx bits)]
    [(tli.TliCompactValue.Bool b)
      (tli-write-u8! ctx 6)
      (tli-write-bool! ctx b)]
    [(tli.TliCompactValue.Char c)
      (tli-write-u8! ctx 7)
      (tli-write-u32! ctx c)]
    [(tli.TliCompactValue.String s)
      (tli-write-u8! ctx 8)
      (tli-write-name! ctx s)]
    [(tli.TliCompactValue.Bytes raw)
      (tli-write-u8! ctx 9)
      (tli-write-u32! ctx (array-length raw))
      (when
        (not ctx.collecting?)
        (buf.byte-buf-builder-append-array (&mut ctx.out) raw))]
    [(tli.TliCompactValue.Unit) (tli-write-u8! ctx 10)]
    [(tli.TliCompactValue.StaticArray raw)
      (tli-write-u8! ctx 11)
      (tli-write-u32! ctx (array-length raw))
      (when
        (not ctx.collecting?)
        (buf.byte-buf-builder-append-array (&mut ctx.out) raw))]))

(define (tli-write-compact-values!
  [ctx : (&mut ctx TliWriteContext)]
  [items : (& items (__tl_dyn-array tli.TliCompactValue))]) : unit
  (tli-write-u32! ctx (array-length items))
  (for [index (iterator.range 0 (array-length items))]
    (tli-write-compact-value! ctx (& (array-ref items index)))))

(define (tli-write-compact-call-args!
  [ctx : (&mut ctx TliWriteContext)]
  [args : (& args tli.TliCompactCallArgs)]) : unit
  (if (>= args.sret-index 0)
    (begin
      (tli-write-u8! ctx 1)
      (tli-write-u32! ctx args.sret-index))
    (tli-write-u8! ctx 0))
  (tli-write-compact-values! ctx (& args.args)))

(define (tli-write-compact-binop!
  [ctx : (&mut ctx TliWriteContext)]
  [op : (& op tli.TliCompactBinOp)]) : unit
  (match op
    [(tli.TliCompactBinOp.Add) (tli-write-u8! ctx 0)]
    [(tli.TliCompactBinOp.Sub) (tli-write-u8! ctx 1)]
    [(tli.TliCompactBinOp.Mul) (tli-write-u8! ctx 2)]
    [(tli.TliCompactBinOp.Div) (tli-write-u8! ctx 3)]
    [(tli.TliCompactBinOp.Mod) (tli-write-u8! ctx 4)]
    [(tli.TliCompactBinOp.SafeDiv) (tli-write-u8! ctx 5)]
    [(tli.TliCompactBinOp.SafeMod) (tli-write-u8! ctx 6)]
    [(tli.TliCompactBinOp.Eq) (tli-write-u8! ctx 7)]
    [(tli.TliCompactBinOp.Ne) (tli-write-u8! ctx 8)]
    [(tli.TliCompactBinOp.Lt) (tli-write-u8! ctx 9)]
    [(tli.TliCompactBinOp.Le) (tli-write-u8! ctx 10)]
    [(tli.TliCompactBinOp.Gt) (tli-write-u8! ctx 11)]
    [(tli.TliCompactBinOp.Ge) (tli-write-u8! ctx 12)]
    [(tli.TliCompactBinOp.BitTestEq) (tli-write-u8! ctx 13)]
    [(tli.TliCompactBinOp.BitTestNe) (tli-write-u8! ctx 14)]
    [(tli.TliCompactBinOp.And) (tli-write-u8! ctx 15)]
    [(tli.TliCompactBinOp.Or) (tli-write-u8! ctx 16)]
    [(tli.TliCompactBinOp.BitAnd) (tli-write-u8! ctx 17)]
    [(tli.TliCompactBinOp.BitOr) (tli-write-u8! ctx 18)]
    [(tli.TliCompactBinOp.BitXor) (tli-write-u8! ctx 19)]
    [(tli.TliCompactBinOp.Shl ty)
      (tli-write-u8! ctx 20)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactBinOp.Shr ty)
      (tli-write-u8! ctx 21)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactBinOp.Rotr) (tli-write-u8! ctx 22)]))

(define (tli-write-compact-unop!
  [ctx : (&mut ctx TliWriteContext)]
  [op : (& op tli.TliCompactUnOp)]) : unit
  (match op
    [(tli.TliCompactUnOp.Neg) (tli-write-u8! ctx 0)]
    [(tli.TliCompactUnOp.Not) (tli-write-u8! ctx 1)]
    [(tli.TliCompactUnOp.BitNot) (tli-write-u8! ctx 2)]
    [(tli.TliCompactUnOp.Sqrt) (tli-write-u8! ctx 3)]
    [(tli.TliCompactUnOp.BitLength) (tli-write-u8! ctx 4)]))

(define (tli-write-compact-instr!
  [ctx : (&mut ctx TliWriteContext)]
  [instr : (& instr tli.TliCompactInstr)]) : unit
  (match instr
    [(tli.TliCompactInstr.Mov dst val ty)
      (tli-write-u8! ctx 0)
      (tli-write-u32! ctx dst)
      (tli-write-compact-value! ctx val)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.Alloc dst ty)
      (tli-write-u8! ctx 1)
      (tli-write-u32! ctx dst)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.AddrOf dst src size)
      (tli-write-u8! ctx 2)
      (tli-write-u32! ctx dst)
      (tli-write-u32! ctx src)
      (tli-write-u64! ctx size)]
    [(tli.TliCompactInstr.Gep dst base idx ty)
      (tli-write-u8! ctx 3)
      (tli-write-u32! ctx dst)
      (tli-write-compact-value! ctx base)
      (tli-write-compact-value! ctx idx)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.Load dst ptr ty)
      (tli-write-u8! ctx 4)
      (tli-write-u32! ctx dst)
      (tli-write-compact-value! ctx ptr)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.StoreOwned ptr val ty)
      (tli-write-u8! ctx 5)
      (tli-write-compact-value! ctx ptr)
      (tli-write-compact-value! ctx val)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.StorePtr ptr val ty)
      (tli-write-u8! ctx 6)
      (tli-write-compact-value! ctx ptr)
      (tli-write-compact-value! ctx val)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.CopyBytes dst src size)
      (tli-write-u8! ctx 7)
      (tli-write-compact-value! ctx dst)
      (tli-write-compact-value! ctx src)
      (tli-write-u64! ctx size)]
    [(tli.TliCompactInstr.BoundsCheck idx len ok-label)
      (tli-write-u8! ctx 8)
      (tli-write-compact-value! ctx idx)
      (tli-write-compact-value! ctx len)
      (tli-write-u32! ctx ok-label)]
    [(tli.TliCompactInstr.Cast dst val from-ty to-ty)
      (tli-write-u8! ctx 9)
      (tli-write-u32! ctx dst)
      (tli-write-compact-value! ctx val)
      (tli-write-type! ctx from-ty)
      (tli-write-type! ctx to-ty)]
    [(tli.TliCompactInstr.Bitcast dst val from-ty to-ty)
      (tli-write-u8! ctx 10)
      (tli-write-u32! ctx dst)
      (tli-write-compact-value! ctx val)
      (tli-write-type! ctx from-ty)
      (tli-write-type! ctx to-ty)]
    [(tli.TliCompactInstr.BinOp dst op lhs rhs ty)
      (tli-write-u8! ctx 11)
      (tli-write-u32! ctx dst)
      (tli-write-compact-binop! ctx op)
      (tli-write-compact-value! ctx lhs)
      (tli-write-compact-value! ctx rhs)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.UnOp dst op val ty)
      (tli-write-u8! ctx 12)
      (tli-write-u32! ctx dst)
      (tli-write-compact-unop! ctx op)
      (tli-write-compact-value! ctx val)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.Call dst callee args ty)
      (tli-write-u8! ctx 13)
      (tli-write-u32! ctx dst)
      (tli-write-name! ctx callee)
      (tli-write-compact-call-args! ctx args)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.CallIndirect dst callee args ty)
      (tli-write-u8! ctx 14)
      (tli-write-u32! ctx dst)
      (tli-write-compact-value! ctx callee)
      (tli-write-compact-call-args! ctx args)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.CallIndirectC dst callee args ty)
      (tli-write-u8! ctx 15)
      (tli-write-u32! ctx dst)
      (tli-write-compact-value! ctx callee)
      (tli-write-compact-call-args! ctx args)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.TailCall callee args ty)
      (tli-write-u8! ctx 16)
      (tli-write-name! ctx callee)
      (tli-write-compact-call-args! ctx args)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.Store sym val ty)
      (tli-write-u8! ctx 17)
      (tli-write-name! ctx sym)
      (tli-write-compact-value! ctx val)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.Jump label)
      (tli-write-u8! ctx 18)
      (tli-write-u32! ctx label)]
    [(tli.TliCompactInstr.Branch cond t-label f-label)
      (tli-write-u8! ctx 19)
      (tli-write-compact-value! ctx cond)
      (tli-write-u32! ctx t-label)
      (tli-write-u32! ctx f-label)]
    [(tli.TliCompactInstr.TotalEnumBranch cond t-label f-label)
      (tli-write-u8! ctx 20)
      (tli-write-compact-value! ctx cond)
      (tli-write-u32! ctx t-label)
      (tli-write-u32! ctx f-label)]
    [(tli.TliCompactInstr.Return has-val val)
      (tli-write-u8! ctx 21)
      (tli-write-bool! ctx has-val)
      (when has-val (tli-write-compact-value! ctx val))]
    [(tli.TliCompactInstr.Phi dst inputs ty)
      (tli-write-u8! ctx 22)
      (tli-write-u32! ctx dst)
      (tli-write-u32! ctx (array-length inputs))
      (for [i (iterator.range 0 (array-length inputs))]
        (let
          [inp (& (array-ref inputs i))]
          (tli-write-compact-value! ctx (& inp.value))
          (tli-write-u32! ctx inp.label)))
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.Pack dst vals ty)
      (tli-write-u8! ctx 23)
      (tli-write-u32! ctx dst)
      (tli-write-compact-values! ctx vals)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.Word dst val idx ty)
      (tli-write-u8! ctx 24)
      (tli-write-u32! ctx dst)
      (tli-write-compact-value! ctx val)
      (tli-write-u32! ctx idx)
      (tli-write-type! ctx ty)]
    [(tli.TliCompactInstr.Switch val base cases def-label)
      (tli-write-u8! ctx 25)
      (tli-write-compact-value! ctx val)
      (tli-write-u64! ctx base)
      (tli-write-u32! ctx (array-length cases))
      (for [i (iterator.range 0 (array-length cases))]
        (let
          [c (& (array-ref cases i))]
          (tli-write-u64! ctx c.value)
          (tli-write-u32! ctx c.label)))
      (tli-write-u32! ctx def-label)]
    [(tli.TliCompactInstr.TotalEnumSwitch val base cases def-label trap-label)
      (tli-write-u8! ctx 26)
      (tli-write-compact-value! ctx val)
      (tli-write-u64! ctx base)
      (tli-write-u32! ctx (array-length cases))
      (for [i (iterator.range 0 (array-length cases))]
        (let
          [c (& (array-ref cases i))]
          (tli-write-u64! ctx c.value)
          (tli-write-u32! ctx c.label)))
      (tli-write-u32! ctx def-label)
      (tli-write-u64! ctx trap-label)]))

(define (tli-write-compact-return-storage!
  [ctx : (&mut ctx TliWriteContext)]
  [rs : (& rs tli.TliCompactReturnStorage)]) : unit
  (match rs
    [(tli.TliCompactReturnStorage.None) (tli-write-u8! ctx 0)]
    [(tli.TliCompactReturnStorage.Some
      conv
      idx
      bytes
      align
      output
      phys-ret
      phys-params
      src-sig)
      (tli-write-u8! ctx 1)
      (tli-write-u8! ctx conv)
      (tli-write-u32! ctx idx)
      (tli-write-u64! ctx bytes)
      (tli-write-u64! ctx align)
      (tli-write-type! ctx output)
      (tli-write-type! ctx phys-ret)
      (tli-write-types! ctx phys-params)
      (tli-write-type! ctx src-sig)]))

(define (tli-write-compact-extern-ref!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliCompactExternRef)]) : unit
  (tli-write-name! ctx (& row.symbol))
  (tli-write-u8! ctx row.abi)
  (tli-write-name! ctx (& row.link-symbol))
  (tli-write-type! ctx (& row.ty))
  (tli-write-compact-return-storage! ctx (& row.return-storage)))

(define (tli-write-compact-ir-body!
  [ctx : (&mut ctx TliWriteContext)]
  [body : (& body tli.TliCompactIrBody)]) : unit
  (tli-write-u8! ctx body.ir-flags)
  (tli-write-u32! ctx body.instr-count)
  (tli-write-u32! ctx (array-length body.params))
  (for [i (iterator.range 0 (array-length body.params))]
    (let
      [p (& (array-ref body.params i))]
      (tli-write-name! ctx (& p.name))
      (tli-write-type! ctx (& p.ty))
      (tli-write-u32! ctx p.var-id)))
  (tli-write-type! ctx (& body.ret-type))
  (tli-write-u32! ctx body.next-var)
  (tli-write-compact-return-storage! ctx (& body.return-storage))
  (let
    [rcount : i64 (array-length body.extern-refs)]
    [order : keys.Vec
      (keys.with-capacity
        (if ctx.collecting?
          0
          rcount))]
    [starts : (__tl_dyn-array i64)
      (__tl_make-array
        i64
        (if ctx.collecting?
          0
          (+ rcount 1)))]
    (tli-write-u32! ctx rcount)
    (if ctx.collecting?
      (for [i (iterator.range 0 rcount)]
        (tli-write-compact-extern-ref! ctx (& (array-ref body.extern-refs i))))
      (begin
        (for [i (iterator.range 0 rcount)]
          (let
            [item (& (array-ref body.extern-refs i))]
            (keys.push-ref!
              (&mut order)
              (tli-order-key
                ctx
                (& item.symbol)
                item.abi
                (& item.link-symbol)
                i))))
        (key_sort.sort! (&mut order) tli-key-less?)
        (let
          [slots (keys.slots (& order))]
          (for [slot (iterator.range 0 rcount)]
            (let
              [key : TliOrderKey (array-ref slots slot)]
              (set! (array-ref starts slot) ctx.out.len)
              (tli-write-compact-extern-ref!
                ctx
                (& (array-ref body.extern-refs key.index)))))
          (set! (array-ref starts rcount) ctx.out.len)
          (tli-sort-tied-rows! (&mut ctx.out) slots (& starts) rcount)))))
  (tli-write-u32! ctx (array-length body.blocks))
  (for [bi (iterator.range 0 (array-length body.blocks))]
    (let
      [blk (& (array-ref body.blocks bi))]
      (tli-write-u32! ctx blk.label)
      (tli-write-u32! ctx (array-length blk.instrs))
      (for [ii (iterator.range 0 (array-length blk.instrs))]
        (tli-write-compact-instr! ctx (& (array-ref blk.instrs ii)))))))

(define (tli-write-spmd-literal!
  [ctx : (&mut ctx TliWriteContext)]
  [lit : (& lit tli.TliSpmdLiteral)]) : unit
  (match lit
    [(tli.TliSpmdLiteral.Int n text)
      (tli-write-u8! ctx 0)
      (tli-write-u64! ctx n)
      (tli-write-name! ctx text)]
    [(tli.TliSpmdLiteral.Float text)
      (tli-write-u8! ctx 1)
      (tli-write-name! ctx text)]
    [(tli.TliSpmdLiteral.Bool b)
      (tli-write-u8! ctx 2)
      (tli-write-bool! ctx b)]
    [(tli.TliSpmdLiteral.Char c)
      (tli-write-u8! ctx 3)
      (tli-write-u32! ctx c)]
    [(tli.TliSpmdLiteral.String s)
      (tli-write-u8! ctx 4)
      (tli-write-name! ctx s)]
    [(tli.TliSpmdLiteral.Unit) (tli-write-u8! ctx 5)]))

(define (tli-write-spmd-exprs!
  [ctx : (&mut ctx TliWriteContext)]
  [items : (& items (__tl_dyn-array tli.TliSpmdExpr))]) : unit
  (tli-write-u32! ctx (array-length items))
  (for [i (iterator.range 0 (array-length items))]
    (tli-write-spmd-expr! ctx (& (array-ref items i)))))

(define (tli-write-spmd-expr!
  [ctx : (&mut ctx TliWriteContext)]
  [expr : (& expr tli.TliSpmdExpr)]) : unit
  (match expr
    [(tli.TliSpmdExpr.Literal lit)
      (tli-write-u8! ctx 0)
      (tli-write-spmd-literal! ctx lit)]
    [(tli.TliSpmdExpr.Var name)
      (tli-write-u8! ctx 1)
      (tli-write-name! ctx name)]
    [(tli.TliSpmdExpr.Unary op inner)
      (tli-write-u8! ctx 2)
      (tli-write-u8! ctx op)
      (tli-write-spmd-expr! ctx (& (deref inner)))]
    [(tli.TliSpmdExpr.Binary op lhs rhs)
      (tli-write-u8! ctx 3)
      (tli-write-u8! ctx op)
      (tli-write-spmd-expr! ctx (& (deref lhs)))
      (tli-write-spmd-expr! ctx (& (deref rhs)))]
    [(tli.TliSpmdExpr.Call callee args)
      (tli-write-u8! ctx 4)
      (tli-write-spmd-expr! ctx (& (deref callee)))
      (tli-write-spmd-exprs! ctx args)]
    [(tli.TliSpmdExpr.If cond-e then-e else-e)
      (tli-write-u8! ctx 5)
      (tli-write-spmd-expr! ctx (& (deref cond-e)))
      (tli-write-spmd-expr! ctx (& (deref then-e)))
      (tli-write-spmd-expr! ctx (& (deref else-e)))]
    [(tli.TliSpmdExpr.Let bindings body)
      (tli-write-u8! ctx 6)
      (tli-write-u32! ctx (array-length bindings))
      (for [i (iterator.range 0 (array-length bindings))]
        (let
          [b (& (array-ref bindings i))]
          (tli-write-name! ctx (& b.name))
          (tli-write-bool! ctx b.has-type)
          (when b.has-type (tli-write-type! ctx (& b.ty)))
          (tli-write-spmd-expr! ctx (& (deref b.init)))))
      (tli-write-spmd-expr! ctx (& (deref body)))]
    [(tli.TliSpmdExpr.Begin items)
      (tli-write-u8! ctx 7)
      (tli-write-spmd-exprs! ctx items)]
    [(tli.TliSpmdExpr.Ann inner ty)
      (tli-write-u8! ctx 8)
      (tli-write-spmd-expr! ctx (& (deref inner)))
      (tli-write-type! ctx ty)]
    [(tli.TliSpmdExpr.Cast inner ty)
      (tli-write-u8! ctx 9)
      (tli-write-spmd-expr! ctx (& (deref inner)))
      (tli-write-type! ctx ty)]
    [(tli.TliSpmdExpr.ArrayRef base idx)
      (tli-write-u8! ctx 10)
      (tli-write-spmd-expr! ctx (& (deref base)))
      (tli-write-spmd-expr! ctx (& (deref idx)))]
    [(tli.TliSpmdExpr.ArraySet base idx val)
      (tli-write-u8! ctx 11)
      (tli-write-spmd-expr! ctx (& (deref base)))
      (tli-write-spmd-expr! ctx (& (deref idx)))
      (tli-write-spmd-expr! ctx (& (deref val)))]
    [(tli.TliSpmdExpr.StructGet base field)
      (tli-write-u8! ctx 12)
      (tli-write-spmd-expr! ctx (& (deref base)))
      (tli-write-name! ctx field)]
    [(tli.TliSpmdExpr.StructSet base field val)
      (tli-write-u8! ctx 13)
      (tli-write-spmd-expr! ctx (& (deref base)))
      (tli-write-name! ctx field)
      (tli-write-spmd-expr! ctx (& (deref val)))]
    [(tli.TliSpmdExpr.Tuple items)
      (tli-write-u8! ctx 14)
      (tli-write-spmd-exprs! ctx items)]
    [(tli.TliSpmdExpr.TupleRef base idx)
      (tli-write-u8! ctx 15)
      (tli-write-spmd-expr! ctx (& (deref base)))
      (tli-write-u32! ctx idx)]
    [(tli.TliSpmdExpr.Set place val)
      (tli-write-u8! ctx 16)
      (tli-write-spmd-expr! ctx (& (deref place)))
      (tli-write-spmd-expr! ctx (& (deref val)))]
    [(tli.TliSpmdExpr.Borrow is-mut life place)
      (tli-write-u8! ctx 17)
      (tli-write-bool! ctx is-mut)
      (tli-write-name! ctx life)
      (tli-write-spmd-expr! ctx (& (deref place)))]))

(define (tli-write-compact-body!
  [ctx : (&mut ctx TliWriteContext)]
  [body : (& body tli.TliCompactBody)]) : unit
  (tli-write-u8! ctx body.kind)
  (when
    (!= (bit-and body.kind tli.tli-compact-body-has-ir) 0)
    (tli-write-compact-ir-body! ctx (& body.ir-body)))
  (when
    (!= (bit-and body.kind tli.tli-compact-body-has-spmd-expr) 0)
    (tli-write-spmd-expr! ctx (& body.spmd-expr))))

(define (tli-write-compact-global!
  [ctx : (&mut ctx TliWriteContext)]
  [row : (& row tli.TliCompactGlobal)]) : unit
  (tli-write-name! ctx (& row.symbol))
  (tli-write-type! ctx (& row.ty))
  (tli-write-u8! ctx row.flags)
  (tli-write-compact-value! ctx (& row.init)))

(defstruct TliEncodedCompactIr
  (bytes (__tl_dyn-array u8))
  (metas (__tl_dyn-array TliCompactBodyMeta)))

(define (tli-bundle-has-compact-ir? [bundle : (& bundle tli.TliBundle)]) : bool
  (or
    (!= (bit-and bundle.flags tli.tli-has-compact-ir) 0)
    (> (array-length bundle.compact-globals) 0)
    (> (array-length bundle.compact-bodies) 0)))

(define (tli-encode-compact-ir-section
  [pool : (& pool strings.Vec)]
  [bundle : (& bundle tli.TliBundle)]) : TliEncodedCompactIr
  (if (not (tli-bundle-has-compact-ir? bundle))
    (TliEncodedCompactIr
      (__tl_make-array u8 0)
      (__tl_make-array TliCompactBodyMeta 0))
    (let
      [pool-copy : strings.Vec (strings.with-capacity (strings.len pool))]
      [pslots (strings.slots pool)]
      (for [i (iterator.range 0 (strings.len pool))]
        (strings.push-ref!
          (&mut pool-copy)
          (string.copy (& (array-ref pslots i)))))
      (let
        [ctx : TliWriteContext
          (TliWriteContext
            false
            pool-copy
            (buf.byte-buf-builder-new)
            (__tl_make-array TliCompactBodyMeta 0))]
        [gcount : i64 (array-length bundle.compact-globals)]
        [bcount : i64 (array-length bundle.compact-bodies)]
        [gorder : keys.Vec (keys.with-capacity gcount)]
        [gstarts : (__tl_dyn-array i64) (__tl_make-array i64 (+ gcount 1))]
        [border : keys.Vec (keys.with-capacity bcount)]
        [metas : (__tl_dyn-array TliCompactBodyMeta)
          (__tl_make-array TliCompactBodyMeta bcount)]
        ;; section_flags = 0
        (tli-write-u32! (&mut ctx) 0)
        (tli-write-u32! (&mut ctx) gcount)
        (for [i (iterator.range 0 gcount)]
          (let
            [item (& (array-ref bundle.compact-globals i))]
            (keys.push-ref!
              (&mut gorder)
              (tli-order-key (& ctx) (& item.symbol) 0 "" i))))
        (key_sort.sort! (&mut gorder) tli-key-less?)
        (let
          [gslots (keys.slots (& gorder))]
          (for [slot (iterator.range 0 gcount)]
            (let
              [key : TliOrderKey (array-ref gslots slot)]
              (set! (array-ref gstarts slot) ctx.out.len)
              (tli-write-compact-global!
                (&mut ctx)
                (& (array-ref bundle.compact-globals key.index)))))
          (set! (array-ref gstarts gcount) ctx.out.len)
          (tli-sort-tied-rows! (&mut ctx.out) gslots (& gstarts) gcount))
        (tli-write-u32! (&mut ctx) bcount)
        (for [i (iterator.range 0 bcount)]
          (let
            [entry (& (array-ref bundle.compact-bodies i))]
            (keys.push-ref!
              (&mut border)
              (tli-order-key
                (& ctx)
                (& entry.module-name)
                (tli-find-string (& ctx.pool) (& entry.fn-name))
                (& entry.link-symbol)
                i))))
        (key_sort.sort! (&mut border) tli-key-less?)
        (let
          [bslots (keys.slots (& border))]
          (for [slot (iterator.range 0 bcount)]
            (let
              [key : TliOrderKey (array-ref bslots slot)]
              [entry (& (array-ref bundle.compact-bodies key.index))]
              [start : i64 ctx.out.len]
              (tli-write-compact-body! (&mut ctx) (& entry.body))
              (let
                [length : i64 (- ctx.out.len start)]
                [digest : (Array u8 32)
                  (tli-module-digest (& ctx.out.slots) start length)]
                (set!
                  (array-ref metas slot)
                  (TliCompactBodyMeta
                    (string.copy (& entry.module-name))
                    (string.copy (& entry.fn-name))
                    (string.copy (& entry.link-symbol))
                    start
                    length
                    digest))))))
        (TliEncodedCompactIr
          (buf.byte-buf-builder-finish-array (& ctx.out))
          metas)))))

(define (tli-collect-pool [bundle : (& bundle tli.TliBundle)]) : strings.Vec
  (let
    [ctx : TliWriteContext
      (TliWriteContext
        true
        (strings.new)
        (buf.byte-buf-builder-new)
        (__tl_make-array TliCompactBodyMeta 0))]
    [pool : strings.Vec (strings.new)]
    (strings.push-ref! (&mut ctx.pool) "")
    (tli-write-name! (&mut ctx) (& bundle.compiler-build))
    (tli-write-name! (&mut ctx) (& bundle.target-triple))
    (for [index (iterator.range 0 (array-length bundle.modules))]
      (tli-write-module! (&mut ctx) (& (array-ref bundle.modules index))))
    (for [index (iterator.range 0 (array-length bundle.compact-globals))]
      (tli-write-compact-global!
        (&mut ctx)
        (& (array-ref bundle.compact-globals index))))
    (for [index (iterator.range 0 (array-length bundle.compact-bodies))]
      (tli-write-compact-body!
        (&mut ctx)
        (& (array-ref bundle.compact-bodies index).body)))
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
    [pool : strings.Vec (tli-collect-pool bundle)]
    [has-compact? : bool (tli-bundle-has-compact-ir? bundle)]
    [encoded-ir : TliEncodedCompactIr
      (tli-encode-compact-ir-section (& pool) bundle)]
    [bundle-flags : i64
      (if has-compact?
        (bit-or bundle.flags tli.tli-has-compact-ir)
        bundle.flags)]
    [ctx : TliWriteContext
      (TliWriteContext false pool (buf.byte-buf-builder-new) encoded-ir.metas)]
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
        [ir-offset : i64
          (if has-compact?
            ctx.out.len
            0)]
        [ir-len : i64 (array-length encoded-ir.bytes)]
        (when
          has-compact?
          (buf.byte-buf-builder-append-array
            (&mut ctx.out)
            (& encoded-ir.bytes)))
        (let
          [bytes : (__tl_dyn-array u8)
            (buf.byte-buf-builder-finish-array (& ctx.out))]
          (le.set-u32! (&mut bytes) 0 tli.tli-magic)
          (le.set-u32! (&mut bytes) 4 tli.tli-schema-version)
          (le.set-u32! (&mut bytes) 8 bundle-flags)
          (le.set-u32! (&mut bytes) 12 count)
          (le.set-u64! (&mut bytes) 16 (array-length bytes))
          (le.set-u64! (&mut bytes) 24 tli.tli-header-size)
          (le.set-u64! (&mut bytes) 32 (- dir-offset tli.tli-header-size))
          (le.set-u64! (&mut bytes) 40 dir-offset)
          (le.set-u64! (&mut bytes) 48 dir-len)
          (le.set-u64! (&mut bytes) 56 ir-offset)
          (le.set-u64! (&mut bytes) 64 ir-len)
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
            (tli-copy-digest!
              (&mut bytes)
              tli.tli-index-digest-offset
              (& index)))
          (let
            [digest : (Array u8 32) (tli-content-digest (& bytes))]
            (tli-copy-digest!
              (&mut bytes)
              tli.tli-content-digest-offset
              (& digest)))
          bytes)))))

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

(define (tli-zero-digest? [digest : (& digest (Array u8 32))]) : bool
  (for [i (iterator.range 0 32)]
    (when (!= (array-ref digest i) (cast 0 : u8)) (return false)))
  true)

(define (tli-read-summary-tail!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [effect-flags : i64]
  [compact-ir-len : i64]) : tli.TliFnSummary
  (let
    [mask : i64 (cursor.read-u64! (&mut rd.cursor))]
    [extra : (__tl_dyn-array i64) (tli-read-arena-extras! rd)]
    [writes : (__tl_dyn-array tli.TliGlobalWrite)
      (tli-read-global-writes! rd pool)]
    [call-memory : i64 (cursor.read-u64! (&mut rd.cursor))]
    [call-clean-raw : i64 (cursor.read-u8! (&mut rd.cursor))]
    [return-alias : i64 (cursor.read-u64! (&mut rd.cursor))]
    [offset : i64 (cursor.read-u64! (&mut rd.cursor))]
    [length : i64 (cursor.read-u32! (&mut rd.cursor))]
    [body-sha : (Array u8 32) (tli-read-digest! rd)]
    [has-body? : bool
      (!=
        (bit-and
          effect-flags
          (bit-or tli.tli-fn-has-inline-ir tli.tli-fn-spmd-inlineable))
        0)]
    (when
      (not (= call-clean-raw (bit-and call-clean-raw 15)))
      (tli-fail!
        rd
        tli-error-flags
        "TLI call-clean flags contain reserved bits"))
    (when
      (< return-alias 0)
      (tli-fail! rd tli-error-tag "TLI return-alias index is negative"))
    (if has-body?
      (when
        (or
          (< compact-ir-len 12)
          (< offset 12)
          (<= length 0)
          (not (cursor.range-present? compact-ir-len offset length)))
        (tli-fail!
          rd
          tli-error-offset
          "TLI inline IR slice lies outside compact IR section"))
      (when
        (or (!= offset 0) (!= length 0) (not (tli-zero-digest? (& body-sha))))
        (tli-fail!
          rd
          tli-error-offset
          "TLI function without inline IR flags carries inline IR metadata")))
    (tli.TliFnSummary
      effect-flags
      mask
      extra
      writes
      call-memory
      (cast call-clean-raw : u8)
      return-alias
      offset
      length
      body-sha)))

(define (tli-read-fn-decl!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [compact-ir-len : i64]) : tli.TliFnDecl
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
    [effect-flags : i64 (tli-read-flags! rd tli.tli-fn-effect-flags-mask)]
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
      (tli-read-summary-tail! rd pool effect-flags compact-ir-len))))

(define (tli-read-fn-decls!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [compact-ir-len : i64]) : (__tl_dyn-array tli.TliFnDecl)
  (let
    [count : i64
      (tli-read-count! rd 117 (comptime (size-of (type tli.TliFnDecl))))]
    [items : (__tl_dyn-array tli.TliFnDecl)
      (__tl_make-array tli.TliFnDecl count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-fn-decl! rd pool compact-ir-len))
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
  (compact-ir-offset i64)
  (compact-ir-len i64)
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

(defenum TliCompactGlobalsResult
  (Ok (__tl_dyn-array tli.TliCompactGlobal))
  (Err tli.TliDecodeFailure))

(defstruct TliCompactBodyHeader
  (kind i64)
  (ir-flags i64)
  (instr-count i64))

(defenum TliCompactBodyHeaderResult
  (Ok TliCompactBodyHeader)
  (Err tli.TliDecodeFailure))

(defenum TliCompactBodyResult
  (Ok tli.TliCompactBody)
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
  [records-start : i64]
  [records-end-expected : i64]) : (__tl_dyn-array tli.TliDirectoryEntry)
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
      (not (= record-end records-end-expected))
      (tli-fail!
        rd
        tli-error-trailing
        "TLI module records do not end where the next section begins"))
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
              (bit-or
                tli.tli-is-stdlib-bundle
                (bit-or tli.tli-has-compact-ir tli.tli-has-tlci-companion)))]
          [has-compact? : bool (!= (bit-and flags tli.tli-has-compact-ir) 0)]
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
            [(and
                (not has-compact?)
                (or (not (= ir-start 0)) (not (= ir-size 0))))
              (tli-fail!
                (&mut rd)
                tli-error-offset
                "TLI compact IR range must be zero when HAS_COMPACT_IR is clear")]
            [(and
                has-compact?
                (or
                  (< ir-size 12)
                  (not (cursor.range-present? length ir-start ir-size))
                  (!= (+ ir-start ir-size) length)))
              (tli-fail!
                (&mut rd)
                tli-error-offset
                "TLI compact IR section lies outside file or has trailing bytes")]
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
            (and rd.cursor.ok? has-compact? (< ir-start (+ dir-start dir-size)))
            (tli-fail!
              (&mut rd)
              tli-error-overlap
              "TLI compact IR section overlaps the module directory"))
          (when
            (not rd.cursor.ok?)
            (return (TliDirectoryResult.Err (tli-read-error (& rd) 0))))
          (when
            verify-content-digest?
            (unless
              (tli-digest-eq?
                (& index-digest)
                (&
                  (tli-index-digest (& rd.cursor.bytes) (+ dir-start dir-size))))
              (tli-fail!
                (&mut rd)
                tli-error-digest
                "TLI index SHA-256 mismatch")
              (return (TliDirectoryResult.Err (tli-read-error (& rd) 0))))
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
              [records-end-expected : i64
                (if has-compact?
                  ir-start
                  length)]
              (set! rd.cursor.offset dir-start)
              (set! rd.cursor.end record-start)
              (let
                [entries : (__tl_dyn-array tli.TliDirectoryEntry)
                  (tli-read-entries!
                    (&mut rd)
                    (& pool)
                    count
                    record-start
                    records-end-expected)]
                (if rd.cursor.ok?
                  (TliDirectoryResult.Ok
                    (TliDirectory
                      version
                      flags
                      build
                      target
                      digest
                      ir-start
                      ir-size
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

;; Lazy open for compiler-job hydration: skips up-front index and content
;; SHA-256 hashing and decoding unused pool strings. Header fields, section
;; bounds, every accessed pool string's UTF-8, every decoded module record's
;; `module_sha256` and import digests, and every decoded compact body's
;; `inline_ir_sha256` are verified fail-closed.
(define (tli-decode-directory-for-lazy
  [bytes : (& bytes (__tl_dyn-array u8))]
  [expected-build : (& expected-build str)]
  [expected-target : (& expected-target str)]) : TliDirectoryResult
  (tli-decode-directory-for-inner bytes expected-build expected-target false))

(define (tli-read-record!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [entry : (& entry tli.TliDirectoryEntry)]
  [compact-ir-len : i64]) : tli.TliModuleRecord
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
      (tli-read-fn-decls! rd pool compact-ir-len)
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
                (tli-read-record!
                  (&mut rd)
                  (& directory.pool)
                  entry
                  directory.compact-ir-len)]
              (tli-check-end! (&mut rd))
              (if rd.cursor.ok?
                (TliBudgetedModuleResult.Ok record rd.owned-bytes)
                (TliBudgetedModuleResult.Err (tli-read-error (& rd) start))))))])))

(define (tli-read-compact-value!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [allow-static-array? : bool]) : tli.TliCompactValue
  (let
    [max-tag : i64
      (if allow-static-array?
        11
        10)]
    [tag : i64 (tli-read-tag! rd max-tag)]
    (match tag
      [0 (tli.TliCompactValue.Var (cursor.read-u32! (&mut rd.cursor)))]
      [1 (tli.TliCompactValue.Global (tli-read-name! rd pool))]
      [2 (tli.TliCompactValue.GlobalAddr (tli-read-name! rd pool))]
      [3 (tli.TliCompactValue.Function (tli-read-name! rd pool))]
      [4 (tli.TliCompactValue.I64 (cursor.read-u64! (&mut rd.cursor)))]
      [5 (tli.TliCompactValue.F64Bits (cursor.read-u64! (&mut rd.cursor)))]
      [6 (tli.TliCompactValue.Bool (tli-read-bool! rd))]
      [7 (tli.TliCompactValue.Char (cursor.read-u32! (&mut rd.cursor)))]
      [8 (tli.TliCompactValue.String (tli-read-name! rd pool))]
      [9 (tli.TliCompactValue.Bytes (tli-read-blob! rd))]
      [10 (tli.TliCompactValue.Unit)]
      [11 (tli.TliCompactValue.StaticArray (tli-read-blob! rd))]
      [_ (tli.TliCompactValue.Unit)])))

(define (tli-read-compact-values!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : (__tl_dyn-array tli.TliCompactValue)
  (let
    [count : i64
      (tli-read-count! rd 1 (comptime (size-of (type tli.TliCompactValue))))]
    [items : (__tl_dyn-array tli.TliCompactValue)
      (__tl_make-array tli.TliCompactValue count)]
    [index : i64 0]
    (while (and rd.cursor.ok? (< index count))
      (set! (array-ref items index) (tli-read-compact-value! rd pool false))
      (+= index 1))
    items))

(define (tli-read-compact-call-args!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliCompactCallArgs
  (let
    [kind : i64 (tli-read-tag! rd 1)]
    [sret-index : i64
      (if (= kind 1)
        (cursor.read-u32! (&mut rd.cursor))
        -1)]
    [args : (__tl_dyn-array tli.TliCompactValue)
      (tli-read-compact-values! rd pool)]
    (when
      (and (= kind 1) (or (< sret-index 0) (>= sret-index (array-length args))))
      (tli-fail! rd tli-error-tag "TLI compact IR sret index is out of range"))
    (tli.TliCompactCallArgs args sret-index)))

(define (tli-read-compact-binop!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliCompactBinOp
  (match (tli-read-tag! rd 22)
    [0 (tli.TliCompactBinOp.Add)]
    [1 (tli.TliCompactBinOp.Sub)]
    [2 (tli.TliCompactBinOp.Mul)]
    [3 (tli.TliCompactBinOp.Div)]
    [4 (tli.TliCompactBinOp.Mod)]
    [5 (tli.TliCompactBinOp.SafeDiv)]
    [6 (tli.TliCompactBinOp.SafeMod)]
    [7 (tli.TliCompactBinOp.Eq)]
    [8 (tli.TliCompactBinOp.Ne)]
    [9 (tli.TliCompactBinOp.Lt)]
    [10 (tli.TliCompactBinOp.Le)]
    [11 (tli.TliCompactBinOp.Gt)]
    [12 (tli.TliCompactBinOp.Ge)]
    [13 (tli.TliCompactBinOp.BitTestEq)]
    [14 (tli.TliCompactBinOp.BitTestNe)]
    [15 (tli.TliCompactBinOp.And)]
    [16 (tli.TliCompactBinOp.Or)]
    [17 (tli.TliCompactBinOp.BitAnd)]
    [18 (tli.TliCompactBinOp.BitOr)]
    [19 (tli.TliCompactBinOp.BitXor)]
    [20 (tli.TliCompactBinOp.Shl (tli-read-type! rd pool false 1))]
    [21 (tli.TliCompactBinOp.Shr (tli-read-type! rd pool false 1))]
    [22 (tli.TliCompactBinOp.Rotr)]
    [_ (tli.TliCompactBinOp.Add)]))

(define (tli-read-compact-unop!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]) : tli.TliCompactUnOp
  (match (tli-read-tag! rd 4)
    [0 (tli.TliCompactUnOp.Neg)]
    [1 (tli.TliCompactUnOp.Not)]
    [2 (tli.TliCompactUnOp.BitNot)]
    [3 (tli.TliCompactUnOp.Sqrt)]
    [4 (tli.TliCompactUnOp.BitLength)]
    [_ (tli.TliCompactUnOp.Neg)]))

(define (tli-read-compact-phi-inputs!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : (__tl_dyn-array tli.TliCompactPhiInput)
  (let
    [count : i64
      (tli-read-count! rd 5 (comptime (size-of (type tli.TliCompactPhiInput))))]
    [items : (__tl_dyn-array tli.TliCompactPhiInput)
      (__tl_make-array tli.TliCompactPhiInput count)]
    [i : i64 0]
    (while (and rd.cursor.ok? (< i count))
      (let
        [val : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [lbl : i64 (cursor.read-u32! (&mut rd.cursor))]
        (set! (array-ref items i) (tli.TliCompactPhiInput val lbl)))
      (+= i 1))
    items))

(define (tli-read-compact-switch-cases!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]) : (__tl_dyn-array
    tli.TliCompactSwitchCase)
  (let
    [count : i64
      (tli-read-count!
        rd
        12
        (comptime (size-of (type tli.TliCompactSwitchCase))))]
    [items : (__tl_dyn-array tli.TliCompactSwitchCase)
      (__tl_make-array tli.TliCompactSwitchCase count)]
    [i : i64 0]
    (while (and rd.cursor.ok? (< i count))
      (let
        [val : i64 (cursor.read-u64! (&mut rd.cursor))]
        [lbl : i64 (cursor.read-u32! (&mut rd.cursor))]
        (set! (array-ref items i) (tli.TliCompactSwitchCase val lbl)))
      (+= i 1))
    items))

(define (tli-read-compact-instr!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliCompactInstr
  (match (tli-read-tag! rd 26)
    [0
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [val : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.Mov dst val ty))]
    [1
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.Alloc dst ty))]
    [2
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [src : i64 (cursor.read-u32! (&mut rd.cursor))]
        [size : i64 (cursor.read-u64! (&mut rd.cursor))]
        (tli.TliCompactInstr.AddrOf dst src size))]
    [3
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [base : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [idx : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.Gep dst base idx ty))]
    [4
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [ptr : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.Load dst ptr ty))]
    [5
      (let
        [ptr : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [val : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.StoreOwned ptr val ty))]
    [6
      (let
        [ptr : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [val : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.StorePtr ptr val ty))]
    [7
      (let
        [dst : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [src : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [size : i64 (cursor.read-u64! (&mut rd.cursor))]
        (tli.TliCompactInstr.CopyBytes dst src size))]
    [8
      (let
        [idx : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [len : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [ok-lbl : i64 (cursor.read-u32! (&mut rd.cursor))]
        (tli.TliCompactInstr.BoundsCheck idx len ok-lbl))]
    [9
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [val : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [from-ty : tli.TliType (tli-read-type! rd pool false 1)]
        [to-ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.Cast dst val from-ty to-ty))]
    [10
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [val : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [from-ty : tli.TliType (tli-read-type! rd pool false 1)]
        [to-ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.Bitcast dst val from-ty to-ty))]
    [11
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [op : tli.TliCompactBinOp (tli-read-compact-binop! rd pool)]
        [lhs : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [rhs : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.BinOp dst op lhs rhs ty))]
    [12
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [op : tli.TliCompactUnOp (tli-read-compact-unop! rd)]
        [val : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.UnOp dst op val ty))]
    [13
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [callee : String (tli-read-name! rd pool)]
        [args : tli.TliCompactCallArgs (tli-read-compact-call-args! rd pool)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.Call dst callee args ty))]
    [14
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [callee : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [args : tli.TliCompactCallArgs (tli-read-compact-call-args! rd pool)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.CallIndirect dst callee args ty))]
    [15
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [callee : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [args : tli.TliCompactCallArgs (tli-read-compact-call-args! rd pool)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.CallIndirectC dst callee args ty))]
    [16
      (let
        [callee : String (tli-read-name! rd pool)]
        [args : tli.TliCompactCallArgs (tli-read-compact-call-args! rd pool)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.TailCall callee args ty))]
    [17
      (let
        [sym : String (tli-read-name! rd pool)]
        [val : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.Store sym val ty))]
    [18 (tli.TliCompactInstr.Jump (cursor.read-u32! (&mut rd.cursor)))]
    [19
      (let
        [cond-v : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [t-lbl : i64 (cursor.read-u32! (&mut rd.cursor))]
        [f-lbl : i64 (cursor.read-u32! (&mut rd.cursor))]
        (tli.TliCompactInstr.Branch cond-v t-lbl f-lbl))]
    [20
      (let
        [cond-v : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [t-lbl : i64 (cursor.read-u32! (&mut rd.cursor))]
        [f-lbl : i64 (cursor.read-u32! (&mut rd.cursor))]
        (tli.TliCompactInstr.TotalEnumBranch cond-v t-lbl f-lbl))]
    [21
      (let
        [has-val : bool (tli-read-bool! rd)]
        [val : tli.TliCompactValue
          (if has-val
            (tli-read-compact-value! rd pool false)
            (tli.TliCompactValue.Unit))]
        (tli.TliCompactInstr.Return has-val val))]
    [22
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [inputs : (__tl_dyn-array tli.TliCompactPhiInput)
          (tli-read-compact-phi-inputs! rd pool)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.Phi dst inputs ty))]
    [23
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [vals : (__tl_dyn-array tli.TliCompactValue)
          (tli-read-compact-values! rd pool)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.Pack dst vals ty))]
    [24
      (let
        [dst : i64 (cursor.read-u32! (&mut rd.cursor))]
        [val : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [idx : i64 (cursor.read-u32! (&mut rd.cursor))]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactInstr.Word dst val idx ty))]
    [25
      (let
        [val : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [base : i64 (cursor.read-u64! (&mut rd.cursor))]
        [cases : (__tl_dyn-array tli.TliCompactSwitchCase)
          (tli-read-compact-switch-cases! rd)]
        [def-lbl : i64 (cursor.read-u32! (&mut rd.cursor))]
        (tli.TliCompactInstr.Switch val base cases def-lbl))]
    [26
      (let
        [val : tli.TliCompactValue (tli-read-compact-value! rd pool false)]
        [base : i64 (cursor.read-u64! (&mut rd.cursor))]
        [cases : (__tl_dyn-array tli.TliCompactSwitchCase)
          (tli-read-compact-switch-cases! rd)]
        [def-lbl : i64 (cursor.read-u32! (&mut rd.cursor))]
        [trap-lbl : i64 (cursor.read-u64! (&mut rd.cursor))]
        (tli.TliCompactInstr.TotalEnumSwitch val base cases def-lbl trap-lbl))]
    [_ (tli.TliCompactInstr.Jump 0)]))

(define (tli-read-compact-return-storage!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliCompactReturnStorage
  (match (tli-read-tag! rd 1)
    [0 (tli.TliCompactReturnStorage.None)]
    [1
      (let
        [conv : i64 (tli-read-tag! rd 3)]
        [idx : i64 (cursor.read-u32! (&mut rd.cursor))]
        [bytes : i64 (cursor.read-u64! (&mut rd.cursor))]
        [align : i64 (cursor.read-u64! (&mut rd.cursor))]
        [output : tli.TliType (tli-read-type! rd pool false 1)]
        [phys-ret : tli.TliType (tli-read-type! rd pool false 1)]
        [phys-params : (__tl_dyn-array tli.TliType)
          (tli-read-types! rd pool false 1)]
        [src-sig : tli.TliType (tli-read-type! rd pool false 1)]
        (tli.TliCompactReturnStorage.Some
          conv
          idx
          bytes
          align
          output
          phys-ret
          phys-params
          src-sig))]
    [_ (tli.TliCompactReturnStorage.None)]))

(define (tli-read-compact-extern-refs!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : (__tl_dyn-array tli.TliCompactExternRef)
  (let
    [count : i64
      (tli-read-count!
        rd
        11
        (comptime (size-of (type tli.TliCompactExternRef))))]
    [items : (__tl_dyn-array tli.TliCompactExternRef)
      (__tl_make-array tli.TliCompactExternRef count)]
    [i : i64 0]
    (while (and rd.cursor.ok? (< i count))
      (let
        [sym : String (tli-read-name! rd pool)]
        [abi : i64 (tli-read-tag! rd 3)]
        [link : String (tli-read-name! rd pool)]
        [ty : tli.TliType (tli-read-type! rd pool false 1)]
        [rs : tli.TliCompactReturnStorage
          (tli-read-compact-return-storage! rd pool)]
        (set! (array-ref items i) (tli.TliCompactExternRef sym abi link ty rs))
        (when
          (> i 0)
          (let
            [prev (& (array-ref items (- i 1)))]
            [cur (& (array-ref items i))]
            (tli-check-order!
              rd
              (& prev.symbol)
              prev.abi
              (& prev.link-symbol)
              (& cur.symbol)
              cur.abi
              (& cur.link-symbol)))))
      (+= i 1))
    items))

(define (tli-read-compact-ir-body!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliCompactIrBody
  (let
    [ir-flags : i64 (cursor.read-u8! (&mut rd.cursor))]
    [instr-count : i64 (cursor.read-u32! (&mut rd.cursor))]
    [pcount : i64
      (tli-read-count! rd 9 (comptime (size-of (type tli.TliCompactParam))))]
    [params : (__tl_dyn-array tli.TliCompactParam)
      (__tl_make-array tli.TliCompactParam pcount)]
    (when
      (not (= ir-flags (bit-and ir-flags tli.tli-compact-ir-call-free)))
      (tli-fail!
        rd
        tli-error-flags
        "TLI compact IR flags contain reserved bits"))
    (let
      [pi : i64 0]
      (while (and rd.cursor.ok? (< pi pcount))
        (let
          [pname : String (tli-read-name! rd pool)]
          [pty : tli.TliType (tli-read-type! rd pool false 1)]
          [pvar : i64 (cursor.read-u32! (&mut rd.cursor))]
          (set! (array-ref params pi) (tli.TliCompactParam pname pty pvar)))
        (+= pi 1)))
    (let
      [ret-ty : tli.TliType (tli-read-type! rd pool false 1)]
      [next-var : i64 (cursor.read-u32! (&mut rd.cursor))]
      [rs : tli.TliCompactReturnStorage
        (tli-read-compact-return-storage! rd pool)]
      [ext-refs : (__tl_dyn-array tli.TliCompactExternRef)
        (tli-read-compact-extern-refs! rd pool)]
      [bcount : i64
        (tli-read-count! rd 8 (comptime (size-of (type tli.TliCompactBlock))))]
      [blocks : (__tl_dyn-array tli.TliCompactBlock)
        (__tl_make-array tli.TliCompactBlock bcount)]
      [actual-instrs : i64 0]
      [bi : i64 0]
      (while (and rd.cursor.ok? (< bi bcount))
        (let
          [lbl : i64 (cursor.read-u32! (&mut rd.cursor))]
          [icount : i64
            (tli-read-count!
              rd
              1
              (comptime (size-of (type tli.TliCompactInstr))))]
          [instrs : (__tl_dyn-array tli.TliCompactInstr)
            (__tl_make-array tli.TliCompactInstr icount)]
          [ii : i64 0]
          (+= actual-instrs icount)
          (while (and rd.cursor.ok? (< ii icount))
            (set! (array-ref instrs ii) (tli-read-compact-instr! rd pool))
            (+= ii 1))
          (set! (array-ref blocks bi) (tli.TliCompactBlock lbl instrs)))
        (+= bi 1))
      (when
        (and rd.cursor.ok? (!= actual-instrs instr-count))
        (tli-fail!
          rd
          tli-error-tag
          "TLI compact IR instruction count disagrees with blocks"))
      (tli.TliCompactIrBody
        ir-flags
        instr-count
        params
        ret-ty
        next-var
        blocks
        rs
        ext-refs))))

(define (tli-read-spmd-literal!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliSpmdLiteral
  (match (tli-read-tag! rd 5)
    [0
      (let
        [n : i64 (cursor.read-u64! (&mut rd.cursor))]
        [text : String (tli-read-name! rd pool)]
        (tli.TliSpmdLiteral.Int n text))]
    [1 (tli.TliSpmdLiteral.Float (tli-read-name! rd pool))]
    [2 (tli.TliSpmdLiteral.Bool (tli-read-bool! rd))]
    [3 (tli.TliSpmdLiteral.Char (cursor.read-u32! (&mut rd.cursor)))]
    [4 (tli.TliSpmdLiteral.String (tli-read-name! rd pool))]
    [5 (tli.TliSpmdLiteral.Unit)]
    [_ (tli.TliSpmdLiteral.Unit)]))

(define (tli-read-spmd-exprs!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [depth : i64]) : (__tl_dyn-array tli.TliSpmdExpr)
  (let
    [count : i64
      (tli-read-count! rd 1 (comptime (size-of (type tli.TliSpmdExpr))))]
    [items : (__tl_dyn-array tli.TliSpmdExpr)
      (__tl_make-array tli.TliSpmdExpr count)]
    [i : i64 0]
    (while (and rd.cursor.ok? (< i count))
      (set! (array-ref items i) (tli-read-spmd-expr! rd pool depth))
      (+= i 1))
    items))

(define (tli-read-spmd-expr-box!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [depth : i64]) : (Box tli.TliSpmdExpr)
  (box (tli-read-spmd-expr! rd pool depth)))

(define (tli-read-spmd-expr!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]
  [depth : i64]) : tli.TliSpmdExpr
  (when
    (> depth tli.tli-max-spmd-expr-depth)
    (tli-fail! rd tli-error-limit "TLI SPMD expression nesting limit exceeded")
    (return (tli.tli-spmd-expr-empty)))
  (let
    [tag : i64 (tli-read-tag! rd 17)]
    [next : i64 (+ depth 1)]
    (when
      (and
        (>= tag 2)
        (not
          (tli-reserve! rd (+ 16 (comptime (size-of (type tli.TliSpmdExpr)))))))
      (return (tli.tli-spmd-expr-empty)))
    (match tag
      [0 (tli.TliSpmdExpr.Literal (tli-read-spmd-literal! rd pool))]
      [1 (tli.TliSpmdExpr.Var (tli-read-name! rd pool))]
      [2
        (let
          [op : i64 (tli-read-tag! rd 2)]
          (tli.TliSpmdExpr.Unary op (tli-read-spmd-expr-box! rd pool next)))]
      [3
        (let
          [op : i64 (tli-read-tag! rd 17)]
          [lhs : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          [rhs : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          (tli.TliSpmdExpr.Binary op lhs rhs))]
      [4
        (let
          [callee : (Box tli.TliSpmdExpr)
            (tli-read-spmd-expr-box! rd pool next)]
          [args : (__tl_dyn-array tli.TliSpmdExpr)
            (tli-read-spmd-exprs! rd pool next)]
          (tli.TliSpmdExpr.Call callee args))]
      [5
        (let
          [c : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          [t : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          [e : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          (tli.TliSpmdExpr.If c t e))]
      [6
        (let
          [bcount : i64
            (tli-read-count!
              rd
              6
              (comptime (size-of (type tli.TliSpmdLetBinding))))]
          [bindings : (__tl_dyn-array tli.TliSpmdLetBinding)
            (__tl_make-array tli.TliSpmdLetBinding bcount)]
          [i : i64 0]
          (while (and rd.cursor.ok? (< i bcount))
            (let
              [bname : String (tli-read-name! rd pool)]
              [has-ty : bool (tli-read-bool! rd)]
              [bty : tli.TliType
                (if has-ty
                  (tli-read-type! rd pool false 1)
                  (tli.TliType.Unit))]
              [binit : (Box tli.TliSpmdExpr)
                (tli-read-spmd-expr-box! rd pool next)]
              (set!
                (array-ref bindings i)
                (tli.TliSpmdLetBinding bname has-ty bty binit)))
            (+= i 1))
          (tli.TliSpmdExpr.Let bindings (tli-read-spmd-expr-box! rd pool next)))]
      [7 (tli.TliSpmdExpr.Begin (tli-read-spmd-exprs! rd pool next))]
      [8
        (let
          [inner : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          [ty : tli.TliType (tli-read-type! rd pool false 1)]
          (tli.TliSpmdExpr.Ann inner ty))]
      [9
        (let
          [inner : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          [ty : tli.TliType (tli-read-type! rd pool false 1)]
          (tli.TliSpmdExpr.Cast inner ty))]
      [10
        (let
          [base : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          [idx : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          (tli.TliSpmdExpr.ArrayRef base idx))]
      [11
        (let
          [base : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          [idx : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          [val : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          (tli.TliSpmdExpr.ArraySet base idx val))]
      [12
        (let
          [base : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          [field : String (tli-read-name! rd pool)]
          (tli.TliSpmdExpr.StructGet base field))]
      [13
        (let
          [base : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          [field : String (tli-read-name! rd pool)]
          [val : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          (tli.TliSpmdExpr.StructSet base field val))]
      [14 (tli.TliSpmdExpr.Tuple (tli-read-spmd-exprs! rd pool next))]
      [15
        (let
          [base : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          [idx : i64 (cursor.read-u32! (&mut rd.cursor))]
          (tli.TliSpmdExpr.TupleRef base idx))]
      [16
        (let
          [place : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          [val : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          (tli.TliSpmdExpr.Set place val))]
      [17
        (let
          [is-mut : bool (tli-read-bool! rd)]
          [life : String (tli-read-name! rd pool)]
          [place : (Box tli.TliSpmdExpr) (tli-read-spmd-expr-box! rd pool next)]
          (tli.TliSpmdExpr.Borrow is-mut life place))]
      [_ (tli.tli-spmd-expr-empty)])))

(define (tli-read-compact-body!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliCompactBody
  (let
    [kind : i64 (cursor.read-u8! (&mut rd.cursor))]
    (when
      (or (< kind 1) (> kind 3))
      (tli-fail! rd tli-error-tag "TLI compact body kind must be 1, 2, or 3")
      (return
        (tli.TliCompactBody
          0
          (tli.tli-compact-ir-body-empty)
          (tli.tli-spmd-expr-empty))))
    (let
      [ir-body : tli.TliCompactIrBody
        (if (!= (bit-and kind tli.tli-compact-body-has-ir) 0)
          (tli-read-compact-ir-body! rd pool)
          (tli.tli-compact-ir-body-empty))]
      [spmd-expr : tli.TliSpmdExpr
        (if (!= (bit-and kind tli.tli-compact-body-has-spmd-expr) 0)
          (tli-read-spmd-expr! rd pool 1)
          (tli.tli-spmd-expr-empty))]
      (tli.TliCompactBody kind ir-body spmd-expr))))

(define (tli-read-compact-global!
  [rd : (&mut rd binary.CompilerIncrementalBinaryReader)]
  [pool : (& pool TliPool)]) : tli.TliCompactGlobal
  (let
    [sym : String (tli-read-name! rd pool)]
    [ty : tli.TliType (tli-read-type! rd pool false 1)]
    [flags : i64 (cursor.read-u8! (&mut rd.cursor))]
    [init : tli.TliCompactValue (tli-read-compact-value! rd pool true)]
    (when
      (not (= flags (bit-and flags tli.tli-compact-global-never-written)))
      (tli-fail!
        rd
        tli-error-flags
        "TLI compact global flags contain reserved bits"))
    (when
      (match (& init)
        [(or (tli.TliCompactValue.I64 _) (tli.TliCompactValue.F64Bits _)
             (tli.TliCompactValue.Bool _) (tli.TliCompactValue.Char _)
             (tli.TliCompactValue.String _) (tli.TliCompactValue.Bytes _)
             (tli.TliCompactValue.Unit) (tli.TliCompactValue.StaticArray _))
          false]
        [_ true])
      (tli-fail!
        rd
        tli-error-tag
        "TLI compact global initializer must be literal"))
    (tli.TliCompactGlobal sym ty flags init)))

(define (tli-decode-compact-globals [directory : (& directory TliDirectory)]) : TliCompactGlobalsResult
  (when
    (= (bit-and directory.flags tli.tli-has-compact-ir) 0)
    (return
      (TliCompactGlobalsResult.Ok (__tl_make-array tli.TliCompactGlobal 0))))
  (let
    [start : i64 directory.compact-ir-offset]
    [length : i64 directory.compact-ir-len]
    (when
      (or
        (< length 12)
        (not
          (cursor.range-present? (array-length directory.bytes) start length)))
      (return
        (TliCompactGlobalsResult.Err
          (tli.TliDecodeFailure
            (tli.TliDecodeError.OffsetOutOfRange)
            start
            "TLI compact IR section is out of range"))))
    (let
      [sec-bytes : (__tl_dyn-array u8) (__tl_make-array u8 length)]
      (for [i (iterator.range 0 length)]
        (set! (array-ref sec-bytes i) (array-ref directory.bytes (+ start i))))
      (let
        [rd : binary.CompilerIncrementalBinaryReader
          (binary.CompilerIncrementalBinaryReader
            (cursor.new sec-bytes tli-max-work)
            directory.owned-bytes
            tli-max-owned-bytes
            tli-max-string-bytes)]
        [_sec-flags : i64 (tli-read-flags! (&mut rd) 0)]
        [gcount : i64
          (tli-read-count!
            (&mut rd)
            7
            (comptime (size-of (type tli.TliCompactGlobal))))]
        [items : (__tl_dyn-array tli.TliCompactGlobal)
          (__tl_make-array tli.TliCompactGlobal gcount)]
        [i : i64 0]
        (while (and rd.cursor.ok? (< i gcount))
          (set!
            (array-ref items i)
            (tli-read-compact-global! (&mut rd) (& directory.pool)))
          (when
            (> i 0)
            (let
              [prev (& (array-ref items (- i 1)))]
              [cur (& (array-ref items i))]
              (tli-check-order!
                (&mut rd)
                (& prev.symbol)
                0
                ""
                (& cur.symbol)
                0
                "")))
          (+= i 1))
        (cursor.read-u32! (&mut rd.cursor))
        (if rd.cursor.ok?
          (TliCompactGlobalsResult.Ok items)
          (TliCompactGlobalsResult.Err (tli-read-error (& rd) start)))))))

(define (tli-peek-compact-body-header
  [directory : (& directory TliDirectory)]
  [rel-offset : i64]
  [length : i64]
  [expected-sha : (& (Array u8 32))]) : TliCompactBodyHeaderResult
  (when
    (or
      (= (bit-and directory.flags tli.tli-has-compact-ir) 0)
      (< rel-offset 12)
      (<= length 0)
      (not (cursor.range-present? directory.compact-ir-len rel-offset length)))
    (return
      (TliCompactBodyHeaderResult.Err
        (tli.TliDecodeFailure
          (tli.TliDecodeError.OffsetOutOfRange)
          rel-offset
          "TLI compact body slice lies outside compact IR section"))))
  (let
    [abs-start : i64 (+ directory.compact-ir-offset rel-offset)]
    [computed : (Array u8 32)
      (tli-module-digest (& directory.bytes) abs-start length)]
    (unless
      (tli-digest-eq? (& computed) expected-sha)
      (return
        (TliCompactBodyHeaderResult.Err
          (tli.TliDecodeFailure
            (tli.TliDecodeError.DigestMismatch)
            abs-start
            "TLI compact body SHA-256 mismatch"))))
    (let
      [kind : i64 (cast (array-ref directory.bytes abs-start) : i64)]
      (when
        (or (< kind 1) (> kind 3))
        (return
          (TliCompactBodyHeaderResult.Err
            (tli.TliDecodeFailure
              (tli.TliDecodeError.UnknownTag)
              abs-start
              "TLI compact body kind must be 1, 2, or 3"))))
      (if (!= (bit-and kind tli.tli-compact-body-has-ir) 0)
        (if (< length 6)
          (TliCompactBodyHeaderResult.Err
            (tli.TliDecodeFailure
              (tli.TliDecodeError.Truncated)
              abs-start
              "TLI compact IR body header is truncated"))
          (let
            [ir-flags : i64
              (cast (array-ref directory.bytes (+ abs-start 1)) : i64)]
            [instr-count : i64
              (le.read-u32 (& directory.bytes) (+ abs-start 2))]
            (if (not
              (= ir-flags (bit-and ir-flags tli.tli-compact-ir-call-free)))
              (TliCompactBodyHeaderResult.Err
                (tli.TliDecodeFailure
                  (tli.TliDecodeError.Flags)
                  (+ abs-start 1)
                  "TLI compact IR flags contain reserved bits"))
              (TliCompactBodyHeaderResult.Ok
                (TliCompactBodyHeader kind ir-flags instr-count)))))
        (TliCompactBodyHeaderResult.Ok (TliCompactBodyHeader kind 0 0))))))

(define (tli-decode-compact-body-at
  [directory : (& directory TliDirectory)]
  [rel-offset : i64]
  [length : i64]
  [expected-sha : (& (Array u8 32))]) : TliCompactBodyResult
  (when
    (or
      (= (bit-and directory.flags tli.tli-has-compact-ir) 0)
      (< rel-offset 12)
      (<= length 0)
      (not (cursor.range-present? directory.compact-ir-len rel-offset length)))
    (return
      (TliCompactBodyResult.Err
        (tli.TliDecodeFailure
          (tli.TliDecodeError.OffsetOutOfRange)
          rel-offset
          "TLI compact body slice lies outside compact IR section"))))
  (let
    [abs-start : i64 (+ directory.compact-ir-offset rel-offset)]
    [computed : (Array u8 32)
      (tli-module-digest (& directory.bytes) abs-start length)]
    (unless
      (tli-digest-eq? (& computed) expected-sha)
      (return
        (TliCompactBodyResult.Err
          (tli.TliDecodeFailure
            (tli.TliDecodeError.DigestMismatch)
            abs-start
            "TLI compact body SHA-256 mismatch"))))
    (let
      [body-bytes : (__tl_dyn-array u8) (__tl_make-array u8 length)]
      (for [i (iterator.range 0 length)]
        (set!
          (array-ref body-bytes i)
          (array-ref directory.bytes (+ abs-start i))))
      (let
        [rd : binary.CompilerIncrementalBinaryReader
          (binary.CompilerIncrementalBinaryReader
            (cursor.new body-bytes tli-max-work)
            (+ directory.owned-bytes length)
            tli-max-owned-bytes
            tli-max-string-bytes)]
        [body : tli.TliCompactBody
          (tli-read-compact-body! (&mut rd) (& directory.pool))]
        (tli-check-end! (&mut rd))
        (if rd.cursor.ok?
          (TliCompactBodyResult.Ok body)
          (TliCompactBodyResult.Err (tli-read-error (& rd) abs-start)))))))

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
          [body-total : i64 0]
          (for [index (iterator.range 0 count)]
            (match (tli-decode-record-at (& directory) index owned)
              [(TliBudgetedModuleResult.Err error)
                (return (TliBundleResult.Err error))]
              [(TliBudgetedModuleResult.Ok record used)
                (for [fi (iterator.range 0 (array-length record.functions))]
                  (when
                    (!=
                      (bit-and
                        (array-ref record.functions fi).summary.effect-flags
                        (bit-or
                          tli.tli-fn-has-inline-ir
                          tli.tli-fn-spmd-inlineable))
                      0)
                    (+= body-total 1)))
                (set! (array-ref modules index) record)
                (set! owned used)]))
          (let
            [cglobals : (__tl_dyn-array tli.TliCompactGlobal)
              (match (tli-decode-compact-globals (& directory))
                [(TliCompactGlobalsResult.Err error)
                  (return (TliBundleResult.Err error))]
                [(TliCompactGlobalsResult.Ok g) g])]
            [cbodies : (__tl_dyn-array tli.TliCompactBodyEntry)
              (__tl_make-array tli.TliCompactBodyEntry body-total)]
            [bpos : i64 0]
            (for [mi (iterator.range 0 count)]
              (let
                [mod (& (array-ref modules mi))]
                (for [fi (iterator.range 0 (array-length mod.functions))]
                  (let
                    [f (& (array-ref mod.functions fi))]
                    [ef : i64 f.summary.effect-flags]
                    [want-ir? : bool
                      (!= (bit-and ef tli.tli-fn-has-inline-ir) 0)]
                    [want-spmd? : bool
                      (!= (bit-and ef tli.tli-fn-spmd-inlineable) 0)]
                    (when
                      (or want-ir? want-spmd?)
                      (match (tli-decode-compact-body-at
                        (& directory)
                        f.summary.inline-ir-offset
                        f.summary.inline-ir-len
                        (& f.summary.inline-ir-sha256))
                        [(TliCompactBodyResult.Err error)
                          (return (TliBundleResult.Err error))]
                        [(TliCompactBodyResult.Ok body)
                          (let
                            [got-ir? : bool
                              (!=
                                (bit-and body.kind tli.tli-compact-body-has-ir)
                                0)]
                            [got-spmd? : bool
                              (!=
                                (bit-and
                                  body.kind
                                  tli.tli-compact-body-has-spmd-expr)
                                0)]
                            (when
                              (or
                                (!= want-ir? got-ir?)
                                (!= want-spmd? got-spmd?))
                              (return
                                (TliBundleResult.Err
                                  (tli.TliDecodeFailure
                                    (tli.TliDecodeError.Flags)
                                    (+
                                      directory.compact-ir-offset
                                      f.summary.inline-ir-offset)
                                    "TLI compact body kind disagrees with function summary flags"))))
                            (set!
                              (array-ref cbodies bpos)
                              (tli.TliCompactBodyEntry
                                (string.copy (& f.module-name))
                                (string.copy (& f.name))
                                (string.copy (& f.link-symbol))
                                body))
                            (+= bpos 1))]))))))
            (TliBundleResult.Ok
              (tli.TliBundle
                directory.flags
                directory.compiler-build
                directory.target-triple
                modules
                cglobals
                cbodies)))))]))