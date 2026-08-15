(module semantic.canonical.shared)

(define shared-value : i64
  41)

(define (function [value : i64]) : i64
  (+ shared-value value))

(defstruct SharedPair
  (value i64))

(defmacro (macro [value : Expr]) : Expr
  value)