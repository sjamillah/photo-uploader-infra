# main.yaml references its children by path; CloudFormation only accepts S3
# URLs for a nested TemplateURL, so CI packages before Git sync reads it.
PROJECT  ?= photo-app
# Pinned so a new release fails on the commit that bumps it, not on someone
# else's unrelated push. CFN_LINT resolves to whatever is on PATH, falling back
# to the venv make tools builds, because pip --user lands somewhere /bin/sh
# does not look.
CFN_LINT_PIN = cfn-lint==1.56.1
CFN_LINT  = $(shell command -v cfn-lint 2>/dev/null || echo $(HOME)/.venvs/cfn/bin/cfn-lint)
REGION    = $(shell aws configure get region)
ACCOUNT   = $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
BUCKET    = $(shell aws ssm get-parameter --name /$(PROJECT)/template-bucket \
              --query Parameter.Value --output text 2>/dev/null)
PREFIX    = $(shell aws ssm get-parameter --name /$(PROJECT)/template-prefix \
              --query Parameter.Value --output text 2>/dev/null)
ARTIFACTS = $(PROJECT)-artifacts-$(ACCOUNT)-$(REGION)
.PHONY: tools lint package verify empty

# Run once per machine. An isolated venv, because newer Ubuntu refuses
# pip install --user outright.
tools:
	python3 -m venv $(HOME)/.venvs/cfn
	$(HOME)/.venvs/cfn/bin/pip install --quiet --upgrade pip
	$(HOME)/.venvs/cfn/bin/pip install --quiet "$(CFN_LINT_PIN)"
	@$(HOME)/.venvs/cfn/bin/cfn-lint --version

# Sources only. *.yaml would sweep in main.packaged.yaml, and a stale
# artefact would then block the very target that regenerates it.
lint:
	$(CFN_LINT) main.yaml bootstrap.yaml templates/*.yaml

# Run before every push, then commit main.packaged.yaml alongside your
# change. Linting first keeps a broken template out of S3.
package: lint
	@test -n "$(BUCKET)" || (echo "no /$(PROJECT)/template-bucket found. wrong region, or bootstrap not deployed"; exit 1)
	aws cloudformation package \
	  --template-file main.yaml \
	  --s3-bucket "$(BUCKET)" \
	  --s3-prefix "$(PREFIX)" \
	  --output-template-file main.packaged.yaml

# CI runs this. Repackaging must be a no-op, or the committed file is stale.
verify: package
	@git diff --exit-code -- main.packaged.yaml 	  || (echo "main.packaged.yaml is stale: run 'make package' and commit it"; exit 1)

# CloudFormation will not delete a bucket that still holds objects, and it has
# no way to empty one. That gap is the only part of teardown worth automating.
# Deleting the stacks is a decision, not a chore, so it stays yours.
empty:
	@test "$(CONFIRM)" = "$(PROJECT)" || (echo "refusing. run: make empty CONFIRM=$(PROJECT)"; exit 1)
	@test -n "$(ACCOUNT)" || (echo "cannot resolve the account. no credentials?"; exit 1)
	@test -n "$(BUCKET)" || (echo "cannot resolve the template bucket. wrong region?"; exit 1)
	-aws s3 rm "s3://$(ARTIFACTS)" --recursive
	aws s3 rm "s3://$(BUCKET)" --recursive
	@echo "emptied. now delete $(PROJECT)-main, then $(PROJECT)-bootstrap"
