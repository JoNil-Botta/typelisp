;; compiler_surface_ast_codec_core.tl - binary primitives for frontend surfaces.
;;
;; The format is deliberately structural. Strings and list storage are copied,
;; expression/type references are dense image-pool indices, and every compiler
;; nominal is repacked through compiler_surface_identity. No arena address,
;; pointer, Box address, or producer-generation intern id is serialized.
(import compiler_ast_types as ast)
(import compiler_intern_state as cis)
(import compiler_surface_identity as identity)
(import compiler_surface_binary as binary)
(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (import stdlib.byte_buf_core))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (defstruct SurfaceAstWriteContext
    (valid (__tl_dyn-array bool))
    (invalid-name (__tl_dyn-array i64))
    (structural-session cis.InternStructuralSessionHandle)
    (source-identity-count i64)
    (identity-count i64)))

(defstruct SurfaceAstReader
  (bytes (__tl_dyn-array u8))
  (offset (__tl_dyn-array i64))
  (valid (__tl_dyn-array bool))
  (message (__tl_dyn-array String))
  (structural-session cis.InternStructuralSessionHandle)
  (identity-remap (__tl_dyn-array i64)))

(define surface-ast-max-count : i64
  8388608)

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-context-new
    [structural-session : cis.InternStructuralSessionHandle]
    [source-identity-count : i64]
    [identity-count : i64]) : SurfaceAstWriteContext
    (let
      [valid : (__tl_dyn-array bool) (__tl_make-array bool 1)]
      [invalid-name : (__tl_dyn-array i64) (__tl_make-array i64 1)]
      (begin
        (set! (array-ref valid 0) true)
        (set! (array-ref invalid-name 0) -1)
        (SurfaceAstWriteContext
          valid
          invalid-name
          structural-session
          source-identity-count
          identity-count)))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-valid? [context : SurfaceAstWriteContext]) : bool
    (array-ref context.valid 0)))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-invalid-name [context : SurfaceAstWriteContext]) : i64
    (array-ref context.invalid-name 0)))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-fail! [context : SurfaceAstWriteContext]) : unit
    (set! (array-ref context.valid 0) false)))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-i64!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [value : i64]) : unit
    (binary.surface-binary-push-u64! out value)))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-bool!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [value : bool]) : unit
    (surface-ast-write-i64!
      out
      (if value
        1
        0))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-string!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [text : String]) : unit
    (begin
      (surface-ast-write-i64! out (binary.surface-binary-string-length text))
      (binary.surface-binary-push-string! out text))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-name!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [name : i64]) : unit
    (let
      [portable : i64
        (identity.surface-identity-portable-id
          context.structural-session
          name
          context.source-identity-count
          context.identity-count)]
      (begin
        (if (< portable 0)
          (begin
            (when
              (surface-ast-write-valid? context)
              (set! (array-ref context.invalid-name 0) name))
            (surface-ast-write-fail! context))
          unit)
        (surface-ast-write-i64! out portable)))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-span!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [span : ast.AstSourceSpan]) : unit
    (begin
      (surface-ast-write-i64! out (ast.ast-source-span-start-line span))
      (surface-ast-write-i64! out (ast.ast-source-span-start-col span))
      (surface-ast-write-i64! out (ast.ast-source-span-end-line span))
      (surface-ast-write-i64! out (ast.ast-source-span-end-col span)))))

