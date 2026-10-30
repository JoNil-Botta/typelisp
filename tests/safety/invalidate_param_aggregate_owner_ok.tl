;; Refs #9503: an aggregate `(:invalidate r T)` owner keeps its own type; only
;; the other parameters that name `r` get the arena region. Forwarding the owner
;; to another `:invalidate` parameter, `in-arena` on its arena and reads of its
;; fields before the end are accepted, as on main.
(import stdlib.arena)
(import stdlib.string)

(defstruct Level
  (:lifetimes owner)
  (arena (arena.Arena owner))
  (name (in owner String))
  (score i64))

(define (release-level [level : (Level q) (:invalidate q)]) : unit
  (arena.destroy-safe! level.arena))

(define (forward-level [level : (Level r) (:invalidate r)]) : unit
  (release-level level))

(define (unload-level [level : (Level r) (:invalidate r)]) : i64
  (let
    [boxed (in-arena level.arena (box level.score))]
    [extra (string.append level.name "-x")]
    [n : i64 (+ (deref boxed) (string.string-length extra))]
    (arena.destroy-safe! level.arena)
    n))

(define (main) : i64
  (let
    [first-owner (arena.make)]
    [first-name (in-arena first-owner (string.append "cave" "-12"))]
    [first (Level first-owner first-name 30)]
    [second-owner (arena.make)]
    [second-name (in-arena second-owner (string.append "lv" "2"))]
    [second (Level second-owner second-name 1)]
    [n : i64 (unload-level first)]
    (forward-level second)
    n))