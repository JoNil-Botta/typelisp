;; A view of a Box holding a String: its contents are the caller's String,
;; which a by-value use would move out of the shared reference (#8927).
(import stdlib.string)

(defstruct Holder
  (s (Box String)))

(define (consume [s : String]) : i64
  (string.string-length (& s)))

(define (take [r : (& r Holder)]) : i64
  (let
    [s r.s]
    (consume (deref s))))

(define (main) : i64
  (let
    [h : Holder (Holder (box (string.copy "a")))]
    (take (& h))))