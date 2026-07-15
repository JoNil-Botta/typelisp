; sym_i64_env module - Immutable scoped interned-symbol -> i64 table.
; Functional binding, head-first lookup, shadowing.
(import stdlib.option)
(import (option i64) as option_i64)

(defenum SymI64Env
  (SymI64Nil)
  (SymI64Bind i64 i64 (Box SymI64Env)))

(define (sym-i64-empty) : SymI64Env
  SymI64Nil)

(define (sym-i64-bind-id [e : SymI64Env] [k : i64] [v : i64]) : SymI64Env
  (SymI64Bind k v (box e)))

(define (sym-i64-lookup-id [e : SymI64Env] [k : i64]) : option_i64.Option
  (let
    [cursor : SymI64Env e]
    [found : bool false]
    [out : option_i64.Option option_i64.None]
    (begin
      (while (not found)
        (match cursor
          [(SymI64Nil) (return option_i64.None)]
          [(SymI64Bind kk vv rest)
            (if (= kk k)
              (begin
                (set! out (option_i64.Some vv))
                (set! found true))
              (set! cursor (box-get rest)))]))
      out)))

(define (sym-i64-lookup-id-or [e : SymI64Env] [k : i64] [fallback : i64]) : i64
  (let
    [cursor : SymI64Env e]
    (begin
      (while true
        (match cursor
          [(SymI64Nil) (return fallback)]
          [(SymI64Bind kk vv rest)
            (if (= kk k)
              (return vv)
              (set! cursor (box-get rest)))]))
      fallback)))

(define (sym-i64-contains-id [e : SymI64Env] [k : i64]) : bool
  (let
    [cursor : SymI64Env e]
    (begin
      (while true
        (match cursor
          [(SymI64Nil) (return false)]
          [(SymI64Bind kk _ rest)
            (if (= kk k)
              (return true)
              (set! cursor (box-get rest)))]))
      false)))