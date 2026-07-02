;; string_vec_core.tl - Shared generated String vector wrapper for selfhost code.
(module string_vec_core)

(import stdlib.vector)
(import (vector.vector String) as generated_string_vec)

(defstruct StringVector
  (items generated_string_vec.Vec))

(define (new) : StringVector
  (StringVector (generated_string_vec.new)))

(define (with-capacity [capacity : i64]) : StringVector
  (StringVector (generated_string_vec.with-capacity capacity)))

(define (len [v : (& v StringVector)]) : i64
  (generated_string_vec.len (& (struct-get v items))))

(define (is-empty? [v : (& v StringVector)]) : bool
  (generated_string_vec.is-empty? (& (struct-get v items))))

(define (get [v : (& v StringVector)] [index : i64] [fallback : String]) : String
  (generated_string_vec.get (& (struct-get v items)) index fallback))

(define (last [v : (& v StringVector)] [fallback : String]) : String
  (generated_string_vec.last (& (struct-get v items)) fallback))

(define (contains? [v : (& v StringVector)] [value : String]) : bool
  (generated_string_vec.contains? (& (struct-get v items)) value))

(define (push [v : (&mut v StringVector)] [value : String]) : unit
  (generated_string_vec.push (&mut (struct-get v items)) value))

(define (pop! [v : (&mut v StringVector)]) : unit
  (match (generated_string_vec.pop (&mut (struct-get v items)))
    [(generated_string_vec.Pop.Ok _) unit]
    [generated_string_vec.Pop.Empty unit]))