;; An authorized descendant may inspect the opaque representation but must not
;; publish a competing canonical equality hook.
(module owner_eq_hash_dep.eq_descendant)

(import stdlib.eq)
(import owner_eq_hash_dep as dep)

(eq.gen dep.Token)