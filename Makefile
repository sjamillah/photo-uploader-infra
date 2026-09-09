# main.yaml references its children by path; CloudFormation only accepts S3 URLs
# for a nested TemplateURL, so CI packages before Git sync reads the repository.
PROJECT ?= photo-app
BUCKET   = $(shell aws ssm get-parameter --name /$(PROJECT)/template-bucket              --query Parameter.Value --output text 2>/dev/null)
PREFIX   = $(shell aws ssm get-parameter --name /$(PROJECT)/template-prefix              --query Parameter.Value --output text 2>/dev/null)

.PHONY: package lint

# CI runs this on every push to main. Locally it is only for seeing the diff.
package:
	@test -n "$(BUCKET)" || (echo "no /$(PROJECT)/template-bucket found. wrong region, or bootstrap not deployed"; exit 1)
	aws cloudformation package 	  --template-file main.yaml 	  --s3-bucket "$(BUCKET)" 	  --s3-prefix "$(PREFIX)" 	  --output-template-file main.packaged.yaml

lint:
	cfn-lint *.yaml templates/*.yaml
