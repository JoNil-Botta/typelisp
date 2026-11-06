(define (first [a : i64] [_b : i64]) : i64
  a)

(define (write-99! [p : (MutPtr i64)]) : i64
  (unsafe
    (ptr-write! p 99))
  0)

(define (inc [x : i64]) : i64
  (+ x 1))

(define (dec [x : i64]) : i64
  (- x 1))

(define (write-dec! [p : (MutPtr (-> i64 i64))]) : i64
  (unsafe
    (ptr-write! p dec))
  41)

(define (argument [x : i64] [count : i64] [expose : bool] [oracle : bool]) : i64
  (let
    [y : i64 0]
    [q : (MutPtr i64)
      (unsafe
        (ptr-addr-of y))]
    [result : i64 0]
    [i : i64 0]
    (while (< i count)
      (when
        (> i 0)
        (set!
          result
          (if oracle
            (let
              [saved : i64 x]
              (first saved (write-99! q)))
            (first x (write-99! q)))))
      (when
        expose
        (set!
          q
          (unsafe
            (ptr-addr-of x))))
      (+= i 1))
    result))

(define (callee
  [f : (-> i64 i64)]
  [count : i64]
  [expose : bool]
  [oracle : bool]) : i64
  (let
    [g dec]
    [p : (MutPtr (-> i64 i64))
      (unsafe
        (ptr-addr-of g))]
    [result : i64 0]
    [i : i64 0]
    (while (< i count)
      (when
        (> i 0)
        (set!
          result
          (if oracle
            (let
              [saved f]
              (saved (write-dec! p)))
            ((ann f : (-> i64 i64)) (write-dec! p)))))
      (when
        expose
        (set!
          p
          (unsafe
            (ptr-addr-of f))))
      (+= i 1))
    result))

(defstruct Pair
  (left i64)
  (right i64))

(define (projection [count : i64]) : i64
  (let
    [pair : Pair (Pair 1 41)]
    [y : i64 0]
    [q : (MutPtr i64)
      (unsafe
        (ptr-addr-of y))]
    [result : i64 0]
    [i : i64 0]
    (while (< i count)
      (when (> i 0) (set! result (first pair.left (write-99! q))))
      (set!
        q
        (unsafe
          (ptr-addr-of pair.left)))
      (+= i 1))
    (+ result (- pair.right 41))))

(define (captured [count : i64]) : i64
  (let
    [x : i64 1]
    [run
      (lambda ([n : i64]) : i64
        (let
          [y : i64 0]
          [q : (MutPtr i64)
            (unsafe
              (ptr-addr-of y))]
          [result : i64 0]
          [i : i64 0]
          (while (< i n)
            (when (> i 0) (set! result (first x (write-99! q))))
            (set!
              q
              (unsafe
                (ptr-addr-of x)))
            (+= i 1))
          result))]
    (run count)))

;; An inner binding's exposure must not make the unrelated outer binding
;; exposed, or make a captured outer name share the inner binding's facts.
(define (shadowed [x : i64]) : i64
  (let
    [y : i64 0]
    [q : (MutPtr i64)
      (unsafe
        (ptr-addr-of y))]
    (let
      [x : i64 17]
      (unsafe
        (ptr-addr-of x))
      unit)
    (first x (write-99! q))))

(define (read-only-tail [x : i64]) : i64
  (let
    [q : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    (first
      x
      (unsafe
        (ptr-read q)))))

(define (main) : i64
  (let
    [counts : (Array i64 4) (array 0 1 2 4)]
    [index : i64 0]
    [ok : bool true]
    (while (< index (array-length counts))
      (let
        [count : i64 (array-ref counts index)]
        [want-argument : i64 (cond [(<= count 1) 0] [(= count 2) 1] [else 99])]
        [want-callee : i64 (cond [(<= count 1) 0] [(= count 2) 42] [else 40])]
        [unexposed-argument : i64
          (if (<= count 1)
            0
            1)]
        [unexposed-callee : i64
          (if (<= count 1)
            0
            42)]
        (set!
          ok
          (and
            ok
            (= (argument 1 count true false) want-argument)
            (= (argument 1 count true true) want-argument)
            (= (argument 1 count false false) unexposed-argument)
            (= (callee inc count true false) want-callee)
            (= (callee inc count true true) want-callee)
            (= (callee inc count false false) unexposed-callee)
            (= (projection count) want-argument)
            (= (captured count) want-argument))))
      (+= index 1))
    (if (and ok (= (shadowed 42) 42) (= (read-only-tail 42) 42))
      42
      1)))