;; Refs #9502 Refs #9493. The contextual match join keeps the live cleanup owner region.
(import stdlib.arena)
(import stdlib.string)

(define (drop-text [text : String]) : unit
  (let
    [_ : i64 (string.string-length (& text))]
    unit))

(defstruct TextOwner
  (:cleanup cleanup-text-owner)
  (text String (:cleanup drop-text)))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(defenum Pick
  (A)
  (B))

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [phase : arena.ArenaPhase (arena.phase scratch)]
    [flag : bool (= (string.string-length "ab") 2)]
    [pick : Pick
      (if flag
        Pick.A
        Pick.B)]
    (with
      ([w
          (match pick
            [(Pick.A)
              (in-arena scratch (TextOwner (string.append "owner" "-text")))]
            [(Pick.B)
              (in-arena scratch (TextOwner (string.append "b" "-text")))])
          cleanup-text-owner])
      (begin
        (arena.rewind-safe! phase)
        (if (string.string=? (& w.text) "owner-text")
          42
          7)))))