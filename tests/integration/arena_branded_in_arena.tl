(import stdlib.arena as memory)
(import stdlib.string)

(defstruct ArenaHolder
  (:lifetimes owner)
  (arena (memory.Arena owner)))

(defstruct ArenaState
  (:lifetimes owner)
  (arena (memory.Arena owner))
  (text (in owner String)))

(define (allocate [owner : (memory.Arena owner)]) : (in owner String)
  (in-arena owner (string.append "parameter" "-owned")))

(define (main) : i64
  (let
    [local-owner (memory.make)]
    [local-text (in-arena local-owner (string.append "local" "-owned"))]
    [local-length : i64 (string.string-length local-text)]
    [helper-owner (memory.make)]
    [helper-text (allocate helper-owner)]
    [helper-length : i64 (string.string-length helper-text)]
    [state-owner (memory.make)]
    [state-text (in-arena state-owner (string.append "state" "-owned"))]
    [state (ArenaState state-owner state-text)]
    [state-length : i64 (string.string-length state.text)]
    [field-owner (memory.make)]
    [holder (ArenaHolder field-owner)]
    [field-text (in-arena holder.arena (string.append "field" "-owned"))]
    [field-length : i64 (string.string-length field-text)]
    (if (= (+ local-length (+ helper-length (+ state-length field-length))) 48)
      42
      1)))