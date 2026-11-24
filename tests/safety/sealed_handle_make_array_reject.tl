;; Zeroed storage of a foreign sealed handle builds one (#9783).
(import sealed_handle_dep as dep)

(define (main) : i64
  (let
    [handles : (Array dep.Handle 1) (make-array dep.Handle 1)]
    (array-ref handles 0).generation))