(define (surface-ast-reader-new
  [bytes : (__tl_dyn-array u8)]
  [structural-session : cis.InternStructuralSessionHandle]
  [identity-remap : (__tl_dyn-array i64)]) : SurfaceAstReader
  (let
    [offset : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [valid : (__tl_dyn-array bool) (__tl_make-array bool 1)]
    [message : (__tl_dyn-array String) (__tl_make-array String 1)]
    (begin
      (set! (array-ref offset 0) 0)
      (set! (array-ref valid 0) true)
      (set! (array-ref message 0) "")
      (SurfaceAstReader
        bytes
        offset
        valid
        message
        structural-session
        identity-remap))))

(define (surface-ast-reader-valid? [reader : SurfaceAstReader]) : bool
  (array-ref reader.valid 0))

(define (surface-ast-reader-message [reader : SurfaceAstReader]) : String
  (array-ref reader.message 0))

(define (surface-ast-reader-offset [reader : SurfaceAstReader]) : i64
  (array-ref reader.offset 0))

(define (surface-ast-reader-fail!
  [reader : SurfaceAstReader]
  [message : String]) : unit
  (if (surface-ast-reader-valid? reader)
    (begin
      (set! (array-ref reader.valid 0) false)
      (set! (array-ref reader.message 0) message))
    unit))

(define (surface-ast-read-i64! [reader : SurfaceAstReader]) : i64
  (let
    [offset : i64 (surface-ast-reader-offset reader)]
    [bytes : (__tl_dyn-array u8) reader.bytes]
    (if (or
      (not (surface-ast-reader-valid? reader))
      (> offset (- (array-length bytes) 8)))
      (begin
        (surface-ast-reader-fail! reader "surface ast: truncated integer")
        0)
      (begin
        (set! (array-ref reader.offset 0) (+ offset 8))
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
    [bytes : (__tl_dyn-array u8) reader.bytes]
    (if (or
      (> offset (array-length bytes))
      (> len (- (array-length bytes) offset)))
      (begin
        (surface-ast-reader-fail! reader "surface ast: truncated string")
        "")
      (let
        [text : String (binary.surface-binary-bytes->string bytes offset len)]
        (begin
          (set! (array-ref reader.offset 0) (+ offset len))
          text)))))

(define (surface-ast-read-name! [reader : SurfaceAstReader]) : i64
  (let
    [portable : i64 (surface-ast-read-i64! reader)]
    [resolved : i64
      (identity.surface-identity-resolve-portable-id
        reader.structural-session
        portable
        reader.identity-remap)]
    (if (< resolved 0)
      (begin
        (surface-ast-reader-fail!
          reader
          "surface ast: invalid identity reference")
        0)
      resolved)))

(define (surface-ast-read-span! [reader : SurfaceAstReader]) : ast.AstSourceSpan
  (ast.ast-source-span
    (surface-ast-read-i64! reader)
    (surface-ast-read-i64! reader)
    (surface-ast-read-i64! reader)
    (surface-ast-read-i64! reader)))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
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
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-lifetime-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [lifetimes : ast.AstLifetimeList]) : unit
    (surface-ast-write-name-list! out context lifetimes.slots lifetimes.len)))

(define (surface-ast-read-lifetime-list! [reader : SurfaceAstReader]) : ast.AstLifetimeList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (surface-ast-read-name! reader))
          (set! index (+ index 1))))
      (ast.AstLifetimeList slots count))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-type-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [types : ast.AstTypeList]) : unit
    (let
      [index : i64 0]
      [count : i64 types.len]
      (begin
        (surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (surface-ast-write-i64! out (array-ref types.slots index))
            (set! index (+ index 1))))))))

