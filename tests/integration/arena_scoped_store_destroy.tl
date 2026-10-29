(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)

;; An older arena's value may move into a younger scope's container while
;; that arena stays alive, or is ended only after the container's last use
;; (#9445).
(defstruct Slot
  (text String))

(define (no-destroy) : i64
  (let
    [o (arena.make)]
    [t (in-arena o (string.append "owner" "-text"))]
    (with-arena
      r1
      (let
        [slot (Slot (string.append "r1" "-text"))]
        (begin
          (set! slot.text t)
          (string.string-length slot.text))))))

(define (destroy-after-last-use) : i64
  (let
    [o (arena.make)]
    [t (in-arena o (string.append "owner" "-text"))]
    (with-arena
      r1
      (let
        [slot (Slot (string.append "r1" "-text"))]
        (begin
          (set! slot.text t)
          (let
            [length : i64 (string.string-length slot.text)]
            (arena.destroy-safe! o)
            length))))))

(define (loop-store) : i64
  (let
    [o (arena.make)]
    (with-arena
      r1
      (let
        [slot (Slot (string.append "r1" "-text"))]
        [round : i64 0]
        (while (< round 3)
          (set! slot.text (in-arena o (string.append "owner" "-text")))
          (set! round (+ round 1)))
        (string.string-length slot.text)))))

(define (main) : i64
  (let
    [result : i64 (+ (no-destroy) (destroy-after-last-use) (loop-store) 12)]
    (io.println "{}" result)
    result))