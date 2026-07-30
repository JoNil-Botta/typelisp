;; compiler_surface_ast_codec_core.tl - binary primitives for frontend surfaces.
;;
;; The format is deliberately structural. Strings and list storage are copied,
;; expression/type references are dense image-pool indices, and every compiler
;; nominal is repacked through compiler_surface_identity. No arena address,
;; pointer, Box address, or producer-generation intern id is serialized.
(import "compiler_ast_types.tl")
(import compiler_surface_identity as identity)
(import compiler_surface_binary as binary)
(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (import stdlib.byte_buf_core))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (defstruct SurfaceAstWriteContext
    (valid (__tl_dyn-array bool))
    (source-identity-count i64)
    (identity-count i64)))

(defstruct SurfaceAstReader
  (bytes (__tl_dyn-array u8))
  (offset (__tl_dyn-array i64))
  (valid (__tl_dyn-array bool))
  (message (__tl_dyn-array String))
  (identity-remap (__tl_dyn-array i64)))

(define surface-ast-max-count : i64
  8388608)

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-context-new
    [source-identity-count : i64]
    [identity-count : i64]) : SurfaceAstWriteContext
    (let
      [valid : (__tl_dyn-array bool) (make-array bool 1)]
      (begin
        (array-set! valid 0 true)
        (SurfaceAstWriteContext valid source-identity-count identity-count)))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-valid? [context : SurfaceAstWriteContext]) : bool
    (array-ref (struct-get context valid) 0)))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-fail! [context : SurfaceAstWriteContext]) : unit
    (array-set! (struct-get context valid) 0 false)))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-i64!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [value : i64]) : unit
    (binary.surface-binary-push-u64! out value)))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-bool!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [value : bool]) : unit
    (surface-ast-write-i64!
      out
      (if value
        1
        0))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-string!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [text : String]) : unit
    (begin
      (surface-ast-write-i64! out (binary.surface-binary-string-length text))
      (binary.surface-binary-push-string! out text))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-name!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [name : i64]) : unit
    (let
      [portable : i64
        (identity.surface-identity-portable-id
          name
          (struct-get context source-identity-count)
          (struct-get context identity-count))]
      (begin
        (if (< portable 0)
          (surface-ast-write-fail! context)
          unit)
        (surface-ast-write-i64! out portable)))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-span!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [span : AstSourceSpan]) : unit
    (begin
      (surface-ast-write-i64! out (ast-source-span-start-line span))
      (surface-ast-write-i64! out (ast-source-span-start-col span))
      (surface-ast-write-i64! out (ast-source-span-end-line span))
      (surface-ast-write-i64! out (ast-source-span-end-col span)))))

(define (surface-ast-reader-new
  [bytes : (__tl_dyn-array u8)]
  [identity-remap : (__tl_dyn-array i64)]) : SurfaceAstReader
  (let
    [offset : (__tl_dyn-array i64) (make-array i64 1)]
    [valid : (__tl_dyn-array bool) (make-array bool 1)]
    [message : (__tl_dyn-array String) (make-array String 1)]
    (begin
      (array-set! offset 0 0)
      (array-set! valid 0 true)
      (array-set! message 0 "")
      (SurfaceAstReader bytes offset valid message identity-remap))))

(define (surface-ast-reader-valid? [reader : SurfaceAstReader]) : bool
  (array-ref (struct-get reader valid) 0))

(define (surface-ast-reader-message [reader : SurfaceAstReader]) : String
  (array-ref (struct-get reader message) 0))

(define (surface-ast-reader-offset [reader : SurfaceAstReader]) : i64
  (array-ref (struct-get reader offset) 0))

(define (surface-ast-reader-fail!
  [reader : SurfaceAstReader]
  [message : String]) : unit
  (if (surface-ast-reader-valid? reader)
    (begin
      (array-set! (struct-get reader valid) 0 false)
      (array-set! (struct-get reader message) 0 message))
    unit))

