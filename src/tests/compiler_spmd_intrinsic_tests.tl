(import compiler_typecheck_tests as checks)
(import stdlib.iterator)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.test)

(define (intrinsic-source [operand : String]) : String
  (str_cat.str-cat
    "(define (fill [xs : (& xs (__tl_dyn-array f64))] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (let [result "
    operand
    "] unit)))"))

(test
  spmd-intrinsic-operands-and-masks
  (let
    [operands
      (array
        "(__tl_float_sqrt (array-ref xs i))"
        "(__tl_float_sqrt (cast (array-ref xs i) : f32))"
        "(__tl_float_from_bits (__tl_float_to_bits (array-ref xs i)))"
        "(if (< (array-ref xs i) 0.0) (__tl_float_sqrt (- 0.0 (array-ref xs i))) (__tl_float_sqrt (array-ref xs i)))")]
    (for [index (iterator.range 0 (array-length operands))]
      (test.assert-true
        (checks.compiler-typecheck-ok?
          (intrinsic-source (string.copy (& (array-ref operands index)))))
        (string.copy (& (array-ref operands index))))))
  (test.assert-true
    (checks.compiler-typecheck-ok?
      "(define (__tl_float_sqrt [value : f64]) : f64 (+ value 1.0))
(define (fill [xs : (& xs (__tl_dyn-array f64))] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let [result (__tl_float_sqrt (array-ref xs i))] unit)))")
    "a source declaration keeps its ordinary shadowing rule"))

(defstruct IntrinsicErrorCase
  (operand String)
  (message String))

(test
  spmd-intrinsic-invalid-operands
  (let
    [cases
      (array
        (IntrinsicErrorCase
          "(__tl_float_sqrt)"
          "typecheck: __tl_float_sqrt expects exactly one argument")
        (IntrinsicErrorCase
          "(__tl_float_sqrt (array-ref xs i) 1.0)"
          "typecheck: __tl_float_sqrt expects exactly one argument")
        (IntrinsicErrorCase
          "(__tl_float_sqrt i)"
          "typecheck: __tl_float_sqrt expects f64 or f32")
        (IntrinsicErrorCase
          "(__tl_float_to_bits i)"
          "typecheck: __tl_float_to_bits expects f64 or f32")
        (IntrinsicErrorCase
          "(__tl_float_from_bits (array-ref xs i))"
          "typecheck: __tl_float_from_bits expects u64 or u32")
        (IntrinsicErrorCase
          "(__tl_float_to_bits (array-ref xs i) 1.0)"
          "typecheck: float bitcast expects exactly one argument")
        (IntrinsicErrorCase
          "(__tl_float_sqrt missing)"
          "typecheck: unbound name missing"))]
    (for [index (iterator.range 0 (array-length cases))]
      (let
        [entry (& (array-ref cases index))]
        (test.assert-true
          (checks.compiler-typecheck-error-ok?
            (intrinsic-source (string.copy (& entry.operand)))
            (string.copy (& entry.message)))
          (string.copy (& entry.operand))))))
  (test.assert-true
    (checks.compiler-typecheck-error-ok?
      "(define (identity [value : f64]) : f64 value)
(define (fill [xs : (& xs (__tl_dyn-array f64))] [n : i64]) : unit
  (let [__tl_float_sqrt : (-> f64 f64) identity]
    (foreach ([i : i64 0 n])
      (let [result (__tl_float_sqrt (array-ref xs i))] unit))))"
      "typecheck: foreach calls with varying arguments are not supported")
    "a lexical function value never acquires intrinsic privileges"))