;; A shared reference returned from an implicit &mut-to-& reborrow keeps the
;; mutable-reference referent borrowed until the returned view's last use.
(defstruct ReborrowLive
  (value i64))

(define (reborrow-live-view [item : (& source ReborrowLive)]) : (&
    source
    ReborrowLive)
  item)

(define (main [exclusive : (&mut exclusive ReborrowLive)]) : i64
  (let
    [view : (& exclusive ReborrowLive) (reborrow-live-view exclusive)]
    (begin
      (set! exclusive.value 42)
      view.value)))