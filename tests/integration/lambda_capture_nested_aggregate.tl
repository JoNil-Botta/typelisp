; Capturing nested aggregate fields in local closure environments (#584).
; `main` yields 42 only if every snapshot case holds.
(import stdlib.array)

;; lint-allow: unused-import
(import stdlib.string)

(defstruct Label
  (id i64)
  (name String))

(define (case-struct-string) : bool
  (let
    [l : Label (Label 38 "abcd")]
    [f : (-> i64)
      (lambda () : i64
        (+ (struct-get l id) (string.string-length (struct-get l name))))]
    (= (f) 42)))

(defstruct Bag
  (items (__tl_dyn-array i64)))

(define (case-struct-dynarray) : bool
  (let
    [a : (__tl_dyn-array i64) (array.make-array i64 1)]
    (begin
      (array-set! a 0 42)
      (let
        [b : Bag (Bag a)]
        [f : (-> i64)
          (lambda () : i64
            (array-ref (struct-get b items) 0))]
        (= (f) 42)))))

(defenum Wrapped
  (WrappedLabel Label)
  (WrappedText String)
  (WrappedNumber i64))

(define (case-wrapped-label) : bool
  (let
    [w : Wrapped (WrappedLabel (Label 39 "abc"))]
    [f : (-> i64)
      (lambda () : i64
        (match w
          [(WrappedLabel l)
            (+ (struct-get l id) (string.string-length (struct-get l name)))]
          [(WrappedText s) (string.string-length s)]
          [(WrappedNumber n) n]))]
    (= (f) 42)))

(define (case-wrapped-text) : bool
  (let
    [w : Wrapped (WrappedText "abcdefghijklmnopqrstuvwxyzabcdefghijklmnop")]
    [f : (-> i64)
      (lambda () : i64
        (match w
          [(WrappedLabel l)
            (+ (struct-get l id) (string.string-length (struct-get l name)))]
          [(WrappedText s) (string.string-length s)]
          [(WrappedNumber n) n]))]
    (= (f) 42)))

(define (case-enum-nested) : bool
  (and (case-wrapped-label) (case-wrapped-text)))

(define (main) : i64
  (begin
    (unless (case-struct-string) (return 1))
    (unless (case-struct-dynarray) (return 2))
    (unless (case-enum-nested) (return 3))
    42))