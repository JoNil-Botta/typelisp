; Capturing String and dynamic-array values in closure environments (#435).
; Each case reads a scalar out of a captured aggregate so the test exercises
; capture (not aggregate returns); `main` yields 42 only if every case holds.
;; lint-allow: unused-import
(import stdlib.string)

; A String captured and used while the creator scope is still live.
(define (case-string-immediate) : bool
  (let
    [s : String "hello"]
    [f : (-> i64)
      (lambda () : i64
        (string.string-length s))]
    (= (f) 5)))

; A dynamic array captured and indexed in the same scope.
(define (case-dynarray-elem) : bool
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (begin
      (set! (array-ref a 2) 9)
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
          (+ n (string.string-length s))))
      42)))

(define (main) : i64
  (begin
    (unless (case-string-immediate) (return 1))
    (unless (case-dynarray-elem) (return 2))
    (unless (case-mixed) (return 3))
    42))