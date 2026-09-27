;; compiler_ir_text.tl - Read `typelisp-ir v1` text back into IR.
;;
;; The inverse of `compiler-ir-program-render` and the renderers under it, for
;; tests: a fixture states its IR as the text `--dump-ir` prints, and a test can
;; compare a pass result against the text it expects. Only test modules import
;; this; the compiler never parses IR text.
;;
;; Reading is line based. Leading and trailing blanks are ignored, so fixture
;; text can be indented to match the source around it, and blank lines are
;; skipped. A line ending in `:` starts a block. Names are resolved the way the
;; hand-built fixtures resolve them: labels through `compiler-ir-label`,
;; symbols through `compiler-ir-test-symbol`, and nominal types through the
;; intern pool. Types are rebuilt with the `ast-ty-*` constructors.
;;
;; Where the renderer drops information, the reader picks the common case: a
;; shift's count type is its operand type, `branch` and `switch` read back as
;; the plain (not total-enum) forms, an integer is an `i64`, a bare nominal type
;; is a struct, and call arguments take the canonical `CompilerIrCallArgs`
;; shape. Malformed text aborts with the offending line.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.io)
(import stdlib.string)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_ir_types as ir)
(cfg test (import stdlib.test))

;; One line of text and the read position within it.
(defstruct IrTextCursor
  (line String)
  (pos i64))

;; The non-blank lines of a text, trimmed, and the next one to read.
(defstruct IrTextLines
  (lines (__tl_dyn-array String))
  (count i64)
  (next i64))

(define (ir-text-fail [line : String] [message : String]) : never
  (io.panic (str_cat.str-cat "ir text: " message ": " line)))

(define (ir-text-lines [text : String]) : IrTextLines
  (let
    [n : i64 (string.string-length text)]
    [count : i64 1]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (= (string.char-at text i) '\n')
            (set! count (+ count 1))
            unit)
          (set! i (+ i 1))))
      (let
        [lines : (__tl_dyn-array String) (__tl_make-array String count)]
        [kept : i64 0]
        [start : i64 0]
        (begin
          (set! i 0)
          (while (<= i n)
            (begin
              (if (or (= i n) (= (string.char-at text i) '\n'))
                (let
                  [line : String
                    (string.trim (string.substring text start (- i start)))]
                  (begin
                    (if (> (string.string-length line) 0)
                      (begin
                        (set! (array-ref lines kept) line)
                        (set! kept (+ kept 1)))
                      unit)
                    (set! start (+ i 1))))
                unit)
              (set! i (+ i 1))))
          (IrTextLines lines kept 0))))))

(define (ir-text-lines-more? [doc : (& doc IrTextLines)]) : bool
  (< doc.next doc.count))

(define (ir-text-lines-peek [doc : (& doc IrTextLines)]) : String
  (if (< doc.next doc.count)
    (string.copy (& (array-ref doc.lines doc.next)))
    ""))

(define (ir-text-lines-take! [doc : (&mut doc IrTextLines)]) : String
  (let
    [line : String (ir-text-lines-peek doc)]
    (begin
      (set! doc.next (+ doc.next 1))
      line)))

(define (ir-text-lines-done! [doc : (& doc IrTextLines)]) : unit
  (if (ir-text-lines-more? doc)
    (ir-text-fail (ir-text-lines-peek doc) "unexpected line after the end")
    unit))

(define (ir-text-lines-count-prefix
  [doc : (& doc IrTextLines)]
  [prefix : (& prefix str)]) : i64
  (let
    [count : i64 0]
    [i : i64 0]
    (begin
      (while (< i doc.count)
        (begin
          (if (string.is-string-prefix-at (& (array-ref doc.lines i)) prefix 0)
            (set! count (+ count 1))
            unit)
          (set! i (+ i 1))))
      count)))

(define (ir-text-label-line? [line : (& line str)]) : bool
  (let
    [n : i64 (string.string-length line)]
    (and (> n 1) (= (string.char-at line (- n 1)) ':'))))

;; --- cursor ---------------------------------------------------------------
(define (ir-text-cursor [line : String]) : IrTextCursor
  (IrTextCursor line 0))

(define (ir-text-error [cur : (& cur IrTextCursor)] [message : String]) : never
  (ir-text-fail
    (string.copy (& cur.line))
    (str_cat.str-cat message " at column " (string.int->string cur.pos))))

(define (ir-text-skip-blanks! [cur : (&mut cur IrTextCursor)]) : unit
  (while (and
    (< cur.pos (string.string-length cur.line))
    (= (string.char-at cur.line cur.pos) ' '))
    (set! cur.pos (+ cur.pos 1))))

(define (ir-text-at-end? [cur : (&mut cur IrTextCursor)]) : bool
  (begin
    (ir-text-skip-blanks! cur)
    (>= cur.pos (string.string-length cur.line))))

(define (ir-text-accept! [cur : (&mut cur IrTextCursor)] [lit : (& lit str)]) : bool
  (begin
    (ir-text-skip-blanks! cur)
    (if (string.is-string-prefix-at cur.line lit cur.pos)
      (begin
        (set! cur.pos (+ cur.pos (string.string-length lit)))
        true)
      false)))

(define (ir-text-expect! [cur : (&mut cur IrTextCursor)] [lit : (& lit str)]) : unit
  (if (ir-text-accept! cur lit)
    unit
    (ir-text-error cur (str_cat.str-cat "expected `" (string.copy lit) "`"))))

;; The next blank-delimited word, also ending before any character of `stops`.
(define (ir-text-word! [cur : (&mut cur IrTextCursor)] [stops : (& stops str)]) : String
  (begin
    (ir-text-skip-blanks! cur)
    (let
      [start : i64 cur.pos]
      (begin
        (while (and
          (< cur.pos (string.string-length cur.line))
          (not (= (string.char-at cur.line cur.pos) ' '))
          (not (string.contains-char stops (string.char-at cur.line cur.pos))))
          (set! cur.pos (+ cur.pos 1)))
        (if (= cur.pos start)
          (ir-text-error cur "expected a word")
          (string.substring cur.line start (- cur.pos start)))))))

(define (ir-text-digits? [text : (& text str)] [start : i64]) : bool
  (let
    [n : i64 (string.string-length text)]
    [i : i64 start]
    [ok : bool (< start n)]
    (begin
      (while (and ok (< i n))
        (let
          [code : i64 (cast (string.char-at text i) : i64)]
          (begin
            (set!
              ok
              (and (>= code (cast '0' : i64)) (<= code (cast '9' : i64))))
            (set! i (+ i 1)))))
      ok)))

(define (ir-text-int? [text : (& text str)]) : bool
  (if (string.is-string-prefix-at text "-" 0)
    (ir-text-digits? text 1)
    (ir-text-digits? text 0)))

(define (ir-text-int-of [cur : (& cur IrTextCursor)] [text : (& text str)]) : i64
  (if (ir-text-int? text)
    (string.>int text)
    (ir-text-error
      cur
      (str_cat.str-cat "expected an integer, found `" (string.copy text) "`"))))

(define (ir-text-int! [cur : (&mut cur IrTextCursor)]) : i64
  (ir-text-int-of cur (ir-text-word! cur ",()[]:")))

(define (ir-text-var! [cur : (&mut cur IrTextCursor)]) : i64
  (begin
    (ir-text-expect! cur "%")
    (ir-text-int! cur)))

(define (ir-text-lanes! [cur : (&mut cur IrTextCursor)]) : i64
  (begin
    (ir-text-expect! cur "lanes")
    (ir-text-int! cur)))

;; --- names ------------------------------------------------------------------
(define (ir-text-symbol [name : String]) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (ir.compiler-ir-test-symbol name)))

