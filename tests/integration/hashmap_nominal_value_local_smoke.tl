(import stdlib.clone)
(import stdlib.hashmap)

(defstruct LocalHashmapScore
  (value i64))

(defstruct LocalHashmapValue
  (score LocalHashmapScore)
  (label String))

(stdlib.clone.gen-clone LocalHashmapValue)

(defenum LocalHashmapState
  (LocalHashmapEmpty)
  (LocalHashmapPresent String))

(stdlib.clone.gen-clone LocalHashmapState)

(import (hashmap.hashmap String LocalHashmapValue) as local_struct_map)
(import (hashmap.hashmap i64 LocalHashmapState) as local_enum_map)

(define (main) : i64
  (let
    [structs : local_struct_map.Map (local_struct_map.new)]
    [states : local_enum_map.Map (local_enum_map.new)]
    (local_struct_map.insert!
      structs
      "answer"
      (LocalHashmapValue (LocalHashmapScore 40) "ok"))
    (local_enum_map.insert! states 1 (LocalHashmapPresent "ready"))
    (match (local_struct_map.get (& structs) "answer")
      [(LookupFound value)
        (match (local_enum_map.get (& states) 1)
          [(LookupFound (LocalHashmapPresent _)) (+ value.score.value 2)]
          [_ 1])]
      [(LookupMissing) 1])))