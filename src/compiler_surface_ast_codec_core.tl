;; compiler_surface_ast_codec_core.tl - binary primitives for frontend surfaces.
;;
;; The format is deliberately structural. Strings and list storage are copied,
;; expression/type references are dense image-pool indices, and every compiler
;; nominal is repacked through compiler_surface_identity. No arena address,
;; pointer, Box address, or producer-generation intern id is serialized.
(import stdlib.byte_reader)
(import stdlib.string)
(import compiler_ast_types as ast)
(import compiler_intern_state as cis)
(import compiler_owned_view as owned_view)
(import compiler_surface_identity as identity)
(import compiler_surface_binary as binary)
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import stdlib.byte_buf_core))
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import stdlib.byte_le))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (defstruct SurfaceAstWriteContext
    (valid (__tl_dyn-array bool))
    (invalid-name (__tl_dyn-array i64))
    (structural-session cis.InternStructuralSessionHandle)
    (source-identity-count i64)
    (identity-count i64)))

(defstruct SurfaceAstReader
  (cursor byte_reader.ByteReader)
  (structural-session cis.InternStructuralSessionHandle)
  (identity-remap (__tl_dyn-array i64))
  (c-function-signatures (__tl_dyn-array ast.AstTypeList)))

(define surface-ast-max-count : i64
  8388608)

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
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
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-valid?
    [context : (& context SurfaceAstWriteContext)]) : bool
    (array-ref context.valid 0)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-invalid-name [context : SurfaceAstWriteContext]) : i64
    (array-ref context.invalid-name 0)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-fail!
    [context : (&mut context SurfaceAstWriteContext)]) : unit
    (set! (array-ref context.valid 0) false)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-i64!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [value : i64]) : unit
    (byte_le.push-u64! out value)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-bool!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [value : bool]) : unit
    (surface-ast-write-i64!
      out
      (if value
        1
        0))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-string!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [text : String]) : unit
    (begin
      (surface-ast-write-i64! out (binary.surface-binary-string-length text))
      (binary.surface-binary-push-string! out text))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-name!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context SurfaceAstWriteContext)]
    [name : i64]) : unit
    (let
      [portable : i64
        (identity.surface-identity-portable-id
          (owned_view.compiler-owned-reference-shared-view
            (& context.structural-session))
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
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
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
    [c-function-signatures : (__tl_dyn-array ast.AstTypeList)
      (__tl_make-array ast.AstTypeList 1)]
    (begin
      (set!
        (array-ref c-function-signatures 0)
        (ast.ast-type-list-with-capacity 0))
      (SurfaceAstReader
        (byte_reader.new bytes byte_reader.unlimited-work)
        structural-session
        identity-remap
        c-function-signatures))))

(define (surface-ast-reader-valid? [reader : (& reader SurfaceAstReader)]) : bool
  reader.cursor.ok?)

(define (surface-ast-reader-message [reader : (& reader SurfaceAstReader)]) : String
  (string.copy reader.cursor.error-message))

(define (surface-ast-reader-offset [reader : (& reader SurfaceAstReader)]) : i64
  reader.cursor.offset)

(define (surface-ast-reader-fail!
  [reader : (&mut reader SurfaceAstReader)]
  [message : String]) : unit
  (let
    [offset : i64 reader.cursor.offset]
    (byte_reader.fail!
      (&mut reader.cursor)
      byte_reader.error-invalid
      offset
      message)))

(define (surface-ast-read-i64! [reader : (&mut reader SurfaceAstReader)]) : i64
  (if (byte_reader.available? (& reader.cursor) 8)
    (byte_reader.read-u64! (&mut reader.cursor))
    (begin
      (surface-ast-reader-fail! reader "surface ast: truncated integer")
      0)))

(define (surface-ast-read-bool! [reader : (&mut reader SurfaceAstReader)]) : bool
  (let
    [value : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= value 0) false]
      [(= value 1) true]
      [else
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid boolean")
          false)])))

