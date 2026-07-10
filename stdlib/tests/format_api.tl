(import stdlib.format)
(import stdlib.string)

(define (main) : i64
  (let
    [name : String "Ada"]
    [score : i64 -7]
    [enabled : bool true]
    [mark : char 'x']
    [ratio : f64 1.5]
    [got : String (format.format "{}:{}:{}:{}:{} {{ok}}" name score enabled mark ratio)]
    (if (string.eq got "Ada:-7:true:x:1.5 {ok}")
      42
      1)))
