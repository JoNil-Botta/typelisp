;; Declaration owner for enum payload exhaustiveness coverage (#6262).
;; The enum fields deliberately use unqualified owner-local struct names.
(defstruct Payload
  (value i64))

(defenum Choice
  (Some Payload)
  (None))

(defstruct RefPayload
  (:lifetimes source)
  (value (& source i64)))

(defenum RefChoice
  (:lifetimes source)
  (RefSome (RefPayload source))
  (RefNone))