(define (ir-text-label! [cur : (&mut cur IrTextCursor)]) : i64
  (ir.compiler-ir-label (ir-text-word! cur ",()[]")))

(define (ir-text-lifetime! [cur : (&mut cur IrTextCursor)]) : i64
  (let
    [name : String (ir-text-word! cur "()")]
    (if (string.is-string-prefix-at name "<id:" 0)
      (ir-text-error cur "an unnamed lifetime has no text form")
      (ci.intern name))))

;; --- types ------------------------------------------------------------------
(define (ir-text-named-type [name : (& name str)]) : ast.AstType
  (cond
    [(string.eq name "i64") (ast.AstType.I64)]
    [(string.eq name "i32") (ast.AstType.I32)]
    [(string.eq name "i16") (ast.AstType.I16)]
    [(string.eq name "i8") (ast.AstType.I8)]
    [(string.eq name "u64") (ast.AstType.U64)]
    [(string.eq name "u32") (ast.AstType.U32)]
    [(string.eq name "u16") (ast.AstType.U16)]
    [(string.eq name "u8") (ast.AstType.U8)]
    [(string.eq name "f64") (ast.AstType.F64)]
    [(string.eq name "f32") (ast.AstType.F32)]
    [(string.eq name "bool") (ast.AstType.Bool)]
    [(string.eq name "char") (ast.AstType.Char)]
    [(string.eq name "String") (ast.AstType.String)]
    [(string.eq name "str") (ast.AstType.Str)]
    [(string.eq name "bytes") (ast.AstType.Bytes)]
    [(string.eq name "unit") (ast.AstType.Unit)]
    [(string.eq name "never") (ast.AstType.Never)]
    [(string.eq name "Expr") (ast.AstType.Expr)]
    [(string.eq name "ExprList") (ast.AstType.ExprList)]
    [else (ast.AstType.Struct (ci.intern (string.copy name)))]))

(define (ir-text-type-id! [cur : (&mut cur IrTextCursor)]) : i64
  (ast.ast-node-pool-reader-type-push (ir-text-type! cur)))

;; Types up to the closing `)` of the current list, which is consumed.
(define (ir-text-type-list! [cur : (&mut cur IrTextCursor)]) : ast.AstTypeList
  (let
    [types : ast.AstTypeList (ast.ast-type-list-new)]
    (begin
      (while (not (ir-text-accept! cur ")"))
        (ast.ast-type-list-push (&mut types) (ir-text-type-id! cur)))
      types)))

(define (ir-text-c-function-mode
  [cur : (& cur IrTextCursor)]
  [name : (& name str)]) : ast.AstCFunctionMode
  (cond
    [(string.eq name "nullable") (ast.AstCFunctionMode.Nullable)]
    [(string.eq name "non-null") (ast.AstCFunctionMode.NonNull)]
    [(string.eq name "unsafe-nullable") (ast.AstCFunctionMode.UnsafeNullable)]
    [(string.eq name "unsafe-non-null") (ast.AstCFunctionMode.UnsafeNonNull)]
    [else
      (ir-text-error
        cur
        (str_cat.str-cat "unknown CFunc mode " (string.copy name)))]))

