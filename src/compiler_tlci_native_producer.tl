;; compiler_tlci_native_producer.tl - Generate and map normal-backend
;; transformer programs for tlci native package images (refs #5213, #5596).
;;
;; The producer captures checked defmacro identities, parameters, and bodies,
;; desugars eligible bodies (general quasiquote templates -- nested calls,
;; literals, plain symbols, unquoted operands, and unquote-splicing -- array
;; intrinsic nodes, literal templates, match-on-type-kind computed bodies,
;; list-length computed ifs, and the expr-list fold intrinsics) into ordinary
;; TypeLisp entry functions whose comptime primitives are host callback calls,
;; and resolves the compiled entries by the compact function-symbol contract.
;; Bodies outside the supported subset compile to ok-with-no-result shells so
;; the dispatch route keeps its counted interpreted fallback.
(import "compiler_parse_core.tl")
(import compiler_object as cobj)
(import "compiler_backend.tl")
(import "compiler_tlci_native_image.tl")
(import "tlci_core.tl")
(import compiler_builtin_ids as cbi)
(import stdlib.array)
(import stdlib.string)

(define (embedded-stdlib-tlci-identity [module : String] [name-id : i64]) : String
  (if (= (string.string-length module) 0)
    (intern-str name-id)
    (str-cat module "/" (intern-str name-id))))

;; Every collected macro's parsed source is captured so the producer can
;; compile each eligible expression body to a native entry; identities whose
;; bodies fall outside the supported subset stay registration shells with the
;; counted interpreted fallback. Captures are an explicit producer input so
;; package dependency builds cannot observe stale sources from an earlier
;; image in the same process. Refs #5212, #5213, #2754.
(defstruct TlciNativeMacroCapture
  (identity String)
  (params AstMacroParamList)
  (body i64))

(defstruct TlciNativeMacroCaptures
  (slots (Array TlciNativeMacroCapture))
  (len i64))

(define (tlci-native-macro-captures-new) : TlciNativeMacroCaptures
  (TlciNativeMacroCaptures (array.make-array TlciNativeMacroCapture 0) 0))

(define (tlci-native-macro-captures-copy-range!
  [dst : (&mut dst (Array TlciNativeMacroCapture))]
  [src : (& src (Array TlciNativeMacroCapture))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (tlci-native-macro-captures-copy-range! dst src (+ index 1) count))))

(define (tlci-native-macro-captures-grow!
  [captures : (&mut captures TlciNativeMacroCaptures)]) : unit
  (let
    [old-cap : i64 (array-length (struct-get captures slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array TlciNativeMacroCapture)
      (array.make-array TlciNativeMacroCapture new-cap)]
    (begin
      (tlci-native-macro-captures-copy-range!
        (&mut bigger)
        (& (struct-get captures slots))
        0
        (struct-get captures len))
      (set! (struct-get captures slots) bigger))))

(define (tlci-native-macro-captures-push!
  [captures : (&mut captures TlciNativeMacroCaptures)]
  [capture : TlciNativeMacroCapture]) : unit
  (begin
    (when
      (>= (struct-get captures len) (array-length (struct-get captures slots)))
      (tlci-native-macro-captures-grow! captures))
    (let
      [index : i64 (struct-get captures len)]
      (begin
        (array-set! (struct-get captures slots) index capture)
        (set! (struct-get captures len) (+ index 1))))))

(define embedded-stdlib-tlci-native-floor-name : String
  "stdlib.array/length")

(define (embedded-stdlib-tlci-unwrap-expr [node : i64]) : AstExpr
  (match (ast-node-get node)
    [(AstExpr.Spanned inner _) (embedded-stdlib-tlci-unwrap-expr inner)]
    [_ (ast-node-get node)]))

(define (embedded-stdlib-tlci-param-index
  [params : (& params AstMacroParamList)]
  [name-id : i64]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index (struct-get params len)))
        (begin
          (match (array-ref (struct-get params slots) index)
            [(AstMacroParam.Param pname _ _ _)
              (if (= pname name-id)
                (set! found index)
                unit)])
          (set! index (+ index 1))))
      found)))

(define (embedded-stdlib-tlci-type-unquote-param
  [params : (& params AstMacroParamList)]
  [ty : AstType]) : i64
  (match ty
    [(AstType.VarArgs name lifetimes)
      (if (and
        (= name cbi.compiler-builtin-id-fix-unquote)
        (= (ast-lifetime-list-len (& (box-get lifetimes))) 1))
        (embedded-stdlib-tlci-param-index
          params
          (ast-lifetime-list-get
            (& (box-get lifetimes))
            0
            (ast-lifetime-fallback)))
        -1)]
    [_ -1]))

