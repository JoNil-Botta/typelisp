(import stdlib.json)
(import stdlib.serialize)
(import stdlib.string)

(defstruct Span
  (start i64))

(defstruct Detail
  (label String)
  (span Span))

(defenum Origin
  (CommandLine i64)
  (Source String String Span)
  (Detailed Detail))

(defstruct Event
  (ordinal i64)
  (id String)
  (origin Origin))

(defstruct Input
  (position i64)
  (file String)
  (origin Origin))

(defstruct Bundle
  (event Event)
  (input Input))

(import (serialize.serialize json Bundle) as codec)
(import (serialize.serialize json Event) as event_codec)
(import (serialize.serialize json Input) as input_codec)

(define (main) : i64
  (let
    [source : Bundle
      (Bundle
        (Event 0 "event" (Source "module-a" "decl-a" (Span 17)))
        (Input 1 "file" (Detailed (Detail "module-b" (Span 25)))))]
    [encoded : json.Value (codec.encode source)]
    (match (codec.decode encoded)
      [(codec.Ok decoded)
        (let
          [left : bool
            (match decoded.event.origin
              [(Source module declaration span)
                (and
                  (string.eq (& module) "module-a")
                  (string.eq (& declaration) "decl-a")
                  (= span.start 17))]
              [_ false])]
          [right : bool
            (match decoded.input.origin
              [(Detailed detail)
                (and
                  (string.eq (& detail.label) "module-b")
                  (= detail.span.start 25))]
              [_ false])]
          [single : bool
            (match (event_codec.decode
              (event_codec.encode (Event 2 "cli" (CommandLine 9))))
              [(event_codec.Ok event)
                (match event.origin
                  [(CommandLine ordinal) (= ordinal 9)]
                  [_ false])]
              [_ false])]
          [other : bool
            (match (input_codec.decode
              (input_codec.encode
                (Input 3 "source" (Source "module-c" "decl-c" (Span 42)))))
              [(input_codec.Ok input)
                (match input.origin
                  [(Source module declaration span)
                    (and
                      (string.eq (& module) "module-c")
                      (string.eq (& declaration) "decl-c")
                      (= span.start 42))]
                  [_ false])]
              [_ false])]
          (if (and left right single other)
            42
            1))]
      [_ 2])))