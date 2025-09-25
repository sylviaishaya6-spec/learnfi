;; LearnFi Payment Processor Contract
;; Handles STX payments for course access and manages student enrollments

;; Error constants
(define-constant ERR-INSUFFICIENT-FUNDS (err u200))
(define-constant ERR-COURSE-NOT-AVAILABLE (err u201))
(define-constant ERR-ALREADY-ENROLLED (err u202))
(define-constant ERR-PAYMENT-FAILED (err u203))
(define-constant ERR-NOT-ENROLLED (err u204))
(define-constant ERR-REFUND-PERIOD-EXPIRED (err u205))
(define-constant ERR-REFUND-NOT-ALLOWED (err u206))
(define-constant ERR-INVALID-AMOUNT (err u207))
(define-constant ERR-CONTRACT-CALL-FAILED (err u208))
(define-constant ERR-NOT-AUTHORIZED (err u209))

;; Contract configuration
(define-data-var contract-owner principal tx-sender)
(define-data-var refund-window-blocks uint u1440) ;; ~24 hours in blocks
(define-data-var platform-wallet principal tx-sender)
(define-data-var platform-fee uint u250) ;; Platform fee in basis points

;; Payment tracking
(define-data-var total-payments uint u0)
(define-data-var total-revenue uint u0)

;; Course data for simplified implementation
(define-map courses-simple
  uint
  {
    instructor: principal,
    price: uint,
    duration-days: uint,
    is-active: bool,
    max-students: uint,
    current-students: uint
  }
)

;; Student enrollments
(define-map enrollments
  { student: principal, course-id: uint }
  {
    payment-amount: uint,
    enrolled-at: uint,
    access-expires: uint,
    is-active: bool
  }
)

;; Payment history
(define-map payment-history
  uint
  {
    student: principal,
    course-id: uint,
    amount: uint,
    instructor-amount: uint,
    platform-fee: uint,
    timestamp: uint,
    status: (string-ascii 20)
  }
)

;; Refund requests
(define-map refund-requests
  { student: principal, course-id: uint }
  {
    requested-at: uint,
    amount: uint,
    reason: (string-ascii 200),
    status: (string-ascii 20),
    processed-at: (optional uint)
  }
)

;; Payment counter for unique payment IDs
(define-data-var payment-counter uint u0)

;; Course counter
(define-data-var course-counter uint u0)

;; Public function: Create simple course (for testing)
(define-public (create-simple-course (price uint) (duration-days uint) (max-students uint))
  (let ((course-id (+ (var-get course-counter) u1)))
    (map-set courses-simple
      course-id
      {
        instructor: tx-sender,
        price: price,
        duration-days: duration-days,
        is-active: true,
        max-students: max-students,
        current-students: u0
      }
    )
    (var-set course-counter course-id)
    (ok course-id)
  )
)

;; Public function: Purchase course access
(define-public (purchase-course (course-id uint))
  (let 
    (
      (student tx-sender)
      (course (unwrap! (map-get? courses-simple course-id) ERR-COURSE-NOT-AVAILABLE))
      (course-price (get price course))
      (platform-fee-amount (/ (* course-price (var-get platform-fee)) u10000))
      (instructor-amount (- course-price platform-fee-amount))
      (payment-id (+ (var-get payment-counter) u1))
      (instructor (get instructor course))
      (duration-days (get duration-days course))
      (access-expires (+ stacks-block-height (* duration-days u144)))
    )
    
    ;; Validation checks
    (asserts! (get is-active course) ERR-COURSE-NOT-AVAILABLE)
    (asserts! (< (get current-students course) (get max-students course)) ERR-COURSE-NOT-AVAILABLE)
    (asserts! (is-none (map-get? enrollments { student: student, course-id: course-id })) ERR-ALREADY-ENROLLED)
    (asserts! (>= (stx-get-balance student) course-price) ERR-INSUFFICIENT-FUNDS)
    
    ;; Process payment
    (try! (stx-transfer? instructor-amount student instructor))
    (try! (stx-transfer? platform-fee-amount student (var-get platform-wallet)))
    
    ;; Update course enrollment count
    (map-set courses-simple
      course-id
      (merge course { current-students: (+ (get current-students course) u1) })
    )
    
    ;; Record enrollment
    (map-set enrollments
      { student: student, course-id: course-id }
      {
        payment-amount: course-price,
        enrolled-at: stacks-block-height,
        access-expires: access-expires,
        is-active: true
      }
    )
    
    ;; Record payment history
    (map-set payment-history
      payment-id
      {
        student: student,
        course-id: course-id,
        amount: course-price,
        instructor-amount: instructor-amount,
        platform-fee: platform-fee-amount,
        timestamp: stacks-block-height,
        status: "completed"
      }
    )
    
    ;; Update counters
    (var-set payment-counter payment-id)
    (var-set total-payments (+ (var-get total-payments) u1))
    (var-set total-revenue (+ (var-get total-revenue) course-price))
    
    (ok payment-id)
  )
)

