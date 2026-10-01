;; Module B for compile_profile_module_view_release.tl: a leaf module whose
;; declarations interrupt module A's. Its function `b` shares its name with
;; A's alias for this module.
(module module_view_release_b)

(define (b) : i64
  30)

(define (base) : i64
  5)