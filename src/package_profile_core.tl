;; Package artifact directory and optimization defaults shared by CLI and loader.
(import stdlib.clone as clone_gen)

(defenum PackageProfile
  (Dev)
  (Release))

(clone_gen.gen-clone PackageProfile)

(define (package-default-profile) : PackageProfile
  (Dev))

(define (package-profile-name [profile : PackageProfile]) : String
  (match profile
    [(Dev) "dev"]
    [(Release) "release"]))

(define (package-profile-opt-level [profile : (& PackageProfile)]) : i64
  (match profile
    [(Dev) 0]
    [(Release) 2]))

(define (package-profile-release? [profile : (& PackageProfile)]) : bool
  (match profile
    [(Release) true]
    [(Dev) false]))