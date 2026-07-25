;; compiler_tlci_native_producer.tl - Generate and map normal-backend
;; transformer programs for tlci native package images (refs #5213, #5596).
;;
;; The producer captures checked defmacro identities, parameters, and bodies,
;; desugars eligible bodies (general quasiquote templates -- nested calls,
;; literals, plain symbols, unquoted operands and computed unquotes, and
;; unquote-splicing -- array intrinsic nodes, literal templates,
;; match-on-type-kind computed bodies, operand-count computed ifs and integer
;; matches, indexed operand access, and the expr-list fold intrinsics) into ordinary
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

;; Compile-time let-local session slots for the body currently compiling
;; (let* scoping; the length is saved and restored around nested bodies).
;; Names are source spellings looked up newest-first so later bindings
;; shadow earlier ones. Refs #5603.
(define embedded-native-locals-cap : i64
  32)
(define embedded-native-local-names : (Array String)
  (array.make-array String embedded-native-locals-cap))
(define embedded-native-local-len : (Array i64)
  (make-array 0))

;; Compile-time i64 locals for the body currently compiling: a binder arm of a
;; computed integer match binds the scrutinee's generated i64 variable, so a
;; later `(comptime.expr-int n)` reads the count as data instead of a literal.
;; Refs #5617.
(define embedded-native-data-locals-cap : i64
  8)
(define embedded-native-data-local-names : (Array String)
  (array.make-array String embedded-native-data-locals-cap))
(define embedded-native-data-local-texts : (Array String)
  (array.make-array String embedded-native-data-locals-cap))
(define embedded-native-data-local-len : (Array i64)
  (make-array 0))

;; Serial number for generated i64 temporaries; unique names keep an arm body's
;; own temporaries from shadowing a scrutinee its default arm still reads.
(define embedded-native-temp-seq : (Array i64)
  (make-array 0))

(define (embedded-native-locals-reset!) : unit
  (begin
    (array-set! embedded-native-local-len 0 0)
    (array-set! embedded-native-data-local-len 0 0)
    (array-set! embedded-native-temp-seq 0 0)))

(define (embedded-native-temp-name!) : String
  (let
    [seq : i64 (array-ref embedded-native-temp-seq 0)]
    (begin
      (array-set! embedded-native-temp-seq 0 (+ seq 1))
      (str-cat "k" (string.int->string seq)))))

;; The generated i64 variable of a compile-time data local, or "" when unbound.
(define (embedded-native-data-local-text [name : String]) : String
  (let
    [index : i64 (- (array-ref embedded-native-data-local-len 0) 1)]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (>= index 0))
        (if (string.eq (array-ref embedded-native-data-local-names index) name)
          (set! found index)
          (set! index (- index 1))))
      (if (< found 0)
        ""
        (array-ref embedded-native-data-local-texts found)))))

;; Bind `name` to the generated i64 variable `text`; false when the slot budget
;; is exhausted (the caller then keeps the fallback shell).
(define (embedded-native-data-local-push! [name : String] [text : String]) : bool
  (let
    [slot : i64 (array-ref embedded-native-data-local-len 0)]
    (if (>= slot embedded-native-data-locals-cap)
      false
      (begin
        (array-set! embedded-native-data-local-names slot name)
        (array-set! embedded-native-data-local-texts slot text)
        (array-set! embedded-native-data-local-len 0 (+ slot 1))
        true))))

;; The session-slot index of a let-bound local, or -1 when unbound.
(define (embedded-native-local-index [name : String]) : i64
  (let
    [index : i64 (- (array-ref embedded-native-local-len 0) 1)]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (>= index 0))
        (if (string.eq (array-ref embedded-native-local-names index) name)
          (set! found index)
          (set! index (- index 1))))
      found)))

;; Bind `name` into the next session slot; returns the slot, or -1 when the
;; slot budget is exhausted (the caller then keeps the fallback shell).
(define (embedded-native-local-push! [name : String]) : i64
  (let
    [slot : i64 (array-ref embedded-native-local-len 0)]
    (if (>= slot embedded-native-locals-cap)
      -1
      (begin
        (array-set! embedded-native-local-names slot name)
        (array-set! embedded-native-local-len 0 (+ slot 1))
        slot))))

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

;; A native entry can still hand single arms back to the interpreter: an arm
;; body outside the supported subset compiles to ok-with-no-result instead of
;; poisoning the whole entry. That is deliberate -- partial nativeness is still
;; a win -- but it makes the native entry count an upper bound on coverage, so
;; the emitted arm carries a marker comment and the producer reports how many
;; such sites and entries the image contains. Refs #5596.
(define embedded-native-interpreted-arm-marker : String
  ";; tlci-interpreted-arm")
(define embedded-native-interpreted-arm-code : String
  "  ;; tlci-interpreted-arm\n  0\n")

;: Entries that compiled natively but still contain at least one interpreted
;: arm site.
(define embedded-stdlib-tlci-native-report-partial-count : (Array i64)
  (make-array 0))

;: Interpreted arm sites across every native entry in the image.
(define embedded-stdlib-tlci-native-report-interpreted-arms : (Array i64)
  (make-array 0))

;: How many non-overlapping occurrences of `needle` appear in `text`.
(define (embedded-native-count-occurrences [text : String] [needle : String]) : i64
  (let
    [needle-len : i64 (string.string-length needle)]
    [limit : i64 (string.string-length text)]
    [index : i64 0]
    [count : i64 0]
    (begin
      (when
        (> needle-len 0)
        (while (<= (+ index needle-len) limit)
          (if (string.is-string-prefix-at text needle index)
            (begin
              (set! count (+ count 1))
              (set! index (+ index needle-len)))
            (set! index (+ index 1)))))
      count)))

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

;; Emit the push for an unquoted name in template/computed position: a macro
;; parameter pushes its operand (op 180), a let-bound local pushes its session
;; slot (op 205). Returns 1, or -1 when the name is unbound. Refs #5603.
(define (embedded-native-unquote-ops
  [params : (& params AstMacroParamList)]
  [pname : i64]
  [ops : (Array String)]
  [ops-count : (Array i64)]) : i64
  (let
    [param : i64 (embedded-stdlib-tlci-param-index params pname)]
    (if (>= param 0)
      (begin
        (embedded-native-template-push!
          ops
          ops-count
          180
          (string.int->string param)
          "0"
          "0")
        1)
      (let
        [slot : i64 (embedded-native-local-index (intern-str pname))]
        (if (< slot 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              205
              (string.int->string slot)
              "0"
              "0")
            1))))))

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