(define (surface-ast-read-i64! [reader : SurfaceAstReader]) : i64
  (let
    [offset : i64 (surface-ast-reader-offset reader)]
    [bytes : (__tl_dyn-array u8) (struct-get reader bytes)]
    (if (or
      (not (surface-ast-reader-valid? reader))
      (> offset (- (array-length bytes) 8)))
      (begin
        (surface-ast-reader-fail! reader "surface ast: truncated integer")
        0)
      (begin
        (array-set! (struct-get reader offset) 0 (+ offset 8))
        (binary.surface-binary-read-u64 bytes offset)))))

(define (surface-ast-read-bool! [reader : SurfaceAstReader]) : bool
  (let
    [value : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= value 0) false]
      [(= value 1) true]
      [else
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid boolean")
          false)])))

(define (surface-ast-count-valid? [count : i64]) : bool
  (and (>= count 0) (<= count surface-ast-max-count)))

(define (surface-ast-read-count! [reader : SurfaceAstReader]) : i64
  (let
    [count : i64 (surface-ast-read-i64! reader)]
    (if (surface-ast-count-valid? count)
      count
      (begin
        (surface-ast-reader-fail!
          reader
          "surface ast: invalid collection count")
        0))))

(define (surface-ast-read-string! [reader : SurfaceAstReader]) : String
  (let
    [len : i64 (surface-ast-read-count! reader)]
    [offset : i64 (surface-ast-reader-offset reader)]
    [bytes : (__tl_dyn-array u8) (struct-get reader bytes)]
    (if (or
      (> offset (array-length bytes))
      (> len (- (array-length bytes) offset)))
      (begin
        (surface-ast-reader-fail! reader "surface ast: truncated string")
        "")
      (let
        [text : String (binary.surface-binary-bytes->string bytes offset len)]
        (begin
          (array-set! (struct-get reader offset) 0 (+ offset len))
          text)))))

(define (surface-ast-read-name! [reader : SurfaceAstReader]) : i64
  (let
    [portable : i64 (surface-ast-read-i64! reader)]
    [resolved : i64
      (identity.surface-identity-resolve-portable-id
        portable
        (struct-get reader identity-remap))]
    (if (< resolved 0)
      (begin
        (surface-ast-reader-fail!
          reader
          "surface ast: invalid identity reference")
        0)
      resolved)))

(define (surface-ast-read-span! [reader : SurfaceAstReader]) : AstSourceSpan
  (ast-source-span
    (surface-ast-read-i64! reader)
    (surface-ast-read-i64! reader)
    (surface-ast-read-i64! reader)
    (surface-ast-read-i64! reader)))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-name-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [items : (__tl_dyn-array i64)]
    [count : i64]) : unit
    (let
      [index : i64 0]
      (begin
        (surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (surface-ast-write-name! out context (array-ref items index))
            (set! index (+ index 1))))))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-lifetime-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [lifetimes : AstLifetimeList]) : unit
    (surface-ast-write-name-list!
      out
      context
      (struct-get lifetimes slots)
      (struct-get lifetimes len))))

(define (surface-ast-read-lifetime-list! [reader : SurfaceAstReader]) : AstLifetimeList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array i64) (make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set! slots index (surface-ast-read-name! reader))
          (set! index (+ index 1))))
      (AstLifetimeList slots count))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-type-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [types : AstTypeList]) : unit
    (let
      [index : i64 0]
      [count : i64 (struct-get types len)]
      (begin
        (surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (surface-ast-write-i64!
              out
              (array-ref (struct-get types slots) index))
            (set! index (+ index 1))))))))

