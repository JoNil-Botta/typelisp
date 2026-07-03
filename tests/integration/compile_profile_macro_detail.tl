;; compile_profile_macro_detail.tl - Fixture for compile-profile macro rows.
(import "stdlib/string.tl")
(import "stdlib/str_cat.tl" module stdlib.str_cat as sc)

(define (profile-macro-detail-short-cat) : String
  (sc.str-cat "a" "b"))

(define (profile-macro-detail-packed-cat) : String
  (sc.str-cat "a" "b" "c" "d" "e" "f"))

(define (profile-macro-detail-bool [flag : bool]) : bool
  (and flag (or false true) true))

(define (main) : i64
  (if (cond
    [(profile-macro-detail-bool true)
      (eq (profile-macro-detail-short-cat) "ab")]
    [else false])
    (if (eq (profile-macro-detail-packed-cat) "abcdef")
      42
      1)
    1))