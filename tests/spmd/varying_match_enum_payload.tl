;; SPMD varying-match enum payload corpus (#3776, #5152): tag-only and payload
;; arms inside a foreach body. The n = 13 length exercises mixed arms plus the
;; AVX2/AVX-512 tail.
(import stdlib.array)

(defenum Choice
  (Zero)
  (Add i64)
  (Scale i64)
  (Flip i64))

(define (choice-at [i : i64]) : Choice
  (match (% i 4)
    [0 Zero]
    [1 (Add (+ i 2))]
    [2 (Scale (+ i 3))]
    [_ (Flip (- i 1))]))

(define (init-choices [items : (Array Choice)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! items i (choice-at i))
        (set! i (+ i 1))))))

(define (fill-match [items : (Array Choice)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [choice : Choice (array-ref items i)]
      (array-set!
        out
        i
        (match choice
          [Zero 7]
          [(Add value) (+ value i)]
          [(Scale value)
            (match (% i 3)
              [0 (* value 2)]
              [1 (+ value 10)]
              [_ (+ value 20)])]
          [(Flip value)
            (if (= (% i 2) 0)
              (- 100 value)
              (+ 100 value))])))))

(define (fill-scalar [items : (Array Choice)] [out : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (let
          [choice : Choice (array-ref items i)]
          (array-set!
            out
            i
            (match choice
              [Zero 7]
              [(Add value) (+ value i)]
              [(Scale value)
                (match (% i 3)
                  [0 (* value 2)]
                  [1 (+ value 10)]
                  [_ (+ value 20)])]
              [(Flip value)
                (if (= (% i 2) 0)
                  (- 100 value)
                  (+ 100 value))])))
        (set! i (+ i 1))))))

(define (arrays-eq [a : (Array i64)] [b : (Array i64)] [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (!= (array-ref a i) (array-ref b i))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (let
    [n : i64 13]
    [items : (Array Choice) (array.make-array Choice n)]
    [got : (Array i64) (array.make-array i64 n)]
    [want : (Array i64) (array.make-array i64 n)]
    (begin
      (init-choices items n)
      (fill-match items got n)
      (fill-scalar items want n)
      (if (arrays-eq got want n)
        42
        1))))