;; A borrow of a value allocated in a `with-arena` region, stored into the
;; caller's array, outlives the arena. The ownership graph erases arena
;; regions (an arena-allocated binder has no storage of its own to retire), so
;; typing's store check decides it by the region's name (#8890).
(import stdlib.string)

(define (keep [items : (__tl_dyn-array (& r str))]) : unit
  (with-arena
    r
    (let
      [s : String (string.int->string 1)]
      ; Must fail: the arena `r` resets before the caller reads `items`.
      (set! (array-ref items 0) (& s)))))

(define (main) : i64
  0)