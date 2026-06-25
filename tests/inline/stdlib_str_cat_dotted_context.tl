;; stdlib_str_cat_dotted_context.tl - exported str_cat macro expansions keep
;; the stdlib.str_cat module's helper import context.
(import stdlib.test)
(import stdlib.str_cat)

(test
  dotted-str-cat-fixed-arity-keeps-helper-context
  (let
    [got : String (str_cat.str-cat "alpha" ":" "beta")]
    [want : String "alpha:beta"]
    (test.assert-string-eq
      (& got)
      (& want)
      "dotted str-cat fixed arity helper context")))

(test
  dotted-str-cat-packed-arity-keeps-helper-context
  (let
    [got : String (str_cat.str-cat "a" "b" "c" "d" "e" "f" "g")]
    [want : String "abcdefg"]
    (test.assert-string-eq
      (& got)
      (& want)
      "dotted str-cat packed arity helper context")))