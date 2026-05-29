;; compiler_typecheck.tl - First scalar typechecker pass over compiler AstProgram (#426).
(import "compiler_typecheck_core.tl")

(import "compiler_specialize.tl")

(define (typecheck-compiler-program-with-paths
  [program : AstProgram]
  [paths : AstDeclPathList]) : ResultCompilerTypecheck
  (let
    [specialized-paths : AstDeclPathList
      (if (compiler-specialize-needed? program)
        AstDeclPathNil
        paths)]
    (match (compiler-specialize-program program)
      [(OkSpecProgram specialized)
        (typecheck-compiler-specialized-program-with-paths
          specialized
          specialized-paths)]
      [(ErrSpecProgram diag) (ErrCompilerTypecheck diag)])))

(define (typecheck-compiler-program [program : AstProgram]) : ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths program AstDeclPathNil))

(define (typecheck-compiler-repl-expr [decls : AstDeclList] [expr : AstExpr]) : ResultTcType
  (let
    [program : AstProgram (AstProgram decls)]
    (match (build-compiler-symbols program)
      [(OkCompilerSymbols symbols)
        (match (build-compiler-registries program)
          [(OkCompilerRegistries registries)
            (let
              [ctx : TcContext (TcContext program symbols registries "")]
              (match (tc-program-source-types-policy-ok ctx program)
                [(OkTcUnit)
                  (match (tc-source-expr-policy-ok ctx expr)
                    [(OkTcUnit)
                      (match (tc-build-top-env ctx program)
                        [(OkTcEnv top-env)
                          (match (tc-check-decls
                            ctx
                            top-env
                            decls
                            (CompilerTypecheckSummary 0 0 0))
                            [(OkCompilerTypecheck _) (tc-expr ctx top-env expr)]
                            [(ErrCompilerTypecheck diag)
                              (ErrTcType (compiler-diagnostic-message diag))])]
                        [(ErrTcEnv message) (ErrTcType message)])]
                    [(ErrTcUnit message) (ErrTcType message)])]
                [(ErrTcUnit message) (ErrTcType message)]))]
          [(ErrCompilerRegistries message) (ErrTcType message)])]
      [(ErrCompilerSymbols message) (ErrTcType message)])))

(define (typecheck-compiler-source [src : String]) : ResultCompilerTypecheck
  (match (parse-ast-source src)
    [(OkAstProgram program) (typecheck-compiler-program program)]
    [(ErrAstProgram message) (ErrCompilerTypecheck (tc-diag-at-start message))]))

(define (compiler-typecheck-smoke-source) : String
  "(extern print-i64 : (-> i64 unit))
(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main [flag : bool]) : i64
  (let
    [x : i64 (inc answer)]
    (begin
      (set! x (+ x 1))
      (if flag x 0))))")

(define (compiler-typecheck-summary-score [summary : CompilerTypecheckSummary]) : i64
  (match summary
    [(CompilerTypecheckSummary values functions externs)
      (+ values (+ (* functions 10) (* externs 100)))]))

(define (compiler-typecheck-error-ok? [src : String] [want : String]) : bool
  (match (typecheck-compiler-source src)
    [(ErrCompilerTypecheck diag)
      (string-eq (compiler-diagnostic-message diag) want)]
    [(OkCompilerTypecheck _) false]))

(define (compiler-typecheck-ok-score? [src : String] [want : i64]) : bool
  (match (typecheck-compiler-source src)
    [(OkCompilerTypecheck summary)
      (= (compiler-typecheck-summary-score summary) want)]
    [(ErrCompilerTypecheck _) false]))

(define (compiler-typecheck-ok? [src : String]) : bool
  (match (typecheck-compiler-source src)
    [(OkCompilerTypecheck _) true]
    [(ErrCompilerTypecheck _) false]))

(define (compiler-typecheck-unbound-source) : String
  "(define (main) : i64 missing)")

(define (compiler-typecheck-bad-call-source) : String
  "(define (id [x : i64]) : i64 x)
(define (main) : i64 (id true))")

(define (compiler-typecheck-branch-mismatch-source) : String
  "(define (main [flag : bool]) : i64
  (if flag 1 false))")

(define (compiler-typecheck-type-parameter-source) : String
  "(define (id [x : T]) : T x)")

(define (compiler-typecheck-aggregate-source) : String
  "(define (id-lambda [n : i64]) : i64
  (let
    [f : (-> i64 i64) (lambda ([x : i64]) : i64 (+ x 1))]
    (f n)))
(define (main [n : i64] [s : String]) : i64
  (let
    [fixed : (Array i64 3) (array 1 2 3)]
    [t : (Tuple i64 bool) (tuple 7 true)]
    [a : (Array i64) (make-array i64 n)]
    (begin
      (array-set! a 0 (cast (string-ref s 0) : i64))
      (foreach ([i : i64 0 n])
        (array-set! a i (+ (array-ref a i) 1)))
      (+ (array-length a)
         (+ (tuple-ref t 0) (+ (array-ref fixed 1) (id-lambda 3)))))))")

(define (compiler-typecheck-builtin-source) : String
  "(define (main [s : String]) : String
  (begin
    (fs-mkdir-status s)
    (fs-remove-file-status s)
    (fs-remove-dir-status s)
    (fs-process-id)
    (string-append (substring s 0 (length s))
                   (int->string (string->int \"7\")))))")

(define (compiler-typecheck-stdio-source) : String
  "(define (main) : i64
  (begin
    (flush-stdout)
    (if (stdin-eof?)
        (string-length (read-stdin-line))
        (string-length (read-stdin-bytes 3)))))")

(define (compiler-typecheck-env-source) : String
  "(define (main [name : String]) : String
  (if (env-var-exists? name)
    (env-var-value name)
    (env-path-separator)))")

(define (compiler-typecheck-tuple-oob-source) : String
  "(define (main) : i64 (tuple-ref (tuple 1 true) 2))")

(define (compiler-typecheck-array-mismatch-source) : String
  "(define bad : (Array i64 2) (array 1 true))")

(define (compiler-typecheck-string-index-source) : String
  "(define (main) : char (string-ref \"hi\" true))")

(define (compiler-typecheck-string-shadow-source) : String
  "(define (string-ref [a : i64] [b : i64]) : i64 (+ a b))
(define (char-at [a : i64] [b : i64]) : i64 (* a b))
(define (main) : i64 (+ (string-ref 10 7) (char-at 3 4)))")

(define (compiler-typecheck-char-range-source) : String
  "(define (is-digit [c : char]) : bool
  (and (>= c #0') (<= c #9')))
(define (main [c : char]) : bool (is-digit c))")

(define (compiler-typecheck-never-branch-source) : String
  "(define (main [flag : bool]) : i64
  (if flag 42 (panic \"stop\")))")

(define (compiler-typecheck-cast-bad-source) : String
  "(define (main) : i64 (cast true : i64))")

(define (compiler-typecheck-foreach-body-source) : String
  "(define (main [n : i64]) : unit
  (foreach ([i : i64 0 n]) i))")

(define (compiler-typecheck-lambda-ret-source) : String
  "(define (main) : (-> i64 i64)
  (lambda ([x : i64]) : i64 true))")

(define (compiler-typecheck-foreach-spmd-ok-source) : String
  "(define (main [n : i64]) : unit
  (let
    [a : (Array i64) (make-array i64 n)]
    [b : (Array i64) (make-array i64 n)]
    [out : (Array i64) (make-array i64 n)]
    (foreach ([i : i64 0 n])
      (let
        [sum : i64 (+ (array-ref a i) (array-ref b i))]
        (array-set! out i sum)))))")

(define (compiler-typecheck-foreach-varying-if-source) : String
  "(define (main [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (if (= (array-ref xs i) 0) unit unit)))")

(define (compiler-typecheck-foreach-varying-while-source) : String
  "(define (main [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (while (< (array-ref xs i) 0) unit)))")

(define (compiler-typecheck-foreach-varying-call-source) : String
  "(define (sink [x : i64]) : unit unit)
(define (main [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (sink (array-ref xs i))))")

(define (compiler-typecheck-foreach-outer-set-source) : String
  "(define (main [xs : (Array i64)] [n : i64]) : i64
  (let
    [sum : i64 0]
    (begin
      (foreach ([i : i64 0 n])
        (set! sum (+ sum (array-ref xs i))))
      sum)))")

(define (compiler-typecheck-foreach-unsupported-lane-source) : String
  "(define (main [ss : (Array String)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [s : String (array-ref ss i)]
      unit)))")

(define (compiler-typecheck-foreach-if-local-set-source) : String
  "(define (sink [x : i64]) : unit unit)
(define (main [xs : (Array i64)] [flag : bool] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [x : i64 0]
      (begin
        (if flag (set! x (array-ref xs i)) unit)
        (sink x)))))")

(define (compiler-typecheck-foreach-while-local-set-source) : String
  "(define (sink [x : i64]) : unit unit)
(define (main [xs : (Array i64)] [flag : bool] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [x : i64 0]
      (begin
        (while flag (set! x (array-ref xs i)))
        (sink x)))))")

(define (compiler-typecheck-foreach-match-local-set-source) : String
  "(defenum Maybe (None) (Some i64))
(define (sink [x : i64]) : unit unit)
(define (main [m : Maybe] [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [x : i64 0]
      (begin
        (match m [(Some v) (set! x (array-ref xs i))] [None unit])
        (sink x)))))")

(define (compiler-typecheck-foreach-local-set-ok-source) : String
  "(define (sink [x : i64]) : unit unit)
(define (main [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [x : i64 0]
      (begin
        (set! x 1)
        (sink x)))))")

(define (compiler-typecheck-foreach-control-flow-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-foreach-local-set-ok-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-foreach-if-local-set-source)
        "typecheck: foreach calls with varying arguments are not supported")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-foreach-while-local-set-source)
          "typecheck: foreach calls with varying arguments are not supported")
        (compiler-typecheck-error-ok?
          (compiler-typecheck-foreach-match-local-set-source)
          "typecheck: foreach calls with varying arguments are not supported")))))

(define (compiler-typecheck-foreach-spmd-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-foreach-spmd-ok-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-foreach-varying-if-source)
        "typecheck: foreach if condition must be uniform")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-foreach-varying-while-source)
          "typecheck: foreach while condition must be uniform")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-foreach-varying-call-source)
            "typecheck: foreach calls with varying arguments are not supported")
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-foreach-outer-set-source)
              "typecheck: foreach cannot set binding declared outside foreach")
            (and
              (compiler-typecheck-error-ok?
                (compiler-typecheck-foreach-unsupported-lane-source)
                "typecheck: foreach varying array lane type is not supported: String")
              (compiler-typecheck-foreach-control-flow-tests-ok?))))))))

