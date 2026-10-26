;; replace! writes the place it names and returns that place's own old value:
;; box contents reached through `&mut` (returned, not borrowed), a `&mut`
;; reached through other mutable references or containers, and the referent
;; of a computed reference held in a temporary.
(import stdlib.string)

(defstruct Pt
  (name String)
  (x i64))

(defstruct Holder
  (:lifetimes a)
  (r (&mut a Pt))
  (n i64))

(defstruct Boxed
  (b (Box String))
  (n i64))

(define locate-calls : i64
  0)

(define (bump [p : (&mut p Pt)]) : unit
  (set! p.x (+ p.x 1)))

(define (look [p : (& p Pt)]) : i64
  p.x)

(define (locate [p : (&mut p Pt)]) : (&mut p Pt)
  (set! locate-calls (+ locate-calls 1))
  p)

(define (take-text [p : (&mut p (Box String))]) : String
  (replace! (deref (deref p)) "after"))

(define (take-field [p : (&mut p Boxed)]) : String
  (replace! (deref p.b) "field-after"))

(define (take-nested [p : (&mut p (Box (Box String)))]) : (Box String)
  (replace! (deref (deref p)) (box "nested-after")))

(define (through-tuple [h : (&mut h (Tuple (&mut a Pt) i64))]) : Pt
  (replace! (deref (tuple-ref (deref h) 0)) (Pt "tuple" 1)))

(define (through-dotted [h : (&mut h (Holder a))]) : String
  (replace! (deref h.r).name "dotted"))

(define (through-field [h : (&mut h (Holder a))]) : Pt
  (replace! (deref (deref h).r) (Pt "field" 4)))

(define (computed [p : (&mut p Pt)]) : Pt
  (bump (&mut (deref (locate p))))
  (replace! (deref (locate p)) (Pt "computed" 6)))

(define (main) : i64
  (let
    [text : (Box String) (box "before")]
    [old-text : String (take-text (&mut text))]
    [boxed : Boxed (Boxed (box "field-before") 0)]
    [old-field : String (take-field (&mut boxed))]
    [nested : (Box (Box String)) (box (box "nested-before"))]
    [old-nested : (Box String) (take-nested (&mut nested))]
    [zero : i64 0]
    [a : Pt (Pt "a" 10)]
    [old-a : Pt
      (let
        [t (tuple (&mut a) zero)]
        (through-tuple (&mut t)))]
    [b : Pt (Pt "b" 20)]
    [old-b : String
      (let
        [holder (Holder (&mut b) 0)]
        (through-dotted (&mut holder)))]
    [d : Pt (Pt "d" 40)]
    [old-d : Pt
      (let
        [holder (Holder (&mut d) 0)]
        (through-field (&mut holder)))]
    [f : Pt (Pt "f" 60)]
    [old-f : Pt (computed (&mut f))]
    [g : Pt (Pt "g" 70)]
    [seen : i64
      (look
        (&
          (deref
            (begin
              (bump (&mut g))
              (& g)))))]
    (if (and
      (string.eq old-text "before")
      (string.eq (deref text) "after")
      (string.eq old-field "field-before")
      (string.eq (deref boxed.b) "field-after")
      (string.eq (deref old-nested) "nested-before")
      (string.eq (deref (deref nested)) "nested-after")
      (string.eq old-a.name "a")
      (= old-a.x 10)
      (string.eq a.name "tuple")
      (= a.x 1)
      (string.eq old-b "b")
      (string.eq b.name "dotted")
      (= b.x 20)
      (= old-d.x 40)
      (string.eq d.name "field")
      (= d.x 4)
      (string.eq old-f.name "f")
      (= old-f.x 61)
      (string.eq f.name "computed")
      (= f.x 6)
      (= locate-calls 2)
      (= seen 71))
      42
      1)))