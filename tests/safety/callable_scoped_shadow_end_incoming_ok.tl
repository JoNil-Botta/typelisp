;; Refs #9098 (D-C47 invariant 1): regions are identified by owner and
;; occurrence, including lexical shadowing. Inside `(with-arena r ...)` the
;; active arena is the fresh inner one, not the incoming owner of brand `r`, so
;; ending the incoming owner there does not end the arena it runs inside. Main
;; rejected both forms by name collision.
(import stdlib.arena)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (destroy-incoming [owner : (arena.Arena r) (:invalidate r)]) : i64
  (with-arena
    r
    (begin
      (arena.destroy-safe! owner)
      42)))

(define (invalidate-incoming [owner : (arena.Arena r) (:invalidate r)]) : i64
  (with-arena
    r
    (begin
      (release owner)
      42)))

(define (main) : i64
  0)