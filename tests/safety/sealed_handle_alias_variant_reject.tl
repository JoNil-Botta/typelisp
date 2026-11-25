;; An alias-qualified payload variant of a foreign sealed enum is a
;; construction (#9783).
(import sealed_handle_dep as dep)

(define (main) : i64
  (begin
    (dep.close-res (dep.Open 1))
    0))