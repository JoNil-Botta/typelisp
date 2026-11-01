;; A Box field reached through a reference is still a Box expression. Keep
;; these place projections distinct from a receiver whose type is a reference.
(defstruct Holder
  (value (Box i64)))

(define (field-value [holder : (& holder Holder)]) : i64
  (let
    [value (& (__tl-box-place holder.value))]
    (deref value)))

(define (reference-value [value : (& value (Box i64))]) : i64
  (let
    [inner (& (deref (deref value)))]
    (deref inner)))

(define (set-reference! [value : (&mut value (Box i64))]) : unit
  (let
    [inner (&mut (deref (deref value)))]
    (set! (deref inner) 43)))

(define (main) : i64
  (let
    [holder : Holder (Holder (box 42))]
    [value : (Box i64) (box 42)]
    [nested : (Box (Box i64)) (box (box 42))]
    (if (and
      (= (field-value (& holder)) 42)
      (= (reference-value (& value)) 42)
      (= (deref (& (__tl-box-place (__tl-box-place nested)))) 42))
      (begin
        (set-reference! (&mut value))
        (if (= (deref value) 43)
          42
          1))
      2)))