;; The rest of a parenthesized type after its head word, through its `)`.
(define (ir-text-compound-type!
  [cur : (&mut cur IrTextCursor)]
  [head : (& head str)]) : ast.AstType
  (cond
    [(string.eq head "->")
      (let
        [types : ast.AstTypeList (ir-text-type-list! cur)]
        [count : i64 (ast.ast-type-list-len (& types))]
        [args : ast.AstTypeList (ast.ast-type-list-new)]
        [i : i64 0]
        (begin
          (if (= count 0)
            (ir-text-error cur "a function type needs a return type")
            unit)
          (while (< i (- count 1))
            (begin
              (ast.ast-type-list-push
                (&mut args)
                (ast.ast-type-list-get (& types) i (ast.ast-type-id-fallback)))
              (set! i (+ i 1))))
          (ast.AstType.Func
            (box args)
            (ast.ast-type-list-get
              (& types)
              (- count 1)
              (ast.ast-type-id-fallback)))))]
    [(string.eq head "Tuple") (ast.ast-ty-tuple (ir-text-type-list! cur))]
    [(string.eq head "CFunc")
      (let
        [mode : ast.AstCFunctionMode
          (ir-text-c-function-mode cur (ir-text-word! cur "()"))]
        [signature : i64 (ir-text-type-id! cur)]
        (begin
          (ir-text-expect! cur ")")
          (ast.AstType.CFunc signature mode)))]
    [(string.eq head "Array")
      (let
        [elem : ast.AstType (ir-text-type! cur)]
        [count : i64 (ir-text-int! cur)]
        (begin
          (ir-text-expect! cur ")")
          (ast.ast-ty-array elem count)))]
    [(or (string.eq head "Region") (string.eq head "&") (string.eq head "&mut"))
      (let
        [region : i64 (ir-text-lifetime! cur)]
        [inner : ast.AstType (ir-text-type! cur)]
        (begin
          (ir-text-expect! cur ")")
          (cond
            [(string.eq head "Region") (ast.ast-ty-region region inner)]
            [(string.eq head "&") (ast.ast-ty-ref region inner)]
            [else (ast.ast-ty-mut-ref region inner)])))]
    [(or
        (string.eq head "__tl_dyn-array")
        (string.eq head "Slice")
        (string.eq head "Box")
        (string.eq head "Ptr")
        (string.eq head "MutPtr"))
      (let
        [elem : ast.AstType (ir-text-type! cur)]
        (begin
          (ir-text-expect! cur ")")
          (cond
            [(string.eq head "__tl_dyn-array") (ast.ast-ty-dyn-array elem)]
            [(string.eq head "Slice") (ast.ast-ty-slice elem)]
            [(string.eq head "Box") (ast.ast-ty-box elem)]
            [(string.eq head "Ptr") (ast.ast-ty-ptr elem)]
            [else (ast.ast-ty-mut-ptr elem)])))]
    [else
      (let
        [lifetimes : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
        (begin
          (while (not (ir-text-accept! cur ")"))
            (ast.ast-lifetime-list-push
              (&mut lifetimes)
              (ir-text-lifetime! cur)))
          (ast.ast-ty-struct-args (ci.intern (string.copy head)) lifetimes)))]))

(define (ir-text-type! [cur : (&mut cur IrTextCursor)]) : ast.AstType
  (if (ir-text-accept! cur "(")
    (ir-text-compound-type! cur (ir-text-word! cur "()"))
    (ir-text-named-type (ir-text-word! cur ",()[]@"))))

(define (ir-text-typed! [cur : (&mut cur IrTextCursor)]) : ast.AstType
  (begin
    (ir-text-expect! cur ":")
    (ir-text-type! cur)))

;; --- values -----------------------------------------------------------------
(define (ir-text-after [text : (& text str)] [prefix : (& prefix str)]) : String
  (string.substring
    text
    (string.string-length prefix)
    (- (string.string-length text) (string.string-length prefix))))

(define (ir-text-value-of [cur : (& cur IrTextCursor)] [word : (& word str)]) : ir.CompilerIrValue
  (cond
    [(string.is-string-prefix-at word "%" 0)
      (ir.CompilerIrValue.Var (ir-text-int-of cur (ir-text-after word "%")))]
    [(string.is-string-prefix-at word "@" 0)
      (ir.CompilerIrValue.Global (ir-text-symbol (ir-text-after word "@")))]
    [(string.is-string-prefix-at word "&@" 0)
      (ir.CompilerIrValue.GlobalAddr (ir-text-symbol (ir-text-after word "&@")))]
    [(string.is-string-prefix-at word "fn@" 0)
      (ir.CompilerIrValue.Function (ir-text-symbol (ir-text-after word "fn@")))]
    [(string.is-string-prefix-at word "runtime-init@" 0)
      (ir.CompilerIrValue.RuntimeGlobal
        (ir-text-symbol (ir-text-after word "runtime-init@")))]
    [(string.is-string-prefix-at word "float-bits:" 0)
      (ir.CompilerIrValue.F64
        (cast (ir-text-int-of cur (ir-text-after word "float-bits:")) : u64))]
    [(string.eq word "true") (ir.CompilerIrValue.Bool true)]
    [(string.eq word "false") (ir.CompilerIrValue.Bool false)]
    [(string.eq word "unit") (ir.CompilerIrValue.Unit)]
    [else (ir.CompilerIrValue.I64 (ir-text-int-of cur word))]))

(define (ir-text-value! [cur : (&mut cur IrTextCursor)]) : ir.CompilerIrValue
  (let
    [word : String (ir-text-word! cur ",()[]")]
    (ir-text-value-of cur word)))

(define (ir-text-comma-value! [cur : (&mut cur IrTextCursor)]) : ir.CompilerIrValue
  (begin
    (ir-text-expect! cur ",")
    (ir-text-value! cur)))

;; Comma-separated values up to the closing `close`, which is consumed.
(define (ir-text-values!
  [cur : (&mut cur IrTextCursor)]
  [close : (& close str)]) : ir.CompilerIrValueSeq
  (let
    [builder : ir.CompilerIrValueBuilder
      (ir.compiler-ir-value-builder-with-capacity 4)]
    (begin
      (if (ir-text-accept! cur close)
        unit
        (begin
          (ir.compiler-ir-value-builder-push!
            (&mut builder)
            (ir-text-value! cur))
          (while (ir-text-accept! cur ",")
            (ir.compiler-ir-value-builder-push!
              (&mut builder)
              (ir-text-value! cur)))
          (ir-text-expect! cur close)))
      (ir.compiler-ir-value-builder-to-seq builder))))

;; `(args)` or `([sret arg N] args)`, through the closing `)`.
(define (ir-text-call-args! [cur : (&mut cur IrTextCursor)]) : ir.CompilerIrCallArgs
  (begin
    (ir-text-expect! cur "(")
    (if (ir-text-accept! cur "[sret arg")
      (let
        [index : i64 (ir-text-int! cur)]
        (begin
          (ir-text-expect! cur "]")
          (ir.compiler-ir-call-args-sret-from-seq
            (ir-text-values! cur ")")
            index)))
      (ir.compiler-ir-call-args-from-seq (ir-text-values! cur ")")))))

(define (ir-text-maybe-value! [cur : (&mut cur IrTextCursor)]) : ir.CompilerIrMaybeValue
  (if (ir-text-at-end? cur)
    (ir.CompilerIrMaybeValue.No)
    (ir.CompilerIrMaybeValue.Some (ir-text-value! cur))))

;; --- operators --------------------------------------------------------------
(define (ir-text-binops [shift-ty : ast.AstType]) : (__tl_dyn-array
    ir.CompilerIrBinOp)
  (__tl_make-array
    (ir.CompilerIrBinOp.Add)
    (ir.CompilerIrBinOp.Sub)
    (ir.CompilerIrBinOp.Mul)
    (ir.CompilerIrBinOp.Div)
    (ir.CompilerIrBinOp.Mod)
    (ir.CompilerIrBinOp.SafeDiv)
    (ir.CompilerIrBinOp.SafeMod)
    (ir.CompilerIrBinOp.Eq)
    (ir.CompilerIrBinOp.Ne)
    (ir.CompilerIrBinOp.Lt)
    (ir.CompilerIrBinOp.Le)
    (ir.CompilerIrBinOp.Gt)
    (ir.CompilerIrBinOp.Ge)
    (ir.CompilerIrBinOp.BitTestEq)
    (ir.CompilerIrBinOp.BitTestNe)
    (ir.CompilerIrBinOp.And)
    (ir.CompilerIrBinOp.Or)
    (ir.CompilerIrBinOp.BitAnd)
    (ir.CompilerIrBinOp.BitOr)
    (ir.CompilerIrBinOp.BitXor)
    (ir.CompilerIrBinOp.Shl (clone shift-ty))
    (ir.CompilerIrBinOp.Shr shift-ty)))

;; The binary operator the renderer spells `name`, or -1.
(define (ir-text-binop-index [name : (& name str)]) : i64
  (let
    [ops : (__tl_dyn-array ir.CompilerIrBinOp)
      (ir-text-binops (ast.AstType.I64))]
    [i : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< i (array-length ops)))
        (begin
          (if (string.eq
            name
            (ir.compiler-ir-bin-op-render (clone (array-ref ops i))))
            (set! found i)
            unit)
          (set! i (+ i 1))))
      found)))

(define (ir-text-binop [index : i64] [shift-ty : ast.AstType]) : ir.CompilerIrBinOp
  (clone (array-ref (ir-text-binops shift-ty) index)))

(define (ir-text-unop-index [name : (& name str)]) : i64
  (cond
    [(string.eq name "neg") 0]
    [(string.eq name "not") 1]
    [(string.eq name "bit_not") 2]
    [(string.eq name "sqrt") 3]
    [(string.eq name "bit_length") 4]
    [else -1]))

(define (ir-text-unop [index : i64]) : ir.CompilerIrUnOp
  (match index
    [0 (ir.CompilerIrUnOp.Neg)]
    [1 (ir.CompilerIrUnOp.Not)]
    [2 (ir.CompilerIrUnOp.BitNot)]
    [3 (ir.CompilerIrUnOp.Sqrt)]
    [_ (ir.CompilerIrUnOp.BitLength)]))

(define (ir-text-vector-prefix-op
  [cur : (& cur IrTextCursor)]
  [name : (& name str)]) : ir.CompilerIrVectorPrefixOp
  (cond
    [(string.eq name "sum") (ir.CompilerIrVectorPrefixOp.Sum)]
    [(string.eq name "min") (ir.CompilerIrVectorPrefixOp.Min)]
    [(string.eq name "max") (ir.CompilerIrVectorPrefixOp.Max)]
    [(string.eq name "all") (ir.CompilerIrVectorPrefixOp.All)]
    [(string.eq name "any") (ir.CompilerIrVectorPrefixOp.Any)]
    [else
      (ir-text-error
        cur
        (str_cat.str-cat "unknown prefix op " (string.copy name)))]))

(define (ir-text-vector-reduce-op
  [cur : (& cur IrTextCursor)]
  [name : (& name str)]) : ir.CompilerIrVectorReduceOp
  (cond
    [(string.eq name "sum") (ir.CompilerIrVectorReduceOp.Sum)]
    [(string.eq name "min") (ir.CompilerIrVectorReduceOp.Min)]
    [(string.eq name "max") (ir.CompilerIrVectorReduceOp.Max)]
    [else
      (ir-text-error
        cur
        (str_cat.str-cat "unknown reduce op " (string.copy name)))]))

(define (ir-text-mask-reduce-op
  [cur : (& cur IrTextCursor)]
  [name : (& name str)]) : ir.CompilerIrMaskReduceOp
  (cond
    [(string.eq name "all") (ir.CompilerIrMaskReduceOp.All)]
    [(string.eq name "any") (ir.CompilerIrMaskReduceOp.Any)]
    [else
      (ir-text-error
        cur
        (str_cat.str-cat "unknown mask reduce op " (string.copy name)))]))

