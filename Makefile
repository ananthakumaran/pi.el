export EMACS ?= $(shell command -v emacs 2>/dev/null)
CASK_DIR := $(shell cask package-directory)
CASK_TREESIT_EXTRA_LOAD_PATH := $(shell $(EMACS) --batch --eval "(princ (mapconcat (lambda (path) path) treesit-extra-load-path path-separator))" 2>/dev/null)
CASK_EMACS := PIMACS_TREESIT_EXTRA_LOAD_PATH="$(CASK_TREESIT_EXTRA_LOAD_PATH)" cask emacs --batch --eval '(setq treesit-extra-load-path (split-string (getenv "PIMACS_TREESIT_EXTRA_LOAD_PATH") path-separator t))'

MATCH ?=
PIMACS_VERSION := $(shell awk '/^;; Version:/ { print $$3; exit }' pimacs.el)
PIMACS_DOC_SOURCES := pimacs-section.el pimacs-utils.el pimacs-markdown-table.el pimacs-markdown.el \
	pimacs-state-line.el pimacs-core.el pimacs-agent.el pimacs-doctor.el pimacs-session.el pimacs.el

$(CASK_DIR): Cask
	cask install
	@touch $(CASK_DIR)

.PHONY: cask
cask: $(CASK_DIR)

.PHONY: setup
setup: cask
	npm install -g --ignore-scripts @earendil-works/pi-coding-agent
	cd integration/fixture && npm install

.PHONY: compile
compile: cask
	@$(CASK_EMACS) -L . -L test \
	  -f batch-byte-compile pimacs-utils.el pimacs-markdown-table.el pimacs-markdown.el pimacs-state-line.el pimacs-core.el pimacs-section.el pimacs-edit.el pimacs-agent.el pimacs-doctor.el pimacs-session.el pimacs.el; \
	  (ret=$$? ; cask clean-elc && exit $$ret)

.PHONY: package-lint
package-lint: cask
	@$(CASK_EMACS) -Q \
	  --eval "(setq package-lint-main-file \"pimacs.el\")" \
	  -f package-lint-batch-and-exit \
	  pimacs-utils.el pimacs-markdown-table.el pimacs-markdown.el pimacs-state-line.el pimacs-core.el pimacs-section.el pimacs-edit.el pimacs-agent.el pimacs-doctor.el pimacs-session.el pimacs.el

.PHONY: test
test: compile
	@$(CASK_EMACS) -L . -L test -l pimacs-tests.el -l pimacs-agent-tests.el -l pimacs-section-tests.el -l pimacs-state-line-tests.el --eval '(let ((ert-quiet (equal (getenv "PI_CODING_AGENT") "true"))) (ert-run-tests-batch-and-exit "$(MATCH)"))'

.PHONY: markdown-test
markdown-test: compile
	@$(CASK_EMACS) -L . -L test -l pimacs-markdown-tests.el --eval '(let ((ert-quiet (equal (getenv "PI_CODING_AGENT") "true"))) (ert-run-tests-batch-and-exit "$(MATCH)"))'

.PHONY: integration
integration: compile
	@$(CASK_EMACS) -L . -L test -l integration/pimacs-integration-tests.el --eval '(let ((ert-quiet (equal (getenv "PI_CODING_AGENT") "true"))) (ert-run-tests-batch-and-exit "$(MATCH)"))'

.PHONY: markdown-profile
markdown-profile: compile
	@$(CASK_EMACS) -L . -L test -l pimacs-markdown-tests.el -f pimacs-markdown-profile-run

.PHONY: coverage
coverage: export UNDERCOVER_FORCE=true
coverage: export UNDERCOVER_CONFIG=("*.el" (:report-format text) (:exclude "*-tests.el"))
coverage: test integration

