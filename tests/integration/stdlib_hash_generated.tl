(import stdlib.eq)
(import stdlib.hash)
(import stdlib.io)
(import stdlib.string as string_mod)

(defenum HashStructuralChoice
  (None)
  (Number i64)
  (OtherNumber i64)
  (Text bool String char))

(defstruct HashStructuralPoint
  (x i32)
  (enabled bool)
  (label String)
  (code char))

(defstruct HashStructuralSample
  (point HashStructuralPoint)
  (choice HashStructuralChoice))

(defstruct HashStructuralTuple
  (items (Tuple u8 u8)))

(defstruct HashStructuralArray
  (items (Array i16 3)))

(defstruct HashStructuralEmpty
  (unit-value unit)
  (items (Array u8 0)))

(import (hash.hash HashStructuralSample) as hash_structural_sample)
(import (hash.hash HashStructuralTuple) as hash_structural_tuple)
(import (hash.hash HashStructuralArray) as hash_structural_array)
(import (hash.hash HashStructuralEmpty) as hash_structural_empty)
(import (eq.eq HashStructuralSample) as eq_structural_sample)
(import (hash.hash (type unit)) as hash_unit)
(import (hash.hash bool) as hash_bool)
(import (hash.hash char) as hash_char)
(import (hash.hash i64) as hash_i64)
(import (hash.hash i32) as hash_i32)
(import (hash.hash i16) as hash_i16)
(import (hash.hash i8) as hash_i8)
(import (hash.hash u64) as hash_u64)
(import (hash.hash u32) as hash_u32)
(import (hash.hash u16) as hash_u16)
(import (hash.hash u8) as hash_u8)
(import (hash.hash String) as hash_string)

(define (sample [x : i32] [label : String] [choice : HashStructuralChoice]) : HashStructuralSample
  (HashStructuralSample (HashStructuralPoint x true label 'A') choice))

(define (require [condition : bool] [message : String]) : unit
  (if condition
    unit
    (io.panic message)))

(define (main) : i64
  (let
    [equal-left : HashStructuralSample
      (sample 4 "same" (HashStructuralChoice.Number 9))]
    [equal-right : HashStructuralSample
      (sample 4 (string_mod.append "sa" "me") (HashStructuralChoice.Number 9))]
    [hash-left : HashStructuralSample
      (sample 4 "same" (HashStructuralChoice.Number 9))]
    [hash-right : HashStructuralSample
      (sample 4 (string_mod.append "s" "ame") (HashStructuralChoice.Number 9))]
    [evaluated-once : HashStructuralSample
      (sample 4 "same" (HashStructuralChoice.Number 9))]
    [field-different : HashStructuralSample
      (sample 5 "same" (HashStructuralChoice.Number 9))]
    [variant-different : HashStructuralSample
      (sample 4 "same" (HashStructuralChoice.OtherNumber 9))]
    [empty-variant : HashStructuralSample
      (sample 4 "same" (HashStructuralChoice.None))]
    [text-choice : HashStructuralSample
      (sample 4 "same" (HashStructuralChoice.Text true "payload" 'Z'))]
    [ordered-tuple : HashStructuralTuple (HashStructuralTuple (tuple 1 2))]
    [reversed-tuple : HashStructuralTuple (HashStructuralTuple (tuple 2 1))]
    [ordered-array : HashStructuralArray (HashStructuralArray (array 1 2 3))]
    [reversed-array : HashStructuralArray (HashStructuralArray (array 3 2 1))]
    [empty : HashStructuralEmpty (HashStructuralEmpty unit (array))]
    [same-left : i64 (hash_structural_sample.hash hash-left)]
    [same-right : i64 (hash_structural_sample.hash hash-right)]
    [field-hash : i64 (hash_structural_sample.hash field-different)]
    [variant-hash : i64 (hash_structural_sample.hash variant-different)]
    [empty-variant-hash : i64 (hash_structural_sample.hash empty-variant)]
    [text-hash : i64 (hash_structural_sample.hash text-choice)]
    [tuple-hash : i64 (hash_structural_tuple.hash ordered-tuple)]
    [tuple-reversed-hash : i64 (hash_structural_tuple.hash reversed-tuple)]
    [array-hash : i64 (hash_structural_array.hash ordered-array)]
    [array-reversed-hash : i64 (hash_structural_array.hash reversed-array)]
    [empty-hash : i64 (hash_structural_empty.hash empty)]
    [evaluations : i64 0]
    [evaluated-once-hash : i64
      (hash_structural_sample.hash
        (begin
          (set! evaluations (+ evaluations 1))
          evaluated-once))]
    (begin
      (require
        (eq_structural_sample.eq equal-left equal-right)
        "generated hash equality fixture must compare equal")
      (require (= same-left same-right) "equal values must hash equally")
      (require
        (= evaluations 1)
        "generated hash must evaluate its input exactly once")
      (require
        (= evaluated-once-hash same-left)
        "one-evaluation wrapper must preserve the value hash")
      (require (!= same-left field-hash) "field values must affect the hash")
      (require (!= same-left variant-hash) "enum variants must affect the hash")
      (require
        (!= same-left empty-variant-hash)
        "empty enum variants must be distinct")
      (require (!= same-left text-hash) "enum payloads must affect the hash")
      (require
        (!= tuple-hash tuple-reversed-hash)
        "tuple element order must affect the hash")
      (require
        (!= array-hash array-reversed-hash)
        "array element order must affect the hash")
      (require (>= empty-hash 0) "empty aggregates must produce a valid hash")
      (require (= same-left 742111166) "nested hash golden value changed")
      (require (= tuple-hash 1095212616) "tuple hash golden value changed")
      (require (= array-hash 92115361) "array hash golden value changed")
      (require (= empty-hash 323376260) "empty hash golden value changed")
      (require (= (hash_unit.hash unit) 1442) "unit hash golden value changed")
      (require
        (!= (hash_bool.hash true) (hash_bool.hash false))
        "bool values affect the hash")
      (require
        (!= (hash_char.hash 'A') (hash_char.hash 'B'))
        "char values affect the hash")
      (require
        (= (hash_i64.hash -7) (hash_i64.hash -7))
        "i64 hashes deterministically")
      (require
        (= (hash_i32.hash (cast -7 : i32)) (hash_i32.hash (cast -7 : i32)))
        "i32 hashes deterministically")
      (require
        (= (hash_i16.hash (cast -7 : i16)) (hash_i16.hash (cast -7 : i16)))
        "i16 hashes deterministically")
      (require
        (= (hash_i8.hash (cast -7 : i8)) (hash_i8.hash (cast -7 : i8)))
        "i8 hashes deterministically")
      (require
        (= (hash_u64.hash (cast 7 : u64)) (hash_u64.hash (cast 7 : u64)))
        "u64 hashes deterministically")
      (require
        (= (hash_u32.hash (cast 7 : u32)) (hash_u32.hash (cast 7 : u32)))
        "u32 hashes deterministically")
      (require
        (= (hash_u16.hash (cast 7 : u16)) (hash_u16.hash (cast 7 : u16)))
        "u16 hashes deterministically")
      (require
        (= (hash_u8.hash (cast 7 : u8)) (hash_u8.hash (cast 7 : u8)))
        "u8 hashes deterministically")
      (require
        (=
          (hash_string.hash "same")
          (hash_string.hash (string_mod.append "sa" "me")))
        "equal distinct owned strings must hash equally")
      0)))