;; Emit the op chain for a template node that wraps exactly one subexpression
;; (`return`, `box`, `box-get`): the operand's chain followed by `op`. Returns
;; the opened op-let count or -1 when the operand is outside the supported
;; subset. Refs #5605.
(define (embedded-native-template-unary-node-ops
  [params : (& params AstMacroParamList)]
  [inner-node : i64]
  [op : i64]
  [ops : (Array String)]
  [ops-count : (Array i64)]) : i64
  (let
    [inner-opened : i64
      (embedded-native-template-ops params inner-node ops ops-count)]
    (if (< inner-opened 0)
      -1
      (begin
        (embedded-native-template-push! ops ops-count op "0" "0" "0")
        (+ inner-opened 1)))))

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
          (embedded-native-unquote-ops params pname ops ops-count)]
        ;; Any other unquoted operand is a computed comptime expression whose
        ;; value substitutes into the template, matching the interpreted
        ;; quote's unquote step. Refs #5617.
        [_ (embedded-native-computed-expr-ops params inner ops ops-count)])]
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
        [(AstLiteral.Float text)
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              232
              (embedded-native-name-arg (embedded-native-escape-string text))
              (string.int->string (string.string-length text))
              "0")
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
      (let
        [head-opened : i64
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
                  1))]
            ;; An unquoted head (a macro parameter or let-bound local used as
            ;; the call operator) builds like any other template expression.
            [_ (embedded-native-template-ops params func-id ops ops-count)])]
        (if (< head-opened 0)
          -1
          (let
            [arg-opened : i64
              (embedded-native-template-args-ops params (& args) ops ops-count)]
            (if (< arg-opened 0)
              -1
              (begin
                (embedded-native-template-push! ops ops-count 181 "0" "0" "0")
                (+ arg-opened 2))))))]
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
    [(AstExpr.BracketClause items)
      (let
        [arg-opened : i64
          (embedded-native-template-args-ops params (& items) ops ops-count)]
        (if (< arg-opened 0)
          -1
          (begin
            (embedded-native-template-push! ops ops-count 207 "0" "0" "0")
            (+ arg-opened 1))))]
    [(AstExpr.Borrow mutable lifetime place)
      (let
        [place-opened : i64
          (embedded-native-template-ops params place ops ops-count)]
        (if (< place-opened 0)
          -1
          (match lifetime
            [(AstBorrowLifetime.Inferred)
              (begin
                (embedded-native-template-push!
                  ops
                  ops-count
                  208
                  (if mutable
                    "1"
                    "0")
                  "0"
                  "0")
                (+ place-opened 1))]
            [(AstBorrowLifetime.Named lifetime-id)
              (let
                [lifetime-name : String (intern-str lifetime-id)]
                (begin
                  (embedded-native-template-push!
                    ops
                    ops-count
                    208
                    (if mutable
                      "1"
                      "0")
                    (embedded-native-name-arg lifetime-name)
                    (string.int->string (string.string-length lifetime-name)))
                  (+ place-opened 1)))]
            [_ -1])))]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee arms)
          (let
            [scrut-opened : i64
              (embedded-native-template-ops params scrutinee ops ops-count)]
            (if (< scrut-opened 0)
              -1
              (let
                [arms-opened : i64
                  (embedded-native-template-match-arms-ops
                    params
                    (& arms)
                    ops
                    ops-count)]
                (if (< arms-opened 0)
                  -1
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      124
                      "0"
                      "0"
                      "0")
                    (+ scrut-opened arms-opened 1))))))])]
    [(AstExpr.StructGet target field)
      (let
        [target-opened : i64
          (embedded-native-template-ops params target ops ops-count)]
        (if (< target-opened 0)
          -1
          (let
            [field-name : String (intern-str field)]
            (begin
              (embedded-native-template-push!
                ops
                ops-count
                104
                (embedded-native-name-arg field-name)
                (string.int->string (string.string-length field-name))
                "0")
              (+ target-opened 1)))))]
    [(AstExpr.ArraySet target index value)
      (let
        [target-opened : i64
          (embedded-native-template-ops params target ops ops-count)]
        (if (< target-opened 0)
          -1
          (let
            [index-opened : i64
              (embedded-native-template-ops params index ops ops-count)]
            (if (< index-opened 0)
              -1
              (let
                [value-opened : i64
                  (embedded-native-template-ops params value ops ops-count)]
                (if (< value-opened 0)
                  -1
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      212
                      "0"
                      "0"
                      "0")
                    (+ target-opened index-opened value-opened 1))))))))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body)
          (begin
            (embedded-native-template-push! ops ops-count 214 "0" "0" "0")
            (let
              [bindings-opened : i64
                (embedded-native-template-let-bindings-ops
                  params
                  (& bindings)
                  0
                  ops
                  ops-count)]
              (if (< bindings-opened 0)
                -1
                (let
                  [body-opened : i64
                    (embedded-native-template-ops params body ops ops-count)]
                  (if (< body-opened 0)
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        216
                        "0"
                        "0"
                        "0")
                      (+ bindings-opened body-opened 2)))))))])]
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
    [(AstExpr.Return inner-node)
      (embedded-native-template-unary-node-ops
        params
        inner-node
        229
        ops
        ops-count)]
    [(AstExpr.Box inner-node)
      (embedded-native-template-unary-node-ops
        params
        inner-node
        230
        ops
        ops-count)]
    [(AstExpr.BoxGet inner-node)
      (embedded-native-template-unary-node-ops
        params
        inner-node
        231
        ops
        ops-count)]
    ;; `(set! (struct-get target field) value)`. The parser folds the place into
    ;; the node, so the field name travels as an immediate like struct-get's.
    ;; The sentinel field id marks `(set! ,place value)`, whose place shape is
    ;; only known once the unquoted operand is evaluated; that stays a fallback.
    [(AstExpr.StructSet target-node field value-node)
      (if (= field (ast-expr-unquote-set-target-field-id))
        -1
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
                (let
                  [field-name : String (intern-str field)]
                  (begin
                    (embedded-native-template-push!
                      ops
                      ops-count
                      106
                      (embedded-native-name-arg field-name)
                      (string.int->string (string.string-length field-name))
                      "0")
                    (+ target-opened value-opened 1))))))))]
    [(AstExpr.Set name-id value-node)
      (let
        [value-opened : i64
          (embedded-native-template-ops params value-node ops ops-count)]
        (if (< value-opened 0)
          -1
          (let
            [name : String (intern-str name-id)]
            (begin
              (embedded-native-template-push!
                ops
                ops-count
                194
                (embedded-native-name-arg name)
                (string.int->string (string.string-length name))
                "0")
              (+ value-opened 1)))))]
    [(AstExpr.While cond-node body-node)
      (let
        [cond-opened : i64
          (embedded-native-template-ops params cond-node ops ops-count)]
        (if (< cond-opened 0)
          -1
          (let
            [body-opened : i64
              (embedded-native-template-ops params body-node ops ops-count)]
            (if (< body-opened 0)
              -1
              (begin
                (embedded-native-template-push! ops ops-count 197 "0" "0" "0")
                (+ cond-opened body-opened 1))))))]
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
                    [slot : i64
                      (if (< param 0)
                        (embedded-native-local-index (intern-str pname))
                        -1)]
                    (if (and (< param 0) (< slot 0))
                      (set! ok false)
                      (begin
                        (embedded-native-template-push!
                          ops
                          ops-count
                          (if (< param 0)
                            205
                            180)
                          (string.int->string
                            (if (< param 0)
                              slot
                              param))
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

;; Emit ops building one template match arm list: match-arm-list-empty, then
;; per arm the pattern, the body template, match-arm, and match-arm-list-cons.
;; Returns the opened op-let count or -1 when any piece is outside the
;; supported subset. Refs #5603.
(define (embedded-native-template-match-arms-ops
  [params : (& params AstMacroParamList)]
  [arms : (& arms AstMatchArmList)]
  [ops : (Array String)]
  [ops-count : (Array i64)]) : i64
  (let
    [count : i64 (struct-get arms len)]
    [index : i64 0]
    [opened : i64 1]
    [ok : bool true]
    (begin
      (embedded-native-template-push! ops ops-count 122 "0" "0" "0")
      (while (and ok (< index count))
        (match (array-ref (struct-get arms slots) index)
          [(AstMatchArm.Arm pattern body-node)
            (let
              [pat-opened : i64
                (match pattern
                  [(AstPattern.Wildcard)
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        116
                        "0"
                        "0"
                        "0")
                      1)]
                  [(AstPattern.Binding pat-name-id)
                    (let
                      [pat-name : String (intern-str pat-name-id)]
                      (begin
                        (embedded-native-template-push!
                          ops
                          ops-count
                          117
                          (embedded-native-name-arg pat-name)
                          (string.int->string (string.string-length pat-name))
                          "0")
                        1))]
                  [(AstPattern.Var pat-name-id pat-maybe-ty)
                    (match pat-maybe-ty
                      [(AstMaybeType.No)
                        (let
                          [pat-name : String (intern-str pat-name-id)]
                          (begin
                            (embedded-native-template-push!
                              ops
                              ops-count
                              211
                              (embedded-native-name-arg pat-name)
                              (string.int->string
                                (string.string-length pat-name))
                              "0")
                            1))]
                      [_ -1])]
                  [(AstPattern.Variant pat-name-id pat-args-box)
                    (let
                      [pat-name : String (intern-str pat-name-id)]
                      [pat-args : AstPatternList (box-get pat-args-box)]
                      [pat-arg-opened : i64
                        (embedded-native-pattern-list-ops
                          (& pat-args)
                          0
                          ops
                          ops-count
                          0)]
                      (if (< pat-arg-opened 0)
                        -1
                        (begin
                          (embedded-native-template-push!
                            ops
                            ops-count
                            118
                            (embedded-native-name-arg pat-name)
                            (string.int->string (string.string-length pat-name))
                            (string.int->string (struct-get (& pat-args) len)))
                          (+ pat-arg-opened 1))))]
                  [_ -1])]
              (if (< pat-opened 0)
                (set! ok false)
                (let
                  [body-opened : i64
                    (embedded-native-template-ops
                      params
                      body-node
                      ops
                      ops-count)]
                  (if (< body-opened 0)
                    (set! ok false)
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        121
                        "0"
                        "0"
                        "0")
                      (embedded-native-template-push!
                        ops
                        ops-count
                        123
                        "0"
                        "0"
                        "0")
                      (set! opened (+ opened pat-opened body-opened 2))
                      (set! index (+ index 1)))))))]
          [_ (set! ok false)]))
      (if ok
        opened
        -1))))