(define (compiler-typecheck-abstraction-policy-tests-ok?) : bool
  (compiler-typecheck-error-ok?
    (compiler-typecheck-type-parameter-source)
    (tc-source-type-policy-message "T")))

(define (compiler-typecheck-aggregate-tests-ok?) : bool
  (and
    (compiler-typecheck-ok-score? (compiler-typecheck-aggregate-source) 20)
    (and
      (compiler-typecheck-ok-score? (compiler-typecheck-builtin-source) 10)
      (and
        (compiler-typecheck-ok-score? (compiler-typecheck-stdio-source) 10)
        (and
          (compiler-typecheck-ok-score? (compiler-typecheck-env-source) 10)
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-tuple-oob-source)
              "typecheck: tuple index out of bounds")
            (and
              (compiler-typecheck-error-ok?
                (compiler-typecheck-array-mismatch-source)
                "typecheck: array elements must have same type")
              (and
                (compiler-typecheck-error-ok?
                  (compiler-typecheck-string-index-source)
                  "typecheck: string index must be integer")
                (and
                  (compiler-typecheck-ok-score?
                    (compiler-typecheck-string-shadow-source)
                    30)
                  (and
                    (compiler-typecheck-error-ok?
                      (compiler-typecheck-cast-bad-source)
                      "typecheck: cast requires integer/char source and target")
                    (and
                      (compiler-typecheck-ok-score?
                        (compiler-typecheck-char-range-source)
                        20)
                      (and
                        (compiler-typecheck-ok-score?
                          (compiler-typecheck-never-branch-source)
                          10)
                        (and
                          (compiler-typecheck-error-ok?
                            (compiler-typecheck-foreach-body-source)
                            "typecheck: foreach body must be unit")
                          (compiler-typecheck-error-ok?
                            (compiler-typecheck-lambda-ret-source)
                            "typecheck: lambda return type mismatch"))))))))))))))

(define (compiler-typecheck-nominal-source) : String
  "(defenum Maybe (None) (Some i64))
(defstruct Point (x i64) (y i64))
(define (from-maybe [m : Maybe]) : i64
  (match m [(Some v) v] [None 0]))
(define (main) : i64
  (let
    [p : Point (Point 40 2)]
    (+ (struct-get p x) (from-maybe (Some (struct-get p y))))))")

(define (compiler-typecheck-comptime-decl-source) : String
  "(comptime-decl (defstruct Point (x i64) (y i64)))
(comptime-decl (defenum Maybe (None) (Some i64)))
(define (main) : i64
  (let
    [p : Point (Point 40 2)]
    (match (Some (struct-get p y))
      [(Some n) (+ (struct-get p x) n)]
      [None 0])))")

(define (compiler-typecheck-match-mismatch-source) : String
  "(defenum Maybe (None) (Some i64))
(define (main [m : Maybe]) : i64
  (match m [(Some v) v] [None false]))")

(define (compiler-typecheck-unknown-variant-source) : String
  "(defenum Maybe (None) (Some i64))
(define (main [m : Maybe]) : i64
  (match m [(Other) 1] [_ 0]))")

(define (compiler-typecheck-unknown-field-source) : String
  "(defstruct Point (x i64) (y i64))
(define (main [p : Point]) : i64
  (struct-get p z))")

(define (compiler-typecheck-duplicate-variant-source) : String
  "(defenum Left (Same))
(defenum Right (Same))
(define (main) : i64 0)")

(define (compiler-typecheck-module-qualified-source) : String
  "(module left)
(define same : i64 20)
(define (get) : i64 same)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module right)
(define same : i64 22)
(define (get) : i64 same)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module main)
(define (main) : i64
  (+
    (left/get)
    (+
      (right/get)
      (+
        (let ([p : right/Point (right/Point 7)])
          (struct-get p x))
        (match (right/Some 1)
          [(right/Some v) v]
          [right/None 0])))))")

(define (compiler-typecheck-module-unqualified-import-source) : String
  "(module left)
(define (get) : i64 20)
(module main)
(define (main) : i64 (get))")

(define (compiler-typecheck-repr-c-layout-source) : String
  "(defstruct Packet
  (:repr c)
  (tag u8)
  (count i64)
  (flag bool))
(defstruct Inner
  (:repr c)
  (a u8)
  (b i32))
(defstruct Outer
  (:repr c)
  (tag u8)
  (inner Inner)
  (tail u16))")

(define (compiler-typecheck-repr-c-layout-ok?) : bool
  (match (parse-ast-source (compiler-typecheck-repr-c-layout-source))
    [(OkAstProgram program)
      (match (build-compiler-symbols program)
        [(OkCompilerSymbols symbols)
          (match (build-compiler-registries program)
            [(OkCompilerRegistries registries)
              (let
                [ctx : TcContext (TcContext program symbols registries "")]
                (match (tc-repr-c-struct-layout ctx "Packet")
                  [(OkTcReprCLayout packet)
                    (match (tc-repr-c-struct-layout ctx "Outer")
                      [(OkTcReprCLayout outer)
                        (and
                          (= (tc-repr-c-layout-size packet) 24)
                          (and
                            (= (tc-repr-c-layout-align packet) 8)
                            (and
                              (=
                                (tc-repr-c-layout-field-offset
                                  (tc-repr-c-layout-fields packet)
                                  "tag")
                                0)
                              (and
                                (=
                                  (tc-repr-c-layout-field-offset
                                    (tc-repr-c-layout-fields packet)
                                    "count")
                                  8)
                                (and
                                  (=
                                    (tc-repr-c-layout-field-offset
                                      (tc-repr-c-layout-fields packet)
                                      "flag")
                                    16)
                                  (and
                                    (= (tc-repr-c-layout-size outer) 16)
                                    (and
                                      (= (tc-repr-c-layout-align outer) 4)
                                      (and
                                        (=
                                          (tc-repr-c-layout-field-offset
                                            (tc-repr-c-layout-fields outer)
                                            "inner")
                                          4)
                                        (=
                                          (tc-repr-c-layout-field-offset
                                            (tc-repr-c-layout-fields outer)
                                            "tail")
                                          12)))))))))]
                      [(ErrTcReprCLayout _) false])]
                  [(ErrTcReprCLayout _) false]))]
            [(ErrCompilerRegistries _) false])]
        [(ErrCompilerSymbols _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-typecheck-repr-c-string-source) : String
  "(defstruct Bad
  (:repr c)
  (s String))")

(define (compiler-typecheck-repr-c-default-nested-source) : String
  "(defstruct Inner (x i64))
(defstruct Bad
  (:repr c)
  (inner Inner))")

(define (compiler-typecheck-repr-c-recursive-source) : String
  "(defstruct Node
  (:repr c)
  (next Node))")

(define (compiler-typecheck-repr-c-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-repr-c-layout-source))
    (and
      (compiler-typecheck-repr-c-layout-ok?)
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-repr-c-string-source)
          "typecheck: repr c struct Bad field s has unsupported field type String")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-repr-c-default-nested-source)
            "typecheck: repr c struct Bad field inner references default-layout struct Inner")
          (compiler-typecheck-error-ok?
            (compiler-typecheck-repr-c-recursive-source)
            "typecheck: recursive repr c struct layout cycle involving Node"))))))

(define (compiler-typecheck-nominal-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-nominal-source))
    (and
      (compiler-typecheck-ok? (compiler-typecheck-comptime-decl-source))
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-match-mismatch-source)
          "typecheck: match arms must agree")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-unknown-variant-source)
            "typecheck: unknown variant Other")
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-unknown-field-source)
              "typecheck: unknown struct field Point.z")
            (and
              (compiler-typecheck-error-ok?
                (compiler-typecheck-duplicate-variant-source)
                "symbols: duplicate enum variant Same")
              (and
                (compiler-typecheck-ok?
                  (compiler-typecheck-module-qualified-source))
                (and
                  (compiler-typecheck-error-ok?
                    (compiler-typecheck-module-unqualified-import-source)
                    "typecheck: unbound name get")
                  (compiler-typecheck-repr-c-tests-ok?))))))))))