(define (surface-ast-read-type-list! [reader : SurfaceAstReader]) : ast.AstTypeList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (surface-ast-read-i64! reader))
          (set! index (+ index 1))))
      (ast.AstTypeList slots count))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-type!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [ty : ast.AstType]) : unit
    (match ty
      [(ast.AstType.I64) (surface-ast-write-i64! out 0)]
      [(ast.AstType.I32) (surface-ast-write-i64! out 1)]
      [(ast.AstType.I16) (surface-ast-write-i64! out 2)]
      [(ast.AstType.I8) (surface-ast-write-i64! out 3)]
      [(ast.AstType.U64) (surface-ast-write-i64! out 4)]
      [(ast.AstType.U32) (surface-ast-write-i64! out 5)]
      [(ast.AstType.U16) (surface-ast-write-i64! out 6)]
      [(ast.AstType.U8) (surface-ast-write-i64! out 7)]
      [(ast.AstType.F64) (surface-ast-write-i64! out 8)]
      [(ast.AstType.F32) (surface-ast-write-i64! out 9)]
      [(ast.AstType.Bool) (surface-ast-write-i64! out 10)]
      [(ast.AstType.Char) (surface-ast-write-i64! out 11)]
      [(ast.AstType.String) (surface-ast-write-i64! out 12)]
      [(ast.AstType.Str) (surface-ast-write-i64! out 13)]
      [(ast.AstType.Bytes) (surface-ast-write-i64! out 14)]
      [(ast.AstType.Unit) (surface-ast-write-i64! out 15)]
      [(ast.AstType.Never) (surface-ast-write-i64! out 16)]
      [(ast.AstType.Expr) (surface-ast-write-i64! out 17)]
      [(ast.AstType.ExprList) (surface-ast-write-i64! out 18)]
      [(ast.AstType.Func args ret)
        (begin
          (surface-ast-write-i64! out 19)
          (surface-ast-write-type-list! out (__tl-box-place args))
          (surface-ast-write-i64! out ret))]
      [(ast.AstType.Tuple items)
        (begin
          (surface-ast-write-i64! out 20)
          (surface-ast-write-type-list! out (__tl-box-place items)))]
      [(ast.AstType.Array elem count)
        (begin
          (surface-ast-write-i64! out 21)
          (surface-ast-write-i64! out elem)
          (surface-ast-write-i64! out count))]
      [(ast.AstType.DynArray elem)
        (begin
          (surface-ast-write-i64! out 22)
          (surface-ast-write-i64! out elem))]
      [(ast.AstType.Box elem)
        (begin
          (surface-ast-write-i64! out 23)
          (surface-ast-write-i64! out elem))]
      [(ast.AstType.Region region inner)
        (begin
          (surface-ast-write-i64! out 24)
          (surface-ast-write-name! out context region)
          (surface-ast-write-i64! out inner))]
      [(ast.AstType.Ref region inner)
        (begin
          (surface-ast-write-i64! out 25)
          (surface-ast-write-name! out context region)
          (surface-ast-write-i64! out inner))]
      [(ast.AstType.MutRef region inner)
        (begin
          (surface-ast-write-i64! out 26)
          (surface-ast-write-name! out context region)
          (surface-ast-write-i64! out inner))]
      [(ast.AstType.Enum name)
        (begin
          (surface-ast-write-i64! out 27)
          (surface-ast-write-name! out context name))]
      [(ast.AstType.EnumArgs name lifetimes)
        (begin
          (surface-ast-write-i64! out 28)
          (surface-ast-write-name! out context name)
          (surface-ast-write-lifetime-list!
            out
            context
            (__tl-box-place lifetimes)))]
      [(ast.AstType.Struct name)
        (begin
          (surface-ast-write-i64! out 29)
          (surface-ast-write-name! out context name))]
      [(ast.AstType.StructArgs name lifetimes)
        (begin
          (surface-ast-write-i64! out 30)
          (surface-ast-write-name! out context name)
          (surface-ast-write-lifetime-list!
            out
            context
            (__tl-box-place lifetimes)))]
      [(ast.AstType.Var name)
        (begin
          (surface-ast-write-i64! out 31)
          (surface-ast-write-name! out context name))]
      [(ast.AstType.VarArgs name lifetimes)
        (begin
          (surface-ast-write-i64! out 32)
          (surface-ast-write-name! out context name)
          (surface-ast-write-lifetime-list!
            out
            context
            (__tl-box-place lifetimes)))]
      [(ast.AstType.Ptr elem)
        (begin
          (surface-ast-write-i64! out 33)
          (surface-ast-write-i64! out elem))]
      [(ast.AstType.MutPtr elem)
        (begin
          (surface-ast-write-i64! out 34)
          (surface-ast-write-i64! out elem))]
      [(ast.AstType.Consume inner)
        (begin
          (surface-ast-write-i64! out 35)
          (surface-ast-write-i64! out inner))]
      [(ast.AstType.Slice elem)
        (begin
          (surface-ast-write-i64! out 36)
          (surface-ast-write-i64! out elem))])))

