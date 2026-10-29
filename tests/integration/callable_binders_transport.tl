(import callable_binders_transport_defs as provider)
(import (provider.generated) as generated)
(import stdlib.comptime)

(defmacro (retain-contract [value : Expr]) : Expr
  (let
    [contract : Expr (comptime.expr-type value)]
    `(ann ,value : ,contract)))

(defmacro (signature-score [value : Expr] [expected : type]) : i64
  (comptime.expr-int
    (if (= (comptime.expr-type value) expected)
      42
      0)))

(defstruct Callback
  (run (-> (& item i64) (& item i64))))

(defstruct BorrowedCallback
  (:lifetimes source)
  (run (-> (& source i64) i64)))

(define (read-holder
  [holder : Callback]
  [_unrelated : (& item i64)]
  [value : (& input i64)]) : i64
  (deref (holder.run value)))

(define (read-fixed-holder [value : (& source i64)]) : i64
  (let
    [read : (-> (& source i64) i64)
      (lambda ([q : (& source i64)]) : i64
        (deref q))]
    [holder : (BorrowedCallback source) (BorrowedCallback read)]
    (holder.run value)))

(define (apply [f : (-> (& input i64) (& input i64))] [value : (& input i64)]) : i64
  (deref (f value)))

(define (read-via-annotations [value : (& input i64)]) : i64
  (let
    [views : (__tl_dyn-array (& input i64))
      (init : (__tl_dyn-array (& input i64)))]
    (__tl_array-push! views (& input (deref value)))
    (deref (array-ref views 0))))

(define (keep-first [value : (& first i64)] [_other : (& second i64)]) : (&
    first
    i64)
  value)

(define (main) : i64
  (let
    [value : i64 7]
    [f : (-> (& item i64) (& item i64)) provider.identity]
    [returned (provider.returned)]
    [reflected (retain-contract provider.identity)]
    [boxed (box f)]
    [stored (Callback returned)]
    [tuple (tuple generated.identity)]
    [array (array f)]
    (if (=
      (signature-score provider.identity (-> (& renamed i64) (& renamed i64)))
      42)
      (+
        (apply reflected (& value))
        (apply (deref boxed) (& value))
        (read-holder stored (& value) (& value))
        (apply (tuple-ref tuple 0) (& value))
        (read-fixed-holder ((array-ref array 0) (& value)))
        (read-via-annotations (keep-first (returned (& value)) (& 0))))
      1)))