(define (compiler-typecheck-region-builtin-source) : String
  "(define (main) : i64
  (with-arena r
    (let
      [s : String (int->string 41)]
      (string-length s))))")

(define (compiler-typecheck-region-escape-source) : String
  "(define (main) : String
  (with-arena r (int->string 41)))")

(define (compiler-typecheck-region-user-call-source) : String
  "(define (sink [s : String]) : i64 (string-length s))
(define (main) : i64
  (with-arena r
    (let
      [s : String (int->string 41)]
      (sink s))))")

(define (compiler-typecheck-region-nested-escape-source) : String
  "(define (main) : i64
  (with-arena outer
    (let
      [s : String (with-arena inner (int->string 1))]
      0)))")

(define (compiler-typecheck-region-outer-in-inner-source) : String
  "(define (main) : i64
  (with-arena outer
    (let
      [s : String (int->string 1)]
      (with-arena inner (string-length s)))))")

(define (compiler-typecheck-region-array-source) : String
  "(define (main [n : i64]) : i64
  (with-arena r
    (let
      [a : (Array i64) (make-array i64 n)]
      (begin
        (array-set! a 0 7)
        (array-length a)))))")

(define (compiler-typecheck-region-struct-escape-source) : String
  "(defstruct Box (s String))
(define (main) : String
  (with-arena r
    (let
      [b : Box (Box (int->string 1))]
      (struct-get b s))))")

(define (compiler-typecheck-region-match-source) : String
  "(defenum Token (Text String) (End))
(define (main) : i64
  (with-arena r
    (match (Text (int->string 1))
      [(Text s) (string-length s)]
      [End 0])))")

(define (compiler-typecheck-region-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-region-builtin-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-region-escape-source)
        "typecheck: region-tagged value cannot escape with-arena 'r'")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-region-user-call-source)
          "typecheck: cannot pass region-tagged value to function parameter; region value would escape")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-region-nested-escape-source)
            "typecheck: region-tagged value cannot escape with-arena 'inner'")
          (and
            (compiler-typecheck-ok?
              (compiler-typecheck-region-outer-in-inner-source))
            (and
              (compiler-typecheck-ok? (compiler-typecheck-region-array-source))
              (and
                (compiler-typecheck-error-ok?
                  (compiler-typecheck-region-struct-escape-source)
                  "typecheck: region-tagged value cannot escape with-arena 'r'")
                (compiler-typecheck-ok?
                  (compiler-typecheck-region-match-source))))))))))

(define (compiler-typecheck-result-try-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (read [flag : bool]) : ResultI64
  (if flag (OkI64 41) (ErrI64 \"read failed\")))
(define (step [flag : bool]) : ResultI64
  (OkI64 (try (read flag))))
(define (main [a : bool] [b : bool]) : ResultI64
  (let ([x : i64 (try (step a))]
        [y : i64 0])
    (begin
      (set! y (try (read b)))
      (OkI64 (+ x y)))))")

(define (compiler-typecheck-result-try-non-result-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (main) : ResultI64
  (OkI64 (try 1)))")

(define (compiler-typecheck-result-try-non-result-return-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (read) : ResultI64 (OkI64 1))
(define (main) : i64
  (try (read)))")

(define (compiler-typecheck-result-try-incompatible-error-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(defenum OtherResult (OkOther i64) (ErrOther i64))
(define (read) : OtherResult (ErrOther 7))
(define (main) : ResultI64
  (OkI64 (try (read))))")

(define (compiler-typecheck-result-try-panic-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (main [flag : bool]) : ResultI64
  (if flag (panic \"stop\") (OkI64 1)))")

(define (compiler-typecheck-resource-with-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([a 1 close]
         [b (+ a 1) close])
    (+ a b)))")

(define (compiler-typecheck-resource-with-cleanup-mismatch-source) : String
  "(define (close [h : bool]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    h))")

(define (compiler-typecheck-resource-with-cleanup-return-source) : String
  "(define (close [h : i64]) : i64 h)
(define (main) : i64
  (with ([h 1 close])
    h))")

(define (compiler-typecheck-resource-with-cleanup-expression-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 (close h)])
    h))")

(define (compiler-typecheck-resource-with-nested-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([outer 1 close])
    (with ([inner (+ outer 1) close])
      (+ outer inner))))")

(define (compiler-typecheck-resource-with-let-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let ([copy h])
      copy)))")

(define (compiler-typecheck-resource-with-escape-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    h))")

(define (compiler-typecheck-resource-with-tuple-store-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let ([t : (Tuple i64 i64) (tuple h 2)])
      0)))")

(define (compiler-typecheck-resource-with-array-store-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let ([items : (Array i64 2) (array h 2)])
      0)))")

(define (compiler-typecheck-resource-with-struct-store-source) : String
  "(defstruct Box (value i64))
(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let ([box : Box (Box h)])
      0)))")

(define (compiler-typecheck-resource-with-enum-store-source) : String
  "(defenum Maybe (Some i64))
(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let ([m : Maybe (Some h)])
      0)))")

(define (compiler-typecheck-resource-with-lambda-capture-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    ((lambda () : i64 h))))")

(define (compiler-typecheck-resource-with-transfer-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close]
         [copy h close])
    copy))")

(define (compiler-typecheck-resource-with-assignment-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (let ([slot : i64 0])
    (with ([h 1 close])
      (set! slot h))))")

(define (compiler-typecheck-resource-with-shadow-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let ([h : i64 2])
      ((lambda () : i64 h)))))")

(define (compiler-typecheck-resource-with-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-resource-with-source))
    (and
      (compiler-typecheck-ok? (compiler-typecheck-resource-with-nested-source))
      (and
        (compiler-typecheck-ok?
          (compiler-typecheck-resource-with-shadow-source))
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-resource-with-cleanup-mismatch-source)
            "typecheck: with cleanup function type mismatch")
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-resource-with-cleanup-return-source)
              "typecheck: with cleanup function type mismatch")
            (and
              (compiler-typecheck-error-ok?
                (compiler-typecheck-resource-with-cleanup-expression-source)
                "typecheck: with cleanup must be a direct function name")
              (and
                (compiler-typecheck-error-ok?
                  (compiler-typecheck-resource-with-let-source)
                  "typecheck: ordinary let cannot own cleanup-required resource; use with")
                (and
                  (compiler-typecheck-error-ok?
                    (compiler-typecheck-resource-with-escape-source)
                    "typecheck: cleanup-required resource would escape with scope")
                  (and
                    (compiler-typecheck-error-ok?
                      (compiler-typecheck-resource-with-tuple-store-source)
                      "typecheck: cannot store cleanup-required resource in ordinary aggregate")
                    (and
                      (compiler-typecheck-error-ok?
                        (compiler-typecheck-resource-with-array-store-source)
                        "typecheck: cannot store cleanup-required resource in ordinary aggregate")
                      (and
                        (compiler-typecheck-error-ok?
                          (compiler-typecheck-resource-with-struct-store-source)
                          "typecheck: cannot store cleanup-required resource in ordinary aggregate")
                        (and
                          (compiler-typecheck-error-ok?
                            (compiler-typecheck-resource-with-enum-store-source)
                            "typecheck: cannot store cleanup-required resource in ordinary aggregate")
                          (and
                            (compiler-typecheck-error-ok?
                              (compiler-typecheck-resource-with-lambda-capture-source)
                              "typecheck: lambda cannot capture cleanup-required resource; resource value would escape")
                            (and
                              (compiler-typecheck-error-ok?
                                (compiler-typecheck-resource-with-transfer-source)
                                "typecheck: cleanup-required resource already has a cleanup owner")
                              (compiler-typecheck-error-ok?
                                (compiler-typecheck-resource-with-assignment-source)
                                "typecheck: cannot store cleanup-required resource in longer-lived binding"))))))))))))))))

(define (compiler-typecheck-result-try-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-result-try-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-result-try-non-result-source)
        "typecheck: try operand must be Result-like enum")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-result-try-non-result-return-source)
          "typecheck: try requires enclosing Result-like function")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-result-try-incompatible-error-source)
            "typecheck: try error type mismatch")
          (compiler-typecheck-ok? (compiler-typecheck-result-try-panic-source)))))))

(define (compiler-typecheck-move-kind-copyable-tests-ok?) : bool
  (and
    (tc-type-copyable? (AstTyI64))
    (and
      (tc-type-copyable? (AstTyI32))
      (and
        (tc-type-copyable? (AstTyF64))
        (and
          (tc-type-copyable? (AstTyF32))
          (and
            (tc-type-copyable? (AstTyBool))
            (and
              (tc-type-copyable? (AstTyChar))
              (and
                (tc-type-copyable? (AstTyUnit))
                (and
                  (tc-type-copyable? (AstTyNever))
                  (and
                    (tc-type-copyable? (AstTyFunc AstTypeNil (AstTyI64)))
                    (and
                      (tc-type-copyable?
                        (AstTyPtr (AstTyRegion "inner" (AstTyString))))
                      (and
                        (tc-type-copyable?
                          (AstTyMutPtr (AstTyDynArray (AstTyI64))))
                        (tc-type-copyable? (AstTyRef "r" (AstTyString)))))))))))))))