(define (surface-ast-read-type! [reader : SurfaceAstReader]) : ast.AstType
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstType.I64]
      [(= tag 1) ast.AstType.I32]
      [(= tag 2) ast.AstType.I16]
      [(= tag 3) ast.AstType.I8]
      [(= tag 4) ast.AstType.U64]
      [(= tag 5) ast.AstType.U32]
      [(= tag 6) ast.AstType.U16]
      [(= tag 7) ast.AstType.U8]
      [(= tag 8) ast.AstType.F64]
      [(= tag 9) ast.AstType.F32]
      [(= tag 10) ast.AstType.Bool]
      [(= tag 11) ast.AstType.Char]
      [(= tag 12) ast.AstType.String]
      [(= tag 13) ast.AstType.Str]
      [(= tag 14) ast.AstType.Bytes]
      [(= tag 15) ast.AstType.Unit]
      [(= tag 16) ast.AstType.Never]
      [(= tag 17) ast.AstType.Expr]
      [(= tag 18) ast.AstType.ExprList]
      [(= tag 19)
        (ast.AstType.Func
          (box (surface-ast-read-type-list! reader))
          (surface-ast-read-i64! reader))]
      [(= tag 20)
        (ast.AstType.Tuple (box (surface-ast-read-type-list! reader)))]
      [(= tag 21)
        (ast.AstType.Array
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 22) (ast.AstType.DynArray (surface-ast-read-i64! reader))]
      [(= tag 23) (ast.AstType.Box (surface-ast-read-i64! reader))]
      [(= tag 24)
        (ast.AstType.Region
          (surface-ast-read-name! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 25)
        (ast.AstType.Ref
          (surface-ast-read-name! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 26)
        (ast.AstType.MutRef
          (surface-ast-read-name! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 27) (ast.AstType.Enum (surface-ast-read-name! reader))]
      [(= tag 28)
        (ast.AstType.EnumArgs
          (surface-ast-read-name! reader)
          (box (surface-ast-read-lifetime-list! reader)))]
      [(= tag 29) (ast.AstType.Struct (surface-ast-read-name! reader))]
      [(= tag 30)
        (ast.AstType.StructArgs
          (surface-ast-read-name! reader)
          (box (surface-ast-read-lifetime-list! reader)))]
      [(= tag 31) (ast.AstType.Var (surface-ast-read-name! reader))]
      [(= tag 32)
        (ast.AstType.VarArgs
          (surface-ast-read-name! reader)
          (box (surface-ast-read-lifetime-list! reader)))]
      [(= tag 33) (ast.AstType.Ptr (surface-ast-read-i64! reader))]
      [(= tag 34) (ast.AstType.MutPtr (surface-ast-read-i64! reader))]
      [(= tag 35) (ast.AstType.Consume (surface-ast-read-i64! reader))]
      [(= tag 36) (ast.AstType.Slice (surface-ast-read-i64! reader))]
      [else
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid type tag")
          ast.AstType.Unit)])))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-maybe-type!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [maybe-ty : ast.AstMaybeType]) : unit
    (match maybe-ty
      [(ast.AstMaybeType.No) (surface-ast-write-i64! out 0)]
      [(ast.AstMaybeType.Some ty)
        (begin
          (surface-ast-write-i64! out 1)
          (surface-ast-write-type! out context ty))])))

(define (surface-ast-read-maybe-type! [reader : SurfaceAstReader]) : ast.AstMaybeType
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstMaybeType.No]
      [(= tag 1) (ast.AstMaybeType.Some (surface-ast-read-type! reader))]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid optional type tag")
          ast.AstMaybeType.No)])))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-literal!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [literal : ast.AstLiteral]) : unit
    (match literal
      [(ast.AstLiteral.Int value text)
        (begin
          (surface-ast-write-i64! out 0)
          (surface-ast-write-i64! out value)
          (surface-ast-write-string! out text))]
      [(ast.AstLiteral.Float text)
        (begin
          (surface-ast-write-i64! out 1)
          (surface-ast-write-string! out text))]
      [(ast.AstLiteral.Bool value)
        (begin
          (surface-ast-write-i64! out 2)
          (surface-ast-write-bool! out value))]
      [(ast.AstLiteral.Char value)
        (begin
          (surface-ast-write-i64! out 3)
          (surface-ast-write-i64! out (cast value : i64)))]
      [(ast.AstLiteral.String name)
        (begin
          (surface-ast-write-i64! out 4)
          (surface-ast-write-name! out context name))]
      [(ast.AstLiteral.Unit) (surface-ast-write-i64! out 5)])))

(define (surface-ast-read-literal! [reader : SurfaceAstReader]) : ast.AstLiteral
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0)
        (ast.AstLiteral.Int
          (surface-ast-read-i64! reader)
          (surface-ast-read-string! reader))]
      [(= tag 1) (ast.AstLiteral.Float (surface-ast-read-string! reader))]
      [(= tag 2) (ast.AstLiteral.Bool (surface-ast-read-bool! reader))]
      [(= tag 3)
        (ast.AstLiteral.Char (cast (surface-ast-read-i64! reader) : char))]
      [(= tag 4) (ast.AstLiteral.String (surface-ast-read-name! reader))]
      [(= tag 5) ast.AstLiteral.Unit]
      [else
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid literal tag")
          ast.AstLiteral.Unit)])))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-borrow-lifetime!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [lifetime : ast.AstBorrowLifetime]) : unit
    (match lifetime
      [(ast.AstBorrowLifetime.Inferred) (surface-ast-write-i64! out 0)]
      [(ast.AstBorrowLifetime.Named name)
        (begin
          (surface-ast-write-i64! out 1)
          (surface-ast-write-name! out context name))])))

