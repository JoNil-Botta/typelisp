;; A self tail call in an arm of a match on a borrowed enum place stays a tail
;; call, so a walker over borrowed elements runs in one frame (#9044): the
;; element of an array reached through a reference parameter, a field reached
;; through one, and a two-word enum the match spills to a slot. A binding that
;; borrows an aggregate payload of a frame local still keeps its call: the
;; callee reads the frame a jump would abandon.
(import stdlib.iterator)

(defenum Item
  (Var i64)
  (Name String)
  (Pair i64 i64))

(defstruct ItemSeq
  (slots (__tl_dyn-array Item))
  (len i64))

;; A borrow of an element through a reference parameter.
(define (walk-borrow [seq : (& ItemSeq)] [i : i64] [acc : i64]) : i64
  (if (>= i seq.len)
    acc
    (match (& (array-ref seq.slots i))
      [(Var _) (walk-borrow seq (+ i 1) (+ acc 1))]
      [_ (walk-borrow seq (+ i 1) acc)])))

(defstruct Holder
  (item Item)
  (next i64))

;; A borrow of a field through a reference parameter.
(define (count-field [h : (& Holder)] [k : i64] [acc : i64]) : i64
  (if (= k 0)
    acc
    (match (& h.item)
      [(Pair a _) (count-field h (- k 1) (+ acc a))]
      [_ (count-field h (- k 1) acc)])))

;; A two-word enum: the borrowed match spills the element to a frame slot.
(defenum Flag
  (On i64)
  (Off))

(defstruct FlagSeq
  (slots (__tl_dyn-array Flag))
  (len i64))

(define (sum-on [seq : (& FlagSeq)] [i : i64] [acc : i64]) : i64
  (if (>= i seq.len)
    acc
    (match (& (array-ref seq.slots i))
      [(On v) (sum-on seq (+ i 1) (+ acc v))]
      [(Off) (sum-on seq (+ i 1) acc)])))

(defstruct Pt
  (x i64)
  (y i64)
  (z i64))

(defenum Shape
  (Dot Pt)
  (Blank))

(define (pt-sum [p : (& Pt)]) : i64
  (+ p.x (+ p.y p.z)))

;; A frame local: `p` borrows the local's payload, so `pt-sum` keeps its call.
(define (local-shape [n : i64]) : i64
  (let
    [sh : Shape (Dot (Pt n 1 2))]
    (match (& sh)
      [(Dot p) (pt-sum p)]
      [(Blank) 0])))

(define (main) : i64
  (let
    [n : i64 300000]
    [slots : (__tl_dyn-array Item) (__tl_make-array Item n)]
    [flags : (__tl_dyn-array Flag) (__tl_make-array Flag n)]
    (for [k (iterator.range 0 n)]
      (set!
        (array-ref slots k)
        (if (= (% k 3) 0)
          (Var k)
          (Pair k k)))
      (set!
        (array-ref flags k)
        (if (= (% k 2) 0)
          (On 1)
          (Off))))
    (let
      [seq : ItemSeq (ItemSeq slots n)]
      [fseq : FlagSeq (FlagSeq flags n)]
      [h : Holder (Holder (Pair 2 3) 0)]
      [vars : i64 (walk-borrow (& seq) 0 0)]
      [ons : i64 (sum-on (& fseq) 0 0)]
      [field : i64 (count-field (& h) n 0)]
      (if (and (= vars 100000) (= ons 150000) (= field (* 2 n)))
        (local-shape 39)
        1))))