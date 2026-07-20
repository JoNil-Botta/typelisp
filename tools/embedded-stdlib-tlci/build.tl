;; Build the host-native stdlib comptime image catalog from the exact embedded
;; source manifest. Macro bodies remain on the interpreted path until general
;; source-to-native comptime lowering lands; the registered identities and
;; loader/container path are production-shaped build inputs now.
(import "../../src/compiler_parse_core.tl")
(import "../../src/tlci_core.tl")
(import "../../src/compiler_backend.tl")
(import "../../src/compiler_tlci_native_image.tl")
(import compiler_builtin_ids as cbi)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector String) as svec)

(define embedded-stdlib-tlci-build-error : String
  "")
(define embedded-stdlib-tlci-source-hash : i64
  7)

(define (embedded-stdlib-tlci-hash-text! [text : String]) : unit
  (let
    [index : i64 0]
    [length : i64 (string.string-length text)]
    (while (< index length)
      (begin
        (set!
          embedded-stdlib-tlci-source-hash
          (%
            (+
              (* embedded-stdlib-tlci-source-hash 131)
              (cast (string.string-ref text index) : i64))
            2147483647))
        (set! index (+ index 1))))))

(define (embedded-stdlib-tlci-line-end [text : String] [start : i64]) : i64
  (let
    [index : i64 start]
    [length : i64 (string.string-length text)]
    (begin
      (while (and (< index length) (!= (string.string-ref text index) '\n'))
        (set! index (+ index 1)))
      index)))

(define (embedded-stdlib-tlci-trim-cr [line : String]) : String
  (let
    [length : i64 (string.string-length line)]
    (if (and (> length 0) (= (string.string-ref line (- length 1)) '\r'))
      (string.substring line 0 (- length 1))
      line)))

(define (embedded-stdlib-tlci-module-name [suffix : String]) : String
  (let
    [length : i64 (string.string-length suffix)]
    (if (and
      (> length 3)
      (= (string.string-ref suffix (- length 3)) '.')
      (= (string.string-ref suffix (- length 2)) 't')
      (= (string.string-ref suffix (- length 1)) 'l'))
      (str-cat "stdlib." (string.substring suffix 0 (- length 3)))
      "")))

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

(define (embedded-stdlib-tlci-push-name!
  [names : (&mut names svec.Vec)]
  [module : String]
  [name-id : i64]) : unit
  (let
    [name : String
      (if (= (string.string-length module) 0)
        (intern-str name-id)
        (str-cat module "/" (intern-str name-id)))]
    [index : i64 0]
    [duplicate : bool false]
    (begin
      (while (and (not duplicate) (< index (svec.len names)))
        (if (string.eq (svec.get names index "") name)
          (set! duplicate true)
          (set! index (+ index 1))))
      (if duplicate
        (set!
          embedded-stdlib-tlci-build-error
          (str-cat "duplicate stdlib macro identity: " name))
        (svec.push names name)))))

(define (embedded-stdlib-tlci-collect-decl!
  [decl : AstDecl]
  [module : String]
  [names : (&mut names svec.Vec)]) : unit
  (match decl
    [(AstDecl.DefMacro decl-meta name params _ body)
      (begin
        (embedded-stdlib-tlci-push-name! names module name)
        (let
          [slot : i64 (array-ref embedded-stdlib-tlci-capture-count 0)]
          (when
            (< slot embedded-stdlib-tlci-capture-cap)
            (array-set!
              embedded-stdlib-tlci-capture-identities
              slot
              (embedded-stdlib-tlci-identity module name))
            (array-set! embedded-stdlib-tlci-capture-params slot params)
            (array-set! embedded-stdlib-tlci-capture-bodies slot body)
            (array-set! embedded-stdlib-tlci-capture-count 0 (+ slot 1)))))]
    [(AstDecl.Unsafe inner)
      (embedded-stdlib-tlci-collect-decl! (box-get inner) module names)]
    [(AstDecl.ModuleBody nested body)
      (embedded-stdlib-tlci-collect-decls!
        (box-get body)
        (intern-str nested)
        names)]
    [_ unit]))

(define (embedded-stdlib-tlci-collect-decls!
  [decls : AstDeclList]
  [module : String]
  [names : (&mut names svec.Vec)]) : unit
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) unit]
    [(AstDeclListStep.Cons decl rest)
      (match decl
        [(AstDecl.Module next-module)
          (embedded-stdlib-tlci-collect-decls!
            rest
            (intern-str next-module)
            names)]
        [_
          (begin
            (embedded-stdlib-tlci-collect-decl! decl module names)
            (embedded-stdlib-tlci-collect-decls! rest module names))])]))

(define (embedded-stdlib-tlci-collect-file!
  [root : String]
  [suffix : String]
  [names : (&mut names svec.Vec)]) : unit
  (let
    [module : String (embedded-stdlib-tlci-module-name suffix)]
    [path : String (str-cat root "/" suffix)]
    [source : String (io.read-file path)]
    (if (= (string.string-length module) 0)
      (set!
        embedded-stdlib-tlci-build-error
        (str-cat "invalid embedded stdlib module suffix: " suffix))
      (begin
        (embedded-stdlib-tlci-hash-text! suffix)
        (embedded-stdlib-tlci-hash-text! source)
        (match (parse-ast-source source)
          [(ResultAstProgram.Err message)
            (set!
              embedded-stdlib-tlci-build-error
              (str-cat "cannot parse " path ": " message))]
          [(ResultAstProgram.Ok program)
            (match program
              [(AstProgram.Program decls)
                (embedded-stdlib-tlci-collect-decls!
                  (box-get decls)
                  module
                  names)])])))))

