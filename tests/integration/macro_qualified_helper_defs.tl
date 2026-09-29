;; Functions spelled like the string helpers and builtins, with results the
;; builtins never produce. A macro that names them qualified must call these
;; (macro_qualified_helpers).
(defstruct Cell
  (v i64))

(defstruct Pair
  (a i64)
  (b i64))

(define (string-length [_text : String]) : i64
  99)

(define (string-ref [_text : String] [_index : i64]) : char
  'z')

(define (char-at [_text : String] [_index : i64]) : char
  'u')

(define (eq [_left : String] [_right : String]) : bool
  true)

(define (string-eq [_left : String] [_right : String]) : bool
  true)

;; lint-allow: function-name-case -- the helper spelling under test
(define (string=? [_left : String] [_right : String]) : bool
  true)

(define (string-append [_left : String] [_right : String]) : String
  "user")

(define (string-concat [_left : String] [_right : String]) : String
  "user")

(define (clone [cell : (& cell Cell)]) : Pair
  (Pair 40 2))