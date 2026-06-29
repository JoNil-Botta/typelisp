; sym_i64_env module - Immutable scoped interned-symbol -> i64 table.
; A focused child of #42: functional binding, head-first lookup, shadowing.
(module sym_i64_env)

(import compiler_intern as ci)
(import stdlib.option)
(import (option i64) as option_i64)

(defenum SymI64Env
  (SymI64Nil)
  (SymI64Bind i64 i64 (Box SymI64Env)))

(define (sym-i64-empty) : SymI64Env
  SymI64Nil)

(define (sym-i64-bind [e : SymI64Env] [k : String] [v : i64]) : SymI64Env
  (sym-i64-bind-id e (ci.intern k) v))

(define (sym-i64-bind-id [e : SymI64Env] [k : i64] [v : i64]) : SymI64Env
  (SymI64Bind k v (box e)))

(define (sym-i64-lookup [e : SymI64Env] [k : String]) : option_i64.Option
  (sym-i64-lookup-id e (ci.intern k)))

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

(define (sym-i64-lookup-or [e : SymI64Env] [k : String] [fallback : i64]) : i64
  (sym-i64-lookup-id-or e (ci.intern k) fallback))

(define (sym-i64-lookup-id-or [e : SymI64Env] [k : i64] [fallback : i64]) : i64
  (match (sym-i64-lookup-id e k)
    [(option_i64.Some value) value]
    [option_i64.None fallback]))

(define (sym-i64-contains [e : SymI64Env] [k : String]) : bool
  (match (sym-i64-lookup e k)
    [(option_i64.Some _) true]
    [option_i64.None false]))

(define (sym-i64-contains-id [e : SymI64Env] [k : i64]) : bool
  (match (sym-i64-lookup-id e k)
    [(option_i64.Some _) true]
    [option_i64.None false]))