(define embedded-stdlib-tlci-native-report-count : (Array i64)
  (make-array 0))

(define (tlci-native-macro-capture-slot
  [captures : (& captures TlciNativeMacroCaptures)]
  [identity : String]) : i64
  (let
    [count : i64 (struct-get captures len)]
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index count))
        (if (string.eq
          (struct-get (array-ref (struct-get captures slots) index) identity)
          identity)
          (set! found index)
          (set! index (+ index 1))))
      found)))

;; Instance-proof producer result: callers across import spellings match on
;; this producer-owned enum and receive raw bytes.
(defenum ResultProducerBytes
  (Ok (Array u8))
  (Err String))

(define embedded-native-ops-cap : i64
  4096)

(define (embedded-native-ops-push!
  [ops : (Array String)]
  [ops-count : (Array i64)]
  [line : String]) : unit
  (let
    [slot : i64 (array-ref ops-count 0)]
    (when
      (< slot embedded-native-ops-cap)
      (array-set! ops slot line)
      (array-set! ops-count 0 (+ slot 1)))))

(define (embedded-native-status-sum [opened : i64]) : String
  (let
    [out : String ""]
    [index : i64 0]
    (begin
      (while (< index opened)
        (begin
          (set!
            out
            (str-cat
              out
              (if (< index (- opened 1))
                (str-cat "(+ q" (string.int->string index) " ")
                (str-cat "q" (string.int->string index)))))
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index (- opened 1))
        (begin
          (set! out (str-cat out ")"))
          (set! index (+ index 1))))
      out)))

(define (embedded-native-op-open
  [status-index : i64]
  [op : i64]
  [arg-a : String]
  [arg-b : String]
  [arg-c : String]) : String
  (let
    [sname : String (str-cat "q" (string.int->string status-index))]
    (str-cat
      "  (let ["
      sname
      " : i64 (comptime-host-invoke host session "
      (string.int->string op)
      " "
      arg-a
      " "
      arg-b
      " "
      arg-c
      ")] (if (not (= "
      sname
      " 0)) "
      sname
      "\n")))

(define (embedded-native-name-arg [name : String]) : String
  (str-cat "(cast (unsafe (ptr->int (string-data \"" name "\"))) : i64)"))

;; Emit the op-call chain for one eligible body into `ops`; returns the count
;; of opened let/if pairs, or -1 when the body is outside the subset.
;; Quasiquoted bodies go through the general template walker; plain bodies may
;; be a macro parameter (the identity transformer), a `(comptime.expr-var
;; "name")` builder call, or one of the expr-list fold intrinsics.
(define (embedded-native-body-ops
  [params : (& params AstMacroParamList)]
  [body-node : i64]
  [ops : (Array String)]
  [ops-count : (Array i64)]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(AstExpr.Quasiquote quoted)
      (embedded-native-template-ops params quoted ops ops-count)]
    [(AstExpr.Var pname)
      (let
        [param : i64 (embedded-stdlib-tlci-param-index params pname)]
        (if (< param 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              180
              (string.int->string param)
              "0"
              "0")
            1)))]
    [(AstExpr.Call fold-func fold-args)
      ;; Plain (not quasiquoted) call to the expr-list fold intrinsic: the
      ;; and/or shape. The host op mirrors the interpreted fold exactly, so
      ;; the whole expansion is one dispatch.
      (match (embedded-stdlib-tlci-unwrap-expr fold-func)
        [(AstExpr.Var fold-head)
          (if (and
            (or
              (string.eq
                (intern-str fold-head)
                "comptime.expr-clause-list-fold-if")
              (string.eq (intern-str fold-head) "expr-clause-list-fold-if"))
            (= (ast-expr-list-len (& fold-args)) 3))
            (let
              [clauses-index : i64
                (embedded-native-var-param-index
                  params
                  (ast-expr-list-get (& fold-args) 0 0))]
              [missing-name : String
                (embedded-native-expr-var-name
                  (ast-expr-list-get (& fold-args) 1 0))]
              [else-not-final-name : String
                (embedded-native-expr-var-name
                  (ast-expr-list-get (& fold-args) 2 0))]
              (if (or
                (< clauses-index 0)
                (= (string.string-length missing-name) 0)
                (= (string.string-length else-not-final-name) 0))
                -1
                (begin
                  (embedded-native-ops-push!
                    ops
                    ops-count
                    (embedded-native-op-open
                      0
                      103
                      (embedded-native-name-arg missing-name)
                      (string.int->string (string.string-length missing-name))
                      "0"))
                  (embedded-native-ops-push!
                    ops
                    ops-count
                    (embedded-native-op-open
                      1
                      103
                      (embedded-native-name-arg else-not-final-name)
                      (string.int->string
                        (string.string-length else-not-final-name))
                      "0"))
                  (embedded-native-ops-push!
                    ops
                    ops-count
                    (embedded-native-op-open
                      2
                      190
                      (string.int->string clauses-index)
                      "0"
                      "0"))
                  3)))
            (if (and
              (or
                (string.eq (intern-str fold-head) "comptime.expr-list-fold-if")
                (string.eq (intern-str fold-head) "expr-list-fold-if"))
              (= (ast-expr-list-len (& fold-args)) 4))
              (let
                [items-index : i64
                  (embedded-native-var-param-index
                    params
                    (ast-expr-list-get (& fold-args) 0 0))]
                [when-true : i64
                  (embedded-native-expr-bool-flag
                    (ast-expr-list-get (& fold-args) 1 0))]
                [when-false : i64
                  (embedded-native-expr-bool-flag
                    (ast-expr-list-get (& fold-args) 2 0))]
                [continue-flag : i64
                  (embedded-native-bool-literal-flag
                    (ast-expr-list-get (& fold-args) 3 0))]
                (if (or
                  (< items-index 0)
                  (< when-true 0)
                  (< when-false 0)
                  (< continue-flag 0))
                  -1
                  (begin
                    (embedded-native-ops-push!
                      ops
                      ops-count
                      (embedded-native-op-open
                        0
                        187
                        (string.int->string when-true)
                        "0"
                        "0"))
                    (embedded-native-ops-push!
                      ops
                      ops-count
                      (embedded-native-op-open
                        1
                        187
                        (string.int->string when-false)
                        "0"
                        "0"))
                    (embedded-native-ops-push!
                      ops
                      ops-count
                      (embedded-native-op-open
                        2
                        189
                        (string.int->string items-index)
                        (string.int->string continue-flag)
                        "0"))
                    3)))
              (let
                [var-name : String (embedded-native-expr-var-name body-node)]
                (if (= (string.string-length var-name) 0)
                  -1
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      103
                      (embedded-native-name-arg var-name)
                      (string.int->string (string.string-length var-name))
                      "0")
                    1)))))]
        [_ -1])]
    [_ -1]))

