;; By-value global actuals retain their call-entry value when an inlined
;; callee writes the cell. A separate local borrow keeps mixed arguments live.
(import stdlib.iterator)
(import stdlib.test)

(defstruct Word
  (value i64))

(defstruct Pair
  (x i64)
  (y i64))

(defstruct Triple
  (x i64)
  (y i64)
  (z i64))

(defenum Tag
  (First)
  (Second))

(defenum Payload
  (Value i64)
  (Empty))

(define scalar : i64
  7)
(define word : Word
  (Word 7))
(define pair : Pair
  (Pair 7 8))
(define triple : Triple
  (Triple 7 8 9))
(define tag : Tag
  (First))
(define payload : Payload
  (Value 7))
(define calls : i64
  0)

(define (touch-scalar [local : (& r Word)] [copied : i64]) : i64
  (set! scalar 99)
  (+ local.value copied))

(define (touch-word [local : (& r Word)] [copied : Word]) : i64
  (set! word (Word 99))
  (+ local.value copied.value))

(define (touch-pair [local : (& r Word)] [copied : Pair]) : i64
  (set! pair (Pair 98 99))
  (+ local.value (+ copied.x copied.y)))

(define (touch-triple [local : (& r Word)] [copied : Triple]) : i64
  (set! triple (Triple 97 98 99))
  (+ local.value (+ copied.x (+ copied.y copied.z))))

(define (touch-tag [local : (& r Word)] [copied : Tag]) : i64
  (set! tag (Second))
  (+
    local.value
    (match copied
      [(First) 1]
      [(Second) 2])))

(define (touch-payload [local : (& r Word)] [copied : Payload]) : i64
  (set! payload (Value 99))
  (+
    local.value
    (match copied
      [(Value n) n]
      [(Empty) 0])))

(define (write-word!) : unit
  (set! word (Word 99)))

(define (transitive [local : (& r Word)] [copied : Word]) : i64
  (write-word!)
  (+ local.value copied.value))

(define (forward [local : (& r Word)] [copied : Word]) : i64
  (transitive local copied))

(define (branching [local : (& r Word)] [copied : Word] [flag : bool]) : i64
  (if flag
    (set! word (Word 98))
    (set! word (Word 99)))
  (+ local.value copied.value))

(define (duplicate [local : (& r Word)] [a : Word] [b : Word]) : i64
  (write-word!)
  (+ local.value (+ a.value b.value)))

(define (tick) : i64
  (+= calls 1)
  3)

(define (once [copied : Word] [n : i64]) : i64
  (write-word!)
  (+ copied.value n))

(define (write-borrowed-word! [_target : (&mut r Word)]) : unit
  (set! _target.value 99))

(define (borrowed-alias [target : (&mut r Word)] [copied : Word]) : i64
  (write-borrowed-word! target)
  copied.value)

(unsafe
  (define (aliased [ptr : (MutPtr Word)] [copied : Word]) : i64
    (unsafe
      (ptr-write! ptr (Word 99)))
    copied.value))

(define (check-values) : i64
  (let
    [local : Word (Word 10)]
    (for [n (iterator.range -2 4)]
      (set! scalar n)
      (set! word (Word n))
      (set! pair (Pair n (+ n 1)))
      (set! triple (Triple n (+ n 1) (+ n 2)))
      (set! tag (First))
      (set! payload (Value n))
      (unless (= (touch-scalar (& local) scalar) (+ 10 n)) (return 1))
      (unless (= (touch-word (& local) word) (+ 10 n)) (return 2))
      (unless (= (touch-pair (& local) pair) (+ 11 (* 2 n))) (return 3))
      (unless (= (touch-triple (& local) triple) (+ 13 (* 3 n))) (return 4))
      (unless (= (touch-tag (& local) tag) 11) (return 5))
      (unless (= (touch-payload (& local) payload) (+ 10 n)) (return 6))
      (set! word (Word n))
      (unless (= (forward (& local) word) (+ 10 n)) (return 7))
      (set! word (Word n))
      (unless (= (branching (& local) word (< n 0)) (+ 10 n)) (return 8))
      (set! word (Word n))
      (unless (= (duplicate (& local) word word) (+ 10 (* 2 n))) (return 9))
      (set! word (Word n))
      (set! calls 0)
      (unless (= (once word (tick)) (+ n 3)) (return 10))
      (unless (= calls 1) (return 11))
      (set! word (Word n))
      (unless
        (=
          (unsafe
            (aliased (ptr-addr-of word) word))
          n)
        (return 12))
      (unless (= word.value 99) (return 13))
      (set! word (Word n))
      (unless (= (borrowed-alias (&mut word) word) n) (return 14))
      (unless (= word.value 99) (return 15))))
  42)

(define (main) : i64
  (check-values))

(test
  inline-global-by-value
  (test.assert-i64-eq
    (check-values)
    42
    "callee writes preserve captured actuals"))