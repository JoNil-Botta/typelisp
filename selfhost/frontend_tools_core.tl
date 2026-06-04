;; frontend_tools_core.tl - Reusable selfhost tokenize/parse helpers (#796).
(import "../stdlib/io.tl")

(import "lex.tl")

(import "compiler_parse_core.tl")

(define (front-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (front-line [text : String]) : unit
  (print-string (string-append text "\n")))

(define (front-error-line [text : String]) : unit
  (print-error (string-append text "\n")))

(define (front-next-is? [src : String] [idx : i64] [n : i64] [want : char]) : bool
  (if (< (+ idx 1) n)
    (= (string-ref src (+ idx 1)) want)
    false))

(define (front-ident-tail? [c : char]) : bool
  (or
    (is-alpha c)
    (or
      (is-digit c)
      (or
        (= c #_')
        (or
          (= c #-')
          (or
            (= c #!')
            (or
              (= c #?')
              (or
                (= c #+')
                (or
                  (= c #*')
                  (or
                    (= c #/')
                    (or
                      (= c #=')
                      (or
                        (= c #<')
                        (or
                          (= c #>')
                          (or (= c #$') (or (= c #.') (or (= c #%') (= c #&')))))))))))))))))

(define (front-scan-ident-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [j : i64 (+ start 1)]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (if (front-ident-tail? (string-ref src j))
            (set! j (+ j 1))
            (set! keep false))
          (set! keep false)))
      j)))

(define (front-number-char? [c : char] [seen-dot : bool]) : bool
  (cond
    [(is-digit c) true]
    [(= c #_') true]
    [(= c #.') (not seen-dot)]
    [else false]))

(define (front-scan-number-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [seen-dot : bool false]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (let
            [c : char (string-ref src j)]
            (if (front-number-char? c seen-dot)
              (begin
                (if (= c #.')
                  (set! seen-dot true)
                  unit)
                (set! j (+ j 1)))
              (set! keep false)))
          (set! keep false)))
      j)))

(define (front-strip-underscores [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (if (= (string-ref text i) #_')
            unit
            (set! out (string-append out (substring text i 1))))
          (set! i (+ i 1))))
      out)))

(define (front-has-dot? [text : String]) : bool
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (begin
          (if (= (string-ref text i) #.')
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

(define (front-trim-float-len [text : String]) : i64
  (let
    [end : i64 (string-length text)]
    [keep : bool true]
    (begin
      (while keep
        (if (> end 0)
          (let
            [c : char (string-ref text (- end 1))]
            (if (= c #0')
              (set! end (- end 1))
              (set! keep false)))
          (set! keep false)))
      (if (> end 0)
        (if (= (string-ref text (- end 1)) #.')
          (- end 1)
          end)
        end))))

(define (front-normalize-number [text : String]) : String
  (let
    [clean : String (front-strip-underscores text)]
    (if (front-has-dot? clean)
      (substring clean 0 (front-trim-float-len clean))
      clean)))

(define (front-print-string-token [text : String]) : unit
  (begin
    (print-string "\"")
    (print-string text)
    (print-string "\"\n")))

(define (front-print-char-token-body [body : String]) : unit
  (begin
    (print-string "'")
    (print-string body)
    (print-string "'\n")))

(defenum FrontScanStep
  (FrontScanStep i64 i64 bool))

(define (front-step-ok [next : i64]) : FrontScanStep
  (FrontScanStep 0 next true))

(define (front-step-error [message : String]) : FrontScanStep
  (begin
    (front-error-line (front-cat3 "lexer error: " message ""))
    (FrontScanStep 1 0 false)))

(define (front-scan-number-token [src : String] [i : i64] [n : i64]) : FrontScanStep
  (let
    [end : i64 (front-scan-number-end src i n)]
    (begin
      (front-line (front-normalize-number (substring src i (- end i))))
      (front-step-ok end))))

(define (front-scan-ident-token [src : String] [i : i64] [n : i64]) : FrontScanStep
  (let
    [end : i64 (front-scan-ident-end src i n)]
    (begin
      (front-line (substring src i (- end i)))
      (front-step-ok end))))

(define (front-scan-string-token [src : String] [i : i64] [n : i64]) : FrontScanStep
  (match (scan-str-end-result src (+ i 1) n)
    [(OkLexI64 end)
      (begin
        (front-print-string-token (unescape-string-literal src (+ i 1) end))
        (front-step-ok (+ end 1)))]
    [(ErrLexI64 message) (front-step-error message)]))

(define (front-scan-char-token [src : String] [i : i64] [n : i64]) : FrontScanStep
  (match (char-literal-value-result src i n)
    [(OkLexChar _)
      (match (char-literal-end-result src i n)
        [(OkLexI64 end)
          (begin
            (front-print-char-token-body
              (substring src (+ i 1) (- end (+ i 2))))
            (front-step-ok end))]
        [(ErrLexI64 message) (front-step-error message)])]
    [(ErrLexChar message) (front-step-error message)]))

(define (front-scan-token [src : String] [i : i64] [n : i64]) : FrontScanStep
  (let
    [c : char (string-ref src i)]
    [step : FrontScanStep (front-step-ok i)]
    [handled : bool false]
    (begin
      (if (is-space c)
        (begin
          (set! step (front-step-ok (+ i 1)))
          (set! handled true))
        unit)
      (if (not handled)
        (if (= c #;')
          (begin
            (set! step (front-step-ok (scan-comment-end src (+ i 1) n)))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (if (= c #(')
          (begin
            (front-line "(")
            (set! step (front-step-ok (+ i 1)))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (if (= c #)')
          (begin
            (front-line ")")
            (set! step (front-step-ok (+ i 1)))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (if (= c #[')
          (begin
            (front-line "[")
            (set! step (front-step-ok (+ i 1)))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (if (= c #]')
          (begin
            (front-line "]")
            (set! step (front-step-ok (+ i 1)))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (if (= c #:')
          (begin
            (front-line ":")
            (set! step (front-step-ok (+ i 1)))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (if (= c #'')
          (begin
            (front-line "'")
            (set! step (front-step-ok (+ i 1)))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (if (= c #`')
          (begin
            (front-line "`")
            (set! step (front-step-ok (+ i 1)))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (if (= c #,')
          (begin
            (if (front-next-is? src i n #@')
              (begin
                (front-line ",@")
                (set! step (front-step-ok (+ i 2))))
              (begin
                (front-line ",")
                (set! step (front-step-ok (+ i 1)))))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (if (= c #.')
          (begin
            (front-line ".")
            (set! step (front-step-ok (+ i 1)))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (if (= c #-')
          (begin
            (if (front-next-is? src i n #>')
              (begin
                (front-line "->")
                (set! step (front-step-ok (+ i 2))))
              (if (negative-number-start? src i n)
                (set! step (front-scan-number-token src i n))
                (set! step (front-scan-ident-token src i n))))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (if (is-digit c)
          (begin
            (set! step (front-scan-number-token src i n))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (if (= c #"')
          (begin
            (set! step (front-scan-string-token src i n))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (if (= c ##')
          (begin
            (set! step (front-scan-char-token src i n))
            (set! handled true))
          unit)
        unit)
      (if (not handled)
        (begin
          (set! step (front-scan-ident-token src i n))
          (set! handled true))
        unit)
      step)))

(define (front-tokenize-string [src : String]) : i64
  (let
    [i : i64 0]
    [n : i64 (string-length src)]
    [status : i64 0]
    [keep : bool true]
    (begin
      (while (and keep (= status 0))
        (if (>= i n)
          (set! keep false)
          (match (front-scan-token src i n)
            [(FrontScanStep next-status next-i next-keep)
              (begin
                (set! status next-status)
                (set! i next-i)
                (set! keep next-keep))])))
      status)))

(define (front-tokenize-file [path : String]) : i64
  (front-tokenize-string (read-file path)))

(define (front-type-list-render [types : AstTypeList]) : String
  (match types
    [(AstTypeNil) ""]
    [(AstTypeCons head rest)
      (string-append
        (front-type-render head)
        (match rest
          [(AstTypeNil) ""]
          [_ (string-append ", " (front-type-list-render rest))]))]))

(define (front-type-render [ty : AstType]) : String
  (match ty
    [(AstTyI64) "I64"]
    [(AstTyI32) "I32"]
    [(AstTyI16) "I16"]
    [(AstTyI8) "I8"]
    [(AstTyU64) "U64"]
    [(AstTyU32) "U32"]
    [(AstTyU16) "U16"]
    [(AstTyU8) "U8"]
    [(AstTyF64) "F64"]
    [(AstTyF32) "F32"]
    [(AstTyBool) "Bool"]
    [(AstTyChar) "Char"]
    [(AstTyString) "String"]
    [(AstTyStr) "Str"]
    [(AstTyUnit) "Unit"]
    [(AstTyNever) "Never"]
    [(AstTyExpr) "Expr"]
    [(AstTyExprList) "ExprList"]
    [(AstTyFunc args ret)
      (front-cat3
        "Func(["
        (front-type-list-render args)
        (front-cat3 "], " (front-type-render ret) ")"))]
    [(AstTyTuple elems)
      (front-cat3 "Tuple([" (front-type-list-render elems) "])")]
    [(AstTyArray elem count)
      (front-cat3
        "Array("
        (front-type-render elem)
        (front-cat3 ", " (int->string count) ")"))]
    [(AstTyDynArray elem) (front-cat3 "DynArray(" (front-type-render elem) ")")]
    [(AstTyBox elem) (front-cat3 "Box(" (front-type-render elem) ")")]
    [(AstTyPtr elem) (front-cat3 "Ptr(" (front-type-render elem) ")")]
    [(AstTyMutPtr elem) (front-cat3 "MutPtr(" (front-type-render elem) ")")]
    [(AstTyRef region inner)
      (front-cat3
        "Ref(\""
        region
        (front-cat3 "\", " (front-type-render inner) ")"))]
    [(AstTyMutRef region inner)
      (front-cat3
        "MutRef(\""
        region
        (front-cat3 "\", " (front-type-render inner) ")"))]
    [(AstTyRegion region inner)
      (front-cat3
        "Region(\""
        region
        (front-cat3 "\", " (front-type-render inner) ")"))]
    [(AstTyEnum name) (front-cat3 "Enum(\"" name "\")")]
    [(AstTyStruct name) (front-cat3 "Struct(\"" name "\")")]
    [(AstTyVar name) (front-cat3 "Var(\"" name "\")")]))

(define (front-binop-render [op : AstBinOp]) : String
  (match op
    [(AstBinAdd) "Add"]
    [(AstBinSub) "Sub"]
    [(AstBinMul) "Mul"]
    [(AstBinDiv) "Div"]
    [(AstBinMod) "Mod"]
    [(AstBinEq) "Eq"]
    [(AstBinNe) "Ne"]
    [(AstBinLt) "Lt"]
    [(AstBinLe) "Le"]
    [(AstBinGt) "Gt"]
    [(AstBinGe) "Ge"]
    [(AstBinAnd) "And"]
    [(AstBinOr) "Or"]
    [(AstBinBitAnd) "BitAnd"]
    [(AstBinBitOr) "BitOr"]
    [(AstBinBitXor) "BitXor"]
    [(AstBinShl) "Shl"]
    [(AstBinShr) "Shr"]))

(define (front-unop-render [op : AstUnOp]) : String
  (match op
    [(AstUnNeg) "Neg"]
    [(AstUnNot) "Not"]
    [(AstUnBitNot) "BitNot"]))

(define (front-reduce-op-render [op : AstReduceOp]) : String
  (match op
    [(AstReduceSum) "Sum"]
    [(AstReduceMin) "Min"]
    [(AstReduceMax) "Max"]
    [(AstReduceAll) "All"]
    [(AstReduceAny) "Any"]))

(define (front-literal-render [lit : AstLiteral]) : String
  (match lit
    [(AstLitInt value) (front-cat3 "Literal(Int(" (int->string value) "))")]
    [(AstLitFloat value) (front-cat3 "Literal(Float(" value "))")]
    [(AstLitBool value)
      (if value
        "Literal(Bool(true))"
        "Literal(Bool(false))")]
    [(AstLitChar _) "Literal(Char(...))"]
    [(AstLitString value) (front-cat3 "Literal(String(\"" value "\"))")]
    [(AstLitUnit) "Literal(Unit)"]))

(define (front-expr-list-render [exprs : AstExprList]) : String
  (match exprs
    [(AstExprNil) ""]
    [(AstExprCons head rest)
      (string-append
        (front-expr-render head)
        (match rest
          [(AstExprNil) ""]
          [_ (string-append ", " (front-expr-list-render rest))]))]))

(define (front-resource-binding-render [binding : AstResourceBinding]) : String
  (match binding
    [(AstResourceBinding name init cleanup)
      (front-cat3
        "ResourceBinding { name: \""
        name
        (front-cat3
          "\", init: "
          (front-expr-render init)
          (front-cat3 ", cleanup: " (front-expr-render cleanup) " }")))]))

(define (front-resource-binding-list-render [bindings : AstResourceBindingList]) : String
  (match bindings
    [(AstResourceBindingNil) ""]
    [(AstResourceBindingCons head rest)
      (string-append
        (front-resource-binding-render head)
        (match rest
          [(AstResourceBindingNil) ""]
          [_ (string-append ", " (front-resource-binding-list-render rest))]))]))

(define (front-expr-render [expr : AstExpr]) : String
  (match (ast-expr-unspan expr)
    [(AstExprSpanned inner _) (front-expr-render inner)]
    [(AstExprLiteral lit) (front-literal-render lit)]
    [(AstExprVar name) (front-cat3 "Var(\"" name "\")")]
    [(AstExprBinary op lhs rhs)
      (front-cat3
        "Binary { op: "
        (front-binop-render op)
        (front-cat3
          ", lhs: "
          (front-expr-render lhs)
          (front-cat3 ", rhs: " (front-expr-render rhs) " }")))]
    [(AstExprUnary op inner)
      (front-cat3
        "Unary { op: "
        (front-unop-render op)
        (front-cat3 ", expr: " (front-expr-render inner) " }"))]
    [(AstExprCall func args)
      (front-cat3
        "Call { func: "
        (front-expr-render func)
        (front-cat3 ", args: [" (front-expr-list-render args) "] }"))]
    [(AstExprIf cond then-branch else-branch)
      (front-cat3
        "If { cond: "
        (front-expr-render cond)
        (front-cat3
          ", then: "
          (front-expr-render then-branch)
          (front-cat3 ", else: " (front-expr-render else-branch) " }")))]
    [(AstExprLet _ body)
      (front-cat3 "Let { body: " (front-expr-render body) " }")]
    [(AstExprLambda _ _ body)
      (front-cat3 "Lambda { body: " (front-expr-render body) " }")]
    [(AstExprTuple elems)
      (front-cat3 "Tuple([" (front-expr-list-render elems) "])")]
    [(AstExprTupleRef inner index)
      (front-cat3
        "TupleRef { expr: "
        (front-expr-render inner)
        (front-cat3 ", index: " (int->string index) " }"))]
    [(AstExprArray elems)
      (front-cat3 "Array([" (front-expr-list-render elems) "])")]
    [(AstExprMakeArray elem-ty len)
      (front-cat3
        "MakeArray { elem_ty: "
        (front-type-render elem-ty)
        (front-cat3 ", len: " (front-expr-render len) " }"))]
    [(AstExprArrayRef arr index)
      (front-cat3
        "ArrayRef { expr: "
        (front-expr-render arr)
        (front-cat3 ", index: " (front-expr-render index) " }"))]
    [(AstExprArraySet arr index value)
      (front-cat3
        "ArraySet { expr: "
        (front-expr-render arr)
        (front-cat3
          ", index: "
          (front-expr-render index)
          (front-cat3 ", value: " (front-expr-render value) " }")))]
    [(AstExprArrayPush arr value)
      (front-cat3
        "ArrayPush { expr: "
        (front-expr-render arr)
        (front-cat3 ", value: " (front-expr-render value) " }"))]
    [(AstExprStringRef text index)
      (front-cat3
        "StringRef { expr: "
        (front-expr-render text)
        (front-cat3 ", index: " (front-expr-render index) " }"))]
    [(AstExprWhile cond body)
      (front-cat3
        "While { cond: "
        (front-expr-render cond)
        (front-cat3 ", body: " (front-expr-render body) " }"))]
    [(AstExprBegin exprs)
      (front-cat3 "Begin([" (front-expr-list-render exprs) "])")]
    [(AstExprUnsafe exprs)
      (front-cat3 "Unsafe([" (front-expr-list-render exprs) "])")]
    [(AstExprSet name value)
      (front-cat3
        "Set(\""
        name
        (front-cat3 "\", " (front-expr-render value) ")"))]
    [(AstExprAnn inner ty)
      (front-cat3
        "Ann { expr: "
        (front-expr-render inner)
        (front-cat3 ", ty: " (front-type-render ty) " }"))]
    [(AstExprCast inner ty)
      (front-cat3
        "Cast { expr: "
        (front-expr-render inner)
        (front-cat3 ", ty: " (front-type-render ty) " }"))]
    [(AstExprBorrow lifetime place)
      (front-cat3
        "Borrow { lifetime: "
        (match lifetime
          [(AstBorrowLifetimeInferred) "Infer"]
          [(AstBorrowLifetimeNamed name) (front-cat3 "\"" name "\"")])
        (front-cat3 ", place: " (front-expr-render place) " }"))]
    [(AstExprMatch scrutinee _)
      (front-cat3 "Match { scrutinee: " (front-expr-render scrutinee) " }")]
    [(AstExprForeach name index-ty start end body)
      (front-cat3
        "Foreach { index: "
        name
        (front-cat3
          ", index_ty: "
          (front-type-render index-ty)
          (front-cat3
            ", start: "
            (front-expr-render start)
            (front-cat3
              ", end: "
              (front-expr-render end)
              (front-cat3 ", body: " (front-expr-render body) " }")))))]
    [(AstExprSpmdReduce op name index-ty start end init value)
      (front-cat3
        "SpmdReduce { op: "
        (front-reduce-op-render op)
        (front-cat3
          ", index: \""
          name
          (front-cat3
            "\", index_ty: "
            (front-type-render index-ty)
            (front-cat3
              ", start: "
              (front-expr-render start)
              (front-cat3
                ", end: "
                (front-expr-render end)
                (front-cat3
                  ", init: "
                  (front-expr-render init)
                  (front-cat3 ", value: " (front-expr-render value) " }")))))))]
    [(AstExprStructGet inner field)
      (front-cat3
        "StructGet { expr: "
        (front-expr-render inner)
        (front-cat3 ", field: \"" field "\" }"))]
    [(AstExprWithRegion region body)
      (front-cat3
        "WithRegion { region: \""
        region
        (front-cat3 "\", body: [" (front-expr-list-render body) "] }"))]
    [(AstExprWithEscape scratch body)
      (front-cat3
        "WithEscape { arena: "
        (front-expr-render scratch)
        (front-cat3 ", body: [" (front-expr-list-render body) "] }"))]
    [(AstExprWithResource bindings body)
      (front-cat3
        "WithResource { bindings: ["
        (front-resource-binding-list-render bindings)
        (front-cat3 "], body: [" (front-expr-list-render body) "] }"))]
    [(AstExprBox inner)
      (front-cat3 "Box { expr: " (front-expr-render inner) " }")]
    [(AstExprBoxGet inner)
      (front-cat3 "BoxGet { expr: " (front-expr-render inner) " }")]
    [(AstExprTypeLiteral ty)
      (front-cat3 "TypeLiteral { ty: " (front-type-render ty) " }")]
    [(AstExprComptime inner)
      (front-cat3 "Comptime { expr: " (front-expr-render inner) " }")]
    [(AstExprQuote inner)
      (front-cat3 "Quote { expr: " (front-expr-render inner) " }")]
    [(AstExprQuasiquote inner)
      (front-cat3 "Quasiquote { expr: " (front-expr-render inner) " }")]
    [(AstExprUnquote inner)
      (front-cat3 "Unquote { expr: " (front-expr-render inner) " }")]
    [(AstExprUnquoteSplicing inner)
      (front-cat3 "UnquoteSplicing { expr: " (front-expr-render inner) " }")]
    [(AstExprTry inner)
      (front-cat3 "Try { expr: " (front-expr-render inner) " }")]
    [(AstExprReturn inner)
      (front-cat3 "Return { expr: " (front-expr-render inner) " }")]
    [(AstExprPtrNull ty)
      (front-cat3 "PtrNull { ty: " (front-type-render ty) " }")]
    [(AstExprPtrNullCheck inner)
      (front-cat3 "PtrNullCheck { expr: " (front-expr-render inner) " }")]
    [(AstExprPtrRead ptr)
      (front-cat3 "PtrRead { ptr: " (front-expr-render ptr) " }")]
    [(AstExprPtrWrite ptr value)
      (front-cat3
        "PtrWrite { ptr: "
        (front-expr-render ptr)
        (front-cat3 ", value: " (front-expr-render value) " }"))]
    [(AstExprPtrOffset ptr offset)
      (front-cat3
        "PtrOffset { ptr: "
        (front-expr-render ptr)
        (front-cat3 ", offset: " (front-expr-render offset) " }"))]
    [(AstExprPtrCast ptr ty)
      (front-cat3
        "PtrCast { ptr: "
        (front-expr-render ptr)
        (front-cat3 ", ty: " (front-type-render ty) " }"))]
    [(AstExprPtrToInt ptr)
      (front-cat3 "PtrToInt { ptr: " (front-expr-render ptr) " }")]
    [(AstExprIntToPtr value ty)
      (front-cat3
        "IntToPtr { value: "
        (front-expr-render value)
        (front-cat3 ", ty: " (front-type-render ty) " }"))]
    [(AstExprStringData inner)
      (front-cat3 "StringData { expr: " (front-expr-render inner) " }")]
    [(AstExprStringFromBytes ptr len)
      (front-cat3
        "StringFromBytes { ptr: "
        (front-expr-render ptr)
        (front-cat3 ", len: " (front-expr-render len) " }"))]
    [(AstExprArrayData inner)
      (front-cat3 "ArrayData { expr: " (front-expr-render inner) " }")]
    [(AstExprProgramArgc) "ProgramArgc"]
    [(AstExprProgramArgv) "ProgramArgv"]
    [(AstExprProgramEnvp) "ProgramEnvp"]
    [(AstExprCpuIdEax leaf subleaf)
      (front-cat3
        "CpuIdEax { leaf: "
        (front-expr-render leaf)
        (front-cat3 ", subleaf: " (front-expr-render subleaf) " }"))]
    [(AstExprCpuIdEbx leaf subleaf)
      (front-cat3
        "CpuIdEbx { leaf: "
        (front-expr-render leaf)
        (front-cat3 ", subleaf: " (front-expr-render subleaf) " }"))]
    [(AstExprCpuIdEcx leaf subleaf)
      (front-cat3
        "CpuIdEcx { leaf: "
        (front-expr-render leaf)
        (front-cat3 ", subleaf: " (front-expr-render subleaf) " }"))]
    [(AstExprCpuIdEdx leaf subleaf)
      (front-cat3
        "CpuIdEdx { leaf: "
        (front-expr-render leaf)
        (front-cat3 ", subleaf: " (front-expr-render subleaf) " }"))]
    [(AstExprXgetbv index)
      (front-cat3 "Xgetbv { index: " (front-expr-render index) " }")]))

(define (front-maybe-module-render [name : AstMaybeModuleName]) : String
  (match name
    [(AstNoModuleName) "None"]
    [(AstSomeModuleName module-name) (front-cat3 "Some(\"" module-name "\")")]))

(define (front-maybe-alias-render [alias : AstMaybeImportAlias]) : String
  (match alias
    [(AstNoImportAlias) "None"]
    [(AstSomeImportAlias alias-name) (front-cat3 "Some(\"" alias-name "\")")]))

(define (front-import-render [spec : AstImportSpec]) : String
  (match spec
    [(AstImportSpec path module-name alias)
      (front-cat3
        "Import { path: \""
        path
        (front-cat3
          "\", module: "
          (front-maybe-module-render module-name)
          (front-cat3 ", alias: " (front-maybe-alias-render alias) " }")))]))

(define (front-struct-cleanup-render [cleanup : AstStructCleanup]) : String
  (match cleanup
    [(AstStructNoCleanup) "None"]
    [(AstStructCleanupFn name) (front-cat3 "Some(\"" name "\")")]))

(define (front-field-cleanup-render [cleanup : AstFieldCleanup]) : String
  (match cleanup
    [(AstFieldNoCleanup) "None"]
    [(AstFieldCleanupFn name) (front-cat3 "Some(\"" name "\")")]
    [(AstFieldOwnedCleanup) "Owned"]))

(define (front-field-render [field : AstFieldDef]) : String
  (match field
    [(AstFieldDef name ty cleanup)
      (front-cat3
        "Field { name: \""
        name
        (front-cat3
          "\", ty: "
          (front-type-render ty)
          (front-cat3 ", cleanup: " (front-field-cleanup-render cleanup) " }")))]))

(define (front-field-list-items-render [fields : AstFieldDefList]) : String
  (match fields
    [(AstFieldDefNil) ""]
    [(AstFieldDefCons field (AstFieldDefNil)) (front-field-render field)]
    [(AstFieldDefCons field rest)
      (front-cat3
        (front-field-render field)
        ", "
        (front-field-list-items-render rest))]))

(define (front-field-list-render [fields : AstFieldDefList]) : String
  (front-cat3 "[" (front-field-list-items-render fields) "]"))

(define (front-export-item-render [item : AstExportItem]) : String
  (match item
    [(AstExportValue name) (front-cat3 "Value(\"" name "\")")]
    [(AstExportType name) (front-cat3 "Type(\"" name "\")")]
    [(AstExportMacro name) (front-cat3 "Macro(\"" name "\")")]
    [(AstExportConstructor name) (front-cat3 "Constructor(\"" name "\")")]
    [(AstExportField type-name field-name)
      (front-cat3 "Field(\"" type-name (front-cat3 "\", \"" field-name "\")"))]
    [(AstExportVariant name) (front-cat3 "Variant(\"" name "\")")]))

(define (front-export-item-list-items-render [items : AstExportItemList]) : String
  (match items
    [(AstExportItemNil) ""]
    [(AstExportItemCons item (AstExportItemNil))
      (front-export-item-render item)]
    [(AstExportItemCons item rest)
      (front-cat3
        (front-export-item-render item)
        ", "
        (front-export-item-list-items-render rest))]))

(define (front-export-item-list-render [items : AstExportItemList]) : String
  (front-cat3 "[" (front-export-item-list-items-render items) "]"))

(define (front-decl-render [decl : AstDecl]) : String
  (match decl
    [(AstDeclModule name) (front-cat3 "Module(\"" name "\")")]
    [(AstDeclDef name ty value)
      (front-cat3
        "Def { name: \""
        name
        (front-cat3
          "\", ty: "
          (match ty
            [(AstNoType) "None"]
            [(AstSomeType some-ty) (front-type-render some-ty)])
          (front-cat3 ", value: " (front-expr-render value) " }")))]
    [(AstDeclDefFn name _ ret body)
      (front-cat3
        "DefFn { name: \""
        name
        (front-cat3
          "\", ret: "
          (front-type-render ret)
          (front-cat3 ", body: " (front-expr-render body) " }")))]
    [(AstDeclDefMacro name _ ret body)
      (front-cat3
        "DefMacro { name: \""
        name
        (front-cat3
          "\", ret: "
          (front-type-render ret)
          (front-cat3 ", body: " (front-expr-render body) " }")))]
    [(AstDeclExtern name metadata ty)
      (front-cat3
        "Extern { name: \""
        name
        (front-cat3
          "\", abi: c, symbol: \""
          (ast-extern-metadata-symbol metadata)
          (front-cat3 "\", ty: " (front-type-render ty) " }")))]
    [(AstDeclDefEnum name _) (front-cat3 "DefEnum { name: \"" name "\" }")]
    [(AstDeclDefStruct name repr cleanup fields)
      (front-cat3
        "DefStruct { name: \""
        name
        (front-cat3
          "\", repr: "
          (if (ast-struct-repr-c? repr)
            "c"
            "default")
          (front-cat3
            ", cleanup: "
            (front-struct-cleanup-render cleanup)
            (front-cat3 ", fields: " (front-field-list-render fields) " }"))))]
    [(AstDeclImport spec) (front-import-render spec)]
    [(AstDeclExport items)
      (front-cat3 "Export { items: " (front-export-item-list-render items) " }")]
    [(AstDeclTest name body _)
      (front-cat3
        "Test { name: \""
        name
        (front-cat3 "\", body: " (front-expr-render body) " }"))]
    [(AstDeclComptimeDecl template)
      (front-cat3 "ComptimeDecl { template: " (front-decl-render template) " }")]))

(define (front-decl-list-render [decls : AstDeclList]) : String
  (match decls
    [(AstDeclNil) ""]
    [(AstDeclCons head rest)
      (string-append
        (front-cat3 "    " (front-decl-render head) ",\n")
        (front-decl-list-render rest))]))

(define (front-program-render [program : AstProgram]) : String
  (match program
    [(AstProgram decls)
      (front-cat3
        "Program {\n  decls: [\n"
        (front-decl-list-render decls)
        "  ],\n}\n")]))

(define (front-parse-file [path : String]) : i64
  (match (parse-ast-source-diagnostic path (read-file path))
    [(OkAstProgramDiagnostic program)
      (begin
        (print-string (front-program-render program))
        0)]
    [(ErrAstProgramDiagnostic diag)
      (begin
        (front-error-line (compiler-diagnostic-render diag))
        1)]))

(define (front-usage) : unit
  (front-error-line
    "frontend-tools: expected mode tokenize|parse and input path"))

(define (front-cli-main) : i64
  (if (< (arg-count) 3)
    (begin
      (front-usage)
      1)
    (let
      [mode : String (arg 1)]
      [path : String (arg 2)]
      (if (string-eq mode "tokenize")
        (front-tokenize-file path)
        (if (string-eq mode "parse")
          (front-parse-file path)
          (begin
            (front-error-line
              (front-cat3 "frontend-tools: unknown mode " mode ""))
            1))))))