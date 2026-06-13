;; compile_profile_macro_detail.tl - Fixture for compile-profile macro rows.
(import "stdlib/string.tl")

(import "stdlib/core_macros.tl" module stdlib.core_macros as core)

(import "stdlib/str_cat.tl" module stdlib.str-cat as sc)

(define (profile-macro-detail-short-cat) : String
  (sc.str-cat "a" "b"))

(define (profile-macro-detail-packed-cat) : String
  (sc.str-cat "a" "b" "c" "d" "e" "f"))

(define (profile-macro-detail-bool [flag : bool]) : bool
  (core.and flag (core.or false true) true))

(define (main) : i64
  (if (core.cond
    (profile-macro-detail-bool true)
    (string-eq (profile-macro-detail-short-cat) "ab")
    false)
    (if (string-eq (profile-macro-detail-packed-cat) "abcdef")
      42
      1)
    1))