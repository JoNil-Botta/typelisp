;; package_cache_smoke.tl - Runnable package cache helper smoke.
(import "../package_cache_core.tl")

(define (main) : i64
  (package-cache-self-test))