;; Region-tagged scalars keep their inner type's signedness (#9688). A value
;; read through `(in p T)` carries the IR type `(Region p T)`; ordering,
;; division, remainder and right shift on it must use T's unsigned or signed
;; instruction. Each row holds a high-bit (or negative) value and 1. Recursion
;; keeps the dispatchers out of line so the compares are not folded away.
(define failures : i64
  0)

(define (assert [condition : bool]) : unit
  (unless condition (set! failures (+ failures 1))))

(define (u8-at [p : (& p (Array u8 2))] [i : i64]) : (in p u8)
  (array-ref p i))

(define (u16-at [p : (& p (Array u16 2))] [i : i64]) : (in p u16)
  (array-ref p i))

(define (u32-at [p : (& p (Array u32 2))] [i : i64]) : (in p u32)
  (array-ref p i))

(define (u64-at [p : (& p (Array u64 2))] [i : i64]) : (in p u64)
  (array-ref p i))

(define (i8-at [p : (& p (Array i8 2))] [i : i64]) : (in p i8)
  (array-ref p i))

(define (i16-at [p : (& p (Array i16 2))] [i : i64]) : (in p i16)
  (array-ref p i))

(define (i32-at [p : (& p (Array i32 2))] [i : i64]) : (in p i32)
  (array-ref p i))

(define (i64-at [p : (& p (Array i64 2))] [i : i64]) : (in p i64)
  (array-ref p i))

;; op 0-3: value `<` `<=` `>` `>=` of row[0] against row[1]; op 4-7: the same
;; as branches; op 8-11: value compares against the literal 1.
(define (order-u8 [p : (& p (Array u8 2))] [op : i64]) : bool
  (cond
    [(= op 0) (< (u8-at p 0) (u8-at p 1))]
    [(= op 1) (<= (u8-at p 0) (u8-at p 1))]
    [(= op 2) (> (u8-at p 0) (u8-at p 1))]
    [(= op 3) (>= (u8-at p 0) (u8-at p 1))]
    [(= op 4)
      (if (< (u8-at p 0) (u8-at p 1))
        true
        false)]
    [(= op 5)
      (if (<= (u8-at p 0) (u8-at p 1))
        true
        false)]
    [(= op 6)
      (if (> (u8-at p 0) (u8-at p 1))
        true
        false)]
    [(= op 7)
      (if (>= (u8-at p 0) (u8-at p 1))
        true
        false)]
    [(= op 8) (< (u8-at p 0) (cast 1 : u8))]
    [(= op 9) (<= (u8-at p 0) (cast 1 : u8))]
    [(= op 10) (> (u8-at p 0) (cast 1 : u8))]
    [(= op 11) (>= (u8-at p 0) (cast 1 : u8))]
    [else (order-u8 p (- op 12))]))

(define (order-u16 [p : (& p (Array u16 2))] [op : i64]) : bool
  (cond
    [(= op 0) (< (u16-at p 0) (u16-at p 1))]
    [(= op 1) (<= (u16-at p 0) (u16-at p 1))]
    [(= op 2) (> (u16-at p 0) (u16-at p 1))]
    [(= op 3) (>= (u16-at p 0) (u16-at p 1))]
    [(= op 4)
      (if (< (u16-at p 0) (u16-at p 1))
        true
        false)]
    [(= op 5)
      (if (<= (u16-at p 0) (u16-at p 1))
        true
        false)]
    [(= op 6)
      (if (> (u16-at p 0) (u16-at p 1))
        true
        false)]
    [(= op 7)
      (if (>= (u16-at p 0) (u16-at p 1))
        true
        false)]
    [(= op 8) (< (u16-at p 0) (cast 1 : u16))]
    [(= op 9) (<= (u16-at p 0) (cast 1 : u16))]
    [(= op 10) (> (u16-at p 0) (cast 1 : u16))]
    [(= op 11) (>= (u16-at p 0) (cast 1 : u16))]
    [else (order-u16 p (- op 12))]))

(define (order-u32 [p : (& p (Array u32 2))] [op : i64]) : bool
  (cond
    [(= op 0) (< (u32-at p 0) (u32-at p 1))]
    [(= op 1) (<= (u32-at p 0) (u32-at p 1))]
    [(= op 2) (> (u32-at p 0) (u32-at p 1))]
    [(= op 3) (>= (u32-at p 0) (u32-at p 1))]
    [(= op 4)
      (if (< (u32-at p 0) (u32-at p 1))
        true
        false)]
    [(= op 5)
      (if (<= (u32-at p 0) (u32-at p 1))
        true
        false)]
    [(= op 6)
      (if (> (u32-at p 0) (u32-at p 1))
        true
        false)]
    [(= op 7)
      (if (>= (u32-at p 0) (u32-at p 1))
        true
        false)]
    [(= op 8) (< (u32-at p 0) (cast 1 : u32))]
    [(= op 9) (<= (u32-at p 0) (cast 1 : u32))]
    [(= op 10) (> (u32-at p 0) (cast 1 : u32))]
    [(= op 11) (>= (u32-at p 0) (cast 1 : u32))]
    [else (order-u32 p (- op 12))]))

