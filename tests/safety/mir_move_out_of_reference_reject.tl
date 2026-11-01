;: A move-only value behind a shared reference cannot be moved out of it.
(import stdlib.string)

(defstruct Item
  (name String)
  (n i64))

(define (steal [item : (& item Item)]) : Item
  (deref item))

(define (main) : i64
  (let
    [item : Item (Item (string.copy "a") 1)]
    [copy : Item (steal (& item))]
    (+ item.n copy.n)))