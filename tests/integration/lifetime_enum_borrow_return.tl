;; refs #2356/#2608: a lifetime-parameterized enum carrying a borrowed str
;; payload is returned by value, survives unrelated stack churn, and projects
;; the borrowed payload from the correct inline slot.
(defenum BorrowedChoice
  (:lifetimes text)
  (BorrowedChoiceText (& text str) i64)
  (BorrowedChoiceEmpty))

(define (make-borrowed-choice [text : (& text str)]) : (BorrowedChoice text)
  (BorrowedChoiceText text 17))

(define (clobber-stack [n : i64]) : i64
  (let
    [a : i64 (+ n 1)]
    [b : i64 (+ n 2)]
    [c : i64 (+ n 3)]
    (if (<= n 0)
      (+ a (+ b c))
      (+ a (clobber-stack (- n 1))))))

(define (borrowed-choice-score [choice : (BorrowedChoice text)]) : i64
  (match choice
    [(BorrowedChoiceText value bonus) (+ (string-length value) bonus)]
    [(BorrowedChoiceEmpty) 0]))

(define (roundtrip-borrowed-choice [text : (& text str)]) : i64
  (let
    [choice : (BorrowedChoice text) (make-borrowed-choice text)]
    [_ : i64 (clobber-stack 32)]
    (borrowed-choice-score choice)))

(define (main) : i64
  (let
    [text : String "borrowed-payload-works-now"]
    (if (= (roundtrip-borrowed-choice (& text)) 43)
      42
      1)))