(define (order-u64 [p : (& p (Array u64 2))] [op : i64]) : bool
  (cond
    [(= op 0) (< (u64-at p 0) (u64-at p 1))]
    [(= op 1) (<= (u64-at p 0) (u64-at p 1))]
    [(= op 2) (> (u64-at p 0) (u64-at p 1))]
    [(= op 3) (>= (u64-at p 0) (u64-at p 1))]
    [(= op 4)
      (if (< (u64-at p 0) (u64-at p 1))
        true
        false)]
    [(= op 5)
      (if (<= (u64-at p 0) (u64-at p 1))
        true
        false)]
    [(= op 6)
      (if (> (u64-at p 0) (u64-at p 1))
        true
        false)]
    [(= op 7)
      (if (>= (u64-at p 0) (u64-at p 1))
        true
        false)]
    [(= op 8) (< (u64-at p 0) (cast 1 : u64))]
    [(= op 9) (<= (u64-at p 0) (cast 1 : u64))]
    [(= op 10) (> (u64-at p 0) (cast 1 : u64))]
    [(= op 11) (>= (u64-at p 0) (cast 1 : u64))]
    [else (order-u64 p (- op 12))]))

(define (order-i8 [p : (& p (Array i8 2))] [op : i64]) : bool
  (cond
    [(= op 0) (< (i8-at p 0) (i8-at p 1))]
    [(= op 1) (<= (i8-at p 0) (i8-at p 1))]
    [(= op 2) (> (i8-at p 0) (i8-at p 1))]
    [(= op 3) (>= (i8-at p 0) (i8-at p 1))]
    [(= op 4)
      (if (< (i8-at p 0) (i8-at p 1))
        true
        false)]
    [(= op 5)
      (if (<= (i8-at p 0) (i8-at p 1))
        true
        false)]
    [(= op 6)
      (if (> (i8-at p 0) (i8-at p 1))
        true
        false)]
    [(= op 7)
      (if (>= (i8-at p 0) (i8-at p 1))
        true
        false)]
    [(= op 8) (< (i8-at p 0) (cast 1 : i8))]
    [(= op 9) (<= (i8-at p 0) (cast 1 : i8))]
    [(= op 10) (> (i8-at p 0) (cast 1 : i8))]
    [(= op 11) (>= (i8-at p 0) (cast 1 : i8))]
    [else (order-i8 p (- op 12))]))

(define (order-i16 [p : (& p (Array i16 2))] [op : i64]) : bool
  (cond
    [(= op 0) (< (i16-at p 0) (i16-at p 1))]
    [(= op 1) (<= (i16-at p 0) (i16-at p 1))]
    [(= op 2) (> (i16-at p 0) (i16-at p 1))]
    [(= op 3) (>= (i16-at p 0) (i16-at p 1))]
    [(= op 4)
      (if (< (i16-at p 0) (i16-at p 1))
        true
        false)]
    [(= op 5)
      (if (<= (i16-at p 0) (i16-at p 1))
        true
        false)]
    [(= op 6)
      (if (> (i16-at p 0) (i16-at p 1))
        true
        false)]
    [(= op 7)
      (if (>= (i16-at p 0) (i16-at p 1))
        true
        false)]
    [(= op 8) (< (i16-at p 0) (cast 1 : i16))]
    [(= op 9) (<= (i16-at p 0) (cast 1 : i16))]
    [(= op 10) (> (i16-at p 0) (cast 1 : i16))]
    [(= op 11) (>= (i16-at p 0) (cast 1 : i16))]
    [else (order-i16 p (- op 12))]))

