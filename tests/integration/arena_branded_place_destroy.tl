(import stdlib.arena)
(import stdlib.string)
(import stdlib.test)

(defstruct BrandedDestroyState
  (:lifetimes owner)
  (arena (arena.Arena owner))
  (text (in owner String))
  (answer i64))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (string.append "owned" "-text"))]
    [state (BrandedDestroyState owner text 40)]
    [other-owner (arena.make)]
    [other-text (in-arena other-owner (string.append "still" "-alive"))]
    [expected-other : String "still-alive"]
    [owned-len : i64 (string.string-length state.text)]
    (begin
      (arena.destroy-safe! state.arena)
      (test.assert-string-eq
        (& other-text)
        (& expected-other)
        "destroying one brand preserves another")
      (arena.destroy-safe! other-owner)
      (+ owned-len 32))))