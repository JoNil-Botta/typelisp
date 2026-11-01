;; An `:invalidate` call through a place holding the owner (`state.arena`):
;; the diagnostic names the owner local `o` of that brand.
(import stdlib.arena)
(import stdlib.string)

(define (drop-text [text : String]) : unit
  (let
    [_ : i64 (string.string-length (& text))]
    unit))

(defstruct TextOwner
  (:cleanup cleanup-text-owner)
  (text String (:cleanup drop-text)))

(defstruct Holder
  (:lifetimes owner)
  (arena (arena.Arena owner)))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (main) : i64
  (let
    [o (arena.make)]
    (with
      ([w
          (in-arena o (TextOwner (string.append "owner" "-text")))
          cleanup-text-owner])
      (let
        [state (Holder o)]
        (begin
          (release state.arena)
          (if (string.string=? (& w.text) "owner-text")
            42
            7))))))