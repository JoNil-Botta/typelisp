(import stdlib.hashmap)

(defstruct LocalHashmapValue
  (score i64)
  (label String))

(defenum LocalHashmapState
  (LocalHashmapEmpty)
  (LocalHashmapPresent String))

(import (hashmap.hashmap String LocalHashmapValue) as local_struct_map)
(import (hashmap.hashmap i64 LocalHashmapState) as local_enum_map)

(define (main) : i64
  (let
    [structs : local_struct_map.Map (local_struct_map.new)]
    [states : local_enum_map.Map (local_enum_map.new)]
    (begin
      (local_struct_map.insert! structs "answer" (LocalHashmapValue 40 "ok"))
      (local_enum_map.insert! states 1 (LocalHashmapPresent "ready"))
      (match (local_struct_map.get (& structs) "answer")
        [(local_struct_map.LookupFound value)
          (match (local_enum_map.get (& states) 1)
            [(local_enum_map.LookupFound (LocalHashmapPresent _))
              (+ value.score 2)]
            [_ 1])]
        [(local_struct_map.LookupMissing) 1]))))