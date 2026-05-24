;;;; String utility library for TypeLisp.
;;;;
;;;; Provides higher-level string operations built on compiler primitives:
;;;; `string-length`, `string-ref`, `substring`, `string-append`, and
;;;; `string-eq`.
;;;;
;;;; Usage: `(import "stdlib/string.tl")`
;;;;
;;;; ```typelisp
;;;; (import "stdlib/string.tl")
;;;; (define ok : bool (string-contains (string-trim "  alpha  ") "ph"))
;;;; ```
;;; Return true if the character is ASCII whitespace.
(define (is-char-whitespace [c : char]) : bool
  (or
    (char-eq c #\space')
    (or (char-eq c #\tab') (or (char-eq c #\newline') (char-eq c #\return')))))

;;; Compare two chars for equality.
(define (char-eq [a : char] [b : char]) : bool
  (= (cast a : i64) (cast b : i64)))

;;; Trim leading whitespace from a string.
(define (string-trim-left [s : String]) : String
  (let ([n : i64 (string-length s)])
    (let (
      [i : i64 0]
      [done : bool false])
      (begin
        (while (and (not done) (< i n))
          (if (is-char-whitespace (string-ref s i))
            (set! i (+ i 1))
            (set! done true)))
        (substring s i (- n i))))))

;;; Trim trailing whitespace from a string.
(define (string-trim-right [s : String]) : String
  (let ([n : i64 (string-length s)])
    (let (
      [i : i64 (- n 1)]
      [done : bool false])
      (begin
        (while (and (not done) (>= i 0))
          (if (is-char-whitespace (string-ref s i))
            (set! i (- i 1))
            (set! done true)))
        (substring s 0 (+ i 1))))))

;;; Trim whitespace from both ends.
(define (string-trim [s : String]) : String
  (string-trim-left (string-trim-right s)))

;;; Return true if haystack contains needle at any position.
(define (string-contains [haystack : String] [needle : String]) : bool
  (let (
    [hlen : i64 (string-length haystack)]
    [nlen : i64 (string-length needle)])
    (if (= nlen 0)
      true
      (if (> nlen hlen)
        false
        (let (
          [found : bool false]
          [i : i64 0])
          (begin
            (while (and (not found) (<= i (- hlen nlen)))
              (if (is-string-prefix-at haystack needle i)
                (set! found true)
                (set! i (+ i 1))))
            found))))))

;;; Return true if haystack contains the character c.
(define (string-contains-char [haystack : String] [c : char]) : bool
  (let (
    [n : i64 (string-length haystack)]
    [found : bool false]
    [i : i64 0])
    (begin
      (while (and (not found) (< i n))
        (if (char-eq (string-ref haystack i) c)
          (set! found true)
          (set! i (+ i 1))))
      found)))

;;; Replace first occurrence of old with new in s.
;;;
;;; Returns s unchanged if old is not present. Full multi-replace needs a string
;;; builder.
(define (string-replace [s : String] [old : String] [new : String]) : String
  (if (string-contains s old)
    (let (
      [hlen : i64 (string-length s)]
      [olen : i64 (string-length old)]
      [i : i64 0]
      [found : bool false])
      (begin
        (while (and (not found) (<= i (- hlen olen)))
          (if (is-string-prefix-at s old i)
            (set! found true)
            (set! i (+ i 1))))
        (string-append
          (string-append (substring s 0 i) new)
          (substring s (+ i olen) (- (- hlen i) olen)))))
    s))

;;; Return true if haystack has needle at position start.
(define (is-string-prefix-at
  [haystack : String]
  [needle : String]
  [start : i64]) : bool
  (let (
    [hlen : i64 (string-length haystack)]
    [nlen : i64 (string-length needle)])
    (if (< start 0)
      false
      (if (> (+ start nlen) hlen)
        false
        (let (
          [ok : bool true]
          [j : i64 0])
          (begin
            (while (and ok (< j nlen))
              (if (char-eq
                (string-ref haystack (+ start j))
                (string-ref needle j))
                (set! j (+ j 1))
                (set! ok false)))
            ok))))))