;; Every read-type call records C signatures, including inline declaration and
;; expression annotations. Validate after the complete destination pool exists;
;; primitive decoding alone cannot distinguish an in-range non-function id.
(define (surface-ast-record-c-function-signature!
  [reader : (&mut reader SurfaceAstReader)]
  [signature : i64]) : unit
  (let
    [signatures : ast.AstTypeList
      (owned_view.compiler-owned-array-element-shared-view
        reader.c-function-signatures
        0)]
    (begin
      (ast.ast-type-list-push (&mut signatures) signature)
      (set! (array-ref reader.c-function-signatures 0) signatures))))

(define (surface-ast-validate-c-function-signatures!
  [reader : (&mut reader SurfaceAstReader)]
  [pools : ast.AstNodePoolContext]) : unit
  (let
    [signatures : ast.AstTypeList
      (owned_view.compiler-owned-array-element-shared-view
        reader.c-function-signatures
        0)]
    [count : i64 (ast.ast-node-pool-context-type-len pools)]
    [index : i64 0]
    (while (and
      (surface-ast-reader-valid? reader)
      (< index (ast.ast-type-list-len (& signatures))))
      (let
        [signature : i64 (ast.ast-type-list-get (& signatures) index -1)]
        [valid : bool
          (and
            (>= signature 0)
            (< signature count)
            (match (ast.ast-node-pool-context-type-get pools signature)
              [(Func _ _) true]
              [_ false]))]
        (begin
          (unless
            valid
            (surface-ast-reader-fail!
              reader
              "surface ast: C function signature must reference a function type"))
          (set! index (+ index 1)))))))

(define (surface-ast-count-valid? [count : i64]) : bool
  (and (>= count 0) (<= count surface-ast-max-count)))

(define (surface-ast-read-count! [reader : (&mut reader SurfaceAstReader)]) : i64
  (let
    [count : i64 (surface-ast-read-i64! reader)]
    (if (surface-ast-count-valid? count)
      count
      (begin
        (surface-ast-reader-fail!
          reader
          "surface ast: invalid collection count")
        0))))

(define (surface-ast-read-string! [reader : (&mut reader SurfaceAstReader)]) : String
  (let
    [len : i64 (surface-ast-read-count! reader)]
    [offset : i64 reader.cursor.offset]
    (if (byte_reader.available? (& reader.cursor) len)
      (let
        [text : String
          (binary.surface-binary-bytes->string reader.cursor.bytes offset len)]
        (begin
          (byte_reader.skip! (&mut reader.cursor) len)
          text))
      (begin
        (surface-ast-reader-fail! reader "surface ast: truncated string")
        ""))))

(define (surface-ast-read-name! [reader : (&mut reader SurfaceAstReader)]) : i64
  (let
    [portable : i64 (surface-ast-read-i64! reader)]
    [resolved : i64
      (identity.surface-identity-resolve-portable-id
        (owned_view.compiler-owned-reference-shared-view
          (& reader.structural-session))
        portable
        (& reader.identity-remap))]
    (if (< resolved 0)
      (begin
        (surface-ast-reader-fail!
          reader
          "surface ast: invalid identity reference")
        0)
      resolved)))

(define (surface-ast-read-span! [reader : (&mut reader SurfaceAstReader)]) : ast.AstSourceSpan
  (ast.ast-source-span
    (surface-ast-read-i64! reader)
    (surface-ast-read-i64! reader)
    (surface-ast-read-i64! reader)
    (surface-ast-read-i64! reader)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-name-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context SurfaceAstWriteContext)]
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
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-lifetime-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context SurfaceAstWriteContext)]
    [lifetimes : ast.AstLifetimeList]) : unit
    (surface-ast-write-name-list! out context lifetimes.slots lifetimes.len)))

