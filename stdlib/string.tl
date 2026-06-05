;# String utility library for TypeLisp.
;#
;# Provides higher-level string operations built on compiler primitives:
;# `string-length`, `string-ref`, `substring`, `string-append`, and
;# `string-eq`.
;#
;# Usage: `(import "stdlib/string.tl")`
;#
;# ```typelisp
;# (import "stdlib/string.tl")
;# (define ok : bool
;#   (let
;#     [s : String "  alpha  "]
;#     [haystack : String (string-trim-left (& s))]
;#     [needle : String "ph"]
;#     (string-contains (& haystack) (& needle))))
;# ```
;: Return true if the character is ASCII whitespace.
(define (is-char-whitespace [c : char]) : bool
  (or
    (char-eq c #\space')
    (or (char-eq c #\tab') (or (char-eq c #\newline') (char-eq c #\return')))))

;: Compare two chars for equality.
(define (char-eq [a : char] [b : char]) : bool
  (= (cast a : i64) (cast b : i64)))

;: Trim leading whitespace from borrowed text.
(define (string-trim-left [s : (& s str)]) : String
  (let
    [n : i64 (string-length s)]
    [i : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (is-char-whitespace (string-ref s i))
          (set! i (+ i 1))
          (set! done true)))
      (substring s i (- n i)))))

;: Trim trailing whitespace from borrowed text.
(define (string-trim-right [s : (& s str)]) : String
  (let
    [n : i64 (string-length s)]
    [i : i64 (- n 1)]
    [done : bool false]
    (begin
      (while (and (not done) (>= i 0))
        (if (is-char-whitespace (string-ref s i))
          (set! i (- i 1))
          (set! done true)))
      (substring s 0 (+ i 1)))))

;: Trim whitespace from both ends of borrowed text.
(define (string-trim [s : (& s str)]) : String
  (let
    [n : i64 (string-length s)]
    [start : i64 0]
    [end : i64 (- n 1)]
    [done-left : bool false]
    [done-right : bool false]
    (begin
      (while (and (not done-left) (< start n))
        (if (is-char-whitespace (string-ref s start))
          (set! start (+ start 1))
          (set! done-left true)))
      (while (and (not done-right) (>= end start))
        (if (is-char-whitespace (string-ref s end))
          (set! end (- end 1))
          (set! done-right true)))
      (substring s start (- (+ end 1) start)))))

;: Return true if haystack contains needle at any position.
(define (string-contains
  [haystack : (& haystack str)]
  [needle : (& needle str)]) : bool
  (let
    [hlen : i64 (string-length haystack)]
    [nlen : i64 (string-length needle)]
    (if (= nlen 0)
      true
      (if (> nlen hlen)
        false
        (let
          [found : bool false]
          [i : i64 0]
          (begin
            (while (and (not found) (<= i (- hlen nlen)))
              (if (is-string-prefix-at haystack needle i)
                (set! found true)
                (set! i (+ i 1))))
            found))))))

;: Return true if borrowed haystack contains the character c.
(define (string-contains-char [haystack : (& haystack str)] [c : char]) : bool
  (let
    [n : i64 (string-length haystack)]
    [found : bool false]
    [i : i64 0]
    (begin
      (while (and (not found) (< i n))
        (if (char-eq (string-ref haystack i) c)
          (set! found true)
          (set! i (+ i 1))))
      found)))

;: Replace first occurrence of old with new in s.
;:
;: Returns s unchanged if old is not present. Full multi-replace needs a string
;: builder.
(define (string-replace [s : String] [old : String] [new : String]) : String
  (let
    [hlen : i64 (string-length s)]
    [olen : i64 (string-length old)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (<= i (- hlen olen)))
        (let
          [j : i64 0]
          [ok : bool true]
          (begin
            (while (and ok (< j olen))
              (if (char-eq (string-ref s (+ i j)) (string-ref old j))
                (set! j (+ j 1))
                (set! ok false)))
            (if ok
              (set! found true)
              (set! i (+ i 1))))))
      (if found
        (begin
          (string-append
            (string-append (substring s 0 i) new)
            (substring s (+ i olen) (- (- hlen i) olen))))
        s))))

;: Return true if haystack has needle at position start.
(define (is-string-prefix-at
  [haystack : (& haystack str)]
  [needle : (& needle str)]
  [start : i64]) : bool
  (let
    [hlen : i64 (string-length haystack)]
    [nlen : i64 (string-length needle)]
    (if (< start 0)
      false
      (if (> (+ start nlen) hlen)
        false
        (let
          [ok : bool true]
          [j : i64 0]
          (begin
            (while (and ok (< j nlen))
              (if (char-eq
                (string-ref haystack (+ start j))
                (string-ref needle j))
                (set! j (+ j 1))
                (set! ok false)))
            ok))))))