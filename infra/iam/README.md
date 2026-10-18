# IAM for eks-practice

What exists in account `259828990969` (us-east-1) for the cluster, and how it
was created. Policy documents in this folder are the exact JSON used.

## OIDC identity provider (for IRSA)

`arn:aws:iam::259828990969:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/56A61AD165D68728B7CDADBC450B2B0B`

```bash
aws iam create-open-id-connect-provider \
  --url https://oidc.eks.us-east-1.amazonaws.com/id/56A61AD165D68728B7CDADBC450B2B0B \
  --client-id-list sts.amazonaws.com
```

No role trusts it yet.

## EBS CSI driver (EKS Pod Identity)

| Resource | Value |
|---|---|
| Role | `arn:aws:iam::259828990969:role/eks-practice-ebs-csi-driver` |
| Trust policy | [`ebs-csi-driver-trust-policy.json`](ebs-csi-driver-trust-policy.json) — `pods.eks.amazonaws.com`, scoped to this account and cluster |
| Permissions | AWS managed `AmazonEBSCSIDriverPolicy` — snapshot of the version attached: [`AmazonEBSCSIDriverPolicy.v15.json`](AmazonEBSCSIDriverPolicy.v15.json) |
| Pod Identity association | `a-wrlmjyymmdufqhkvx`: `kube-system/ebs-csi-controller-sa` → role above |
| Addon | `aws-ebs-csi-driver` `v1.67.0-eksbuild.1` |

```bash
aws iam create-role --role-name eks-practice-ebs-csi-driver \
  --assume-role-policy-document file://infra/iam/ebs-csi-driver-trust-policy.json
aws iam attach-role-policy --role-name eks-practice-ebs-csi-driver \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
aws eks create-pod-identity-association --cluster-name eks-practice \
  --namespace kube-system --service-account ebs-csi-controller-sa \
  --role-arn arn:aws:iam::259828990969:role/eks-practice-ebs-csi-driver
aws eks create-addon --cluster-name eks-practice \
  --addon-name aws-ebs-csi-driver --addon-version v1.67.0-eksbuild.1
```

The default StorageClass using it is [`infra/k8s/storageclass-gp3.yaml`](../k8s/storageclass-gp3.yaml).
