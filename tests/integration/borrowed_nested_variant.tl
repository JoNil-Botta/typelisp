;; A nested enum-variant pattern in a match on a borrowed scrutinee reads the
;; nested payload in place (#8905): through `(& local)`, through `(& r.field)`
;; with `r` a reference, and through a reference parameter; at the first and a
;; later outer payload; for nested enums of one word, two words (a register
;; group, which used to be loaded as a packed value and then read as an
;; address), three words and a boxed payload; with by-value Copy binders and
;; borrowed non-Copy ones. Every probe yields 42 when the nested payload is
;; read correctly; `main` returns the number of probes, 36.
(import stdlib.string)

(define (make-items [v : i64]) : (__tl_dyn-array i64)
  (__tl_make-array v))

(defenum Tag
  (A)
  (B))

(defenum OuterTag
  (First Tag i64)
  (Later i64 Tag)
  (Other i64))

(defstruct HolderTag
  (outer OuterTag)
  (tag i64))

(define (first-tag [o : (& OuterTag)]) : i64
  (match o
    [(First (Tag.B) k) (+ 40 k)]
    [_ 0]))

(define (later-tag [o : (& OuterTag)]) : i64
  (match o
    [(Later k (Tag.B)) (+ 40 k)]
    [_ 0]))

(define (local-tag [n : i64]) : i64
  (let
    [first : OuterTag (First (Tag.B) 2)]
    [later : OuterTag (Later 2 (Tag.B))]
    (+
      (match (& first)
        [(First (Tag.B) k) (+ 40 k)]
        [_ n])
      (match (& later)
        [(Later k (Tag.B)) (+ 40 k)]
        [_ n]))))

(define (field-tag [first : (& HolderTag)] [later : (& HolderTag)]) : i64
  (+
    (match (& first.outer)
      [(First (Tag.B) k) (+ 40 k)]
      [_ 0])
    (match (& later.outer)
      [(Later k (Tag.B)) (+ 40 k)]
      [_ 0])))

(define (probe-tag) : i64
  (let
    [first : OuterTag (First (Tag.B) 2)]
    [later : OuterTag (Later 2 (Tag.B))]
    [hf : HolderTag (HolderTag (First (Tag.B) 2) 0)]
    [hl : HolderTag (HolderTag (Later 2 (Tag.B)) 0)]
    (+
      (+ (first-tag (& first)) (later-tag (& later)))
      (+ (local-tag 0) (field-tag (& hf) (& hl))))))

(defenum Word
  (No)
  (Some i64))

(defenum OuterWord
  (First Word i64)
  (Later i64 Word)
  (Other i64))

(defstruct HolderWord
  (outer OuterWord)
  (tag i64))

(define (first-word [o : (& OuterWord)]) : i64
  (match o
    [(First (Word.Some x) k) (+ x k)]
    [_ 0]))

(define (later-word [o : (& OuterWord)]) : i64
  (match o
    [(Later k (Word.Some x)) (+ x k)]
    [_ 0]))

(define (local-word [n : i64]) : i64
  (let
    [first : OuterWord (First (Word.Some 40) 2)]
    [later : OuterWord (Later 2 (Word.Some 40))]
    (+
      (match (& first)
        [(First (Word.Some x) k) (+ x k)]
        [_ n])
      (match (& later)
        [(Later k (Word.Some x)) (+ x k)]
        [_ n]))))

(define (field-word [first : (& HolderWord)] [later : (& HolderWord)]) : i64
  (+
    (match (& first.outer)
      [(First (Word.Some x) k) (+ x k)]
      [_ 0])
    (match (& later.outer)
      [(Later k (Word.Some x)) (+ x k)]
      [_ 0])))

(define (probe-word) : i64
  (let
    [first : OuterWord (First (Word.Some 40) 2)]
    [later : OuterWord (Later 2 (Word.Some 40))]
    [hf : HolderWord (HolderWord (First (Word.Some 40) 2) 0)]
    [hl : HolderWord (HolderWord (Later 2 (Word.Some 40)) 0)]
    (+
      (+ (first-word (& first)) (later-word (& later)))
      (+ (local-word 0) (field-word (& hf) (& hl))))))

(defenum Items
  (No)
  (Full (__tl_dyn-array i64)))

(defenum OuterItems
  (First Items i64)
  (Later i64 Items)
  (Other i64))

(defstruct HolderItems
  (outer OuterItems)
  (tag i64))

(define (first-items [o : (& OuterItems)]) : i64
  (match o
    [(First (Items.Full xs) k) (+ (array-ref xs 0) k)]
    [_ 0]))

(define (later-items [o : (& OuterItems)]) : i64
  (match o
    [(Later k (Items.Full xs)) (+ (array-ref xs 0) k)]
    [_ 0]))

(define (local-items [n : i64]) : i64
  (let
    [first : OuterItems (First (Items.Full (make-items 40)) 2)]
    [later : OuterItems (Later 2 (Items.Full (make-items 40)))]
    (+
      (match (& first)
        [(First (Items.Full xs) k) (+ (array-ref xs 0) k)]
        [_ n])
      (match (& later)
        [(Later k (Items.Full xs)) (+ (array-ref xs 0) k)]
        [_ n]))))

(define (field-items [first : (& HolderItems)] [later : (& HolderItems)]) : i64
  (+
    (match (& first.outer)
      [(First (Items.Full xs) k) (+ (array-ref xs 0) k)]
      [_ 0])
    (match (& later.outer)
      [(Later k (Items.Full xs)) (+ (array-ref xs 0) k)]
      [_ 0])))

(define (probe-items) : i64
  (let
    [first : OuterItems (First (Items.Full (make-items 40)) 2)]
    [later : OuterItems (Later 2 (Items.Full (make-items 40)))]
    [hf : HolderItems (HolderItems (First (Items.Full (make-items 40)) 2) 0)]
    [hl : HolderItems (HolderItems (Later 2 (Items.Full (make-items 40))) 0)]
    (+
      (+ (first-items (& first)) (later-items (& later)))
      (+ (local-items 0) (field-items (& hf) (& hl))))))

(defenum Pair
  (No)
  (Some i64 i64))

(defenum OuterPair
  (First Pair i64)
  (Later i64 Pair)
  (Other i64))

(defstruct HolderPair
  (outer OuterPair)
  (tag i64))

(define (first-pair [o : (& OuterPair)]) : i64
  (match o
    [(First (Pair.Some x y) k) (+ (+ x y) k)]
    [_ 0]))

(define (later-pair [o : (& OuterPair)]) : i64
  (match o
    [(Later k (Pair.Some x y)) (+ (+ x y) k)]
    [_ 0]))

(define (local-pair [n : i64]) : i64
  (let
    [first : OuterPair (First (Pair.Some 30 10) 2)]
    [later : OuterPair (Later 2 (Pair.Some 30 10))]
    (+
      (match (& first)
        [(First (Pair.Some x y) k) (+ (+ x y) k)]
        [_ n])
      (match (& later)
        [(Later k (Pair.Some x y)) (+ (+ x y) k)]
        [_ n]))))

(define (field-pair [first : (& HolderPair)] [later : (& HolderPair)]) : i64
  (+
    (match (& first.outer)
      [(First (Pair.Some x y) k) (+ (+ x y) k)]
      [_ 0])
    (match (& later.outer)
      [(Later k (Pair.Some x y)) (+ (+ x y) k)]
      [_ 0])))

(define (probe-pair) : i64
  (let
    [first : OuterPair (First (Pair.Some 30 10) 2)]
    [later : OuterPair (Later 2 (Pair.Some 30 10))]
    [hf : HolderPair (HolderPair (First (Pair.Some 30 10) 2) 0)]
    [hl : HolderPair (HolderPair (Later 2 (Pair.Some 30 10)) 0)]
    (+
      (+ (first-pair (& first)) (later-pair (& later)))
      (+ (local-pair 0) (field-pair (& hf) (& hl))))))

(defenum Name
  (No)
  (Text String))

(defenum OuterName
  (First Name i64)
  (Later i64 Name)
  (Other i64))

(defstruct HolderName
  (outer OuterName)
  (tag i64))

(define (first-name [o : (& OuterName)]) : i64
  (match o
    [(First (Name.Text s) k) (+ (string.string-length s) k)]
    [_ 0]))

(define (later-name [o : (& OuterName)]) : i64
  (match o
    [(Later k (Name.Text s)) (+ (string.string-length s) k)]
    [_ 0]))

(define (local-name [n : i64]) : i64
  (let
    [first : OuterName
      (First (Name.Text "abcdefghijabcdefghijabcdefghijabcdefghij") 2)]
    [later : OuterName
      (Later 2 (Name.Text "abcdefghijabcdefghijabcdefghijabcdefghij"))]
    (+
      (match (& first)
        [(First (Name.Text s) k) (+ (string.string-length s) k)]
        [_ n])
      (match (& later)
        [(Later k (Name.Text s)) (+ (string.string-length s) k)]
        [_ n]))))

(define (field-name [first : (& HolderName)] [later : (& HolderName)]) : i64
  (+
    (match (& first.outer)
      [(First (Name.Text s) k) (+ (string.string-length s) k)]
      [_ 0])
    (match (& later.outer)
      [(Later k (Name.Text s)) (+ (string.string-length s) k)]
      [_ 0])))

(define (probe-name) : i64
  (let
    [first : OuterName
      (First (Name.Text "abcdefghijabcdefghijabcdefghijabcdefghij") 2)]
    [later : OuterName
      (Later 2 (Name.Text "abcdefghijabcdefghijabcdefghijabcdefghij"))]
    [hf : HolderName
      (HolderName
        (First (Name.Text "abcdefghijabcdefghijabcdefghijabcdefghij") 2)
        0)]
    [hl : HolderName
      (HolderName
        (Later 2 (Name.Text "abcdefghijabcdefghijabcdefghijabcdefghij"))
        0)]
    (+
      (+ (first-name (& first)) (later-name (& later)))
      (+ (local-name 0) (field-name (& hf) (& hl))))))

(defenum Boxed
  (No)
  (Some (Box i64)))

(defenum OuterBoxed
  (First Boxed i64)
  (Later i64 Boxed)
  (Other i64))

(defstruct HolderBoxed
  (outer OuterBoxed)
  (tag i64))

(define (first-boxed [o : (& OuterBoxed)]) : i64
  (match o
    [(First (Boxed.Some b) k) (+ (deref b) k)]
    [_ 0]))

(define (later-boxed [o : (& OuterBoxed)]) : i64
  (match o
    [(Later k (Boxed.Some b)) (+ (deref b) k)]
    [_ 0]))

(define (local-boxed [n : i64]) : i64
  (let
    [first : OuterBoxed (First (Boxed.Some (box 40)) 2)]
    [later : OuterBoxed (Later 2 (Boxed.Some (box 40)))]
    (+
      (match (& first)
        [(First (Boxed.Some b) k) (+ (deref b) k)]
        [_ n])
      (match (& later)
        [(Later k (Boxed.Some b)) (+ (deref b) k)]
        [_ n]))))

(define (field-boxed [first : (& HolderBoxed)] [later : (& HolderBoxed)]) : i64
  (+
    (match (& first.outer)
      [(First (Boxed.Some b) k) (+ (deref b) k)]
      [_ 0])
    (match (& later.outer)
      [(Later k (Boxed.Some b)) (+ (deref b) k)]
      [_ 0])))

(define (probe-boxed) : i64
  (let
    [first : OuterBoxed (First (Boxed.Some (box 40)) 2)]
    [later : OuterBoxed (Later 2 (Boxed.Some (box 40)))]
    [hf : HolderBoxed (HolderBoxed (First (Boxed.Some (box 40)) 2) 0)]
    [hl : HolderBoxed (HolderBoxed (Later 2 (Boxed.Some (box 40))) 0)]
    (+
      (+ (first-boxed (& first)) (later-boxed (& later)))
      (+ (local-boxed 0) (field-boxed (& hf) (& hl))))))

(define (main) : i64
  (let
    [total : i64
      (+
        (probe-tag)
        (probe-word)
        (probe-items)
        (probe-pair)
        (probe-name)
        (probe-boxed))]
    (if (= total (* 42 36))
      36
      1)))