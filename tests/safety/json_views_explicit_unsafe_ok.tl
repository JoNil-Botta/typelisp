;; Inside the caller's own `unsafe`, each `stdlib.json` view macro compiles
;; when called directly, through an import alias and through another macro
;; (#7701). Every viewed source is consumed by its read and every index is
;; below the live length.
(import stdlib.json)
(import stdlib.json as j)
(import stdlib.string)

(defmacro (user-view [place : Expr]) : Expr
  `(json.json-shared-view ,place))

(defmacro (user-element-view [items : Expr] [index : Expr]) : Expr
  `(j.json-array-element-shared-view ,items ,index))

(defmacro (user-box-view [value : Expr]) : Expr
  `(json.json-box-shared-view ,value))

(define (string-value? [value : json.Json] [expected : String]) : bool
  (match value
    [(json.JsonString text) (string.eq text expected)]
    [_ false]))

(define (main) : i64
  (let
    [a : json.Json (json.JsonString "a")]
    [b : json.Json (json.JsonString "b")]
    [c : json.Json (json.JsonString "c")]
    [items : json.JsonSeq
      (json.list-cons (json.JsonString "d") (json.list-empty))]
    [more : json.JsonSeq
      (json.list-cons (json.JsonString "e") (json.list-empty))]
    [boxed : (Box json.JsonSeq)
      (box (json.list-cons (json.JsonNull) (json.list-empty)))]
    [aliased-boxed : (Box json.JsonSeq) (box (json.list-empty))]
    [n : i64 (json.list-count-ref (& items))]
    [m : i64 (json.list-count-ref (& more))]
    [va : json.Json
      (unsafe
        (json.json-shared-view a))]
    [vb : json.Json
      (unsafe
        (j.json-shared-view b))]
    [vc : json.Json
      (unsafe
        (user-view c))]
    [vd : json.Json
      (if (> n 0)
        (unsafe
          (json.json-array-element-shared-view items.slots 0))
        json.JsonNull)]
    [ve : json.Json
      (if (> m 0)
        (unsafe
          (user-element-view more.slots 0))
        json.JsonNull)]
    [inner : json.JsonSeq
      (unsafe
        (user-box-view boxed))]
    [aliased-inner : json.JsonSeq
      (unsafe
        (j.json-box-shared-view aliased-boxed))]
    (if (and
      (string-value? va "a")
      (string-value? vb "b")
      (string-value? vc "c")
      (string-value? vd "d")
      (string-value? ve "e")
      (= (json.list-count inner) 1)
      (= (json.list-count aliased-inner) 0))
      42
      1)))