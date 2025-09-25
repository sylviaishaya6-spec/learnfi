;; LearnFi Course Manager Contract
;; Handles course creation, management, and instructor permissions

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-COURSE-EXISTS (err u101))
(define-constant ERR-COURSE-NOT-FOUND (err u102))
(define-constant ERR-INVALID-PRICE (err u103))
(define-constant ERR-ENROLLMENT-FULL (err u104))
(define-constant ERR-INVALID-DURATION (err u105))
(define-constant ERR-ALREADY-INSTRUCTOR (err u106))
(define-constant ERR-NOT-INSTRUCTOR (err u107))

;; Contract owner
(define-data-var contract-owner principal tx-sender)

;; Global course counter
(define-data-var course-counter uint u0)

;; Platform fee percentage (in basis points, e.g., 250 = 2.5%)
(define-data-var platform-fee uint u250)

;; Course data structure
(define-map courses
  uint
  {
    instructor: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    price: uint,
    max-students: uint,
    current-students: uint,
    duration-days: uint,
    created-at: uint,
    is-active: bool,
    category: (string-ascii 50)
  }
)

;; Instructor registry
(define-map instructors
  principal
  {
    name: (string-ascii 50),
    bio: (string-ascii 200),
    total-courses: uint,
    total-revenue: uint,
    rating: uint,
    is-verified: bool,
    joined-at: uint
  }
)

;; Course categories for organization
(define-map course-categories
  (string-ascii 50)
  {
    total-courses: uint,
    description: (string-ascii 200)
  }
)

;; Public function: Register as instructor
(define-public (register-instructor (name (string-ascii 50)) (bio (string-ascii 200)))
  (let ((caller tx-sender))
    (asserts! (is-none (map-get? instructors caller)) ERR-ALREADY-INSTRUCTOR)
    (map-set instructors
      caller
      {
        name: name,
        bio: bio,
        total-courses: u0,
        total-revenue: u0,
        rating: u5,
        is-verified: false,
        joined-at: stacks-block-height
      }
    )
    (ok true)
  )
)

;; Public function: Create new course
(define-public (create-course 
  (title (string-ascii 100))
  (description (string-ascii 500))
  (price uint)
  (max-students uint)
  (duration-days uint)
  (category (string-ascii 50))
)
  (let 
    (
      (caller tx-sender)
      (course-id (+ (var-get course-counter) u1))
      (instructor-data (unwrap! (map-get? instructors caller) ERR-NOT-INSTRUCTOR))
    )
    (asserts! (> price u0) ERR-INVALID-PRICE)
    (asserts! (> max-students u0) ERR-INVALID-PRICE)
    (asserts! (> duration-days u0) ERR-INVALID-DURATION)
    
    ;; Create the course
    (map-set courses
      course-id
      {
        instructor: caller,
        title: title,
        description: description,
        price: price,
        max-students: max-students,
        current-students: u0,
        duration-days: duration-days,
        created-at: stacks-block-height,
        is-active: true,
        category: category
      }
    )
    
    ;; Update instructor stats
    (map-set instructors
      caller
      (merge instructor-data { total-courses: (+ (get total-courses instructor-data) u1) })
    )
    
    ;; Update category stats
    (update-category-stats category)
    
    ;; Update course counter
    (var-set course-counter course-id)
    
    (ok course-id)
  )
)

;; Public function: Update course status
(define-public (toggle-course-status (course-id uint))
  (let 
    (
      (course (unwrap! (map-get? courses course-id) ERR-COURSE-NOT-FOUND))
      (caller tx-sender)
    )
    (asserts! (or (is-eq caller (get instructor course)) (is-eq caller (var-get contract-owner))) ERR-NOT-AUTHORIZED)
    
    (map-set courses
      course-id
      (merge course { is-active: (not (get is-active course)) })
    )
    
    (ok true)
  )
)

;; Public function: Update course price
(define-public (update-course-price (course-id uint) (new-price uint))
  (let 
    (
      (course (unwrap! (map-get? courses course-id) ERR-COURSE-NOT-FOUND))
      (caller tx-sender)
    )
    (asserts! (is-eq caller (get instructor course)) ERR-NOT-AUTHORIZED)
    (asserts! (> new-price u0) ERR-INVALID-PRICE)
    
    (map-set courses
      course-id
      (merge course { price: new-price })
    )
    
    (ok true)
  )
)

;; Public function: Verify instructor (admin only)
(define-public (verify-instructor (instructor-principal principal))
  (let ((instructor-data (unwrap! (map-get? instructors instructor-principal) ERR-NOT-INSTRUCTOR)))
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    (map-set instructors
      instructor-principal
      (merge instructor-data { is-verified: true })
    )
    
    (ok true)
  )
)

;; Read-only function: Get course details
(define-read-only (get-course-details (course-id uint))
  (map-get? courses course-id)
)

;; Read-only function: Get instructor info
(define-read-only (get-instructor-info (instructor-principal principal))
  (map-get? instructors instructor-principal)
)

;; Read-only function: Get total courses count
(define-read-only (get-total-courses)
  (var-get course-counter)
)

;; Read-only function: Check if course is available
(define-read-only (is-course-available (course-id uint))
  (match (map-get? courses course-id)
    course-data 
      (and 
        (get is-active course-data)
        (< (get current-students course-data) (get max-students course-data))
      )
    false
  )
)

;; Read-only function: Get course price
(define-read-only (get-course-price (course-id uint))
  (match (map-get? courses course-id)
    course-data (some (get price course-data))
    none
  )
)

;; Read-only function: Get platform fee
(define-read-only (get-platform-fee)
  (var-get platform-fee)
)

;; Read-only function: Get category stats
(define-read-only (get-category-stats (category (string-ascii 50)))
  (map-get? course-categories category)
)

;; Private function: Update category statistics
(define-private (update-category-stats (category (string-ascii 50)))
  (match (map-get? course-categories category)
    existing-data
      (map-set course-categories
        category
        (merge existing-data { total-courses: (+ (get total-courses existing-data) u1) })
      )
    (map-set course-categories
      category
      {
        total-courses: u1,
        description: "Course category"
      }
    )
  )
)

;; Public function: Increment student enrollment (called by payment processor)
(define-public (increment-enrollment (course-id uint))
  (let 
    (
      (course (unwrap! (map-get? courses course-id) ERR-COURSE-NOT-FOUND))
      (current-count (get current-students course))
    )
    (asserts! (< current-count (get max-students course)) ERR-ENROLLMENT-FULL)
    
    (map-set courses
      course-id
      (merge course { current-students: (+ current-count u1) })
    )
    
    (ok true)
  )
)

;; Public function: Update instructor revenue (called by payment processor)
(define-public (update-instructor-revenue (instructor-principal principal) (amount uint))
  (let ((instructor-data (unwrap! (map-get? instructors instructor-principal) ERR-NOT-INSTRUCTOR)))
    (map-set instructors
      instructor-principal
      (merge instructor-data { total-revenue: (+ (get total-revenue instructor-data) amount) })
    )
    
    (ok true)
  )
)
