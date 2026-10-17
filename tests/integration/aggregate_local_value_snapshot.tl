;; Memory-class local values keep their own inline bytes. In particular a
;; projection or wrapped expression must not turn a value binding into an alias.
(defstruct SnapshotValue
  (first i64)
  (second i64)
  (third i64))

(defstruct SnapshotOuter
  (left SnapshotValue)
  (right SnapshotValue))

(defstruct SnapshotOwner
  (value (Box i64))
  (padding i64)
  (more i64))

(define (snapshot-route [route : i64]) : bool
  (let
    [outer : SnapshotOuter
      (SnapshotOuter (SnapshotValue 1 2 3) (SnapshotValue 4 5 6))]
    [visits : i64 0]
    [saved : SnapshotValue
      (match route
        [0 outer.left]
        [1
          (begin
            (set! visits (+ visits 1))
            outer.left)]
        [2
          (if true
            outer.left
            outer.right)]
        [_
          (let
            [increment : i64 1]
            (begin
              (set! visits (+ visits increment))
              outer.left))])]
    [again : SnapshotValue saved]
    (begin
      (set! outer.left (SnapshotValue 7 8 9))
      (set! saved.second 11)
      (and
        (=
          visits
          (if (or (= route 1) (= route 3))
            1
            0))
        (= outer.left.second 8)
        (= saved.first 1)
        (= saved.second 11)
        (= again.second 2)
        (= again.third 3)
        (= outer.right.second 5)))))

(define (snapshot-nested) : bool
  (let
    [values : (Array SnapshotValue 2)
      (array (SnapshotValue 1 2 3) (SnapshotValue 4 5 6))]
    [before : (Array SnapshotValue 2) values]
    [element : SnapshotValue (array-ref values 1)]
    [assigned : SnapshotValue (SnapshotValue 0 0 0)]
    [initialized : bool
      (match assigned
        [(SnapshotValue _ _ third) (= third 0)])]
    (begin
      (set! assigned (array-ref values 0))
      (set! (array-ref values 0) (SnapshotValue 7 8 9))
      (set! (array-ref values 1) (SnapshotValue 10 11 12))
      (and
        initialized
        (= assigned.third 3)
        (= (array-ref before 0).second 2)
        (= (array-ref before 1).second 5)
        (= element.third 6)))))

(define (snapshot-move) : bool
  (let
    [owner : SnapshotOwner (SnapshotOwner (box 42) 0 0)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of owner.value) : (Ptr u64))))]
    [moved : SnapshotOwner owner]
    (begin
      (set! owner (SnapshotOwner (box 7) 0 0))
      (and
        (= (deref moved.value) 42)
        (= (deref owner.value) 7)
        (=
          address
          (unsafe
            (ptr-read (ptr-cast (ptr-addr-of moved.value) : (Ptr u64)))))))))

(define (main) : i64
  (if (and
    (snapshot-route 0)
    (snapshot-route 1)
    (snapshot-route 2)
    (snapshot-route 3)
    (snapshot-nested)
    (snapshot-move))
    42
    1))