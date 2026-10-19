;; A `cond` arm yielding a field read through a shared reference where the
;; `cond` yields the owned value moves it out of the holder (main accepted it,
;; #8449).
(import stdlib.string)

(defstruct Holder
  (name String)
  (n i64))

(define (consume [s : String]) : i64
  (string.string-length (& s)))

(define (take [h : (& h Holder)] [c : bool]) : String
  (cond [c h.name] [else (string.copy "x")]))

(define (main) : i64
  42)