(define (compiler-typecheck-move-kind-move-only-tests-ok?) : bool
  (and
    (tc-type-move-only? (AstTyString))
    (and
      (tc-type-move-only? (AstTyDynArray (AstTyI64)))
      (and
        (tc-type-move-only? (AstTyArray (AstTyI64) 4))
        (and
          (tc-type-move-only?
            (AstTyTuple
              (AstTypeCons (AstTyI64) (AstTypeCons (AstTyBool) AstTypeNil))))
          (and
            (tc-type-move-only? (AstTyStruct "Box"))
            (and
              (tc-type-move-only? (AstTyEnum "ResultI64"))
              (and
                (tc-type-move-only? (AstTyMutRef "phase" (AstTyI64)))
                (tc-type-move-only?
                  (AstTyTuple
                    (AstTypeCons
                      (AstTyStruct "Box")
                      (AstTypeCons (AstTyDynArray (AstTyI64)) AstTypeNil))))))))))))

(define (compiler-typecheck-move-kind-region-tests-ok?) : bool
  (and
    (tc-type-copyable? (AstTyRegion "r" (AstTyI64)))
    (and
      (tc-type-copyable? (AstTyRegion "r" (AstTyRef "inner" (AstTyString))))
      (and
        (tc-type-move-only? (AstTyRegion "r" (AstTyString)))
        (and
          (tc-type-move-only?
            (AstTyRegion "r" (AstTyTuple (AstTypeCons (AstTyI64) AstTypeNil))))
          (tc-type-move-only?
            (AstTyRegion "r" (AstTyMutRef "phase" (AstTyI64)))))))))

(define (compiler-typecheck-move-kind-tests-ok?) : bool
  (and
    (compiler-typecheck-move-kind-copyable-tests-ok?)
    (and
      (compiler-typecheck-move-kind-move-only-tests-ok?)
      (compiler-typecheck-move-kind-region-tests-ok?))))

(define (compiler-typecheck-raw-pointer-source) : String
  "(extern raw-sink : (-> (Ptr i64) unit))
(extern raw-make : (-> (MutPtr (Ptr u8))))
(define (main [p : (Ptr i64)]) : unit
  (raw-sink p))")

(define (compiler-typecheck-raw-pointer-render-ok?) : bool
  (and
    (string-eq (tc-type-render (AstTyPtr (AstTyI64))) "(Ptr i64)")
    (and
      (string-eq
        (tc-type-render (AstTyMutPtr (AstTyPtr (AstTyU8))))
        "(MutPtr (Ptr u8))")
      (and
        (tc-type-eq (AstTyPtr (AstTyI64)) (AstTyPtr (AstTyI64)))
        (and
          (not (tc-type-eq (AstTyPtr (AstTyI64)) (AstTyMutPtr (AstTyI64))))
          (tc-type-eq
            (AstTyPtr (AstTyRegion "r" (AstTyI64)))
            (AstTyPtr (AstTyI64))))))))

(define (compiler-typecheck-raw-pointer-ops-source) : String
  "(extern raw-make : (-> (MutPtr i64)))
(define (main [n : u64]) : u64
  (unsafe
    (ptr-write! (raw-make) 41)
    (ptr-read (raw-make))
    (ptr->int (ptr-offset (ptr-cast (int->ptr n : (MutPtr i64)) : (Ptr i64)) 1))))")

(define (compiler-typecheck-raw-pointer-cast-source) : String
  "(define (main [n : u64]) : (Ptr u8)
  (unsafe (ptr-cast (int->ptr n : (MutPtr i64)) : (Ptr u8))))")

(define (compiler-typecheck-raw-pointer-safe-read-source) : String
  "(define (main [p : (Ptr i64)]) : i64 (ptr-read p))")

(define (compiler-typecheck-raw-pointer-safe-marker-shadow-source) : String
  "(define (main [p : (Ptr i64)]) : i64
  (let [__tl_unsafe_context : unit unit] (ptr-read p)))")

(define (compiler-typecheck-raw-pointer-write-const-source) : String
  "(define (main [p : (Ptr i64)]) : unit (unsafe (ptr-write! p 1)))")

(define (compiler-typecheck-raw-pointer-write-mismatch-source) : String
  "(define (main [p : (MutPtr i64)]) : unit (unsafe (ptr-write! p true)))")

(define (compiler-typecheck-raw-pointer-offset-bad-source) : String
  "(define (main [p : (Ptr i64)]) : (Ptr i64) (unsafe (ptr-offset p true)))")

(define (compiler-typecheck-raw-pointer-cast-bad-target-source) : String
  "(define (main [p : (Ptr i64)]) : i64 (unsafe (ptr-cast p : i64)))")

(define (compiler-typecheck-raw-pointer-int-to-ptr-bad-source) : String
  "(define (main [b : bool]) : (Ptr i64) (unsafe (int->ptr b : (Ptr i64))))")

(define (compiler-typecheck-raw-pointer-op-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-raw-pointer-ops-source))
    (and
      (compiler-typecheck-ok? (compiler-typecheck-raw-pointer-cast-source))
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-raw-pointer-safe-read-source)
          "typecheck: ptr-read requires unsafe context")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-raw-pointer-safe-marker-shadow-source)
            "typecheck: ptr-read requires unsafe context")
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-raw-pointer-write-const-source)
              "typecheck: ptr-write! requires a MutPtr pointer operand")
            (and
              (compiler-typecheck-error-ok?
                (compiler-typecheck-raw-pointer-write-mismatch-source)
                "typecheck: ptr-write! value type mismatch")
              (and
                (compiler-typecheck-error-ok?
                  (compiler-typecheck-raw-pointer-offset-bad-source)
                  "typecheck: ptr-offset requires an integer offset")
                (and
                  (compiler-typecheck-error-ok?
                    (compiler-typecheck-raw-pointer-cast-bad-target-source)
                    "typecheck: ptr-cast target must be a raw pointer type")
                  (compiler-typecheck-error-ok?
                    (compiler-typecheck-raw-pointer-int-to-ptr-bad-source)
                    "typecheck: int->ptr requires an integer operand"))))))))))

(define (compiler-typecheck-raw-pointer-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-raw-pointer-source))
    (compiler-typecheck-raw-pointer-render-ok?)))

(define (compiler-typecheck-extern-abi-source) : String
  "(defenum ResultI64 (OkI64 i64))
(defstruct Box (value i64))
(extern foreign-callback (:abi c) (:symbol \"foreign_callback\") : (-> (Ptr i64) (-> i64 i64) ResultI64))
(extern foreign-box (:abi c) (:symbol \"foreign_box\") : (-> Box unit))")

(define (compiler-typecheck-extern-abi-tuple-source) : String
  "(extern bad (:abi c) (:symbol \"bad_tuple\") : (-> (Tuple i64 i64) i64))")

(define (compiler-typecheck-extern-abi-array-source) : String
  "(extern bad (:abi c) (:symbol \"bad_array\") : (-> (Array i64 2) i64))")

(define (compiler-typecheck-extern-abi-f32-source) : String
  "(extern bad (:abi c) (:symbol \"bad_f32\") : (-> f32 i64))")

(define (compiler-typecheck-extern-abi-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-extern-abi-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-extern-abi-tuple-source)
        "typecheck: extern ABI c does not support parameter type (Tuple i64 i64)")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-extern-abi-array-source)
          "typecheck: extern ABI c does not support parameter type (Array i64 2)")
        (compiler-typecheck-error-ok?
          (compiler-typecheck-extern-abi-f32-source)
          "typecheck: extern ABI c does not support parameter type f32")))))

(define (compiler-typecheck-reference-local-source) : String
  "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (let [r : (& n i64) (& n)]
    (take r)))")

(define (compiler-typecheck-reference-param-source) : String
  "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take (& n)))")

