# Pod → AWS identity: IRSA vs EKS Pod Identity

flightdeck uses both mechanisms on `eks-practice`, deliberately:

| Workload | Mechanism | Role |
|---|---|---|
| EBS CSI controller (`kube-system/ebs-csi-controller-sa`) | EKS Pod Identity | `eks-practice-ebs-csi-driver` |
| AWS Load Balancer Controller (`kube-system/aws-load-balancer-controller`) | IRSA | `eks-practice-aws-load-balancer-controller` |

## The short answer

Both give a pod short-lived AWS credentials for one IAM role without node
credentials or static keys. They differ in **who IAM trusts** and **where the
pod → role binding lives**:

- **IRSA**: the role trusts the *cluster's OIDC provider*. The binding is
  split across two places that must agree: a `sub` condition in the IAM trust
  policy (`system:serviceaccount:<ns>:<sa>`) and an
  `eks.amazonaws.com/role-arn` annotation on the ServiceAccount. The pod
  exchanges its projected service-account token with STS
  (`AssumeRoleWithWebIdentity`) itself.
- **Pod Identity**: the role trusts *one AWS service principal*,
  `pods.eks.amazonaws.com`. The binding is an EKS API object, a Pod Identity
  association (cluster + namespace + SA → role). There is no annotation and no
  per-cluster OIDC provider. The pod gets credentials from the
  `eks-pod-identity-agent` DaemonSet on its node, which calls the EKS Auth API
  (`AssumeRoleForPodIdentity`).

## Side by side

| | IRSA | Pod Identity |
|---|---|---|
| IAM prerequisite | One IAM OIDC provider per cluster | None (agent addon in the cluster) |
| Trust policy principal | `Federated: arn:…:oidc-provider/oidc.eks…/id/<cluster-id>` | `Service: pods.eks.amazonaws.com` |
| Trust policy action | `sts:AssumeRoleWithWebIdentity` | `sts:AssumeRole`, `sts:TagSession` |
| Where SA → role is defined | Trust policy `sub` condition **and** SA annotation | Pod Identity association (EKS API) |
| Reusing a role in another cluster | Edit the trust policy: add that cluster's OIDC ID | Add an association; trust policy unchanged¹ |
| What the pod sees | `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE` | `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` |
| Who calls AWS for credentials | The pod's SDK → STS | The pod's SDK → node agent → EKS Auth |
| Session tags for ABAC | No | Yes: cluster, namespace, SA, pod name |
| Runs outside EKS / on Fargate | Yes (any OIDC-capable cluster) | EKS only, EC2 nodes only (needs the agent) |

¹ Our EBS CSI trust policy adds `aws:SourceArn` = the cluster ARN, which pins
it to `eks-practice`. That is a choice, not a requirement.

## Why each was used here

- **EBS CSI → Pod Identity.** It's an EKS add-on, and add-ons support Pod
  Identity first-class. The role needs no knowledge of the cluster's OIDC
  issuer, and the association is managed next to the add-on.
- **Load Balancer Controller → IRSA.** It's installed from its own Helm chart,
  and IRSA is the integration that chart has always documented. It also
  exercises the OIDC provider registered for this cluster.

## How to verify on the cluster

```bash
# IRSA: annotation on the SA, web-identity env injected into the pod
kubectl -n kube-system get sa aws-load-balancer-controller -o jsonpath='{.metadata.annotations}'
kubectl -n kube-system get pod -l app.kubernetes.io/name=aws-load-balancer-controller \
  -o jsonpath='{.items[0].spec.containers[0].env[*].name}'

# Pod Identity: the association lives in EKS, not on the SA
aws eks list-pod-identity-associations --cluster-name eks-practice --region us-east-1
kubectl -n kube-system get pod -l app=ebs-csi-controller \
  -o jsonpath='{.items[0].spec.containers[0].env[*].name}'
```

The EBS CSI pod also lists `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`.
Those are *optional* references to a Secret named `aws-secret` in the add-on's
manifest (the static-key fallback). That Secret doesn't exist, so the
variables are empty and the SDK's credential chain falls through to the Pod
Identity endpoint.

The exact policies are in [`infra/iam/`](../infra/iam/).
