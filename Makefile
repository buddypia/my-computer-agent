.PHONY: q.check q.fix build test gate

q.check:
	@rm -f .tmp/quality-gate-passed
	@mkdir -p .tmp
	@./Scripts/gate.sh
	@touch .tmp/quality-gate-passed
	@echo "✅ Quality Gate PASSED"

q.fix: q.check

build:
	swift build

test:
	swift test

gate:
	./Scripts/gate.sh

# --- agent harness bundle (auto-managed targets) ---
.PHONY: wt.new wt.run

wt.new:
	@if [ -z "$(BR)" ]; then \
		echo "❌ wt.new: BR=<branch> required. Example: make wt.new BR=feature/<task>"; \
		exit 2; \
	fi
	@node .claude/scripts/worktree-new.mjs --branch $(BR) $(if $(BASE),--base $(BASE)) $(if $(DRY),--dry-run)

wt.run:
	@if [ -z "$(CMD)" ]; then \
		echo "❌ wt.run: CMD=\"<command>\" required. Example: make wt.run CMD=\"npm run test\""; \
		exit 2; \
	fi
	@node .claude/scripts/wt-run.mjs $(CMD)

# --- end agent harness bundle ---
