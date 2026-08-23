;; Regression for #5953. A scalar snapshot head crosses calls while each
;; extension writes indexed global storage and returns the new immutable head.
;; Keep raw, one-field-struct, and single-variant-enum forms together so opt2
;; cannot silently give only one representation different propagation rules.
;; The recursive group-return path also provokes a rejected shrinkwrap attempt;
;; its carry-safe labels must not leak into the accepted function body.
(import stdlib.array)
(import stdlib.io)

(defstruct ScalarSnapshot
  (head i64))

(defenum EnumSnapshot
  (Snapshot i64))

(defstruct IndexedSnapshotSlot
  (key i64)
  (value i64)
  (parent i64))

(define snapshot-slots : (__tl_dyn-array IndexedSnapshotSlot)
  (array.make-array IndexedSnapshotSlot 0))
(define snapshot-count : i64
  0)
(define stored-raw-heads : (__tl_dyn-array i64)
  (array.make-array i64 128))
(define stored-struct-heads : (__tl_dyn-array ScalarSnapshot)
  (array.make-array ScalarSnapshot 128))
(define stored-enum-heads : (__tl_dyn-array i64)
  (array.make-array i64 128))

(define (snapshot-reset!) : unit
  (begin
    (set! snapshot-count 0)
    (set! snapshot-slots (array.make-array IndexedSnapshotSlot 0))))

(define (snapshot-grow-copy!
  [dst : (&mut dst (__tl_dyn-array IndexedSnapshotSlot))]
  [src : (& src (__tl_dyn-array IndexedSnapshotSlot))]
  [index : i64]) : unit
  (if (>= index snapshot-count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (snapshot-grow-copy! dst src (+ index 1)))))

(define (snapshot-ensure-capacity!) : unit
  (if (< snapshot-count (array.length snapshot-slots))
    unit
    (let
      [old-capacity : i64 (array.length snapshot-slots)]
      [next-capacity : i64
        (if (< old-capacity 1)
          64
          (* old-capacity 2))]
      [next-slots : (__tl_dyn-array IndexedSnapshotSlot)
        (array.make-array IndexedSnapshotSlot next-capacity)]
      (begin
        (snapshot-grow-copy! (&mut next-slots) (& snapshot-slots) 0)
        (set! snapshot-slots next-slots)))))

(define (snapshot-push-head [parent : i64] [key : i64] [value : i64]) : i64
  (begin
    (snapshot-ensure-capacity!)
    (let
      [index : i64 snapshot-count]
      (begin
        (set!
          (array-ref snapshot-slots index)
          (IndexedSnapshotSlot key value parent))
        (set! snapshot-count (+ snapshot-count 1))
        index))))

(define (snapshot-lookup-head [head : i64] [key : i64]) : i64
  (let
    [cursor : i64 head]
    [out : i64 -1]
    [done : bool false]
    (begin
      (while (and (>= cursor 0) (not done))
        (let
          [slot : IndexedSnapshotSlot (array-ref snapshot-slots cursor)]
          (if (= slot.key key)
            (begin
              (set! out slot.value)
              (set! done true))
            (set! cursor slot.parent))))
      out)))

(define (raw-snapshot-push [env : i64] [key : i64] [value : i64]) : i64
  (let
    [next : i64 (snapshot-push-head env key value)]
    (begin
      (set! (array-ref stored-raw-heads next) next)
      (array-ref stored-raw-heads next))))

(define (struct-snapshot-push [env : ScalarSnapshot] [key : i64] [value : i64]) : ScalarSnapshot
  (let
    [next : ScalarSnapshot
      (ScalarSnapshot (snapshot-push-head env.head key value))]
    (begin
      (set! (array-ref stored-struct-heads next.head) next)
      (array-ref stored-struct-heads next.head))))

(define (enum-snapshot-head [env : EnumSnapshot]) : i64
  (match env
    [(EnumSnapshot.Snapshot head) head]))