(define (compiler-typecheck-reference-projection-source) : String
  "(defstruct Pair (left i64) (right i64))
(define (take-pair [r : (& p i64)]) : unit unit)
(define (take-tuple [r : (& t i64)]) : unit unit)
(define (take-array [r : (& items i64)]) : unit unit)
(define (main [p : Pair] [t : (Tuple i64 bool)] [items : (Array i64)]) : unit
  (begin
    (take-pair (& (struct-get p left)))
    (take-tuple (& (tuple-ref t 0)))
    (take-array (& (array-ref items 0)))))")

(define (compiler-typecheck-reference-temp-source) : String
  "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take (& (+ n 1))))")

(define (compiler-typecheck-reference-mismatch-source) : String
  "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take (& other n)))")

(define (compiler-typecheck-reference-return-source) : String
  "(define (main [n : i64]) : (& n i64)
  (& n))")

(define (compiler-typecheck-reference-return-param-ref-source) : String
  "(define (id [r : (& n i64)]) : (& n i64) r)
(define (main [n : i64]) : (& n i64)
  (id (& n)))")

(define (compiler-typecheck-reference-return-untied-source) : String
  "(define (main [n : i64]) : (& other i64)
  (& n))")

(define (compiler-typecheck-reference-return-local-escape-source) : String
  "(define (main [n : i64]) : (& n i64)
  (let [x : i64 1] (& x)))")

(define (compiler-typecheck-reference-lambda-return-source) : String
  "(define (main [n : i64]) : i64
  (begin
    (lambda ([x : i64]) : (& x i64) (& x))
    n))")

(define (compiler-typecheck-reference-mut-source) : String
  "(define (main [n : (&mut phase i64)]) : unit unit)")

(define (compiler-typecheck-reference-str-source) : String
  "(define (take [s : (& text str)]) : unit unit)
(define (main [text : String]) : unit
  (let [view : (& text str) (& text)]
    (take view)))")

(define (compiler-typecheck-reference-str-region-source) : String
  "(define (take [s : (& r str)]) : unit unit)
(define (main) : unit
  (with-arena r
    (let [text : String (int->string 41)]
      (take (& r text)))))")

(define (compiler-typecheck-str-value-source) : String
  "(define (main [s : str]) : unit unit)")

(define (compiler-typecheck-str-return-source) : String
  "(define (main) : str \"x\")")

(define (compiler-typecheck-str-local-source) : String
  "(define (main) : unit (let [s : str \"x\"] unit))")

(define (compiler-typecheck-str-global-source) : String
  "(define bad : str \"x\")")

(define (compiler-typecheck-str-field-source) : String
  "(defstruct Bad (s str))")

(define (compiler-typecheck-str-variant-source) : String
  "(defenum Bad (S str))")

(define (compiler-typecheck-str-mut-ref-source) : String
  "(define (main [s : (&mut text str)]) : unit unit)")

(define (compiler-typecheck-reference-render-ok?) : bool
  (let
    [string-ref-render-ok : bool
      (string-eq (tc-type-render (AstTyRef "r" (AstTyString))) "(& r String)")]
    [str-ref-render-ok : bool
      (string-eq (tc-type-render (AstTyRef "r" (AstTyStr))) "(& r str)")]
    [mut-ref-render-ok : bool
      (string-eq
        (tc-type-render (AstTyMutRef "phase" (AstTyDynArray (AstTyI64))))
        "(&mut phase (Array i64))")]
    [str-eq-ok : bool (tc-type-eq (AstTyStr) (AstTyStr))]
    [str-distinct-ok : bool (not (tc-type-eq (AstTyStr) (AstTyString)))]
    [str-move-kind-ok : bool (tc-type-move-only? (AstTyStr))]
    [str-ref-move-kind-ok : bool (tc-type-copyable? (AstTyRef "r" (AstTyStr)))]
    [region-erased-eq-ok : bool
      (tc-type-eq
        (AstTyRef "r" (AstTyRegion "inner" (AstTyI64)))
        (AstTyRef "r" (AstTyI64)))]
    [region-distinct-ok : bool
      (not (tc-type-eq (AstTyRef "r" (AstTyI64)) (AstTyRef "s" (AstTyI64))))]
    [mut-distinct-ok : bool
      (not (tc-type-eq (AstTyRef "r" (AstTyI64)) (AstTyMutRef "r" (AstTyI64))))]
    [region-contains-ok : bool
      (tc-type-contains-region (AstTyRef "r" (AstTyI64)) "r")]
    [inner-region-contains-ok : bool
      (tc-type-contains-region
        (AstTyMutRef "phase" (AstTyRegion "inner" (AstTyString)))
        "inner")]
    (and
      string-ref-render-ok
      (and
        str-ref-render-ok
        (and
          mut-ref-render-ok
          (and
            str-eq-ok
            (and
              str-distinct-ok
              (and
                str-move-kind-ok
                (and
                  str-ref-move-kind-ok
                  (and
                    region-erased-eq-ok
                    (and
                      region-distinct-ok
                      (and
                        mut-distinct-ok
                        (and region-contains-ok inner-region-contains-ok)))))))))))))

(define (compiler-typecheck-reference-tests-ok?) : bool
  (let
    [render-ok : bool (compiler-typecheck-reference-render-ok?)]
    [local-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-local-source))]
    [param-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-param-source))]
    [projection-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-projection-source))]
    [str-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-str-source))]
    [str-region-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-str-region-source))]
    [temp-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-temp-source)
        "typecheck: borrow requires a local, parameter, or aggregate place")]
    [mismatch-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-mismatch-source)
        "typecheck: borrow lifetime mismatch")]
    [return-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-return-source))]
    [return-param-ref-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-reference-return-param-ref-source))]
    [return-untied-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-return-untied-source)
        "typecheck: returned reference lifetime must be tied to a parameter")]
    [return-local-escape-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-return-local-escape-source)
        "typecheck: reference value would escape lexical scope")]
    [lambda-return-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-lambda-return-source)
        "typecheck: returning references requires lifetime support (#804)")]
    [mut-ref-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-mut-source)
        "typecheck: mutable reference types require mutable borrow checker support (#806)")]
    [str-value-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-value-source)
        (tc-source-str-value-policy-message))]
    [str-return-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-return-source)
        (tc-source-str-value-policy-message))]
    [str-local-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-local-source)
        (tc-source-str-value-policy-message))]
    [str-global-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-global-source)
        (tc-source-str-value-policy-message))]
    [str-field-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-field-source)
        (tc-source-str-value-policy-message))]
    [str-variant-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-variant-source)
        (tc-source-str-value-policy-message))]
    [str-mut-ref-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-mut-ref-source)
        (tc-source-str-mut-ref-policy-message))]
    [ok : bool true]
    (begin
      (if render-ok
        unit
        (set! ok false))
      (if local-ok
        unit
        (set! ok false))
      (if param-ok
        unit
        (set! ok false))
      (if projection-ok
        unit
        (set! ok false))
      (if str-ok
        unit
        (set! ok false))
      (if str-region-ok
        unit
        (set! ok false))
      (if temp-error-ok
        unit
        (set! ok false))
      (if mismatch-error-ok
        unit
        (set! ok false))
      (if return-ok
        unit
        (set! ok false))
      (if return-param-ref-ok
        unit
        (set! ok false))
      (if return-untied-error-ok
        unit
        (set! ok false))
      (if return-local-escape-error-ok
        unit
        (set! ok false))
      (if lambda-return-error-ok
        unit
        (set! ok false))
      (if mut-ref-error-ok
        unit
        (set! ok false))
      (if str-value-error-ok
        unit
        (set! ok false))
      (if str-return-error-ok
        unit
        (set! ok false))
      (if str-local-error-ok
        unit
        (set! ok false))
      (if str-global-error-ok
        unit
        (set! ok false))
      (if str-field-error-ok
        unit
        (set! ok false))
      (if str-variant-error-ok
        unit
        (set! ok false))
      (if str-mut-ref-error-ok
        unit
        (set! ok false))
      ok)))

;; A type error whose offending expression (`missing`) is on source line 2, so
;; the diagnostic must locate it there (not at the 1:1 fallback) — proving the
;; typechecker carries the nearest declaration-body `AstExprSpanned` span (#681).
(define (compiler-typecheck-located-fn-source) : String
  "(define (main) : i64
  missing)")

(define (compiler-typecheck-located-value-source) : String
  "(define bad : i64
  missing)")

(define (compiler-typecheck-located-source-ok? [src : String]) : bool
  (match (typecheck-compiler-source src)
    [(ErrCompilerTypecheck diag)
      (if (= (compiler-diagnostic-line diag) 2)
        (if (> (compiler-diagnostic-col diag) 0)
          (string-eq
            (compiler-diagnostic-message diag)
            "typecheck: unbound name missing")
          false)
        false)]
    [(OkCompilerTypecheck _) false]))

(define (compiler-typecheck-located-ok?) : bool
  (and
    (compiler-typecheck-located-source-ok?
      (compiler-typecheck-located-fn-source))
    (compiler-typecheck-located-source-ok?
      (compiler-typecheck-located-value-source))))

;; Statement and control-flow type rules (#1042): if/while conditions, the
;; while-body unit rule, set!/let annotation mismatches, and `ann` mismatch,
;; plus an accepting program exercising the same forms. Migrated from
;; src/typechecker.rs unit coverage.
(define (compiler-typecheck-stmt-if-cond-source) : String
  "(define (main) : i64 (if 1 2 3))")

(define (compiler-typecheck-stmt-while-cond-source) : String
  "(define (main [n : i64]) : unit
  (let [i : i64 n] (while i (set! i (- i 1)))))")

(define (compiler-typecheck-stmt-while-body-source) : String
  "(define (main [n : i64]) : unit
  (let [i : i64 n] (while (> i 0) i)))")

(define (compiler-typecheck-stmt-set-mismatch-source) : String
  "(define (main) : i64
  (let [x : i64 0] (begin (set! x true) x)))")

(define (compiler-typecheck-stmt-let-mismatch-source) : String
  "(define (main) : i64 (let [x : i64 true] x))")

(define (compiler-typecheck-stmt-ann-mismatch-source) : String
  "(define (main) : i64 (ann true : i64))")

(define (compiler-typecheck-stmt-ok-while-source) : String
  "(define (main [n : i64]) : unit
  (let [i : i64 n] (while (> i 0) (set! i (- i 1)))))")

(define (compiler-typecheck-stmt-ok-if-set-source) : String
  "(define (main [flag : bool]) : i64
  (let [x : i64 0] (begin (set! x 5) (if flag x 0))))")

(define (compiler-typecheck-stmt-ok-cast-ann-source) : String
  "(define (main [c : char]) : i64 (ann (cast c : i64) : i64))")

(define (compiler-typecheck-statement-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (compiler-typecheck-stmt-if-cond-source)
      "typecheck: if condition must be bool")
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-stmt-while-cond-source)
        "typecheck: while condition must be bool")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-stmt-while-body-source)
          "typecheck: while body must be unit")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-stmt-set-mismatch-source)
            "typecheck: assignment type mismatch")
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-stmt-let-mismatch-source)
              "typecheck: let binding type mismatch")
            (and
              (compiler-typecheck-error-ok?
                (compiler-typecheck-stmt-ann-mismatch-source)
                "typecheck: annotation type mismatch")
              (and
                (compiler-typecheck-ok?
                  (compiler-typecheck-stmt-ok-while-source))
                (and
                  (compiler-typecheck-ok?
                    (compiler-typecheck-stmt-ok-if-set-source))
                  (compiler-typecheck-ok?
                    (compiler-typecheck-stmt-ok-cast-ann-source)))))))))))