;: The literal name of a (comptime.expr-var "name") argument; "" otherwise.
(define (embedded-native-expr-var-name [node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(AstExpr.Call var-func var-args)
      (match (embedded-stdlib-tlci-unwrap-expr var-func)
        [(AstExpr.Var var-head)
          (if (and
            (or
              (string.eq (intern-str var-head) "comptime.expr-var")
              (string.eq (intern-str var-head) "expr-var"))
            (= (ast-expr-list-len (& var-args)) 1))
            (match (embedded-stdlib-tlci-unwrap-expr
              (ast-expr-list-get (& var-args) 0 0))
              [(AstExpr.Literal lit)
                (match lit
                  [(AstLiteral.String text) (intern-str text)]
                  [_ ""])]
              [_ ""])
            "")]
        [_ ""])]
    [_ ""]))

;: 1/0 for a (comptime.expr-bool <literal>) argument; -1 otherwise.
(define (embedded-native-expr-bool-flag [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(AstExpr.Call bool-func bool-args)
      (match (embedded-stdlib-tlci-unwrap-expr bool-func)
        [(AstExpr.Var bool-head)
          (if (and
            (or
              (string.eq (intern-str bool-head) "comptime.expr-bool")
              (string.eq (intern-str bool-head) "expr-bool"))
            (= (ast-expr-list-len (& bool-args)) 1))
            (embedded-native-bool-literal-flag
              (ast-expr-list-get (& bool-args) 0 0))
            -1)]
        [_ -1])]
    [_ -1]))

;: 1/0 for a literal bool node; -1 otherwise.
(define (embedded-native-bool-literal-flag [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(AstExpr.Literal lit)
      (match lit
        [(AstLiteral.Bool flag)
          (if flag
            1
            0)]
        [_ -1])]
    [_ -1]))

;; Escape `text` for embedding inside a generated source string literal. The
;; generated transformer source is re-lexed by the ordinary lexer, whose
;; string escapes are \\, \", \n, \t, and \r.
(define (embedded-native-escape-string [text : String]) : String
  (let
    [out : String ""]
    [index : i64 0]
    [length : i64 (string.string-length text)]
    (begin
      (while (< index length)
        (let
          [c : char (string.string-ref text index)]
          (begin
            (cond
              [(= c '\\') (set! out (str-cat out "\\\\"))]
              [(= c '"') (set! out (str-cat out "\\\""))]
              [(= c '\n') (set! out (str-cat out "\\n"))]
              [(= c '\t') (set! out (str-cat out "\\t"))]
              [(= c '\r') (set! out (str-cat out "\\r"))]
              [else (set! out (str-cat out (string.substring text index 1)))])
            (set! index (+ index 1)))))
      out)))