;; Emit the ops producing one template pattern. Variant constructor names pass
;; through unmarked; binding and unit-variable names carry the template-source
;; mark, matching the interpreted quote. Returns the opened op-let count or
;; -1 outside the supported subset.
(define (embedded-native-pattern-ops
  [pattern : AstPattern]
  [ops : (Array String)]
  [ops-count : (Array i64)]) : i64
  (match pattern
    [(AstPattern.Wildcard)
      (begin
        (embedded-native-template-push! ops ops-count 116 "0" "0" "0")
        1)]
    [(AstPattern.Binding name-id)
      (let
        [name : String (intern-str name-id)]
        (begin
          (embedded-native-template-push!
            ops
            ops-count
            117
            (embedded-native-name-arg name)
            (string.int->string (string.string-length name))
            "0")
          1))]
    [(AstPattern.Var name-id maybe-ty)
      (match maybe-ty
        [(AstMaybeType.No)
          (let
            [name : String (intern-str name-id)]
            (begin
              (embedded-native-template-push!
                ops
                ops-count
                211
                (embedded-native-name-arg name)
                (string.int->string (string.string-length name))
                "0")
              1))]
        [_ -1])]
    [(AstPattern.Variant name-id args-box)
      (let
        [name : String (intern-str name-id)]
        [args : AstPatternList (box-get args-box)]
        [arg-opened : i64
          (embedded-native-pattern-list-ops (& args) 0 ops ops-count 0)]
        (if (< arg-opened 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              118
              (embedded-native-name-arg name)
              (string.int->string (string.string-length name))
              (string.int->string (struct-get (& args) len)))
            (+ arg-opened 1))))]
    [_ -1]))

(define (embedded-native-pattern-list-ops
  [args : (& args AstPatternList)]
  [index : i64]
  [ops : (Array String)]
  [ops-count : (Array i64)]
  [opened : i64]) : i64
  (if (>= index (struct-get args len))
    opened
    (let
      [item-opened : i64
        (embedded-native-pattern-ops
          (ast-pattern-list-get args index (ast-pattern-fallback))
          ops
          ops-count)]
      (if (< item-opened 0)
        -1
        (embedded-native-pattern-list-ops
          args
          (+ index 1)
          ops
          ops-count
          (+ opened item-opened))))))

;; Scalar AstType ordinal contract shared with the host callback consumer;
;; the embedded image and its consumer are always the same source-bound
;; binary. Refs #5603.
(define (embedded-native-scalar-type-ordinal [ty : AstType]) : i64
  (match ty
    [(AstType.I64) 0]
    [(AstType.I32) 1]
    [(AstType.I16) 2]
    [(AstType.I8) 3]
    [(AstType.U64) 4]
    [(AstType.U32) 5]
    [(AstType.U16) 6]
    [(AstType.U8) 7]
    [(AstType.F64) 8]
    [(AstType.F32) 9]
    [(AstType.Bool) 10]
    [(AstType.Char) 11]
    [(AstType.String) 12]
    [(AstType.Str) 13]
    [(AstType.Bytes) 14]
    [(AstType.Expr) 15]
    [(AstType.ExprList) 16]
    [(AstType.Unit) 17]
    [(AstType.Never) 18]
    [_ -1]))

;; Emit ops building one template let-binding list: empty, then per binding
;; the init template, the (possibly typed) binding, and cons. Plain `Var`
;; type annotations pass through as type-var; unquoted annotations are not
;; supported yet (the caller keeps the fallback shell). Returns the opened
;; op-let count or -1 outside the subset.
;; Emit the type-template ops for one binding annotation: plain `Var` names
;; and scalar types. Other shapes keep the fallback shell. Returns the opened
;; op-let count or -1 outside the subset.
(define (embedded-native-template-type-ops
  [ty : AstType]
  [ops : (Array String)]
  [ops-count : (Array i64)]) : i64
  (match ty
    [(AstType.Var type-name-id)
      (let
        [type-name : String (intern-str type-name-id)]
        (begin
          (embedded-native-template-push!
            ops
            ops-count
            218
            (embedded-native-name-arg type-name)
            (string.int->string (string.string-length type-name))
            "0")
          1))]
    [_
      (let
        [ordinal : i64 (embedded-native-scalar-type-ordinal ty)]
        (if (< ordinal 0)
          -1
          (begin
            (embedded-native-template-push!
              ops
              ops-count
              220
              (string.int->string ordinal)
              "0"
              "0")
            1)))]))

(define (embedded-native-template-let-bindings-ops
  [params : (& params AstMacroParamList)]
  [bindings : (& bindings AstLetBindingList)]
  [index : i64]
  [ops : (Array String)]
  [ops-count : (Array i64)]) : i64
  (if (>= index (struct-get bindings len))
    0
    (match (ast-let-binding-list-get bindings index (ast-let-binding-fallback))
      [(AstLetBinding.Binding name-id maybe-ty init)
        (let
          [name : String (intern-str name-id)]
          [init-opened : i64
            (embedded-native-template-ops params init ops ops-count)]
          (if (< init-opened 0)
            -1
            (let
              [binding-opened : i64
                (match maybe-ty
                  [(AstMaybeType.No)
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        213
                        (embedded-native-name-arg name)
                        (string.int->string (string.string-length name))
                        "0")
                      1)]
                  [(AstMaybeType.Some ty)
                    (let
                      [type-opened : i64
                        (embedded-native-template-type-ops ty ops ops-count)]
                      (if (< type-opened 0)
                        -1
                        (begin
                          (embedded-native-template-push!
                            ops
                            ops-count
                            219
                            (embedded-native-name-arg name)
                            (string.int->string (string.string-length name))
                            "0")
                          (+ type-opened 1))))]
                  [_ -1])]
              (if (< binding-opened 0)
                -1
                (begin
                  (embedded-native-template-push! ops ops-count 215 "0" "0" "0")
                  (let
                    [rest-opened : i64
                      (embedded-native-template-let-bindings-ops
                        params
                        bindings
                        (+ index 1)
                        ops
                        ops-count)]
                    (if (< rest-opened 0)
                      -1
                      (+ init-opened binding-opened 1 rest-opened))))))))]
      [_ -1])))

;; Full source for the native package: the host extern plus one entry function
;; per identity in catalog order.
;; A complete, balanced arm expression: the op lets, the status-sum return
;; (q99 is the enclosing fuel status), and one closing paren per op let.
(define (embedded-native-arm-block-with-final
  [ops : (Array String)]
  [ops-count : i64]
  [opened : i64]
  [final : String]) : String
  (let
    [out : String ""]
    [index : i64 0]
    (begin
      (while (< index ops-count)
        (begin
          (set! out (str-cat out (array-ref ops index)))
          (set! index (+ index 1))))
      (set! out (str-cat out final))
      (set! index 0)
      (while (< index (* opened 2))
        (begin
          (set! out (str-cat out ")"))
          (set! index (+ index 1))))
      out)))

(define (embedded-native-arm-block
  [ops : (Array String)]
  [ops-count : i64]
  [opened : i64]) : String
  (embedded-native-arm-block-with-final
    ops
    ops-count
    opened
    "  (comptime-host-invoke host session 182 0 0 0)\n"))

(define (embedded-native-var-param-index
  [params : (& params AstMacroParamList)]
  [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(AstExpr.Var pname) (embedded-stdlib-tlci-param-index params pname)]
    [_ -1]))