;; Public function: Request refund
(define-public (request-refund (course-id uint) (reason (string-ascii 200)))
  (let 
    (
      (student tx-sender)
      (enrollment (unwrap! (map-get? enrollments { student: student, course-id: course-id }) ERR-NOT-ENROLLED))
      (enrolled-at (get enrolled-at enrollment))
      (refund-deadline (+ enrolled-at (var-get refund-window-blocks)))
    )
    
    ;; Check if refund period is still valid
    (asserts! (<= stacks-block-height refund-deadline) ERR-REFUND-PERIOD-EXPIRED)
    (asserts! (get is-active enrollment) ERR-REFUND-NOT-ALLOWED)
    
    ;; Check if refund already requested
    (asserts! (is-none (map-get? refund-requests { student: student, course-id: course-id })) ERR-ALREADY-ENROLLED)
    
    ;; Create refund request
    (map-set refund-requests
      { student: student, course-id: course-id }
      {
        requested-at: stacks-block-height,
        amount: (get payment-amount enrollment),
        reason: reason,
        status: "pending",
        processed-at: none
      }
    )
    
    (ok true)
  )
)

;; Public function: Process refund (admin only)
(define-public (process-refund (student principal) (course-id uint) (approve bool))
  (let 
    (
      (refund-request (unwrap! (map-get? refund-requests { student: student, course-id: course-id }) ERR-NOT-ENROLLED))
      (enrollment (unwrap! (map-get? enrollments { student: student, course-id: course-id }) ERR-NOT-ENROLLED))
      (refund-amount (get amount refund-request))
    )
    
    ;; Only contract owner can process refunds
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    (if approve
      (begin
        ;; Process approved refund
        (try! (as-contract (stx-transfer? refund-amount tx-sender student)))
        
        ;; Deactivate enrollment
        (map-set enrollments
          { student: student, course-id: course-id }
          (merge enrollment { is-active: false })
        )
        
        ;; Update refund request status
        (map-set refund-requests
          { student: student, course-id: course-id }
          (merge refund-request { 
            status: "approved", 
            processed-at: (some stacks-block-height)
          })
        )
      )
      ;; Process denied refund
      (map-set refund-requests
        { student: student, course-id: course-id }
        (merge refund-request { 
          status: "denied", 
          processed-at: (some stacks-block-height)
        })
      )
    )
    
    (ok true)
  )
)

;; Public function: Extend course access
(define-public (extend-course-access (student principal) (course-id uint) (additional-days uint))
  (let 
    (
      (enrollment (unwrap! (map-get? enrollments { student: student, course-id: course-id }) ERR-NOT-ENROLLED))
      (current-expires (get access-expires enrollment))
      (additional-blocks (* additional-days u144))
      (new-expires (+ current-expires additional-blocks))
    )
    
    ;; Only contract owner can extend access
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    (map-set enrollments
      { student: student, course-id: course-id }
      (merge enrollment { access-expires: new-expires })
    )
    
    (ok true)
  )
)

;; Read-only function: Check if student has access to course
(define-read-only (has-course-access (student principal) (course-id uint))
  (match (map-get? enrollments { student: student, course-id: course-id })
    enrollment 
      (and 
        (get is-active enrollment)
        (> (get access-expires enrollment) stacks-block-height)
      )
    false
  )
)

;; Read-only function: Get enrollment details
(define-read-only (get-enrollment-details (student principal) (course-id uint))
  (map-get? enrollments { student: student, course-id: course-id })
)

;; Read-only function: Get payment details
(define-read-only (get-payment-details (payment-id uint))
  (map-get? payment-history payment-id)
)

;; Read-only function: Get refund request
(define-read-only (get-refund-request (student principal) (course-id uint))
  (map-get? refund-requests { student: student, course-id: course-id })
)

;; Read-only function: Get platform statistics
(define-read-only (get-platform-stats)
  {
    total-payments: (var-get total-payments),
    total-revenue: (var-get total-revenue),
    refund-window-blocks: (var-get refund-window-blocks)
  }
)

;; Read-only function: Get course details
(define-read-only (get-course-details (course-id uint))
  (map-get? courses-simple course-id)
)

;; Read-only function: Check refund eligibility
(define-read-only (is-refund-eligible (student principal) (course-id uint))
  (match (map-get? enrollments { student: student, course-id: course-id })
    enrollment 
      (let 
        (
          (enrolled-at (get enrolled-at enrollment))
          (refund-deadline (+ enrolled-at (var-get refund-window-blocks)))
        )
        (and 
          (get is-active enrollment)
          (<= stacks-block-height refund-deadline)
          (is-none (map-get? refund-requests { student: student, course-id: course-id }))
        )
      )
    false
  )
)

;; Read-only function: Get total courses
(define-read-only (get-total-courses)
  (var-get course-counter)
)
