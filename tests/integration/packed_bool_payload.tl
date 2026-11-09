;; Refs #9689: a bool unpacked from a packed enum payload is compared, branched
;; on and stored as a bool, at low and high byte offsets of a payload word. Each
;; operand crosses a recursive relay so the unpacking stays at run time.
(defenum Flag
  (Absent)
  (One bool)
  (Four bool bool u8 bool)
  (Far u32 u16 u8 bool))

(define (relay [value : Flag] [depth : i64]) : Flag
  (if (> depth 0)
    (relay value (- depth 1))
    value))

(define (one-eq? [lhs : Flag] [rhs : Flag]) : bool
  (match (relay lhs 3)
    [(One a)
      (match (relay rhs 3)
        [(One b) (= a b)]
        [_ false])]
    [_ false]))

(define (one-ne? [lhs : Flag] [rhs : Flag]) : bool
  (match (relay lhs 3)
    [(One a)
      (match (relay rhs 3)
        [(One b) (!= a b)]
        [_ false])]
    [_ false]))

;; Compares the bools at byte offsets 0 and 3 of one payload word, with a u8
;; neighbour between them whose bits must not reach either comparison.
(define (four-ends-eq? [value : Flag]) : bool
  (match (relay value 3)
    [(Four first _ _ last) (= first last)]
    [_ false]))

(define (four-middle-ne? [value : Flag]) : bool
  (match (relay value 3)
    [(Four first second _ _) (!= first second)]
    [_ false]))

;; The bool in the word's top byte takes the extraction with no left shift.
(define (far-eq-one? [far : Flag] [one : Flag]) : bool
  (match (relay far 3)
    [(Far _ _ _ top)
      (match (relay one 3)
        [(One b) (= top b)]
        [_ false])]
    [_ false]))

(define (branch-value [value : Flag]) : i64
  (match (relay value 3)
    [(One a)
      (if a
        1
        2)]
    [(Far _ _ _ top)
      (if top
        3
        4)]
    [_ 5]))

(define (stored-then-compared? [value : Flag] [expected : bool]) : bool
  (match (relay value 3)
    [(Four _ second _ _)
      (let
        [held : bool second]
        (= held expected))]
    [_ false]))

(define (far [top : bool] [noise : u8]) : Flag
  (Far (cast 4294967295 : u32) (cast 65535 : u16) noise top))

(define (check-one-pairs) : bool
  (and
    (one-eq? (One true) (One true))
    (one-eq? (One false) (One false))
    (not (one-eq? (One true) (One false)))
    (not (one-eq? (One false) (One true)))
    (one-ne? (One true) (One false))
    (one-ne? (One false) (One true))
    (not (one-ne? (One true) (One true)))
    (not (one-ne? (One false) (One false)))))

(define (check-four-offsets) : bool
  (let
    [noise : u8 (cast 255 : u8)]
    (and
      (four-ends-eq? (Four true false noise true))
      (four-ends-eq? (Four false true noise false))
      (not (four-ends-eq? (Four true true noise false)))
      (not (four-ends-eq? (Four false false noise true)))
      (four-middle-ne? (Four true false noise true))
      (four-middle-ne? (Four false true noise false))
      (not (four-middle-ne? (Four true true noise false)))
      (not (four-middle-ne? (Four false false noise true))))))

(define (check-top-byte) : bool
  (let
    [noise : u8 (cast 254 : u8)]
    (and
      (far-eq-one? (far true noise) (One true))
      (far-eq-one? (far false noise) (One false))
      (not (far-eq-one? (far true noise) (One false)))
      (not (far-eq-one? (far false noise) (One true))))))

(define (check-branches) : bool
  (and
    (= (branch-value (One true)) 1)
    (= (branch-value (One false)) 2)
    (= (branch-value (far true (cast 255 : u8))) 3)
    (= (branch-value (far false (cast 255 : u8))) 4)
    (= (branch-value (Absent)) 5)))

(define (check-stored) : bool
  (let
    [noise : u8 (cast 255 : u8)]
    (and
      (stored-then-compared? (Four false true noise false) true)
      (stored-then-compared? (Four true false noise true) false)
      (not (stored-then-compared? (Four false true noise false) false))
      (not (stored-then-compared? (Four true false noise true) true)))))

(define (main) : i64
  (cond
    [(not (check-one-pairs)) 1]
    [(not (check-four-offsets)) 2]
    [(not (check-top-byte)) 3]
    [(not (check-branches)) 4]
    [(not (check-stored)) 5]
    [else 42]))