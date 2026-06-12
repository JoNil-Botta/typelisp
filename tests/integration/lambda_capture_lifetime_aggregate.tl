; #1867 + #2356 follow-up: capturing lifetime-parameterized inline aggregates
; (`AstTyStructArgs` / `AstTyEnumArgs`) in closure environments. The default
; inline-aggregate flip stores struct/enum values inline; a closure that
; captures such a value must snapshot it into the closure environment. The
; capture-support classifier, slot typing, and snapshot dispatch matched only
; the bare `AstTyStruct` / `AstTyEnum` forms, so a parameterized aggregate fell
; through -- `lower-supported-capture-type?` rejected it and the program failed
; to compile. Each case reads a scalar out of a captured parameterized
; aggregate; `main` yields 42 only if every case holds.
(defenum RefChoice
  (:lifetimes text)
  (RefChoiceBorrowed (& text str))
  (RefChoiceOwned String))

(defstruct RefBox
  (:lifetimes text)
  (borrowed (& text str))
  (owned String)
  (is-owned bool))

(define (choice-length [choice : (RefChoice text)]) : i64
  (match choice
    [(RefChoiceBorrowed value) (string-length value)]
    [(RefChoiceOwned value) (string-length value)]))

(define (box-length [item : (RefBox text)]) : i64
  (if (struct-get item is-owned)
    (string-length (struct-get item owned))
    (string-length (struct-get item borrowed))))

; A parameterized enum holding a borrowed reference, captured and read while
; the borrow source is still live.
(define (capture-enum-borrowed [text : (& text str)]) : i64
  (let
    [c : (RefChoice text) (RefChoiceBorrowed text)]
    [f : (-> i64)
      (lambda () : i64
        (choice-length c))]
    (f)))

; A parameterized enum holding an owned String, captured and read.
(define (capture-enum-owned [text : (& text str)] [owned : String]) : i64
  (let
    [c : (RefChoice text) (RefChoiceOwned owned)]
    [f : (-> i64)
      (lambda () : i64
        (choice-length c))]
    (f)))

; A parameterized struct with a borrowed field, captured and read.
(define (capture-struct-borrowed [text : (& text str)] [owned : String]) : i64
  (let
    [b : (RefBox text) (RefBox text owned false)]
    [f : (-> i64)
      (lambda () : i64
        (box-length b))]
    (f)))

(define (main) : i64
  (let
    [s : String "hello"]
    [owned : String "abc"]
    (if (and
      (= (capture-enum-borrowed (& s)) 5)
      (= (capture-enum-owned (& s) owned) 3)
      (= (capture-struct-borrowed (& s) owned) 5))
      42
      1)))