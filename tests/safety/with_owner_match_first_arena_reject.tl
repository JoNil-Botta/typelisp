;; Refs #9502 Refs #9493. Both possible allocation owners survive a contextual join.
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
    [first (arena.make)]
    [second (arena.make)]
    [flag : bool (= (string.string-length "ab") 2)]
    [pick : Pick
      (if flag
        Pick.A
        Pick.B)]
    (with
      ([held
          (match pick
            [(A) (in-arena first (TextOwner (string.append "first" "-text")))]
            [(B) (in-arena second (TextOwner (string.append "second" "-text")))])
          cleanup-text-owner])
      (arena.destroy-safe! first)
      (string.string-length (& held.text)))
    42))