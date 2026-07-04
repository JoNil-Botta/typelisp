;; compiler_string_i64_map.tl - shared compiler-local String -> i64 map wrapper.
;;
;; Several compiler modules need the generated collection API shape for the same
;; `String -> i64` map. Keeping the generated import in one source slice avoids
;; paying the module macro expansion cost at each user while preserving the
;; reader `&` / mutator `&mut` surface.
(module compiler_string_i64_map)

(import stdlib.hashmap)
(import (hashmap String i64) as gen)

(defstruct Map
  (inner gen.Map))

(define (with-capacity [capacity : i64]) : Map
  (Map (gen.with-capacity capacity)))

(define (inner-mut [map : (&mut map Map)]) : (&mut map gen.Map)
  (&mut (struct-get map inner)))

(define (len [map : (& map Map)]) : i64
  (gen.len (& (struct-get map inner))))

(define (capacity [map : (& map Map)]) : i64
  (gen.capacity (& (struct-get map inner))))

(define (contains-borrowed? [map : (& map Map)] [key : (& key str)]) : bool
  (gen.contains-borrowed? (& (struct-get map inner)) key))

(define (contains? [map : (& map Map)] [key : String]) : bool
  (gen.contains? (& (struct-get map inner)) key))

(define (insert [map : (&mut map Map)] [key : String] [value : i64]) : unit
  (gen.insert (inner-mut map) key value))