;; Emit the op chain for one computed (non-template) expression, producing
;; exactly one session value: string literals as comptime String values,
;; string-append, the expr-var builder, type-key/type-kind reflection on a
;; type parameter, a parameter operand, or a let-bound local. Returns the
;; opened op-let count, or -1 outside the subset. Refs #5603.
(define (embedded-native-computed-expr-ops
  [params : (& params AstMacroParamList)]
  [node : i64]
  [ops : (Array String)]
  [ops-count : (Array i64)]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(AstExpr.Literal lit)
      (match lit
        [(AstLiteral.String sid)
          (let
            [text : String (intern-str sid)]
            (begin
              (embedded-native-template-push!
                ops
                ops-count
                209
                (embedded-native-name-arg (embedded-native-escape-string text))
                (string.int->string (string.string-length text))
                "0")
              1))]
        [_ -1])]
    [(AstExpr.Var pname)
      (embedded-native-unquote-ops params pname ops ops-count)]
    [(AstExpr.Call func args)
      (match (embedded-stdlib-tlci-unwrap-expr func)
        [(AstExpr.Var head-id)
          (let
            [head : String (intern-str head-id)]
            [argc : i64 (ast-expr-list-len (& args))]
            (cond
              [(and
                  (or
                    (string.eq head "comptime.string-append")
                    (string.eq head "string-append"))
                  (= argc 2))
                (embedded-native-computed-binary-ops
                  params
                  (ast-expr-list-get (& args) 0 0)
                  (ast-expr-list-get (& args) 1 0)
                  109
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-var")
                    (string.eq head "expr-var"))
                  (= argc 1))
                (let
                  [lit-name : String (embedded-native-expr-var-name node)]
                  (if (> (string.string-length lit-name) 0)
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        103
                        (embedded-native-name-arg lit-name)
                        (string.int->string (string.string-length lit-name))
                        "0")
                      1)
                    (let
                      [inner-opened : i64
                        (embedded-native-computed-expr-ops
                          params
                          (ast-expr-list-get (& args) 0 0)
                          ops
                          ops-count)]
                      (if (< inner-opened 0)
                        -1
                        (begin
                          (embedded-native-template-push!
                            ops
                            ops-count
                            206
                            "0"
                            "0"
                            "0")
                          (+ inner-opened 1))))))]
              [(and
                  (or
                    (string.eq head "comptime.type-key")
                    (string.eq head "type-key"))
                  (= argc 1))
                (embedded-native-computed-type-query-ops
                  params
                  (ast-expr-list-get (& args) 0 0)
                  131
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.type-kind")
                    (string.eq head "type-kind"))
                  (= argc 1))
                (embedded-native-computed-type-query-ops
                  params
                  (ast-expr-list-get (& args) 0 0)
                  130
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.array-element-type")
                    (string.eq head "array-element-type"))
                  (= argc 1))
                (embedded-native-computed-type-query-ops
                  params
                  (ast-expr-list-get (& args) 0 0)
                  141
                  ops
                  ops-count)]
              [(and
                  (or
                    (string.eq head "comptime.expr-int")
                    (string.eq head "expr-int"))
                  (= argc 1))
                (match (embedded-stdlib-tlci-unwrap-expr
                  (ast-expr-list-get (& args) 0 0))
                  [(AstExpr.Literal (AstLiteral.Int value text))
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
                  ;; A compile-time data local (a computed match binder), or
                  ;; arithmetic over one, flows into the literal builder as
                  ;; data. Refs #5617, #5602.
                  [_
                    (let
                      [text : String
                        (embedded-native-data-index-text
                          (ast-expr-list-get (& args) 0 0))]
                      (if (string.eq text "")
                        -1
                        (begin
                          (embedded-native-template-push!
                            ops
                            ops-count
                            221
                            text
                            "0"
                            "0")
                          1)))])]
              ;; `(comptime.expr-list-nth p index)` over a variadic operand:
              ;; the host op indexes the operand list exactly like the
              ;; interpreted builtin. Refs #5617.
              [(and
                  (or
                    (string.eq head "comptime.expr-list-nth")
                    (string.eq head "expr-list-nth"))
                  (= argc 2))
                (let
                  [list-param : i64
                    (embedded-native-var-param-index
                      params
                      (ast-expr-list-get (& args) 0 0))]
                  ;; A destructured list payload lives in a session local, so
                  ;; the local-slot twin op indexes it. Refs #5602.
                  [list-slot : i64
                    (if (>= list-param 0)
                      -1
                      (match (embedded-stdlib-tlci-unwrap-expr
                        (ast-expr-list-get (& args) 0 0))
                        [(AstExpr.Var list-name)
                          (embedded-native-local-index (intern-str list-name))]
                        [_ -1]))]
                  [index-text : String
                    (embedded-native-data-index-text
                      (ast-expr-list-get (& args) 1 0))]
                  (if (or
                    (and (< list-param 0) (< list-slot 0))
                    (string.eq index-text ""))
                    -1
                    (begin
                      (embedded-native-template-push!
                        ops
                        ops-count
                        (if (>= list-param 0)
                          156
                          228)
                        (string.int->string
                          (if (>= list-param 0)
                            list-param
                            list-slot))
                        index-text
                        "0")
                      1)))]
              [else -1]))]
        [_ -1])]
    [_ -1]))

;: The generated i64 text of a canonical int literal, a compile-time data
;: local, or their sums and differences; "" for anything else. Refs #5617.
(define (embedded-native-data-index-text [node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(AstExpr.Literal (AstLiteral.Int value text))
      (if (or
        (= (string.string-length text) 0)
        (string.eq text (string.int->string value)))
        (string.int->string value)
        "")]
    [(AstExpr.Var name) (embedded-native-data-local-text (intern-str name))]
    ;; `(+ i 1)` in an index or literal-builder position stays plain generated
    ;; i64 arithmetic over the data locals. Refs #5602.
    [(AstExpr.Binary op left-node right-node)
      (let
        [ordinal : i64 (embedded-native-binop-ordinal op)]
        [left : String (embedded-native-data-index-text left-node)]
        [right : String (embedded-native-data-index-text right-node)]
        (if (or (> ordinal 1) (string.eq left "") (string.eq right ""))
          ""
          (str-cat
            "("
            (if (= ordinal 0)
              "+"
              "-")
            " "
            left
            " "
            right
            ")")))]
    [_ ""]))

;; One i64-valued comptime expression rendered for the generated entry: `open`
;; is the let/if chain any host probe needs (with `opens` let/if pairs to
;; close), and `text` is the value expression, or "" outside the subset.
;; Refs #5602.
(defstruct EmbeddedNativeDataValue
  (open String)
  (text String)
  (opens i64))

(define (embedded-native-data-value-none) : EmbeddedNativeDataValue
  (EmbeddedNativeDataValue "" "" 0))

;; The open chain for a data-returning probe: bind it, then unwind the public
;; bad-request status on the negative malformed-request sentinel.
(define (embedded-native-data-probe-open
  [name : String]
  [op : i64]
  [arg : String]) : String
  (str-cat
    "  (let ["
    name
    " : i64 (comptime-host-invoke host session "
    (string.int->string op)
    " "
    arg
    " 0 0)]\n"
    "  (if (< "
    name
    " 0)\n  "
    (string.int->string tlci-host-callback-status-bad-request)
    "\n"))

;; Literals, data locals, and arithmetic need no probe; an operand or local
;; expression-list length hoists one.
(define (embedded-native-data-value
  [params : (& params AstMacroParamList)]
  [node : i64]) : EmbeddedNativeDataValue
  (let
    [plain : String (embedded-native-data-index-text node)]
    (if (not (string.eq plain ""))
      (EmbeddedNativeDataValue "" plain 0)
      (let
        [operand : i64 (embedded-native-expr-list-length-param params node)]
        (if (>= operand 0)
          (let
            [name : String (embedded-native-temp-name!)]
            (EmbeddedNativeDataValue
              (embedded-native-data-probe-open
                name
                155
                (string.int->string operand))
              name
              1))
          (let
            [slot : i64 (embedded-native-expr-list-length-local params node)]
            (if (< slot 0)
              (embedded-native-data-value-none)
              (let
                [name : String (embedded-native-temp-name!)]
                (EmbeddedNativeDataValue
                  (embedded-native-data-probe-open
                    name
                    227
                    (string.int->string slot))
                  name
                  1)))))))))

