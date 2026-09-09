# main.yaml references its children by path; CloudFormation only accepts S3 URLs
# for a nested TemplateURL, so `make package` rewrites them before Git sync runs.
PROJECT ?= photo-app
BUCKET   = $(shell aws ssm get-parameter --name /$(PROJECT)/template-bucket              --query Parameter.Value --output text 2>/dev/null)
PREFIX   = $(shell aws ssm get-parameter --name /$(PROJECT)/template-prefix              --query Parameter.Value --output text 2>/dev/null)

.PHONY: ship package lint check

# The only command you need. Packaging cannot be skipped because it is in here.
ship: lint package
	@test -n "$(M)" || (echo 'usage: make ship M="what changed"'; exit 1)
	git add -A
	git commit -m "$(M)"
	git push

package:
	@test -n "$(BUCKET)" || (echo "no /$(PROJECT)/template-bucket found. wrong region, or bootstrap not deployed"; exit 1)
	aws cloudformation package 	  --template-file main.yaml 	  --s3-bucket "$(BUCKET)" 	  --s3-prefix "$(PREFIX)" 	  --output-template-file main.packaged.yaml

lint:
	cfn-lint *.yaml templates/*.yaml

# Package again and prove nothing moved. Linting is a separate CI job.
check: package
	@git diff --exit-code -- main.packaged.yaml 	  || (echo "main.packaged.yaml is stale. Run 'make package' and commit it."; exit 1)
