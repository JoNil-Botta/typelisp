;; A borrowed tuple pattern binds a reference to the non-Copy part and a copy
;; of the Copy part (#8572) without moving the tuple: the owner stays
;; initialized and is writable after the reference's last
;; use.
(import stdlib.string)

(define (main) : i64
  (let
    [pair : (Tuple String i64) (tuple (string.copy "abc") 39)]
    [length : i64
      (match (& pair)
        [(tuple text number) (+ (string.string-length text) number)])]
    (begin
      (set! (tuple-ref pair 1) 0)
      (+ length (tuple-ref pair 1)))))