;: The session-local slot of a `(comptime.expr-list-length <local>)` call, or
;: -1 for anything else. Refs #5602.
(define (embedded-native-expr-list-length-local
  [params : (& params AstMacroParamList)]
  [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(AstExpr.Call length-func length-args)
      (match (embedded-stdlib-tlci-unwrap-expr length-func)
        [(AstExpr.Var length-head)
          (if (and
            (or
              (string.eq (intern-str length-head) "comptime.expr-list-length")
              (string.eq (intern-str length-head) "expr-list-length"))
            (= (ast-expr-list-len (& length-args)) 1)
            (<
              (embedded-native-var-param-index
                params
                (ast-expr-list-get (& length-args) 0 0))
              0))
            (match (embedded-stdlib-tlci-unwrap-expr
              (ast-expr-list-get (& length-args) 0 0))
              [(AstExpr.Var list-name)
                (embedded-native-local-index (intern-str list-name))]
              [_ -1])
            -1)]
        [_ -1])]
    [_ -1]))

;; Compile `(if (<cmp> <i64> <i64>) then else)` where each side is a literal,
;; a compile-time data local, arithmetic over them, or an operand/local
;; expression-list length. Returns "" outside that shape. Refs #5602.
(define (embedded-native-data-if-body
  [params : (& params AstMacroParamList)]
  [body-node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(AstExpr.If cond-node then-node else-node)
      (match (embedded-stdlib-tlci-unwrap-expr cond-node)
        [(AstExpr.Binary op left-node right-node)
          (let
            [ordinal : i64 (embedded-native-binop-ordinal op)]
            [left : EmbeddedNativeDataValue
              (embedded-native-data-value params left-node)]
            [right : EmbeddedNativeDataValue
              (embedded-native-data-value params right-node)]
            (if (or
              (< ordinal 5)
              (> ordinal 10)
              (string.eq (struct-get left text) "")
              (string.eq (struct-get right text) ""))
              ""
              (let
                [then-code : String
                  (embedded-native-body-code params then-node)]
                [else-code : String
                  (embedded-native-body-code params else-node)]
                (if (or (string.eq then-code "") (string.eq else-code ""))
                  ""
                  (str-cat
                    (struct-get left open)
                    (struct-get right open)
                    "  (if ("
                    (embedded-native-comparison-spelling ordinal)
                    " "
                    (struct-get left text)
                    " "
                    (struct-get right text)
                    ")\n"
                    then-code
                    else-code
                    ")\n"
                    (embedded-native-closing-parens
                      (* 2 (+ (struct-get left opens) (struct-get right opens)))))))))]
        [_ ""])]
    [_ ""]))

;; Two computed expressions then one binary host op over their session values.
(define (embedded-native-computed-binary-ops
  [params : (& params AstMacroParamList)]
  [left-node : i64]
  [right-node : i64]
  [op : i64]
  [ops : (Array String)]
  [ops-count : (Array i64)]) : i64
  (let
    [left-opened : i64
      (embedded-native-computed-expr-ops params left-node ops ops-count)]
    (if (< left-opened 0)
      -1
      (let
        [right-opened : i64
          (embedded-native-computed-expr-ops params right-node ops ops-count)]
        (if (< right-opened 0)
          -1
          (begin
            (embedded-native-template-push! ops ops-count op "0" "0" "0")
            (+ left-opened right-opened 1)))))))

;; `(type-key T)` / `(type-kind T)` with a type parameter scrutinee.
(define (embedded-native-computed-type-query-ops
  [params : (& params AstMacroParamList)]
  [arg-node : i64]
  [op : i64]
  [ops : (Array String)]
  [ops-count : (Array i64)]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr arg-node)
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
            (embedded-native-template-push! ops ops-count op "0" "0" "0")
            2)))]
    [_ -1]))

;; The `(comptime-host-invoke host session 204 N 0 0)` local-set final text
;; for one binding slot.
(define (embedded-native-local-set-final [slot : i64]) : String
  (str-cat
    "  (comptime-host-invoke host session 204 "
    (string.int->string slot)
    " 0 0)\n"))

;; Compile one computed expression to a balanced code string evaluating to a
;; host status, ending with the `final` operation over the produced session
;; value. Quasiquoted fragments reuse the general template walker.
;; Returns "" outside the supported subset.
(define (embedded-native-computed-expr-code
  [params : (& params AstMacroParamList)]
  [node : i64]
  [final : String]) : String
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(AstExpr.If cond-node then-node else-node)
      (embedded-native-computed-if-code
        params
        cond-node
        then-node
        else-node
        final)]
    [(AstExpr.Match match-box)
      (embedded-native-computed-match-code params match-box final)]
    ;; A let nested in a computed position (an if/match branch at body
    ;; level): the body commits like a top-level body. Refs #5603.
    [(AstExpr.Let _) (embedded-native-let-body-code params node)]
    [(AstExpr.Call func args)
      (match (embedded-stdlib-tlci-unwrap-expr func)
        [(AstExpr.Var head-id)
          (let
            [head : String (intern-str head-id)]
            [argc : i64 (ast-expr-list-len (& args))]
            (cond
              ;; `(comptime.expr-int (array-length T))`: the count flows as
              ;; data out of the reflection probe into the literal builder.
              [(and
                  (or
                    (string.eq head "comptime.expr-int")
                    (string.eq head "expr-int"))
                  (= argc 1))
                (match (embedded-stdlib-tlci-unwrap-expr
                  (ast-expr-list-get (& args) 0 0))
                  [(AstExpr.Call length-func length-args)
                    (match (embedded-stdlib-tlci-unwrap-expr length-func)
                      [(AstExpr.Var length-head)
                        (if (and
                          (or
                            (string.eq
                              (intern-str length-head)
                              "comptime.array-length")
                            (string.eq (intern-str length-head) "array-length"))
                          (= (ast-expr-list-len (& length-args)) 1))
                          (let
                            [param : i64
                              (embedded-native-var-param-index
                                params
                                (ast-expr-list-get (& length-args) 0 0))]
                            (if (< param 0)
                              ""
                              (embedded-native-arm-block-with-final
                                (embedded-native-single-op-ops
                                  180
                                  (string.int->string param)
                                  "0"
                                  "0")
                                1
                                1
                                (str-cat
                                  "  (let [d0 : i64 (comptime-host-invoke host session 142 0 0 0)]\n"
                                  "  (if (< d0 0)\n  "
                                  (string.int->string
                                    tlci-host-callback-status-bad-request)
                                  "\n"
                                  "  (let [q0 : i64 (comptime-host-invoke host session 221 d0 0 0)] (if (not (= q0 0)) q0\n"
                                  final
                                  "))))\n"))))
                          "")]
                      [_ ""])]
                  [_ ""])]
              ;; `(comptime.comptime-error msg)` / `(comptime.error msg)`:
              ;; the message flows to the session diagnostic with the
              ;; diagnostic status, ignoring `final`.
              [(and
                  (or
                    (string.eq head "comptime.comptime-error")
                    (string.eq head "comptime.error")
                    (string.eq head "comptime-error"))
                  (= argc 1))
                (let
                  [ops : (Array String)
                    (array.make-array String embedded-native-ops-cap)]
                  [ops-count : (Array i64) (make-array 0)]
                  [opened : i64
                    (embedded-native-computed-expr-ops
                      params
                      (ast-expr-list-get (& args) 0 0)
                      ops
                      ops-count)]
                  (if (or
                    (< opened 0)
                    (>= (array-ref ops-count 0) embedded-native-ops-cap))
                    ""
                    (embedded-native-arm-block-with-final
                      ops
                      (array-ref ops-count 0)
                      opened
                      "  (comptime-host-invoke host session 210 0 0 0)\n")))]
              [else
                (embedded-native-computed-expr-code-linear params node final)]))]
        [_ (embedded-native-computed-expr-code-linear params node final)])]
    [_ (embedded-native-computed-expr-code-linear params node final)]))

