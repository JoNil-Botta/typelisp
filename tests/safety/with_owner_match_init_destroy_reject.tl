;; #9493: as with_owner_if_init_destroy_reject, initialized by a `match`.
(import stdlib.arena)
(import stdlib.string)

(define (drop-text [text : String]) : unit
  (let
    [_ : i64 (string.string-length (& text))]
    unit))

(defstruct TextOwner
  (:cleanup cleanup-text-owner)
  (text String (:cleanup drop-text)))

(defenum Pick
  (A)
  (B))

(define (main) : i64
  (let
    [o (arena.make)]
    [flag : bool (= (string.string-length "ab") 2)]
    [pick : Pick
      (if flag
        Pick.A
        Pick.B)]
    (with
      ([w
          (match pick
            [(Pick.A) (in-arena o (TextOwner (string.append "owner" "-text")))]
            [(Pick.B) (in-arena o (TextOwner (string.append "b" "-text")))])
          cleanup-text-owner])
      (begin
        (arena.destroy-safe! o)
        (if (string.string=? (& w.text) "owner-text")
          42
          7)))))