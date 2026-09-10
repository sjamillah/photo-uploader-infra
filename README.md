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

Two stacks you deploy; twelve CloudFormation creates for you.

| Stack | Deployed by | Contains |
|---|---|---|
| `photo-app-bootstrap` | created by hand once, then Git sync from `deployments/bootstrap.yaml` | the three roles Git sync needs, the OIDC provider, the template staging bucket |
| `photo-app-main` | Git sync from `deployments/main.yaml` | twelve nested children |

Both are Git-synced. Bootstrap has to be *created* by hand, because it is what
creates the roles Git sync assumes, but once it exists Git sync adopts it and
every later change comes from the repository.

Bootstrap holds only what must exist before anything else can run: those roles,
the OIDC provider, and the bucket the nested templates are staged in. Nothing
else. The registry and the alert topic used to live here and are now
`templates/ecr.yaml` and `templates/alerts.yaml`, so that rebuilding either one
does not destroy the container images or the email subscription.

The registry still has to be built before the service. That is handled by the
`DeployApplication` parameter rather than by a separate stack: the first pass
creates the registry with the service left out, and the second pass adds the
service once an image exists.

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

One file per concern, so the file name is the index:

| Looking for | File |
|---|---|
| CIDRs, subnets, route tables | `network.yaml` |
| Security groups and every rule between them | `security.yaml` |
| VPC endpoints | `endpoints.yaml` |
| Bucket policy, CloudFront, OAC | `media.yaml` |
| PostgreSQL and its credentials | `database.yaml` |
| Any role or policy | `iam.yaml`, `bootstrap.yaml` |
| ALB, listeners, target groups, task definition, scaling | `service.yaml` |
| Blue/green configuration and the alarms that gate a cutover | `codedeploy.yaml` |
| Alarms that only notify | `monitoring.yaml` |
| Deployment trigger, pipeline, artifact bucket | `pipeline.yaml` |

**Nothing account-specific is committed.** The deployment files hold the project
name, the GitHub org, an email address and one boolean. The template bucket, the
CodeConnections ARN and the S3 prefix list id are read from Parameter Store at
deploy time through `AWS::SSM::Parameter::Value<String>` parameters, so no
account id, bucket name or connection ARN ever lands in git.

Values flow down as stack parameters, so the twelve children contain no
`Fn::ImportValue` at all, and `main.yaml` needs only one block per child.

## Getting it running

Eleven steps, and the order is load-bearing. The service cannot start before an
image exists in the registry, and the registry is created by the same stack that
would run the service — so the stack is deployed twice, with a parameter
deciding whether the application half is included.

**1. Create bootstrap by hand.** Console, CloudFormation, Create stack, Upload a
template file, `bootstrap.yaml`. Stack name `photo-app-bootstrap`. It has to be
by hand because it creates the roles Git sync will later ask you for.

| Parameter | Value |
|---|---|
| ProjectName | `photo-app` |
| GitHubOrg | your GitHub account |
| GitHubInfraRepo | `photo-uploader-infra` |
| GitHubBranch | `main` |
| CreateOidcProvider | `false` if the account already has the GitHub provider |

Tick the IAM acknowledgement. Keep the Outputs tab: you need
`GitHubInfraRoleArn` and `TemplateBucketName`.

**2. Create the GitHub connection.** Developer Tools, Connections, Create
connection, GitHub, granting access to both repositories. It is born `PENDING`
and needs an interactive OAuth handshake to become `AVAILABLE` — the one step
in this build with no API. It must be in the same region as the stacks, because
CodeConnections is regional and CodePipeline will not accept one from elsewhere.

**3. Put two values in Parameter Store.** Bootstrap publishes
`/photo-app/template-bucket` and `/photo-app/template-prefix` itself. These two
have no CloudFormation source: the connection ARN only exists once a person has
authorised it, and the prefix list id is assigned by AWS per region with no
resource that returns it.