(define (surface-ast-read-lifetime-list!
  [reader : (&mut reader SurfaceAstReader)]) : ast.AstLifetimeList
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
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
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

(define (surface-ast-read-type-list! [reader : (&mut reader SurfaceAstReader)]) : ast.AstTypeList
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
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-type!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context SurfaceAstWriteContext)]
    [ty : ast.AstType]) : unit
    (match ty
      [(I64) (surface-ast-write-i64! out 0)]
      [(I32) (surface-ast-write-i64! out 1)]
      [(I16) (surface-ast-write-i64! out 2)]
      [(I8) (surface-ast-write-i64! out 3)]
      [(U64) (surface-ast-write-i64! out 4)]
      [(U32) (surface-ast-write-i64! out 5)]
      [(U16) (surface-ast-write-i64! out 6)]
      [(U8) (surface-ast-write-i64! out 7)]
      [(F64) (surface-ast-write-i64! out 8)]
      [(F32) (surface-ast-write-i64! out 9)]
      [(Bool) (surface-ast-write-i64! out 10)]
      [(Char) (surface-ast-write-i64! out 11)]
      [(String) (surface-ast-write-i64! out 12)]
      [(Str) (surface-ast-write-i64! out 13)]
      [(Bytes) (surface-ast-write-i64! out 14)]
      [(Unit) (surface-ast-write-i64! out 15)]
      [(Never) (surface-ast-write-i64! out 16)]
      [(Expr) (surface-ast-write-i64! out 17)]
      [(ExprList) (surface-ast-write-i64! out 18)]
      [(Func args ret)
        (begin
          (surface-ast-write-i64! out 19)
          (surface-ast-write-type-list! out (deref args))
          (surface-ast-write-i64! out ret))]
      [(Tuple items)
        (begin
          (surface-ast-write-i64! out 20)
          (surface-ast-write-type-list! out (deref items)))]
      [(Array elem count)
        (begin
          (surface-ast-write-i64! out 21)
          (surface-ast-write-i64! out elem)
          (surface-ast-write-i64! out count))]
      [(DynArray elem)
        (begin
          (surface-ast-write-i64! out 22)
          (surface-ast-write-i64! out elem))]
      [(Box elem)
        (begin
          (surface-ast-write-i64! out 23)
          (surface-ast-write-i64! out elem))]
      [(Region region inner)
        (begin
          (surface-ast-write-i64! out 24)
          (surface-ast-write-name! out context region)
          (surface-ast-write-i64! out inner))]
      [(Ref region inner)
        (begin
          (surface-ast-write-i64! out 25)
          (surface-ast-write-name! out context region)
          (surface-ast-write-i64! out inner))]
      [(MutRef region inner)
        (begin
          (surface-ast-write-i64! out 26)
          (surface-ast-write-name! out context region)
          (surface-ast-write-i64! out inner))]
      [(Invalidate lifetime inner)
        (begin
          (surface-ast-write-i64! out 39)
          (surface-ast-write-name! out context lifetime)
          (surface-ast-write-i64! out inner))]
      [(Enum name)
        (begin
          (surface-ast-write-i64! out 27)
          (surface-ast-write-name! out context name))]
      [(EnumArgs name lifetimes)
        (begin
          (surface-ast-write-i64! out 28)
          (surface-ast-write-name! out context name)
          (surface-ast-write-lifetime-list! out context (deref lifetimes)))]
      [(Struct name)
        (begin
          (surface-ast-write-i64! out 29)
          (surface-ast-write-name! out context name))]
      [(StructArgs name lifetimes)
        (begin
          (surface-ast-write-i64! out 30)
          (surface-ast-write-name! out context name)
          (surface-ast-write-lifetime-list! out context (deref lifetimes)))]
      [(Var name)
        (begin
          (surface-ast-write-i64! out 31)
          (surface-ast-write-name! out context name))]
      [(VarArgs name lifetimes)
        (begin
          (surface-ast-write-i64! out 32)
          (surface-ast-write-name! out context name)
          (surface-ast-write-lifetime-list! out context (deref lifetimes)))]
      [(CFunc signature mode)
        (begin
          (surface-ast-write-i64! out 38)
          (surface-ast-write-i64! out signature)
          (surface-ast-write-i64! out (ast.ast-c-function-mode-key mode)))]
      [(Ptr elem)
        (begin
          (surface-ast-write-i64! out 33)
          (surface-ast-write-i64! out elem))]
      [(MutPtr elem)
        (begin
          (surface-ast-write-i64! out 34)
          (surface-ast-write-i64! out elem))]
      [(Slice elem)
        (begin
          (surface-ast-write-i64! out 36)
          (surface-ast-write-i64! out elem))])))

