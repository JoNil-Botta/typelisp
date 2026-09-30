;; Inside the caller's own `unsafe`, each `stdlib.serialize` view macro
;; compiles when called directly, through an import alias and through another
;; macro (#7701). Every viewed source is consumed by its read and every index
;; is below the array length.
(import stdlib.serialize)
(import stdlib.serialize as s)
(import stdlib.string)

(defmacro (user-view [place : Expr]) : Expr
  `(serialize.serialize-shared-view ,place))

(defmacro (user-element-view [items : Expr] [index : Expr]) : Expr
  `(s.serialize-array-element-shared-view ,items ,index))

(define (main) : i64
  (let
    [a : String "a"]
    [b : String "b"]
    [c : String "c"]
    [items : (__tl_dyn-array String) (__tl_make-array String 2)]
    (begin
      (__tl_array-set! items 0 "d")
      (__tl_array-set! items 1 "e")
      (let
        [va : String
          (unsafe
            (serialize.serialize-shared-view a))]
        [vb : String
          (unsafe
            (s.serialize-shared-view b))]
        [vc : String
          (unsafe
            (user-view c))]
        [n : i64 (__tl_array-length items)]
        [vd : String
          (if (> n 0)
            (unsafe
              (serialize.serialize-array-element-shared-view items 0))
            "")]
        [ve : String
          (if (> n 1)
            (unsafe
              (user-element-view items 1))
            "")]
        (if (and
          (string.eq va "a")
          (string.eq vb "b")
          (string.eq vc "c")
          (string.eq vd "d")
          (string.eq ve "e"))
          42
          1)))))