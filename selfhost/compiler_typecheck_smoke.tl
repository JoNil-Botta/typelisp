;; compiler_typecheck_smoke.tl - Runnable smoke for compiler_typecheck.tl (#426).
(import "compiler_typecheck.tl")

(define (compiler-typecheck-reference-nested-local-source) : String
  "(define (main [x : i64]) : unit
  (let
    [x : i64 (+ x 1)]
    (let [r : (& x i64) (& x)] unit)))")

(define (compiler-typecheck-reference-inner-let-escape-source) : String
  "(define (main) : unit
  (let
    [r : (& x i64) (let [x : i64 1] (& x))]
    unit))")

(define (compiler-typecheck-reference-outer-assignment-escape-source) : String
  "(define (main [x : i64]) : unit
  (let
    [slot : (& x i64) (& x)]
    (let [x : i64 1] (set! slot (& x)))))")

(define (compiler-typecheck-reference-container-escape-source) : String
  "(define (main [x : i64] [items : (Array (& x i64))]) : unit
  (let [x : i64 1] (array-set! items 0 (& x))))")

(define (compiler-typecheck-reference-arena-store-escape-source) : String
  "(define (main [items : (Array (& r String))]) : unit
  (with-arena r
    (let [s : String (int->string 1)]
      (array-set! items 0 (& s)))))")

(define (compiler-typecheck-reference-lambda-capture-source) : String
  "(define (main [x : i64]) : (-> unit)
  (let
    [r : (& x i64) (& x)]
    (lambda () : unit (let [copy : (& x i64) r] unit))))")

(define (compiler-typecheck-reference-escape-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-reference-nested-local-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-inner-let-escape-source)
        "typecheck: reference value would escape lexical scope")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-reference-outer-assignment-escape-source)
          "typecheck: cannot store reference into longer-lived binding; reference value would escape lexical scope")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-reference-container-escape-source)
            "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-reference-arena-store-escape-source)
              "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
            (compiler-typecheck-error-ok?
              (compiler-typecheck-reference-lambda-capture-source)
              "typecheck: lambda cannot capture immutable reference; reference value would escape lexical scope")))))))

(define (main) : i64
  (begin
    (compiler-typecheck-self-test)
    (if (compiler-typecheck-reference-escape-tests-ok?)
      42
      (begin
        (panic "typecheck: reference escape tests failed")
        0))))