(define (order-i32 [p : (& p (Array i32 2))] [op : i64]) : bool
  (cond
    [(= op 0) (< (i32-at p 0) (i32-at p 1))]
    [(= op 1) (<= (i32-at p 0) (i32-at p 1))]
    [(= op 2) (> (i32-at p 0) (i32-at p 1))]
    [(= op 3) (>= (i32-at p 0) (i32-at p 1))]
    [(= op 4)
      (if (< (i32-at p 0) (i32-at p 1))
        true
        false)]
    [(= op 5)
      (if (<= (i32-at p 0) (i32-at p 1))
        true
        false)]
    [(= op 6)
      (if (> (i32-at p 0) (i32-at p 1))
        true
        false)]
    [(= op 7)
      (if (>= (i32-at p 0) (i32-at p 1))
        true
        false)]
    [(= op 8) (< (i32-at p 0) (cast 1 : i32))]
    [(= op 9) (<= (i32-at p 0) (cast 1 : i32))]
    [(= op 10) (> (i32-at p 0) (cast 1 : i32))]
    [(= op 11) (>= (i32-at p 0) (cast 1 : i32))]
    [else (order-i32 p (- op 12))]))

(define (order-i64 [p : (& p (Array i64 2))] [op : i64]) : bool
  (cond
    [(= op 0) (< (i64-at p 0) (i64-at p 1))]
    [(= op 1) (<= (i64-at p 0) (i64-at p 1))]
    [(= op 2) (> (i64-at p 0) (i64-at p 1))]
    [(= op 3) (>= (i64-at p 0) (i64-at p 1))]
    [(= op 4)
      (if (< (i64-at p 0) (i64-at p 1))
        true
        false)]
    [(= op 5)
      (if (<= (i64-at p 0) (i64-at p 1))
        true
        false)]
    [(= op 6)
      (if (> (i64-at p 0) (i64-at p 1))
        true
        false)]
    [(= op 7)
      (if (>= (i64-at p 0) (i64-at p 1))
        true
        false)]
    [(= op 8) (< (i64-at p 0) 1)]
    [(= op 9) (<= (i64-at p 0) 1)]
    [(= op 10) (> (i64-at p 0) 1)]
    [(= op 11) (>= (i64-at p 0) 1)]
    [else (order-i64 p (- op 12))]))

;; Branch on a compare of the high-bit row value against 1; each arm asserts
;; directly, so the branch itself (not a materialized bool) carries the result.
(define (branch-u64 [p : (& p (Array u64 2))] [op : i64]) : unit
  (cond
    [(= op 0)
      (if (< (u64-at p 0) (cast 1 : u64))
        (assert false)
        (assert true))]
    [(= op 1)
      (if (<= (u64-at p 0) (cast 1 : u64))
        (assert false)
        (assert true))]
    [(= op 2)
      (if (> (u64-at p 0) (cast 1 : u64))
        (assert true)
        (assert false))]
    [(= op 3)
      (if (>= (u64-at p 0) (cast 1 : u64))
        (assert true)
        (assert false))]
    [else (branch-u64 p (- op 4))]))

;; An unsigned row (high-bit value, 1): `<` and `<=` are false, `>` and `>=`
;; true. A signed control row (negative value, 1): the opposite.
(define (expected [unsigned? : bool] [op : i64]) : bool
  (let
    [k : i64 (% op 4)]
    (if unsigned?
      (>= k 2)
      (< k 2))))

(define (check-u8 [p : (& p (Array u8 2))] [op : i64]) : unit
  (when
    (< op 12)
    (assert (= (order-u8 p op) (expected true op)))
    (check-u8 p (+ op 1))))

(define (check-u16 [p : (& p (Array u16 2))] [op : i64]) : unit
  (when
    (< op 12)
    (assert (= (order-u16 p op) (expected true op)))
    (check-u16 p (+ op 1))))

(define (check-u32 [p : (& p (Array u32 2))] [op : i64]) : unit
  (when
    (< op 12)
    (assert (= (order-u32 p op) (expected true op)))
    (check-u32 p (+ op 1))))

(define (check-u64 [p : (& p (Array u64 2))] [op : i64]) : unit
  (when
    (< op 12)
    (assert (= (order-u64 p op) (expected true op)))
    (check-u64 p (+ op 1))))

(define (check-i8 [p : (& p (Array i8 2))] [op : i64]) : unit
  (when
    (< op 12)
    (assert (= (order-i8 p op) (expected false op)))
    (check-i8 p (+ op 1))))

(define (check-i16 [p : (& p (Array i16 2))] [op : i64]) : unit
  (when
    (< op 12)
    (assert (= (order-i16 p op) (expected false op)))
    (check-i16 p (+ op 1))))

(define (check-i32 [p : (& p (Array i32 2))] [op : i64]) : unit
  (when
    (< op 12)
    (assert (= (order-i32 p op) (expected false op)))
    (check-i32 p (+ op 1))))

(define (check-i64 [p : (& p (Array i64 2))] [op : i64]) : unit
  (when
    (< op 12)
    (assert (= (order-i64 p op) (expected false op)))
    (check-i64 p (+ op 1))))