(define (ir-text-mask-bin-op [cur : (& cur IrTextCursor)] [name : (& name str)]) : ir.CompilerIrMaskBinOp
  (cond
    [(string.eq name "and") (ir.CompilerIrMaskBinOp.And)]
    [(string.eq name "or") (ir.CompilerIrMaskBinOp.Or)]
    [else
      (ir-text-error
        cur
        (str_cat.str-cat "unknown mask op " (string.copy name)))]))

;; --- instructions -----------------------------------------------------------
(define (ir-text-phi-inputs! [cur : (&mut cur IrTextCursor)]) : ir.CompilerIrPhiInputSeq
  (let
    [builder : ir.CompilerIrPhiInputBuilder
      (ir.compiler-ir-phi-input-builder-with-capacity 2)]
    (begin
      (while (ir-text-accept! cur "[")
        (let
          [value : ir.CompilerIrValue (ir-text-value! cur)]
          (begin
            (ir-text-expect! cur ",")
            (ir.compiler-ir-phi-input-builder-push!
              (&mut builder)
              (ir.compiler-ir-phi-input-of value (ir-text-label! cur)))
            (ir-text-expect! cur "]")
            (ir-text-accept! cur ",")
            unit)))
      (ir.compiler-ir-phi-input-builder-to-seq builder))))

(define (ir-text-switch-cases! [cur : (&mut cur IrTextCursor)]) : ir.CompilerIrSwitchCaseSeq
  (let
    [builder : ir.CompilerIrSwitchCaseBuilder
      (ir.compiler-ir-switch-case-builder-with-capacity 4)]
    (begin
      (ir-text-expect! cur "[")
      (while (not (ir-text-accept! cur "]"))
        (let
          [tag : i64 (ir-text-int! cur)]
          (begin
            (ir-text-expect! cur ":")
            (ir.compiler-ir-switch-case-builder-push!
              (&mut builder)
              (ir.CompilerIrSwitchCase.Case tag (ir-text-label! cur)))
            (ir-text-accept! cur ",")
            unit)))
      (ir.compiler-ir-switch-case-builder-to-seq builder))))

(define (ir-text-c-abi-slots! [cur : (&mut cur IrTextCursor)]) : ir.CompilerIrCAbiReturnSlotSeq
  (let
    [slots : (__tl_dyn-array ir.CompilerIrCAbiReturnSlot)
      (__tl_make-array ir.CompilerIrCAbiReturnSlot 8)]
    [count : i64 0]
    (begin
      (ir-text-expect! cur "[")
      (while (not (ir-text-accept! cur "]"))
        (let
          [ty : ast.AstType (ir-text-type! cur)]
          (begin
            (ir-text-expect! cur "@")
            (set!
              (array-ref slots count)
              (ir.CompilerIrCAbiReturnSlot.Slot ty (ir-text-int! cur)))
            (set! count (+ count 1))
            (ir-text-accept! cur ",")
            unit)))
      (let
        [exact : (__tl_dyn-array ir.CompilerIrCAbiReturnSlot)
          (__tl_make-array ir.CompilerIrCAbiReturnSlot count)]
        [i : i64 0]
        (begin
          (while (< i count)
            (begin
              (set! (array-ref exact i) (clone (array-ref slots i)))
              (set! i (+ i 1))))
          (ir.compiler-ir-c-abi-return-slot-seq-of exact count))))))

;; `name(args)` of a direct call.
(define (ir-text-callee-symbol! [cur : (&mut cur IrTextCursor)]) : i64
  (ir-text-symbol (ir-text-word! cur "(")))

;; The vector and mask families: `vector_<binop>`, `vector_prefix_<op>`,
;; `vector_reduce_<op>`, `vector_compare_<binop>`, `mask_<op>`.
(define (ir-text-lane-instr!
  [cur : (&mut cur IrTextCursor)]
  [dst : i64]
  [op : (& op str)]) : ir.CompilerIrInstr
  (cond
    [(string.is-string-prefix-at op "vector_prefix_" 0)
      (let
        [prefix-op : ir.CompilerIrVectorPrefixOp
          (ir-text-vector-prefix-op cur (ir-text-after op "vector_prefix_"))]
        [src : ir.CompilerIrValue (ir-text-value! cur)]
        [carry : ir.CompilerIrValue
          (begin
            (ir-text-expect! cur ", carry")
            (ir-text-value! cur))]
        [lanes : i64 (ir-text-lanes! cur)]
        (ir.CompilerIrInstr.VectorPrefix
          (box
            (ir.CompilerIrInstrVectorPrefixPayload
              dst
              prefix-op
              src
              carry
              lanes
              (ir-text-typed! cur)))))]
    [(string.is-string-prefix-at op "vector_reduce_" 0)
      (let
        [reduce-op : ir.CompilerIrVectorReduceOp
          (ir-text-vector-reduce-op cur (ir-text-after op "vector_reduce_"))]
        [value : ir.CompilerIrValue (ir-text-value! cur)]
        [lanes : i64 (ir-text-lanes! cur)]
        (ir.CompilerIrInstr.VectorReduce
          dst
          reduce-op
          value
          lanes
          (ir-text-typed! cur)))]
    [(string.is-string-prefix-at op "vector_compare_" 0)
      (let
        [name : String (ir-text-after op "vector_compare_")]
        [index : i64 (ir-text-binop-index (& name))]
        [lhs : ir.CompilerIrValue (ir-text-value! cur)]
        [rhs : ir.CompilerIrValue (ir-text-comma-value! cur)]
        [lanes : i64 (ir-text-lanes! cur)]
        [ty : ast.AstType (ir-text-typed! cur)]
        (if (< index 0)
          (ir-text-error
            cur
            (str_cat.str-cat "unknown operation " (string.copy op)))
          (ir.CompilerIrInstr.VectorCompare
            (box
              (ir.CompilerIrInstrVectorComparePayload
                dst
                (ir-text-binop index (clone ty))
                lhs
                rhs
                lanes
                ty)))))]
    [(string.is-string-prefix-at op "vector_" 0)
      (let
        [name : String (ir-text-after op "vector_")]
        [index : i64 (ir-text-binop-index (& name))]
        [lhs : ir.CompilerIrValue (ir-text-value! cur)]
        [rhs : ir.CompilerIrValue (ir-text-comma-value! cur)]
        [lanes : i64 (ir-text-lanes! cur)]
        [ty : ast.AstType (ir-text-typed! cur)]
        (if (< index 0)
          (ir-text-error
            cur
            (str_cat.str-cat "unknown operation " (string.copy op)))
          (ir.CompilerIrInstr.VectorBinOp
            (box
              (ir.CompilerIrInstrVectorBinOpPayload
                dst
                (ir-text-binop index (clone ty))
                lhs
                rhs
                lanes
                ty)))))]
    [(string.eq op "mask_not")
      (let
        [value : ir.CompilerIrValue (ir-text-value! cur)]
        (ir.CompilerIrInstr.MaskNot dst value (ir-text-lanes! cur)))]
    [(string.is-string-prefix-at op "mask_reduce_" 0)
      (let
        [reduce-op : ir.CompilerIrMaskReduceOp
          (ir-text-mask-reduce-op cur (ir-text-after op "mask_reduce_"))]
        [value : ir.CompilerIrValue (ir-text-value! cur)]
        (ir.CompilerIrInstr.MaskReduce dst reduce-op value (ir-text-lanes! cur)))]
    [else
      (let
        [mask-op : ir.CompilerIrMaskBinOp
          (ir-text-mask-bin-op cur (ir-text-after op "mask_"))]
        [lhs : ir.CompilerIrValue (ir-text-value! cur)]
        [rhs : ir.CompilerIrValue (ir-text-comma-value! cur)]
        (ir.CompilerIrInstr.MaskBinOp dst mask-op lhs rhs (ir-text-lanes! cur)))]))