;; Operator and call type rules (#1042): equality/comparison/integer operator
;; operand matching and call arity, plus accepting arithmetic/comparison/call
;; programs. Migrated from src/typechecker.rs unit coverage.
(define (compiler-typecheck-op-eq-mismatch-source) : String
  "(define (main) : bool (= 1 true))")

(define (compiler-typecheck-op-int-mismatch-source) : String
  "(define (main) : i64 (+ 1 true))")

(define (compiler-typecheck-op-cmp-mismatch-source) : String
  "(define (main) : bool (< 1 true))")

(define (compiler-typecheck-op-arity-many-source) : String
  "(define (f [x : i64]) : i64 x)
(define (main) : i64 (f 1 2))")

(define (compiler-typecheck-op-arity-few-source) : String
  "(define (f [x : i64] [y : i64]) : i64 (+ x y))
(define (main) : i64 (f 1))")

(define (compiler-typecheck-op-ok-arith-source) : String
  "(define (main) : i64 (+ (* 2 3) (- 10 4)))")

(define (compiler-typecheck-op-ok-cmp-eq-source) : String
  "(define (main) : bool (and (< 1 2) (= 3 3)))")

(define (compiler-typecheck-op-ok-call-source) : String
  "(define (add [a : i64] [b : i64]) : i64 (+ a b))
(define (main) : i64 (add 2 3))")

(define (compiler-typecheck-operator-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (compiler-typecheck-op-eq-mismatch-source)
      "typecheck: equality operands must match")
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-op-int-mismatch-source)
        "typecheck: integer operator expects matching integer operands")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-op-cmp-mismatch-source)
          "typecheck: comparison expects matching ordered scalar operands")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-op-arity-many-source)
            "typecheck: arity mismatch")
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-op-arity-few-source)
              "typecheck: arity mismatch")
            (and
              (compiler-typecheck-ok? (compiler-typecheck-op-ok-arith-source))
              (and
                (compiler-typecheck-ok?
                  (compiler-typecheck-op-ok-cmp-eq-source))
                (compiler-typecheck-ok? (compiler-typecheck-op-ok-call-source))))))))))

;; Match / pattern type rules (#1042): arm-type agreement and unknown-variant
;; rejection, plus accepting enum-payload, bool, and wildcard-on-scalar matches.
;; Migrated from src/typechecker.rs unit coverage.
(define (compiler-typecheck-match-arm-mismatch-source) : String
  "(defenum E (A) (B))
(define (main [e : E]) : i64 (match e [(A) 1] [(B) true]))")

(define (compiler-typecheck-match-unknown-variant-source) : String
  "(defenum E (A) (B))
(define (main [e : E]) : i64 (match e [(A) 1] [(C) 2]))")

(define (compiler-typecheck-match-ok-payload-source) : String
  "(defenum E (A i64) (B))
(define (main [e : E]) : i64 (match e [(A x) x] [(B) 0]))")

(define (compiler-typecheck-match-ok-bool-source) : String
  "(define (main [b : bool]) : i64 (match b [true 1] [false 0]))")

(define (compiler-typecheck-match-ok-wildcard-source) : String
  "(define (main) : i64 (match 1 [_ 0]))")

;; A diverging arm (panic : never) must unify with a value arm rather than
;; being reported as a disagreement; mirrors never-in-if branch handling.
(define (compiler-typecheck-match-ok-never-arm-source) : String
  "(defenum E (A) (B))
(define (main [e : E]) : i64 (match e [(A) 1] [(B) (panic \"no\")]))")

(define (compiler-typecheck-match-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (compiler-typecheck-match-arm-mismatch-source)
      "typecheck: match arms must agree")
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-match-unknown-variant-source)
        "typecheck: unknown variant C")
      (and
        (compiler-typecheck-ok? (compiler-typecheck-match-ok-payload-source))
        (and
          (compiler-typecheck-ok? (compiler-typecheck-match-ok-bool-source))
          (and
            (compiler-typecheck-ok?
              (compiler-typecheck-match-ok-wildcard-source))
            (compiler-typecheck-ok?
              (compiler-typecheck-match-ok-never-arm-source))))))))

(define (compiler-typecheck-string-builtin-ok-length-source) : String
  "(define (main) : i64 (string-length \"hi\"))")

(define (compiler-typecheck-string-builtin-ok-append-source) : String
  "(define (f) : String (string-append \"a\" \"b\"))")

(define (compiler-typecheck-string-builtin-ok-substring-source) : String
  "(define (f) : String (substring \"abc\" 0 1))")

(define (compiler-typecheck-string-builtin-ok-eq-source) : String
  "(define (f) : bool (string-eq \"a\" \"b\"))")

(define (compiler-typecheck-string-builtin-bad-arg-source) : String
  "(define (main) : i64 (string-length 5))")

(define (compiler-typecheck-string-builtin-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-string-builtin-ok-length-source))
    (and
      (compiler-typecheck-ok?
        (compiler-typecheck-string-builtin-ok-append-source))
      (and
        (compiler-typecheck-ok?
          (compiler-typecheck-string-builtin-ok-substring-source))
        (and
          (compiler-typecheck-ok?
            (compiler-typecheck-string-builtin-ok-eq-source))
          (compiler-typecheck-error-ok?
            (compiler-typecheck-string-builtin-bad-arg-source)
            "typecheck: argument type mismatch"))))))

;; Bootstrap argv builtin signature rules (#1042): `arg-count` returns i64 and
;; `arg` accepts an i64 index and returns String. User declarations may shadow
;; these bootstrap defaults.
(define (compiler-typecheck-argv-builtin-ok-source) : String
  "(define (main) : i64
  (+ (arg-count) (string-length (arg 0))))")

(define (compiler-typecheck-argv-builtin-bad-index-source) : String
  "(define (main) : String (arg \"0\"))")

(define (compiler-typecheck-argv-builtin-bad-arg-arity-source) : String
  "(define (main) : String (arg 0 1))")

(define (compiler-typecheck-argv-builtin-bad-count-arity-source) : String
  "(define (main) : i64 (arg-count 0))")

(define (compiler-typecheck-argv-builtin-shadow-source) : String
  "(define (arg-count) : i64 9)
(define (arg [n : i64]) : i64 n)
(define (main) : i64 (+ (arg-count) (arg 1)))")

(define (compiler-typecheck-argv-builtin-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-argv-builtin-ok-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-argv-builtin-bad-index-source)
        "typecheck: argument type mismatch")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-argv-builtin-bad-arg-arity-source)
          "typecheck: arity mismatch")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-argv-builtin-bad-count-arity-source)
            "typecheck: arity mismatch")
          (compiler-typecheck-ok?
            (compiler-typecheck-argv-builtin-shadow-source)))))))

(define (compiler-typecheck-lambda-ok-typed-source) : String
  "(define (main) : i64 (let [f : (-> i64 i64) (lambda ([x : i64]) : i64 x)] (f 5)))")

(define (compiler-typecheck-lambda-ok-nullary-source) : String
  "(define (main) : i64 (let [g : (-> i64) (lambda () : i64 42)] (g)))")

(define (compiler-typecheck-lambda-ok-inferred-ret-source) : String
  "(define (main) : i64 (let [h : (-> i64 i64) (lambda ([x : i64]) (+ x 1))] (h 7)))")

(define (compiler-typecheck-lambda-bad-ret-source) : String
  "(define (main) : i64 (begin (lambda ([x : i64]) : bool x) 0))")

(define (compiler-typecheck-lambda-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-lambda-ok-typed-source))
    (and
      (compiler-typecheck-ok? (compiler-typecheck-lambda-ok-nullary-source))
      (and
        (compiler-typecheck-ok?
          (compiler-typecheck-lambda-ok-inferred-ret-source))
        (compiler-typecheck-error-ok?
          (compiler-typecheck-lambda-bad-ret-source)
          "typecheck: lambda return type mismatch")))))

