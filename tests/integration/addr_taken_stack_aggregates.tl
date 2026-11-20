;; A frame object whose address is taken keeps every store into its OWN slots:
;; the callee reads them through the pointer, so nothing in this function's
;; text reads them. GAP5's precise leaq poison must protect exactly the
;; addressed object's extent: a narrower span would sweep the field store the
;; callee reads, and a wider one (the old poison-everything watermark) would
;; stop every unrelated local above the object from being swept.
(defstruct Pair
  (lo i64)
  (hi i64)
  (tail unit))

;; Reads every element: the loop keeps it out of the caller's body, so the
;; caller's element stores stay unread in the caller's own text.
(define (sum-all [base : (Ptr i64)] [count : i64]) : i64
  (let
    [total : i64 0]
    [i : i64 0]
    (while (< i count)
      (+=
        total
        (unsafe
          (ptr-read (ptr-offset base i))))
      (+= i 1))
    total))

;; Reads the pointed-to word once per round; a loop for the same reason.
(define (read-slot [p : (Ptr i64)] [rounds : i64]) : i64
  (let
    [total : i64 0]
    [i : i64 0]
    (while (< i rounds)
      (+=
        total
        (unsafe
          (ptr-read p)))
      (+= i 1))
    total))

;; Never-taken self-recursion in each case below keeps inlining and TCO from
;; folding the named bodies away, so the asm-shape gate can inspect them.
;; A stack array's address goes to a callee that reads all four elements.
(define (array-case [seed : i64]) : i64
  (if (< seed -999999)
    (array-case (- seed 1))
    (let
      [items : (Array i64 4) (array seed (+ seed 1) (+ seed 2) (+ seed 3))]
      [base : (MutPtr i64)
        (unsafe
          (ptr-cast (ptr-addr-of items) : (MutPtr i64)))]
      (sum-all
        (unsafe
          (ptr-cast base : (Ptr i64)))
        4))))

;; A field address inside a stack struct goes to the callee: the address is
;; base+8, and the callee reads it, so the whole 16-byte object must stay.
(define (struct-case [seed : i64]) : i64
  (if (< seed -999999)
    (struct-case (- seed 1))
    (let
      [p : Pair (Pair seed (+ seed 2) unit)]
      [field : (MutPtr i64)
        (unsafe
          (ptr-addr-of p.hi))]
      (read-slot
        (unsafe
          (ptr-cast field : (Ptr i64)))
        3))))

;; A scalar local whose address goes to the callee.
(define (scalar-case [seed : i64]) : i64
  (if (< seed -999999)
    (scalar-case (- seed 1))
    (let
      [value : i64 (bit-xor seed 17)]
      [p : (MutPtr i64)
        (unsafe
          (ptr-addr-of value))]
      (read-slot
        (unsafe
          (ptr-cast p : (Ptr i64)))
        2))))

(define (main) : i64
  (let
    [out : i64 (+ (array-case 1) (+ (struct-case 2) (scalar-case 3)))]
    (if (> out 0)
      42
      1)))