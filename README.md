# Photo Uploader: infrastructure

Infrastructure for [Darkroom](https://github.com/sjamillah/photo-uploader-app),
a containerised photo gallery running on ECS Fargate in a single region.
Everything here is CloudFormation, deployed through Git sync.

The product is called Darkroom; the infrastructure prefix stays `photo-app`.
Renaming would touch every ARN, and product names differing from
infrastructure identifiers is normal.

## Live endpoints

| What | URL |
|---|---|
| Application (ALB) | `http://photo-app-alb-XXXXXXXX.<region>.elb.amazonaws.com` |
| Images | `https://dXXXXXXXXXXXXX.cloudfront.net/photos/...` |

## Stack layout

Two stacks you deploy; eight CloudFormation creates for you.

| Stack | Deployed by | Contains |
|---|---|---|
| `photo-app-bootstrap` | created by hand once, then Git sync from `deployments/bootstrap.yaml` | the three roles Git sync needs, the OIDC provider, the template staging bucket |
| `photo-app-main` | Git sync from `deployments/main.yaml` | ten nested children |

Both are Git-synced. Bootstrap has to be *created* by hand, because it is what
creates the roles Git sync assumes, but once it exists Git sync adopts it and
every later change comes from the repository.

Bootstrap holds only what has to exist before anything else can run: the roles
Git sync and GitHub Actions assume, the bucket the nested templates are staged
in, and the container registry. The registry is there rather than under
`main.yaml` because CI must push an image before `service.yaml` can create a
service that runs one — a registry nested in the root stack would be created in
the same deployment that needs an image already in it.

The alert topic used to be here too. It is now `templates/alerts.yaml`, a
nested child, because nothing needs it before the main stack exists.

Templates are named for what they do, not for the service they happen to use.
`iam.yaml` keeps its name because that already describes its job.

| File | Holds |
|---|---|
| `bootstrap.yaml` | Deployed by hand: the three roles Git sync needs, the OIDC provider, the staging bucket |
| `main.yaml` | The parent, referencing the twelve templates below by path |
| `main.packaged.yaml` | What Git sync deploys. Written by CI, never edited by hand |
| `Makefile` | `make package` and `make lint`, both of which CI runs |
| `templates/ecr.yaml` | The container registry, built on the first pass |
| `templates/alerts.yaml` | The SNS topic every alarm and the pipeline publish to |
| `templates/network.yaml` | VPC, subnets, routing |
| `templates/security.yaml` | The four security groups and every rule between them |
| `templates/endpoints.yaml` | The interface and gateway endpoints that replace a NAT gateway |
| `templates/media.yaml` | Private media bucket behind a CloudFront distribution |
| `templates/database.yaml` | PostgreSQL and its generated credentials |
| `templates/iam.yaml` | Every role the running system assumes |
| `templates/service.yaml` | Load balancer, ECS cluster and service, auto scaling |
| `templates/codedeploy.yaml` | The blue/green application and the two alarms that gate a cutover |
| `templates/pipeline.yaml` | EventBridge rule, CodePipeline, artifact bucket |
| `templates/monitoring.yaml` | Alarms that notify, not ones that block |

### Changing a template

`main.yaml` references its children by path. CloudFormation only accepts an S3
URL for a nested `TemplateURL` and Git sync has no packaging step, so CI does it:

```bash
git add -A && git commit -m "split security out of network" && git push
```

That is the whole flow. The workflow lints, runs `make package`, and commits
`main.packaged.yaml` back if it moved. Git sync deploys **that** commit.

Nothing deploys until cfn-lint passes, because the packaged file is what Git
sync reads and CI only writes it after linting. A broken template makes your
push a no-op rather than a failed stack update.

`make package` locally is only for seeing the rewritten URLs before you push.

Deploy order is `ecr -> alerts -> network -> security -> endpoints -> media ->
database -> iam -> service -> codedeploy -> pipeline -> monitoring`, which
CloudFormation works out from the `!GetAtt` references between them.

`service`, `codedeploy`, `pipeline` and `monitoring` are conditional on
`DeployApplication`. The first pass leaves them out, because a service cannot
reach steady state before CI has pushed an image into the registry that the
same stack has only just created. Push an image, set the parameter to `true`,
and push again.

Two splits are worth knowing about, because both look arbitrary until you hit
the reason:

- **The load balancer is separate from the service.** CodeDeploy owns the
  relationship between them, swapping which target group the production
  listener forwards to. Keeping the pair together makes that the subject of
  one file.
- **Alarms are split by what they do.** The two the deployment group blocks on
  are in `service.yaml`, because they have to exist before it does. Everything
  that only emails somebody is in `monitoring.yaml`, deployed last, since its
  dimensions come from three other stacks.

### Finding a resource

Every template is divided by `# ---` banners, so `grep "# ---" templates/service.yaml`
prints its contents. Roughly:

| Looking for | File | Section |
|---|---|---|
| CIDRs, subnets, route tables | `network.yaml` | Subnets, Routing |
| Security group rules | `network.yaml` | Security group rules |
| VPC endpoints | `network.yaml` | VPC endpoints |
| Bucket policy, CloudFront, RDS | `media.yaml` and `database.yaml` | Media storage, Database |
| Any role or policy | `iam.yaml`, `bootstrap.yaml` | see the table below |
| ALB, listeners, target groups | `service.yaml` | Load balancer, Listeners |
| Task definition, scaling | `service.yaml` | Cluster and task, Auto scaling |
| Blue/green configuration | `service.yaml` | Blue/green deployment |
| Gating alarms | `service.yaml` | Alarms that gate the cutover |
| Notification alarms | `monitoring.yaml` | Database, Load balancer, Service capacity |
| Deployment trigger | `pipeline.yaml` | Triggers and notifications |

Nested stacks need an S3 `TemplateURL`, and Git sync has no packaging step that
would rewrite a local path into a bucket URL. So `main.yaml` points at a fixed
prefix and CI keeps that prefix in step with `templates/` on every push. The
same push is what makes Git sync redeploy the root stack.

Nothing is rewritten and nothing is committed back. `TemplateVersion` names the
prefix once and never changes, which is why there is no generated commit in
this repository's history.

**Nothing account-specific is committed.** The deployment file holds a prefix
name, the project name and the GitHub org, and that is all. The bucket, the
connection ARN and the prefix list id are read from Parameter Store at deploy
time through `AWS::SSM::Parameter::Value<String>` parameters, so no account id,
bucket name or connection ARN ever lands in git.

Values flow down as stack parameters, so the four children contain no
`Fn::ImportValue` at all, and `main.yaml` needs only one line per child.

## Getting it running

Order matters. The service cannot start without an image, and the main stack
resolves the image URI from Parameter Store.

**1. Deploy bootstrap once, with your own credentials.**

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name photo-app-bootstrap \
  --template-file bootstrap.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      GitHubOrg=sjamillah \
      AlertEmail=you@example.com \
  --tags Project=photo-uploader Environment=dev Owner=jamillah.ssozi \
         ManagedBy=cloudformation CostCentre=training

aws cloudformation describe-stacks --stack-name photo-app-bootstrap \
  --query 'Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}' --output table
```

Confirm the SNS subscription email. Until you click that link, every alarm
fires into nothing.

**2. Set the repository secrets** from those outputs.

All six are repository **secrets**, under Settings, Secrets and variables,
Actions.

| Repo | Secret | Source |
|---|---|---|
| infra | `AWS_ROLE_ARN` | `GitHubInfraRoleArn` |
| infra | `TEMPLATE_BUCKET` | `TemplateBucketName` |
| infra | `AWS_REGION` | the region everything is deployed into |
| app | `AWS_ROLE_ARN` | `GitHubAppRoleArn` |
| app | `AWS_REGION` | the same region as the infra repo |
| app | `ECR_REPOSITORY` | `photo-app` |

None of them is a credential on its own. A role ARN grants nothing without a
matching OIDC token, and there are no AWS access keys anywhere in either repo.
They are secrets so that nothing identifying the account is echoed into a
public build log.

**3. Create the GitHub connection.** Developer Tools → Connections → Create
connection → GitHub, granting access to both repositories. It is born
`PENDING` and needs an interactive OAuth handshake to become `AVAILABLE`,
which is the one step in this build with no API.

**4. Put the two remaining values in Parameter Store.** Bootstrap publishes
`/photo-app/template-bucket` itself. These two have no CloudFormation source:
the connection ARN only exists once a person has authorised it, and the prefix
list id is assigned by AWS per region with no resource that returns it.

The connection must be in the same region as the stack. CodeConnections is
regional and CodePipeline will not accept one from elsewhere.

```bash
aws ssm put-parameter --name /photo-app/connection-arn --type String \
  --overwrite --value "<the ARN from Developer Tools, Connections>"

aws ssm put-parameter --name /photo-app/s3-prefix-list-id --type String \
  --overwrite --value "$(aws ec2 describe-managed-prefix-lists \
    --filters Name=prefix-list-name,Values="com.amazonaws.$AWS_REGION.s3" \
    --query 'PrefixLists[0].PrefixListId' --output text)"
```

`/photo-app/image/current` is written by the application pipeline as a record
of what was last published. No template reads it: `main.yaml` builds the task
definition's image from the repository name and the `latest` tag instead, so
that the value never changes between stack updates. The next section says why
that matters.

**5. Push the application.** CI tests and pushes an image, then records
its digest at `/photo-app/image/current`.

**6. Create the synced stack**, named `photo-app-main`. CloudFormation → Create
stack → Sync from Git, branch `main`, deployment file
`deployments/main.yaml`. Choose the existing
`photo-app-gitsync` and `photo-app-cfn-deployment` roles. Do not let the
console create new ones.

**7. Generate `deploy/taskdef.json`** in the application repo, once the service
exists. The command is in that repo's README.

## Roles and what they can do

Nothing is created by hand in the console. The three in `bootstrap.yaml` have to
exist before any pipeline can run; the five in `iam.yaml` belong to the running
system and are deployed with it.

### bootstrap.yaml

| Role | Assumed by | Permitted to |
|---|---|---|
| `photo-app-gha-infra` | GitHub Actions, infra repo, `main` only | Write and delete objects in the template bucket, and nothing else |
| `photo-app-gha-app` | GitHub Actions, app repo, `main` only | Push to the `photo-app` ECR repository; read and write `/photo-app/image/*` in Parameter Store |
| `photo-app-cfn-deployment` | `cloudformation.amazonaws.com`, this account only | The project's services; IAM confined to `photo-app-*` and service-linked roles; denied entirely outside the deployment region |
| `photo-app-gitsync` | `cloudformation.sync.codeconnections.amazonaws.com` | Read the repository through the connection, create and execute change sets, and pass the deployment role to CloudFormation |

Both GitHub roles pin the `aud` claim to `sts.amazonaws.com` and the `sub`
claim to one repository on `main`. A fork, a pull request, a tag build or any
other branch produces a different `sub`, and STS refuses.

### templates/iam.yaml

| Role | Assumed by | Permitted to |
|---|---|---|
| `photo-app-task-execution` | The ECS agent, before the app starts | Pull the image and create log streams (`AmazonECSTaskExecutionRolePolicy`), plus read the one database secret |
| `photo-app-task` | The application process | `GetObject`, `PutObject` and `DeleteObject` under `photos/` in the media bucket; open ECS Exec channels. No bucket-level access, no `ListBucket` |
| `photo-app-codedeploy` | CodeDeploy | `AWSCodeDeployRoleForECS`: create task sets and shift target groups |
| `photo-app-pipeline` | CodePipeline | The artifact bucket; use the GitHub connection; describe ECR images; drive CodeDeploy; register task definitions; pass the two task roles, and only to ECS |
| `photo-app-eventbridge-pipeline` | EventBridge | Start this one pipeline |

The split between the two ECS roles is the one worth being able to explain:
the execution role belongs to the agent and the task role belongs to your code,
so application code can never read a secret it was not injected with.

## Repository settings

Nothing special. The `upload` job only reads the repository and writes to S3, so
the default `GITHUB_TOKEN` permissions are enough.

## Address plan

| Tier | AZ a | AZ b | Usable | Peak use |
|---|---|---|---|---|
| Public | 10.20.0.0/26 | 10.20.0.64/26 | 59 | ~16, ALB scaling |
| Private app | 10.20.4.0/26 | 10.20.4.64/26 | 59 | 18 |
| Private data | 10.20.8.0/27 | 10.20.8.32/27 | 27 | 3 |
| *unallocated* | 10.20.12.0/22 | | | a third AZ, or a NAT-backed tier |

The app tier figure is 5 AWS-reserved + 5 interface endpoint ENIs + 4 tasks +
4 more while blue and green coexist during a cutover.

There are no NAT gateways. The private route tables carry `local` and the S3
prefix list, nothing else, so the tasks have no path to the internet in either
direction. Five interface endpoints across two AZs cost roughly $7/month more
than two NAT gateways would; the trade is deliberate.

## Decisions

**Nested children over separate stacks.** Children take parameters instead of
`Fn::ImportValue`, which strips a lot of ceremony out of the lines you most
need to read, and teardown becomes one delete instead of four in a fixed order. The
cost is S3 staging, handled by the fixed prefix above.

**A /20, not a /16.** Private IPv4 inside a VPC is free, so oversizing
costs nothing today. It costs later: `10.0.0.0/16` is the most-used range
there is, and the day this VPC needs peering or a Transit Gateway an overlap
means renumbering, which you cannot do to a VPC's primary CIDR.

**The deployment role is scoped, not minimal.** An explicit service list with
IAM confined to `photo-app-*`, plus a region lock. The name-prefix scope is the
part that matters: even with `ec2:*`, a role that cannot mint arbitrary IAM
roles cannot escalate its own privileges. A permissions boundary is the next
step, not taken because every child would then need to set it.

**No architecture diagram in this repo.** It is produced separately and
submitted with the report, so it does not go stale here every time a template
moves.

**IAM lives in one file.** Roles were previously next to the resources using
them, spread over three templates. Collecting them means "what can this thing
do?" has one answer, and it takes about 170 lines out of `service.yaml` and
`pipeline.yaml`. The cost is that adding a permission for a new resource means
editing two files.

**Alarms gate deployments.** `AutoRollbackConfiguration` lists
`DEPLOYMENT_STOP_ON_ALARM`, and the deployment group has two alarms attached,
so that event can actually fire. Without them it is a rollback trigger wired to
nothing, and a release that returns 500 on every real request would pass every
health check and go live.

## CI

One workflow, `ci.yml`, with two jobs:

| Job | Runs on | Does |
|---|---|---|
| `check` | pull requests and pushes | cfn-lint |
| `upload` | pushes to `main`, and only if `check` passed | sync `templates/` to the bucket |

The `upload` job syncs with `--delete`, so a template removed from the repository stops
existing in the bucket rather than lingering for a stale URL to find. Only
`upload` is granted `id-token: write`, and neither job writes to the
repository.

## Two loops

`network.yaml` and `service.yaml` use `Transform: AWS::LanguageExtensions` and
`Fn::ForEach` for the five interface endpoints and the two target groups,
which were otherwise five and two near-identical blocks.

The generated logical ids stay predictable (`VpcEndpointEcrApi`,
`TargetGroupBlue`) and the mapping keys they come from are in the template,
so a stack event still points somewhere you can search for. The one cost is that
cfn-lint cannot resolve a service name through `Fn::FindInMap`, so it reads the
five endpoints as duplicates; that check is suppressed on those resources only,
with the reason in a comment. It is not suppressed globally.

## Deliverables

| Required | Where |
|---|---|
| Infrastructure repository | this repo |
| Application repository | https://github.com/sjamillah/photo-uploader-app |
| ALB endpoint | `ApplicationUrl` output of the main stack |
| Network architecture diagram | **produced separately, not in this repo** |

The diagram is deliberately outside version control: it is a submission
artefact, not something the deploy depends on, and keeping it here means it
goes quietly stale every time a template moves.

## Rubric map

| Criterion | Built in | Evidence to capture |
|---|---|---|
| Multi-AZ VPC, subnet design | `network.yaml` | VPC resource map; six subnets, three tiers, two AZs |
| Private ECS, VPC endpoints, public ALB | `network.yaml`, `service.yaml` | Private route tables with no `0.0.0.0/0`; `AssignPublicIp: DISABLED`; internet-facing ALB |
| CloudFront and private S3 with OAC | `media.yaml` and `database.yaml` | 200 through CloudFront next to 403 direct to S3 |
| All resources via CloudFormation Git sync | `bootstrap.yaml`, `templates/` | Git sync tab showing a synced commit on **both** stacks; the main stack's Resources tab listing twelve nested children |
| GitHub Actions builds the image | app `ci.yml` | Green `build` job |
| Image pushed to ECR | app `ci.yml` | `describe-images` showing the SHA and `latest` tags |
| OIDC authentication | `bootstrap.yaml` | The trust policy, and Settings showing no AWS access keys in either repo |
| EventBridge detects the push | `pipeline.yaml` | The rule's event pattern, and a pipeline execution whose trigger was the event |
| Application reachable via ALB | `service.yaml` | The URL, serving the gallery |
| Tasks pass ALB health checks | `service.yaml` | `photo-app-tg-blue` with a healthy target |
| Logs in CloudWatch | `service.yaml` | `/ecs/photo-app` with request lines |
| Auto scaling 1 to 4 | `main.yaml`, `service.yaml` | Scaling policy, and desired count moving under load |
| Blue/green works | `service.yaml`, `pipeline.yaml` | CodeDeploy at 100% on green, and a poll of production showing no failed request |
| Security and cost practices | throughout | The Decisions and Known gaps sections above |

## The task definition can only be changed by CodeDeploy

The ECS service uses the `CODE_DEPLOY` deployment controller, and ECS refuses
any attempt by CloudFormation to move such a service onto a different task
definition:

```
Unable to update task definition on services with a CODE_DEPLOY deployment
controller. Use AWS CodeDeploy to trigger a new deployment.
```

So anything that makes `service.yaml`'s `TaskDefinition` resource change during a
stack update will fail the update and roll the whole stack back. That includes
`TaskCpu`, `TaskMemory`, `ContainerPort` and the container image.

The image is handled: `ImageUri` is built from the repository name and the
`latest` tag, so its string is identical on every update and the task
definition stays put. CodeDeploy pins a digest from `imageDetail.json` from the
first deployment onward.

The sizing parameters are not. To change cpu or memory, change them in
`service.yaml`, let the stack fail, then deploy through the pipeline; or delete and
recreate the service. This is a property of blue/green on ECS, not of these
templates.

## Known gaps

- **The ALB is HTTP.** ACM will not issue a certificate without a domain. The
  fix without buying one is a second CloudFront distribution in front of the
  ALB, using its default `*.cloudfront.net` certificate. That distribution has
  to live in the service child, not the platform child, because the platform
  child deploys first and would otherwise need the ALB's DNS name before it
  exists.
- **No secret rotation.** ECS injects secrets as environment variables once, at
  task start, so single-user rotation would leave running tasks holding a dead
  password with `/health` still passing. Doing this properly needs
  `PostgreSQLMultiUser` rotation or an application that reads the secret at
  connection time.
- **No S3 access logging and no WAF.** Both are cost calls on a stack that runs
  at roughly $115/month; WAF alone is about $6 plus per-request.
- **Schema is created at container start**, not by a migration tool.

## Teardown

Unsync both stacks first, or a stray push recreates what you deleted. Empty
the three buckets. The media bucket is versioned, so empty that one from the console
not with `aws s3 rm`. Delete `photo-app-main`, then
`photo-app-bootstrap`. Finally delete the RDS snapshot, which
`DeletionPolicy: Snapshot` leaves behind and which is billed.

Check nothing survives:

```bash
aws ec2 describe-vpc-endpoints --query 'VpcEndpoints[].ServiceName'
aws rds describe-db-snapshots --snapshot-type manual
```

Interface endpoints are the largest silent cost here.