(define (surface-ast-read-type-list! [reader : SurfaceAstReader]) : AstTypeList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array i64) (make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set! slots index (surface-ast-read-i64! reader))
          (set! index (+ index 1))))
      (AstTypeList slots count))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-type!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [ty : AstType]) : unit
    (match ty
      [(AstType.I64) (surface-ast-write-i64! out 0)]
      [(AstType.I32) (surface-ast-write-i64! out 1)]
      [(AstType.I16) (surface-ast-write-i64! out 2)]
      [(AstType.I8) (surface-ast-write-i64! out 3)]
      [(AstType.U64) (surface-ast-write-i64! out 4)]
      [(AstType.U32) (surface-ast-write-i64! out 5)]
      [(AstType.U16) (surface-ast-write-i64! out 6)]
      [(AstType.U8) (surface-ast-write-i64! out 7)]
      [(AstType.F64) (surface-ast-write-i64! out 8)]
      [(AstType.F32) (surface-ast-write-i64! out 9)]
      [(AstType.Bool) (surface-ast-write-i64! out 10)]
      [(AstType.Char) (surface-ast-write-i64! out 11)]
      [(AstType.String) (surface-ast-write-i64! out 12)]
      [(AstType.Str) (surface-ast-write-i64! out 13)]
      [(AstType.Bytes) (surface-ast-write-i64! out 14)]
      [(AstType.Unit) (surface-ast-write-i64! out 15)]
      [(AstType.Never) (surface-ast-write-i64! out 16)]
      [(AstType.Expr) (surface-ast-write-i64! out 17)]
      [(AstType.ExprList) (surface-ast-write-i64! out 18)]
      [(AstType.Func args ret)
        (begin
          (surface-ast-write-i64! out 19)
          (surface-ast-write-type-list! out (box-get args))
          (surface-ast-write-i64! out ret))]
      [(AstType.Tuple items)
        (begin
          (surface-ast-write-i64! out 20)
          (surface-ast-write-type-list! out (box-get items)))]
      [(AstType.Array elem count)
        (begin
          (surface-ast-write-i64! out 21)
          (surface-ast-write-i64! out elem)
          (surface-ast-write-i64! out count))]
      [(AstType.DynArray elem)
        (begin
          (surface-ast-write-i64! out 22)
          (surface-ast-write-i64! out elem))]
      [(AstType.Box elem)
        (begin
          (surface-ast-write-i64! out 23)
          (surface-ast-write-i64! out elem))]
      [(AstType.Region region inner)
        (begin
          (surface-ast-write-i64! out 24)
          (surface-ast-write-name! out context region)
          (surface-ast-write-i64! out inner))]
      [(AstType.Ref region inner)
        (begin
          (surface-ast-write-i64! out 25)
          (surface-ast-write-name! out context region)
          (surface-ast-write-i64! out inner))]
      [(AstType.MutRef region inner)
        (begin
          (surface-ast-write-i64! out 26)
          (surface-ast-write-name! out context region)
          (surface-ast-write-i64! out inner))]
      [(AstType.Enum name)
        (begin
          (surface-ast-write-i64! out 27)
          (surface-ast-write-name! out context name))]
      [(AstType.EnumArgs name lifetimes)
        (begin
          (surface-ast-write-i64! out 28)
          (surface-ast-write-name! out context name)
          (surface-ast-write-lifetime-list! out context (box-get lifetimes)))]
      [(AstType.Struct name)
        (begin
          (surface-ast-write-i64! out 29)
          (surface-ast-write-name! out context name))]
      [(AstType.StructArgs name lifetimes)
        (begin
          (surface-ast-write-i64! out 30)
          (surface-ast-write-name! out context name)
          (surface-ast-write-lifetime-list! out context (box-get lifetimes)))]
      [(AstType.Var name)
        (begin
          (surface-ast-write-i64! out 31)
          (surface-ast-write-name! out context name))]
      [(AstType.VarArgs name lifetimes)
        (begin
          (surface-ast-write-i64! out 32)
          (surface-ast-write-name! out context name)
          (surface-ast-write-lifetime-list! out context (box-get lifetimes)))]
      [(AstType.Ptr elem)
        (begin
          (surface-ast-write-i64! out 33)
          (surface-ast-write-i64! out elem))]
      [(AstType.MutPtr elem)
        (begin
          (surface-ast-write-i64! out 34)
          (surface-ast-write-i64! out elem))]
      [(AstType.Consume inner)
        (begin
          (surface-ast-write-i64! out 35)
          (surface-ast-write-i64! out inner))])))

