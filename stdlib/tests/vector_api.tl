(import "stdlib/test.tl")
(import "stdlib/vector.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

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

(define (string-pop-ok? [p : StringVecPop]) : bool
  (match p
    [(StringVecPopOk _ _) true]
    [(StringVecPopEmpty) false]))

(define (string-pop-value-or [p : StringVecPop] [fallback : String]) : String
  (match p
    [(StringVecPopOk value _) value]
    [(StringVecPopEmpty) fallback]))

(define (string-pop-vec-or [p : StringVecPop] [fallback : StringVec]) : StringVec
  (match p
    [(StringVecPopOk _ rest) rest]
    [(StringVecPopEmpty) fallback]))

(defenum VecApiTag
  (VecApiTagA i64)
  (VecApiTagB i64))

(define (vec-api-tag-score [tag : VecApiTag]) : i64
  (match tag
    [(VecApiTagA value) value]
    [(VecApiTagB value) (+ value 100)]))

(define (vec-api-fold-decimal [acc : i64] [value : i64]) : i64
  (+ (* acc 10) value))

(define (vec-api-double [value : i64]) : i64
  (* value 2))

(comptime-decl
  (:generated vector-family VecApiTagVec "VecApiTag")
  (defstruct VecApiTagVec
    (slots (Array VecApiTag))
    (len i64)))

(comptime-decl
  (:generated vector-family VecApiTagVecPop "VecApiTag")
  (defenum VecApiTagVecPop
    (VecApiTagVecPopEmpty)
    (VecApiTagVecPopOk VecApiTag VecApiTagVec)))

(comptime-decl
  (:generated vector-family vec-api-tag-vec-slots "VecApiTag")
  (define (vec-api-tag-vec-slots [v : VecApiTagVec]) : (Array VecApiTag)
    (struct-get v slots)))

(comptime-decl
  (:generated vector-family vec-api-tag-vec-len "VecApiTag")
  (define (vec-api-tag-vec-len [v : VecApiTagVec]) : i64
    (struct-get v len)))

(comptime-decl
  (:generated vector-family vec-api-tag-vec-capacity "VecApiTag")
  (define (vec-api-tag-vec-capacity [v : VecApiTagVec]) : i64
    (array-length (struct-get v slots))))

(comptime-decl
  (:generated vector-family vec-api-tag-vec-with-capacity "VecApiTag")
  (define (vec-api-tag-vec-with-capacity [capacity : i64]) : VecApiTagVec
    (let
      [cap : i64
        (if (< capacity 1)
          1
          capacity)]
      (VecApiTagVec (make-array VecApiTag cap) 0))))

(comptime-decl
  (:generated vector-family vec-api-tag-vec-get "VecApiTag")
  (define (vec-api-tag-vec-get
    [v : VecApiTagVec]
    [index : i64]
    [fallback : VecApiTag]) : VecApiTag
    (if (if (>= index 0)
      (< index (vec-api-tag-vec-len v))
      false)
      (array-ref (vec-api-tag-vec-slots v) index)
      fallback)))

(comptime-decl
  (:generated vector-family vec-api-tag-vec-set! "VecApiTag")
  (define (vec-api-tag-vec-set!
    [v : VecApiTagVec]
    [index : i64]
    [value : VecApiTag]) : VecApiTagVec
    (begin
      (if (if (>= index 0)
        (< index (vec-api-tag-vec-len v))
        false)
        (array-set! (vec-api-tag-vec-slots v) index value)
        unit)
      v)))

(comptime-decl
  (:generated vector-family vec-api-tag-vec-copy-range "VecApiTag")
  (define (vec-api-tag-vec-copy-range
    [dst : (Array VecApiTag)]
    [src : (Array VecApiTag)]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (array-set! dst index (array-ref src index))
        (vec-api-tag-vec-copy-range dst src (+ index 1) count)))))

(comptime-decl
  (:generated vector-family vec-api-tag-vec-grow "VecApiTag")
  (define (vec-api-tag-vec-grow [v : VecApiTagVec]) : VecApiTagVec
    (let
      [n : i64 (vec-api-tag-vec-len v)]
      [bigger : (Array VecApiTag)
        (make-array VecApiTag (* (vec-api-tag-vec-capacity v) 2))]
      (begin
        (vec-api-tag-vec-copy-range bigger (vec-api-tag-vec-slots v) 0 n)
        (VecApiTagVec bigger n)))))

