;# Deterministic hash helpers for stdlib collections.
;#
;# This module provides stable, non-cryptographic hash building blocks for
;# future maps, sets, intern tables, and compiler data structures. Hash values
;# are normalized nonnegative `i64` values in `0 <= hash < modulus`.
;#
;# A hash is only a bucket hint. Key users must still compare candidate keys
;# with the matching equality predicate because different keys can collide.
;# These helpers do not allocate; they only inspect scalar values and String
;# bytes/chars already owned by the caller.
;#
;# Usage: `(import stdlib.hash)`
;#
;# ```typelisp
;# (import stdlib.hash)
;# (define (main) : i64
;#   (let [key : String "symbol"]
;#     (hash.combine (hash.string-key (& key)) (hash.i64 7))))
;# ```
(import stdlib.comptime)
(import stdlib.string as string_mod)

;: Return the fixed hash modulus.
(define (modulus) : i64
  2147483647)

;: Return the fixed multiplier used by `combine` and `string-key`.
(define (multiplier) : i64
  131)

;: Normalize any integer into the public hash range.
(define (normalize [value : i64]) : i64
  (let
    [m : i64 2147483647]
    [raw : i64 (% value 2147483647)]
    (if (< raw 0)
      (+ raw m)
      raw)))

;: Combine an accumulated hash value with one component hash.
;:
;: The result is deterministic and non-cryptographic. The `+ 1` delimiter keeps
;: `combine 0 0` distinct from an untouched empty accumulator.
(define (combine [seed : i64] [component : i64]) : i64
  (stdlib.hash.normalize
    (+
      (+ (* (stdlib.hash.normalize seed) 131) (stdlib.hash.normalize component))
      1)))

;: Combine already-normalized hash parts without re-normalizing inputs.
(define (combine-normalized [seed : i64] [component : i64]) : i64
  (stdlib.hash.normalize (+ (+ (* seed 131) component) 1)))

;: Hash an `i64` key value.
(define (i64 [value : i64]) : i64
  (stdlib.hash.normalize value))

;: Return true when two `i64` keys are equal.
(define (key-i64-eq? [a : i64] [b : i64]) : bool
  (= a b))

;: Hash a `bool` key value.
(define (bool [value : bool]) : i64
  (if value
    1
    0))

;: Return true when two `bool` keys are equal.
(define (key-bool-eq? [a : bool] [b : bool]) : bool
  (= a b))

;: Hash a `char` key value by scalar code.
(define (char [value : char]) : i64
  (stdlib.hash.normalize (cast value : i64)))

;: Return true when two `char` keys have the same scalar code.
(define (key-char-eq? [a : char] [b : char]) : bool
  (= (cast a : i64) (cast b : i64)))

;: Hash borrowed text by walking its current byte/char sequence.
;:
;: Hash values are bucket hints only; key users must still compare candidate keys
;: with the matching equality predicate because different keys can collide.
(define (string-key [key : (& key str)]) : i64
  (let
    [n : i64 (string-length key)]
    [i : i64 0]
    [hash : i64 0]
    (begin
      (while (>= (- n i) 4)
        (let
          [h1 : i64 (+ (+ (* hash 131) (cast (string-ref key i) : i64)) 1)]
          [h2 : i64 (+ (+ (* h1 131) (cast (string-ref key (+ i 1)) : i64)) 1)]
          [h3 : i64 (+ (+ (* h2 131) (cast (string-ref key (+ i 2)) : i64)) 1)]
          [h4 : i64 (+ (+ (* h3 131) (cast (string-ref key (+ i 3)) : i64)) 1)]
          [reduced : i64 (+ (bit-and h4 0x7fffffff) (shr h4 31))]
          (begin
            (set!
              hash
              (if (>= reduced 0x7fffffff)
                (- reduced 0x7fffffff)
                reduced))
            (set! i (+ i 4)))))
      (while (< i n)
        (let
          [next : i64 (+ (+ (* hash 131) (cast (string-ref key i) : i64)) 1)]
          [reduced : i64 (+ (bit-and next 0x7fffffff) (shr next 31))]
          (begin
            (set!
              hash
              (if (>= reduced 0x7fffffff)
                (- reduced 0x7fffffff)
                reduced))
            (set! i (+ i 1)))))
      hash)))

