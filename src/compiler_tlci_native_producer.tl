;; compiler_tlci_native_producer.tl - Generate and map normal-backend
;; transformer programs for tlci native package images (refs #5213).
;;
;; The producer captures checked defmacro identities, parameters, and bodies,
;; desugars eligible bodies (splice-only quasiquote templates, array intrinsic
;; nodes, literal templates, and match-on-type-kind computed bodies) into
;; ordinary TypeLisp entry functions whose comptime primitives are host
;; callback calls, and resolves the compiled entries by the compact
;; function-symbol contract. Ineligible bodies and match arms compile to
;; ok-with-no-result shells so the dispatch route keeps its counted
;; interpreted fallback.
(import "compiler_parse_core.tl")
(import compiler_object as cobj)
(import "compiler_tlci_native_image.tl")
(import compiler_builtin_ids as cbi)
(import stdlib.string)
(import stdlib.vector)
(import (vector String) as svec)

(define (embedded-stdlib-tlci-identity [module : String] [name-id : i64]) : String
  (if (= (string.string-length module) 0)
    (intern-str name-id)
    (str-cat module "/" (intern-str name-id))))

;; Every collected macro's checked source is captured so the producer can
;; compile each eligible expression body to a native entry; identities whose
;; bodies fall outside the supported subset stay registration shells with the
;; counted interpreted fallback. array/length must remain native as a
;; regression floor. Refs #5212, #5213.
(define embedded-stdlib-tlci-capture-cap : i64
  1024)
(define embedded-stdlib-tlci-capture-count : (Array i64)
  (make-array 0))
(define embedded-stdlib-tlci-capture-identities : (Array String)
  (array.make-array String 1024))
(define embedded-stdlib-tlci-capture-params : (Array AstMacroParamList)
  (array.make-array AstMacroParamList 1024))
(define embedded-stdlib-tlci-capture-bodies : (Array i64)
  (array.make-array i64 1024))
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

;; Compile the splice-only quasiquote subset: the body must be a quasiquoted
;; call form whose head is a plain name and whose arguments are unquoted
;; macro parameters. Bodies outside this subset return false with no side
;; effect, so the caller keeps them as interpreted-fallback shells. This is
;; the first eligible tranche of #5213; richer bodies are later slices.
(define (embedded-stdlib-tlci-unquoted-param
  [params : (& params AstMacroParamList)]
  [node : i64]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr node)
    [(AstExpr.Unquote inner)
      (match (embedded-stdlib-tlci-unwrap-expr inner)
        [(AstExpr.Var pname) (embedded-stdlib-tlci-param-index params pname)]
        [_ -1])]
    [_ -1]))

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

(define (embedded-stdlib-tlci-capture-slot [identity : String]) : i64
  (let
    [count : i64 (array-ref embedded-stdlib-tlci-capture-count 0)]
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index count))
        (if (string.eq
          (array-ref embedded-stdlib-tlci-capture-identities index)
          identity)
          (set! found index)
          (set! index (+ index 1))))
      found)))

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
(define (embedded-native-body-ops
  [params : AstMacroParamList]
  [body-node : i64]
  [ops : (&mut ops svec.Vec)]) : i64
  (match (embedded-stdlib-tlci-unwrap-expr body-node)
    [(AstExpr.Quasiquote quoted)
      (match (embedded-stdlib-tlci-unwrap-expr quoted)
        [(AstExpr.Call func-id args)
          (match (embedded-stdlib-tlci-unwrap-expr func-id)
            [(AstExpr.Var head-id)
              (let
                [argc : i64 (ast-expr-list-len (& args))]
                [head : String (intern-str head-id)]
                [index : i64 0]
                [opened : i64 0]
                [ok : bool true]
                (begin
                  (svec.push
                    ops
                    (embedded-native-op-open
                      opened
                      103
                      (embedded-native-name-arg head)
                      (string.int->string (string.string-length head))
                      "0"))
                  (set! opened (+ opened 1))
                  (svec.push
                    ops
                    (embedded-native-op-open opened 178 "0" "0" "0"))
                  (set! opened (+ opened 1))
                  (while (and ok (< index argc))
                    (let
                      [param : i64
                        (embedded-stdlib-tlci-unquoted-param
                          (& params)
                          (ast-expr-list-get (& args) index 0))]
                      (if (< param 0)
                        (set! ok false)
                        (begin
                          (svec.push
                            ops
                            (embedded-native-op-open
                              opened
                              180
                              (string.int->string param)
                              "0"
                              "0"))
                          (set! opened (+ opened 1))
                          (svec.push
                            ops
                            (embedded-native-op-open opened 179 "0" "0" "0"))
                          (set! opened (+ opened 1))
                          (set! index (+ index 1))))))
                  (if (not ok)
                    -1
                    (begin
                      (svec.push
                        ops
                        (embedded-native-op-open opened 181 "0" "0" "0"))
                      (+ opened 1)))))]
            [_ -1])]
        [(AstExpr.Literal lit)
          (match lit
            [(AstLiteral.Bool flag)
              (begin
                (svec.push
                  ops
                  (embedded-native-op-open
                    0
                    187
                    (if flag
                      "1"
                      "0")
                    "0"
                    "0"))
                1)]
            [(AstLiteral.Int value text)
              (if (string.eq text (string.int->string value))
                (begin
                  (svec.push
                    ops
                    (embedded-native-op-open
                      0
                      188
                      (string.int->string value)
                      "0"
                      "0"))
                  1)
                -1)]
            [_ -1])]
        [(AstExpr.ArrayRef target-node index-node)
          (embedded-native-binary-ops params target-node index-node 183 ops)]
        [(AstExpr.ArrayPush target-node value-node)
          (embedded-native-binary-ops params target-node value-node 184 ops)]
        [(AstExpr.MakeArray elem-type size-node)
          (let
            [ti : i64
              (embedded-stdlib-tlci-type-unquote-param (& params) elem-type)]
            [si : i64
              (embedded-stdlib-tlci-unquoted-param (& params) size-node)]
            (if (or (< ti 0) (< si 0))
              -1
              (begin
                (svec.push
                  ops
                  (embedded-native-op-open
                    0
                    180
                    (string.int->string ti)
                    "0"
                    "0"))
                (svec.push
                  ops
                  (embedded-native-op-open
                    1
                    180
                    (string.int->string si)
                    "0"
                    "0"))
                (svec.push ops (embedded-native-op-open 2 185 "0" "0" "0"))
                3)))]
        [_ -1])]
    [_ -1]))

