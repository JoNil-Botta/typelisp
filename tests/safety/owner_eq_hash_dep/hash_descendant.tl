;; An authorized descendant must not publish a competing canonical hash hook.
(module owner_eq_hash_dep.hash_descendant)

(import stdlib.hash)
(import owner_eq_hash_dep as dep)

(hash.gen dep.Token)