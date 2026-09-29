;; Checked `(mutex i64)` identity (#7755): handles and guards constructed in
;; safe code fail closed, and every create/share/lock/close cycle returns the
;; registry to its starting occupancy.
(import stdlib.sync)
(import stdlib.concurrency_registry as registry)
(import (sync.mutex i64) as mutex_i64)

(define (leases) : i64
  (let
    [stats : registry.ConcurrencyStats (registry.concurrency-stats)]
    stats.active-leases))

(define (live-authorities) : i64
  (let
    [stats : registry.ConcurrencyStats (registry.concurrency-stats)]
    stats.live-authorities))

(define (live-resources) : i64
  (let
    [stats : registry.ConcurrencyStats (registry.concurrency-stats)]
    stats.live-resources))

;: A guard built from a registered non-holder token: its cleanup must neither
;: release a lease nor clear the holder of the live genuine guard.
(define (stolen-token-cleanup-is-inert? [mutex : (& mutex mutex_i64.Mutex)]) : bool
  (match (mutex_i64.share mutex)
    [(mutex_i64.ShareErr) false]
    [(mutex_i64.Shared alias)
      (let
        [token : (Box i64) alias.authority.token]
        (begin
          (set! alias.authority.token (box 0))
          (with
            ([guard (mutex_i64.lock mutex) mutex_i64.unlock])
            (let
              [before : i64 (leases)]
              [_forged : unit
                (with ([forged (mutex_i64.Guard token) mutex_i64.unlock]) unit)]
              [after : i64 (leases)]
              (and (= before after) (= (mutex_i64.add! guard 1) 43))))))]))

(define (run [mutex : (& mutex mutex_i64.Mutex)]) : i64
  (let
    [first : i64
      (with
        ([guard (mutex_i64.lock mutex) mutex_i64.unlock])
        (begin
          (mutex_i64.set! guard 17)
          (mutex_i64.add! guard 25)))]
    [blocked : bool
      (with
        ([guard (mutex_i64.lock mutex) mutex_i64.unlock])
        (mutex_i64.close mutex))]
    [idle-leases : i64 (leases)]
    [forged-guard : i64
      (with
        ([guard (mutex_i64.lock mutex) mutex_i64.unlock])
        (begin
          (with ([forged (mutex_i64.Guard (box 99)) mutex_i64.unlock]) unit)
          (mutex_i64.get guard)))]
    [stolen : bool (stolen-token-cleanup-is-inert? mutex)]
    [forged-close : bool
      (with
        ([forged (mutex_i64.empty) mutex_i64.release])
        (mutex_i64.close (& forged)))]
    [authorities-before-share : i64 (live-authorities)]
    [alias-code : i64
      (match (mutex_i64.share mutex)
        [(mutex_i64.ShareErr) 1]
        [(mutex_i64.Shared alias)
          (let
            [value : i64
              (with
                ([guard (mutex_i64.lock (& alias)) mutex_i64.unlock])
                (mutex_i64.get guard))]
            [closed : bool (mutex_i64.close mutex)]
            [alias-close : bool (mutex_i64.close (& alias))]
            [alias-share-code : i64
              (match (mutex_i64.share (& alias))
                [(mutex_i64.ShareErr) 0]
                [(mutex_i64.Shared _) 1])]
            (cond
              [(not (= value 43)) 2]
              [(not closed) 3]
              [alias-close 4]
              [(not (= alias-share-code 0)) 5]
              [else 0]))])]
    (cond
      [(not (= first 42)) 2]
      [blocked 3]
      [(not (= idle-leases 0)) 4]
      [(not (= forged-guard 42)) 5]
      [(not stolen) 6]
      [forged-close 7]
      [(not (= alias-code 0)) (+ 10 alias-code)]
      [(not (= (leases) 0)) 8]
      [(> (live-authorities) authorities-before-share) 9]
      [else 42])))

(define (main) : i64
  (let
    [resources : i64 (live-resources)]
    [authorities : i64 (live-authorities)]
    [code : i64
      (match (mutex_i64.create 0)
        [(mutex_i64.CreateErr _) 1]
        [(mutex_i64.CreateOk mutex) (run (& mutex))])]
    (cond
      [(not (= code 42)) code]
      [(not (= (live-resources) resources)) 20]
      [(not (= (live-authorities) authorities)) 21]
      [(not (mutex_i64.create-initial-ok? 5)) 22]
      [(not (= (live-resources) resources)) 23]
      [else 42])))