;; Push one host-op call whose status let name matches the current op slot,
;; keeping generated status bindings unique across the whole entry.
(define (embedded-native-template-push!
  [ops : (Array String)]
  [ops-count : (Array i64)]
  [op : i64]
  [arg-a : String]
  [arg-b : String]
  [arg-c : String]) : unit
  (embedded-native-ops-push!
    ops
    ops-count
    (embedded-native-op-open (array-ref ops-count 0) op arg-a arg-b arg-c)))

;; AstBinOp ordinal contract shared with the host callback consumer; the
;; embedded image and its consumer are always the same source-bound binary.
(define (embedded-native-binop-ordinal [op : AstBinOp]) : i64
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
    [(AstBinOp.Shr) 17]))

(define (embedded-native-unop-ordinal [op : AstUnOp]) : i64
  (match op
    [(AstUnOp.Neg) 0]
    [(AstUnOp.Not) 1]
    [(AstUnOp.BitNot) 2]))

(define (embedded-native-comparison-spelling [ordinal : i64]) : String
  (cond
    [(= ordinal 5) "="]
    [(= ordinal 6) "!="]
    [(= ordinal 7) "<"]
    [(= ordinal 8) "<="]
    [(= ordinal 9) ">"]
    [(= ordinal 10) ">="]
    [else "="]))