```bash
aws ssm put-parameter --name /photo-app/connection-arn --type String \
  --overwrite --value "<the ARN from Developer Tools, Connections>"

aws ssm put-parameter --name /photo-app/s3-prefix-list-id --type String \
  --overwrite --value "$(aws ec2 describe-managed-prefix-lists \
    --filters Name=prefix-list-name,Values="com.amazonaws.$AWS_REGION.s3" \
    --query 'PrefixLists[0].PrefixListId' --output text)"

aws ssm get-parameters-by-path --path /photo-app --recursive \
  --query 'Parameters[].[Name,Value]' --output table
```

Four rows, none of them `None`.

**4. Set `DeployApplication: 'false'`** in `deployments/main.yaml`, commit and
push. CI packages and commits `main.packaged.yaml` behind you — wait for that
bot commit before the next step, because it is the file Git sync deploys.

**5. Create the synced stack.** CloudFormation, Create stack, With new
resources, Sync from Git.

| Field | Value |
|---|---|
| Stack name | `photo-app-main` |
| Repository | your connection, branch `main` |
| Deployment file | `deployments/main.yaml` |
| Git sync role | `photo-app-gitsync` |
| Stack operations role | `photo-app-cfn-deployment` |

Choose the existing roles. Do not let the console create new ones. Around
twenty minutes, most of it RDS.

**6. Set the repository secrets** from the two stacks' Outputs.

| Repo | Secret | Source |
|---|---|---|
| infra | `AWS_ROLE_ARN` | `GitHubInfraRoleArn`, from bootstrap |
| infra | `AWS_REGION` | the region everything is deployed into |
| app | `AWS_ROLE_ARN` | `GitHubAppRoleArn`, from `photo-app-main` |
| app | `AWS_REGION` | the same region |
| app | `ECR_REPOSITORY` | `photo-app` |

None of them is a credential on its own. A role ARN grants nothing without a
matching OIDC token, and there are no AWS access keys anywhere in either repo.
They are secrets so that nothing identifying the account is echoed into a public
build log.

**7. Push the application.** CI builds the image and pushes it to ECR. Do not go
on until a tag appears:

```bash
aws ecr describe-images --repository-name photo-app \
  --query 'imageDetails[].imageTags' --output table
```

**8. Flip to the second pass.** Set `DeployApplication: 'true'` in
`deployments/main.yaml`, commit, push. That is a parameter, not a template, so
no packaging is involved and Git sync deploys it directly. This adds the
service, CodeDeploy, the pipeline and the notification alarms.

**9. Generate `deploy/taskdef.json`** in the application repo, from the task
definition CloudFormation just registered. The command is in that repo's README.
Until this is done the pipeline deploys a task definition pointing at whatever
was committed last, which after any rebuild is a secret ARN that no longer
exists.

**10. Adopt bootstrap into Git sync.** `photo-app-bootstrap`, Stack actions,
Sync from Git, deployment file `deployments/bootstrap.yaml`, the same two roles.
It adopts the existing stack rather than creating a second one. Both stacks
synced is the requirement being marked.

Leave this until last. Adopting it earlier means Git sync deploying changes to
`photo-app-gitsync` while it is mid-deploy using that role.

**11. Confirm the SNS subscription.** AWS emails a link when `alerts.yaml`
creates the subscription. Until it is clicked every alarm fires into nothing:

```bash
aws sns list-subscriptions \
  --query "Subscriptions[?contains(TopicArn,'photo-app-alerts')].[Endpoint,SubscriptionArn]" \
  --output text
```

`PendingConfirmation` in the second column means unclicked. Confirmation links
expire after three days, and a link from a previous build of the topic fails
with *"Subscription not confirmed"* — resubscribing the same address sends a
fresh one without creating a duplicate.

## When something needs a nudge

Three things in this system do not happen on their own.

**A config-only change does not deploy.** `pipeline.yaml` sets
`DetectChanges: false` on the GitHub source, so only an image push starts a
deployment — otherwise a README edit in the app repo would cut a release.
Changing `taskdef.json` or `appspec.yaml` alone therefore deploys nothing until
you start a run yourself:

```bash
aws codepipeline start-pipeline-execution --name photo-app-pipeline
```

