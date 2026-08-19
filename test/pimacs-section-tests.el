;;; pimacs-section-tests --- Tests for pimacs-section.el -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)

;; development only packages, not declared as a package-dependency
(package-initialize)

(require 'undercover)
(undercover)

(require 'pimacs-section)
(setq pimacs-section-padding "")

(defmacro pimacs-with-root-section (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (pimacs-section--create-root-section)
     ,@body))

(defmacro pimacs-section-tests-with-demo-buffer (&rest body)
  (declare (indent 0))
  `(pimacs-with-root-section
     (let* ((build (pimacs-section--new-section 'build pimacs-section--root-section))
            (compile (pimacs-section--new-section 'compile build))
            (tests (pimacs-section--new-section 'test build))
            (unit-tests (pimacs-section--new-section 'unit-tests tests))
            (integration-tests (pimacs-section--new-section 'integration-tests tests))
            (logs (pimacs-section--new-section 'logs pimacs-section--root-section))
            (server-log (pimacs-section--new-section 'server-log logs))
            (worker-log (pimacs-section--new-section 'worker-log logs))
            (deploy (pimacs-section--new-section 'deploy pimacs-section--root-section)))
       (pimacs-section--insert-section build
         (insert "[-] Build\n"))
       (pimacs-section--insert-section compile
         (insert "  [-] Compile\n")
         (insert "      Compiling foo.c\n")
         (insert "      Compiling bar.c\n"))
       (pimacs-section--insert-section tests
         (insert "  [-] Tests\n"))
       (pimacs-section--insert-section unit-tests
         (insert "      [-] Unit Tests\n")
         (insert "          test-auth ... ok\n")
         (insert "          test-db ... ok\n"))
       (pimacs-section--insert-section integration-tests
         (insert "      [-] Integration Tests\n")
         (insert "          api-flow ... running\n"))
       (pimacs-section--insert-section logs
         (insert "[-] Logs\n"))
       (pimacs-section--insert-section server-log
         (insert "  [-] Server\n")
         (insert "      Listening on :8080\n")
         (insert "      Connected client #42\n"))
       (pimacs-section--insert-section worker-log
         (insert "  [-] Worker\n")
         (insert "      Job started\n")
         (insert "      Job completed\n"))
       (pimacs-section--insert-section deploy
         (insert "[-] Deploy\n")
         (insert "    Uploading artifacts...\n")
         (insert "    Restarting services...\n"))
       (pimacs-section--append-section server-log
         (insert "      Connected client #43\n")
         (insert "      Connected client #44\n")
         (insert "      Connected client #45\n"))
       (goto-char (point-min))
       ,@body)))

(defun pimacs-section-tests--visibility-indicator-overlay (section)
  (cl-find-if
   (lambda (ov)
     (overlay-get ov 'pimacs-section-visibility-indicator))
   (overlays-in (pimacs-section-beginning section)
                (save-excursion
                  (goto-char (pimacs-section-beginning section))
                  (line-end-position)))))

;; ─── Basic section creation ────────────────────────────────────────────

(ert-deftest pimacs-section-create-root ()
  (pimacs-with-root-section
    (should (pimacs-section-p pimacs-section--root-section))
    (should (eq (pimacs-section-type pimacs-section--root-section) 'root))
    (should (null (pimacs-section-parent pimacs-section--root-section)))
    (should (null (pimacs-section-children pimacs-section--root-section)))
    (should (= (pimacs-section-beginning pimacs-section--root-section) (point-min)))
    (should (= (pimacs-section-end pimacs-section--root-section) (point-min)))))

(ert-deftest pimacs-section-new-child ()
  (pimacs-with-root-section
    (let ((child (pimacs-section--new-section 'child pimacs-section--root-section)))
      (should (pimacs-section-p child))
      (should (eq (pimacs-section-type child) 'child))
      (should (eq (pimacs-section-parent child) pimacs-section--root-section))
      (should (memq child (pimacs-section-children pimacs-section--root-section))))))

(ert-deftest pimacs-section-new-nested-children ()
  (pimacs-with-root-section
    (let* ((build (pimacs-section--new-section 'build pimacs-section--root-section))
           (compile (pimacs-section--new-section 'compile build)))
      (should (eq (pimacs-section-parent compile) build))
      (should (memq compile (pimacs-section-children build)))
      (should (eq (pimacs-section-parent build) pimacs-section--root-section))
      (should (memq build (pimacs-section-children pimacs-section--root-section))))))

(ert-deftest pimacs-section-default-visibility ()
  (pimacs-with-root-section
    (let ((child (pimacs-section--new-section 'child pimacs-section--root-section)))
      (should (equal (pimacs-section-visibility child) pimacs-section--visibility-default))
      (should (eq (pimacs-section-visibility child) :autoshow)))))

;; ─── pimacs-section--insert-section ─────────────────────────────────────────────────

(ert-deftest pimacs-section-insert-sets-beginning-and-end ()
  (pimacs-with-root-section
    (let ((build (pimacs-section--new-section 'build pimacs-section--root-section)))
      (pimacs-section--insert-section build
        (insert "[-] Build\n"))
      (should (< (pimacs-section-beginning build) (pimacs-section-end build)))
      (should (= (pimacs-section-beginning build) 1))
      (should (= (pimacs-section-end build) 11)))))

(ert-deftest pimacs-section-insert-propertizes-text ()
  (pimacs-with-root-section
    (let ((build (pimacs-section--new-section 'build pimacs-section--root-section)))
      (pimacs-section--insert-section build
        (insert "[-] Build\n"))
      (goto-char 1)
      (should (eq (get-text-property (point) 'pimacs-section) build)))))

(ert-deftest pimacs-section-insert-updates-parent-end ()
  (pimacs-with-root-section
    (let* ((build (pimacs-section--new-section 'build pimacs-section--root-section))
           (compile (pimacs-section--new-section 'compile build)))
      (pimacs-section--insert-section build
        (insert "[-] Build\n"))
      (pimacs-section--insert-section compile
        (insert "  [-] Compile\n"))
      (should (>= (pimacs-section-end build) (pimacs-section-end compile)))
      (should (>= (pimacs-section-end pimacs-section--root-section) (pimacs-section-end build))))))

;; ─── pimacs-section--append-section ─────────────────────────────────────────────────

(ert-deftest pimacs-section-append-extends-existing ()
  (pimacs-with-root-section
    (let ((log (pimacs-section--new-section 'log pimacs-section--root-section)))
      (pimacs-section--insert-section log
        (insert "[-] Log\n"))
      (let ((original-end (pimacs-section-end log)))
        (pimacs-section--append-section log
          (insert "extra line\n"))
        (should (> (pimacs-section-end log) original-end))))))

(ert-deftest pimacs-section-append-adds-text-properties ()
  (pimacs-with-root-section
    (let ((log (pimacs-section--new-section 'log pimacs-section--root-section)))
      (pimacs-section--insert-section log
        (insert "[-] Log\n"))
      (pimacs-section--append-section log
        (insert "extra line\n"))
      (goto-char (point-max))
      (should (eq (get-text-property (1- (point)) 'pimacs-section) log)))))

;; ─── pimacs-section--replace-section ────────────────────────────────────────────────

(ert-deftest pimacs-section-replace-content ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 18)
    (let* ((worker (pimacs-section--current-section))
           (old-end (marker-position (pimacs-section-end worker))))
      (pimacs-section--replace-section worker
        (insert "  [-] Worker\n")
        (insert "      Restarted\n"))
      (should (eq (pimacs-section-type worker) 'worker-log))
      (should (< (marker-position (pimacs-section-end worker)) old-end))
      (goto-char (pimacs-section-beginning worker))
      (should (looking-at "  \\[-\\] Worker\n"))
      (forward-line 1)
      (should (looking-at "      Restarted\n"))
      (should (not (search-forward "Job started" nil t))))))

(ert-deftest pimacs-section-replace-clear-children ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (let* ((build (pimacs-section--current-section))
           (old-children (pimacs-section-children build)))
      (should old-children)
      (pimacs-section--replace-section build
        (insert "[-] Build\n"))
      (should (null (pimacs-section-children build))))))

(ert-deftest pimacs-section-replace-propertizes-text ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 12)
    (let ((worker (pimacs-section--current-section)))
      (pimacs-section--replace-section worker
        (insert "  [-] Worker\n")
        (insert "      Restarted\n"))
      (goto-char (pimacs-section-beginning worker))
      (should (eq (get-text-property (point) 'pimacs-section) worker))
      (goto-char (1- (pimacs-section-end worker)))
      (should (eq (get-text-property (point) 'pimacs-section) worker)))))

(ert-deftest pimacs-section-replace-updates-parent-end ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 10)
    (let* ((logs (pimacs-section--current-section))
           (worker (pimacs-section--find-section '(logs worker-log) pimacs-section--root-section))
           (server (pimacs-section--find-section '(logs server-log) pimacs-section--root-section)))
      (should worker)
      (pimacs-section--replace-section worker
        (insert "  [-] Worker\n"))
      ;; parent end should still cover the remaining server-log content
      (should (>= (pimacs-section-end logs) (pimacs-section-end server))))))

(ert-deftest pimacs-section-replace-clear-multiple-children ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (let ((tests (pimacs-section--find-section '(build test) pimacs-section--root-section)))
      (should (pimacs-section-children tests))
      (pimacs-section--replace-section tests
        (insert "  [-] Tests\n"))
      (should (null (pimacs-section-children tests))))))

;; ─── pimacs-section--current-section / pimacs-section--section-at ────────────────────────────────

(ert-deftest pimacs-section--section-at-returns-correct-section ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (let ((s (pimacs-section--section-at (point))))
      (should (pimacs-section-p s))
      (should (eq (pimacs-section-type s) 'build)))))

(ert-deftest pimacs-section-current-returns-correct-section ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (should (eq (pimacs-section-type (pimacs-section--current-section)) 'build))))

(ert-deftest pimacs-section--section-at-on-different-lines ()
  (pimacs-section-tests-with-demo-buffer
    ;; Server log section
    (goto-char (point-min))
    (forward-line 10)
    (should (eq (pimacs-section-type (pimacs-section--current-section)) 'logs))
    ;; Worker log section
    (goto-char (point-min))
    (forward-line 17)
    (should (eq (pimacs-section-type (pimacs-section--current-section)) 'worker-log))))

;; ─── pimacs-section--section-path ───────────────────────────────────────────────────

(ert-deftest pimacs-section--section-path-root ()
  (pimacs-section-tests-with-demo-buffer
    (let ((root pimacs-section--root-section))
      (while (pimacs-section-parent root)
        (setq root (pimacs-section-parent root)))
      (should (equal (pimacs-section--section-path root) '())))))

(ert-deftest pimacs-section--section-path-nested ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 5)
    (let ((s (pimacs-section--current-section)))
      (should (equal (pimacs-section--section-path s)
                     '(build test unit-tests))))))

;; ─── pimacs-section--find-section ───────────────────────────────────────────────────

(ert-deftest pimacs-section--find-section-by-path ()
  (pimacs-section-tests-with-demo-buffer
    (let* ((found (pimacs-section--find-section '(build compile) pimacs-section--root-section)))
      (should found)
      (should (eq (pimacs-section-type found) 'compile)))))

(ert-deftest pimacs-section--find-section-non-existent ()
  (pimacs-section-tests-with-demo-buffer
    (let* ((root pimacs-section--root-section)
           (found (pimacs-section--find-section '(build non-existent) root)))
      (should (null found)))))

(ert-deftest pimacs-section--find-section-empty-path ()
  (pimacs-section-tests-with-demo-buffer
    (let* ((root pimacs-section--root-section)
           (found (pimacs-section--find-section '() root)))
      (should (eq found root)))))

;; ─── pimacs-section--next-section / pimacs-section--prev-section ─────────────────────────────────

(ert-deftest pimacs-section--next-section-first-child ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (let ((next (pimacs-section--next-section (pimacs-section--current-section))))
      (should next)
      (should (eq (pimacs-section-type next) 'compile)))))

(ert-deftest pimacs-section--next-section-goes-to-sibling-before-parent ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 5)
    (let ((next (pimacs-section--next-section (pimacs-section--current-section))))
      (should next)
      (should (eq (pimacs-section-type next) 'integration-tests)))))

(ert-deftest pimacs-section--next-section-goes-to-parent-sibling ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 8)
    (let ((next (pimacs-section--next-section (pimacs-section--current-section))))
      (should next)
      (should (eq (pimacs-section-type next) 'logs)))))

(ert-deftest pimacs-section--next-section-last ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-max))
    (forward-line -1)
    (let ((section (pimacs-section--section-at (point))))
      (should (null (pimacs-section--next-section section))))))

(ert-deftest pimacs-section--next-section-of-type ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (let ((next (pimacs-section--next-section-of-type (pimacs-section--current-section) 'deploy)))
      (should next)
      (should (eq (pimacs-section-type next) 'deploy)))))

(ert-deftest pimacs-section--next-section-of-type-missing ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (let ((next (pimacs-section--next-section-of-type (pimacs-section--current-section) 'missing)))
      (should (null next)))))

(ert-deftest pimacs-section--next-section-walks-tree-in-order ()
  (pimacs-section-tests-with-demo-buffer
    (let* ((compile (pimacs-section--find-section '(build compile) pimacs-section--root-section))
           (next1 (pimacs-section--next-section compile))
           (next2 (pimacs-section--next-section next1))
           (next3 (pimacs-section--next-section next2))
           (next4 (pimacs-section--next-section next3)))
      (should (eq (pimacs-section-type next1) 'test))
      (should (eq (pimacs-section-type next2) 'unit-tests))
      (should (eq (pimacs-section-type next3) 'integration-tests))
      (should (eq (pimacs-section-type next4) 'logs)))))

(ert-deftest pimacs-section--prev-section-sibling ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 10)
    (let* ((logs (pimacs-section--current-section))
           (prev (pimacs-section--prev-section logs)))
      (should prev)
      (should (eq (pimacs-section-type prev) 'integration-tests)))))

(ert-deftest pimacs-section--prev-section-goes-to-parent ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 1)
    (let* ((compile (pimacs-section--current-section))
           (prev (pimacs-section--prev-section compile)))
      (should prev)
      (should (eq (pimacs-section-type prev) 'build)))))

(ert-deftest pimacs-section--prev-section-first-top-level-is-nil ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (let ((build (pimacs-section--current-section)))
      (should (null (pimacs-section--prev-section build))))))

(ert-deftest pimacs-section--prev-section-of-type ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 10)
    (let ((prev (pimacs-section--prev-section-of-type (pimacs-section--current-section) 'build)))
      (should prev)
      (should (eq (pimacs-section-type prev) 'build)))))

(ert-deftest pimacs-section--prev-section-of-type-missing ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (let ((prev (pimacs-section--prev-section-of-type (pimacs-section--current-section) 'missing)))
      (should (null prev)))))

(ert-deftest pimacs-section--prev-section-walks-tree-in-reverse-order ()
  (pimacs-section-tests-with-demo-buffer
    (let* ((worker-log (pimacs-section--find-section '(logs worker-log) pimacs-section--root-section))
           (prev1 (pimacs-section--prev-section worker-log))
           (prev2 (pimacs-section--prev-section prev1))
           (prev3 (pimacs-section--prev-section prev2))
           (prev4 (pimacs-section--prev-section prev3)))
      (should (eq (pimacs-section-type prev1) 'server-log))
      (should (eq (pimacs-section-type prev2) 'logs))
      (should (eq (pimacs-section-type prev3) 'integration-tests))
      (should (eq (pimacs-section-type prev4) 'unit-tests)))))

(ert-deftest pimacs-section--goto-next-section-of-type ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (pimacs-section--goto-next-section-of-type 'deploy)
    (should (eq (pimacs-section-type (pimacs-section--current-section)) 'deploy))))

(ert-deftest pimacs-section--next-section-skips-hidden-children ()
  (pimacs-section-tests-with-demo-buffer
    (let ((build (pimacs-section--find-section '(build) pimacs-section--root-section)))
      (pimacs-section--set-visibility build :hide)
      (should (eq (pimacs-section-type (pimacs-section--next-section build)) 'logs)))))

(ert-deftest pimacs-section--prev-section-skips-hidden-children ()
  (pimacs-section-tests-with-demo-buffer
    (let ((logs (pimacs-section--find-section '(logs) pimacs-section--root-section))
          (build (pimacs-section--find-section '(build) pimacs-section--root-section)))
      (pimacs-section--set-visibility build :hide)
      (should (eq (pimacs-section-type (pimacs-section--prev-section logs)) 'build)))))

(ert-deftest pimacs-section--goto-previous-section-of-type ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 10)
    (pimacs-section--goto-previous-section-of-type 'build)
    (should (eq (pimacs-section-type (pimacs-section--current-section)) 'build))))

(ert-deftest pimacs-section--goto-previous-section-of-type-current-section ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 11)
    (pimacs-section--goto-previous-section-of-type 'logs)
    (should (eq (pimacs-section-type (pimacs-section--current-section)) 'logs))
    (should (= (point) (pimacs-section-beginning (pimacs-section--current-section))))))

;; ─── pimacs-section--delete-section ────────────────────────────────────────────

(ert-deftest pimacs-section-delete-removes-content ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (let ((build (pimacs-section--current-section)))
      (pimacs-section--delete-section build)
      (should (not (search-forward "[-] Build" nil t)))
      (should (looking-at (regexp-quote "[-] Logs\n"))))))

(ert-deftest pimacs-section-delete-removes-from-parent-children ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (let ((build (pimacs-section--current-section)))
      (pimacs-section--delete-section build)
      (should (not (memq build (pimacs-section-children pimacs-section--root-section))))
      ;; other root children remain
      (let ((remaining-types
             (mapcar #'pimacs-section-type (pimacs-section-children pimacs-section--root-section))))
        (should (equal remaining-types '(logs deploy)))))))

(ert-deftest pimacs-section-delete-updates-parent-end ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (let* ((build (pimacs-section--current-section))
           (old-parent-end (marker-position (pimacs-section-end pimacs-section--root-section)))
           (build-size (- (marker-position (pimacs-section-end build))
                          (pimacs-section-beginning build))))
      (pimacs-section--delete-section build)
      (should (= (marker-position (pimacs-section-end pimacs-section--root-section))
                 (- old-parent-end build-size))))))

(ert-deftest pimacs-section-delete-middle-child ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 10)
    (let ((logs (pimacs-section--current-section)))
      (pimacs-section--delete-section logs)
      (goto-char (point-min))
      (should (looking-at (regexp-quote "[-] Build\n")))
      (forward-line 10)
      (should (looking-at (regexp-quote "[-] Deploy\n")))
      (let ((remaining-types
             (mapcar #'pimacs-section-type (pimacs-section-children pimacs-section--root-section))))
        (should (equal remaining-types '(build deploy)))))))

(ert-deftest pimacs-section-delete-leaf-child ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 1)
    (let* ((compile (pimacs-section--current-section))
           (build (pimacs-section-parent compile)))
      (pimacs-section--delete-section compile)
      (should (not (memq compile (pimacs-section-children build))))
      (goto-char (pimacs-section-beginning build))
      (should (looking-at (regexp-quote "[-] Build\n")))
      (forward-line 1)
      (should (looking-at (regexp-quote "  [-] Tests\n"))))))

(ert-deftest pimacs-section-delete-nested-content-gone ()
  (pimacs-section-tests-with-demo-buffer
    (goto-char (point-min))
    (forward-line 10)
    (let ((logs (pimacs-section--current-section)))
      (pimacs-section--delete-section logs)
      (goto-char (point-min))
      ;; server and worker content should be gone
      (should (not (search-forward "Connected client" nil t)))
      (should (not (search-forward "Job" nil t))))))

(ert-deftest pimacs-section-delete-all-restores-empty-root-bounds ()
  (pimacs-with-root-section
    (let* ((initial-root-beginning (pimacs-section-beginning pimacs-section--root-section))
           (initial-root-end (marker-position (pimacs-section-end pimacs-section--root-section)))
           (build (pimacs-section--new-section 'build pimacs-section--root-section))
           (compile (pimacs-section--new-section 'compile build))
           (logs (pimacs-section--new-section 'logs pimacs-section--root-section)))
      (pimacs-section--insert-section build
        (insert "[-] Build\n"))
      (pimacs-section--insert-section compile
        (insert "  [-] Compile\n")
        (insert "      Compiling foo.c\n"))
      (pimacs-section--insert-section logs
        (insert "[-] Logs\n")
        (insert "  Listening on :8080\n"))
      (pimacs-section--delete-section build)
      (pimacs-section--delete-section logs)
      (should (= (pimacs-section-beginning pimacs-section--root-section)
                 initial-root-beginning))
      (should (= (marker-position (pimacs-section-end pimacs-section--root-section))
                 initial-root-end))
      (should (null (pimacs-section-children pimacs-section--root-section)))
      (should (equal (buffer-string) "")))))

;; ─── pimacs-section--update-section-end ─────────────────────────────────────────────

(ert-deftest pimacs-section--update-section-end-expands ()
  (pimacs-with-root-section
    (let ((child (pimacs-section--new-section 'child pimacs-section--root-section)))
      (pimacs-section--insert-section child
        (insert "  [-] Compile\n")
        (insert "      Compiling foo.c\n")
        (insert "      Compiling bar.c\n"))
      (setf (pimacs-section-beginning child) (point-min))
      (setf (pimacs-section-end child) (point-min-marker))
      (let ((m (make-marker)))
        (set-marker m 10)
        (pimacs-section--update-section-end child m)
        (should (= (pimacs-section-end child) 10))))))

(ert-deftest pimacs-section--update-section-end-propagates-to-parent ()
  (pimacs-with-root-section
    (let ((child (pimacs-section--new-section 'child pimacs-section--root-section)))
      (pimacs-section--insert-section child
        (insert "  [-] Compile\n")
        (insert "      Compiling foo.c\n")
        (insert "      Compiling bar.c\n"))
      (setf (pimacs-section-beginning child) (set-marker (make-marker) 1))
      (setf (pimacs-section-end child) (set-marker (make-marker) 5))
      (setf (pimacs-section-beginning pimacs-section--root-section) (set-marker (make-marker) 1))
      (setf (pimacs-section-end pimacs-section--root-section) (set-marker (make-marker) 5))
      (let ((m (make-marker)))
        (set-marker m 20)
        (pimacs-section--update-section-end child m)
        (should (= (pimacs-section-end pimacs-section--root-section) 20))))))

(ert-deftest pimacs-section--update-section-end-does-not-shrink ()
  (pimacs-with-root-section
    (let ((child (pimacs-section--new-section 'child pimacs-section--root-section)))
      (pimacs-section--insert-section child
        (insert "  [-] Compile\n")
        (insert "      Compiling foo.c\n")
        (insert "      Compiling bar.c\n"))
      (setf (pimacs-section-beginning child) (set-marker (make-marker) 1))
      (setf (pimacs-section-end child) (set-marker (make-marker) 20))
      (let ((m (make-marker)))
        (set-marker m 5)
        (pimacs-section--update-section-end child m)
        (should (= (pimacs-section-end child) 20))))))

;; ─── pimacs-section--set-visibility / pimacs-toggle-section ─────────────────────

(ert-deftest pimacs-section--set-visibility-hides ()
  "Setting visibility to :hide or :autohide makes content invisible."
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (let ((build (pimacs-section--current-section)))
      (pimacs-section--set-visibility build :hide)
      (goto-char (pimacs-section-beginning build))
      (forward-line 1)
      (should (invisible-p (point)))
      (pimacs-section--set-visibility build :autohide)
      (should (invisible-p (point))))))

(ert-deftest pimacs-section--set-visibility-shows ()
  "Setting visibility to :show or :autoshow makes content visible."
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (let ((build (pimacs-section--current-section)))
      (pimacs-section--set-visibility build :hide)
      (pimacs-section--set-visibility build :show)
      (goto-char (pimacs-section-beginning build))
      (forward-line 1)
      (should (not (invisible-p (point))))
      (pimacs-section--set-visibility build :autoshow)
      (should (not (invisible-p (point)))))))

(ert-deftest pimacs-toggle-section-toggles-visibility ()
  "Toggle transitions: :autoshow->:hide, :autohide->:show, :show->:hide, :hide->:show."
  (pimacs-section-tests-with-demo-buffer
    (goto-char 1)
    (let ((build (pimacs-section--current-section)))
      (should (eq (pimacs-section-visibility build) :autoshow))
      ;; :autoshow -> :hide
      (pimacs-toggle-section)
      (should (eq (pimacs-section-visibility build) :hide))
      ;; :hide -> :show
      (pimacs-toggle-section)
      (should (eq (pimacs-section-visibility build) :show))
      ;; :show -> :hide
      (pimacs-toggle-section)
      (should (eq (pimacs-section-visibility build) :hide))
      ;; :hide -> :show
      (pimacs-toggle-section)
      (should (eq (pimacs-section-visibility build) :show))
      ;; :autohide -> :show
      (pimacs-section--set-visibility build :autohide)
      (should (eq (pimacs-section-visibility build) :autohide))
      (pimacs-toggle-section)
      (should (eq (pimacs-section-visibility build) :show)))))

(ert-deftest pimacs-section--set-visibility-updates-fringe-indicator ()
  (cl-letf (((symbol-function 'display-graphic-p)
             (lambda (&optional _frame) t)))
    (pimacs-section-tests-with-demo-buffer
      (let* ((build (pimacs-section--current-section))
             (overlay (pimacs-section-tests--visibility-indicator-overlay build)))
        (should overlay)
        (should (equal (get-text-property 0 'display
                                          (overlay-get overlay 'before-string))
                       '(left-fringe pimacs-section-fringe-bitmapv fringe)))
        (pimacs-section--set-visibility build :hide)
        (setq overlay (pimacs-section-tests--visibility-indicator-overlay build))
        (should overlay)
        (should (equal (get-text-property 0 'display
                                          (overlay-get overlay 'before-string))
                       '(left-fringe pimacs-section-fringe-bitmap> fringe)))))))

(ert-deftest pimacs-section--visibility-indicator-shows-for-leaf-sections ()
  (cl-letf (((symbol-function 'display-graphic-p)
             (lambda (&optional _frame) t)))
    (pimacs-with-root-section
      (let ((leaf (pimacs-section--new-section 'leaf pimacs-section--root-section)))
        (pimacs-section--insert-section leaf
          (insert "[-] Leaf\n"))
        (should (pimacs-section-tests--visibility-indicator-overlay leaf))))))

(ert-deftest pimacs-section--hidden-parent-hides-child-fringe-indicator ()
  (cl-letf (((symbol-function 'display-graphic-p)
             (lambda (&optional _frame) t)))
    (pimacs-with-root-section
      (let* ((parent (pimacs-section--new-section 'parent pimacs-section--root-section))
             (child (pimacs-section--new-section 'child parent)))
        (pimacs-section--insert-section parent
          (insert "[-] Parent\n"))
        (pimacs-section--insert-section child
          (insert "  [-] Child\n"))
        (should (pimacs-section-tests--visibility-indicator-overlay child))
        (pimacs-section--set-visibility parent :hide)
        (should-not (pimacs-section-tests--visibility-indicator-overlay child))
        (pimacs-section--set-visibility parent :show)
        (should (pimacs-section-tests--visibility-indicator-overlay child))))))

(ert-deftest pimacs-section--visibility-indicator-skips-root ()
  (cl-letf (((symbol-function 'display-graphic-p)
             (lambda (&optional _frame) t)))
    (pimacs-with-root-section
      (pimacs-section--propertize-section pimacs-section--root-section)
      (should-not (pimacs-section-tests--visibility-indicator-overlay
                   pimacs-section--root-section)))))

(ert-deftest pimacs-section--delete-section-keeps-parent-fringe-indicator ()
  (cl-letf (((symbol-function 'display-graphic-p)
             (lambda (&optional _frame) t)))
    (pimacs-with-root-section
      (let* ((parent (pimacs-section--new-section 'parent pimacs-section--root-section))
             (child (pimacs-section--new-section 'child parent)))
        (pimacs-section--insert-section parent
          (insert "[-] Parent\n"))
        (pimacs-section--insert-section child
          (insert "  [-] Child\n"))
        (should (pimacs-section-tests--visibility-indicator-overlay parent))
        (pimacs-section--delete-section child)
        (should (pimacs-section-tests--visibility-indicator-overlay parent))))))

;; ─── pimacs-section-autohide ───────────────────────────────────────────────

(ert-deftest pimacs-section-autohide-nil-count ()
  (pimacs-with-root-section
    (let ((a (pimacs-section--new-section 'a pimacs-section--root-section))
          (b (pimacs-section--new-section 'b pimacs-section--root-section)))
      (pimacs-section--insert-section a (insert "[-] A\n"))
      (pimacs-section--insert-section b (insert "[-] B\n"))
      (pimacs-section--set-visibility a :autohide)
      (let ((pimacs-section-autohide-count nil))
        (pimacs-section-autohide)
        (should (eq (pimacs-section-visibility a) :autoshow))
        (should (eq (pimacs-section-visibility b) :autoshow))))))

(ert-deftest pimacs-section-autohide-skips-middle-section-at-point ()
  (pimacs-with-root-section
    (let ((a (pimacs-section--new-section 'a pimacs-section--root-section))
          (b (pimacs-section--new-section 'b pimacs-section--root-section))
          (c (pimacs-section--new-section 'c pimacs-section--root-section))
          (d (pimacs-section--new-section 'd pimacs-section--root-section)))
      (pimacs-section--insert-section a (insert "[-] A\n"))
      (pimacs-section--insert-section b (insert "[-] B\n"))
      (pimacs-section--insert-section c (insert "[-] C\n"))
      (pimacs-section--insert-section d (insert "[-] D\n"))
      (let ((pimacs-section-autohide-count 2))
        (goto-char (pimacs-section-beginning b))
        (pimacs-section-autohide)
        (should (eq (pimacs-section-visibility a) :autohide))
        (should (eq (pimacs-section-visibility b) :autoshow))
        (should (eq (pimacs-section-visibility c) :autoshow))
        (should (eq (pimacs-section-visibility d) :autoshow))))))

(ert-deftest pimacs-section-autohide-skips-non-autoshow ()
  (pimacs-with-root-section
    (let ((a (pimacs-section--new-section 'a pimacs-section--root-section))
          (b (pimacs-section--new-section 'b pimacs-section--root-section))
          (c (pimacs-section--new-section 'c pimacs-section--root-section)))
      (pimacs-section--insert-section a (insert "[-] A\n"))
      (pimacs-section--insert-section b (insert "[-] B\n"))
      (pimacs-section--insert-section c (insert "[-] C\n"))
      (pimacs-section--set-visibility a :show)
      (let ((pimacs-section-autohide-count 1))
        (pimacs-section-autohide)
        (should (eq (pimacs-section-visibility a) :show))
        (should (eq (pimacs-section-visibility b) :autohide))
        (should (eq (pimacs-section-visibility c) :autoshow))))))

(ert-deftest pimacs-section-autohide-includes-only-configured-types ()
  (pimacs-with-root-section
    (let ((user (pimacs-section--new-section 'user pimacs-section--root-section))
          (old-call (pimacs-section--new-section 'tool-call pimacs-section--root-section))
          (assistant (pimacs-section--new-section 'assistant pimacs-section--root-section))
          (new-call (pimacs-section--new-section 'tool-call pimacs-section--root-section)))
      (pimacs-section--insert-section user (insert "[-] User\n"))
      (pimacs-section--insert-section old-call (insert "[-] Old call\n"))
      (pimacs-section--insert-section assistant (insert "[-] Assistant\n"))
      (pimacs-section--insert-section new-call (insert "[-] New call\n"))
      (pimacs-section--set-visibility user :autohide)
      (pimacs-section--set-visibility assistant :autohide)
      (let ((pimacs-section-autohide-count 1)
            (pimacs-section-autohide-filter '(:include tool-call)))
        (pimacs-section-autohide)
        (should (eq (pimacs-section-visibility user) :autoshow))
        (should (eq (pimacs-section-visibility old-call) :autohide))
        (should (eq (pimacs-section-visibility assistant) :autoshow))
        (should (eq (pimacs-section-visibility new-call) :autoshow))))))

(ert-deftest pimacs-section-autohide-excludes-configured-types ()
  (pimacs-with-root-section
    (let ((user (pimacs-section--new-section 'user pimacs-section--root-section))
          (old-call (pimacs-section--new-section 'tool-call pimacs-section--root-section))
          (assistant (pimacs-section--new-section 'assistant pimacs-section--root-section))
          (new-call (pimacs-section--new-section 'tool-call pimacs-section--root-section))
          (info (pimacs-section--new-section 'info pimacs-section--root-section)))
      (pimacs-section--insert-section user (insert "[-] User\n"))
      (pimacs-section--insert-section old-call (insert "[-] Old call\n"))
      (pimacs-section--insert-section assistant (insert "[-] Assistant\n"))
      (pimacs-section--insert-section new-call (insert "[-] New call\n"))
      (pimacs-section--insert-section info (insert "[-] Info\n"))
      (let ((pimacs-section-autohide-count 1)
            (pimacs-section-autohide-filter '(:exclude tool-call)))
        (pimacs-section-autohide)
        (should (eq (pimacs-section-visibility user) :autohide))
        (should (eq (pimacs-section-visibility old-call) :autoshow))
        (should (eq (pimacs-section-visibility assistant) :autohide))
        (should (eq (pimacs-section-visibility new-call) :autoshow))
        (should (eq (pimacs-section-visibility info) :autoshow))))))

(ert-deftest pimacs-section-autohide-accepts-predicate-function ()
  (pimacs-with-root-section
    (let ((edit (pimacs-section--new-section 'tool-call pimacs-section--root-section))
          (bash (pimacs-section--new-section 'tool-call pimacs-section--root-section)))
      (pimacs-section--insert-section edit (insert "[-] Edit\n"))
      (pimacs-section--insert-section bash (insert "[-] Bash\n"))
      (pimacs-section--set-info
       edit (make-pimacs-section-tool-call-info :tool-name "edit"))
      (pimacs-section--set-info
       bash (make-pimacs-section-tool-call-info :tool-name "bash"))
      (pimacs-section--set-visibility edit :autohide)
      (let ((pimacs-section-autohide-count 0)
            (pimacs-section-autohide-filter
             (lambda (section)
               (not (equal
                     (pimacs-section-tool-call-info-tool-name
                      (pimacs-section-info section))
                     "edit")))))
        (pimacs-section-autohide)
        (should (eq (pimacs-section-visibility edit) :autoshow))
        (should (eq (pimacs-section-visibility bash) :autohide))))))

(ert-deftest pimacs-section-autohide-skips-unchanged-visibility ()
  (pimacs-with-root-section
    (let ((a (pimacs-section--new-section 'a pimacs-section--root-section))
          (b (pimacs-section--new-section 'b pimacs-section--root-section))
          (pimacs-section-autohide-count 1))
      (pimacs-section--insert-section a (insert "[-] A\n"))
      (pimacs-section--insert-section b (insert "[-] B\n"))
      (pimacs-section-autohide)
      (let ((setter (symbol-function 'pimacs-section--set-visibility))
            calls)
        (cl-letf (((symbol-function 'pimacs-section--set-visibility)
                   (lambda (&rest args)
                     (push args calls)
                     (apply setter args))))
          (pimacs-section-autohide))
        (should-not calls)))))

(ert-deftest pimacs-section-cycle-global ()
  (pimacs-section-tests-with-demo-buffer
    (let ((build (pimacs-section--find-section '(build) pimacs-section--root-section))
          (compile (pimacs-section--find-section '(build compile) pimacs-section--root-section))
          (unit-tests (pimacs-section--find-section '(build test unit-tests)
                                                    pimacs-section--root-section)))
      ;; Hide every section.
      (pimacs-section--cycle-global)
      (should (eq (pimacs-section-visibility build) :hide))
      (should (eq (pimacs-section-visibility compile) :hide))
      (should (eq (pimacs-section-visibility unit-tests) :hide))
      ;; Show the first level.
      (pimacs-section--cycle-global)
      (should (eq (pimacs-section-visibility build) :show))
      (should (eq (pimacs-section-visibility compile) :hide))
      ;; Show the second level.
      (pimacs-section--cycle-global)
      (should (eq (pimacs-section-visibility compile) :show))
      (should (eq (pimacs-section-visibility unit-tests) :hide))
      ;; Show every section, then cycle back to hiding everything.
      (pimacs-section--cycle-global)
      (should (eq (pimacs-section-visibility unit-tests) :show))
      (pimacs-section--cycle-global)
      (should (eq (pimacs-section-visibility build) :hide)))))

(ert-deftest pimacs-section-show-levels-current-tree ()
  (pimacs-section-tests-with-demo-buffer
    (let ((build (pimacs-section--find-section '(build) pimacs-section--root-section))
          (compile (pimacs-section--find-section '(build compile) pimacs-section--root-section))
          (logs (pimacs-section--find-section '(logs) pimacs-section--root-section)))
      (goto-char (pimacs-section-beginning build))
      (pimacs-section-show-level-1)
      (should (pimacs-section--hidden-p build))
      (should (pimacs-section--visible-p logs))
      (pimacs-section--set-visibility build :show)
      (goto-char (pimacs-section-beginning build))
      (pimacs-section-show-level-2)
      (should (pimacs-section--visible-p build))
      (should (pimacs-section--hidden-p compile))
      (should (pimacs-section--visible-p logs)))))

(ert-deftest pimacs-section-inserts-before-existing-child ()
  (pimacs-with-root-section
    (let ((pimacs-section-padding "|"))
      (let* ((loading (pimacs-section--create-section 'history pimacs-section--root-section
                        (insert "loading")))
             (boundary (pimacs-section--create-section 'user pimacs-section--root-section
                         (insert "boundary")))
             (last (pimacs-section--create-section 'user pimacs-section--root-section
                     (insert "last")))
             first second)
        (pimacs-section--with-insertion-before pimacs-section--root-section boundary
          (setq first (pimacs-section--create-section 'user pimacs-section--root-section
                        (insert "first")))
          (setq second (pimacs-section--create-section 'user pimacs-section--root-section
                         (insert "second"))))
        (should (equal (pimacs-section-children pimacs-section--root-section)
                       (list loading first second boundary last)))
        (should (equal (buffer-string) "loading|first|second|boundary|last|"))))))