;: Return true when two borrowed string keys are equal.
(define (key-string-eq? [a : (& a str)] [b : (& b str)]) : bool
  (string_mod.eq a b))

;: Emit one deterministic scalar or aggregate component hash.
(defmacro (inline-hash [value : comptime.Expr] [path-expr : comptime.Expr]) : comptime.Expr
  (let
    [path : String (comptime.expr-string-value path-expr)]
    [value-type (comptime.expr-type value)]
    (match (type-kind value-type)
      ["unit" `(stdlib.hash.combine 11 0)]
      ["bool"
        `(stdlib.hash.combine
          13
          (if ,value
            1
            0))]
      ["char"
        `(stdlib.hash.combine 17 (stdlib.hash.normalize (cast ,value : i64)))]
      ["i64"
        `(stdlib.hash.combine 19 (stdlib.hash.normalize (cast ,value : i64)))]
      ["i32"
        `(stdlib.hash.combine 23 (stdlib.hash.normalize (cast ,value : i64)))]
      ["i16"
        `(stdlib.hash.combine 29 (stdlib.hash.normalize (cast ,value : i64)))]
      ["i8"
        `(stdlib.hash.combine 31 (stdlib.hash.normalize (cast ,value : i64)))]
      ["u64"
        `(stdlib.hash.combine 37 (stdlib.hash.normalize (cast ,value : i64)))]
      ["u32"
        `(stdlib.hash.combine 41 (stdlib.hash.normalize (cast ,value : i64)))]
      ["u16"
        `(stdlib.hash.combine 43 (stdlib.hash.normalize (cast ,value : i64)))]
      ["u8"
        `(stdlib.hash.combine 47 (stdlib.hash.normalize (cast ,value : i64)))]
      ["string" `(stdlib.hash.combine 53 (stdlib.hash.string-key (& ,value)))]
      ["struct" `(stdlib.hash.struct-hash-fields 0 ,value 59 ,path-expr)]
      ["tuple" `(stdlib.hash.tuple-hash-elements 0 ,value 61 ,path-expr)]
      ["array"
        (if (array-dynamic? value-type)
          (comptime.comptime-error
            (comptime.string-append
              "hash: unsupported type "
              (comptime.string-append
                (type-key value-type)
                (comptime.string-append " at " path))))
          (let
            [length-expr : comptime.Expr
              (comptime.expr-int (array-length value-type))]
            [element-path : String (comptime.string-append path "[]")]
            `(stdlib.hash.inline-fixed-array-hash
              ,length-expr
              ,value
              ,(comptime.expr-string element-path))))]
      ["enum" `(stdlib.hash.enum-hash-dispatch ,value 0 ,path-expr)]
      [_
        (comptime.comptime-error
          (comptime.string-append
            "hash: unsupported type "
            (comptime.string-append
              (type-key value-type)
              (comptime.string-append " at " path))))])))

;: Emit ordered field hashing for a struct.
(defmacro (struct-hash-fields
  [index-expr : comptime.Expr]
  [value : comptime.Expr]
  [seed : comptime.Expr]
  [path-expr : comptime.Expr]) : comptime.Expr
  (let
    [path : String (comptime.expr-string-value path-expr)]
    [value-type (comptime.expr-type value)]
    (match index-expr
      [(comptime.Expr.Int index)
        (if (>= index (struct-field-count value-type))
          seed
          (let
            [field-name : String (struct-field-name value-type index)]
            [field-value : comptime.Expr
              (comptime.expr-struct-get value field-name)]
            [field-path : String
              (comptime.string-append
                path
                (comptime.string-append "." field-name))]
            [next-index : comptime.Expr (comptime.expr-int (+ index 1))]
            [position-expr : comptime.Expr (comptime.expr-int (+ 1000 index))]
            [next-seed : comptime.Expr
              `(stdlib.hash.combine
                (stdlib.hash.combine ,seed ,position-expr)
                (stdlib.hash.inline-hash
                  ,field-value
                  ,(comptime.expr-string field-path)))]
            `(stdlib.hash.struct-hash-fields
              ,next-index
              ,value
              ,next-seed
              ,path-expr)))]
      [_
        (comptime.comptime-error
          "hash: struct field index must be an integer literal")])))

;: Emit ordered element hashing for a tuple.
(defmacro (tuple-hash-elements
  [index-expr : comptime.Expr]
  [value : comptime.Expr]
  [seed : comptime.Expr]
  [path-expr : comptime.Expr]) : comptime.Expr
  (let
    [path : String (comptime.expr-string-value path-expr)]
    [value-type (comptime.expr-type value)]
    (match index-expr
      [(comptime.Expr.Int index)
        (if (>= index (tuple-element-count value-type))
          seed
          (let
            [element-value : comptime.Expr
              (comptime.expr-tuple-ref value index)]
            [element-path : String
              (comptime.string-append
                path
                (comptime.string-append
                  "["
                  (comptime.string-append (comptime.int->string index) "]")))]
            [next-index : comptime.Expr (comptime.expr-int (+ index 1))]
            [position-expr : comptime.Expr (comptime.expr-int (+ 2000 index))]
            [next-seed : comptime.Expr
              `(stdlib.hash.combine
                (stdlib.hash.combine ,seed ,position-expr)
                (stdlib.hash.inline-hash
                  ,element-value
                  ,(comptime.expr-string element-path)))]
            `(stdlib.hash.tuple-hash-elements
              ,next-index
              ,value
              ,next-seed
              ,path-expr)))]
      [_
        (comptime.comptime-error
          "hash: tuple element index must be an integer literal")])))

;: Emit allocation-free traversal of a fixed array.
(defmacro (inline-fixed-array-hash
  [length-expr : comptime.Expr]
  [value : comptime.Expr]
  [path-expr : comptime.Expr]) : comptime.Expr
  `(let
    [__hash_array ,value]
    [__hash_i : i64 0]
    [__hash_seed : i64 67]
    (begin
      (while (< __hash_i ,length-expr)
        (begin
          (set!
            __hash_seed
            (stdlib.hash.combine
              (stdlib.hash.combine __hash_seed (+ 3000 __hash_i))
              (stdlib.hash.inline-hash
                (array-ref __hash_array __hash_i)
                ,path-expr)))
          (set! __hash_i (+ __hash_i 1))))
      __hash_seed)))

;: Emit ordered hashing for one matched enum variant's payloads.
(defmacro (enum-hash-payloads
  [enum-value : comptime.Expr]
  [variant-index-expr : comptime.Expr]
  [payload-index-expr : comptime.Expr]
  [seed : comptime.Expr]
  [path-expr : comptime.Expr]) : comptime.Expr
  (let
    [path : String (comptime.expr-string-value path-expr)]
    [enum-type (comptime.expr-type enum-value)]
    (match variant-index-expr
      [(comptime.Expr.Int variant-index)
        (match payload-index-expr
          [(comptime.Expr.Int payload-index)
            (if (>=
              payload-index
              (enum-variant-payload-count enum-type variant-index))
              seed
              (let
                [payload-name : String
                  (comptime.string-append
                    (comptime.string-append
                      (comptime.string-append
                        "__hash_v"
                        (comptime.int->string variant-index))
                      "_p")
                    (comptime.int->string payload-index))]
                [payload-value : comptime.Expr (comptime.expr-var payload-name)]
                [variant-name : String
                  (enum-variant-name enum-type variant-index)]
                [payload-path : String
                  (comptime.string-append
                    path
                    (comptime.string-append
                      "."
                      (comptime.string-append
                        variant-name
                        (comptime.string-append
                          "["
                          (comptime.string-append
                            (comptime.int->string payload-index)
                            "]")))))]
                [next-index : comptime.Expr
                  (comptime.expr-int (+ payload-index 1))]
                [position-expr : comptime.Expr
                  (comptime.expr-int (+ 4000 payload-index))]
                [next-seed : comptime.Expr
                  `(stdlib.hash.combine
                    (stdlib.hash.combine ,seed ,position-expr)
                    (stdlib.hash.inline-hash
                      ,payload-value
                      ,(comptime.expr-string payload-path)))]
                `(stdlib.hash.enum-hash-payloads
                  ,enum-value
                  ,variant-index-expr
                  ,next-index
                  ,next-seed
                  ,path-expr)))]
          [_
            (comptime.comptime-error
              "hash: enum payload index must be an integer literal")])]
      [_
        (comptime.comptime-error
          "hash: enum variant index must be an integer literal")])))

;: Emit a staged enum match with variant and payload domain separation.
(defmacro (enum-hash-dispatch
  [value : comptime.Expr]
  [variant-index-expr : comptime.Expr]
  [path-expr : comptime.Expr]) : comptime.Expr
  (let
    [value-type (comptime.expr-type value)]
    (match variant-index-expr
      [(comptime.Expr.Int variant-index)
        (if (>= variant-index (enum-variant-count value-type))
          `0
          (let
            [variant-name : String (enum-variant-name value-type variant-index)]
            [payload-count : i64
              (enum-variant-payload-count value-type variant-index)]
            [payload-prefix : String
              (comptime.string-append
                (comptime.string-append
                  "__hash_v"
                  (comptime.int->string variant-index))
                "_p")]
            [pattern : comptime.Pattern
              (comptime.pattern-variant
                variant-name
                (comptime.pattern-list-bindings payload-prefix payload-count))]
            [variant-seed : comptime.Expr
              `(stdlib.hash.combine
                71
                ,(comptime.expr-int (+ 5000 variant-index)))]
            [body : comptime.Expr
              `(stdlib.hash.enum-hash-payloads
                ,value
                ,variant-index-expr
                0
                ,variant-seed
                ,path-expr)]
            [next-index : comptime.Expr (comptime.expr-int (+ variant-index 1))]
            [fallback : comptime.Expr
              `(stdlib.hash.enum-hash-dispatch ,value ,next-index ,path-expr)]
            (comptime.expr-match
              value
              (comptime.match-arm-list-cons
                (comptime.match-arm pattern body)
                (comptime.match-arm-list-cons
                  (comptime.match-arm (comptime.pattern-wildcard) fallback)
                  (comptime.match-arm-list-empty))))))]
      [_
        (comptime.comptime-error
          "hash: enum variant index must be an integer literal")])))

;: Evaluate one public hash operand and dispatch its inferred concrete type.
(defmacro (hash-once [value : comptime.Expr]) : comptime.Expr
  `(let
    [__hash_value ,value]
    (stdlib.hash.inline-hash __hash_value "value")))

;: Generate a deterministic, unkeyed structural-hash module for finite `T`.
;:
;: The generated `hash` operation evaluates its argument once. Equal values
;: under `(import (eq T))` always receive equal hashes for supported `T`.
;: Collisions and adversarial hash-flood resistance are outside this v1 API;
;: consumers must still compare candidate keys.
(defmacro (hash [T : type]) : Module
  (let
    [module-name : comptime.Expr
      (comptime.expr-var
        (comptime.string-append "stdlib.hash.generated." (type-key T)))]
    (match (type-kind T)
      ["unit"
        `(begin
          (module ,module-name)
          (import stdlib.hash)
          (define (hash [value : ,T]) : i64
            (stdlib.hash.combine 11 0)))]
      [_
        `(begin
          (module ,module-name)
          (import stdlib.comptime)
          (import stdlib.hash)
          (defmacro (hash [value : ,T]) : i64
            (comptime.expr-call
              (comptime.expr-var "stdlib.hash.hash-once")
              (comptime.expr-list-cons value (comptime.expr-list-empty)))))])))

(test
  hash-api
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [empty : String ""]
    [a : String "a"]
    [ab : String "ab"]
    [abc : String "abc"]
    [abcd : String "abcd"]
    [abcdefgh : String "abcdefgh"]
    [ba : String "ba"]
    [a-newline-b : String "a\nb"]
    [bc : String "bc"]
    [joined : String (string_mod.append a bc)]
    [same : String "same"]
    [same-copy : String (string_mod.append "sa" "me")]
    [different : String "different"]
    [edge : String "edge\ncase"]
    [range-min : i64 (stdlib.hash.i64 -9223372036854775808)]
    [range-max : i64 (stdlib.hash.i64 9223372036854775807)]
    [range-combine : i64 (stdlib.hash.combine -1 -1)]
    [range-empty : i64 (stdlib.hash.string-key (& empty))]
    [range-edge : i64 (stdlib.hash.string-key (& edge))]
    (begin
      (if (= (stdlib.hash.modulus) 2147483647)
        unit
        (fail))
      (if (= (stdlib.hash.multiplier) 131)
        unit
        (fail))
      (if (= (stdlib.hash.normalize 2147483647) 0)
        unit
        (fail))
      (if (= (stdlib.hash.normalize -1) 2147483646)
        unit
        (fail))
      (if (= (stdlib.hash.i64 42) 42)
        unit
        (fail))
      (if (= (stdlib.hash.i64 -42) 2147483605)
        unit
        (fail))
      (if (= (stdlib.hash.bool false) 0)
        unit
        (fail))
      (if (= (stdlib.hash.bool true) 1)
        unit
        (fail))
      (if (= (stdlib.hash.char 'A') 65)
        unit
        (fail))
      (if (= (stdlib.hash.char '\n') 10)
        unit
        (fail))
      (if (= (stdlib.hash.combine 0 0) 1)
        unit
        (fail))
      (if (= (stdlib.hash.combine 42 7) 5510)
        unit
        (fail))
      (if (= (stdlib.hash.string-key (& empty)) 0)
        unit
        (fail))
      (if (= (stdlib.hash.string-key (& a)) 98)
        unit
        (fail))
      (if (= (stdlib.hash.string-key (& ab)) 12937)
        unit
        (fail))
      (if (= (stdlib.hash.string-key (& abc)) 1694847)
        unit
        (fail))
      (if (= (stdlib.hash.string-key (& abcd)) 222025058)
        unit
        (fail))
      (if (= (stdlib.hash.string-key (& abcdefgh)) 1379066653)
        unit
        (fail))
      (if (= (stdlib.hash.string-key (& ba)) 13067)
        unit
        (fail))
      (if (= (stdlib.hash.string-key (& a-newline-b)) 1683318)
        unit
        (fail))
      (if (= (stdlib.hash.i64 42) (stdlib.hash.i64 (+ 40 2)))
        unit
        (fail))
      (if (= (stdlib.hash.bool true) (stdlib.hash.bool (not false)))
        unit
        (fail))
      (if (= (stdlib.hash.char 'A') (stdlib.hash.char (string-ref "A" 0)))
        unit
        (fail))
      (if (=
        (stdlib.hash.string-key (& abc))
        (stdlib.hash.string-key (& joined)))
        unit
        (fail))
      (if (stdlib.hash.key-i64-eq? 5 5)
        unit
        (fail))
      (if (not (stdlib.hash.key-i64-eq? 5 6))
        unit
        (fail))
      (if (stdlib.hash.key-bool-eq? true true)
        unit
        (fail))
      (if (not (stdlib.hash.key-bool-eq? true false))
        unit
        (fail))
      (if (stdlib.hash.key-char-eq? 'x' 'x')
        unit
        (fail))
      (if (not (stdlib.hash.key-char-eq? 'x' (string-ref "y" 0)))
        unit
        (fail))
      (if (stdlib.hash.key-string-eq? (& same) (& same-copy))
        unit
        (fail))
      (if (not (stdlib.hash.key-string-eq? (& same) (& different)))
        unit
        (fail))
      (if (= (stdlib.hash.i64 0) (stdlib.hash.i64 2147483647))
        unit
        (fail))
      (if (not (stdlib.hash.key-i64-eq? 0 2147483647))
        unit
        (fail))
      (if (= (stdlib.hash.combine 0 131) (stdlib.hash.combine 1 0))
        unit
        (fail))
      (if (not (stdlib.hash.key-i64-eq? 0 1))
        unit
        (fail))
      (if (if (>= range-min 0)
        (< range-min (stdlib.hash.modulus))
        false)
        unit
        (fail))
      (if (if (>= range-max 0)
        (< range-max (stdlib.hash.modulus))
        false)
        unit
        (fail))
      (if (if (>= range-combine 0)
        (< range-combine (stdlib.hash.modulus))
        false)
        unit
        (fail))
      (if (if (>= range-empty 0)
        (< range-empty (stdlib.hash.modulus))
        false)
        unit
        (fail))
      (if (if (>= range-edge 0)
        (< range-edge (stdlib.hash.modulus))
        false)
        unit
        (fail)))))