(define (surface-ast-read-type! [reader : SurfaceAstReader]) : AstType
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstType.I64]
      [(= tag 1) AstType.I32]
      [(= tag 2) AstType.I16]
      [(= tag 3) AstType.I8]
      [(= tag 4) AstType.U64]
      [(= tag 5) AstType.U32]
      [(= tag 6) AstType.U16]
      [(= tag 7) AstType.U8]
      [(= tag 8) AstType.F64]
      [(= tag 9) AstType.F32]
      [(= tag 10) AstType.Bool]
      [(= tag 11) AstType.Char]
      [(= tag 12) AstType.String]
      [(= tag 13) AstType.Str]
      [(= tag 14) AstType.Bytes]
      [(= tag 15) AstType.Unit]
      [(= tag 16) AstType.Never]
      [(= tag 17) AstType.Expr]
      [(= tag 18) AstType.ExprList]
      [(= tag 19)
        (AstType.Func
          (box (surface-ast-read-type-list! reader))
          (surface-ast-read-i64! reader))]
      [(= tag 20) (AstType.Tuple (box (surface-ast-read-type-list! reader)))]
      [(= tag 21)
        (AstType.Array
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 22) (AstType.DynArray (surface-ast-read-i64! reader))]
      [(= tag 23) (AstType.Box (surface-ast-read-i64! reader))]
      [(= tag 24)
        (AstType.Region
          (surface-ast-read-name! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 25)
        (AstType.Ref
          (surface-ast-read-name! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 26)
        (AstType.MutRef
          (surface-ast-read-name! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 27) (AstType.Enum (surface-ast-read-name! reader))]
      [(= tag 28)
        (AstType.EnumArgs
          (surface-ast-read-name! reader)
          (box (surface-ast-read-lifetime-list! reader)))]
      [(= tag 29) (AstType.Struct (surface-ast-read-name! reader))]
      [(= tag 30)
        (AstType.StructArgs
          (surface-ast-read-name! reader)
          (box (surface-ast-read-lifetime-list! reader)))]
      [(= tag 31) (AstType.Var (surface-ast-read-name! reader))]
      [(= tag 32)
        (AstType.VarArgs
          (surface-ast-read-name! reader)
          (box (surface-ast-read-lifetime-list! reader)))]
      [(= tag 33) (AstType.Ptr (surface-ast-read-i64! reader))]
      [(= tag 34) (AstType.MutPtr (surface-ast-read-i64! reader))]
      [(= tag 35) (AstType.Consume (surface-ast-read-i64! reader))]
      [else
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid type tag")
          AstType.Unit)])))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-maybe-type!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [maybe-ty : AstMaybeType]) : unit
    (match maybe-ty
      [(AstMaybeType.No) (surface-ast-write-i64! out 0)]
      [(AstMaybeType.Some ty)
        (begin
          (surface-ast-write-i64! out 1)
          (surface-ast-write-type! out context ty))])))

(define (surface-ast-read-maybe-type! [reader : SurfaceAstReader]) : AstMaybeType
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstMaybeType.No]
      [(= tag 1) (AstMaybeType.Some (surface-ast-read-type! reader))]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid optional type tag")
          AstMaybeType.No)])))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-literal!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [literal : AstLiteral]) : unit
    (match literal
      [(AstLiteral.Int value text)
        (begin
          (surface-ast-write-i64! out 0)
          (surface-ast-write-i64! out value)
          (surface-ast-write-string! out text))]
      [(AstLiteral.Float text)
        (begin
          (surface-ast-write-i64! out 1)
          (surface-ast-write-string! out text))]
      [(AstLiteral.Bool value)
        (begin
          (surface-ast-write-i64! out 2)
          (surface-ast-write-bool! out value))]
      [(AstLiteral.Char value)
        (begin
          (surface-ast-write-i64! out 3)
          (surface-ast-write-i64! out (cast value : i64)))]
      [(AstLiteral.String name)
        (begin
          (surface-ast-write-i64! out 4)
          (surface-ast-write-name! out context name))]
      [(AstLiteral.Unit) (surface-ast-write-i64! out 5)])))

