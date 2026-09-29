;; Safe code can move a registered handle token out of a shared mutex and
;; wrap it in a guard, but that token is not the holder: guard access aborts
;; (134) before reading the protected value (#7755).
(import stdlib.sync)
(import (sync.mutex i64) as mutex_i64)

(define (read-through-stolen-token [mutex : (& mutex mutex_i64.Mutex)]) : i64
  (match (mutex_i64.share mutex)
    [(mutex_i64.ShareErr) 1]
    [(mutex_i64.Shared alias)
      (let
        [token : (Box i64) alias.authority.token]
        (begin
          (set! alias.authority.token (box 0))
          (with
            ([forged (mutex_i64.Guard token) mutex_i64.unlock])
            (mutex_i64.get forged))))]))

(define (main) : i64
  (match (mutex_i64.create 7)
    [(mutex_i64.CreateErr _) 1]
    [(mutex_i64.CreateOk mutex) (read-through-stolen-token (& mutex))]))