;; The operation after `%dst =`.
(define (ir-text-dst-instr!
  [cur : (&mut cur IrTextCursor)]
  [dst : i64]
  [op : (& op str)]) : ir.CompilerIrInstr
  (let
    [binop : i64 (ir-text-binop-index op)]
    [unop : i64 (ir-text-unop-index op)]
    (cond
      [(>= binop 0)
        (let
          [lhs : ir.CompilerIrValue (ir-text-value! cur)]
          [rhs : ir.CompilerIrValue (ir-text-comma-value! cur)]
          [ty : ast.AstType (ir-text-typed! cur)]
          (ir.CompilerIrInstr.BinOp
            dst
            (ir-text-binop binop (clone ty))
            lhs
            rhs
            ty))]
      [(>= unop 0)
        (let
          [value : ir.CompilerIrValue (ir-text-value! cur)]
          (ir.CompilerIrInstr.UnOp
            dst
            (ir-text-unop unop)
            value
            (ir-text-typed! cur)))]
      [(string.eq op "mov")
        (let
          [value : ir.CompilerIrValue (ir-text-value! cur)]
          (ir.CompilerIrInstr.Mov dst value (ir-text-typed! cur)))]
      [(string.eq op "alloc")
        (ir.CompilerIrInstr.Alloc dst (ir-text-type! cur))]
      [(string.eq op "addr_of")
        (ir.CompilerIrInstr.AddrOf dst (ir-text-var! cur))]
      [(string.eq op "gep")
        (let
          [base : ir.CompilerIrValue (ir-text-value! cur)]
          [offset : ir.CompilerIrValue (ir-text-comma-value! cur)]
          (ir.CompilerIrInstr.Gep dst base offset (ir-text-typed! cur)))]
      [(string.eq op "load")
        (let
          [source : ir.CompilerIrValue (ir-text-value! cur)]
          (ir.CompilerIrInstr.Load dst source (ir-text-typed! cur)))]
      [(or (string.eq op "cast") (string.eq op "bitcast"))
        (let
          [value : ir.CompilerIrValue (ir-text-value! cur)]
          [from : ast.AstType (ir-text-typed! cur)]
          [to : ast.AstType
            (begin
              (ir-text-expect! cur "to")
              (ir-text-type! cur))]
          (if (string.eq op "cast")
            (ir.CompilerIrInstr.Cast dst value from to)
            (ir.CompilerIrInstr.Bitcast dst value from to)))]
      [(string.eq op "lane_id")
        (let
          [lanes : i64 (ir-text-int! cur)]
          (ir.CompilerIrInstr.LaneId dst lanes (ir-text-typed! cur)))]
      [(string.eq op "splat")
        (let
          [value : ir.CompilerIrValue (ir-text-value! cur)]
          [lanes : i64 (ir-text-lanes! cur)]
          (ir.CompilerIrInstr.Splat dst value lanes (ir-text-typed! cur)))]
      [(string.eq op "select")
        (let
          [mask : ir.CompilerIrValue (ir-text-value! cur)]
          [on-true : ir.CompilerIrValue (ir-text-comma-value! cur)]
          [on-false : ir.CompilerIrValue (ir-text-comma-value! cur)]
          [lanes : i64 (ir-text-lanes! cur)]
          (ir.CompilerIrInstr.Select
            (box
              (ir.CompilerIrInstrSelectPayload
                dst
                mask
                on-true
                on-false
                lanes
                (ir-text-typed! cur)))))]
      [(string.eq op "vector_load")
        (let
          [base : ir.CompilerIrValue (ir-text-value! cur)]
          [index : ir.CompilerIrValue (ir-text-comma-value! cur)]
          [lanes : i64 (ir-text-lanes! cur)]
          (ir.CompilerIrInstr.VectorLoad
            dst
            base
            index
            lanes
            (ir-text-typed! cur)))]
      [(string.eq op "predicated_load")
        (let
          [base : ir.CompilerIrValue (ir-text-value! cur)]
          [index : ir.CompilerIrValue (ir-text-comma-value! cur)]
          [mask : ir.CompilerIrValue
            (begin
              (ir-text-expect! cur "mask")
              (ir-text-value! cur))]
          [lanes : i64 (ir-text-lanes! cur)]
          (ir.CompilerIrInstr.PredicatedLoad
            (box
              (ir.CompilerIrInstrPredicatedLoadPayload
                dst
                base
                index
                mask
                lanes
                (ir-text-typed! cur)))))]
      [(string.eq op "gather_load")
        (let
          [base : ir.CompilerIrValue (ir-text-value! cur)]
          [index-base : ir.CompilerIrValue (ir-text-comma-value! cur)]
          [index : ir.CompilerIrValue (ir-text-comma-value! cur)]
          [lane-offset : bool
            (begin
              (ir-text-expect! cur "lane_offset")
              (string.eq (ir-text-word! cur "") "true"))]
          [lanes : i64 (ir-text-lanes! cur)]
          (ir.CompilerIrInstr.GatherLoad
            (box
              (ir.CompilerIrInstrGatherLoadPayload
                dst
                base
                index-base
                index
                lane-offset
                lanes
                (ir-text-typed! cur)))))]
      [(string.eq op "vector_shuffle")
        (let
          [source : ir.CompilerIrValue (ir-text-value! cur)]
          [selector-low : ir.CompilerIrValue (ir-text-comma-value! cur)]
          [selector-high : ir.CompilerIrMaybeValue
            (begin
              (ir-text-expect! cur ",")
              (if (ir-text-accept! cur "active")
                (ir.CompilerIrMaybeValue.No)
                (let
                  [high : ir.CompilerIrValue (ir-text-value! cur)]
                  (begin
                    (ir-text-expect! cur "active")
                    (ir.CompilerIrMaybeValue.Some high)))))]
          [active-lanes : ir.CompilerIrValue (ir-text-value! cur)]
          [lanes : i64 (ir-text-lanes! cur)]
          (ir.CompilerIrInstr.VectorShuffle
            (box
              (ir.CompilerIrInstrVectorShufflePayload
                dst
                source
                selector-low
                selector-high
                active-lanes
                lanes
                (ir-text-typed! cur)))))]
      [(string.eq op "tail_mask")
        (let
          [index : ir.CompilerIrValue (ir-text-value! cur)]
          [length : ir.CompilerIrValue (ir-text-comma-value! cur)]
          (ir.CompilerIrInstr.TailMask dst index length (ir-text-lanes! cur)))]
      [(or
          (string.is-string-prefix-at op "vector_" 0)
          (string.is-string-prefix-at op "mask_" 0))
        (ir-text-lane-instr! cur dst op)]
      [(string.eq op "entry_argc") (ir.CompilerIrInstr.EntryArgc dst)]
      [(string.eq op "entry_argv") (ir.CompilerIrInstr.EntryArgv dst)]
      [(string.eq op "entry_envp") (ir.CompilerIrInstr.EntryEnvp dst)]
      [(string.eq op "cpuid")
        (let
          [leaf : ir.CompilerIrValue (ir-text-value! cur)]
          [subleaf : ir.CompilerIrValue (ir-text-comma-value! cur)]
          (begin
            (ir-text-expect! cur "word")
            (ir.CompilerIrInstr.CpuId dst leaf subleaf (ir-text-int! cur))))]
      [(string.eq op "xgetbv")
        (ir.CompilerIrInstr.Xgetbv dst (ir-text-value! cur))]
      [(string.eq op "syscall")
        (ir.CompilerIrInstr.Syscall dst (ir-text-call-args! cur))]
      [(string.eq op "call")
        (let
          [name : i64 (ir-text-callee-symbol! cur)]
          [args : ir.CompilerIrCallArgs (ir-text-call-args! cur)]
          (ir.CompilerIrInstr.Call dst name args (ir-text-typed! cur)))]
      [(or (string.eq op "call*") (string.eq op "call_c*"))
        (let
          [callee : ir.CompilerIrValue (ir-text-value! cur)]
          [args : ir.CompilerIrCallArgs (ir-text-call-args! cur)]
          [ty : ast.AstType (ir-text-typed! cur)]
          (if (string.eq op "call*")
            (ir.CompilerIrInstr.CallIndirect dst callee args ty)
            (ir.CompilerIrInstr.CallIndirectC dst callee args ty)))]
      [(string.eq op "phi")
        (let
          [inputs : ir.CompilerIrPhiInputSeq (ir-text-phi-inputs! cur)]
          (ir.CompilerIrInstr.Phi dst inputs (ir-text-typed! cur)))]
      [(string.eq op "pack")
        (begin
          (ir-text-expect! cur "[")
          (let
            [values : ir.CompilerIrValueSeq (ir-text-values! cur "]")]
            (ir.CompilerIrInstr.Pack dst values (ir-text-typed! cur))))]
      [(string.eq op "word")
        (let
          [value : ir.CompilerIrValue (ir-text-value! cur)]
          [index : i64
            (begin
              (ir-text-expect! cur ",")
              (ir-text-int! cur))]
          (ir.CompilerIrInstr.Word dst value index (ir-text-typed! cur)))]
      [else
        (ir-text-error
          cur
          (str_cat.str-cat "unknown operation " (string.copy op)))])))

