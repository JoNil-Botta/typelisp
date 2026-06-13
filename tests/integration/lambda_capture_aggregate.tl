; Capturing String and dynamic-array values in closure environments (#435).
; Each case reads a scalar out of a captured aggregate so the test exercises
; capture (not aggregate returns); `main` yields 42 only if every case holds.
; A String captured and used while the creator scope is still live.
(define (case-string-immediate) : bool
  (let
    [s : String "hello"]
    [f : (-> i64)
      (lambda () : i64
        (string-length s))]
    (= (f) 5)))

; A String literal captured by a closure that OUTLIVES the frame that created
; it: the fat value is frame-owned in `make-str-reader`, so this only works if
; the capture snapshots it onto the heap.
(define (make-str-reader [s : String]) : (-> char)
  (lambda () : char
    (char-at s 0)))

(define (case-string-returned) : bool
  (= ((make-str-reader "Z")) #Z'))

; A dynamic array created inside `make-arr`'s frame, captured by the returned
; closure, and read after `make-arr` returns (the key dangling case).
(define (make-arr) : (-> i64)
  (let
    [a : (Array i64) (make-array i64 3)]
    (begin
      (array-set! a 0 42)
      (lambda () : i64
        (array-ref a 0)))))

(define (case-dynarray-returned) : bool
  (= ((make-arr)) 42))

; A dynamic array captured and indexed in the same scope.
(define (case-dynarray-elem) : bool
  (let
    [a : (Array i64) (make-array i64 4)]
    (begin
      (array-set! a 2 9)
      (=
        ((lambda () : i64
            (array-ref a 2)))
        9))))

; Mixed capture: a scalar and a String captured together.
(define (case-mixed) : bool
  (let
    [n : i64 40]
    [s : String "ab"]
    (=
      ((lambda () : i64
          (+ n (string-length s))))
      42)))

(define (main) : i64
  (begin
    (unless (case-string-immediate) (return 1))
    (unless (case-string-returned) (return 2))
    (unless (case-dynarray-returned) (return 3))
    (unless (case-dynarray-elem) (return 4))
    (unless (case-mixed) (return 5))
    42))