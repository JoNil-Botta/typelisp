; Capturing nested aggregate fields in closure environments (#584).
; Returned closures read through copied nested handles after the creator frame
; has returned. `main` yields 42 only if every case holds.

(defstruct Label (id i64) (name String))

(define (make-label-reader) : (-> i64)
  (let ([l : Label (Label 38 "abcd")])
    (lambda () : i64 (+ (struct-get l id) (string-length (struct-get l name))))))

(define (case-struct-string) : bool
  (= ((make-label-reader)) 42))

(defstruct Bag (items (Array i64)))

(define (make-bag-reader) : (-> i64)
  (let ([a : (Array i64) (make-array i64 1)])
    (begin
      (array-set! a 0 42)
      (let ([b : Bag (Bag a)])
        (lambda () : i64 (array-ref (struct-get b items) 0))))))

(define (case-struct-dynarray) : bool
  (= ((make-bag-reader)) 42))

(defenum Wrapped (WrappedLabel Label) (WrappedText String) (WrappedNumber i64))

(define (make-wrapped-label-reader) : (-> i64)
  (let ([w : Wrapped (WrappedLabel (Label 39 "abc"))])
    (lambda () : i64
      (match w
        [(WrappedLabel l) (+ (struct-get l id) (string-length (struct-get l name)))]
        [(WrappedText s) (string-length s)]
        [(WrappedNumber n) n]))))

(define (make-wrapped-text-reader) : (-> i64)
  (let ([w : Wrapped (WrappedText "abcdefghijklmnopqrstuvwxyzabcdefghijklmnop")])
    (lambda () : i64
      (match w
        [(WrappedLabel l) (+ (struct-get l id) (string-length (struct-get l name)))]
        [(WrappedText s) (string-length s)]
        [(WrappedNumber n) n]))))

(define (case-enum-nested) : bool
  (if (= ((make-wrapped-label-reader)) 42)
      (= ((make-wrapped-text-reader)) 42)
      false))

(define (main) : i64
  (if (case-struct-string)
      (if (case-struct-dynarray)
          (if (case-enum-nested) 42 3)
          2)
      1))
