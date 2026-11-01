;; An element read by value through a reference to a dynamic array (here one
;; returned by an accessor) would duplicate the borrowed owner: only
;; `replace!` moves an element out, and a reader takes a clone (#8449 M5;
;; legacy typing accepted it, as `stdlib/queue.tl` relied on).
(import stdlib.string)

(defstruct Names
  (items (__tl_dyn-array String)))

(define (items [names : (& r Names)]) : (& r (__tl_dyn-array String))
  (& names.items))

(define (first [names : (& r Names)]) : String
  (array-ref (items names) 0))

(define (main) : i64
  (let
    [names : Names (Names (__tl_make-array String 1))]
    (string.string-length (& (first (& names))))))