;; Signed division, remainder and right shift of a region-tagged negative
;; value: `idiv`/`sar`, never `div`/`shr`. Row: (-7, 2).
(define (arith-i64 [p : (& p (Array i64 2))] [op : i64]) : i64
  (cond
    [(= op 0) (/ (i64-at p 0) (i64-at p 1))]
    [(= op 1) (% (i64-at p 0) (i64-at p 1))]
    [(= op 2) (/ (i64-at p 0) 2)]
    [(= op 3) (% (i64-at p 0) 2)]
    [(= op 4) (/ (i64-at p 0) -1)]
    [(= op 5) (/ (i64-at p 0) 7)]
    [(= op 6) (% (i64-at p 0) 7)]
    [(= op 7) (shr (i64-at p 0) 1)]
    [(= op 8) (shr (i64-at p 0) (i64-at p 1))]
    [else (arith-i64 p (- op 9))]))

(define (arith-i32 [p : (& p (Array i32 2))] [op : i64]) : i32
  (cond
    [(= op 0) (/ (i32-at p 0) (i32-at p 1))]
    [(= op 1) (% (i32-at p 0) (i32-at p 1))]
    [(= op 2) (/ (i32-at p 0) (cast 2 : i32))]
    [(= op 3) (shr (i32-at p 0) 1)]
    [else (arith-i32 p (- op 4))]))

;; Unsigned controls: the same operators on a region-tagged high-bit u64.
(define (arith-u64 [p : (& p (Array u64 2))] [op : i64]) : u64
  (cond
    [(= op 0) (/ (u64-at p 0) (u64-at p 1))]
    [(= op 1) (% (u64-at p 0) (u64-at p 1))]
    [(= op 2) (shr (u64-at p 0) 63)]
    [else (arith-u64 p (- op 3))]))

(define (main) : i64
  (let
    [u8s : (Array u8 2) (array (cast 200 : u8) (cast 1 : u8))]
    [u16s : (Array u16 2) (array (cast 65535 : u16) (cast 1 : u16))]
    [u32s : (Array u32 2) (array (cast 4294967295 : u32) (cast 1 : u32))]
    [u64s : (Array u64 2) (array (cast -1 : u64) (cast 1 : u64))]
    [i8s : (Array i8 2) (array (cast -5 : i8) (cast 1 : i8))]
    [i16s : (Array i16 2) (array (cast -5 : i16) (cast 1 : i16))]
    [i32s : (Array i32 2) (array (cast -5 : i32) (cast 1 : i32))]
    [i64s : (Array i64 2) (array -5 1)]
    [div64 : (Array i64 2) (array -7 2)]
    [div32 : (Array i32 2) (array (cast -7 : i32) (cast 2 : i32))]
    [udiv : (Array u64 2) (array (cast -1 : u64) (cast 2 : u64))]
    (check-u8 (& u8s) 0)
    (check-u16 (& u16s) 0)
    (check-u32 (& u32s) 0)
    (check-u64 (& u64s) 0)
    (check-i8 (& i8s) 0)
    (check-i16 (& i16s) 0)
    (check-i32 (& i32s) 0)
    (check-i64 (& i64s) 0)
    (branch-u64 (& u64s) 0)
    (branch-u64 (& u64s) 1)
    (branch-u64 (& u64s) 2)
    (branch-u64 (& u64s) 3)
    (assert (= (arith-i64 (& div64) 0) -3))
    (assert (= (arith-i64 (& div64) 1) -1))
    (assert (= (arith-i64 (& div64) 2) -3))
    (assert (= (arith-i64 (& div64) 3) -1))
    (assert (= (arith-i64 (& div64) 4) 7))
    (assert (= (arith-i64 (& div64) 5) -1))
    (assert (= (arith-i64 (& div64) 6) 0))
    (assert (= (arith-i64 (& div64) 7) -4))
    (assert (= (arith-i64 (& div64) 8) -2))
    (assert (= (arith-i32 (& div32) 0) (cast -3 : i32)))
    (assert (= (arith-i32 (& div32) 1) (cast -1 : i32)))
    (assert (= (arith-i32 (& div32) 2) (cast -3 : i32)))
    (assert (= (arith-i32 (& div32) 3) (cast -4 : i32)))
    (assert (= (arith-u64 (& udiv) 0) (cast 9223372036854775807 : u64)))
    (assert (= (arith-u64 (& udiv) 1) (cast 1 : u64)))
    (assert (= (arith-u64 (& udiv) 2) (cast 1 : u64)))
    (- 42 failures)))