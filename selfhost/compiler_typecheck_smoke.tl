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

(define (compiler-typecheck-reference-lambda-immediate-ok-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    ((lambda () : i64 (read r)))))")

(define (compiler-typecheck-reference-lambda-local-ok-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (read r))]
      (f))))")

(define (compiler-typecheck-reference-lambda-while-ok-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [i : i64 0]
      (let [f : (-> i64) (lambda () : i64 (read r))]
        (begin
          (while (< i 1)
            (begin
              (set! i (+ i 1))
              (let [v : i64 (f)] unit)))
          (f))))))")

(define (compiler-typecheck-reference-lambda-nested-ok-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    ((lambda () : i64
      (let [f : (-> i64) (lambda () : i64 (read r))]
        (f))))))")

(define (compiler-typecheck-reference-lambda-inner-arena-ok-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (with-arena scratch
      (let [f : (-> i64) (lambda () : i64 (read r))]
        (f)))))")

(define (compiler-typecheck-reference-lambda-local-return-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : (-> i64)
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (read r))]
      f)))")

(define (compiler-typecheck-reference-lambda-store-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : (Tuple (-> i64))
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (read r))]
      (tuple f))))")

(define (compiler-typecheck-reference-lambda-pass-unknown-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (call-now [f : (-> i64)]) : i64 (f))
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (read r))]
      (call-now f))))")

(define (compiler-typecheck-reference-lambda-assign-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let
      [f : (-> i64) (lambda () : i64 (read r))]
      [g : (-> i64) (lambda () : i64 0)]
      (begin
        (set! g f)
        (g)))))")

(define (compiler-typecheck-reference-lambda-inner-arena-return-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main) : (-> i64)
  (with-arena scratch
    (let [n : i64 1]
      (let [r : (& n i64) (& n)]
        (let [f : (-> i64) (lambda () : i64 (read r))]
          f)))))")

(define (compiler-typecheck-reference-lambda-mutable-reject-source) : String
  "(define (read [r : (&mut n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (&mut n i64) (&mut n)]
    ((lambda () : i64 (read r)))))")

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

(define (compiler-typecheck-reference-lambda-capture-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-lambda-immediate-ok-source))
    (and
      (compiler-typecheck-ok?
        (compiler-typecheck-reference-lambda-local-ok-source))
      (and
        (compiler-typecheck-ok?
          (compiler-typecheck-reference-lambda-while-ok-source))
        (and
          (compiler-typecheck-ok?
            (compiler-typecheck-reference-lambda-nested-ok-source))
          (and
            (compiler-typecheck-ok?
              (compiler-typecheck-reference-lambda-inner-arena-ok-source))
            (and
              (compiler-typecheck-error-ok?
                (compiler-typecheck-reference-lambda-local-return-source)
                "typecheck: reference-capturing closure value would escape lexical scope")
              (and
                (compiler-typecheck-error-ok?
                  (compiler-typecheck-reference-lambda-store-source)
                  "typecheck: reference-capturing closure value would escape lexical scope")
                (and
                  (compiler-typecheck-error-ok?
                    (compiler-typecheck-reference-lambda-pass-unknown-source)
                    "typecheck: reference-capturing closure value would escape lexical scope")
                  (and
                    (compiler-typecheck-error-ok?
                      (compiler-typecheck-reference-lambda-assign-source)
                      "typecheck: reference-capturing closure value would escape lexical scope")
                    (and
                      (compiler-typecheck-error-ok?
                        (compiler-typecheck-reference-lambda-inner-arena-return-source)
                        "typecheck: reference-capturing closure value would escape lexical scope")
                      (compiler-typecheck-error-ok?
                        (compiler-typecheck-reference-lambda-mutable-reject-source)
                        "typecheck: lambda cannot capture mutable reference; reference value would escape lexical scope"))))))))))))

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
                    (compiler-typecheck-reference-lambda-capture-tests-ok?)
                    (and
                      (compiler-typecheck-reference-return-container-tests-ok?)
                      (compiler-typecheck-reference-dyn-array-tests-ok?))))))))))))

(define (main) : i64
  (begin
    (compiler-typecheck-self-test)
    (if (compiler-typecheck-reference-escape-tests-ok?)
      42
      (begin
        (panic "typecheck: reference escape tests failed")
        0))))