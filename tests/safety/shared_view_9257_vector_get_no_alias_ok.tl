;; #9257: Safe `vector` `get` and `last` on move-only owning aggregates and
;; `String` must return independent deep copies and never alias the vector's
;; live slots.
(import stdlib.eq)
(import stdlib.clone)
(import stdlib.string)
(import stdlib.vector)

(defstruct NamedCell
  (label String)
  (count i64))

(clone.gen-clone NamedCell)

(eq.gen NamedCell)

(import (vector.vector NamedCell) as nvec)
(import (vector.vector String) as svec)
(import (vector.vector i64 core) as ivec)

(define (main) : i64
  (let
    [v : nvec.Vec (nvec.new)]
    [words : svec.Vec (svec.new)]
    [nums : ivec.Vec (ivec.new)]
    (nvec.push! v (NamedCell (string.copy "orig") 10))
    (let
      [got : NamedCell (nvec.get (& v) 0 (NamedCell "" 0))]
      [tail : NamedCell (nvec.last (& v) (NamedCell "" 0))]
      [v-ref (& v)]
      [v-slice : (& v (Slice NamedCell)) (nvec.view v-ref)]
      [orig-ptr : u64
        (unsafe
          (ptr->int (string-data (& (array-ref v-slice 0).label))))]
      [got-ptr : u64
        (unsafe
          (ptr->int (string-data (& got.label))))]
      [tail-ptr : u64
        (unsafe
          (ptr->int (string-data (& tail.label))))]
      (when (= got-ptr orig-ptr) (return 1))
      (when (= tail-ptr orig-ptr) (return 2))
      (set! got.label "mutated-get")
      (set! tail.label "mutated-last")
      (when (not (string.eq (& (array-ref v-slice 0).label) "orig")) (return 3))
      (when (not (= (array-ref v-slice 0).count 10)) (return 4)))
    (svec.push! words (string.copy "hello"))
    (let
      [w1 : String (svec.get (& words) 0 "")]
      [w2 : String (svec.last (& words) "")]
      [w-slice : (& words (Slice String)) (svec.view (& words))]
      [orig-wptr : u64
        (unsafe
          (ptr->int (string-data (& (array-ref w-slice 0)))))]
      [w1-ptr : u64
        (unsafe
          (ptr->int (string-data (& w1))))]
      [w2-ptr : u64
        (unsafe
          (ptr->int (string-data (& w2))))]
      (when (= w1-ptr orig-wptr) (return 5))
      (when (= w2-ptr orig-wptr) (return 6))
      (when (not (string.eq (& w1) "hello")) (return 7))
      (when (not (string.eq (& w2) "hello")) (return 8)))
    (ivec.push! nums 42)
    (if (= (ivec.get (& nums) 0 0) 42)
      42
      9)))