(define (surface-ast-read-borrow-lifetime! [reader : SurfaceAstReader]) : ast.AstBorrowLifetime
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstBorrowLifetime.Inferred]
      [(= tag 1) (ast.AstBorrowLifetime.Named (surface-ast-read-name! reader))]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid borrow lifetime tag")
          ast.AstBorrowLifetime.Inferred)])))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-bin-op!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [op : ast.AstBinOp]) : unit
    (surface-ast-write-i64!
      out
      (match op
        [(ast.AstBinOp.Add) 0]
        [(ast.AstBinOp.Sub) 1]
        [(ast.AstBinOp.Mul) 2]
        [(ast.AstBinOp.Div) 3]
        [(ast.AstBinOp.Mod) 4]
        [(ast.AstBinOp.Eq) 5]
        [(ast.AstBinOp.Ne) 6]
        [(ast.AstBinOp.Lt) 7]
        [(ast.AstBinOp.Le) 8]
        [(ast.AstBinOp.Gt) 9]
        [(ast.AstBinOp.Ge) 10]
        [(ast.AstBinOp.And) 11]
        [(ast.AstBinOp.Or) 12]
        [(ast.AstBinOp.BitAnd) 13]
        [(ast.AstBinOp.BitOr) 14]
        [(ast.AstBinOp.BitXor) 15]
        [(ast.AstBinOp.Shl) 16]
        [(ast.AstBinOp.Shr) 17]))))

(define (surface-ast-read-bin-op! [reader : SurfaceAstReader]) : ast.AstBinOp
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstBinOp.Add]
      [(= tag 1) ast.AstBinOp.Sub]
      [(= tag 2) ast.AstBinOp.Mul]
      [(= tag 3) ast.AstBinOp.Div]
      [(= tag 4) ast.AstBinOp.Mod]
      [(= tag 5) ast.AstBinOp.Eq]
      [(= tag 6) ast.AstBinOp.Ne]
      [(= tag 7) ast.AstBinOp.Lt]
      [(= tag 8) ast.AstBinOp.Le]
      [(= tag 9) ast.AstBinOp.Gt]
      [(= tag 10) ast.AstBinOp.Ge]
      [(= tag 11) ast.AstBinOp.And]
      [(= tag 12) ast.AstBinOp.Or]
      [(= tag 13) ast.AstBinOp.BitAnd]
      [(= tag 14) ast.AstBinOp.BitOr]
      [(= tag 15) ast.AstBinOp.BitXor]
      [(= tag 16) ast.AstBinOp.Shl]
      [(= tag 17) ast.AstBinOp.Shr]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid binary operator")
          ast.AstBinOp.Add)])))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-un-op!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [op : ast.AstUnOp]) : unit
    (surface-ast-write-i64!
      out
      (match op
        [(ast.AstUnOp.Neg) 0]
        [(ast.AstUnOp.Not) 1]
        [(ast.AstUnOp.BitNot) 2]))))

(define (surface-ast-read-un-op! [reader : SurfaceAstReader]) : ast.AstUnOp
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstUnOp.Neg]
      [(= tag 1) ast.AstUnOp.Not]
      [(= tag 2) ast.AstUnOp.BitNot]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid unary operator")
          ast.AstUnOp.Neg)])))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-reduce-op!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [op : ast.AstReduceOp]) : unit
    (surface-ast-write-i64!
      out
      (match op
        [(ast.AstReduceOp.Sum) 0]
        [(ast.AstReduceOp.Min) 1]
        [(ast.AstReduceOp.Max) 2]
        [(ast.AstReduceOp.All) 3]
        [(ast.AstReduceOp.Any) 4]))))

(define (surface-ast-read-reduce-op! [reader : SurfaceAstReader]) : ast.AstReduceOp
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) ast.AstReduceOp.Sum]
      [(= tag 1) ast.AstReduceOp.Min]
      [(= tag 2) ast.AstReduceOp.Max]
      [(= tag 3) ast.AstReduceOp.All]
      [(= tag 4) ast.AstReduceOp.Any]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid reduce operator")
          ast.AstReduceOp.Sum)])))