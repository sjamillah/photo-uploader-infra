# main.yaml references its children by path; `make package` rewrites those into
# bucket URLs. Commit main.packaged.yaml with your change or `make check` fails.
PROJECT ?= photo-app
BUCKET   = $(shell aws ssm get-parameter --name /$(PROJECT)/template-bucket \
             --query Parameter.Value --output text)
PREFIX   = $(shell aws ssm get-parameter --name /$(PROJECT)/template-prefix \
             --query Parameter.Value --output text)

.PHONY: package lint check

package:
	aws cloudformation package \
	  --template-file main.yaml \
	  --s3-bucket "$(BUCKET)" \
	  --s3-prefix "$(PREFIX)" \
	  --output-template-file main.packaged.yaml
	@echo "packaged. commit main.packaged.yaml with your change."

lint:
	cfn-lint *.yaml templates/*.yaml

# What CI runs: package again and prove nothing moved.
check: lint package
	@git diff --exit-code -- main.packaged.yaml \
	  || (echo "main.packaged.yaml is stale. Run 'make package' and commit it."; exit 1)
