(import stdlib.hashmap)
(import (hashmap String String) as map_string_string)

(define (main) : i64
  (let
    [m : map_string_string.Map (map_string_string.with-capacity 2)]
    [key : String "alpha"]
    (begin
      (map_string_string.insert! m "alpha" "red")
      (let
        [entry : (map_string_string.MutEntry m)
          (map_string_string.get-mut-entry-borrowed (&mut m) (& key))]
        (begin
          (map_string_string.insert! m "beta" "amber")
          (if (map_string_string.mut-entry-present? entry)
            1
            0))))))