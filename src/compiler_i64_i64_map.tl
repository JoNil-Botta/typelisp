;; compiler_i64_i64_map.tl - shared compiler-local i64 -> i64 map wrapper.
(module compiler_i64_i64_map)

(import stdlib.hashmap)
(import (hashmap i64 i64) as gen)

(defstruct Map
  (inner gen.Map))

(defenum Lookup
  (LookupMissing)
  (LookupFound i64))

(defenum RemoveResult
  (RemoveOk)
  (RemoveMissing))

(define (with-capacity [capacity : i64]) : Map
  (Map (gen.with-capacity capacity)))

(define (inner-mut [map : (&mut map Map)]) : (&mut map gen.Map)
  (&mut (struct-get map inner)))

(define (lookup-from-gen [lookup : gen.Lookup]) : Lookup
  (match lookup
    [(gen.LookupFound value) (LookupFound value)]
    [(gen.LookupMissing) (LookupMissing)]))

(define (remove-from-gen [result : gen.RemoveResult]) : RemoveResult
  (match result
    [(gen.RemoveOk) (RemoveOk)]
    [(gen.RemoveMissing) (RemoveMissing)]))

(define (get [map : (& map Map)] [key : i64]) : Lookup
  (lookup-from-gen (gen.get (& (struct-get map inner)) key)))

(define (contains? [map : (& map Map)] [key : i64]) : bool
  (gen.contains? (& (struct-get map inner)) key))

(define (insert [map : (&mut map Map)] [key : i64] [value : i64]) : unit
  (gen.insert (inner-mut map) key value))

(define (remove [map : (&mut map Map)] [key : i64]) : RemoveResult
  (remove-from-gen (gen.remove (inner-mut map) key)))