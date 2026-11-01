;; An `:invalidate` call ends its argument's arena like a safe destroy (#9476):
;; the `with` owner `w` lives in `o`, so its later read and its scope-exit
;; cleanup would both touch unmapped memory.
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

(define (main) : i64
  (let
    [o (arena.make)]
    (with
      ([w
          (in-arena o (TextOwner (string.append "owner" "-text")))
          cleanup-text-owner])
      (begin
        (release o)
        (if (string.string=? (& w.text) "owner-text")
          42
          7)))))