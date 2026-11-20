;; #9493: as with_owner_if_init_destroy_reject, ended by a safe rewind.
(import stdlib.arena)
(import stdlib.string)

(define (drop-text [text : String]) : unit
  (let
    [_ : i64 (string.string-length (& text))]
    unit))

(defstruct TextOwner
  (:cleanup cleanup-text-owner)
  (text String (:cleanup drop-text)))

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [phase : arena.ArenaPhase (arena.phase scratch)]
    [flag : bool (= (string.string-length "ab") 2)]
    (with
      ([w
          (if flag
            (in-arena scratch (TextOwner (string.append "owner" "-text")))
            (in-arena scratch (TextOwner (string.append "b" "-text"))))
          cleanup-text-owner])
      (begin
        (arena.rewind-safe! phase)
        (if (string.string=? (& w.text) "owner-text")
          42
          7)))))