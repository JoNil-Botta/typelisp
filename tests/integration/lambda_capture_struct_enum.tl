; Capturing scalar-field struct and enum values in closure environments (#540).
; Each case reads scalars out of a captured aggregate; `main` yields 42 only if
; every case holds. The "returned" cases capture an aggregate whose inline
; storage is frame-owned in the maker, then read it after the maker returns, so
; they only pass if the capture snapshots the storage onto the heap.
(defstruct Point
  (x i64)
  (y i64))

; Struct captured and read while the creator scope is still live.
(define (case-struct-immediate) : bool
  (let (
    [p : Point (Point 40 2)]
    [f : (-> i64) (lambda () : i64 (+ (struct-get p x) (struct-get p y)))])
    (= (f) 42)))

; Struct captured by a closure that OUTLIVES the frame that built it.
(define (make-x-reader [p : Point]) : (-> i64)
  (lambda () : i64 (struct-get p x)))

(define (case-struct-returned) : bool
  (= ((make-x-reader (Point 42 7))) 42))

(defenum Shape
  (Circle i64)
  (Rect i64 i64)
  (Nothing))

; Enum (scalar payloads) captured by a returned closure, then matched after the
; maker returns.
(define (make-area [s : Shape]) : (-> i64)
  (lambda
    ()
    :
    i64
    (match s
      [(Circle r) r]
      [(Rect w h) (* w h)]
      [(Nothing) 0])))

(define (case-enum-returned) : bool
  (if (= ((make-area (Circle 42))) 42)
    (= ((make-area (Rect 6 7))) 42)
    false))

(define (main) : i64
  (if (case-struct-immediate)
    (if (case-struct-returned)
      (if (case-enum-returned)
        42
        3)
      2)
    1))