(define (surface-ast-read-literal! [reader : SurfaceAstReader]) : AstLiteral
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0)
        (AstLiteral.Int
          (surface-ast-read-i64! reader)
          (surface-ast-read-string! reader))]
      [(= tag 1) (AstLiteral.Float (surface-ast-read-string! reader))]
      [(= tag 2) (AstLiteral.Bool (surface-ast-read-bool! reader))]
      [(= tag 3) (AstLiteral.Char (cast (surface-ast-read-i64! reader) : char))]
      [(= tag 4) (AstLiteral.String (surface-ast-read-name! reader))]
      [(= tag 5) AstLiteral.Unit]
      [else
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid literal tag")
          AstLiteral.Unit)])))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-borrow-lifetime!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [lifetime : AstBorrowLifetime]) : unit
    (match lifetime
      [(AstBorrowLifetime.Inferred) (surface-ast-write-i64! out 0)]
      [(AstBorrowLifetime.Named name)
        (begin
          (surface-ast-write-i64! out 1)
          (surface-ast-write-name! out context name))])))

(define (surface-ast-read-borrow-lifetime! [reader : SurfaceAstReader]) : AstBorrowLifetime
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstBorrowLifetime.Inferred]
      [(= tag 1) (AstBorrowLifetime.Named (surface-ast-read-name! reader))]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid borrow lifetime tag")
          AstBorrowLifetime.Inferred)])))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-bin-op!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [op : AstBinOp]) : unit
    (surface-ast-write-i64!
      out
      (match op
        [(AstBinOp.Add) 0]
        [(AstBinOp.Sub) 1]
        [(AstBinOp.Mul) 2]
        [(AstBinOp.Div) 3]
        [(AstBinOp.Mod) 4]
        [(AstBinOp.Eq) 5]
        [(AstBinOp.Ne) 6]
        [(AstBinOp.Lt) 7]
        [(AstBinOp.Le) 8]
        [(AstBinOp.Gt) 9]
        [(AstBinOp.Ge) 10]
        [(AstBinOp.And) 11]
        [(AstBinOp.Or) 12]
        [(AstBinOp.BitAnd) 13]
        [(AstBinOp.BitOr) 14]
        [(AstBinOp.BitXor) 15]
        [(AstBinOp.Shl) 16]
        [(AstBinOp.Shr) 17]))))

(define (surface-ast-read-bin-op! [reader : SurfaceAstReader]) : AstBinOp
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstBinOp.Add]
      [(= tag 1) AstBinOp.Sub]
      [(= tag 2) AstBinOp.Mul]
      [(= tag 3) AstBinOp.Div]
      [(= tag 4) AstBinOp.Mod]
      [(= tag 5) AstBinOp.Eq]
      [(= tag 6) AstBinOp.Ne]
      [(= tag 7) AstBinOp.Lt]
      [(= tag 8) AstBinOp.Le]
      [(= tag 9) AstBinOp.Gt]
      [(= tag 10) AstBinOp.Ge]
      [(= tag 11) AstBinOp.And]
      [(= tag 12) AstBinOp.Or]
      [(= tag 13) AstBinOp.BitAnd]
      [(= tag 14) AstBinOp.BitOr]
      [(= tag 15) AstBinOp.BitXor]
      [(= tag 16) AstBinOp.Shl]
      [(= tag 17) AstBinOp.Shr]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid binary operator")
          AstBinOp.Add)])))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-un-op!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [op : AstUnOp]) : unit
    (surface-ast-write-i64!
      out
      (match op
        [(AstUnOp.Neg) 0]
        [(AstUnOp.Not) 1]
        [(AstUnOp.BitNot) 2]))))

(define (surface-ast-read-un-op! [reader : SurfaceAstReader]) : AstUnOp
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstUnOp.Neg]
      [(= tag 1) AstUnOp.Not]
      [(= tag 2) AstUnOp.BitNot]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid unary operator")
          AstUnOp.Neg)])))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-reduce-op!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [op : AstReduceOp]) : unit
    (surface-ast-write-i64!
      out
      (match op
        [(AstReduceOp.Sum) 0]
        [(AstReduceOp.Min) 1]
        [(AstReduceOp.Max) 2]
        [(AstReduceOp.All) 3]
        [(AstReduceOp.Any) 4]))))

(define (surface-ast-read-reduce-op! [reader : SurfaceAstReader]) : AstReduceOp
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) AstReduceOp.Sum]
      [(= tag 1) AstReduceOp.Min]
      [(= tag 2) AstReduceOp.Max]
      [(= tag 3) AstReduceOp.All]
      [(= tag 4) AstReduceOp.Any]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid reduce operator")
          AstReduceOp.Sum)])))