(define (enum-snapshot-push [env : EnumSnapshot] [key : i64] [value : i64]) : EnumSnapshot
  (let
    [next : EnumSnapshot
      (EnumSnapshot.Snapshot
        (snapshot-push-head (enum-snapshot-head env) key value))]
    [head : i64 (enum-snapshot-head next)]
    (begin
      (set! (array-ref stored-enum-heads head) head)
      (EnumSnapshot.Snapshot (array-ref stored-enum-heads head)))))

(define (raw-shadow-many [env : i64] [index : i64] [base : i64]) : i64
  (if (>= index 80)
    env
    (raw-shadow-many (raw-snapshot-push env 7 (+ base index)) (+ index 1) base)))

(define (struct-shadow-many [env : ScalarSnapshot] [index : i64] [base : i64]) : ScalarSnapshot
  (if (>= index 80)
    env
    (struct-shadow-many
      (struct-snapshot-push env 7 (+ base index))
      (+ index 1)
      base)))

(define (enum-shadow-many [env : EnumSnapshot] [index : i64] [base : i64]) : EnumSnapshot
  (if (>= index 80)
    env
    (enum-shadow-many
      (enum-snapshot-push env 7 (+ base index))
      (+ index 1)
      base)))

(define (raw-snapshot-case [base : i64]) : bool
  (begin
    (snapshot-reset!)
    (let
      [env : i64 -1]
      [env : i64 (raw-snapshot-push env 3 (+ base 1))]
      [sibling : i64 (raw-snapshot-push env 5 (+ base 20))]
      [env : i64 (raw-shadow-many env 0 (+ base 2))]
      (and
        (= (snapshot-lookup-head env 7) (+ base 81))
        (= (snapshot-lookup-head env 3) (+ base 1))
        (= (snapshot-lookup-head env 5) -1)
        (= (snapshot-lookup-head sibling 5) (+ base 20))
        (= (snapshot-lookup-head sibling 7) -1)))))

(define (struct-snapshot-case [base : i64]) : bool
  (begin
    (snapshot-reset!)
    (let
      [env : ScalarSnapshot (ScalarSnapshot -1)]
      [env : ScalarSnapshot (struct-snapshot-push env 3 (+ base 1))]
      [sibling : ScalarSnapshot (struct-snapshot-push env 5 (+ base 20))]
      [env : ScalarSnapshot (struct-shadow-many env 0 (+ base 2))]
      (and
        (= (snapshot-lookup-head env.head 7) (+ base 81))
        (= (snapshot-lookup-head env.head 3) (+ base 1))
        (= (snapshot-lookup-head env.head 5) -1)
        (= (snapshot-lookup-head sibling.head 5) (+ base 20))
        (= (snapshot-lookup-head sibling.head 7) -1)))))

(define (enum-snapshot-case [base : i64]) : i64
  (begin
    (snapshot-reset!)
    (let
      [env : EnumSnapshot (EnumSnapshot.Snapshot -1)]
      [env : EnumSnapshot (enum-snapshot-push env 3 (+ base 1))]
      [sibling : EnumSnapshot (enum-snapshot-push env 5 (+ base 20))]
      [env : EnumSnapshot (enum-shadow-many env 0 (+ base 2))]
      (begin
        (unless
          (= (snapshot-lookup-head (enum-snapshot-head env) 7) (+ base 81))
          (return 31))
        (unless
          (= (snapshot-lookup-head (enum-snapshot-head env) 3) (+ base 1))
          (return 32))
        (unless
          (= (snapshot-lookup-head (enum-snapshot-head env) 5) -1)
          (return 33))
        (unless
          (= (snapshot-lookup-head (enum-snapshot-head sibling) 5) (+ base 20))
          (return 34))
        (unless
          (= (snapshot-lookup-head (enum-snapshot-head sibling) 7) -1)
          (return 35))
        0))))

(define (main) : i64
  (let
    [base : i64 (+ 29 (io.arg-count))]
    (if (raw-snapshot-case base)
      (if (struct-snapshot-case base)
        (let
          [enum-result : i64 (enum-snapshot-case base)]
          (if (= enum-result 0)
            42
            enum-result))
        2)
      1)))