(define (surface-ast-read-type! [reader : (&mut reader SurfaceAstReader)]) : ast.AstType
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) I64]
      [(= tag 1) I32]
      [(= tag 2) I16]
      [(= tag 3) I8]
      [(= tag 4) U64]
      [(= tag 5) U32]
      [(= tag 6) U16]
      [(= tag 7) U8]
      [(= tag 8) F64]
      [(= tag 9) F32]
      [(= tag 10) Bool]
      [(= tag 11) Char]
      [(= tag 12) String]
      [(= tag 13) Str]
      [(= tag 14) Bytes]
      [(= tag 15) Unit]
      [(= tag 16) Never]
      [(= tag 17) Expr]
      [(= tag 18) ExprList]
      [(= tag 19)
        (Func
          (box (surface-ast-read-type-list! reader))
          (surface-ast-read-i64! reader))]
      [(= tag 20) (Tuple (box (surface-ast-read-type-list! reader)))]
      [(= tag 21)
        (Array (surface-ast-read-i64! reader) (surface-ast-read-i64! reader))]
      [(= tag 22) (DynArray (surface-ast-read-i64! reader))]
      [(= tag 23) (Box (surface-ast-read-i64! reader))]
      [(= tag 24)
        (Region (surface-ast-read-name! reader) (surface-ast-read-i64! reader))]
      [(= tag 25)
        (Ref (surface-ast-read-name! reader) (surface-ast-read-i64! reader))]
      [(= tag 26)
        (MutRef (surface-ast-read-name! reader) (surface-ast-read-i64! reader))]
      [(= tag 39)
        (ast.ast-ty-invalidate-id
          (surface-ast-read-name! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 27) (Enum (surface-ast-read-name! reader))]
      [(= tag 28)
        (EnumArgs
          (surface-ast-read-name! reader)
          (box (surface-ast-read-lifetime-list! reader)))]
      [(= tag 29) (Struct (surface-ast-read-name! reader))]
      [(= tag 30)
        (StructArgs
          (surface-ast-read-name! reader)
          (box (surface-ast-read-lifetime-list! reader)))]
      [(= tag 31) (Var (surface-ast-read-name! reader))]
      [(= tag 32)
        (VarArgs
          (surface-ast-read-name! reader)
          (box (surface-ast-read-lifetime-list! reader)))]
      [(= tag 38)
        (let
          [signature : i64 (surface-ast-read-i64! reader)]
          [mode : i64 (surface-ast-read-i64! reader)]
          [_record : unit
            (surface-ast-record-c-function-signature! reader signature)]
          (cond
            [(or (< signature 0) (< mode 0) (> mode 3))
              (begin
                (surface-ast-reader-fail!
                  reader
                  "surface ast: invalid C function type")
                Unit)]
            [(= mode 0) (CFunc signature Nullable)]
            [(= mode 1) (CFunc signature NonNull)]
            [(= mode 2) (CFunc signature UnsafeNullable)]
            [else (CFunc signature UnsafeNonNull)]))]
      [(= tag 33) (Ptr (surface-ast-read-i64! reader))]
      [(= tag 34) (MutPtr (surface-ast-read-i64! reader))]
      [(= tag 36) (Slice (surface-ast-read-i64! reader))]
      [else
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid type tag")
          Unit)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-maybe-type!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context SurfaceAstWriteContext)]
    [maybe-ty : ast.AstMaybeType]) : unit
    (match maybe-ty
      [(No) (surface-ast-write-i64! out 0)]
      [(Some ty)
        (begin
          (surface-ast-write-i64! out 1)
          (surface-ast-write-type! out context ty))])))

(define (surface-ast-read-maybe-type! [reader : (&mut reader SurfaceAstReader)]) : ast.AstMaybeType
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) No]
      [(= tag 1) (Some (surface-ast-read-type! reader))]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid optional type tag")
          No)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-literal!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context SurfaceAstWriteContext)]
    [literal : ast.AstLiteral]) : unit
    (match literal
      [(Int value text)
        (begin
          (surface-ast-write-i64! out 0)
          (surface-ast-write-i64! out value)
          (surface-ast-write-string! out text))]
      [(Float text)
        (begin
          (surface-ast-write-i64! out 1)
          (surface-ast-write-string! out text))]
      [(Bool value)
        (begin
          (surface-ast-write-i64! out 2)
          (surface-ast-write-bool! out value))]
      [(Char value)
        (begin
          (surface-ast-write-i64! out 3)
          (surface-ast-write-i64! out (cast value : i64)))]
      [(String name)
        (begin
          (surface-ast-write-i64! out 4)
          (surface-ast-write-name! out context name))]
      [(Unit) (surface-ast-write-i64! out 5)])))

