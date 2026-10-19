# Teardown

Run on 2026-10-19, 09:23–10:30Z, against `eks-practice` in us-east-1. This
page is the order that was actually used, the three traps worth recording,
and what the orphan sweep found. A reusable command runbook follows.
Pre-teardown snapshot and final billing: [final-state.md](final-state.md).

## Three traps

**1. Load balancers survive cluster deletion.** The ALB isn't an EKS
resource. EKS doesn't know it exists. The AWS Load Balancer
Controller created the ALB, its target groups and its security groups. Only
the controller deletes them, and only while it's running and sees the Ingress
go away. Delete the cluster first and the ALB stays, billing ~$0.0225/h plus
its public IPv4 addresses, with nothing left to clean it up. So: delete the
Ingresses (and any `type: LoadBalancer` Service), **wait until the ALB is
gone**, and only then remove anything else.

**2. PVCs survive `helm uninstall`.** Volumes created from a StatefulSet's
`volumeClaimTemplates` aren't part of the Helm release. Uninstalling the chart
leaves the PVC, the PV and the EBS volume behind. Deleting the cluster then
strands the EBS volume, because the CSI driver that would have deleted it is
gone. Delete PVCs while the driver is still running, then confirm the volumes
are gone in EC2.

What actually happened with the five PVCs:

| PVC | Created by | After `helm uninstall` |
|---|---|---|
| Postgres `data-flightdeck-postgresql-0` | StatefulSet template | **survived** → deleted by hand |
| Redis `redis-data-flightdeck-redis-master-0` | StatefulSet template | **survived** → deleted by hand |
| Prometheus `prometheus-…-db-…-0` | operator StatefulSet template | **survived** → deleted by hand |
| Grafana | a plain PVC in the chart's manifest | deleted with the release |
| Loki | StatefulSet with `persistentVolumeClaimRetentionPolicy: Delete` | deleted with the release |

So "PVCs survive uninstall" is true by default but not always. Each chart
decides. Don't assume either way: list PVCs after every uninstall.

The same goes for anything annotated `helm.sh/resource-policy: keep` (the
`flightdeck-db` Secret) and for objects applied outside Helm (the
`flightdeck-slo` PrometheusRule and the two dashboard ConfigMaps). All of
them were deleted by hand.

**3. A stopped clock service looks like a credentials problem.** Teardown
started with every AWS call failing. The workstation clock was **604 s
behind**. SigV4 signs the request time, and AWS rejects any signature more
than 5 minutes (300 s) off. Depending on the client and service, the error was
`InvalidSignatureException` or `SignatureExpired`. The first reads like bad
keys; the second points at the clock if you read the rest of the message
(`Signature expired: <signed time> is now earlier than <server time - 5 min>`).

`kubectl` kept working throughout, which made the AWS CLI's credentials look
like the problem. Setting the clock by hand didn't help: NTP looked blocked. The
real cause was that the **Windows Time service (`w32time`) was stopped**.
Starting it and setting it to Automatic brought the offset to ~1 s.

Check before you debug credentials:

```powershell
w32tm /query /status          # "The service has not been started" = this trap
w32tm /stripchart /computer:time.windows.com /samples:1 /dataonly
```

## Order used

| Phase | What | Time (Z) | Result |
|---|---|---|---|
| 0 | Snapshot: `helm list`, ingresses, PVCs, nodes, cost, credits | 09:23 | [final-state.md](final-state.md) |
| 1 | Ingresses deleted; wait for the ALB | 09:25–09:27:54 | ALB, 2 `k8s-` target groups, 2 controller SGs removed by the controller. No LoadBalancer Services existed. |
| 2 | `helm uninstall` flightdeck → alloy → loki → kube-prometheus-stack → aws-load-balancer-controller (last, once no Ingress remained) | 09:42:59–09:46:29 | `helm list -A` empty |
| 3 | 3 surviving PVCs, kept Secret, PrometheusRule, 2 dashboard ConfigMaps | ~09:50 | all 5 app/platform EBS volumes NotFound; 0 snapshots |
| 4 | Node group `ng-public`, then cluster | 09:59:25–10:09:15 | 2 instances terminated, both 20 GiB roots NotFound, `list-clusters` empty |
| 5 | IAM (below) | ~10:15 | all gone |
| 6 | Sweep, us-east-1 and ap-south-1 | ~10:20 | see below |

**IAM** — from [infra/iam/README.md](../infra/iam/README.md), plus the two roles the cluster was created with:

- `eks-practice-ebs-csi-driver`: detached `AmazonEBSCSIDriverPolicy`, then deleted.
- `eks-practice-aws-load-balancer-controller` (IRSA): detached the custom policy, then deleted.
- Custom policy `eks-practice-AWSLoadBalancerController`: 0 attachments, deleted.
- `eks-practice-cluster-role`: detached `AmazonEKSClusterPolicy`, then deleted.
- `eks-practice-node-role`: first removed from its **instance profile**
  (`eks-practice-node-role`), then the profile was deleted. Without that step,
  `delete-role` fails. Then the 3 AWS-managed policies were detached and the
  role deleted.
- The IAM OIDC provider for the cluster was deleted. It's an account-level
  object, so cluster deletion leaves it behind.
- **Already gone:** the Pod Identity association for EBS CSI. It's part of the
  cluster, so cluster deletion removed it.
- **Left alone on purpose:** `AWSServiceRoleForAmazonEKS`,
  `AWSServiceRoleForAmazonEKSNodegroup` (service-linked, shared), and the
  `prod-eks-*` roles (another project in ap-south-2).