(comptime-decl
  (:generated vector-family vec-api-tag-vec-push "VecApiTag")
  (define (vec-api-tag-vec-push [v : VecApiTagVec] [value : VecApiTag]) : VecApiTagVec
    (if (< (vec-api-tag-vec-len v) (vec-api-tag-vec-capacity v))
      (let
        [slots : (Array VecApiTag) (vec-api-tag-vec-slots v)]
        (begin
          (array-set! slots (vec-api-tag-vec-len v) value)
          (VecApiTagVec slots (+ (vec-api-tag-vec-len v) 1))))
      (vec-api-tag-vec-push (vec-api-tag-vec-grow v) value))))

(comptime-decl
  (:generated vector-family vec-api-tag-vec-pop "VecApiTag")
  (define (vec-api-tag-vec-pop [v : VecApiTagVec]) : VecApiTagVecPop
    (if (<= (vec-api-tag-vec-len v) 0)
      (VecApiTagVecPopEmpty)
      (let
        [last-index : i64 (- (vec-api-tag-vec-len v) 1)]
        (VecApiTagVecPopOk
          (array-ref (vec-api-tag-vec-slots v) last-index)
          (VecApiTagVec (vec-api-tag-vec-slots v) last-index))))))

(comptime-decl
  (:generated vector-family vec-api-tag-vec-to-array "VecApiTag")
  (define (vec-api-tag-vec-to-array [v : VecApiTagVec]) : (Array VecApiTag)
    (let
      [n : i64 (vec-api-tag-vec-len v)]
      [out : (Array VecApiTag) (make-array VecApiTag n)]
      (begin
        (vec-api-tag-vec-copy-range out (vec-api-tag-vec-slots v) 0 n)
        out))))

(define (tag-pop-ok? [p : VecApiTagVecPop]) : bool
  (match p
    [(VecApiTagVecPopOk _ _) true]
    [(VecApiTagVecPopEmpty) false]))

(define (tag-pop-score-or [p : VecApiTagVecPop] [fallback : i64]) : i64
  (match p
    [(VecApiTagVecPopOk value _) (vec-api-tag-score value)]
    [(VecApiTagVecPopEmpty) fallback]))