(define (surface-ast-read-literal! [reader : (&mut reader SurfaceAstReader)]) : ast.AstLiteral
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0)
        (Int (surface-ast-read-i64! reader) (surface-ast-read-string! reader))]
      [(= tag 1) (Float (surface-ast-read-string! reader))]
      [(= tag 2) (Bool (surface-ast-read-bool! reader))]
      [(= tag 3) (Char (cast (surface-ast-read-i64! reader) : char))]
      [(= tag 4) (String (surface-ast-read-name! reader))]
      [(= tag 5) Unit]
      [else
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid literal tag")
          Unit)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-borrow-lifetime!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context SurfaceAstWriteContext)]
    [lifetime : ast.AstBorrowLifetime]) : unit
    (match lifetime
      [(Inferred) (surface-ast-write-i64! out 0)]
      [(Named name)
        (begin
          (surface-ast-write-i64! out 1)
          (surface-ast-write-name! out context name))])))

(define (surface-ast-read-borrow-lifetime!
  [reader : (&mut reader SurfaceAstReader)]) : ast.AstBorrowLifetime
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) Inferred]
      [(= tag 1) (Named (surface-ast-read-name! reader))]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid borrow lifetime tag")
          Inferred)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-bin-op!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [op : ast.AstBinOp]) : unit
    (surface-ast-write-i64!
      out
      (match op
        [(Add) 0]
        [(Sub) 1]
        [(Mul) 2]
        [(Div) 3]
        [(Mod) 4]
        [(Eq) 5]
        [(Ne) 6]
        [(Lt) 7]
        [(Le) 8]
        [(Gt) 9]
        [(Ge) 10]
        [(And) 11]
        [(Or) 12]
        [(BitAnd) 13]
        [(BitOr) 14]
        [(BitXor) 15]
        [(Shl) 16]
        [(Shr) 17]))))

(define (surface-ast-read-bin-op! [reader : (&mut reader SurfaceAstReader)]) : ast.AstBinOp
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) Add]
      [(= tag 1) Sub]
      [(= tag 2) Mul]
      [(= tag 3) Div]
      [(= tag 4) Mod]
      [(= tag 5) Eq]
      [(= tag 6) Ne]
      [(= tag 7) Lt]
      [(= tag 8) Le]
      [(= tag 9) Gt]
      [(= tag 10) Ge]
      [(= tag 11) And]
      [(= tag 12) Or]
      [(= tag 13) BitAnd]
      [(= tag 14) BitOr]
      [(= tag 15) BitXor]
      [(= tag 16) Shl]
      [(= tag 17) Shr]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid binary operator")
          Add)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-un-op!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [op : ast.AstUnOp]) : unit
    (surface-ast-write-i64!
      out
      (match op
        [(Neg) 0]
        [(Not) 1]
        [(BitNot) 2]))))

(define (surface-ast-read-un-op! [reader : (&mut reader SurfaceAstReader)]) : ast.AstUnOp
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) Neg]
      [(= tag 1) Not]
      [(= tag 2) BitNot]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid unary operator")
          Neg)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-reduce-op!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [op : ast.AstReduceOp]) : unit
    (surface-ast-write-i64!
      out
      (match op
        [(Sum) 0]
        [(Min) 1]
        [(Max) 2]
        [(All) 3]
        [(Any) 4]))))

(define (surface-ast-read-reduce-op! [reader : (&mut reader SurfaceAstReader)]) : ast.AstReduceOp
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0) Sum]
      [(= tag 1) Min]
      [(= tag 2) Max]
      [(= tag 3) All]
      [(= tag 4) Any]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid reduce operator")
          Sum)])))