;; Emit the op chain that pushes exactly one session-stack value for one
;; quasiquoted template node, mirroring the interpreted quote's reconstruction
;; of calls, if/begin/binary/unary forms, literals, plain symbols, unquoted
;; operands, and the intrinsic array nodes. Returns the number of opened op
;; lets, or -1 when the node is outside the supported template subset (the
;; caller then keeps the counted fallback shell). Refs #5596.
(define (embedded-native-template-ops
  [params : (& params AstMacroParamList)]
  [node : i64]
  [ops : (Array String)]
  [ops-count : (Array i64)]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(AstExpr.Unquote inner)
      (match (embedded-stdlib-tlci-unwrap-expr inner)
        [(AstExpr.Var pname)
          (let
            [param : i64 (embedded-stdlib-tlci-param-index params pname)]
            (if (< param 0)
              -1
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  180
                  (string.int->string param)
                  "0"
                  "0")
                1)))]
        [_ -1])]
    [(AstExpr.Literal lit)
      (match lit
        [(AstLiteral.Bool flag)
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              187
              (if flag
                "1"
                "0")
              "0"
              "0")
            1)]
        [(AstLiteral.Int value text)
          (if (or
            (= (string.string-length text) 0)
            (string.eq text (string.int->string value)))
            (begin
              (embedded-native-template-push!
                ops
                ops-count
                188
                (string.int->string value)
                "0"
                "0")
              1)
            -1)]
        [(AstLiteral.String sid)
          (let
            [text : String (intern-str sid)]
            (begin
              (embedded-native-template-push!
                ops
                ops-count
                102
                (embedded-native-name-arg (embedded-native-escape-string text))
                (string.int->string (string.string-length text))
                "0")
              1))]
        [(AstLiteral.Char c)
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              202
              (string.int->string (cast c : i64))
              "0"
              "0")
            1)]
        [(AstLiteral.Unit)
          (begin
            (embedded-native-template-push! ops ops-count 203 "0" "0" "0")
            1)]
        [_ -1])]
    [(AstExpr.Var name-id)
      (let
        [name : String (intern-str name-id)]
        (begin
          (embedded-native-template-push!
            ops
            ops-count
            103
            (embedded-native-name-arg name)
            (string.int->string (string.string-length name))
            "0")
          1))]
    [(AstExpr.Call func-id args)
      (match (embedded-stdlib-tlci-unwrap-expr func-id)
        [(AstExpr.Var head-id)
          (let
            [head : String (intern-str head-id)]
            (begin
              (embedded-native-template-push!
                ops
                ops-count
                103
                (embedded-native-name-arg head)
                (string.int->string (string.string-length head))
                "0")
              (let
                [arg-opened : i64
                  (embedded-native-template-args-ops
                    params
                    (& args)
                    ops
                    ops-count)]
                (if (< arg-opened 0)
                  -1
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      181
                      "0"
                      "0"
                      "0")
                    (+ arg-opened 2))))))]
        [_ -1])]
    [(AstExpr.If cond-node then-node else-node)
      (let
        [cond-opened : i64
          (embedded-native-template-ops params cond-node ops ops-count)]
        (if (< cond-opened 0)
          -1
          (let
            [then-opened : i64
              (embedded-native-template-ops params then-node ops ops-count)]
            (if (< then-opened 0)
              -1
              (let
                [else-opened : i64
                  (embedded-native-template-ops params else-node ops ops-count)]
                (if (< else-opened 0)
                  -1
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      115
                      "0"
                      "0"
                      "0")
                    (+ cond-opened then-opened else-opened 1))))))))]
    [(AstExpr.Begin exprs)
      (let
        [arg-opened : i64
          (embedded-native-template-args-ops params (& exprs) ops ops-count)]
        (if (< arg-opened 0)
          -1
          (begin
            (embedded-native-template-push! ops ops-count 199 "0" "0" "0")
            (+ arg-opened 1))))]
    [(AstExpr.Binary op left-node right-node)
      (let
        [left-opened : i64
          (embedded-native-template-ops params left-node ops ops-count)]
        (if (< left-opened 0)
          -1
          (let
            [right-opened : i64
              (embedded-native-template-ops params right-node ops ops-count)]
            (if (< right-opened 0)
              -1
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  200
                  (string.int->string (embedded-native-binop-ordinal op))
                  "0"
                  "0")
                (+ left-opened right-opened 1))))))]
    [(AstExpr.Unary op inner-node)
      (let
        [inner-opened : i64
          (embedded-native-template-ops params inner-node ops ops-count)]
        (if (< inner-opened 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              201
              (string.int->string (embedded-native-unop-ordinal op))
              "0"
              "0")
            (+ inner-opened 1))))]
    [(AstExpr.ArrayRef target-node index-node)
      (let
        [target-opened : i64
          (embedded-native-template-ops params target-node ops ops-count)]
        (if (< target-opened 0)
          -1
          (let
            [index-opened : i64
              (embedded-native-template-ops params index-node ops ops-count)]
            (if (< index-opened 0)
              -1
              (begin
                (embedded-native-template-push! ops ops-count 183 "0" "0" "0")
                (+ target-opened index-opened 1))))))]
    [(AstExpr.ArrayPush target-node value-node)
      (let
        [target-opened : i64
          (embedded-native-template-ops params target-node ops ops-count)]
        (if (< target-opened 0)
          -1
          (let
            [value-opened : i64
              (embedded-native-template-ops params value-node ops ops-count)]
            (if (< value-opened 0)
              -1
              (begin
                (embedded-native-template-push! ops ops-count 184 "0" "0" "0")
                (+ target-opened value-opened 1))))))]
    [(AstExpr.MakeArray elem-type size-node)
      (let
        [ti : i64 (embedded-stdlib-tlci-type-unquote-param params elem-type)]
        (if (< ti 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              180
              (string.int->string ti)
              "0"
              "0")
            (let
              [size-opened : i64
                (embedded-native-template-ops params size-node ops ops-count)]
              (if (< size-opened 0)
                -1
                (begin
                  (embedded-native-template-push! ops ops-count 185 "0" "0" "0")
                  (+ size-opened 2)))))))]
    [_ -1]))

;; Emit ops building one template argument/expression list: expr-list-empty,
;; then per item either list-append of a pushed template value or expr-splice
;; of a variadic operand's whole ExprList, matching the interpreted quote's
;; unquote-splicing step. Returns the opened op-let count or -1 when an item
;; is outside the supported subset.
(define (embedded-native-template-args-ops
  [params : (& params AstMacroParamList)]
  [args : (& args AstExprList)]
  [ops : (Array String)]
  [ops-count : (Array i64)]) : i64
  (let
    [count : i64 (ast-expr-list-len args)]
    [index : i64 0]
    [opened : i64 1]
    [ok : bool true]
    (begin
      (embedded-native-template-push! ops ops-count 178 "0" "0" "0")
      (while (and ok (< index count))
        (let
          [item : i64 (ast-expr-list-get args index 0)]
          (match (embedded-stdlib-tlci-unwrap-expr item)
            [(AstExpr.UnquoteSplicing inner)
              (match (embedded-stdlib-tlci-unwrap-expr inner)
                [(AstExpr.Var pname)
                  (let
                    [param : i64
                      (embedded-stdlib-tlci-param-index params pname)]
                    (if (< param 0)
                      (set! ok false)
                      (begin
                        (embedded-native-template-push!
                          ops
                          ops-count
                          180
                          (string.int->string param)
                          "0"
                          "0")
                        (embedded-native-template-push!
                          ops
                          ops-count
                          114
                          "0"
                          "0"
                          "0")
                        (set! opened (+ opened 2))
                        (set! index (+ index 1)))))]
                [_ (set! ok false)])]
            [_
              (let
                [item-opened : i64
                  (embedded-native-template-ops params item ops ops-count)]
                (if (< item-opened 0)
                  (set! ok false)
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      179
                      "0"
                      "0"
                      "0")
                    (set! opened (+ opened item-opened 1))
                    (set! index (+ index 1)))))])))
      (if ok
        opened
        -1))))

