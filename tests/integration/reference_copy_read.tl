(import stdlib.arena)
(import stdlib.profile)
(import stdlib.test)

(defstruct Pair
  (a i64)
  (b i64))

(defstruct Wide
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(defstruct Outer
  (item Wide)
  (tail i64))

(defstruct Empty
  (value unit))

(defstruct Store
  (items (__tl_dyn-array Pair)))

(defenum Row
  (RowValue Pair))

(defenum Choice
  (Value Wide)
  (None))

(define calls : i64
  0)

(define (pair-return [p : (& p Pair)]) : Pair
  (deref p))

(define (pair-mut-return [p : (&mut p Pair)]) : Pair
  (deref p))

(define (pair-typed [p : (& p Pair)]) : Pair
  (let
    [copy : Pair (deref p)]
    copy))

(define (pair-inferred [p : (& p Pair)]) : Pair
  (let
    [copy (deref p)]
    copy))

(define (pair-sum [value : Pair]) : i64
  (+ value.a value.b))

(define (pair-call [p : (& p Pair)]) : i64
  (pair-sum (deref p)))

(define (wide-return [p : (& p Wide)]) : Wide
  (deref p))

(define (wide-mut-return [p : (&mut p Wide)]) : Wide
  (deref p))

(define (wide-typed [p : (& p Wide)]) : Wide
  (let
    [copy : Wide (deref p)]
    copy))

(define (wide-inferred [p : (& p Wide)]) : Wide
  (let
    [copy (deref p)]
    copy))

(define (wide-sum [value : Wide]) : i64
  (+ value.a value.d))

(define (wide-call [p : (& p Wide)]) : i64
  (wide-sum (deref p)))

(define (tuple-return [p : (& p (Tuple i64 i64 i64 i64))]) : (Tuple
    i64
    i64
    i64
    i64)
  (deref p))

(define (array-return [p : (& p (Array i64 4))]) : (Array i64 4)
  (deref p))

(define (choice-return [p : (& p Choice)]) : Choice
  (deref p))

(define (empty-return [p : (& p Empty)]) : Empty
  (+= calls 1)
  (deref p))

(define (read-row [store : (& store Store)]) : Row
  (RowValue (array-ref store.items 0)))

(define (count-reference [p : (& p Wide)]) : (& p Wide)
  (+= calls 1)
  p)

(define (change-nested [p : (&mut p Outer)]) : unit
  (let
    [q : (&mut p Wide) (&mut (deref p).item)]
    (set! q.a 42)
    (test.assert-i64-eq q.a 42 "nested borrowed write")))

(define (release-and-read
  [value : Wide]
  [owner : (arena.Arena r) (:invalidate r)]) : i64
  (arena.destroy-safe! owner)
  (+ value.a value.d))

(define (check-wide-copies) : unit
  (let
    [source : Wide (Wide 20 2 3 22)]
    [before : i64 (profile.alloc-total)]
    [typed : Wide (deref (& source))]
    [inferred (deref (&mut source))]
    [returned (wide-return (& source))]
    [mut-returned (wide-mut-return (&mut source))]
    [typed-returned (wide-typed (& source))]
    [inferred-returned (wide-inferred (& source))]
    (test.assert-i64-eq
      (profile.alloc-total)
      before
      "whole reads use frame storage")
    (test.assert-i64-eq (wide-call (& source)) 42 "by-value argument")
    (set! source.a 100)
    (set! typed.d 40)
    (test.assert-i64-eq source.d 22 "copy writes leave source unchanged")
    (test.assert-i64-eq typed.a 20 "source writes leave typed copy unchanged")
    (test.assert-i64-eq
      inferred.a
      20
      "source writes leave inferred copy unchanged")
    (test.assert-i64-eq (wide-sum returned) 42 "direct return")
    (test.assert-i64-eq (wide-sum mut-returned) 42 "mutable reference return")
    (test.assert-i64-eq (wide-sum typed-returned) 42 "typed binding return")
    (test.assert-i64-eq
      (wide-sum inferred-returned)
      42
      "inferred binding return")))

(define (check-projections) : unit
  (let
    [source : Outer (Outer (Wide 20 2 3 22) 5)]
    [copy (deref (& source)).item]
    [constructed : Outer (Outer (deref (& source.item)) 9)]
    [stored : Wide (Wide 0 0 0 0)]
    (test.assert-i64-eq (wide-sum stored) 0 "initial store value")
    (set! stored (deref (& source.item)))
    (set! source.item.a 100)
    (set! copy.d 40)
    (test.assert-i64-eq copy.a 20 "nested field copy")
    (test.assert-i64-eq source.item.d 22 "nested copy is independent")
    (test.assert-i64-eq (wide-sum constructed.item) 42 "constructor operand")
    (test.assert-i64-eq (wide-sum stored) 42 "assignment operand")
    (change-nested (&mut source))
    (test.assert-i64-eq source.item.a 42 "nested borrow keeps original place"))
  (let
    [store : Store (Store (__tl_make-array (Pair 20 22)))]
    (match (read-row (& store))
      [(RowValue value)
        (test.assert-i64-eq (pair-sum value) 42 "borrowed array into enum")]))
  (let
    [items : (__tl_dyn-array Wide) (__tl_make-array (Wide 20 2 3 22))]
    [copy (array-ref items 0)]
    (set! (array-ref items 0).a 100)
    (test.assert-i64-eq (wide-sum copy) 42 "whole array element read")))

(define (check-other-aggregates) : unit
  (let
    [source : (Tuple i64 i64 i64 i64) (tuple 20 2 3 22)]
    [copy (deref (& source))]
    [returned (tuple-return (& source))]
    (set! (tuple-ref source 0) 100)
    (set! (tuple-ref copy 3) 40)
    (test.assert-i64-eq (tuple-ref copy 0) 20 "tuple copy")
    (test.assert-i64-eq (tuple-ref source 3) 22 "tuple source")
    (test.assert-i64-eq
      (+ (tuple-ref returned 0) (tuple-ref returned 3))
      42
      "tuple return"))
  (let
    [source : (Array i64 4) (array 20 2 3 22)]
    [copy (deref (& source))]
    [returned (array-return (& source))]
    (set! (array-ref source 0) 100)
    (set! (array-ref copy 3) 40)
    (test.assert-i64-eq (array-ref copy 0) 20 "fixed array copy")
    (test.assert-i64-eq (array-ref source 3) 22 "fixed array source")
    (test.assert-i64-eq
      (+ (array-ref returned 0) (array-ref returned 3))
      42
      "fixed array return"))
  (let
    [source : Choice (Choice.Value (Wide 20 2 3 22))]
    [copy (deref (& source))]
    [returned (choice-return (& source))]
    (let
      [view : (&mut source Choice) (&mut source)]
      (set! (deref view) (Choice.Value (Wide 100 200 300 400))))
    (match copy
      [(Choice.Value value)
        (test.assert-i64-eq (wide-sum value) 42 "enum copy")]
      [(Choice.None) (test.assert-true false "enum tag preserved")])
    (match returned
      [(Choice.Value value)
        (test.assert-i64-eq (wide-sum value) 42 "enum return")]
      [(Choice.None) (test.assert-true false "returned enum tag preserved")]))
  (set! calls 0)
  (let
    [source : Empty (Empty unit)]
    [_copy (empty-return (& source))]
    [zero : (Array i64 0) (array)]
    [zero-copy (deref (& zero))]
    (test.assert-i64-eq calls 1 "zero-sized struct read is evaluated")
    (test.assert-i64-eq (array-length zero-copy) 0 "zero-sized fixed array")))

(define (check-evaluation) : unit
  (let
    [source : Wide (Wide 20 2 3 22)]
    (set! calls 0)
    (let
      [copy (deref (count-reference (& source)))]
      (test.assert-i64-eq calls 1 "whole receiver evaluated once")
      (test.assert-i64-eq (wide-sum copy) 42 "whole receiver value"))
    (test.assert-i64-eq
      (deref (count-reference (& source))).a
      20
      "scalar projection value")
    (test.assert-i64-eq calls 2 "projection receiver evaluated once")
    (let
      [first (deref (&mut source))]
      (set! source.a 7)
      (let
        [second (deref (&mut source))]
        (set! source.a 9)
        (test.assert-i64-eq first.a 20 "first read snapshot")
        (test.assert-i64-eq second.a 7 "second read snapshot")))))

(define (snapshot-oracle [n : i64]) : bool
  (let
    [source : Wide (Wide n (+ n 1) (+ n 2) (+ n 3))]
    [shared (deref (& source))]
    (set! source.b (+ n 5))
    (let
      [mutable (deref (&mut source))]
      (set! shared.a (- 0 n))
      (set! source.b 0)
      (and
        (= shared.a (- 0 n))
        (= shared.b (+ n 1))
        (= mutable.a n)
        (= mutable.b (+ n 5))
        (= source.a n)
        (= source.b 0)))))

(define (main) : i64
  (let
    [source : Pair (Pair 20 22)]
    (test.assert-i64-eq
      (pair-sum (pair-return (& source)))
      42
      "register return")
    (test.assert-i64-eq
      (pair-sum (pair-mut-return (&mut source)))
      42
      "register mutable return")
    (test.assert-i64-eq
      (pair-sum (pair-typed (& source)))
      42
      "register typed let")
    (test.assert-i64-eq
      (pair-sum (pair-inferred (& source)))
      42
      "register inferred let")
    (test.assert-i64-eq (pair-call (& source)) 42 "register argument"))
  (check-wide-copies)
  (check-projections)
  (check-other-aggregates)
  (check-evaluation)
  (let
    [n : i64 -8]
    (while (<= n 8)
      (test.assert-true
        (snapshot-oracle n)
        "shared/mutable copies agree with scalar oracle")
      (+= n 1)))
  (let
    [owner (arena.make)]
    [initial : Wide (Wide 20 2 3 22)]
    [source (in-arena owner (box initial))]
    (test.assert-i64-eq
      (release-and-read (deref (& (deref source))) owner)
      42
      "by-value copy survives source arena destruction"))
  42)