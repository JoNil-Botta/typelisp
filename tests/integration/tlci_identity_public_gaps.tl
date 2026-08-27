;; Exhaustive embedded-stdlib TLCI differential witness for public generator
;; and mutation macros that the broader compiler/stdlib corpus does not reach
;; together. Keep each call semantically live so route evidence cannot become
;; vacuous under later fixture cleanup. Refs #6609.
(import stdlib.math)
(import stdlib.queue)
(import stdlib.set)
(import stdlib.sort)
(import stdlib.str_cat_runtime)
(import stdlib.text_buf)
(import stdlib.vector)
(import (queue.deque i64) as queue_i64)
(import (set.set i64) as set_i64)
(import (vector.vector i64) as vector_i64)
(import (sort.vec i64) as sort_i64)

(defstruct TlciIdentityFieldWitness
  (value i64))

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [buf : text_buf.TextBuf (text_buf.empty)]
    [q : queue_i64.Deque (queue_i64.new)]
    [keys : set_i64.Set (set_i64.new)]
    [power : f64 (math.pow 2.0 3.0)]
    [exp-value : f64 (math.exp 0.0)]
    [log-value : f64 (math.log 1.0)]
    [sqrt-value : f64 (math.sqrt 9.0)]
    [joined : String (str_cat_runtime.str-cat "a" "b")]
    [field-witness : TlciIdentityFieldWitness (TlciIdentityFieldWitness 0)]
    (begin
      (__tl-project-set-field field-witness value 42)
      (__tl_array-push! items 42)
      (text_buf.append-char! buf 'x')
      (text_buf.append-int! buf 7)
      (text_buf.clear! buf)
      (text_buf.reset! buf)
      (queue_i64.push-back! q (array-ref items 0))
      (set_i64.insert! keys 42)
      (if (and
        (= (queue_i64.len (& q)) 1)
        (= (set_i64.len (& keys)) 1)
        (= power 8.0)
        (= exp-value 1.0)
        (= log-value 0.0)
        (= sqrt-value 3.0)
        (= (string-length joined) 2)
        (= field-witness.value 42)
        (= (string-length (text_buf.render buf)) 0))
        42
        1))))