;; An instruction without a destination.
(define (ir-text-effect-instr!
  [cur : (&mut cur IrTextCursor)]
  [op : (& op str)]) : ir.CompilerIrInstr
  (cond
    [(string.eq op "jump") (ir.CompilerIrInstr.Jump (ir-text-label! cur))]
    [(string.eq op "branch")
      (let
        [test : ir.CompilerIrValue (ir-text-value! cur)]
        [on-true : i64
          (begin
            (ir-text-expect! cur ",")
            (ir-text-label! cur))]
        [on-false : i64
          (begin
            (ir-text-expect! cur ",")
            (ir-text-label! cur))]
        (ir.CompilerIrInstr.Branch test on-true on-false))]
    [(string.eq op "return")
      (ir.CompilerIrInstr.Return (ir-text-maybe-value! cur))]
    [(string.eq op "store")
      (let
        [global : i64
          (begin
            (ir-text-expect! cur "@")
            (ir-text-symbol (ir-text-word! cur ",")))]
        [value : ir.CompilerIrValue (ir-text-comma-value! cur)]
        (ir.CompilerIrInstr.Store global value (ir-text-typed! cur)))]
    [(string.eq op "store_ptr")
      (let
        [ptr : ir.CompilerIrValue (ir-text-value! cur)]
        [value : ir.CompilerIrValue (ir-text-comma-value! cur)]
        (ir.CompilerIrInstr.StorePtr ptr value (ir-text-typed! cur)))]
    [(string.eq op "store_owned")
      (let
        [value : ir.CompilerIrValue (ir-text-value! cur)]
        [ptr : ir.CompilerIrValue
          (begin
            (ir-text-expect! cur "->")
            (ir-text-value! cur))]
        (ir.CompilerIrInstr.StoreOwned ptr value (ir-text-typed! cur)))]
    [(string.eq op "copy_bytes")
      (let
        [dst : ir.CompilerIrValue (ir-text-value! cur)]
        [src : ir.CompilerIrValue (ir-text-comma-value! cur)]
        (begin
          (ir-text-expect! cur ",")
          (ir.CompilerIrInstr.CopyBytes dst src (ir-text-int! cur))))]
    [(string.eq op "bounds_check")
      (let
        [index : ir.CompilerIrValue (ir-text-value! cur)]
        [length : ir.CompilerIrValue (ir-text-comma-value! cur)]
        (begin
          (ir-text-expect! cur "message \"")
          (let
            [start : i64 cur.pos]
            [end : i64 (- (string.string-length cur.line) 1)]
            (if (and (> end start) (= (string.char-at cur.line end) '"'))
              (begin
                (set! cur.pos (+ end 1))
                (ir.CompilerIrInstr.BoundsCheck
                  index
                  length
                  (ir.compiler-ir-label
                    (string.substring cur.line start (- end start)))))
              (ir-text-error cur "expected a quoted message")))))]
    [(or (string.eq op "vector_store") (string.eq op "predicated_store"))
      (let
        [base : ir.CompilerIrValue (ir-text-value! cur)]
        [index : ir.CompilerIrValue (ir-text-comma-value! cur)]
        [value : ir.CompilerIrValue (ir-text-comma-value! cur)]
        (if (string.eq op "vector_store")
          (let
            [lanes : i64 (ir-text-lanes! cur)]
            (ir.CompilerIrInstr.VectorStore
              (box
                (ir.CompilerIrInstrVectorStorePayload
                  base
                  index
                  value
                  lanes
                  (ir-text-typed! cur)))))
          (let
            [mask : ir.CompilerIrValue
              (begin
                (ir-text-expect! cur "mask")
                (ir-text-value! cur))]
            [lanes : i64 (ir-text-lanes! cur)]
            (ir.CompilerIrInstr.PredicatedStore
              (box
                (ir.CompilerIrInstrPredicatedStorePayload
                  base
                  index
                  value
                  mask
                  lanes
                  (ir-text-typed! cur)))))))]
    [(string.eq op "call_c_store")
      (let
        [name : i64 (ir-text-callee-symbol! cur)]
        [args : ir.CompilerIrCallArgs (ir-text-call-args! cur)]
        [base : ir.CompilerIrValue
          (begin
            (ir-text-expect! cur "->")
            (ir-text-value! cur))]
        (ir.CompilerIrInstr.CallCAbiStoreResult
          (box
            (ir.CompilerIrInstrCallCAbiStoreResultPayload
              base
              name
              args
              (ir-text-c-abi-slots! cur)))))]
    [(string.eq op "call_c_store*")
      (let
        [callee : ir.CompilerIrValue (ir-text-value! cur)]
        [args : ir.CompilerIrCallArgs (ir-text-call-args! cur)]
        [base : ir.CompilerIrValue
          (begin
            (ir-text-expect! cur "->")
            (ir-text-value! cur))]
        (ir.CompilerIrInstr.CallIndirectCAbiStoreResult
          (box
            (ir.CompilerIrInstrCallIndirectCAbiStoreResultPayload
              base
              callee
              args
              (ir-text-c-abi-slots! cur)))))]
    [(string.eq op "tailcall")
      (let
        [name : i64 (ir-text-callee-symbol! cur)]
        [args : ir.CompilerIrCallArgs (ir-text-call-args! cur)]
        (ir.CompilerIrInstr.TailCall name args (ir-text-typed! cur)))]
    [(string.eq op "tailcall*")
      (let
        [callee : ir.CompilerIrValue (ir-text-value! cur)]
        [args : ir.CompilerIrCallArgs (ir-text-call-args! cur)]
        (ir.CompilerIrInstr.TailCallIndirect callee args (ir-text-typed! cur)))]
    [(string.eq op "switch")
      (let
        [index : ir.CompilerIrValue (ir-text-value! cur)]
        [base : i64
          (begin
            (ir-text-expect! cur "base")
            (ir-text-int! cur))]
        [cases : ir.CompilerIrSwitchCaseSeq (ir-text-switch-cases! cur)]
        (begin
          (ir-text-expect! cur "default")
          (ir.CompilerIrInstr.Switch index base cases (ir-text-label! cur))))]
    [else
      (ir-text-error
        cur
        (str_cat.str-cat "unknown instruction " (string.copy op)))]))

