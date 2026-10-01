;; Module A for compile_profile_module_view_release.tl. Importing B splices B's
;; declarations in before A's own, so A's first segment holds no declarations
;; and A is revisited after B. A reaches B's function `b` through its alias,
;; which has the same name.
(module module_view_release_a)

(import module_view_release_b as b)

(define (before) : i64
  1)

(define (helper) : i64
  (+ (b.b) (before)))

(define (after) : i64
  (b.base))