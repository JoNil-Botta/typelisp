(import stdlib.string)
(import stdlib.io)

(defstruct Label
  (text String)
  (code i64))

(defstruct Nested
  (ignored String)
  (label Label))

(define (tuple-length [items : (& items (Tuple Label i64))]) : i64
  (match items
    [(tuple (Label text _) _) (string.string-length text)]))

(define (tuple-content
  [items : (& items (Tuple Label i64))]
  [expected : (& expected str)]) : bool
  (match items
    [(tuple (Label text _) _) (string.eq text expected)]))

(define (array-score [items : (& items (Array Label 2))]) : i64
  (match items
    [(array (Label first first-code) (Label second second-code))
      (if (and (string.eq first "abc") (string.eq second ""))
        (+
          (string.string-length first)
          (string.string-length second)
          first-code
          second-code)
        1)]))

(define (nested-score [items : (& items (Tuple Nested i64))]) : i64
  (match items
    [(tuple (Nested _ (Label text code)) _)
      (if (string.eq text "nested")
        (+ (string.string-length text) code)
        1)]))

(define (owner-score [items : (Tuple Label i64)]) : i64
  (let
    [length : i64
      (match (& items)
        [(tuple (Label text _) _) (string.string-length text)])]
    (+ length (tuple-ref items 1))))

(define (owned-score [items : (Tuple Label i64)]) : i64
  (match items
    [(tuple (Label text code) _) (+ (string.string-length text) code)]))

(define (exercise) : i64
  (let
    [items : (Tuple Label i64) (tuple (Label "abc" 39) 0)]
    [empty : (Tuple Label i64) (tuple (Label "" 42) 0)]
    [labels : (Array Label 2) (array (Label "abc" 20) (Label "" 19))]
    [nested : (Tuple Nested i64)
      (tuple (Nested "ignored" (Label "nested" 36)) 0)]
    (unless (= (tuple-length (& items)) 3) (return 1))
    (unless (tuple-content (& items) "abc") (return 2))
    (unless (= (tuple-length (& empty)) 0) (return 3))
    (unless (tuple-content (& empty) "") (return 4))
    (unless (= (array-score (& labels)) 42) (return 5))
    (unless (= (nested-score (& nested)) 42) (return 6))
    (unless (= (owner-score (tuple (Label "abc" 0) 39)) 42) (return 7))
    (unless (= (owned-score (tuple (Label "abc" 39) 0)) 42) (return 8))
    42))

(define (main) : i64
  (exercise))

(test
  borrowed-struct-pattern-string
  (unless
    (= (exercise) 42)
    (io.panic "borrowed struct String pattern result mismatch")))