(import stdlib.serialize)
(import serialize_toy_format as toy)

(defstruct SerializeEnumStructPayload
  (value i64))

(defenum SerializeEnumStructPayloadStatus
  (SerializeEnumStructPayloadWrapped SerializeEnumStructPayload))

(import (serialize.serialize toy SerializeEnumStructPayloadStatus) as serialize_enum_struct_payload_ser)

(define (main) : i64
  (begin
    (serialize_enum_struct_payload_ser.encode
      (SerializeEnumStructPayloadWrapped (SerializeEnumStructPayload 1)))
    0))