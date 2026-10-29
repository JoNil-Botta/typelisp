(import stdlib.arena)
(import stdlib.string)
(import stdlib.io)

(defstruct Slot
  (text String))

;; Only the scalar length leaves the scratch region and younger local owner.
(define (value) : i64
  (let
    [scratch (arena.make)]
    (with-escape
      scratch
      (let
        [text (string.append "r1" "-text")]
        [owner (arena.make)]
        (in-arena
          owner
          (let
            [slot (Slot text)]
            (+ (string.string-length slot.text) 35)))))))

(define (main) : i64
  (let
    [result : i64 (value)]
    (io.println "{}" result)
    result))