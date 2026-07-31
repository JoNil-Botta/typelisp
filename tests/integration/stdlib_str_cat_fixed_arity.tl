;; stdlib_str_cat_fixed_arity.tl - compare public fixed-arity concat helpers
;; with the backend-local helper shape that #3888 is retiring.
;; Exit code: 42
(import stdlib.array)
(import stdlib.string)
(import stdlib.str_cat)

(define (fixture-copy-chunk-into
  [chunk : String]
  [dst : (MutPtr u8)]
  [start : i64]) : unit
  (let
    [clen : i64 (string.string-length chunk)]
    [src : (Ptr u8)
      (unsafe
        (string-data (& chunk)))]
    [words : i64 (/ clen 8)]
    [src64 : (Ptr i64)
      (unsafe
        (ptr-cast src : (Ptr i64)))]
    [dst64 : (MutPtr i64)
      (unsafe
        (ptr-cast (ptr-offset dst start) : (MutPtr i64)))]
    [w : i64 0]
    [b : i64 (* words 8)]
    (begin
      (while (< w words)
        (begin
          (unsafe
            (ptr-write! (ptr-offset dst64 w) (ptr-read (ptr-offset src64 w))))
          (set! w (+ w 1))))
      (while (< b clen)
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset dst (+ start b))
              (ptr-read (ptr-offset src b))))
          (set! b (+ b 1))))
      unit)))

(define (fixture-backend-cat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (let
    [la : i64 (string.string-length a)]
    [lb : i64 (string.string-length b)]
    [lc : i64 (string.string-length c)]
    [ld : i64 (string.string-length d)]
    [le : i64 (string.string-length e)]
    [total : i64 (+ la (+ lb (+ lc (+ ld le))))]
    (if (= total 0)
      ""
      (let
        [out : (__tl_dyn-array u8) (array.make-array u8 total)]
        [dst : (MutPtr u8)
          (unsafe
            (array-data out))]
        (begin
          (fixture-copy-chunk-into a dst 0)
          (fixture-copy-chunk-into b dst la)
          (fixture-copy-chunk-into c dst (+ la lb))
          (fixture-copy-chunk-into d dst (+ la (+ lb lc)))
          (fixture-copy-chunk-into e dst (+ la (+ lb (+ lc ld))))
          (unsafe
            (string-from-bytes (ptr-cast dst : (Ptr u8)) total)))))))

(define (main) : i64
  (let
    [a : String "call "]
    [b : String "*"]
    [c : String "%rax"]
    [d : String "\n"]
    [e : String "tail"]
    [backend : String (fixture-backend-cat5 a b c d e)]
    [public : String (string.concat5 a b c d e)]
    [macro : String (str_cat.str-cat a b c d e)]
    [short-public : String (string.concat3 "leaq " "%rax" "\n")]
    [short-macro : String (str_cat.str-cat "leaq " "%rax")]
    [empty-backend : String (fixture-backend-cat5 "" "" "" "" "")]
    [empty-public : String (string.concat5 "" "" "" "" "")]
    [empty-macro : String (str_cat.str-cat "" "")]
    (if (and
      (string.eq backend public)
      (string.eq backend macro)
      (string.eq short-public "leaq %rax\n")
      (string.eq short-macro "leaq %rax")
      (string.eq empty-backend "")
      (string.eq empty-public "")
      (string.eq empty-macro ""))
      42
      1)))