;; Functions spelled like the string helpers and builtins, with results the
;; builtins never produce. A macro that names them qualified must call these
;; (macro_qualified_helpers).
(defstruct Cell
  (v i64))

(defstruct Pair
  (a i64)
  (b i64))

(define (string-length [text : String]) : i64
  99)

(define (string-ref [text : String] [index : i64]) : char
  'z')

(define (char-at [text : String] [index : i64]) : char
  'u')

(define (eq [left : String] [right : String]) : bool
  true)

(define (string-eq [left : String] [right : String]) : bool
  true)

(define (string=? [left : String] [right : String]) : bool
  true)

(define (string-append [left : String] [right : String]) : String
  "user")

(define (string-concat [left : String] [right : String]) : String
  "user")

(define (clone [cell : (& cell Cell)]) : Pair
  (Pair 40 2))