(define (compiler-typecheck-cast-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? "(define (f [x : i32]) : i64 (cast x : i64))")
    (and
      (compiler-typecheck-ok? "(define (f [x : i64]) : u8 (cast x : u8))")
      (and
        (compiler-typecheck-ok? "(define (f [x : i64]) : char (cast x : char))")
        (and
          (compiler-typecheck-ok?
            "(define (f [c : char]) : i64 (cast c : i64))")
          (and
            (compiler-typecheck-error-ok?
              "(define (f [x : f64]) : i64 (cast x : i64))"
              "typecheck: cast requires integer/char source and target")
            (compiler-typecheck-error-ok?
              "(define (f [b : bool]) : i64 (cast b : i64))"
              "typecheck: cast requires integer/char source and target")))))))

;; spmd-reduce operator/type rules (#1011, SPEC 5.15): `sum` accepts i32/i64/f64,
;; `min`/`max` accept i32/i64, `all`/`any` accept bool. (The varying-value
;; purity/effect rules are a separate slice.)
(define (compiler-typecheck-spmd-reduce-op-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))")
    (and
      (compiler-typecheck-ok?
        "(define (main [bs : (Array bool)] [n : i64]) : bool (spmd-reduce all ([i : i64 0 n]) true (array-ref bs i)))")
      (and
        (compiler-typecheck-error-ok?
          "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce all ([i : i64 0 n]) 0 (array-ref xs i)))"
          "typecheck: spmd-reduce all requires a bool type")
        (compiler-typecheck-error-ok?
          "(define (main [bs : (Array bool)] [n : i64]) : bool (spmd-reduce sum ([i : i64 0 n]) true (array-ref bs i)))"
          "typecheck: spmd-reduce sum requires an i32, i64, or f64 type")))))

;; spmd-reduce purity rules (#1011, SPEC.md §5.16): the per-lane value
;; expression accepts pure arithmetic over dynamic-array reads and the varying
;; index, but rejects writes (`array-set!`), function calls (also covers
;; `print*`/`panic`/file I/O and varying-argument user calls), varying control
;; flow (`if`/`while`/`match`), and indirect/gather array indexing.
(define (compiler-typecheck-spmd-reduce-purity-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (+ (array-ref xs i) 1)))")
    (and
      (compiler-typecheck-error-ok?
        "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-set! xs i 1)))"
        "`array-set!` is not allowed inside a spmd-reduce value expression; the value expression must be free of writes and other side effects (SPEC.md §5.16)")
      (and
        (compiler-typecheck-error-ok?
          "(define (helper [x : i64]) : i64 x) (define (main [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (helper i)))"
          "function calls are not allowed inside a spmd-reduce value expression; side-effecting builtins and user calls with varying arguments are deferred in the first slice (SPEC.md §5.16)")
        (and
          (compiler-typecheck-error-ok?
            "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (if (< (array-ref xs i) 0) 0 1)))"
            "varying control flow is not allowed inside a spmd-reduce value expression; the first slice has no varying if/while/match (SPEC.md §5.16)")
          (compiler-typecheck-error-ok?
            "(define (main [xs : (Array i64)] [ys : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs (array-ref ys i))))"
            "indirect array indexing is not allowed inside a spmd-reduce value expression; gather/scatter is deferred in the first slice (SPEC.md §5.16)"))))))

;; array-builtin signature rules (#1042): make-array length, array-ref array/index
;; types, and array-set! value-type agreement, with valid accepts.
(define (compiler-typecheck-array-builtin-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (f [a : (Array i64)]) : i64 (begin (array-set! a 0 5) (array-ref a 0)))")
    (and
      (compiler-typecheck-ok?
        "(define (f) : i64 (let [a : (Array i64) (make-array i64 4)] (array-length a)))")
      (and
        (compiler-typecheck-error-ok?
          "(define (f [a : (Array i64)]) : i64 (array-ref a true))"
          "typecheck: array index must be integer")
        (and
          (compiler-typecheck-error-ok?
            "(define (f) : i64 (make-array i64 true))"
            "typecheck: make-array length must be integer")
          (compiler-typecheck-error-ok?
            "(define (f [a : (Array i64)]) : unit (array-set! a 0 true))"
            "typecheck: array-set! value type mismatch"))))))

;; comptime typecheck rules (#1042): a `(comptime ...)` form is typed by its
;; inner expression and flows that type to the use site (so an `i64` body is an
;; `i64`, a `bool` comparison is a `bool`, and a `let`/`if` body keeps its type);
;; `comptime` cannot reference a runtime variable, and a comptime result that
;; disagrees with the surrounding type is rejected like any other mismatch.
(define (compiler-typecheck-comptime-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? "(define (main) : i64 (comptime (+ 1 2)))")
    (and
      (compiler-typecheck-ok? "(define (main) : bool (comptime (< 1 2)))")
      (and
        (compiler-typecheck-ok?
          "(define (main) : i64 (comptime (let [a : i64 1] (if (< a 2) a 0))))")
        (and
          (compiler-typecheck-ok?
            "(define (main) : i64 (+ (comptime (* 6 7)) 0))")
          (and
            (compiler-typecheck-ok?
              "(define (mk) : Expr (comptime (expr-if (expr-bool true) (expr-splice (expr-bool false)) (expr-bool true))))")
            (and
              (compiler-typecheck-ok?
                "(define (mk) : bool (comptime (expr-if? (expr-if (expr-bool true) (expr-bool false) (expr-bool true)))))")
              (and
                (compiler-typecheck-error-ok?
                  "(define (mk) : Expr (comptime (expr-if true (expr-bool true) (expr-bool false))))"
                  "expr-if condition expects Expr")
                (and
                  (compiler-typecheck-error-ok?
                    "(define (f [x : i64]) : i64 (comptime x))"
                    "compile-time evaluation cannot reference runtime variable 'x'")
                  (compiler-typecheck-error-ok?
                    "(define (main) : i64 (comptime (< 1 2)))"
                    "typecheck: return type mismatch"))))))))))

;; IO-builtin signature rules (#1042): whole-file helpers and file-handle status
;; primitives accept, plus wrong-argument, wrong-arity, and result-type-mismatch
;; rejections. Migrated from src/typechecker.rs read-file/write-file coverage.
(define (compiler-typecheck-io-builtin-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok?
        "(define (f [p : String]) : String (read-file p))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (f [p : String] [c : String]) : unit (write-file p c))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (f [p : String] [c : String]) : i64 (append-file-status p c))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (f [p : String]) : bool (file-exists? p))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (f [p : String]) : i64 (file-open-status p 0))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (f [h : i64]) : i64 (file-close-status h))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (f [h : i64] [n : i64]) : i64 (file-read-chunk-status h n))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (f [h : i64] [c : String]) : i64 (file-write-status h c))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (f [h : i64]) : i64 (file-flush-status h))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (f [h : i64]) : String (file-read-chunk-bytes h))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (f [h : i64]) : bool (file-read-chunk-eof? h))")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f [c : String]) : unit (write-file 5 c))"
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f [p : String]) : unit (write-file p))"
        "typecheck: arity mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f [p : i64]) : String (read-file p))"
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f [p : String]) : i64 (file-open-status p \"r\"))"
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f) : i64 (file-close-status \"h\"))"
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f [h : i64]) : i64 (file-write-status h 5))"
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f) : i64 (file-flush-status))"
        "typecheck: arity mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f [p : String] [c : String]) : i64 (write-file p c))"
        "typecheck: return type mismatch")
        unit
        (set! ok false))
      ok)))

;; Raw-pointer null construction / check (#1054).
(define (compiler-typecheck-ptr-null-ok-source) : String
  "(define (main) : i64 (if (ptr-null? (ptr-null : (Ptr i64))) 1 0))")

(define (compiler-typecheck-ptr-null-mut-source) : String
  "(define (main) : i64 (if (ptr-null? (ptr-null : (MutPtr i64))) 1 0))")

(define (compiler-typecheck-ptr-null-bad-type-source) : String
  "(define (main) : i64 (if (ptr-null? (ptr-null : i64)) 1 0))")

(define (compiler-typecheck-ptr-null-check-bad-source) : String
  "(define (main) : i64 (if (ptr-null? 5) 1 0))")

(define (compiler-typecheck-ptr-null-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-ptr-null-ok-source))
    (and
      (compiler-typecheck-ok? (compiler-typecheck-ptr-null-mut-source))
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-ptr-null-bad-type-source)
          "typecheck: ptr-null requires a pointer type, e.g. (ptr-null : (Ptr i64))")
        (compiler-typecheck-error-ok?
          (compiler-typecheck-ptr-null-check-bad-source)
          "typecheck: ptr-null? requires a raw pointer operand")))))

;; Unsafe blocks (#1053): parse + typecheck like `begin`; empty `(unsafe)`
;; rejects at parse.
(define (compiler-typecheck-unsafe-ok-source) : String
  "(define (main) : i64 (unsafe 1 2 42))")

(define (compiler-typecheck-unsafe-empty-source) : String
  "(define (main) : i64 (unsafe))")

(define (compiler-typecheck-unsafe-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-unsafe-ok-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-unsafe-empty-source)
      "parse: unsafe requires a non-empty body")))

