;; compiler_typecheck_smoke.tl - Runnable smoke for compiler_typecheck.tl (#426).
(import "../stdlib/io.tl")

(import "compiler_typecheck.tl")

(import "../stdlib/string.tl")

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

(define (compiler-typecheck-reference-array-push-ok-source) : String
  "(define (main [x : i64] [items : (Array (& x i64))]) : unit
  (array-push! items (& x)))")

(define (compiler-typecheck-reference-array-push-escape-source) : String
  "(define (main [x : i64] [items : (Array (& x i64))]) : unit
  (let [x : i64 1] (array-push! items (& x))))")

(define (compiler-typecheck-reference-arena-store-escape-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main [items : (Array (& r str))]) : unit
  (with-arena r
    (let [s : String (int->string 1)]
      (array-set! items 0 (& s)))))"))

(define (compiler-typecheck-reference-lambda-capture-source) : String
  "(define (main [x : i64]) : (-> unit)
  (let
    [r : (& x i64) (& x)]
    (lambda () : unit (let [copy : (& x i64) r] unit))))")

(define (compiler-typecheck-reference-tuple-return-ok-source) : String
  "(define (main [n : i64]) : (Tuple (& n i64) i64)
  (tuple (& n) 1))")

(define (compiler-typecheck-reference-fixed-return-ok-source) : String
  "(define (main [n : i64]) : (Array (& n i64) 1)
  (array (& n)))")

(define (compiler-typecheck-reference-tuple-local-escape-source) : String
  "(define (main [n : i64]) : (Tuple (& n i64) i64)
  (let [n : i64 1] (tuple (& n) 1)))")

(define (compiler-typecheck-reference-fixed-local-escape-source) : String
  "(define (main [n : i64]) : (Array (& n i64) 1)
  (let [n : i64 1] (array (& n))))")

(define (compiler-typecheck-reference-tuple-arena-escape-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main [seed : (& phase str)]) : (Tuple (& phase str) i64)
  (with-arena phase
    (let [s : String (int->string 1)] (tuple (& phase s) 1))))"))

(define (compiler-typecheck-reference-fixed-arena-escape-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main [seed : (& phase str)]) : (Array (& phase str) 1)
  (with-arena phase
    (let [s : String (int->string 1)] (array (& phase s)))))"))

(define (compiler-typecheck-reference-dyn-array-init-ok-source) : String
  "(define (main [n : i64]) : unit
  (let [items : (Array (& n i64)) (init : (Array (& n i64)))] unit))")

(define (compiler-typecheck-reference-dyn-array-make-reject-source) : String
  "(define (main [n : i64]) : unit
  (let [items : (Array (& n i64)) (make-array (& n i64) 0)] unit))")

(define (compiler-typecheck-reference-dyn-array-push-read-ok-source) : String
  "(define (main [n : i64]) : unit
  (let
    [items : (Array (& n i64)) (init : (Array (& n i64)))]
    (begin
      (array-push! items (& n))
      (let [r : (& n i64) (array-ref items 0)] unit))))")

(define (compiler-typecheck-reference-dyn-array-push-escape-source) : String
  "(define (main [n : i64]) : unit
  (let
    [items : (Array (& n i64)) (init : (Array (& n i64)))]
    (let [n : i64 1] (array-push! items (& n)))))")

(define (compiler-typecheck-reference-dyn-array-hidden-source) : String
  "(define (main) : unit
  (let [items : (Array (& n i64)) (make-array (& n i64) 0)] unit))")

(define (compiler-typecheck-reference-return-container-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-tuple-return-ok-source))
    (and
      (compiler-typecheck-ok?
        (compiler-typecheck-reference-fixed-return-ok-source))
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-reference-tuple-local-escape-source)
          "typecheck: reference value would escape lexical scope")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-reference-fixed-local-escape-source)
            "typecheck: reference value would escape lexical scope")
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-reference-tuple-arena-escape-source)
              "typecheck: region-tagged value cannot escape with-arena 'phase'")
            (compiler-typecheck-error-ok?
              (compiler-typecheck-reference-fixed-arena-escape-source)
              "typecheck: region-tagged value cannot escape with-arena 'phase'")))))))

(define (compiler-typecheck-reference-dyn-array-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-dyn-array-init-ok-source))
    (and
      (compiler-typecheck-ok?
        (compiler-typecheck-reference-dyn-array-push-read-ok-source))
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-reference-dyn-array-push-escape-source)
          "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-reference-dyn-array-make-reject-source)
            "typecheck: init unsupported type (& n i64)")
          (compiler-typecheck-error-ok?
            (compiler-typecheck-reference-dyn-array-hidden-source)
            "typecheck: make-array element type is not supported"))))))

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
            (compiler-typecheck-ok?
              (compiler-typecheck-reference-array-push-ok-source))
            (and
              (compiler-typecheck-error-ok?
                (compiler-typecheck-reference-array-push-escape-source)
                "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
              (and
                (compiler-typecheck-error-ok?
                  (compiler-typecheck-reference-arena-store-escape-source)
                  "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
                (and
                  (compiler-typecheck-error-ok?
                    (compiler-typecheck-reference-lambda-capture-source)
                    "typecheck: lambda cannot capture immutable reference; reference value would escape lexical scope")
                  (and
                    (compiler-typecheck-reference-return-container-tests-ok?)
                    (compiler-typecheck-reference-dyn-array-tests-ok?)))))))))))

(define (main) : i64
  (begin
    (compiler-typecheck-self-test)
    (if (compiler-typecheck-reference-escape-tests-ok?)
      42
      (begin
        (panic "typecheck: reference escape tests failed")
        0))))