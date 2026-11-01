;; Testing a move-only field behind a shared reference, or reading its Copy
;; parts, moves nothing: the holder keeps its value.
(import stdlib.string)

(defenum MaybeText
  (Some String)
  (No))

(defstruct Holder
  (alias MaybeText)
  (count i64))

(define (has-alias? [holder : (& holder Holder)]) : bool
  (match holder.alias
    [(MaybeText.Some _) true]
    [(MaybeText.No) false]))

(define (alias-length [holder : (& holder Holder)]) : i64
  (match holder.alias
    [(MaybeText.Some text) (string.string-length (& text))]
    [(MaybeText.No) 0]))

(define (main) : i64
  (let
    [holder : Holder (Holder (MaybeText.Some (string.copy "abc")) 36)]
    (if (and (has-alias? (& holder)) (has-alias? (& holder)))
      (+ holder.count (alias-length (& holder)) (alias-length (& holder)))
      1)))