The retry arrow on a failed stage is not the same thing: it replays the same
source revision, including the file you just fixed.

**Rebuilding the database stack invalidates `taskdef.json`.** Secrets Manager
mints a new random ARN suffix, and the committed file still names the old one.
The task then fails to start with `ResourceInitializationError: unable to pull
secrets` — an *AccessDenied*, not a *NotFound*, because the execution role's
policy is scoped to the real secret. Regenerate the file and start a run.

**Bootstrap changes need bootstrap to be synced.** Until step 10 is done,
editing `bootstrap.yaml` and pushing changes nothing, and the symptom shows up
somewhere else entirely — usually CI failing on `ssm:GetParameter` because the
role in the account predates the grant in the template.

## Roles and what they can do

Nothing is created by hand in the console. The three in `bootstrap.yaml` have to
exist before anything can be deployed; the six in `iam.yaml` belong to the
running system and are deployed with it.

### bootstrap.yaml

| Role | Assumed by | Permitted to |
|---|---|---|
| `photo-app-gha-infra` | GitHub Actions, infra repo, `main` only | Write and delete objects in the template bucket, and read the two Parameter Store values naming it |
| `photo-app-cfn-deployment` | `cloudformation.amazonaws.com`, this account only | The project's services; IAM confined to `photo-app-*` and service-linked roles; denied entirely outside the deployment region |
| `photo-app-gitsync` | `cloudformation.sync.codeconnections.amazonaws.com` | Read the repository through the connection, create and execute change sets, and pass the deployment role to CloudFormation |

The last two carry `DeletionPolicy: Retain`, because CloudFormation assumes the
deployment role to tear the stack down and deleting it partway strands the
delete. See Teardown.

### templates/iam.yaml

| Role | Assumed by | Permitted to |
|---|---|---|
| `photo-app-task-execution` | The ECS agent, before the app starts | Pull the image and create log streams (`AmazonECSTaskExecutionRolePolicy`), plus read the one database secret |
| `photo-app-task` | The application process | `GetObject`, `PutObject` and `DeleteObject` under `photos/` in the media bucket; open ECS Exec channels. No bucket-level access, no `ListBucket` |
| `photo-app-codedeploy` | CodeDeploy | `AWSCodeDeployRoleForECS`: create task sets and shift target groups |
| `photo-app-pipeline` | CodePipeline | The artifact bucket; use the GitHub connection; describe ECR images; drive CodeDeploy; register task definitions; pass the two task roles, and only to ECS |
| `photo-app-eventbridge-pipeline` | EventBridge | Start this one pipeline |
| `photo-app-gha-app` | GitHub Actions, app repo, `main` only | Push to the `photo-app` ECR repository, and write `/photo-app/image/*` in Parameter Store |

`photo-app-gha-app` lives here rather than in bootstrap because it needs the
registry's ARN, and the registry is `templates/ecr.yaml`. That is also why
`GitHubAppRoleArn` is a `main.yaml` output rather than a bootstrap one, and why
it is not conditional on `DeployApplication` — you need it on the first pass,
before there is an image to deploy.

Both GitHub roles pin the `aud` claim to `sts.amazonaws.com` and the `sub` claim
to one repository on `main`. A fork, a pull request, a tag build or any other
branch produces a different `sub`, and STS refuses.

GitHub now also issues immutable subject claims of the form
`repo:owner@1234/repo@5678:ref:refs/heads/main`, which survive a rename. Both
roles accept either shape through `StringLike`, with the literal `@` anchoring
the wildcard so it cannot match an unrelated account.

The split between the two ECS roles is the one worth being able to explain: the
execution role belongs to the agent and the task role belongs to your code, so
application code can never read a secret it was not injected with.

## Repository settings

