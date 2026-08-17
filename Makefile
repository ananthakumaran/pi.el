export EMACS ?= $(shell command -v emacs 2>/dev/null)
CASK_DIR := $(shell cask package-directory)
CASK_TREESIT_EXTRA_LOAD_PATH := $(shell $(EMACS) --batch --eval "(princ (mapconcat (lambda (path) path) treesit-extra-load-path path-separator))" 2>/dev/null)
CASK_EMACS := PIMACS_TREESIT_EXTRA_LOAD_PATH="$(CASK_TREESIT_EXTRA_LOAD_PATH)" cask emacs --batch --eval '(setq treesit-extra-load-path (split-string (getenv "PIMACS_TREESIT_EXTRA_LOAD_PATH") path-separator t))'

MATCH ?=
SESSION_FILE ?=
SESSION_PATH ?= $(SESSION_FILE)
PIMACS_DOC_SOURCES := pimacs-section.el pimacs-edit.el pimacs-utils.el pimacs-markdown-table.el pimacs-markdown.el \
	pimacs-state-line.el pimacs-core.el pimacs-agent.el pimacs-doctor.el pimacs-session.el pimacs.el

VERSION ?=

.PHONY: bump-version
bump-version:
	@test -n "$(VERSION)" || (echo "Usage: make bump-version VERSION=x.y.z" >&2; exit 1)
	@printf '%s\n' "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-pre)?$$' || (echo "Invalid version: $(VERSION)" >&2; exit 1)
	@sed -i.bak -E 's/^(;; Version:).*/\1 $(VERSION)/' pimacs.el
	@sed -i.bak -E 's/^(@set VERSION).*/\1 $(VERSION)/' pimacs.texi
	@rm -f pimacs.el.bak pimacs.texi.bak

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
	@$(CASK_EMACS) -L . -L test -l pimacs-markdown-tests.el -l pimacs-markdown-table-tests.el --eval '(let ((ert-quiet (equal (getenv "PI_CODING_AGENT") "true"))) (ert-run-tests-batch-and-exit "$(MATCH)"))'

.PHONY: integration
integration: compile
	@$(CASK_EMACS) -L . -L test -l integration/pimacs-integration-tests.el --eval '(let ((ert-quiet (equal (getenv "PI_CODING_AGENT") "true"))) (ert-run-tests-batch-and-exit "$(MATCH)"))'

.PHONY: markdown-profile
markdown-profile: compile
	@$(CASK_EMACS) -L . -L test -l pimacs-markdown-tests.el -f pimacs-markdown-profile-run

.PHONY: profile-session-render
profile-session-render: compile
	@test -n "$(SESSION_PATH)" || (echo "SESSION_PATH is required" >&2; exit 1)
	@PIMACS_RENDER_PROFILE_SESSION_FILE="$(SESSION_PATH)" \
	  $(CASK_EMACS) -L . -l scripts/profile-session-render.el \
	  -f pimacs-render-profile--command-line

.PHONY: coverage
coverage: export UNDERCOVER_FORCE=true
coverage: export UNDERCOVER_CONFIG=("*.el" (:report-format text) (:exclude "*-tests.el"))
coverage: test integration

.PHONY: format
format:
	@$(CASK_EMACS) -L . -L test -l pimacs-utils.el -l pimacs-markdown-table.el -l pimacs-markdown.el -l pimacs-state-line.el -l pimacs-core.el -l pimacs.el -l pimacs-section.el -l pimacs-edit.el -l pimacs-agent.el -l pimacs-doctor.el -l pimacs-session.el -l test/pimacs-tests.el -l test/pimacs-agent-tests.el -l test/pimacs-markdown-tests.el -l test/pimacs-markdown-table-tests.el -l test/pimacs-section-tests.el -l test/pimacs-state-line-tests.el -l integration/pimacs-integration-tests.el \
	  --eval " \
	  (let ((inhibit-message t) \
                (message-log-max nil)) \
            (setq-default indent-tabs-mode nil) \
	    (dolist (f command-line-args-left) \
	      (with-current-buffer (find-file-noselect f) \
	        (indent-region (point-min) (point-max)) \
	        (save-buffer))))" \
          pimacs-utils.el pimacs-markdown-table.el pimacs-markdown.el pimacs-state-line.el pimacs-core.el pimacs-section.el pimacs-edit.el pimacs-agent.el pimacs-doctor.el pimacs-session.el pimacs.el test/pimacs-tests.el test/pimacs-agent-tests.el test/pimacs-markdown-tests.el test/pimacs-markdown-table-tests.el test/pimacs-section-tests.el test/pimacs-state-line-tests.el integration/pimacs-integration-tests.el


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
	        --eval "(use-package pimacs :ensure t)" \
                --eval "(when (eq system-type 'darwin) (setq mac-option-key-is-meta nil mac-command-key-is-meta t mac-command-modifier 'meta mac-option-modifier 'none))"

.PHONY: docs-lint
docs-lint:
	@PIMACS_DOC_ACTION=lint PIMACS_DOC_SOURCES="$(PIMACS_DOC_SOURCES)" \
	  $(CASK_EMACS) -L . -l docs/build.el 2>&1 | \
	  grep '^pimacs[.-]' | grep -v 'All variables and subroutines might as well have a documentation string' || true

.PHONY: docs
docs: docs/index.html docs/index.md docs/changelog.html docs/changelog.md

pimacs.info: Makefile pimacs.texi $(PIMACS_DOC_SOURCES) docs/build.el
	@PIMACS_DOC_SOURCES="$(PIMACS_DOC_SOURCES)" $(EMACS) -Q --batch -l docs/build.el
	@makeinfo -o pimacs.info pimacs.texi

docs/index.html: pimacs.info
	@makeinfo --no-number-sections --html --no-split -o $@ pimacs.texi

docs/index.md: pimacs.info
	@tmp=$$(mktemp); \
	trap 'rm -f "$$tmp"' EXIT; \
	makeinfo --no-number-sections --docbook -o "$$tmp" pimacs.texi && \
	pandoc --from=docbook --to=gfm --standalone --output=$@ "$$tmp"

docs/changelog.html: CHANGELOG.md docs/changelog-head.html docs/changelog-template.html docs/global.css
	@pandoc --from=gfm --to=html5 --standalone \
	  --metadata title="Pimacs Changelog" \
	  --template=docs/changelog-template.html \
	  --include-in-header=docs/changelog-head.html --css=global.css \
	  --output=$@ $<

docs/changelog.md: CHANGELOG.md
	@cp $< $@

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