.PHONY: format
format:
	@$(CASK_EMACS) -L . -l pimacs-utils.el -l pimacs-markdown-table.el -l pimacs-markdown.el -l pimacs-state-line.el -l pimacs-core.el -l pimacs.el -l pimacs-section.el -l pimacs-edit.el -l pimacs-agent.el -l pimacs-doctor.el -l pimacs-session.el -l pimacs-tests.el -l pimacs-agent-tests.el -l pimacs-markdown-tests.el -l pimacs-section-tests.el -l pimacs-state-line-tests.el -l integration/pimacs-integration-tests.el \
	  --eval " \
	  (let ((inhibit-message t) \
                (message-log-max nil)) \
            (setq-default indent-tabs-mode nil) \
	    (dolist (f command-line-args-left) \
	      (with-current-buffer (find-file-noselect f) \
	        (indent-region (point-min) (point-max)) \
	        (save-buffer))))" \
          pimacs-utils.el pimacs-markdown-table.el pimacs-markdown.el pimacs-state-line.el pimacs-core.el pimacs-section.el pimacs-edit.el pimacs-agent.el pimacs-doctor.el pimacs-session.el pimacs.el pimacs-tests.el pimacs-agent-tests.el pimacs-markdown-tests.el pimacs-section-tests.el pimacs-state-line-tests.el integration/pimacs-integration-tests.el


.PHONY: sandbox
sandbox:
	rm -rf sandbox
	mkdir sandbox
	emacs -Q --init-directory=./sandbox --debug \
	        --eval '(setq user-emacs-directory (file-truename "sandbox"))' \
	        -l package \
	        --eval "(add-to-list 'package-archives '(\"gnu\" . \"http://elpa.gnu.org/packages/\") t)" \
	        --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
	        --eval "(package-refresh-contents)" \
	        --eval "(package-initialize)" \
	        --eval "(use-package pimacs :ensure t :vc (:url \"git@github.com:ananthakumaran/pimacs.el.git\" :rev :newest) :commands (pimacs-chat))" \
                --eval "(when (eq system-type 'darwin) (setq mac-option-key-is-meta nil mac-command-key-is-meta t mac-command-modifier 'meta mac-option-modifier 'none))"