;; Full source for the native package: the host extern plus one entry function
;; per identity in catalog order.
;; A complete, balanced arm expression: the op lets, the status-sum return
;; (q99 is the enclosing fuel status), and one closing paren per op let.
(define (embedded-native-arm-block
  [ops : (Array String)]
  [ops-count : i64]
  [opened : i64]) : String
  (let
    [out : String ""]
    [index : i64 0]
    (begin
      (while (< index ops-count)
        (begin
          (set! out (str-cat out (array-ref ops index)))
          (set! index (+ index 1))))
      (set!
        out
        (str-cat out "  (comptime-host-invoke host session 182 0 0 0)\n"))
      (set! index 0)
      (while (< index (* opened 2))
        (begin
          (set! out (str-cat out ")"))
          (set! index (+ index 1))))
      out)))

(define (embedded-native-var-param-index
  [params : (& params AstMacroParamList)]
  [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(AstExpr.Var pname) (embedded-stdlib-tlci-param-index params pname)]
    [_ -1]))

;; Desugar `(match (type-kind T) ["kind" template] ...)` into nested
;; type-kind-eq queries with a complete arm block per match; an unmatched
;; scrutinee falls back to the interpreter by returning ok with no result.
;; Returns "" when the body is outside the supported shape.
(define (embedded-native-match-arms
  [params : (& params AstMacroParamList)]
  [type-index : i64]
  [arms : (& arms AstMatchArmList)]
  [index : i64]) : String
  (if (>= index (struct-get arms len))
    "  0\n"
    (match (array-ref (struct-get arms slots) index)
      [(AstMatchArm.Arm pattern body-node)
        (match pattern
          [(AstPattern.Literal (AstLiteral.String sid))
            (let
              [kind : String (intern-str sid)]
              [arm-code : String (embedded-native-body-code params body-node)]
              [rest : String
                (embedded-native-match-arms params type-index arms (+ index 1))]
              (if (string.eq rest "")
                ""
                (str-cat
                  "  (let [t"
                  (string.int->string index)
                  " : i64 (comptime-host-invoke host session 186 "
                  (string.int->string type-index)
                  " "
                  (embedded-native-name-arg kind)
                  " "
                  (string.int->string (string.string-length kind))
                  ")]\n"
                  "  (if (< t"
                  (string.int->string index)
                  " 0)\n"
                  "  "
                  (string.int->string tlci-host-callback-status-bad-request)
                  "\n"
                  "  (if (= t"
                  (string.int->string index)
                  " 1)\n"
                  (if (string.eq arm-code "")
                    "  0\n"
                    arm-code)
                  "\n"
                  rest
                  ")))\n")))]
          [_ "  0\n"])])))

(define (embedded-native-match-body
  [params : (& params AstMacroParamList)]
  [body-node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee arms)
          (match (embedded-stdlib-tlci-unwrap-expr scrutinee)
            [(AstExpr.Call head-id args)
              (match (embedded-stdlib-tlci-unwrap-expr head-id)
                [(AstExpr.Var head-name)
                  (if (and
                    (string.eq (intern-str head-name) "type-kind")
                    (= (ast-expr-list-len (& args)) 1))
                    (let
                      [type-index : i64
                        (embedded-native-var-param-index
                          params
                          (ast-expr-list-get (& args) 0 0))]
                      (if (< type-index 0)
                        ""
                        (embedded-native-match-arms
                          params
                          type-index
                          (& arms)
                          0)))
                    "")]
                [_ ""])]
            [_ ""])])]
    [_ ""]))

;; One extracted `(cmp (comptime.expr-list-length p) lit)` condition: the
;; variadic-operand index, the comparison AstBinOp ordinal (Eq..Ge only), and
;; the canonical literal bound.
(defenum EmbeddedNativeLengthProbe
  (LengthProbe i64 i64 i64)
  (NoLengthProbe))

