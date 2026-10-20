;; A tail call reuses its frame, so an argument may not point into that frame
;; (#9183). An argument that is, or holds, a reference or view must come from a
;; tail parameter, a re-borrowed reference parameter or storage outside the
;; frame; any other one keeps the call. Each `scrub` callee first fills its own
;; frame, so a read through a reference into the caller's abandoned frame sees
;; the fill instead of the value.
(import stdlib.iterator)

(defstruct Rec
  (x i64)
  (name String))

(defstruct CopyRec
  (x i64)
  (y i64)
  (z i64))

(defenum Holder
  (H Rec)
  (Nothing))

(defstruct Lst
  (slots (__tl_dyn-array i64))
  (len i64))

;; Fills 32 words of its own frame, then reads through `r`.
(define (scrub-ref [r : (& i64)] [seed : i64]) : i64
  (let
    [a : (Array i64 32)
      (array 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)]
    (for [k (iterator.range 0 32)]
      (set! (array-ref a k) (+ 2000000 k)))
    (+ (deref r) (- (array-ref a (% seed 32)) (array-ref a (% seed 32))))))

;; The same through a slice view, reading its first element.
(define (scrub-slice [xs : (& (Slice i64))] [seed : i64]) : i64
  (let
    [a : (Array i64 32)
      (array 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)]
    (for [k (iterator.range 0 32)]
      (set! (array-ref a k) (+ 3000000 k)))
    (+ (array-ref xs 0) (- (array-ref a (% seed 32)) (array-ref a (% seed 32))))))

(define (field-ref [r : (& r Rec)]) : (& r i64)
  (& r.x))

;; Frame provenance: each keeps its call.
;; A scalar field of a frame-local struct.
(define (local-field [n : i64]) : i64
  (let
    [r : Rec (Rec n "abc")]
    (scrub-ref (& r.x) 7)))

;; The callee's formal type inserts the same borrow for a plain field.
(define (local-implicit-field [n : i64]) : i64
  (let
    [r : Rec (Rec n "abc")]
    (scrub-ref r.x 7)))

(define (local-array-element [n : i64]) : i64
  (let
    [xs : (Array i64 3) (array n 0 0)]
    (scrub-ref (& (array-ref xs 0)) 7)))

;; Indirect calls use the same frame safety proof.
(define (local-indirect-field [f : (-> (& i64) i64 i64)] [n : i64]) : i64
  (let
    [r : Rec (Rec n "abc")]
    (f r.x 7)))

;; A shadowing local has a different IR identity from its reference parameter.
(define (shadowed-ref [r : (& i64)] [n : i64]) : i64
  (let
    [local : Rec (Rec n "abc")]
    (let
      [r : (& local i64) (& local.x)]
      (scrub-ref r 7))))

;; Reading a Copy aggregate out of heap storage copies it into this frame.
(define (heap-copy-field [n : i64]) : i64
  (let
    [xs : (__tl_dyn-array CopyRec) (__tl_make-array CopyRec 1)]
    (set! (array-ref xs 0) (CopyRec n 1 2))
    (let
      [copied : CopyRec (array-ref xs 0)]
      (scrub-ref (& copied.x) 7))))

;; A tuple field of a frame local.
(define (local-tuple [n : i64]) : i64
  (let
    [t : (Tuple i64 i64) (tuple n 1)]
    (scrub-ref (& (tuple-ref t 0)) 7)))

;; A slice of a frame-local array.
(define (local-slice [n : i64]) : i64
  (let
    [a : (Array i64 3) (array n 0 0)]
    (scrub-slice (slice-view (& a) 0 3) 7)))

;; A reference into a frame local, returned by a call.
(define (local-call-ref [n : i64]) : i64
  (let
    [r : Rec (Rec n "abc")]
    (scrub-ref (field-ref (& r)) 7)))

;; A payload field reached through a local reference to a frame-local enum.
(define (local-ref-scrutinee [n : i64]) : i64
  (let
    [e : Holder (H (Rec n "abc"))]
    (let
      [r : (& e Holder) (& e)]
      (match r
        [(H p) (scrub-ref (& p.x) 7)]
        [(Nothing) 0]))))

;; A let-bound reference to a frame-local scalar, passed directly and
;; re-borrowed.
(define (local-ref-direct [n : i64]) : i64
  (let
    [x : i64 n]
    (let
      [r : (& x i64) (& x)]
      (scrub-ref r 7))))

(define (local-ref-reborrow [n : i64]) : i64
  (let
    [x : i64 n]
    (let
      [r : (& x i64) (& x)]
      (scrub-ref (& r) 7))))

;; A let-bound slice view of a frame-local array.
(define (local-slice-view [n : i64]) : i64
  (let
    [a : (Array i64 3) (array n 0 0)]
    (let
      [v : (& a (Slice i64)) (slice-view (& a) 0 3)]
      (scrub-slice v 7))))

(define (lst-len [l : (& Lst)] [k : i64]) : i64
  (+ l.len k))

;; A let-bound reference to a frame-local aggregate, re-borrowed (#9137's
;; exemption covers only reference parameters).
(define (local-lst-reborrow [n : i64]) : i64
  (let
    [xs : Lst (Lst (__tl_make-array i64 1) n)]
    (let
      [l : (& xs Lst) (& xs)]
      (lst-len (& l) 0))))

;; Provenance outside the frame: each stays a tail call.
;; A reference parameter passed straight through, and re-borrowed.
(define (param-ref [r : (& i64)] [k : i64]) : i64
  (scrub-ref r k))

(define (param-reborrow [r : (& i64)] [k : i64]) : i64
  (scrub-ref (& r) k))

;; A field reached through a reference parameter: the caller's storage.
(define (param-field [r : (& Rec)] [k : i64]) : i64
  (scrub-ref (& r.x) k))

;; An element of a dynamic array: heap storage.
(define (heap-element [l : (& Lst)] [k : i64]) : i64
  (scrub-ref (& (array-ref l.slots 0)) k))

;; A slice of a dynamic array.
(define (heap-slice [l : (& Lst)] [k : i64]) : i64
  (scrub-slice (slice-view l.slots 0 1) k))

;; A direct projection keeps the heap element's address. Binding the Copy
;; aggregate to a local instead is covered by heap-copy-field above.
(define (heap-projected-field [n : i64]) : i64
  (let
    [xs : (__tl_dyn-array CopyRec) (__tl_make-array CopyRec 1)]
    (set! (array-ref xs 0) (CopyRec n 1 2))
    (scrub-ref (& (array-ref xs 0).x) 7)))

;; A borrow of a scalar local is a copy in its own heap storage.
(define (scalar-copy [n : i64]) : i64
  (let
    [x : i64 n]
    (scrub-ref (& x) 7)))

(define (main) : i64
  (let
    [rec : Rec (Rec 6 "r")]
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (set! (array-ref xs 0) 7)
    (let
      [lst : Lst (Lst xs 1)]
      [v : i64 9]
      [frame : i64
        (+
          (+ (local-field 1) (local-tuple 2))
          (+
            (+ (local-slice 3) (local-call-ref 4))
            (+
              (+ (local-ref-scrutinee 5) (local-ref-direct 6))
              (+
                (+ (local-ref-reborrow 7) (local-slice-view 8))
                (local-lst-reborrow 9)))))]
      [outside : i64
        (+
          (+ (param-ref (& v) 7) (param-reborrow (& v) 7))
          (+
            (+ (param-field (& rec) 7) (heap-element (& lst) 7))
            (+ (heap-slice (& lst) 7) (scalar-copy 9))))]
      [extra : i64
        (+
          (+ (local-implicit-field 1) (local-array-element 2))
          (+
            (local-indirect-field scrub-ref 3)
            (+ (shadowed-ref (& v) 4) (heap-copy-field 5))))]
      (if (and
        (= frame 45)
        (= outside 47)
        (= extra 15)
        (= (heap-projected-field 42) 42))
        42
        1))))