(define (tag-pop-vec-or [p : VecApiTagVecPop] [fallback : VecApiTagVec]) : VecApiTagVec
  (match p
    [(VecApiTagVecPopOk _ rest) rest]
    [(VecApiTagVecPopEmpty) fallback]))

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
    ;; --- I64Vec higher-order fold/map helpers (#2067) ---
    (let
      [src : (Array i64) (make-array i64 5)]
      (begin
        (array-set! src 0 1)
        (array-set! src 1 2)
        (array-set! src 2 3)
        (array-set! src 3 4)
        (array-set! src 4 5)
        (let
          [hv : I64Vec (i64-vec-from-array src 5)]
          (begin
            (assert-i64-eq
              (i64-vec-fold hv 0 vec-api-fold-decimal)
              12345
              "fold named function preserves order")
            (assert-i64-eq
              (i64-vec-fold-from hv 2 10 vec-api-fold-decimal)
              10345
              "fold-from starts at index")
            (assert-i64-eq
              (i64-vec-fold (i64-vec-new) 77 vec-api-fold-decimal)
              77
              "fold empty returns initial")
            (let
              [empty-mapped : I64Vec (i64-vec-map (i64-vec-new) vec-api-double)]
              (begin
                (assert-i64-eq (i64-vec-len empty-mapped) 0 "map empty len 0")
                (assert-true
                  (>= (i64-vec-capacity empty-mapped) 1)
                  "map empty remains growable")))
            (let
              [doubled : I64Vec (i64-vec-map hv vec-api-double)]
              (begin
                (assert-i64-eq (i64-vec-len doubled) 5 "map len 5")
                (assert-i64-eq
                  (i64-vec-capacity doubled)
                  8
                  "map output grows through push")
                (assert-i64-eq (i64-vec-get doubled 0 -1) 2 "map order 0")
                (assert-i64-eq (i64-vec-get doubled 4 -1) 10 "map order 4")))
            (let
              [suffix : I64Vec (i64-vec-map-from hv 2 vec-api-double)]
              (begin
                (assert-i64-eq (i64-vec-len suffix) 3 "map-from len 3")
                (assert-i64-eq
                  (i64-vec-get suffix 0 -1)
                  6
                  "map-from first suffix")
                (assert-i64-eq
                  (i64-vec-get suffix 2 -1)
                  10
                  "map-from last suffix")))
            (let
              [bias : i64 7]
              [biased : I64Vec
                (i64-vec-map
                  hv
                  (lambda ([x : i64]) : i64
                    (+ x bias)))]
              (begin
                (assert-i64-eq
                  (i64-vec-get biased 0 -1)
                  8
                  "map scalar-capturing lambda first")
                (assert-i64-eq
                  (i64-vec-get biased 4 -1)
                  12
                  "map scalar-capturing lambda last")))))))
    ;; --- generated StringVec: growth, mutation, pop, snapshot, reverse ---
    (let
      [sv2 : StringVec
        (string-vec-push
          (string-vec-push (string-vec-with-capacity 2) "alpha")
          "beta")]
      (begin
        (assert-i64-eq (string-vec-len sv2) 2 "string two pushes -> len 2")
        (assert-i64-eq (string-vec-capacity sv2) 2 "string capacity unchanged")
        (assert-owned-string-eq
          (string-vec-get sv2 0 "missing")
          "alpha"
          "string get 0")
        (assert-owned-string-eq
          (string-vec-last sv2 "missing")
          "beta"
          "string last")
        (let
          [sv3 : StringVec (string-vec-push sv2 "gamma")]
          (begin
            (assert-i64-eq (string-vec-len sv3) 3 "string third push len")
            (assert-i64-eq (string-vec-capacity sv3) 4 "string grow capacity")
            (assert-true
              (string-vec-contains? sv3 "beta")
              "string contains beta")
            (let
              [sv4 : StringVec (string-vec-set! sv3 1 "BETA")]
              (begin
                (assert-owned-string-eq
                  (string-vec-get sv4 1 "missing")
                  "BETA"
                  "string set! 1")
                (let
                  [popped : StringVecPop (string-vec-pop sv4)]
                  (begin
                    (assert-true (string-pop-ok? popped) "string pop ok")
                    (assert-owned-string-eq
                      (string-pop-value-or popped "missing")
                      "gamma"
                      "string pop value")
                    (let
                      [rest : StringVec (string-pop-vec-or popped sv4)]
                      (begin
                        (assert-i64-eq
                          (string-vec-len rest)
                          2
                          "string pop shrinks")
                        (let
                          [snap : (Array String) (string-vec-to-array rest)]
                          (begin
                            (assert-i64-eq
                              (array-length snap)
                              2
                              "string snapshot length")
                            (assert-owned-string-eq
                              (array-ref snap 1)
                              "BETA"
                              "string snapshot value")
                            (array-set! snap 1 "changed")
                            (assert-owned-string-eq
                              (string-vec-get rest 1 "missing")
                              "BETA"
                              "string snapshot independent")))
                        (let
                          [rv : StringVec (string-vec-reverse! rest)]
                          (begin
                            (assert-owned-string-eq
                              (string-vec-get rv 0 "missing")
                              "BETA"
                              "string reverse first")
                            (assert-owned-string-eq
                              (string-vec-get rv 1 "missing")
                              "alpha"
                              "string reverse second")))))))))))))
    ;; --- generated nominal enum payload vector witness ---
    (let
      [tv2 : VecApiTagVec
        (vec-api-tag-vec-push
          (vec-api-tag-vec-push
            (vec-api-tag-vec-with-capacity 1)
            (VecApiTagA 1))
          (VecApiTagB 2))]
      (begin
        (assert-i64-eq (vec-api-tag-vec-len tv2) 2 "tag vec len")
        (assert-i64-eq (vec-api-tag-vec-capacity tv2) 2 "tag vec grew")
        (assert-i64-eq
          (vec-api-tag-score (vec-api-tag-vec-get tv2 1 (VecApiTagA 0)))
          102
          "tag vec get")
        (let
          [tv3 : VecApiTagVec (vec-api-tag-vec-set! tv2 0 (VecApiTagB 7))]
          (begin
            (assert-i64-eq
              (vec-api-tag-score (vec-api-tag-vec-get tv3 0 (VecApiTagA 0)))
              107
              "tag vec set!")
            (let
              [popped : VecApiTagVecPop (vec-api-tag-vec-pop tv3)]
              (begin
                (assert-true (tag-pop-ok? popped) "tag pop ok")
                (assert-i64-eq (tag-pop-score-or popped -1) 102 "tag pop value")
                (let
                  [rest : VecApiTagVec (tag-pop-vec-or popped tv3)]
                  (begin
                    (assert-i64-eq (vec-api-tag-vec-len rest) 1 "tag pop len")
                    (let
                      [snap : (Array VecApiTag) (vec-api-tag-vec-to-array rest)]
                      (begin
                        (assert-i64-eq
                          (array-length snap)
                          1
                          "tag snapshot length")
                        (assert-i64-eq
                          (vec-api-tag-score (array-ref snap 0))
                          107
                          "tag snapshot value")
                        (array-set! snap 0 (VecApiTagA 99))
                        (assert-i64-eq
                          (vec-api-tag-score
                            (vec-api-tag-vec-get rest 0 (VecApiTagA 0)))
                          107
                          "tag snapshot independent")))))))))))
    42))