(define (embedded-stdlib-tlci-collect-manifest!
  [manifest : String]
  [root : String]
  [start : i64]
  [names : (&mut names svec.Vec)]) : unit
  (when
    (and
      (= (string.string-length embedded-stdlib-tlci-build-error) 0)
      (< start (string.string-length manifest)))
    (let
      [end : i64 (embedded-stdlib-tlci-line-end manifest start)]
      [line : String
        (embedded-stdlib-tlci-trim-cr
          (string.substring manifest start (- end start)))]
      [next : i64
        (if (< end (string.string-length manifest))
          (+ end 1)
          end)]
      (begin
        (when
          (> (string.string-length line) 0)
          (embedded-stdlib-tlci-collect-file! root line names))
        (embedded-stdlib-tlci-collect-manifest! manifest root next names)))))

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
  [image : CompilerObjectImage]
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

(define (embedded-native-write
  [output : String]
  [build-hash : String]
  [windows-target : bool]
  [names : (Array String)]) : i64
  (let
    [source : String (embedded-native-source names)]
    [target : CompilerBackendTarget
      (if windows-target
        (CompilerBackendTarget.Windows)
        (CompilerBackendTarget.Linux))]
    (begin
      (io.write-file (str-cat output ".source.tl") source)
      unit)
    (match (compiler-backend-lower-source-for-target source target)
      [(ResultCompilerLower.Err diag)
        (begin
          (io.print-error
            (str-cat
              "embedded stdlib tlci: generated source rejected: "
              (compiler-diagnostic-render (box-get diag))
              "\n"))
          1)]
      [(ResultCompilerLower.Ok program spans)
        (match (compiler-backend-emit-program-object-image-target-with-mode-and-crt
          program
          target
          (CompilerBackendMode.Scalar)
          spans
          false
          false)
          [(ResultCompilerBackendObject.Err diag)
            (begin
              (io.print-error
                (str-cat
                  "embedded stdlib tlci: object emission failed: "
                  (compiler-diagnostic-render (box-get diag))
                  "\n"))
              1)]
          [(ResultCompilerBackendObject.Ok image)
            (match (compiler-tlci-native-layout-image image)
              [(ResultCompilerTlciNativeLayout.Err message)
                (begin
                  (io.print-error
                    (str-cat "embedded stdlib tlci: " message "\n"))
                  1)]
              [(ResultCompilerTlciNativeLayout.Ok layout)
                (let
                  [entry-offsets : (Array i64)
                    (embedded-native-entry-offsets image (array-length names))]
                  (if (not
                    (= (array-length entry-offsets) (array-length names)))
                    (begin
                      (io.print-error
                        (str-cat
                          "embedded stdlib tlci: entry count "
                          (string.int->string (array-length entry-offsets))
                          " does not match catalog count "
                          (string.int->string (array-length names))
                          "
"))
                      1)
                    (match (compiler-tlci-native-emit-imports (& layout))
                      [(ResultCompilerTlciNativeImports.Err message)
                        (begin
                          (io.print-error
                            (str-cat "embedded stdlib tlci: " message "\n"))
                          1)]
                      [(ResultCompilerTlciNativeImports.Ok imports)
                        (match (tlci-emit-native-package-image
                          (tlci-make-metadata "v1" "stdlib" "0.1.0")
                          build-hash
                          (TlciNativePackageInput
                            (struct-get layout bytes)
                            imports
                            (struct-get layout fixup-offsets)
                            (struct-get layout fixup-count)
                            names
                            entry-offsets
                            (array-length names)))
                          [(ResultTlciBytes.Err message)
                            (begin
                              (io.print-error
                                (str-cat "embedded stdlib tlci: " message "\n"))
                              1)]
                          [(ResultTlciBytes.Ok bytes)
                            (begin
                              (io.write-file
                                output
                                (tlci-bytes->string
                                  bytes
                                  0
                                  (array-length bytes)))
                              (io.print-string
                                (str-cat
                                  "embedded stdlib tlci: wrote "
                                  (string.int->string (array-length bytes))
                                  " bytes for "
                                  (string.int->string (array-length names))
                                  " macro entries ("
                                  (string.int->string
                                    (array-ref
                                      embedded-stdlib-tlci-native-report-count
                                      0))
                                  " native)\n"))
                              0)])])))])])])))

(define (main) : i64
  (if (not (= (io.arg-count) 6))
    (begin
      (io.print-error
        "usage: build <module-manifest> <stdlib-root> <output.tlci> <linux|windows> <build-hash>\n")
      2)
    (let
      [manifest-path : String (io.arg 1)]
      [root : String (io.arg 2)]
      [output : String (io.arg 3)]
      [target : String (io.arg 4)]
      [build-hash : String (io.arg 5)]
      [names : svec.Vec (svec.new)]
      (begin
        (if (or (string.eq target "linux") (string.eq target "windows"))
          (embedded-stdlib-tlci-collect-manifest!
            (io.read-file manifest-path)
            root
            0
            (&mut names))
          (set!
            embedded-stdlib-tlci-build-error
            (str-cat "invalid host target: " target)))
        (if (> (string.string-length embedded-stdlib-tlci-build-error) 0)
          (begin
            (io.print-error
              (str-cat
                "embedded stdlib tlci: "
                embedded-stdlib-tlci-build-error
                "\n"))
            1)
          (embedded-native-write
            output
            (str-cat
              build-hash
              "-stdlib-"
              (string.int->string embedded-stdlib-tlci-source-hash))
            (string.eq target "windows")
            (svec.to-array (& names))))))))