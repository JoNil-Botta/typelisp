(import stdlib.format)
(import stdlib.string)

(defstruct RootDisplay
  (value i64))

(define (to-string [value : (& value RootDisplay)]) : String
  (format.format "root={}" value.value))

(define (main) : i64
  (let
    [name : String "Ada"]
    [score : i64 -7]
    [enabled : bool true]
    [mark : char 'x']
    [ratio : f64 1.5]
    [got : String
      (format.format
        "{}:{}:{}:{}:{}:{} {{ok}}"
        name
        score
        enabled
        mark
        ratio
        (RootDisplay 9))]
    (if (string.eq got "Ada:-7:true:x:1.5:root=9 {ok}")
      42
      1)))