;; CTFE layout queries (#989): folded calls produce `i64`, runtime calls are
;; rejected, and `offset-of` is restricted to repr-c structs and known fields.
(define (compiler-typecheck-layout-query-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (f) : i64 (comptime (size-of (type i64))))")
    (and
      (compiler-typecheck-ok?
        "(define (f) : i64 (comptime (align-of (type bool))))")
      (and
        (compiler-typecheck-ok?
          "(defstruct Inner
  (:repr c)
  (x i32))
(defstruct Outer
  (:repr c)
  (tag u8)
  (inner Inner)
  (tail i64))
(define (f) : i64
  (comptime (+ (size-of (type Outer)) (offset-of (type Outer) tail))))")
        (and
          (compiler-typecheck-error-ok?
            "(define (f) : i64 (comptime (size-of (type i64) (type bool))))"
            "size-of expects exactly one type argument")
          (and
            (compiler-typecheck-error-ok?
              "(define (f) : i64 (size-of (type i64)))"
              "typecheck: size-of is compile-time only; wrap it in (comptime ...)")
            (and
              (compiler-typecheck-error-ok?
                "(defstruct Box (x i64))
(define (f) : i64 (comptime (offset-of (type Box) x)))"
                "offset-of requires repr c struct type")
              (compiler-typecheck-error-ok?
                "(defstruct Packet
  (:repr c)
  (tag u8)
  (count i64))
(define (f) : i64 (comptime (offset-of (type Packet) missing)))"
                "offset-of unknown field missing"))))))))

(define (compiler-typecheck-reflection-source) : String
  "(defstruct Point (x i64) (flag bool))
(defenum Maybe (None) (Some String))
(define (field-count-helper [comptime T : type]) : i64
  (comptime (struct-field-count (type T))))
(define (enum-payload-helper [comptime T : type]) : i64
  (comptime (enum-variant-payload-count (type T) 1)))
(define (main) : i64
  (+ (field-count-helper (type Point))
     (+ (enum-payload-helper (type Maybe))
        (+ (comptime (if (string-eq (type-kind (type Point)) \"struct\") 1 0))
           (+ (comptime (if (string-eq (type-nominal-name (type Point)) \"Point\") 1 0))
              (+ (comptime (if (= (struct-field-type (type Point) 0) (type i64)) 1 0))
                 (+ (comptime (if (= (enum-variant-payload-type (type Maybe) 1 0) (type String)) 1 0))
                    (+ (comptime (array-length (type (Array i64 4))))
                       (+ (comptime (if (string-eq (type-key (type (& r str))) \"ref_r_str\") 1 0))
                          (comptime (function-param-count (type (-> i64 bool String)))))))))))))")

(define (compiler-typecheck-reflection-runtime-source) : String
  "(define (main) : String (type-kind (type i64)))")

(define (compiler-typecheck-reflection-string-result-source) : String
  "(define (main) : String (comptime (type-kind (type i64))))")

(define (compiler-typecheck-reflection-kind-mismatch-source) : String
  "(define (main) : i64 (comptime (struct-field-count (type i64))))")

(define (compiler-typecheck-reflection-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-reflection-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reflection-runtime-source)
        "typecheck: type-kind is compile-time only; wrap it in (comptime ...)")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-reflection-string-result-source)
          "String value is compile-time only")
        (compiler-typecheck-error-ok?
          (compiler-typecheck-reflection-kind-mismatch-source)
          "struct-field-count requires struct type")))))

(define (compiler-typecheck-defmacro-source) : String
  "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(defmacro (first [x : bool] [rest : bool ...]) : bool x)
(define (main) : i64 0)")

(define (compiler-typecheck-defmacro-produced-mismatch-source) : String
  "(defmacro (bad) : i64 (expr-bool true))
(define (main) : i64 0)")

(define (compiler-typecheck-defmacro-body-type-source) : String
  "(defmacro (bad [x : bool]) : bool (expr-bool? x))
(define (main) : i64 0)")

(define (compiler-typecheck-defmacro-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-defmacro-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-defmacro-produced-mismatch-source)
        "typecheck: macro body produced type does not match declaration")
      (compiler-typecheck-error-ok?
        (compiler-typecheck-defmacro-body-type-source)
        "typecheck: macro body must return Expr"))))

(define (compiler-typecheck-self-test-basics) : unit
  (begin
    (if (compiler-typecheck-ptr-null-tests-ok?)
      unit
      (panic "typecheck: ptr-null construction/check tests failed"))
    (if (compiler-typecheck-unsafe-tests-ok?)
      unit
      (panic "typecheck: unsafe block tests failed"))
    (if (compiler-typecheck-raw-pointer-op-tests-ok?)
      unit
      (panic "typecheck: raw pointer unsafe operation tests failed"))
    (if (compiler-typecheck-statement-tests-ok?)
      unit
      (panic "typecheck: statement/control-flow tests failed"))
    (if (compiler-typecheck-operator-tests-ok?)
      unit
      (panic "typecheck: operator/arity tests failed"))
    (if (compiler-typecheck-match-tests-ok?)
      unit
      (panic "typecheck: match/pattern tests failed"))
    (if (compiler-typecheck-spmd-reduce-op-tests-ok?)
      unit
      (panic "typecheck: spmd-reduce operator/type tests failed"))
    (if (compiler-typecheck-spmd-reduce-purity-tests-ok?)
      unit
      (panic "typecheck: spmd-reduce purity tests failed"))
    (if (compiler-typecheck-array-builtin-tests-ok?)
      unit
      (panic "typecheck: array-builtin signature tests failed"))
    (match (typecheck-compiler-source (compiler-typecheck-smoke-source))
      [(OkCompilerTypecheck summary)
        (if (= (compiler-typecheck-summary-score summary) 121)
          unit
          (panic "typecheck: smoke score mismatch"))]
      [(ErrCompilerTypecheck diag)
        (begin
          (panic (compiler-diagnostic-message diag))
          unit)])
    unit))

(define (compiler-typecheck-self-test-diagnostics) : unit
  (begin
    (if (compiler-typecheck-error-ok?
      (compiler-typecheck-unbound-source)
      "typecheck: unbound name missing")
      unit
      (panic "typecheck: unbound-name diagnostic test failed"))
    (if (compiler-typecheck-error-ok?
      (compiler-typecheck-bad-call-source)
      "typecheck: argument type mismatch")
      unit
      (panic "typecheck: bad-call diagnostic test failed"))
    (if (compiler-typecheck-error-ok?
      (compiler-typecheck-branch-mismatch-source)
      "typecheck: if branches must match")
      unit
      (panic "typecheck: branch mismatch diagnostic test failed"))
    unit))

(define (compiler-typecheck-self-test-models) : unit
  (begin
    (if (compiler-typecheck-aggregate-tests-ok?)
      unit
      (panic "typecheck: aggregate tests failed"))
    (if (compiler-typecheck-foreach-spmd-tests-ok?)
      unit
      (panic "typecheck: foreach/spmd tests failed"))
    (if (compiler-typecheck-nominal-tests-ok?)
      unit
      (panic "typecheck: nominal tests failed"))
    (if (compiler-typecheck-abstraction-policy-tests-ok?)
      unit
      (panic "typecheck: abstraction policy tests failed"))
    (if (compiler-typecheck-region-tests-ok?)
      unit
      (panic "typecheck: region tests failed"))
    (if (compiler-typecheck-result-try-tests-ok?)
      unit
      (panic "typecheck: result try tests failed"))
    (if (compiler-typecheck-move-kind-tests-ok?)
      unit
      (panic "typecheck: move-kind classifier tests failed"))
    (if (compiler-typecheck-resource-with-tests-ok?)
      unit
      (panic "typecheck: resource with tests failed"))
    (if (compiler-typecheck-raw-pointer-tests-ok?)
      unit
      (panic "typecheck: raw pointer type tests failed"))
    (if (compiler-typecheck-extern-abi-tests-ok?)
      unit
      (panic "typecheck: extern ABI signature tests failed"))
    (if (compiler-typecheck-reference-tests-ok?)
      unit
      (panic "typecheck: reference tests failed"))
    (if (compiler-typecheck-located-ok?)
      unit
      (panic "typecheck: located diagnostic test failed"))
    unit))

(define (compiler-typecheck-self-test-builtins) : unit
  (begin
    (if (compiler-typecheck-string-builtin-tests-ok?)
      unit
      (panic "typecheck: string builtin tests failed"))
    (if (compiler-typecheck-argv-builtin-tests-ok?)
      unit
      (panic "typecheck: argv builtin tests failed"))
    (if (compiler-typecheck-lambda-tests-ok?)
      unit
      (panic "typecheck: lambda tests failed"))
    (if (compiler-typecheck-cast-tests-ok?)
      unit
      (panic "typecheck: cast tests failed"))
    (if (compiler-typecheck-comptime-tests-ok?)
      unit
      (panic "typecheck: comptime tests failed"))
    (if (compiler-typecheck-io-builtin-tests-ok?)
      unit
      (panic "typecheck: io builtin tests failed"))
    (if (compiler-typecheck-reflection-tests-ok?)
      unit
      (panic "typecheck: comptime reflection tests failed"))
    (if (compiler-typecheck-layout-query-tests-ok?)
      unit
      (begin
        (panic "typecheck: layout query tests failed")
        unit))
    (if (compiler-typecheck-defmacro-tests-ok?)
      unit
      (begin
        (panic "typecheck: defmacro tests failed")
        unit))))

(define (compiler-typecheck-self-test) : i64
  (begin
    (compiler-typecheck-self-test-basics)
    (compiler-typecheck-self-test-diagnostics)
    (compiler-typecheck-self-test-models)
    (compiler-typecheck-self-test-builtins)
    42))