;; The linear chain fallback for computed-expr-code.
(define (embedded-native-computed-expr-code-linear
  [params : (& params AstMacroParamList)]
  [node : i64]
  [final : String]) : String
  (let
    [ops : (Array String) (array.make-array String embedded-native-ops-cap)]
    [ops-count : (Array i64) (make-array 0)]
    [opened : i64
      (if (match (embedded-stdlib-tlci-unwrap-expr node)
        [(AstExpr.Quasiquote _) true]
        [_ false])
        (embedded-native-body-ops params node ops ops-count)
        (embedded-native-computed-expr-ops params node ops ops-count))]
    (if (or (< opened 0) (>= (array-ref ops-count 0) embedded-native-ops-cap))
      ""
      (embedded-native-arm-block-with-final
        ops
        (array-ref ops-count 0)
        opened
        final))))

;; A one-entry ops array for a single host op.
(define (embedded-native-single-op-ops
  [op : i64]
  [arg-a : String]
  [arg-b : String]
  [arg-c : String]) : (Array String)
  (let
    [ops : (Array String) (array.make-array String embedded-native-ops-cap)]
    [ops-count : (Array i64) (make-array 0)]
    (begin
      (embedded-native-template-push! ops ops-count op arg-a arg-b arg-c)
      ops)))

;; `(if (string.eq A B) then else)` or `(if (cmp (expr-list-length p) lit)
;; then else)` with computed branches sharing one `final` operation.
(define (embedded-native-computed-if-code
  [params : (& params AstMacroParamList)]
  [cond-node : i64]
  [then-node : i64]
  [else-node : i64]
  [final : String]) : String
  (let
    [then-code : String
      (embedded-native-computed-expr-code params then-node final)]
    (if (string.eq then-code "")
      ""
      (let
        [else-code : String
          (embedded-native-computed-expr-code params else-node final)]
        (if (string.eq else-code "")
          ""
          (match (embedded-native-length-probe params cond-node)
            [(EmbeddedNativeLengthProbe.LengthProbe param ordinal literal)
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
                ")))\n")]
            [(EmbeddedNativeLengthProbe.NoLengthProbe)
              (match (embedded-stdlib-tlci-unwrap-expr cond-node)
                [(AstExpr.Call cond-func cond-args)
                  (match (embedded-stdlib-tlci-unwrap-expr cond-func)
                    [(AstExpr.Var cond-head)
                      (let
                        [cond-name : String (intern-str cond-head)]
                        (cond
                          [(and
                              (or
                                (string.eq cond-name "comptime.array-dynamic?")
                                (string.eq cond-name "array-dynamic?"))
                              (= (ast-expr-list-len (& cond-args)) 1))
                            (let
                              [dyn-param : i64
                                (embedded-native-var-param-index
                                  params
                                  (ast-expr-list-get (& cond-args) 0 0))]
                              (if (< dyn-param 0)
                                ""
                                (str-cat
                                  "  (let [q0 : i64 (comptime-host-invoke host session 180 "
                                  (string.int->string dyn-param)
                                  " 0 0)] (if (not (= q0 0)) q0\n"
                                  "  (let [t0 : i64 (comptime-host-invoke host session 143 0 0 0)] (if (< t0 0)\n  "
                                  (string.int->string
                                    tlci-host-callback-status-bad-request)
                                  "\n  (if (= t0 1)\n"
                                  then-code
                                  else-code
                                  ")))))\n")))]
                          [(and
                              (or
                                (string.eq cond-name "comptime.string-eq")
                                (string.eq cond-name "string-eq")
                                (string.eq cond-name "string.eq"))
                              (= (ast-expr-list-len (& cond-args)) 2))
                            (let
                              [ops : (Array String)
                                (array.make-array
                                  String
                                  embedded-native-ops-cap)]
                              [ops-count : (Array i64) (make-array 0)]
                              [opened : i64
                                (embedded-native-computed-binary-ops
                                  params
                                  (ast-expr-list-get (& cond-args) 0 0)
                                  (ast-expr-list-get (& cond-args) 1 0)
                                  107
                                  ops
                                  ops-count)]
                              (if (or
                                (< opened 0)
                                (>=
                                  (array-ref ops-count 0)
                                  embedded-native-ops-cap))
                                ""
                                (embedded-native-arm-block-with-final
                                  ops
                                  (array-ref ops-count 0)
                                  opened
                                  (str-cat
                                    "  (let [c0 : i64 (comptime-host-invoke host session 107 0 0 0)]\n"
                                    "  (if (< c0 0)\n  "
                                    (string.int->string
                                      tlci-host-callback-status-bad-request)
                                    "\n  (if (= c0 1)\n"
                                    then-code
                                    else-code
                                    ")))\n"))))]
                          [else ""]))]
                    [_ ""])]
                [_ ""])]))))))

;; A computed `(match scrutinee ["literal" arm] ... [_ else])` over a String
;; scrutinee: the scrutinee is computed into a fresh session slot, then each
;; literal arm compares with raw local-get/string-value/string-eq chains.
(define (embedded-native-computed-match-code
  [params : (& params AstMacroParamList)]
  [match-box : (Box AstMatch)]
  [final : String]) : String
  (match (box-get match-box)
    [(AstMatch.Match scrutinee arms)
      (let
        [slot : i64 (embedded-native-local-push! "__tlci_match")]
        (if (< slot 0)
          ""
          (let
            [scrut-code : String
              (embedded-native-computed-expr-code
                params
                scrutinee
                (embedded-native-local-set-final slot))]
            (if (string.eq scrut-code "")
              ""
              (let
                [arms-code : String
                  (embedded-native-computed-match-arms-code
                    params
                    (& arms)
                    0
                    slot
                    final)]
                (if (string.eq arms-code "")
                  ""
                  (str-cat
                    "  (let [m"
                    (string.int->string slot)
                    " : i64\n"
                    scrut-code
                    "] (if (not (= m"
                    (string.int->string slot)
                    " 0)) m"
                    (string.int->string slot)
                    "\n"
                    arms-code
                    "))\n")))))))]))

(define (embedded-native-computed-match-arms-code
  [params : (& params AstMacroParamList)]
  [arms : (& arms AstMatchArmList)]
  [index : i64]
  [slot : i64]
  [final : String]) : String
  (if (>= index (struct-get arms len))
    "  0\n"
    (match (array-ref (struct-get arms slots) index)
      [(AstMatchArm.Arm pattern body-node)
        (match pattern
          [(AstPattern.Literal (AstLiteral.String sid))
            (let
              [lit : String (intern-str sid)]
              [arm-code : String
                (embedded-native-computed-expr-code params body-node final)]
              [rest-code : String
                (embedded-native-computed-match-arms-code
                  params
                  arms
                  (+ index 1)
                  slot
                  final)]
              (if (or (string.eq arm-code "") (string.eq rest-code ""))
                ""
                (str-cat
                  "  (let [t"
                  (string.int->string index)
                  " : i64 (comptime-host-invoke host session 205 "
                  (string.int->string slot)
                  " 0 0)] (if (not (= t"
                  (string.int->string index)
                  " 0)) t"
                  (string.int->string index)
                  "\n  (let [u"
                  (string.int->string index)
                  " : i64 (comptime-host-invoke host session 209 "
                  (embedded-native-name-arg (embedded-native-escape-string lit))
                  " "
                  (string.int->string (string.string-length lit))
                  " 0)] (if (not (= u"
                  (string.int->string index)
                  " 0)) u"
                  (string.int->string index)
                  "\n  (let [c"
                  (string.int->string index)
                  " : i64 (comptime-host-invoke host session 107 0 0 0)] (if (< c"
                  (string.int->string index)
                  " 0)\n  "
                  (string.int->string tlci-host-callback-status-bad-request)
                  "\n  (if (= c"
                  (string.int->string index)
                  " 1)\n"
                  arm-code
                  rest-code
                  ")))))))\n")))]
          [(AstPattern.Wildcard)
            (embedded-native-computed-expr-code params body-node final)]
          [_ ""])])))

;; Compile a let-rooted body: each binding's init is a computed expression
;; stored in a fresh session slot, then the body compiles with the new locals
;; visible. let* scoping: binding inits see only earlier locals, and the
;; local length is restored afterwards. Refs #5603.
(define (embedded-native-let-body-code
  [params : (& params AstMacroParamList)]
  [body-node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body)
          (let
            [saved : i64 (array-ref embedded-native-local-len 0)]
            [open-code : String
              (embedded-native-let-bindings-open params (& bindings) 0)]
            (if (string.eq open-code "\x01")
              (begin
                (array-set! embedded-native-local-len 0 saved)
                "")
              (let
                [body-code : String (embedded-native-body-code params body)]
                (begin
                  (array-set! embedded-native-local-len 0 saved)
                  (if (string.eq body-code "")
                    ""
                    (str-cat
                      open-code
                      body-code
                      (embedded-native-closing-parens
                        (* 2 (struct-get (& bindings) len)))))))))]
        [_ ""])]
    [_ ""]))

