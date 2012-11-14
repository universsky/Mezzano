(in-package #:sys.int)

(defconstant +ata-status-err+ #b00000001)
(defconstant +ata-status-drq+ #b00001000)
(defconstant +ata-status-bsy+ #b10000000)

(defun dump-range (start end start-sector)
  "Write a range of physical memory to disk.
Returns number of sectors written."
  (let ((count (truncate (- end start) 512)))
    (dotimes (sector count)
      (setf (io-port/8 #x1F6) (logior #xE0 (ldb (byte 4 24) (+ start-sector sector)));drive and high bits of the lba
            (io-port/8 #x1F1) 0 ; ???
            (io-port/8 #x1F2) 1 ; sector count
            (io-port/8 #x1F3) (ldb (byte 8 0) (+ start-sector sector))
            (io-port/8 #x1F4) (ldb (byte 8 8) (+ start-sector sector))
            (io-port/8 #x1F5) (ldb (byte 8 16) (+ start-sector sector))
            (io-port/8 #x1F7) #x30) ;command write sectors
      ;; Wait for BSY to clear and DRQ or ERR to set.
      ;; Assumes that BSY will clear and DRQ will set at the same time.
      (tagbody
       top (let ((status (io-port/8 #x1F7)))
             (when (logtest status +ata-status-bsy+)
               (go top))
             (when (or (logtest status +ata-status-err+) ;ERR set.
                       (not (logtest status +ata-status-drq+))) ;DRQ not set.
               (error "Failed write command for sector ~S. Status: ~X." (+ start-sector sector) status))))
      ;; HERE WE GO! HERE WE GO!
      (dotimes (i 256)
        (setf (io-port/16 #x1F0) (memref-unsigned-byte-16 (+ #x8000000000 start
                                                             (* sector 512))
                                                          i))))
    count))

(defun dump-virtual-range (start end start-sector)
  (let ((total 0))
    (dotimes (page (truncate (- end start) #x200000))
      (let* ((pte (memref-unsigned-byte-64 #x8000403000 (+ (truncate start #x200000) page)))
             (phys (logand pte (lognot #xFFF))))
        (format t "Dump virt ~X. phys ~X. pte off ~X~%"
                (+ start (* page #x200000))
                phys
                (+ (truncate start #x200000) page))
        (incf total (dump-range phys (+ phys #x200000) (+ start-sector (* page (truncate #x200000 512)))))))
    total))

(defun round-up (value nearest)
  (* (ceiling value nearest) nearest))

(defun dump-disk-image-size ()
  "Calculate the amount of actual data that dump must save."
  (+ #x600000 ; 6MB for paging structures.
     (round-up (- *static-bump-pointer* #x200000) #x200000)
     (round-up (* *newspace-offset* 8) #x200000)
     (round-up (- *stack-bump-pointer-limit* #x100000000) #x200000)))

(defun dump-memory-image-size ()
  "Calculate the amount of actual data that dump must save."
  (+ #x600000 ; 6MB for paging structures.
     (round-up (* *static-area-size* 8) #x200000)
     (round-up (* *semispace-size* 8 2) #x200000)
     (round-up (- *stack-bump-pointer-limit* #x100000000) #x200000)))

(defconstant +page-table-present+  #b0000000000001)
(defconstant +page-table-writable+ #b0000000000010)
(defconstant +page-table-user+     #b0000000000100)
(defconstant +page-table-pwt+      #b0000000001000)
(defconstant +page-table-pcd+      #b0000000010000)
(defconstant +page-table-accessed+ #b0000000100000)
(defconstant +page-table-dirty+    #b0000001000000)
(defconstant +page-table-large+    #b0000010000000)
(defconstant +page-table-global+   #b0000100000000)
(defconstant +page-table-pat+      #b1000000000000)

(defparameter *static-area-base*  #x0000200000)
#+nil(defparameter *static-area-size*  (- #x0080000000 *static-area-base*))
(defparameter *dynamic-area-base* #x0080000000)
(defparameter *dynamic-area-size* #x0080000000) ; 2GB
(defparameter *stack-area-base*   #x0100000000)
(defparameter *stack-area-size*   #x0040000000) ; 1GB
(defparameter *linear-map*        #x8000000000)
(defparameter *physical-load-address* #x0000200000)

(defun dump-generate-page-tables (allocation-start)
  "Generate a new set of page tables for a dumped image.
This must currently replicate the layout of Cold's create-page-tables function.
The setup code requires the PML4 to be in a fixed position and the GC needs to
know where the PDEs for new- and old-space are."
  (flet ((allocate (count)
           (prog1 allocation-start
             (incf allocation-start (* count 8)))))
    (let* (;; Load address. Must be the same across images.
           (phys-curr #x200000)
           (conversion-factor (- allocation-start (+ phys-curr #x200000)))
           (pml4 (allocate 512))
           (data-pml3 (allocate 512))
           (phys-pml3 (allocate 512))
           (data-pml2 (allocate (* 512 512)))
           (phys-pml2 (allocate (* 512 512))))
      (dotimes (i 512)
        ;; Clear PML4.
        (setf (memref-unsigned-byte-64 pml4 i) 0)
        ;; Link PML3s to PML2s.
        (setf (memref-unsigned-byte-64 data-pml3 i) (logior (+ (- data-pml2 conversion-factor) (* i 4096))
                                                            +page-table-present+
                                                            +page-table-global+))
        (setf (memref-unsigned-byte-64 phys-pml3 i) (logior (+ (- phys-pml2 conversion-factor) (* i 4096))
                                                            +page-table-present+
                                                            +page-table-global+))
        (dotimes (j 512)
          ;; Clear the data PML2.
          (setf (memref-unsigned-byte-64 data-pml2 (+ (* i 512) j)) 0)
          ;; Map the physical PML2 to the first 512GB of physical memory.
          (setf (memref-unsigned-byte-64 phys-pml2 (+ (* i 512) j)) (logior (* (+ (* i 512) j) #x200000)
                                                                            +page-table-present+
                                                                            +page-table-global+
                                                                            +page-table-large+))))
      ;; Link the PML4 to the PML3s.
      ;; Data PML3 at 0, physical PML3 at 512GB.
      (setf (memref-unsigned-byte-64 pml4 0) (logior (- data-pml3 conversion-factor)
                                                     +page-table-present+
                                                     +page-table-global+))
      (setf (memref-unsigned-byte-64 pml4 1) (logior (- phys-pml3 conversion-factor)
                                                     +page-table-present+
                                                     +page-table-global+))
      ;; Identity map the first 2MB of static space.
      (setf (memref-unsigned-byte-64 data-pml2 (truncate phys-curr #x200000))
            (logior phys-curr
                    +page-table-present+
                    +page-table-global+
                    +page-table-large+))
      (incf phys-curr #x200000)
      ;; Skip over the page tables.
      (incf phys-curr #x600000)
      ;; The rest of the static area.
      (dotimes (i (1- (ceiling (- *static-bump-pointer* #x200000) #x200000)))
        (setf (memref-unsigned-byte-64 data-pml2 (+ (truncate *static-area-base* #x200000) 1 i))
              (logior phys-curr
                      +page-table-present+
                      +page-table-global+
                      +page-table-large+))
        (incf phys-curr #x200000))
      ;; The dynamic area.
      (dotimes (i (ceiling *newspace-offset* #x40000))
        (setf (memref-unsigned-byte-64 data-pml2 (+ (truncate *newspace* #x200000) i))
              (logior phys-curr
                      +page-table-present+
                      +page-table-global+
                      +page-table-large+))
        (incf phys-curr #x200000))
      ;; Stack space.
      (dotimes (i (ceiling (- *stack-bump-pointer-limit* #x100000000) #x200000))
        (setf (memref-unsigned-byte-64 data-pml2 (+ (truncate *stack-area-base* #x200000) i))
              (logior phys-curr
                      +page-table-present+
                      +page-table-global+
                      +page-table-large+))
        (incf phys-curr #x200000))
      ;; Now map any left-over memory in dynamic/static space in at the end using the BSS.
      (dotimes (i (truncate (- (* *static-area-size* 8) (- *static-bump-pointer* #x200000)) #x200000))
        (setf (memref-unsigned-byte-64 data-pml2 (+ (truncate *static-area-base* #x200000)
                                                    (ceiling (- *static-bump-pointer* #x200000) #x200000) i))
              (logior phys-curr
                      +page-table-present+
                      +page-table-global+
                      +page-table-large+))
        (incf phys-curr #x200000))
      (dotimes (i (truncate (- *semispace-size* *newspace-offset*) #x40000))
        (setf (memref-unsigned-byte-64 data-pml2 (+ (truncate *newspace* #x200000)
                                                    (ceiling *newspace-offset* #x40000) i))
              (logior phys-curr
                      +page-table-present+
                      +page-table-global+
                      +page-table-large+))
        (incf phys-curr #x200000))
      ;; And future-newspace also comes from the BSS.
      (dotimes (i (ceiling *semispace-size* #x40000))
        (setf (memref-unsigned-byte-64 data-pml2 (+ (truncate *oldspace* #x200000) i))
              (logior phys-curr
                      +page-table-present+
                      +page-table-global+
                      +page-table-large+))
        (incf phys-curr #x200000)))))

(defun dump-image ()
  (when (not (yes-or-no-p "Danger! This will overwrite the primary master hard disk. Continue?"))
    (return-from dump-image))
  (format t "Saving image... ")
  (let ((total-sectors 0))
    (with-interrupts-disabled ()
      (let ((old-bump-pointer *bump-pointer*))
        (unwind-protect
             (progn
               (setf *bump-pointer* (round-up old-bump-pointer 512))
               (dump-generate-page-tables *bump-pointer*)
               ;; Reconfigure the multiboot header for the larger image.
               (setf (aref *multiboot-header* 5) (+ #x200000 (dump-disk-image-size))
                     (aref *multiboot-header* 6) (+ #x200000 (dump-memory-image-size)))
               ;; Identity mapped static area.
               (incf total-sectors (dump-range #x200000 #x400000 0))
               ;; Page tables.
               (incf total-sectors (dump-range (- *bump-pointer* #x8000000000)
                                               (+ (- *bump-pointer* #x8000000000) #x600000)
                                               total-sectors))
               ;; Rest of static area.
               (incf total-sectors (dump-virtual-range #x400000
                                                       (round-up *static-bump-pointer* #x200000)
                                                       total-sectors))
               ;; Dynamic area.
               (incf total-sectors (dump-virtual-range *newspace*
                                                       (round-up (+ *newspace* (* *newspace-offset* 8)) #x200000)
                                                       total-sectors))
               ;; Stacks.
               (incf total-sectors (dump-virtual-range #x100000000
                                                       (round-up *stack-bump-pointer-limit* #x200000)
                                                       total-sectors)))
          (setf *bump-pointer* old-bump-pointer))))
    (format t "Wrote ~S sectors (~DbMB) to disk.~%" total-sectors (truncate (truncate (* total-sectors 512) 1024) 1024))
    total-sectors))