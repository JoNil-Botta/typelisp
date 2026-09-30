(import stdlib.arena)
(import stdlib.string)
(import stdlib.test)

;; `(:invalidate r)` helpers (#6670): each destroys the owner of its branded
;; argument, and the caller keeps using every arena it did not pass.
(defstruct InvalidateLevel
  (:lifetimes owner)
  (arena (arena.Arena owner))
  (name (in owner String))
  (score i64))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

;; A struct owner is consumed whole; its fields are read before the destroy.
(define (unload-level [level : (InvalidateLevel r) (:invalidate r)]) : i64
  (let
    [score : i64 level.score]
    [name-length : i64 (string.string-length level.name)]
    (begin
      (arena.destroy-safe! level.arena)
      (+ score name-length))))

;; Forwarding the owner to another `:invalidate` parameter discharges it.
(define (forward [owner : (arena.Arena s) (:invalidate s)]) : unit
  (release owner))

(define (release-through
  [f : (-> (:invalidate q (arena.Arena q)) unit)]
  [owner : (arena.Arena s) (:invalidate s)]) : unit
  (f owner))

(define (release-pair
  [first : (arena.Arena r) (:invalidate r)]
  [second : (arena.Arena s) (:invalidate s)]
  [second-first : bool]) : i64
  (if second-first
    (begin
      (arena.destroy-safe! second)
      (arena.destroy-safe! first)
      1)
    (begin
      (arena.destroy-safe! first)
      (arena.destroy-safe! second)
      2)))

(define (main) : i64
  (let
    [kept (arena.make)]
    [kept-text (in-arena kept (string.append "kept" "-alive"))]
    [expected-kept : String "kept-alive"]
    [level-owner (arena.make)]
    [level-name (in-arena level-owner (string.append "cave" "-12"))]
    [level (InvalidateLevel level-owner level-name 30)]
    [unloaded : i64 (unload-level level)]
    [forwarded (arena.make)]
    [forwarded-text (in-arena forwarded (string.append "for" "ward"))]
    [forwarded-length : i64 (string.string-length forwarded-text)]
    [through (arena.make)]
    [first (arena.make)]
    [second (arena.make)]
    [order : i64 (release-pair first second true)]
    (begin
      (forward forwarded)
      (release-through release through)
      (test.assert-string-eq
        (& kept-text)
        (& expected-kept)
        "invalidating other arenas preserves this one")
      (test.assert-true (= unloaded 37) "unload reads fields before destroy")
      (test.assert-true (= forwarded-length 7) "forwarded arena was readable")
      (arena.destroy-safe! kept)
      (+ unloaded (+ order 4)))))