;; Extract `(cmp (comptime.expr-list-length p) lit)` with the length call on
;; the left and a canonical int literal on the right. Anything else is not a
;; length probe.
(define (embedded-native-length-probe
  [params : (& params AstMacroParamList)]
  [cond-node : i64]) : EmbeddedNativeLengthProbe
  (match (embedded-stdlib-tlci-unwrap-expr cond-node)
    [(AstExpr.Binary op left-node right-node)
      (let
        [ordinal : i64 (embedded-native-binop-ordinal op)]
        (if (or (< ordinal 5) (> ordinal 10))
          (EmbeddedNativeLengthProbe.NoLengthProbe)
          (match (embedded-stdlib-tlci-unwrap-expr left-node)
            [(AstExpr.Call length-func length-args)
              (match (embedded-stdlib-tlci-unwrap-expr length-func)
                [(AstExpr.Var length-head)
                  (if (and
                    (or
                      (string.eq
                        (intern-str length-head)
                        "comptime.expr-list-length")
                      (string.eq (intern-str length-head) "expr-list-length"))
                    (= (ast-expr-list-len (& length-args)) 1))
                    (let
                      [param : i64
                        (embedded-native-var-param-index
                          params
                          (ast-expr-list-get (& length-args) 0 0))]
                      (match (embedded-stdlib-tlci-unwrap-expr right-node)
                        [(AstExpr.Literal (AstLiteral.Int value text))
                          (if (and
                            (>= param 0)
                            (or
                              (= (string.string-length text) 0)
                              (string.eq text (string.int->string value))))
                            (EmbeddedNativeLengthProbe.LengthProbe
                              param
                              ordinal
                              value)
                            (EmbeddedNativeLengthProbe.NoLengthProbe))]
                        [_ (EmbeddedNativeLengthProbe.NoLengthProbe)]))
                    (EmbeddedNativeLengthProbe.NoLengthProbe))]
                [_ (EmbeddedNativeLengthProbe.NoLengthProbe)])]
            [_ (EmbeddedNativeLengthProbe.NoLengthProbe)])))]
    [_ (EmbeddedNativeLengthProbe.NoLengthProbe)]))

;; Compile `(if (cmp (comptime.expr-list-length p) lit) then else)` when both
;; branches are supported bodies; returns "" outside that shape. A negative
;; probe (a non-list operand) unwinds as the public bad-request status, the
;; same contract the type-kind probe uses.
(define (embedded-native-computed-if-body
  [params : (& params AstMacroParamList)]
  [body-node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(AstExpr.If cond-node then-node else-node)
      (match (embedded-native-length-probe params cond-node)
        [(EmbeddedNativeLengthProbe.LengthProbe param ordinal literal)
          (let
            [then-code : String (embedded-native-body-code params then-node)]
            [else-code : String (embedded-native-body-code params else-node)]
            (if (or (string.eq then-code "") (string.eq else-code ""))
              ""
              (str-cat
                "  (let [t0 : i64 (comptime-host-invoke host session 155 "
                (string.int->string param)
                " 0 0)]\n"
                "  (if (< t0 0)\n  "
                (string.int->string tlci-host-callback-status-bad-request)
                "\n  (if ("
                (embedded-native-comparison-spelling ordinal)
                " t0 "
                (string.int->string literal)
                ")\n"
                then-code
                else-code
                ")))\n")))]
        [(EmbeddedNativeLengthProbe.NoLengthProbe) ""])]
    [_ ""]))

;; Compile a linear op-chain body (template, fold, or plain builder) into a
;; complete arm block; returns "" when the body is outside the supported
;; subset or would overflow the per-entry op budget (a dropped op can never
;; be emitted silently).
(define (embedded-native-linear-body-code
  [params : (& params AstMacroParamList)]
  [body-node : i64]) : String
  (let
    [ops : (Array String) (array.make-array String embedded-native-ops-cap)]
    [ops-count : (Array i64) (make-array 0)]
    [opened : i64 (embedded-native-body-ops params body-node ops ops-count)]
    (if (or (< opened 0) (>= (array-ref ops-count 0) embedded-native-ops-cap))
      ""
      (embedded-native-arm-block ops (array-ref ops-count 0) opened))))

;; Unified native body compiler: a type-kind match, a computed list-length
;; if, or a linear template/fold/plain body. Returns "" when the body stays
;; an interpreted-fallback shell.
(define (embedded-native-body-code
  [params : (& params AstMacroParamList)]
  [body-node : i64]) : String
  (let
    [match-text : String (embedded-native-match-body params body-node)]
    (if (not (string.eq match-text ""))
      match-text
      (let
        [if-text : String (embedded-native-computed-if-body params body-node)]
        (if (not (string.eq if-text ""))
          if-text
          (embedded-native-linear-body-code params body-node))))))