Settings, Actions, General, Workflow permissions must be **Read and write
permissions**. The `package` job commits `main.packaged.yaml` back, and a
job-level `contents: write` cannot grant more than the repository setting
allows — with the default the push step fails with a 403.

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
`Fn::ImportValue`, so nothing locks: an export cannot be changed or deleted
while an import exists, which turns teardown into twelve deletes in a fixed
order. This way it is one. The cost is S3 staging, handled by CI.

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
| `check` | pull requests and pushes | `make lint`, which is cfn-lint over every template |
| `package` | pushes to `main`, only if `check` passed | `make package`, then commits `main.packaged.yaml` back if it moved |

`package` is the only job granted `id-token: write`, and the only one granted
`contents: write`. A push made with `GITHUB_TOKEN` starts no workflow, so the
commit it makes cannot loop back into another run.

The ordering matters more than it looks. `main.packaged.yaml` is what Git sync
deploys, and CI only writes it after cfn-lint has passed, so a broken template
turns your push into a no-op rather than a failed stack update.

## Two loops

`endpoints.yaml` and `service.yaml` use `Transform: AWS::LanguageExtensions` and
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
| Private ECS, VPC endpoints, public ALB | `network.yaml`, `endpoints.yaml`, `security.yaml`, `service.yaml` | Private route tables with no `0.0.0.0/0`; `AssignPublicIp: DISABLED`; internet-facing ALB |
| CloudFront and private S3 with OAC | `media.yaml` | 200 through CloudFront next to 403 direct to S3 |
| All resources via CloudFormation Git sync | `bootstrap.yaml`, `templates/` | Git sync tab showing a synced commit on **both** stacks; the main stack's Resources tab listing twelve nested children |
| GitHub Actions builds the image | app `ci.yml` | Green `build` job |
| Image pushed to ECR | app `ci.yml` | `describe-images` showing the SHA and `latest` tags |
| OIDC authentication | `bootstrap.yaml` | The trust policy, and Settings showing no AWS access keys in either repo |
| EventBridge detects the push | `pipeline.yaml` | The rule's event pattern, and a pipeline execution whose trigger was the event |
| Application reachable via ALB | `service.yaml` | The URL, serving the gallery |
| Tasks pass ALB health checks | `service.yaml` | `photo-app-tg-blue` with a healthy target |
| Logs in CloudWatch | `service.yaml` | `/ecs/photo-app` with request lines |
| Auto scaling 1 to 4 | `main.yaml`, `service.yaml` | Scaling policy, and desired count moving under load |
| Blue/green works | `codedeploy.yaml`, `pipeline.yaml` | CodeDeploy at 100% on green, and a poll of production showing no failed request |
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

Unsync both stacks first, or a stray push recreates what you deleted. Empty the
three buckets. The media bucket is versioned, so empty that one from the console
rather than with `aws s3 rm`. Delete `photo-app-main`, then
`photo-app-bootstrap`. Finally delete the RDS snapshot, which
`DeletionPolicy: Snapshot` leaves behind and which is billed.

**Delete the two retained roles last, and only after the stack is gone.**
`photo-app-cfn-deployment` and `photo-app-gitsync` carry `DeletionPolicy:
Retain` precisely because CloudFormation assumes the first of them to tear the
stack down. Delete it early and the stack delete fails with *"role is invalid or
cannot be assumed"*, and it keeps failing — CloudFormation caches the failure
against the request token, so retrying alone will not clear it. The recovery is
to recreate the role with the same name, delete the stack, then delete the role:

```bash
aws iam create-role --role-name photo-app-cfn-deployment \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"cloudformation.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name photo-app-cfn-deployment \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

aws cloudformation delete-stack --stack-name photo-app-bootstrap

aws iam detach-role-policy --role-name photo-app-cfn-deployment \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam delete-role --role-name photo-app-cfn-deployment
```

That `AdministratorAccess` attachment is a throwaway for the delete only.
Remove it, or you leave an admin role behind.

If a resource inside the stack refuses to delete, `delete-stack
--retain-resources <LogicalId>` skips it and you clean it up by hand.

Check nothing survives:

```bash
aws ec2 describe-vpc-endpoints --query 'VpcEndpoints[].ServiceName'
aws rds describe-db-snapshots --snapshot-type manual
```

Interface endpoints are the largest silent cost here.