;; The `(let [sN : i64 <init>] (if (not (= sN 0)) sN` open chain for one or
;; more bindings, or "\x01" on any failure (a sentinel that cannot appear in
;; valid generated code).
(define (embedded-native-let-bindings-open
  [params : (& params AstMacroParamList)]
  [bindings : (& bindings AstLetBindingList)]
  [index : i64]) : String
  (if (>= index (struct-get bindings len))
    ""
    (match (ast-let-binding-list-get bindings index (ast-let-binding-fallback))
      [(AstLetBinding.Binding name _ init)
        (let
          [slot : i64 (embedded-native-local-push! (intern-str name))]
          (if (< slot 0)
            "\x01"
            (let
              [init-code : String
                (embedded-native-computed-expr-code
                  params
                  init
                  (embedded-native-local-set-final slot))]
              (if (string.eq init-code "")
                "\x01"
                (str-cat
                  "  (let [s"
                  (string.int->string slot)
                  " : i64\n"
                  init-code
                  "] (if (not (= s"
                  (string.int->string slot)
                  " 0)) s"
                  (string.int->string slot)
                  "\n"
                  (embedded-native-let-bindings-open
                    params
                    bindings
                    (+ index 1)))))))])))

(define (embedded-native-closing-parens [count : i64]) : String
  (if (<= count 0)
    ""
    (str-cat ")" (embedded-native-closing-parens (- count 1)))))

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
                    embedded-native-interpreted-arm-code
                    arm-code)
                  "\n"
                  rest
                  ")))\n")))]
          [_ embedded-native-interpreted-arm-code])])))

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

;: The variadic-operand index of a `(comptime.expr-list-length p)` call; -1 for
;: any other expression. Refs #5617.
(define (embedded-native-expr-list-length-param
  [params : (& params AstMacroParamList)]
  [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(AstExpr.Call length-func length-args)
      (match (embedded-stdlib-tlci-unwrap-expr length-func)
        [(AstExpr.Var length-head)
          (if (and
            (or
              (string.eq (intern-str length-head) "comptime.expr-list-length")
              (string.eq (intern-str length-head) "expr-list-length"))
            (= (ast-expr-list-len (& length-args)) 1))
            (embedded-native-var-param-index
              params
              (ast-expr-list-get (& length-args) 0 0))
            -1)]
        [_ -1])]
    [_ -1]))

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
        [param : i64 (embedded-native-expr-list-length-param params left-node)]
        (if (or (< ordinal 5) (> ordinal 10) (< param 0))
          (EmbeddedNativeLengthProbe.NoLengthProbe)
          (match (embedded-stdlib-tlci-unwrap-expr right-node)
            [(AstExpr.Literal (AstLiteral.Int value text))
              (if (or
                (= (string.string-length text) 0)
                (string.eq text (string.int->string value)))
                (EmbeddedNativeLengthProbe.LengthProbe param ordinal value)
                (EmbeddedNativeLengthProbe.NoLengthProbe))]
            [_ (EmbeddedNativeLengthProbe.NoLengthProbe)])))]
    [_ (EmbeddedNativeLengthProbe.NoLengthProbe)]))

;; Compile `(match (comptime.expr-list-length p) [<int> body] ... [n body])`:
;; the operand count is probed once into a fresh i64 temporary, each integer
;; arm compares against it, and a trailing binder or wildcard arm is the
;; default. A binder also binds the count as a compile-time data local so the
;; arm can rebuild it with `(comptime.expr-int n)`. Returns "" outside that
;; shape. Refs #5617.
(define (embedded-native-int-match-body
  [params : (& params AstMacroParamList)]
  [body-node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee arms)
          (let
            [param : i64
              (embedded-native-expr-list-length-param params scrutinee)]
            (if (< param 0)
              ""
              (let
                [name : String (embedded-native-temp-name!)]
                [arms-code : String
                  (embedded-native-int-match-arms params (& arms) 0 name)]
                (if (string.eq arms-code "")
                  ""
                  (str-cat
                    "  (let ["
                    name
                    " : i64 (comptime-host-invoke host session 155 "
                    (string.int->string param)
                    " 0 0)]\n"
                    "  (if (< "
                    name
                    " 0)\n  "
                    (string.int->string tlci-host-callback-status-bad-request)
                    "\n"
                    arms-code
                    "))\n")))))])]
    [_ ""]))

;; Compile `(match <operand> [(comptime.Expr.Call callee args) body] ... [_ body])`:
;; the operand's expression shape is probed as data, and a matching arm binds
;; the callee expression and the argument list into session local slots, the
;; same two values the interpreted `comptime.Expr.Call` pattern binds. Returns
;; "" outside that shape. Refs #5602.
(define (embedded-native-value-match-body
  [params : (& params AstMacroParamList)]
  [body-node : i64]) : String
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee arms)
          (let
            [param : i64 (embedded-native-var-param-index params scrutinee)]
            (if (< param 0)
              ""
              (embedded-native-value-match-arms params (& arms) 0 param)))])]
    [_ ""]))

;: The `comptime.Expr.<name>` variant a pattern names, or "" for anything else.
(define (embedded-native-expr-variant-name [name-id : i64]) : String
  (let
    [name : String (intern-str name-id)]
    (cond
      [(string.eq name "comptime.Expr.Call") "Call"]
      [(string.eq name "Expr.Call") "Call"]
      [(string.eq name "comptime.Expr.Int") "Int"]
      [(string.eq name "Expr.Int") "Int"]
      [else ""])))

;; One `(comptime.Expr.Int i)` arm: the operand's shape is probed as data, and
;; the matching arm reads the literal's value into a fresh i64 temporary bound
;; as a compile-time data local for the arm body. Refs #5602.
(define (embedded-native-int-value-arm-code
  [params : (& params AstMacroParamList)]
  [pat-args : (& pat-args AstPatternList)]
  [body-node : i64]
  [param : i64]
  [rest : String]) : String
  (let
    [probe : String (embedded-native-temp-name!)]
    [value : String (embedded-native-temp-name!)]
    [saved : i64 (array-ref embedded-native-data-local-len 0)]
    [bound : bool
      (match (ast-pattern-list-get pat-args 0 (ast-pattern-fallback))
        [(AstPattern.Wildcard) true]
        [(AstPattern.Binding bind-id)
          (embedded-native-data-local-push! (intern-str bind-id) value)]
        [_ false])]
    [arm-code : String
      (if bound
        (embedded-native-body-code params body-node)
        "")]
    (begin
      (array-set! embedded-native-data-local-len 0 saved)
      (if (or (string.eq arm-code "") (string.eq rest ""))
        ""
        (str-cat
          "  (let ["
          probe
          " : i64 (comptime-host-invoke host session 225 "
          (string.int->string param)
          " 0 0)]\n"
          "  (if (< "
          probe
          " 0)\n  "
          (string.int->string tlci-host-callback-status-bad-request)
          "\n  (if (= "
          probe
          " 1)\n"
          "  (let ["
          value
          " : i64 (comptime-host-invoke host session 226 "
          (string.int->string param)
          " 0 0)]\n"
          arm-code
          ")\n"
          rest
          ")))\n")))))

