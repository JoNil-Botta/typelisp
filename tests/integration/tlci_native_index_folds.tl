;; tlci_native_index_folds.tl - drive the tlci index-fold macro bodies through
;; whichever macro route the compiler selects, so the embedded (native) and
;; comment-modified-root (interpreted) routes can be compared for byte-identical
;; assembly.
;;
;; `str-cat` at six or more operands folds through
;; `stdlib.str_cat_runtime/str-cat-pack`, and `path-join-many` folds through
;; `stdlib.fs/path-join-fold`. Both walk an operand list by index, so a fold
;; that stops one element early, repeats one, or reverses the order still
;; compiles and still runs -- only the differential catches it, which is why the
;; fixture checks exact strings rather than lengths. Refs #5647, #5596.
;; Exit code: 42
(import stdlib.fs)
(import stdlib.string)
(import stdlib.str_cat)

(define (fold-checks-ok?) : bool
  (let
    [six : String (str_cat.str-cat "a" "b" "c" "d" "e" "f")]
    [seven : String (str_cat.str-cat "1" "2" "3" "4" "5" "6" "7")]
    [mixed : String
      (str_cat.str-cat "head/" "one" "-" "two" "-" "three" "/tail")]
    [empties : String (str_cat.str-cat "" "x" "" "y" "" "z")]
    [two-segments : String (fs.path-join-many "usr" "local")]
    [five-segments : String
      (fs.path-join-many "usr" "local" "share" "typelisp" "stdlib")]
    (and
      (string.eq six "abcdef")
      (string.eq seven "1234567")
      (string.eq mixed "head/one-two-three/tail")
      (string.eq empties "xyz")
      (string.eq two-segments (fs.path-join-owned-pair "usr" "local"))
      (string.eq
        five-segments
        (fs.path-join-owned-pair
          (fs.path-join-owned-pair
            (fs.path-join-owned-pair
              (fs.path-join-owned-pair "usr" "local")
              "share")
            "typelisp")
          "stdlib")))))

(define (main) : i64
  (if (fold-checks-ok?)
    42
    1))