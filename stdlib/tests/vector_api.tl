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
    ;; --- from-array / to-array round-trip (#1212) ---
    (let
      [src : (Array i64) (make-array i64 3)]
      (begin
        (array-set! src 0 5)
        (array-set! src 1 6)
        (array-set! src 2 7)
        ;; from-array copies the live prefix [0, count)
        (let
          [fv : I64Vec (i64-vec-from-array src 3)]
          (begin
            (assert-i64-eq (i64-vec-len fv) 3 "from-array len 3")
            (assert-i64-eq (i64-vec-get fv 0 -1) 5 "from-array[0] = 5")
            (assert-i64-eq (i64-vec-get fv 2 -1) 7 "from-array[2] = 7")
            ;; sum + contains? over the live elements
            (assert-i64-eq (i64-vec-sum fv) 18 "sum 5+6+7 = 18")
            (assert-true (i64-vec-contains? fv 6) "contains 6")
            (assert-false (i64-vec-contains? fv 99) "does not contain 99")
            ;; to-array snapshot has exactly len elements and is independent
            (let
              [snap : (Array i64) (i64-vec-to-array fv)]
              (begin
                (assert-i64-eq (array-length snap) 3 "to-array length = len")
                (assert-i64-eq (array-ref snap 1) 6 "to-array[1] = 6")
                ;; mutating the snapshot does not affect the vector
                (array-set! snap 1 0)
                (assert-i64-eq
                  (i64-vec-get fv 1 -1)
                  6
                  "vector unaffected by snapshot mutation")))
            ;; reverse! reverses the live prefix in place
            (let
              [rv : I64Vec (i64-vec-reverse! fv)]
              (begin
                (assert-i64-eq (i64-vec-get rv 0 -1) 7 "reverse![0] = 7")
                (assert-i64-eq (i64-vec-get rv 2 -1) 5 "reverse![2] = 5")
                (assert-i64-eq (i64-vec-sum rv) 18 "reverse keeps sum")))))
        ;; from-array with non-positive count yields an empty, growable vector
        (let
          [ev : I64Vec (i64-vec-from-array src 0)]
          (begin
            (assert-true (i64-vec-is-empty? ev) "from-array 0 is empty")
            (assert-true
              (>= (i64-vec-capacity ev) 1)
              "empty from-array still growable")
            ;; extend pushes the first count elements (growing as needed)
            (let
              [xv : I64Vec (i64-vec-extend ev src 3)]
              (begin
                (assert-i64-eq (i64-vec-len xv) 3 "extend len 3")
                (assert-i64-eq (i64-vec-get xv 0 -1) 5 "extend[0] = 5")
                (assert-i64-eq (i64-vec-get xv 2 -1) 7 "extend[2] = 7")
                (assert-i64-eq (i64-vec-sum xv) 18 "extend sum 18")))))))
    42))