## What the sweep found

Checked in us-east-1 and ap-south-1:

- EC2 instances, EBS volumes, snapshots, Elastic IPs
- ALB/NLB and classic LBs, target groups
- Non-default security groups (with an ENI count), detached ENIs, non-default VPCs, NAT gateways
- ECR repositories, CloudWatch log groups, CloudFormation stacks
- EKS clusters, ASGs, launch templates, key pairs

**Result: nothing in either region.** The only remaining default security group in each region is the default VPC's own.

Three things are worth knowing:

- **Subnet tags.** `kubernetes.io/role/elb` was still on the 5 default-VPC
  subnets in us-east-1. Harmless and free, but it was ours, so it was removed.
- **The tagging API lies for a while.** `resourcegroupstaggingapi get-resources`
  still listed 7 ARNs tagged for the cluster (5 volumes, 2 instances) an hour
  after deletion. Every one was NotFound or `terminated` when queried directly.
  Use it to find candidates, then verify each one against the service's own API.
- **The ECR line on the bill isn't this project.** Cost Explorer shows ECR
  storage ($0.0035) and $0.84 of EC2-Other, but both are in **ap-south-2**,
  which is prod-eks, not flightdeck. flightdeck's images were always on GHCR,
  and both swept regions have zero ECR repositories.

No CloudWatch log groups existed: control-plane logging was never enabled.
No CloudFormation stacks existed: the cluster wasn't created with eksctl.

## What stays (on purpose)

- **GHCR images** `ghcr.io/saicharanchanda/flightdeck-*`: public, and they outlive the account.
- **GitHub Pages** and the repository.
- **Local kubeconfig context** for the deleted cluster:
  `kubectl config delete-context arn:aws:eks:us-east-1:<AWS_ACCOUNT_ID>:cluster/eks-practice`.

---

## Runbook

All commands assume `AWS_REGION=us-east-1 CLUSTER=eks-practice` and
`AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)`.

**1. Ingresses, then wait for the ALB**

```bash
kubectl -n monitoring delete ingress kube-prometheus-stack-grafana
kubectl -n flightdeck delete ingress flightdeck-gateway
kubectl get svc -A --field-selector spec.type=LoadBalancer   # must be empty
# repeat until empty:
aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'flightdeck') || starts_with(LoadBalancerName,'k8s-')].LoadBalancerName" --output text
```

**2. Releases (controller last)**

```bash
helm uninstall flightdeck -n flightdeck
helm uninstall alloy loki kube-prometheus-stack -n monitoring
kubectl get ingress -A        # must be empty
helm uninstall aws-load-balancer-controller -n kube-system
```

**3. What uninstall left**

```bash
kubectl get pvc -A
kubectl delete pvc --all -n flightdeck
kubectl delete pvc --all -n monitoring
kubectl -n flightdeck delete secret flightdeck-db --ignore-not-found
kubectl -n monitoring delete prometheusrule flightdeck-slo --ignore-not-found
kubectl -n monitoring delete configmap dashboard-flightdeck-platform dashboard-flightdeck-red --ignore-not-found
kubectl get pv                # wait until empty
aws ec2 describe-volumes --filters Name=tag-key,Values=kubernetes.io/created-for/pvc/name --query 'Volumes[].VolumeId' --output text
```

**4. Cluster**

```bash
aws eks delete-nodegroup --cluster-name $CLUSTER --nodegroup-name ng-public
aws eks wait nodegroup-deleted --cluster-name $CLUSTER --nodegroup-name ng-public
aws eks delete-cluster --name $CLUSTER
aws eks wait cluster-deleted --name $CLUSTER
```

For a cluster made from `infra/cluster.yaml`, use
`eksctl delete cluster -f infra/cluster.yaml --wait` instead. That also
removes the VPC, the roles and the CloudFormation stacks eksctl created.

**5. IAM**

```bash
detach_all() { for p in $(aws iam list-attached-role-policies --role-name $1 --query 'AttachedPolicies[].PolicyArn' --output text); do aws iam detach-role-policy --role-name $1 --policy-arn $p; done; }
for r in eks-practice-ebs-csi-driver eks-practice-aws-load-balancer-controller eks-practice-cluster-role; do detach_all $r; aws iam delete-role --role-name $r; done
aws iam delete-policy --policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/eks-practice-AWSLoadBalancerController
aws iam remove-role-from-instance-profile --instance-profile-name eks-practice-node-role --role-name eks-practice-node-role
aws iam delete-instance-profile --instance-profile-name eks-practice-node-role
detach_all eks-practice-node-role; aws iam delete-role --role-name eks-practice-node-role
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>
```

**6. Sweep** (each should print nothing; repeat per region)

```bash
aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text
aws ec2 describe-volumes --query 'Volumes[].VolumeId' --output text
aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[].SnapshotId' --output text
aws ec2 describe-addresses --query 'Addresses[].AllocationId' --output text
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text
aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName' --output text
aws ec2 describe-security-groups --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName]" --output text
aws ecr describe-repositories --query 'repositories[].repositoryName' --output text
aws logs describe-log-groups --query 'logGroups[].logGroupName' --output text
aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED --query 'StackSummaries[].StackName' --output text
aws ec2 describe-subnets --filters Name=tag-key,Values=kubernetes.io/role/elb --query 'Subnets[].SubnetId' --output text
```

Then check Cost Explorer a day later: the EKS, EC2, ELB and EBS lines should
stop at the teardown hour.
