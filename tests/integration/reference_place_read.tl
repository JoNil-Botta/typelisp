(import stdlib.string)

(defstruct Pt
  (name String)
  (x i64))

(defstruct Outer
  (pt Pt))

(define receiver-calls : i64
  0)
(define index-calls : i64
  0)
(define read-receiver-calls : i64
  0)
(define array-evaluation-order : i64
  0)
(define evaluation-order : i64
  0)

(define (replace-direct [slot : (&mut slot Pt)]) : i64
  (let
    [old : Pt (replace! (deref slot) (Pt "direct-new" 2))]
    (if (string.eq old.name "direct-old")
      old.x
      -1)))

(define (replace-field [slot : (&mut slot Outer)]) : i64
  (let
    [old : Pt (replace! (deref slot).pt (Pt "field-new" 2))]
    (if (string.eq old.name "field-old")
      old.x
      -1)))

(define (bump [slot : (&mut slot Pt)]) : unit
  (set! slot.x (+ slot.x 1)))

(define (reborrow [slot : (&mut slot Pt)]) : i64
  (bump (&mut (deref slot)))
  (deref slot).x)

(define (observe-box [slot : (& slot (Box i64))]) : (& slot (Box i64))
  (set! read-receiver-calls (+ read-receiver-calls 1))
  slot)

(define (read-box [slot : (& slot (Box i64))]) : i64
  (deref (deref (observe-box slot))))

(define (replace-box-text [slot : (&mut slot (Box String))]) : bool
  (let
    [old : String (replace! (deref (deref slot)) "after")]
    (string.eq old "before")))

(define (locate [slot : (&mut slot Pt)]) : (&mut slot Pt)
  (set! receiver-calls (+ receiver-calls 1))
  (set! evaluation-order (+ (* evaluation-order 10) 1))
  slot)

(define (replacement) : Pt
  (set! evaluation-order (+ (* evaluation-order 10) 2))
  (Pt "factory-new" 31))

(define (selected-index) : i64
  (set! index-calls (+ index-calls 1))
  (set! array-evaluation-order (+ (* array-evaluation-order 10) 1))
  0)

(define (array-replacement) : Pt
  (set! array-evaluation-order (+ (* array-evaluation-order 10) 2))
  (Pt "array-new" 27))

(define (replace-element [slots : (&mut slots (Array Pt 1))]) : i64
  (let
    [old : Pt
      (replace! (array-ref (deref slots) (selected-index)) (array-replacement))]
    (if (string.eq old.name "array-old")
      old.x
      -1)))

(define (main) : i64
  (let
    [point : Pt (Pt "direct-old" 10)]
    [outer : Outer (Outer (Pt "field-old" 12))]
    [number : (Box i64) (box 8)]
    [text : (Box String) (box "before")]
    [items : (Array Pt 1) (array (Pt "array-old" 6))]
    [direct : i64 (replace-direct (&mut point))]
    [field : i64 (replace-field (&mut outer))]
    [updated : i64 (reborrow (&mut point))]
    [copied : i64 (read-box (& number))]
    [text-replaced : bool (replace-box-text (&mut text))]
    [element : i64 (replace-element (&mut items))]
    [located (locate (&mut point))]
    [factory-old : Pt (replace! (deref located) (replacement))]
    (if (and
      (= direct 10)
      (= field 12)
      (= updated 3)
      (= copied 8)
      text-replaced
      (= element 6)
      (= factory-old.x 3)
      (string.eq factory-old.name "direct-new")
      (= point.x 31)
      (string.eq point.name "factory-new")
      (= outer.pt.x 2)
      (= (array-ref items 0).x 27)
      (string.eq (deref text) "after")
      (= (deref number) 8)
      (= receiver-calls 1)
      (= index-calls 1)
      (= read-receiver-calls 1)
      (= array-evaluation-order 12)
      (= evaluation-order 12))
      42
      1)))