(define (ir-text-instr-line [line : String]) : ir.CompilerIrInstr
  (let
    [cur : IrTextCursor (ir-text-cursor line)]
    [instr : ir.CompilerIrInstr
      (if (ir-text-accept! (&mut cur) "%")
        (let
          [dst : i64 (ir-text-int! (&mut cur))]
          [op : String
            (begin
              (ir-text-expect! (&mut cur) "=")
              (ir-text-word! (&mut cur) "("))]
          (ir-text-dst-instr! (&mut cur) dst (& op)))
        (let
          [op : String (ir-text-word! (&mut cur) "(")]
          (ir-text-effect-instr! (&mut cur) (& op))))]
    (if (ir-text-at-end? (&mut cur))
      instr
      (ir-text-error (& cur) "unexpected text after the instruction"))))

;; The instruction lines up to the next label, `}` or the end.
(define (ir-text-instr-lines! [doc : (&mut doc IrTextLines)]) : ir.CompilerIrInstrSeq
  (let
    [count : i64 0]
    (begin
      (while (and
        (< (+ doc.next count) doc.count)
        (not (ir-text-label-line? (& (array-ref doc.lines (+ doc.next count)))))
        (not (string.eq (& (array-ref doc.lines (+ doc.next count))) "}")))
        (set! count (+ count 1)))
      (let
        [builder : ir.CompilerIrInstrBuilder
          (ir.compiler-ir-instr-builder-with-capacity count)]
        [i : i64 0]
        (begin
          (while (< i count)
            (begin
              (ir.compiler-ir-instr-builder-push!
                (&mut builder)
                (ir-text-instr-line (ir-text-lines-take! doc)))
              (set! i (+ i 1))))
          (ir.compiler-ir-instr-builder-to-seq builder))))))

(define (ir-text-block! [doc : (&mut doc IrTextLines)]) : ir.CompilerIrBlock
  (let
    [line : String (ir-text-lines-take! doc)]
    (if (ir-text-label-line? (& line))
      (let
        [label : i64
          (ir.compiler-ir-label
            (string.substring line 0 (- (string.string-length line) 1)))]
        (ir.CompilerIrBlock.Block label (ir-text-instr-lines! doc)))
      (ir-text-fail line "expected a block label"))))

(define (ir-text-blocks! [doc : (&mut doc IrTextLines)]) : ir.CompilerIrBlockList
  (if (and
    (ir-text-lines-more? doc)
    (ir-text-label-line? (& (array-ref doc.lines doc.next))))
    (let
      [first : ir.CompilerIrBlock (ir-text-block! doc)]
      (ir.compiler-ir-block-cons first (ir-text-blocks! doc)))
    (ir.CompilerIrBlockList.Nil)))

;; `name=%var:type`, comma separated, up to the closing `close`.
(define (ir-text-count-from
  [text : (& text str)]
  [needle : (& needle str)]
  [start : i64]) : i64
  (let
    [count : i64 0]
    [i : i64 start]
    (begin
      (while (< i (string.string-length text))
        (begin
          (if (string.is-string-prefix-at text needle i)
            (set! count (+ count 1))
            unit)
          (set! i (+ i 1))))
      count)))

;; `name=%var:type`, comma separated, up to the closing `close` or, when
;; `close` is empty, the end of the line.
(define (ir-text-params!
  [cur : (&mut cur IrTextCursor)]
  [close : (& close str)]) : ir.CompilerIrParamSeq
  (let
    [builder : ir.CompilerIrParamBuilder
      (ir.compiler-ir-param-builder-with-capacity
        (ir-text-count-from cur.line "=%" cur.pos))]
    (begin
      (while (not
        (if (= (string.string-length close) 0)
          (ir-text-at-end? cur)
          (ir-text-accept! cur close)))
        (let
          [name : String (ir-text-word! cur "=")]
          [var : i64
            (begin
              (ir-text-expect! cur "=%")
              (ir-text-int! cur))]
          (begin
            (ir-text-expect! cur ":")
            (ir.compiler-ir-param-builder-push!
              (&mut builder)
              (ir.CompilerIrParam.Param name (ir-text-type! cur) var))
            (ir-text-accept! cur ",")
            unit)))
      (ir.compiler-ir-param-builder-to-seq builder))))

(define (ir-text-function! [doc : (&mut doc IrTextLines)]) : ir.CompilerIrFunction
  (let
    [cur : IrTextCursor (ir-text-cursor (ir-text-lines-take! doc))]
    [name : i64
      (begin
        (ir-text-expect! (&mut cur) "function @")
        (ir-text-callee-symbol! (&mut cur)))]
    [params : ir.CompilerIrParamSeq
      (begin
        (ir-text-expect! (&mut cur) "(")
        (ir-text-params! (&mut cur) ")"))]
    [ret : ast.AstType
      (begin
        (ir-text-expect! (&mut cur) "->")
        (ir-text-type! (&mut cur)))]
    [vars : i64
      (begin
        (ir-text-expect! (&mut cur) "vars")
        (ir-text-int! (&mut cur)))]
    (begin
      (ir-text-expect! (&mut cur) "{")
      (if (ir-text-at-end? (&mut cur))
        unit
        (ir-text-error (& cur) "only ordinary functions have a text form"))
      (let
        [blocks : ir.CompilerIrBlockList (ir-text-blocks! doc)]
        (if (string.eq (ir-text-lines-take! doc) "}")
          (ir.CompilerIrFunction.Function
            name
            params
            ret
            vars
            blocks
            ir.CompilerIrFunctionAbi.Ordinary)
          (ir-text-fail cur.line "function without a closing `}`"))))))

(define (ir-text-global-line [line : String]) : ir.CompilerIrGlobal
  (let
    [cur : IrTextCursor (ir-text-cursor line)]
    [name : i64
      (begin
        (ir-text-expect! (&mut cur) "global @")
        (ir-text-symbol (ir-text-word! (&mut cur) "")))]
    [ty : ast.AstType (ir-text-typed! (&mut cur))]
    (begin
      (ir-text-expect! (&mut cur) "=")
      (ir.CompilerIrGlobal.Global name ty (ir-text-value! (&mut cur))))))

;; --- entry points -----------------------------------------------------------
;: Read one instruction line, such as `%3 = add %1, %2 : i64`.
(define (instr [text : String]) : ir.CompilerIrInstr
  (ir-text-instr-line (string.trim text)))

;: Read instruction lines into a dense sequence.
(define (instrs [text : String]) : ir.CompilerIrInstrSeq
  (let
    [doc : IrTextLines (ir-text-lines text)]
    [seq : ir.CompilerIrInstrSeq (ir-text-instr-lines! (&mut doc))]
    (begin
      (ir-text-lines-done! (& doc))
      seq)))

;: Read one labelled block.
(define (block [text : String]) : ir.CompilerIrBlock
  (let
    [doc : IrTextLines (ir-text-lines text)]
    [one : ir.CompilerIrBlock (ir-text-block! (&mut doc))]
    (begin
      (ir-text-lines-done! (& doc))
      one)))

;: Read labelled blocks into a cons block list.
(define (blocks [text : String]) : ir.CompilerIrBlockList
  (let
    [doc : IrTextLines (ir-text-lines text)]
    [list : ir.CompilerIrBlockList (ir-text-blocks! (&mut doc))]
    (begin
      (ir-text-lines-done! (& doc))
      list)))

