;; str_cat_scoped_region.tl - fixed-arity str-cat accepts current-region text
;; without moving operands outside the scoped arena.
(import stdlib.string)
(import stdlib.str_cat)

(define (main) : i64
  (with-arena
    frame
    (let
      [one : String (string.int->string 1)]
      [two : String (string.int->string 2)]
      [three : String (string.int->string 3)]
      [four : String (string.int->string 4)]
      [got2 : String (str_cat.str-cat "visible:" one)]
      [got3 : String (str_cat.str-cat one ":" two)]
      [got4 : String (str_cat.str-cat one ":" two three)]
      [got5 : String (str_cat.str-cat one ":" two three four)]
      (if (and
        (string.eq got2 "visible:1")
        (string.eq got3 "1:2")
        (string.eq got4 "1:23")
        (string.eq got5 "1:234"))
        42
        1))))