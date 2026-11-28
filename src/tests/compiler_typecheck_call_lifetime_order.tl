(import compiler_typecheck_api as tc_api)
(import compiler_diagnostic as cdiag)
(import stdlib.io)
(import stdlib.iterator)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)

(define (check-order [params : String] [args : String] [conflict? : bool]) : unit
  (let
    [source : String
      (str_cat.str-cat
        "(defstruct RefBox (:lifetimes t) (value (& t i64)))
(defstruct Consumer (:lifetimes t) (apply (-> (& t i64) i64)))
(define (take "
        params
        ") : i64 (+ (consumer.apply x) (+ (deref y) (deref target.value))))
(define (probe [x : (& a i64)] [y : (& b i64)]) : i64
  (let [local : i64 7]
    [callback : (-> (& local i64) i64) (lambda ([v : (& local i64)]) : i64 (deref v))]
    [consumer : (Consumer local) (Consumer callback)]
    [holder (RefBox "
        (if conflict?
          "x"
          "(& local)")
        ")]
    (take "
        (string.copy args)
        ")))
(define (main) : i64 0)")]
    (match (tc_api.typecheck-compiler-source source)
      [(Ok _)
        (when
          conflict?
          (io.panic (str_cat.str-cat "accepted conflicting pin in " args)))]
      [(Err diagnostics)
        (let
          [first : cdiag.CompilerDiagnostic
            (cdiag.compiler-diagnostic-list-first (deref diagnostics))]
          [message : String (cdiag.compiler-diagnostic-message first)]
          (unless
            (and conflict? (string.contains message "call `take` argument"))
            (io.panic (str_cat.str-cat args ": " message))))])))

(define (check-orders [params : String] [args : String] [used : i64]) : unit
  (if (= used 15)
    (begin
      (check-order (string.copy params) (string.copy args) false)
      (check-order params args true))
    (for [i (iterator.range 0 4)]
      (let
        [bit : i64 (shl 1 i)]
        (when
          (= (bit-and used bit) 0)
          (check-orders
            (str_cat.str-cat
              (string.copy params)
              (cond
                [(= i 0) " [x : (& t i64)]"]
                [(= i 1) " [y : (& t i64)]"]
                [(= i 2) " [consumer : (Consumer t)]"]
                [else " [target : (&mut r (RefBox t))]"]))
            (str_cat.str-cat
              (string.copy args)
              (cond
                [(= i 0) " x"]
                [(= i 1) " y"]
                [(= i 2) " consumer"]
                [else " (&mut holder)"]))
            (bit-or used bit)))))))

(test
  call-lifetime-independent-bounds-and-pin-permutations
  (check-orders "" "" 0))