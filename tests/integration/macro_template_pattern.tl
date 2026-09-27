;; The provider's macro template matches on the provider's enum, also where it
;; expands in a module that declares an enum of the same name.
(import macro_template_pattern_user as user)

(define (main) : i64
  (user.pattern-template-total))