define ESCRIPT
(with-temp-buffer
  (require 'subr-x)
  (insert-file-contents "pimacs-section.el")
  (insert-file-contents "pimacs-utils.el")
  (insert-file-contents "pimacs-markdown-table.el")
  (insert-file-contents "pimacs-markdown.el")
  (insert-file-contents "pimacs-state-line.el")
  (insert-file-contents "pimacs-core.el")
  (insert-file-contents "pimacs-agent.el")
  (insert-file-contents "pimacs-doctor.el")
  (insert-file-contents "pimacs-session.el")
  (insert-file-contents "pimacs.el")
  (while
      (ignore-errors
        (let* ((sexp (read (current-buffer)))
               (form-start (save-excursion
                             (backward-sexp 1)
                             (point))))
          (when sexp
            (when (eq (car sexp) 'defcustom)
              (unless (cadr (cddr sexp))
                (princ (format "Documentation missing for defcustom %S\n" (cadr sexp)))
                (kill-emacs 1))
              (let* ((name (cadr sexp))
                     (default-raw
                      (save-excursion
                        (goto-char form-start)
                        (forward-comment (point-max))
                        (forward-char 1)
                        (forward-sexp 1)
                        (forward-comment (point-max))
                        (forward-sexp 1)
                        (forward-comment (point-max))
                        (let ((default-start (point)))
                          (forward-sexp 1)
                          (buffer-substring-no-properties default-start (point)))))
                     (default-str
                      (with-temp-buffer
                        (emacs-lisp-mode)
                        (insert default-raw)
                        (let ((inhibit-message t))
                          (indent-region (point-min) (point-max)))
                        (string-trim (buffer-string))))
                     (raw-doc (cadr (cddr sexp)))
                     (doc (replace-regexp-in-string "`\\([^']*\\)'" "@code{\\1}" raw-doc))
                     (doc
                      (replace-regexp-in-string
                       "^@code{[^}\n]+}[ \t][ \t]+[^\n]*\n\\(?:@code{[^}\n]+}[ \t][ \t]+[^\n]*\n\\)+"
                       (lambda (block)
                         (save-match-data
                           (with-temp-buffer
                             (insert block)
                             (goto-char (point-min))
                             (while (re-search-forward "^@code{\\([^}\n]+\\)}[ \t][ \t]+\\([^\n]*\\)" nil t)
                               (replace-match (format "@item %s\n%s"
                                                      (match-string 1)
                                                      (match-string 2))
                                              t t))
                             (concat "@table @code\n" (buffer-string) "@end table\n"))))
                       doc)))
                (if (string-match-p "\n" default-str)
                    (princ (format "@defopt %s\n\n@lisp\n%s\n@end lisp\n\n%s\n@end defopt\n\n" name default-str doc))
                  (princ (format "@defopt %s @code{%s}\n\n%s\n@end defopt\n\n" name default-str doc)))))
            t)))))
endef
export ESCRIPT


.PHONY: docs-lint
docs-lint:
	@$(CASK_EMACS) -L . \
	  --eval "(require 'checkdoc)" \
	  --eval "(checkdoc-file \"pimacs.el\")" \
	  --eval "(checkdoc-file \"pimacs-doctor.el\")" \
	  --eval "(checkdoc-file \"pimacs-section.el\")" \
	  --eval "(checkdoc-file \"pimacs-utils.el\")" \
	  --eval "(checkdoc-file \"pimacs-markdown-table.el\")" \
	  --eval "(checkdoc-file \"pimacs-markdown.el\")" \
	  --eval "(checkdoc-file \"pimacs-state-line.el\")" \
	  --eval "(checkdoc-file \"pimacs-edit.el\")" \
	  --eval "(checkdoc-file \"pimacs-agent.el\")" \
	  --eval "(checkdoc-file \"pimacs-core.el\")" \
	  --eval "(checkdoc-file \"pimacs-session.el\")" 2>&1 | grep '^pimacs[.-]' | grep -v 'All variables and subroutines might as well have a documentation string' || true

.PHONY: docs
docs: docs/index.html docs/changelog.html

pimacs.info: Makefile pimacs.texi $(PIMACS_DOC_SOURCES)
	@ruby -e 'txt = IO.read("pimacs.texi").split("@c custom-variables-start")[0] + "@c custom-variables-start\n\n" + `$(EMACS) -Q --batch --eval "$$ESCRIPT"` + "@c custom-variables-end" + IO.read("pimacs.texi").split("@c custom-variables-end")[1]; File.write("pimacs.texi", txt)'
	@makeinfo -D 'VERSION $(PIMACS_VERSION)' -o pimacs.info pimacs.texi

docs/index.html: pimacs.info
	@makeinfo -D 'VERSION $(PIMACS_VERSION)' --no-number-sections --html --no-split -o $@ pimacs.texi

docs/changelog.html: CHANGELOG.md docs/changelog-head.html docs/changelog-template.html docs/global.css
	@pandoc --from=gfm --to=html5 --standalone \
	  --metadata title="Pimacs Changelog" \
	  --template=docs/changelog-template.html \
	  --include-in-header=docs/changelog-head.html --css=global.css \
	  --output=$@ $<

define run-verify-task
	@printf '%s\n' 'make $(1)'
	@$(MAKE) --no-print-directory --silent $(1)
endef

.PHONY: verify
verify:
	$(call run-verify-task,format)
	$(call run-verify-task,test)
	$(call run-verify-task,markdown-test)
	$(call run-verify-task,docs)
	$(call run-verify-task,docs-lint)
	$(call run-verify-task,package-lint)

.PHONY: verify-full
verify-full:
	$(call run-verify-task,format)
	$(call run-verify-task,test)
	$(call run-verify-task,markdown-test)
	$(call run-verify-task,docs)
	$(call run-verify-task,integration)
	$(call run-verify-task,docs-lint)
	$(call run-verify-task,package-lint)