(define (embedded-native-value-match-arms
  [params : (& params AstMacroParamList)]
  [arms : (& arms AstMatchArmList)]
  [index : i64]
  [param : i64]) : String
  (if (>= index (struct-get arms len))
    "  0\n"
    (match (array-ref (struct-get arms slots) index)
      [(AstMatchArm.Arm pattern body-node)
        (match pattern
          [(AstPattern.Variant name-id args-box)
            (let
              [variant : String (embedded-native-expr-variant-name name-id)]
              [pat-args : AstPatternList (box-get args-box)]
              (if (and
                (string.eq variant "Int")
                (= (struct-get (& pat-args) len) 1))
                (embedded-native-int-value-arm-code
                  params
                  (& pat-args)
                  body-node
                  param
                  (embedded-native-value-match-arms
                    params
                    arms
                    (+ index 1)
                    param))
                (if (or
                  (not (string.eq variant "Call"))
                  (not (= (struct-get (& pat-args) len) 2)))
                  ""
                  (let
                    [name : String (embedded-native-temp-name!)]
                    [saved : i64 (array-ref embedded-native-local-len 0)]
                    [bind-code : String
                      (embedded-native-value-match-bind (& pat-args) 0 param)]
                    [arm-code : String
                      (if (string.eq bind-code "\x01")
                        ""
                        (embedded-native-body-code params body-node))]
                    [bound : i64
                      (embedded-native-pattern-binder-count (& pat-args) 0)]
                    (begin
                      (array-set! embedded-native-local-len 0 saved)
                      (let
                        [rest : String
                          (embedded-native-value-match-arms
                            params
                            arms
                            (+ index 1)
                            param)]
                        (if (or (string.eq arm-code "") (string.eq rest ""))
                          ""
                          (str-cat
                            "  (let ["
                            name
                            " : i64 (comptime-host-invoke host session 222 "
                            (string.int->string param)
                            " 0 0)]\n"
                            "  (if (< "
                            name
                            " 0)\n  "
                            (string.int->string
                              tlci-host-callback-status-bad-request)
                            "\n  (if (= "
                            name
                            " 1)\n"
                            bind-code
                            arm-code
                            (embedded-native-closing-parens (* 2 bound))
                            "\n"
                            rest
                            ")))\n"))))))))]
          [(AstPattern.Wildcard) (embedded-native-body-code params body-node)]
          [_ ""])])))

;: How many payload patterns bind a name (each opens one let/if pair).
(define (embedded-native-pattern-binder-count
  [pat-args : (& pat-args AstPatternList)]
  [index : i64]) : i64
  (if (>= index (struct-get pat-args len))
    0
    (+
      (match (ast-pattern-list-get pat-args index (ast-pattern-fallback))
        [(AstPattern.Binding _) 1]
        [_ 0])
      (embedded-native-pattern-binder-count pat-args (+ index 1)))))

;; Emit the `(let [sN : i64 <accessor>] (if (not (= sN 0)) sN` opens that bind
;; one arm's payload patterns to session local slots: a binder takes the value,
;; a wildcard consumes nothing. Returns "\x01" on any unsupported piece.
(define (embedded-native-value-match-bind
  [pat-args : (& pat-args AstPatternList)]
  [index : i64]
  [param : i64]) : String
  (if (>= index (struct-get pat-args len))
    ""
    (let
      [op : i64
        (if (= index 0)
          223
          224)]
      [head : String
        (match (ast-pattern-list-get pat-args index (ast-pattern-fallback))
          [(AstPattern.Wildcard) ""]
          [(AstPattern.Binding bind-id)
            (let
              [slot : i64 (embedded-native-local-push! (intern-str bind-id))]
              (if (< slot 0)
                "\x01"
                (str-cat
                  "  (let [s"
                  (string.int->string slot)
                  " : i64\n"
                  (embedded-native-arm-block-with-final
                    (embedded-native-single-op-ops
                      op
                      (string.int->string param)
                      "0"
                      "0")
                    1
                    1
                    (embedded-native-local-set-final slot))
                  "] (if (not (= s"
                  (string.int->string slot)
                  " 0)) s"
                  (string.int->string slot)
                  "\n")))]
          [_ "\x01"])]
      (if (string.eq head "\x01")
        "\x01"
        (let
          [rest : String
            (embedded-native-value-match-bind pat-args (+ index 1) param)]
          (if (string.eq rest "\x01")
            "\x01"
            (str-cat head rest)))))))

(define (embedded-native-int-match-arms
  [params : (& params AstMacroParamList)]
  [arms : (& arms AstMatchArmList)]
  [index : i64]
  [name : String]) : String
  (if (>= index (struct-get arms len))
    "  0\n"
    (match (array-ref (struct-get arms slots) index)
      [(AstMatchArm.Arm pattern body-node)
        (match pattern
          [(AstPattern.Literal (AstLiteral.Int value text))
            (if (and
              (> (string.string-length text) 0)
              (not (string.eq text (string.int->string value))))
              ""
              (let
                [arm-code : String (embedded-native-body-code params body-node)]
                [rest : String
                  (embedded-native-int-match-arms params arms (+ index 1) name)]
                (if (or (string.eq arm-code "") (string.eq rest ""))
                  ""
                  (str-cat
                    "  (if (= "
                    name
                    " "
                    (string.int->string value)
                    ")\n"
                    arm-code
                    rest
                    ")\n"))))]
          [(AstPattern.Wildcard) (embedded-native-body-code params body-node)]
          [(AstPattern.Binding binder)
            (embedded-native-int-match-default params body-node binder name)]
          [(AstPattern.Var binder (AstMaybeType.No))
            (embedded-native-int-match-default params body-node binder name)]
          [_ ""])])))

;; The default arm of a computed integer match: the binder names the probed
;; count for the arm body, and the binding is dropped again afterwards.
(define (embedded-native-int-match-default
  [params : (& params AstMacroParamList)]
  [body-node : i64]
  [binder : i64]
  [name : String]) : String
  (let
    [saved : i64 (array-ref embedded-native-data-local-len 0)]
    [bound : bool (embedded-native-data-local-push! (intern-str binder) name)]
    [code : String
      (if bound
        (embedded-native-body-code params body-node)
        "")]
    (begin
      (array-set! embedded-native-data-local-len 0 saved)
      code)))

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
    [let-text : String (embedded-native-let-body-code params body-node)]
    (if (not (string.eq let-text ""))
      let-text
      (let
        [match-text : String (embedded-native-match-body params body-node)]
        (if (not (string.eq match-text ""))
          match-text
          (let
            [int-match-text : String
              (embedded-native-int-match-body params body-node)]
            (if (not (string.eq int-match-text ""))
              int-match-text
              (let
                [value-match-text : String
                  (embedded-native-value-match-body params body-node)]
                (if (not (string.eq value-match-text ""))
                  value-match-text
                  (let
                    [data-if-text : String
                      (embedded-native-data-if-body params body-node)]
                    (if (not (string.eq data-if-text ""))
                      data-if-text
                      (let
                        [linear-text : String
                          (embedded-native-linear-body-code params body-node)]
                        (if (not (string.eq linear-text ""))
                          linear-text
                          ;; Computed string matches and string-eq ifs at body
                          ;; level (the module-generator dispatch shapes) share
                          ;; the commit final with template bodies. Refs #5603.
                          (embedded-native-computed-expr-code
                            params
                            body-node
                            "  (comptime-host-invoke host session 182 0 0 0)\n"))))))))))))))

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
    [partial-count : i64 0]
    [interpreted-arms : i64 0]
    (begin
      (while (< index count)
        (let
          [slot : i64
            (tlci-native-macro-capture-slot captures (array-ref names index))]
          [body-text : String
            (if (>= slot 0)
              (begin
                (embedded-native-locals-reset!)
                (embedded-native-body-code
                  (&
                    (struct-get
                      (array-ref (struct-get captures slots) slot)
                      params))
                  (struct-get (array-ref (struct-get captures slots) slot) body)))
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
              (let
                [arm-sites : i64
                  (embedded-native-count-occurrences
                    body-text
                    embedded-native-interpreted-arm-marker)]
                (begin
                  (set! native-count (+ native-count 1))
                  (set! interpreted-arms (+ interpreted-arms arm-sites))
                  (when
                    (> arm-sites 0)
                    (set! partial-count (+ partial-count 1)))
                  (set!
                    out
                    (str-cat
                      out
                      (embedded-native-op-open 99 1 "0" "0" "0")
                      body-text
                      ")))\n")))))
            (set! index (+ index 1)))))
      (array-set! embedded-stdlib-tlci-native-report-count 0 native-count)
      (array-set!
        embedded-stdlib-tlci-native-report-partial-count
        0
        partial-count)
      (array-set!
        embedded-stdlib-tlci-native-report-interpreted-arms
        0
        interpreted-arms)
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