(define (embedded-native-binary-ops
  [params : AstMacroParamList]
  [target-node : i64]
  [operand-node : i64]
  [op : i64]
  [ops : (&mut ops svec.Vec)]) : i64
  (let
    [ti : i64 (embedded-stdlib-tlci-unquoted-param (& params) target-node)]
    [oi : i64 (embedded-stdlib-tlci-unquoted-param (& params) operand-node)]
    (if (or (< ti 0) (< oi 0))
      -1
      (begin
        (svec.push
          ops
          (embedded-native-op-open 0 180 (string.int->string ti) "0" "0"))
        (svec.push
          ops
          (embedded-native-op-open 1 180 (string.int->string oi) "0" "0"))
        (svec.push ops (embedded-native-op-open 2 op "0" "0" "0"))
        3))))

;; Full source for the native package: the host extern plus one entry function
;; per identity in catalog order.
;; A complete, balanced arm expression: the op lets, the status-sum return
;; (q99 is the enclosing fuel status), and one closing paren per op let.
(define (embedded-native-arm-block [ops : (& ops svec.Vec)] [opened : i64]) : String
  (let
    [out : String ""]
    [index : i64 0]
    (begin
      (while (< index (svec.len ops))
        (begin
          (set! out (str-cat out (svec.get ops index "")))
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
  [params : AstMacroParamList]
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
              [ops : svec.Vec (svec.new)]
              [opened : i64
                (embedded-native-body-ops params body-node (&mut ops))]
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
                  "  (if (= t"
                  (string.int->string index)
                  " 1)\n"
                  (if (< opened 0)
                    "  0\n"
                    (embedded-native-arm-block (& ops) opened))
                  "\n"
                  rest
                  "))\n")))]
          [_ "  0\n"])])))

(define (embedded-native-match-body
  [params : AstMacroParamList]
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
                          (& params)
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

(define (embedded-native-source [names : (Array String)]) : String
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
            (embedded-stdlib-tlci-capture-slot (array-ref names index))]
          [ops : svec.Vec (svec.new)]
          [match-text : String
            (if (>= slot 0)
              (embedded-native-match-body
                (array-ref embedded-stdlib-tlci-capture-params slot)
                (array-ref embedded-stdlib-tlci-capture-bodies slot))
              "")]
          [opened : i64
            (if (and (>= slot 0) (string.eq match-text ""))
              (embedded-native-body-ops
                (array-ref embedded-stdlib-tlci-capture-params slot)
                (array-ref embedded-stdlib-tlci-capture-bodies slot)
                (&mut ops))
              -1)]
          (begin
            (set!
              out
              (str-cat
                out
                "(define (macro-entry-"
                (string.int->string index)
                " [image-ctx : i64] [host : i64] [session : i64]"
                " [operands : i64] [count : i64] [result : i64]) : i64\n"))
            (if (and (string.eq match-text "") (< opened 0))
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
                    (if (string.eq match-text "")
                      (embedded-native-arm-block (& ops) opened)
                      match-text)
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