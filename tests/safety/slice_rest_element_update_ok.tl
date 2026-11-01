;: Reading an element through a mutable slice reference reborrows it shared
;: (Rust's `Index::index(&*r)`), so a store may read the element it updates,
;: through a parameter or a slice pattern's rest binder (#8449).
(define (bump-param! [xs : (&mut (Slice i64))]) : unit
  (set! (array-ref xs 0) (+ (array-ref xs 0) 1)))

(define (bump-rest! [xs : (&mut (Slice i64))]) : unit
  (match xs
    [(slice) unit]
    [(slice first & rest)
      (when
        (> (array-length rest) 0)
        (set! (array-ref rest 0) (+ (array-ref rest 0) first)))
      (bump-rest! rest)]))

(define (main) : i64
  (let
    [items : (Array i64 3) (array 1 2 3)]
    (bump-param! (&mut items))
    (bump-rest! (&mut items))
    (array-ref items 2)))