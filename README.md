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

| Stack | Deployed by | Contains |
|---|---|---|
| `photo-app-bootstrap` | created by hand once, then Git sync from `deployments/bootstrap.yaml` | IAM roles, OIDC provider, ECR, template staging bucket, SNS topic |
| `photo-app-main` | Git sync from `deployments/main.yaml` | eight nested children |

Both stacks are Git-synced. Bootstrap has to be *created* by hand, because it
is what creates the roles Git sync assumes, but once it exists Git sync adopts
it and every later change comes from the repository.

The risk that buys is small and recoverable: if a push breaks `GitSyncRole` or
`CfnDeploymentRole`, CloudFormation rolls the update back, and the fallback is
re-running the same deploy command that created it.

Templates are named for the AWS service they hold, so the file name tells
you what is inside. ECR is the exception: it is in `bootstrap.yaml`, because
an image has to exist before the main stack creates the service that runs one.

Two files at the repository root are the things you deploy. Everything in
`templates/` is a nested child that `main.yaml` composes and never deployed on
its own.

| File | Holds |
|---|---|
| `bootstrap.yaml` | Deployed by hand: IAM, OIDC, ECR, staging bucket, alert topic |
| `main.yaml` | The Git-synced parent; composes the eight templates below |
| `templates/vpc.yaml` | VPC, subnets, routing, VPC endpoints, security groups |
| `templates/s3-cloudfront.yaml` | Private media bucket behind a distribution |
| `templates/rds.yaml` | PostgreSQL and its generated credentials |
| `templates/iam.yaml` | Every role the running system assumes |
| `templates/ecs.yaml` | ECS cluster and service, auto scaling, CodeDeploy |
| `templates/codepipeline.yaml` | EventBridge rule, CodePipeline, artifact bucket |
| `templates/cloudwatch.yaml` | Alarms that notify, not ones that block |
| `scripts/upload-templates.sh` | What CI runs to upload and pin |

Deploy order is `vpc -> s3-cloudfront -> rds -> iam -> alb -> ecs ->
codepipeline -> cloudwatch`, which CloudFormation works out from the `!GetAtt` references
between them.

Two splits are worth knowing about, because both look arbitrary until you hit
the reason:

- **The load balancer is separate from the service.** CodeDeploy owns the
  relationship between them, swapping which target group the production
  listener forwards to. Keeping the pair together makes that the subject of
  one file.
- **Alarms are split by what they do.** The two the deployment group blocks on
  are in `ecs.yaml`, because they have to exist before it does. Everything
  that only emails somebody is in `cloudwatch.yaml`, deployed last, since its
  dimensions come from three other stacks.

### Finding a resource

Every template is divided by `# ---` banners, so `grep "# ---" templates/ecs.yaml`
prints its contents. Roughly:

| Looking for | File | Section |
|---|---|---|
| CIDRs, subnets, route tables | `vpc.yaml` | Subnets, Routing |
| Security group rules | `vpc.yaml` | Security group rules |
| VPC endpoints | `vpc.yaml` | VPC endpoints |
| Bucket policy, CloudFront, RDS | `s3-cloudfront.yaml` and `rds.yaml` | Media storage, Database |
| Any role or policy | `iam.yaml`, `bootstrap.yaml` | see the table below |
| ALB, listeners, target groups | `ecs.yaml` | Load balancer, Listeners |
| Task definition, scaling | `ecs.yaml` | Cluster and task, Auto scaling |
| Blue/green configuration | `ecs.yaml` | Blue/green deployment |
| Gating alarms | `ecs.yaml` | Alarms that gate the cutover |
| Notification alarms | `cloudwatch.yaml` | Database, Load balancer, Service capacity |
| Deployment trigger | `codepipeline.yaml` | Triggers and notifications |

Nested stacks need an S3 `TemplateURL` and Git sync has no packaging step, so
CI uploads everything in `templates/` under the commit SHA, then writes
that SHA into `deployments/main.yaml`. The resulting commit is what Git sync
deploys, which closes the race where it could otherwise start while the upload
was still running.

**Nothing account-specific is committed.** The deployment file holds a commit
SHA, the project name and the GitHub org, and that is all. The bucket, the
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

`/photo-app/image/current` is written by the application pipeline and stays
that way. Creating it here would mean every bootstrap update reset it to a
placeholder, rolling ECS back to an image that does not exist.

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

Nothing is created by hand in the console. The four in `bootstrap.yaml` have to
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

## One repository setting

The `upload` job commits the pinned version back, so `GITHUB_TOKEN` needs write
access: **Settings, Actions, General, Workflow permissions, "Read and write
permissions"**.

Without it the job fails at `git push`, the version is never pinned, and Git
sync goes on deploying the previous set of templates. Nothing errors loudly,
which is what makes it worth checking first when a change does not appear.

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
cost is S3 staging, handled by the SHA pinning above.

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
do?" has one answer, and it takes about 170 lines out of `ecs.yaml` and
`codepipeline.yaml`. The cost is that adding a permission for a new resource means
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
| `upload` | pushes to `main`, and only if `check` passed | upload templates, pin the commit |

`upload` exits early when no template changed, so a README commit does not
re-upload anything, and its own commit carries `[skip ci]` so it cannot trigger
the workflow again. Only `upload` is granted `id-token: write`.

## Two loops

`vpc.yaml` and `ecs.yaml` use `Transform: AWS::LanguageExtensions` and
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
| Multi-AZ VPC, subnet design | `vpc.yaml` | VPC resource map; six subnets, three tiers, two AZs |
| Private ECS, VPC endpoints, public ALB | `vpc.yaml`, `ecs.yaml` | Private route tables with no `0.0.0.0/0`; `AssignPublicIp: DISABLED`; internet-facing ALB |
| CloudFront and private S3 with OAC | `s3-cloudfront.yaml` and `rds.yaml` | 200 through CloudFront next to 403 direct to S3 |
| All resources via CloudFormation Git sync | `bootstrap.yaml`, `templates/` | Git sync tab showing a commit SHA on **both** stacks; the main stack's Resources tab listing eight nested children |
| GitHub Actions builds the image | app `ci.yml` | Green `build` job |
| Image pushed to ECR | app `ci.yml` | `describe-images` showing the SHA and `latest` tags |
| OIDC authentication | `bootstrap.yaml` | The trust policy, and Settings showing no AWS access keys in either repo |
| EventBridge detects the push | `codepipeline.yaml` | The rule's event pattern, and a pipeline execution whose trigger was the event |
| Application reachable via ALB | `ecs.yaml` | The URL, serving the gallery |
| Tasks pass ALB health checks | `ecs.yaml` | `photo-app-tg-blue` with a healthy target |
| Logs in CloudWatch | `ecs.yaml` | `/ecs/photo-app` with request lines |
| Auto scaling 1 to 4 | `main.yaml`, `ecs.yaml` | Scaling policy, and desired count moving under load |
| Blue/green works | `ecs.yaml`, `codepipeline.yaml` | CodeDeploy at 100% on green, and a poll of production showing no failed request |
| Security and cost practices | throughout | The Decisions and Known gaps sections above |

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
