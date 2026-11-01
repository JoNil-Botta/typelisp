;; A field read through a shared reference returned early by value would move
;; it out of the holder, which still owns it (main accepted it, #8449).
(import stdlib.string)

(defstruct Holder
  (name String)
  (n i64))

(define (consume [s : String]) : i64
  (string.string-length (& s)))

(define (take [h : (& h Holder)] [c : bool]) : String
  (begin
    (when c (return h.name))
    (string.copy "x")))

(define (main) : i64
  42)