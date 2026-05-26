(import "stdlib/test.tl")

(import "stdlib/vector.tl")

;; Predicate/extractor helpers return concrete bool/i64 (no panic in a match
;; arm) so the module typechecks on every stage0, independent of the never-type.
(define (pop-ok? [p : I64VecPop]) : bool
  (match p
    [(I64VecPopOk _ _) true]
    [(I64VecPopEmpty) false]))

(define (pop-value-or [p : I64VecPop] [fallback : i64]) : i64
  (match p
    [(I64VecPopOk value _) value]
    [(I64VecPopEmpty) fallback]))

(define (pop-vec-or [p : I64VecPop] [fallback : I64Vec]) : I64Vec
  (match p
    [(I64VecPopOk _ rest) rest]
    [(I64VecPopEmpty) fallback]))

(define (main) : i64
  (begin
    ;; --- empty vector: len/capacity/is-empty? ---
    (let
      [empty : I64Vec (i64-vec-with-capacity 2)]
      (begin
        (assert-i64-eq (i64-vec-len empty) 0 "empty len 0")
        (assert-i64-eq (i64-vec-capacity empty) 2 "empty capacity 2")
        (assert-true (i64-vec-is-empty? empty) "empty is-empty?")
        ;; out-of-range reads fall back
        (assert-i64-eq (i64-vec-get empty 0 -1) -1 "empty get 0 fallback")
        (assert-i64-eq (i64-vec-last empty -1) -1 "empty last fallback")))
    ;; --- non-positive capacity is clamped to 1 ---
    (assert-i64-eq
      (i64-vec-capacity (i64-vec-with-capacity 0))
      1
      "zero capacity clamps to 1")
    (assert-true (>= (i64-vec-capacity (i64-vec-new)) 1) "new has capacity")
    ;; --- push within capacity: no growth ---
    (let
      [v2 : I64Vec
        (i64-vec-push (i64-vec-push (i64-vec-with-capacity 2) 10) 20)]
      (begin
        (assert-i64-eq (i64-vec-len v2) 2 "two pushes -> len 2")
        (assert-i64-eq (i64-vec-capacity v2) 2 "still capacity 2")
        (assert-i64-eq (i64-vec-get v2 0 -1) 10 "get 0 -> 10")
        (assert-i64-eq (i64-vec-get v2 1 -1) 20 "get 1 -> 20")
        (assert-i64-eq (i64-vec-last v2 -1) 20 "last -> 20")
        ;; index at len and a negative index both fall back
        (assert-i64-eq (i64-vec-get v2 2 -1) -1 "get at len fallback")
        (assert-i64-eq (i64-vec-get v2 -1 -1) -1 "get negative fallback")
        ;; --- push past capacity: grows, preserves prefix ---
        (let
          [v3 : I64Vec (i64-vec-push v2 30)]
          (begin
            (assert-i64-eq (i64-vec-len v3) 3 "third push -> len 3")
            (assert-i64-eq (i64-vec-capacity v3) 4 "grew to capacity 4")
            (assert-i64-eq (i64-vec-get v3 0 -1) 10 "prefix preserved: 0 -> 10")
            (assert-i64-eq (i64-vec-get v3 1 -1) 20 "prefix preserved: 1 -> 20")
            (assert-i64-eq (i64-vec-get v3 2 -1) 30 "new element: 2 -> 30")
            (assert-i64-eq (i64-vec-last v3 -1) 30 "last -> 30")
            ;; --- set! mutates in place within bounds ---
            (let
              [v4 : I64Vec (i64-vec-set! v3 1 99)]
              (begin
                (assert-i64-eq (i64-vec-get v4 1 -1) 99 "set! 1 -> 99")
                (assert-i64-eq (i64-vec-len v4) 3 "set! keeps len")
                ;; out-of-range set! is a no-op
                (i64-vec-set! v4 5 7)
                (assert-i64-eq
                  (i64-vec-get v4 5 -1)
                  -1
                  "set! out of range no-op")
                ;; --- pop: last element + shrunk vector ---
                (let
                  [popped : I64VecPop (i64-vec-pop v4)]
                  (begin
                    (assert-true (pop-ok? popped) "pop ok")
                    (assert-i64-eq
                      (pop-value-or popped -1)
                      30
                      "pop value -> 30")
                    (let
                      [rest : I64Vec (pop-vec-or popped v4)]
                      (begin
                        (assert-i64-eq (i64-vec-len rest) 2 "pop shrinks len")
                        (assert-i64-eq
                          (i64-vec-last rest -1)
                          99
                          "rest last -> 99")))))))))))
    ;; --- pop on an empty vector is Empty ---
    (let
      [pe : I64VecPop (i64-vec-pop (i64-vec-with-capacity 1))]
      (begin
        (assert-true (not (pop-ok? pe)) "empty pop not ok")
        (assert-i64-eq (pop-value-or pe -1) -1 "empty pop value fallback")))
    ;; --- from-array / to-array round-trip ---
    (let
      [src : (Array i64) (make-array i64 3)]
      [unit-begin : unit
        (begin
          (array-set! src 0 5)
          (array-set! src 1 7)
          (array-set! src 2 9))]
      [v5 : I64Vec (i64-vec-from-array src 3)]
      (begin
        (assert-i64-eq (i64-vec-len v5) 3 "from-array len")
        (assert-i64-eq (i64-vec-get v5 0 -1) 5 "from-array 0")
        (assert-i64-eq (i64-vec-get v5 1 -1) 7 "from-array 1")
        (assert-i64-eq (i64-vec-get v5 2 -1) 9 "from-array 2")
        ;; from-array with count 0 yields empty vector (capacity 1)
        (let
          [v0 : I64Vec (i64-vec-from-array src 0)]
          (begin
            (assert-true (i64-vec-is-empty? v0) "from-array count 0 empty")
            (assert-i64-eq (i64-vec-capacity v0) 1 "from-array count 0 cap 1")))
        ;; to-array snapshot preserves live prefix exactly
        (let
          [dst : (Array i64) (i64-vec-to-array v5)]
          (begin
            (assert-i64-eq (array-length dst) 3 "to-array len")
            (assert-i64-eq (array-ref dst 0) 5 "to-array 0")
            (assert-i64-eq (array-ref dst 1) 7 "to-array 1")
            (assert-i64-eq (array-ref dst 2) 9 "to-array 2")))))
    ;; --- extend in order ---
    (let
      [src : (Array i64) (make-array i64 3)]
      [unit-begin : unit
        (begin
          (array-set! src 0 1)
          (array-set! src 1 2)
          (array-set! src 2 3))]
      [base : I64Vec (i64-vec-push (i64-vec-new) 0)]
      [extended : I64Vec (i64-vec-extend base src 3)]
      (begin
        (assert-i64-eq (i64-vec-len extended) 4 "extend len")
        (assert-i64-eq (i64-vec-get extended 0 -1) 0 "extend order 0")
        (assert-i64-eq (i64-vec-get extended 1 -1) 1 "extend order 1")
        (assert-i64-eq (i64-vec-get extended 2 -1) 2 "extend order 2")
        (assert-i64-eq (i64-vec-get extended 3 -1) 3 "extend order 3")
        ;; extend with count 0 is identity
        (let
          [same : I64Vec (i64-vec-extend extended src 0)]
          (assert-i64-eq (i64-vec-len same) 4 "extend count 0 identity"))))
    ;; --- reverse! ---
    (let
      [v6 : I64Vec (i64-vec-new)]
      [v6p : I64Vec (i64-vec-push (i64-vec-push (i64-vec-push v6 1) 2) 3)]
      [r6 : I64Vec (i64-vec-reverse! v6p)]
      (begin
        (assert-i64-eq (i64-vec-get r6 0 -1) 3 "reverse 3-element 0")
        (assert-i64-eq (i64-vec-get r6 1 -1) 2 "reverse 3-element 1")
        (assert-i64-eq (i64-vec-get r6 2 -1) 1 "reverse 3-element 2")))
    ;; reverse! on empty / single is identity
    (let
      [ve : I64Vec (i64-vec-reverse! (i64-vec-new))]
      (begin
        (assert-true (i64-vec-is-empty? ve) "reverse empty stays empty")
        (let
          [vs : I64Vec (i64-vec-reverse! (i64-vec-push (i64-vec-new) 42))]
          (assert-i64-eq (i64-vec-get vs 0 -1) 42 "reverse single stays single"))))
    ;; reverse! on two elements swaps
    (let
      [v2 : I64Vec (i64-vec-push (i64-vec-push (i64-vec-new) 7) 8)]
      [r2 : I64Vec (i64-vec-reverse! v2)]
      (begin
        (assert-i64-eq (i64-vec-get r2 0 -1) 8 "reverse 2-element 0")
        (assert-i64-eq (i64-vec-get r2 1 -1) 7 "reverse 2-element 1")))
    ;; --- sum ---
    (assert-i64-eq (i64-vec-sum (i64-vec-new)) 0 "sum empty")
    (let
      [v7 : I64Vec (i64-vec-push (i64-vec-push (i64-vec-new) 10) 20)]
      (assert-i64-eq (i64-vec-sum v7) 30 "sum two elements"))
    ;; --- contains? ---
    (let
      [v8 : I64Vec (i64-vec-new)]
      [v8p : I64Vec (i64-vec-push (i64-vec-push v8 5) 9)]
      (begin
        (assert-true (i64-vec-contains? v8p 5) "contains first")
        (assert-true (i64-vec-contains? v8p 9) "contains last")
        (assert-true (not (i64-vec-contains? v8p 7)) "does not contain missing")))
    (assert-true (not (i64-vec-contains? (i64-vec-new) 0)) "empty does not contain")
    42))
