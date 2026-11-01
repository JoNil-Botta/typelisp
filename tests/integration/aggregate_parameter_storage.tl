;; By-value aggregate parameters own shallow inline storage. A callee may
;; mutate its value without changing a caller's Copy value. References retain
;; their identity, and moving an owning aggregate must not clone its Box.
(defstruct ParameterTriple
  (first i64)
  (second i64)
  (third i64))

(defenum ParameterChoice
  (Empty)
  (Triple ParameterTriple))

(defstruct ParameterOwner
  (value (Box i64))
  (padding i64)
  (more i64))

(define (parameter-struct-change [value : ParameterTriple]) : i64
  (begin
    (set! value.first 99)
    (+ value.first value.third)))

(define (parameter-struct-tail [value : ParameterTriple]) : i64
  (parameter-struct-change value))

(define (parameter-struct-indirect
  [change : (-> ParameterTriple i64)]
  [value : ParameterTriple]) : i64
  (change value))

(define (parameter-struct-reference [value : (&mut value ParameterTriple)]) : unit
  (set! value.second 77))

(define (parameter-struct-ok?) : bool
  (let
    [value : ParameterTriple (ParameterTriple 10 11 12)]
    [direct : i64 (parameter-struct-change value)]
    [tail : i64 (parameter-struct-tail value)]
    [indirect : i64 (parameter-struct-indirect parameter-struct-change value)]
    [delta : i64 7]
    [closure : (-> ParameterTriple i64)
      (lambda ([argument : ParameterTriple]) : i64
        (begin
          (set! argument.first (+ argument.first delta))
          argument.first))]
    [captured : i64 (closure value)]
    (begin
      (parameter-struct-reference (&mut value))
      (and
        (= direct 111)
        (= tail 111)
        (= indirect 111)
        (= captured 17)
        (= value.first 10)
        (= value.second 77)
        (= value.third 12)))))

(define (parameter-enum-first [value : (& value ParameterChoice)]) : i64
  (match value
    [(ParameterChoice.Triple triple) triple.first]
    [_ -1]))

(define (parameter-enum-change [value : ParameterChoice]) : i64
  (begin
    (set! value (ParameterChoice.Triple (ParameterTriple 99 98 97)))
    (parameter-enum-first (& value))))

(define (parameter-enum-tail [value : ParameterChoice]) : i64
  (parameter-enum-change value))

(define (parameter-enum-indirect
  [change : (-> ParameterChoice i64)]
  [value : ParameterChoice]) : i64
  (change value))

(define (parameter-enum-ok?) : bool
  (let
    [value : ParameterChoice
      (ParameterChoice.Triple (ParameterTriple 10 11 12))]
    [direct : i64 (parameter-enum-change value)]
    [tail : i64 (parameter-enum-tail value)]
    [indirect : i64 (parameter-enum-indirect parameter-enum-change value)]
    [first : i64 23]
    [closure : (-> ParameterChoice i64)
      (lambda ([argument : ParameterChoice]) : i64
        (begin
          (set! argument (ParameterChoice.Triple (ParameterTriple first 2 3)))
          (parameter-enum-first (& argument))))]
    [captured : i64 (closure value)]
    (and
      (= direct 99)
      (= tail 99)
      (= indirect 99)
      (= captured 23)
      (= (parameter-enum-first (& value)) 10))))

(define (parameter-owner-change [value : ParameterOwner]) : ParameterOwner
  (begin
    (set! value.padding 23)
    value))

(define (parameter-owner-tail [value : ParameterOwner]) : ParameterOwner
  (parameter-owner-change value))

(define (parameter-owner-indirect
  [change : (-> ParameterOwner ParameterOwner)]
  [value : ParameterOwner]) : ParameterOwner
  (change value))

(define (parameter-owner-ok? [route : i64]) : bool
  (let
    [owner : ParameterOwner (ParameterOwner (box 42) 0 7)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of owner.value) : (Ptr u64))))]
    [moved : ParameterOwner
      (match route
        [0 (parameter-owner-change owner)]
        [1 (parameter-owner-tail owner)]
        [_ (parameter-owner-indirect parameter-owner-change owner)])]
    (begin
      ;; The original storage can be initialized again after the move. This
      ;; also detects a returned pointer into an abandoned callee frame.
      (set! owner (ParameterOwner (box 7) 0 0))
      (and
        (= moved.padding 23)
        (= moved.more 7)
        (= (deref moved.value) 42)
        (= (deref owner.value) 7)
        (=
          address
          (unsafe
            (ptr-read (ptr-cast (ptr-addr-of moved.value) : (Ptr u64)))))))))

(define (main) : i64
  (begin
    (unless (parameter-struct-ok?) (return 1))
    (unless (parameter-enum-ok?) (return 2))
    (unless (parameter-owner-ok? 0) (return 3))
    (unless (parameter-owner-ok? 1) (return 4))
    (unless (parameter-owner-ok? 2) (return 5))
    42))