;; A module that declares its own `string-concat` and `string-eq` beside
;; `(import stdlib.string)`. Its own bare calls reach these definitions, while
;; its bare `string=?` is still stdlib.string's helper (#7957). The definitions
;; keep the helpers' signatures; a different signature is #8096.
(import stdlib.string)

(define (string-concat [_left : String] [right : String]) : String
  right)

(define (string-eq [_left : String] [_right : String]) : bool
  false)

(define (joined [left : String] [right : String]) : String
  (string-concat left right))

(define (same? [left : String] [right : String]) : bool
  (string-eq left right))

(define (same-helper? [left : String] [right : String]) : bool
  (string=? left right))