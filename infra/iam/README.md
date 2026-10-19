# IAM for eks-practice

What exists in account `<AWS_ACCOUNT_ID>` (us-east-1) for the cluster, and how it
was created. Policy documents in this folder are the exact JSON used.

> The AWS account ID and the cluster's OIDC provider ID are redacted
> deliberately as `<AWS_ACCOUNT_ID>` and `<OIDC_ID>`; render them with the
> commands below. Subnet IDs and the association ID are the original values,
> shown as a record — on a new cluster they will differ.

Render the placeholders for your account and cluster (writes to `.rendered/`,
which is gitignored):

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ID=$(aws eks describe-cluster --name eks-practice --region us-east-1 \
  --query 'cluster.identity.oidc.issuer' --output text | sed 's|.*/id/||')
mkdir -p .rendered
for f in infra/iam/*-trust-policy.json; do
  sed -e "s/<AWS_ACCOUNT_ID>/$AWS_ACCOUNT_ID/g" -e "s/<OIDC_ID>/$OIDC_ID/g" "$f" > ".rendered/$(basename "$f")"
done
```

The commands below then use `file://.rendered/…` for the trust policies.

## OIDC identity provider (for IRSA)

`arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>`

```bash
aws iam create-open-id-connect-provider \
  --url https://oidc.eks.us-east-1.amazonaws.com/id/$OIDC_ID \
  --client-id-list sts.amazonaws.com
```

Trusted by the AWS Load Balancer Controller role below.

## AWS Load Balancer Controller (IRSA)

| Resource | Value |
|---|---|
| Policy | `arn:aws:iam::<AWS_ACCOUNT_ID>:policy/eks-practice-AWSLoadBalancerController` — the official [`iam_policy.json` at v3.6.0](https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v3.6.0/docs/install/iam_policy.json): [`aws-load-balancer-controller-policy.v3.6.0.json`](aws-load-balancer-controller-policy.v3.6.0.json) |
| Role | `arn:aws:iam::<AWS_ACCOUNT_ID>:role/eks-practice-aws-load-balancer-controller` |
| Trust policy | [`aws-load-balancer-controller-trust-policy.json`](aws-load-balancer-controller-trust-policy.json) — the cluster OIDC provider, `sub` = `system:serviceaccount:kube-system:aws-load-balancer-controller`, `aud` = `sts.amazonaws.com` |
| ServiceAccount | [`platform/aws-load-balancer-controller/serviceaccount.yaml`](../../platform/aws-load-balancer-controller/serviceaccount.yaml) (role-arn annotation) |

```bash
aws iam create-policy --policy-name eks-practice-AWSLoadBalancerController \
  --policy-document file://infra/iam/aws-load-balancer-controller-policy.v3.6.0.json
aws iam create-role --role-name eks-practice-aws-load-balancer-controller \
  --assume-role-policy-document file://.rendered/aws-load-balancer-controller-trust-policy.json
aws iam attach-role-policy --role-name eks-practice-aws-load-balancer-controller \
  --policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/eks-practice-AWSLoadBalancerController
# Subnets the controller may place internet-facing ALBs in:
aws ec2 create-tags --resources subnet-0a1941b4dfdc5991a subnet-0d4961f49d7549fe9 \
  subnet-0ae45884493a1c0c1 subnet-0308db969f1aa66c2 subnet-01682c81c587baf9c \
  --tags Key=kubernetes.io/role/elb,Value=1
```

See [`docs/identity.md`](../../docs/identity.md) for IRSA vs Pod Identity.

## EBS CSI driver (EKS Pod Identity)

| Resource | Value |
|---|---|
| Role | `arn:aws:iam::<AWS_ACCOUNT_ID>:role/eks-practice-ebs-csi-driver` |
| Trust policy | [`ebs-csi-driver-trust-policy.json`](ebs-csi-driver-trust-policy.json) — `pods.eks.amazonaws.com`, scoped to this account and cluster |
| Permissions | AWS managed `AmazonEBSCSIDriverPolicy` — snapshot of the version attached: [`AmazonEBSCSIDriverPolicy.v15.json`](AmazonEBSCSIDriverPolicy.v15.json) |
| Pod Identity association | `a-wrlmjyymmdufqhkvx`: `kube-system/ebs-csi-controller-sa` → role above |
| Addon | `aws-ebs-csi-driver` `v1.67.0-eksbuild.1` |

```bash
aws iam create-role --role-name eks-practice-ebs-csi-driver \
  --assume-role-policy-document file://.rendered/ebs-csi-driver-trust-policy.json
aws iam attach-role-policy --role-name eks-practice-ebs-csi-driver \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
aws eks create-pod-identity-association --cluster-name eks-practice \
  --namespace kube-system --service-account ebs-csi-controller-sa \
  --role-arn arn:aws:iam::$AWS_ACCOUNT_ID:role/eks-practice-ebs-csi-driver
aws eks create-addon --cluster-name eks-practice \
  --addon-name aws-ebs-csi-driver --addon-version v1.67.0-eksbuild.1
```

The default StorageClass using it is [`infra/k8s/storageclass-gp3.yaml`](../k8s/storageclass-gp3.yaml).