(define (embedded-native-source
  [names : (Array String)]
  [captures : (& captures TlciNativeMacroCaptures)]) : String
  (let
    [out : String
      (str-cat
        "(module tlci-entries)\n"
        "(extern comptime-host-invoke (:symbol "
        "\"_tl_comptime_host_invoke\") : (-> i64 i64 i64 i64 i64 i64 i64))\n")]
    [count : i64 (array-length names)]
    [index : i64 0]
    [native-count : i64 0]
    (begin
      (while (< index count)
        (let
          [slot : i64
            (tlci-native-macro-capture-slot captures (array-ref names index))]
          [body-text : String
            (if (>= slot 0)
              (embedded-native-body-code
                (&
                  (struct-get
                    (array-ref (struct-get captures slots) slot)
                    params))
                (struct-get (array-ref (struct-get captures slots) slot) body))
              "")]
          (begin
            (set!
              out
              (str-cat
                out
                "(define (macro-entry-"
                (string.int->string index)
                " [image-ctx : i64] [host : i64] [session : i64]"
                " [operands : i64] [count : i64] [result : i64]) : i64\n"))
            (if (string.eq body-text "")
              (set!
                out
                (str-cat
                  out
                  "  (if (= count -"
                  (string.int->string (+ index 2))
                  ") 1 0))\n"))
              (begin
                (set! native-count (+ native-count 1))
                (set!
                  out
                  (str-cat
                    out
                    (embedded-native-op-open 99 1 "0" "0" "0")
                    body-text
                    ")))\n"))))
            (set! index (+ index 1)))))
      (array-set! embedded-stdlib-tlci-native-report-count 0 native-count)
      out)))

(define (embedded-native-entry-offsets
  [image : cobj.CompilerObjectImage]
  [count : i64]) : (Array i64)
  (let
    [out : (Array i64) (array.make-array i64 count)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (let
          [offset : i64
            (compiler-tlci-native-entry-offset
              image
              (str-cat "_tl_f" (string.int->string index)))]
          (if (< offset 0)
            (set! ok false)
            (begin
              (array-set! out index offset)
              (set! index (+ index 1))))))
      (if ok
        out
        (array.make-array i64 0)))))

;; Compile the generated transformer program and assemble the native package
;; image. Identities without captured sources become interpreted-fallback
;; shells, so a caller with no captures gets a pure registration image.
(define (embedded-native-emit-package
  [metadata-text : String]
  [build-hash : String]
  [windows-target : bool]
  [rodata : (Array u8)]
  [names : (Array String)]
  [captures : (& captures TlciNativeMacroCaptures)]) : ResultProducerBytes
  (let
    [source : String (embedded-native-source names captures)]
    [target : CompilerBackendTarget
      (if windows-target
        (CompilerBackendTarget.Windows)
        (CompilerBackendTarget.Linux))]
    (match (compiler-backend-lower-source-for-target-in-session source target)
      [(ResultCompilerLower.Err diag)
        (ResultProducerBytes.Err
          (str-cat
            "generated source rejected: "
            (compiler-diagnostic-render (box-get diag))))]
      [(ResultCompilerLower.Ok program spans)
        (match (compiler-backend-emit-program-object-image-target-with-mode-and-crt
          program
          target
          (CompilerBackendMode.Scalar)
          spans
          false
          false)
          [(ResultCompilerBackendObject.Err diag)
            (ResultProducerBytes.Err
              (str-cat
                "object emission failed: "
                (compiler-diagnostic-render (box-get diag))))]
          [(ResultCompilerBackendObject.Ok image)
            (match (compiler-tlci-native-layout-image image)
              [(ResultCompilerTlciNativeLayout.Err message)
                (ResultProducerBytes.Err message)]
              [(ResultCompilerTlciNativeLayout.Ok layout)
                (let
                  [entry-offsets : (Array i64)
                    (embedded-native-entry-offsets image (array-length names))]
                  (if (not
                    (= (array-length entry-offsets) (array-length names)))
                    (ResultProducerBytes.Err
                      "entry count does not match catalog")
                    (match (compiler-tlci-native-emit-imports (& layout))
                      [(ResultCompilerTlciNativeImports.Err message)
                        (ResultProducerBytes.Err message)]
                      [(ResultCompilerTlciNativeImports.Ok imports)
                        (match (compiler-tlci-native-package
                          metadata-text
                          build-hash
                          rodata
                          (struct-get layout bytes)
                          imports
                          (struct-get layout fixup-offsets)
                          (struct-get layout fixup-count)
                          names
                          entry-offsets
                          (array-length names))
                          [(ResultCompilerTlciNativeBytes.Err message)
                            (ResultProducerBytes.Err message)]
                          [(ResultCompilerTlciNativeBytes.Ok bytes)
                            (ResultProducerBytes.Ok bytes)])])))])])])))