;: Read a parameter list such as `a=%0:i64, b=%1:i64`.
(define (params [text : String]) : ir.CompilerIrParamSeq
  (let
    [cur : IrTextCursor (ir-text-cursor (string.trim text))]
    (ir-text-params! (&mut cur) "")))

;: Read one `function @name(params) -> type vars n { ... }`.
(define (func [text : String]) : ir.CompilerIrFunction
  (let
    [doc : IrTextLines (ir-text-lines text)]
    [one : ir.CompilerIrFunction (ir-text-function! (&mut doc))]
    (begin
      (ir-text-lines-done! (& doc))
      one)))

;: Read a whole program: the optional `typelisp-ir v1` header, `global` lines
;: and functions.
(define (program [text : String]) : ir.CompilerIrProgram
  (let
    [doc : IrTextLines (ir-text-lines text)]
    [globals : ir.CompilerIrGlobalBuilder
      (ir.compiler-ir-global-builder-with-capacity
        (ir-text-lines-count-prefix (& doc) "global @"))]
    [functions : ir.CompilerIrFunctionBuilder
      (ir.compiler-ir-function-builder-with-capacity
        (ir-text-lines-count-prefix (& doc) "function @"))]
    (begin
      (if (string.eq (ir-text-lines-peek (& doc)) "typelisp-ir v1")
        (begin
          (ir-text-lines-take! (&mut doc))
          unit)
        unit)
      (while (string.is-string-prefix-at
        (ir-text-lines-peek (& doc))
        "global @"
        0)
        (ir.compiler-ir-global-builder-push!
          (&mut globals)
          (ir-text-global-line (ir-text-lines-take! (&mut doc)))))
      (while (ir-text-lines-more? (& doc))
        (ir.compiler-ir-function-builder-push!
          (&mut functions)
          (ir-text-function! (&mut doc))))
      (ir.CompilerIrProgram.Program
        (ir.compiler-ir-global-builder-to-seq globals)
        (ir.compiler-ir-function-builder-to-seq functions)
        (ir.compiler-ir-extern-seq-empty)))))

(define (ir-text-session) : cis.InternStructuralSessionHandle
  (cis.InternStructuralSessionHandle 0))

;: The text `instrs` reads back: one rendered instruction per line.
(define (instrs-text [seq : ir.CompilerIrInstrSeq]) : String
  (ir.compiler-ir-instr-seq-render-from
    (ir-text-session)
    (ast.ast-node-pool-reader-type-segment-bases)
    seq
    0))

;: The text `blocks` reads back.
(define (blocks-text [list : ir.CompilerIrBlockList]) : String
  (ir.compiler-ir-block-list-render
    (ir-text-session)
    (ast.ast-node-pool-reader-type-segment-bases)
    list))

;: The text `program` reads back.
(define (program-text [whole : ir.CompilerIrProgram]) : String
  (ir.compiler-ir-program-render
    (ir-text-session)
    (ast.ast-node-pool-reader-type-segment-bases)
    whole))

;; Every instruction form and every type constructor the renderer writes.
(cfg
  test
  (define (ir-text-every-form) : String
    "entry:
  %1 = mov 5 : i64
  %2 = alloc (Array i64 4)
  %3 = addr_of %2
  %4 = gep %3, 8 : i64
  %5 = load %4 : i64
  store_owned %5 -> %4 : String
  store_ptr %4, -3 : i64
  copy_bytes %4, %3, 16
  bounds_check %1, %5 message \"index out of bounds\"
  %6 = cast %5 : i64 to u8
  %7 = bitcast %5 : i64 to f64
  %8 = add %1, %5 : i64
  %9 = shl %8, 2 : u32
  %10 = bit_and %8, 255 : i64
  %11 = bit_test_ne %8, %10 : i64
  %12 = neg %8 : i64
  %13 = bit_length %8 : u64
  %14 = lane_id 8 : i32
  %15 = splat %1 lanes 8 : i64
  %16 = vector_add %15, %15 lanes 8 : i64
  %17 = vector_prefix_sum %16, carry %1 lanes 8 : i64
  %18 = vector_reduce_max %17 lanes 8 : i64
  %19 = vector_compare_lt %15, %16 lanes 8 : i64
  %20 = mask_and %19, %19 lanes 8
  %21 = mask_not %20 lanes 8
  %22 = mask_reduce_any %21 lanes 8
  %23 = select %19, %15, %16 lanes 8 : i64
  %24 = vector_load %3, %1 lanes 8 : i64
  vector_store %3, %1, %24 lanes 8 : i64
  predicated_store %3, %1, %24 mask %19 lanes 8 : i64
  %25 = predicated_load %3, %1 mask %19 lanes 8 : i64
  %26 = gather_load %3, %1, %14 lane_offset true lanes 8 : i64
  %27 = vector_shuffle %24, %14, %14 active 8 lanes 8 : i64
  %28 = vector_shuffle %24, %14,  active 8 lanes 8 : i64
  %29 = tail_mask %1, %5 lanes 8
  %30 = entry_argc
  %31 = entry_argv
  %32 = entry_envp
  %33 = cpuid 7, 0 word 1
  %34 = xgetbv 0
  %35 = syscall(60, %1)
  %36 = call ir_text_helper(%1, @ir_text_g, &@ir_text_g, fn@ir_text_helper) : i64
  %37 = call* %36() : unit
  %38 = call_c* %36(true, false, unit, float-bits:4607182418800017408) : f64
  call_c_store ir_text_helper(%1) -> %3 [i64@0, f64@8]
  call_c_store* %36([sret arg 0] %3, %1) -> %3 [i64@0]
  store @ir_text_g, runtime-init@ir_text_g : (__tl_dyn-array i64)
  %39 = phi [%1, entry], [%8, loop] : i64
  %40 = pack [%1, %5] : (Tuple i64 bool)
  %41 = word %40, 1 : (-> i64 (Ptr u8) (MutPtr char))
  %42 = mov %41 : (->  unit)
  %43 = mov %41 : (CFunc nullable (-> i64 i64))
  %44 = mov %41 : (& ir_text_a (Slice i64))
  %45 = mov %41 : (&mut ir_text_a (Box f32))
  %46 = mov %41 : (Region ir_text_a IrTextPair)
  %47 = mov %41 : (IrTextPair ir_text_a)
  switch %1 base 0 [0:entry, 1:loop] default exit

loop:
  tailcall ir_text_helper(%1) : i64

exit:
  tailcall* %36(%1, %5, %8) : i64
  return 
"))

(test
  ir-text-reads-back-every-form
  (test.assert-true
    (string.eq (blocks-text (blocks (ir-text-every-form))) (ir-text-every-form))
    "rendering the read blocks reproduces the text"))

(test
  ir-text-reads-back-a-program
  (let
    [text : String
      "typelisp-ir v1
global @ir_text_g : i64 = 7

function @ir_text_f(a=%0:i64, b=%1:(& ir_text_a (Slice i64))) -> i64 vars 3 {
entry:
  %2 = add %0, 1 : i64
  branch %2, done, entry

done:
  return %2
}

function @ir_text_h() -> unit vars 0 {
entry:
  return 
}
"]
    (test.assert-true
      (string.eq (program-text (program (string.copy (& text)))) text)
      "rendering the read program reproduces the text")))

(test
  ir-text-ignores-indentation
  (test.assert-true
    (string.eq
      (instrs-text
        (instrs
          "
            %1 = mov 5 : i64

            return %1
          "))
      "  %1 = mov 5 : i64
  return %1
")
    "blank lines and indentation are not part of the IR"))