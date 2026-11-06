;; Plain annotations keep shared Box, nominal and String field/name views.
;; Reading and reborrowing the aliases is legal; their loans end at last use.
(import stdlib.string)

(defstruct Inner
  (b (Box i64)))

(defstruct Holder
  (b (Box i64))
  (inner Inner)
  (text String))

(define (peek [b : (& b (Box i64))]) : i64
  (deref (deref b)))

(define (read-inner [inner : (& inner Inner)]) : i64
  (deref inner.b))

(define (main) : i64
  (let
    [holder : Holder (Holder (box 10) (Inner (box 10)) (string.copy "ab"))]
    [shared : (& holder Holder) (& holder)]
    [b : (Box i64) shared.b]
    [box-name : (Box i64) b]
    [inner : Inner shared.inner]
    [inner-name : Inner inner]
    [text : String shared.text]
    [text-name : String text]
    [result : i64
      (+
        (+ (deref box-name) (peek (& box-name)))
        (+ (read-inner (& inner-name)) (string.string-length (& text-name))))]
    (set! holder.b (box 42))
    (set! holder.inner (Inner (box 1)))
    (set! holder.text (string.copy "after"))
    (if (= result 32)
      (deref holder.b)
      0)))