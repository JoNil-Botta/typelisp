;; A struct whose field names an unsafe cleanup hook is constructed outside
;; its module family only in unsafe code (#9783).
(import sealed_handle_dep as dep)

(define (main) : i64
  (with ([hooked (dep.Hooked 3) dep.close-hooked]) hooked.fd))