;; Matching a field reached through a shared reference binds views of its
;; parts. Returning the `String` payload as an owned value would move it out
;; from behind the reference (Rust E0507), leaving two owners of one string.
(import stdlib.string)

(defenum MaybeText
  (Some String)
  (No))

(defstruct Holder
  (alias MaybeText))

(define (alias [holder : (& holder Holder)]) : String
  (match holder.alias
    [(MaybeText.Some text) text]
    [(MaybeText.No) (string.copy "")]))

(define (main) : i64
  (let
    [holder : Holder (Holder (MaybeText.Some (string.copy "abc")))]
    [first : String (alias (& holder))]
    [second : String (alias (& holder))]
    (+ (string.string-length first) (string.string-length second))))