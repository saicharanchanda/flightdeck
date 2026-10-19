# Teardown

Ordered so nothing is orphaned. The account closes 2026-10-22; until then,
everything below bills hourly (≈ $0.36/h at list price, README → Cost).

**The one rule: delete the Ingresses — and wait for the ALB to disappear —
before deleting anything else.** The AWS Load Balancer Controller created the
ALB, its target groups and its security groups; only it removes them, and
only while it is still running. Delete the cluster first and they stay,
billing, with nothing left to clean them up. The same holds for EBS volumes:
PVCs must be deleted while the EBS CSI driver is still running.

All commands assume us-east-1 and `eks-practice`. Set once:

```bash
export AWS_REGION=us-east-1 CLUSTER=eks-practice
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

## 1. Ingresses → wait for the ALB to go

```bash
kubectl -n monitoring delete ingress kube-prometheus-stack-grafana
kubectl -n flightdeck delete ingress flightdeck-gateway
```

```bash
# Repeat until it prints nothing (usually 1-2 minutes):
aws elbv2 describe-load-balancers --names flightdeck --query 'LoadBalancers[].State.Code' --output text
```

## 2. Applications and platform (still with the cluster up)

```bash
helm uninstall flightdeck -n flightdeck
helm uninstall alloy loki kube-prometheus-stack -n monitoring
kubectl delete prometheusrule flightdeck-slo -n monitoring --ignore-not-found
kubectl delete namespace loadtest --ignore-not-found
```

`flightdeck-db` (a Secret with `helm.sh/resource-policy: keep`) and the PVCs
survive `helm uninstall` by design. Delete them now:

```bash
kubectl -n flightdeck delete secret flightdeck-db --ignore-not-found
kubectl -n monitoring delete secret grafana-admin --ignore-not-found
kubectl delete pvc --all -n flightdeck
kubectl delete pvc --all -n monitoring
```

```bash
# Wait until the CSI driver has deleted every volume (gp3, reclaimPolicy Delete):
kubectl get pv
```

kube-prometheus-stack's CRDs are left by Helm; remove them if the cluster is being kept:

```bash
kubectl get crd -o name | grep monitoring.coreos.com | xargs -r kubectl delete
```

Last, the controller itself, once no Ingress remains:

```bash
kubectl get ingress -A        # must be empty
helm uninstall aws-load-balancer-controller -n kube-system
```

## 3. The cluster

If it was created from `infra/cluster.yaml`, eksctl removes the node group, the
add-ons, the Pod Identity association, the IRSA role and the VPC it made:

```bash
eksctl delete cluster -f infra/cluster.yaml --wait
```

The original `eks-practice` was not created by eksctl, so delete it directly:

```bash
aws eks delete-pod-identity-association --cluster-name $CLUSTER \
  --association-id $(aws eks list-pod-identity-associations --cluster-name $CLUSTER --query 'associations[0].associationId' --output text)
aws eks delete-nodegroup --cluster-name $CLUSTER --nodegroup-name ng-public
aws eks wait nodegroup-deleted --cluster-name $CLUSTER --nodegroup-name ng-public
aws eks delete-cluster --name $CLUSTER
aws eks wait cluster-deleted --name $CLUSTER
```

## 4. Orphan sweep

Run each; every one should print nothing (or `0`). Delete what it finds.

**EC2 instances still tagged for the cluster**

```bash
aws ec2 describe-instances --filters Name=tag:eks:cluster-name,Values=$CLUSTER Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text
```

**EBS volumes** — anything left by a PVC, plus any unattached volume

```bash
aws ec2 describe-volumes --filters Name=tag-key,Values=kubernetes.io/created-for/pvc/name \
  --query 'Volumes[].[VolumeId,State,Size]' --output text
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output text
# delete: aws ec2 delete-volume --volume-id vol-...
```

**Elastic IPs** (unassociated ones bill)

```bash
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]' --output text
# release: aws ec2 release-address --allocation-id eipalloc-...
```

**Load balancers and target groups** created by the controller

```bash
aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'flightdeck') || starts_with(LoadBalancerName,'k8s-')].LoadBalancerArn" --output text
aws elbv2 describe-target-groups --query "TargetGroups[?starts_with(TargetGroupName,'k8s-')].TargetGroupArn" --output text
# delete: aws elbv2 delete-load-balancer --load-balancer-arn ...; aws elbv2 delete-target-group --target-group-arn ...
```

**Security groups** the controller made (`k8s-…`) or the cluster left (`eks-cluster-sg-…`)

```bash
aws ec2 describe-security-groups --query "SecurityGroups[?starts_with(GroupName,'k8s-') || starts_with(GroupName,'eks-cluster-sg-$CLUSTER')].[GroupId,GroupName]" --output text
# delete: aws ec2 delete-security-group --group-id sg-...
```

**ECR** — not used (images are on GHCR), but check

```bash
aws ecr describe-repositories --query 'repositories[].repositoryName' --output text
```

**CloudWatch log groups**

```bash
aws logs describe-log-groups --log-group-name-prefix /aws/eks/$CLUSTER --query 'logGroups[].logGroupName' --output text
aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights/$CLUSTER --query 'logGroups[].logGroupName' --output text
# delete: aws logs delete-log-group --log-group-name ...
```

**IAM roles and policies** (`infra/iam/`)

```bash
for role in eks-practice-aws-load-balancer-controller eks-practice-ebs-csi-driver; do
  for p in $(aws iam list-attached-role-policies --role-name $role --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name $role --policy-arn $p
  done
  aws iam delete-role --role-name $role 2>/dev/null && echo "deleted $role"
done
aws iam delete-policy --policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/eks-practice-AWSLoadBalancerController
```

Roles the cluster and node group were created with (names vary; look for the cluster name):

```bash
aws iam list-roles --query "Roles[?contains(RoleName,'$CLUSTER') || contains(RoleName,'eksctl-$CLUSTER')].RoleName" --output text
```

**IAM OIDC provider**

```bash
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text
# delete the one ending in the cluster's OIDC ID:
# aws iam delete-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>
```

**Subnet tags** added for the ALB (default VPC only; harmless, but tidy)

```bash
aws ec2 describe-subnets --filters Name=tag-key,Values=kubernetes.io/role/elb --query 'Subnets[].SubnetId' --output text \
  | xargs -r -n1 -I{} aws ec2 delete-tags --resources {} --tags Key=kubernetes.io/role/elb
```

## 5. What stays (on purpose)

- **GHCR images** `ghcr.io/saicharanchanda/flightdeck-*` — public, outlive the account.
- **GitHub Pages** and the repository.
- **Local**: `~/.kube/config` still has the cluster's context; remove it with
  `kubectl config delete-context arn:aws:eks:us-east-1:$AWS_ACCOUNT_ID:cluster/$CLUSTER`.

## Final check

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=project,Values=flightdeck --query 'ResourceTagMappingList[].ResourceARN' --output text
aws resourcegroupstaggingapi get-resources --tag-filters Key=kubernetes.io/cluster/$CLUSTER --query 'ResourceTagMappingList[].ResourceARN' --output text
```

Both empty means nothing tagged for this project is left. Then check
**Billing → Bills** the next day: EKS, EC2, ELB and EBS lines should stop at
the teardown hour.
