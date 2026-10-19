# Final state of eks-practice

The last snapshot of the cluster before teardown, captured **2026-10-19T09:35:52Z** (server time).
The repo is the deliverable; this is the evidence the cluster existed.

> Times inside `helm list` are workstation-local. On 2026-10-19 that clock
> ran 604-606s behind until the Windows time service was restarted.

## Cost, month to date (Cost Explorer, at 2026-10-19T09:35:52Z)

Usage records only, by service. Credits are booked inside each service, so
an unfiltered by-service view nets to ~$0; this is the gross usage.

```text
EC2 - Other                                         0.9320
AWS Cost Explorer                                   0.0200
Amazon EC2 Container Registry (ECR)                 0.0035
Amazon Elastic Compute Cloud - Compute              2.4898
Amazon Elastic Container Service for Kubernetes     1.6127
Amazon Elastic Load Balancing                       0.2475
Amazon Simple Storage Service                       0.0001
Amazon Virtual Private Cloud                        0.4071
TOTAL usage                                         5.7126
```

Usage vs credits (record type):

```text
Credit                  -5.7126
Tax                      0.0000
Usage                    5.7126
```

By day (Cost Explorer lags up to ~24h, so the last day is incomplete):

```text
2026-10-17   0.0473
2026-10-18   4.9090
2026-10-19   0.0000
```

Account plan: **FREE**, remaining credits **$105.5**, plan expires **2026-10-22T17:38:08.343000+00:00**.

## `helm list -A`

```text
NAME                        	NAMESPACE  	REVISION	UPDATED                               	STATUS  	CHART                             	APP VERSION
alloy                       	monitoring 	2       	2026-10-18 19:13:48.7313426 +0530 IST 	deployed	alloy-1.13.1                      	v1.20.1    
aws-load-balancer-controller	kube-system	1       	2026-10-18 18:08:14.842776 +0530 IST  	deployed	aws-load-balancer-controller-3.6.0	v3.6.0     
flightdeck                  	flightdeck 	14      	2026-10-19 11:26:22.0360384 +0530 IST 	deployed	flightdeck-0.1.0                  	a0c7c1b    
kube-prometheus-stack       	monitoring 	3       	2026-10-18 13:53:36.85878283 +0000 UTC	deployed	kube-prometheus-stack-92.10.1     	v0.94.1    
loki                        	monitoring 	1       	2026-10-18 19:10:55.8322799 +0530 IST 	deployed	loki-7.3.0                        	3.6.12     
```

## `kubectl get ingress -A`

Captured at 2026-10-19T09:23:55Z. Both Ingresses were then deleted outside
this session at about 09:25–09:27Z; the AWS Load Balancer Controller removed
the ALB, its target groups and both of its security groups (last one at
09:27:54Z). By the final capture above, `get ingress -A` returned nothing.

```text
NAMESPACE    NAME                            CLASS   HOSTS   ADDRESS                                             PORTS   AGE
flightdeck   flightdeck-gateway              alb     *       flightdeck-1333631130.us-east-1.elb.amazonaws.com   80      20h
monitoring   kube-prometheus-stack-grafana   alb     *       flightdeck-1333631130.us-east-1.elb.amazonaws.com   80      20h
```

## `kubectl get svc -A --field-selector spec.type=LoadBalancer`

```text
No resources found
```

## `kubectl get pvc -A`

```text
NAMESPACE    NAME                                                                                           STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
flightdeck   data-flightdeck-postgresql-0                                                                   Bound    pvc-e3134d56-e235-4893-b54f-8f5d2a98b4c4   2Gi        RWO            gp3            <unset>                 21h
flightdeck   redis-data-flightdeck-redis-master-0                                                           Bound    pvc-f196da62-6ff5-4002-a099-672b37972650   2Gi        RWO            gp3            <unset>                 21h
monitoring   kube-prometheus-stack-grafana                                                                  Bound    pvc-aac5cc6d-57e7-4bfb-a0b7-705c096155ba   5Gi        RWO            gp3            <unset>                 20h
monitoring   prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0   Bound    pvc-1f7fcf26-9927-4b31-944a-5acc7303d026   10Gi       RWO            gp3            <unset>                 20h
monitoring   storage-loki-0                                                                                 Bound    pvc-a6ba6252-11c6-4fd9-8f3a-a6b2a1e2ad4c   10Gi       RWO            gp3            <unset>                 19h
```

## `kubectl get nodes -o wide`

```text
NAME                            STATUS   ROLES    AGE   VERSION               INTERNAL-IP     EXTERNAL-IP      OS-IMAGE                        KERNEL-VERSION                            CONTAINER-RUNTIME
ip-172-31-41-250.ec2.internal   Ready    <none>   25h   v1.36.4-eks-b9510e3   172.31.41.250   100.30.230.191   Amazon Linux 2023.12.20261012   6.18.54-121.166.amzn2023.x86_64 (amd64)   containerd://2.3.5+unknown
ip-172-31-85-171.ec2.internal   Ready    <none>   25h   v1.36.4-eks-b9510e3   172.31.85.171   3.91.177.81      Amazon Linux 2023.12.20261012   6.18.54-121.166.amzn2023.x86_64 (amd64)   containerd://2.3.5+unknown
```

## `kubectl get all -A`

```text
NAMESPACE     NAME                                                            READY   STATUS    RESTARTS      AGE
flightdeck    pod/flightdeck-flights-999bc5647-44txd                          1/1     Running   0             3h29m
flightdeck    pod/flightdeck-flights-999bc5647-x7db4                          1/1     Running   0             3h29m
flightdeck    pod/flightdeck-gateway-7b84d447fc-lsv84                         1/1     Running   0             3h29m
flightdeck    pod/flightdeck-gateway-7b84d447fc-s9942                         1/1     Running   0             3h29m
flightdeck    pod/flightdeck-notifier-74dd944d46-sfl85                        1/1     Running   0             3h29m
flightdeck    pod/flightdeck-postgresql-0                                     1/1     Running   0             14h
flightdeck    pod/flightdeck-redis-master-0                                   1/1     Running   0             21h
kube-system   pod/aws-load-balancer-controller-65d5559bff-4jt7n               1/1     Running   0             20h
kube-system   pod/aws-load-balancer-controller-65d5559bff-ftzd8               1/1     Running   0             20h
kube-system   pod/aws-node-sb8br                                              2/2     Running   0             25h
kube-system   pod/aws-node-sbvdp                                              2/2     Running   0             25h
kube-system   pod/coredns-687dddfb64-rmcr8                                    1/1     Running   0             26h
kube-system   pod/coredns-687dddfb64-wmz8m                                    1/1     Running   0             26h
kube-system   pod/ebs-csi-controller-699795c679-q9x7l                         6/6     Running   0             21h
kube-system   pod/ebs-csi-controller-699795c679-s2g9s                         6/6     Running   0             21h
kube-system   pod/ebs-csi-node-25845                                          3/3     Running   0             21h
kube-system   pod/ebs-csi-node-45mxb                                          3/3     Running   0             21h
kube-system   pod/eks-node-monitoring-agent-wqdph                             1/1     Running   1 (25h ago)   25h
kube-system   pod/eks-node-monitoring-agent-z84qp                             1/1     Running   0             25h
kube-system   pod/eks-pod-identity-agent-lj7j2                                1/1     Running   0             25h
kube-system   pod/eks-pod-identity-agent-zmz2z                                1/1     Running   0             25h
kube-system   pod/kube-proxy-npbf5                                            1/1     Running   0             25h
kube-system   pod/kube-proxy-x8crg                                            1/1     Running   0             25h
kube-system   pod/metrics-server-54fc76cd9f-7zwrh                             1/1     Running   0             26h
kube-system   pod/metrics-server-54fc76cd9f-kdnsv                             1/1     Running   0             26h
monitoring    pod/alertmanager-kube-prometheus-stack-alertmanager-0           2/2     Running   0             20h
monitoring    pod/alloy-fjp5b                                                 2/2     Running   0             19h
monitoring    pod/alloy-x9lkh                                                 2/2     Running   0             19h
monitoring    pod/kube-prometheus-stack-grafana-5c954854f5-t68bn              3/3     Running   0             19h
monitoring    pod/kube-prometheus-stack-kube-state-metrics-55bb9fff6c-vzd27   1/1     Running   0             20h
monitoring    pod/kube-prometheus-stack-operator-978f5b6f9-sh6ts              1/1     Running   0             20h
monitoring    pod/kube-prometheus-stack-prometheus-node-exporter-sjvns        1/1     Running   0             20h
monitoring    pod/kube-prometheus-stack-prometheus-node-exporter-zpcck        1/1     Running   0             20h
monitoring    pod/loki-0                                                      1/1     Running   0             19h
monitoring    pod/prometheus-kube-prometheus-stack-prometheus-0               2/2     Running   0             20h

NAMESPACE     NAME                                                     TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)                        AGE
default       service/kubernetes                                       ClusterIP   10.100.0.1       <none>        443/TCP                        26h
flightdeck    service/flightdeck-flights                               ClusterIP   10.100.135.35    <none>        8081/TCP                       21h
flightdeck    service/flightdeck-gateway                               ClusterIP   10.100.60.193    <none>        8080/TCP                       21h
flightdeck    service/flightdeck-notifier                              ClusterIP   10.100.106.142   <none>        8082/TCP                       21h
flightdeck    service/flightdeck-postgresql                            ClusterIP   10.100.215.17    <none>        5432/TCP                       21h
flightdeck    service/flightdeck-postgresql-hl                         ClusterIP   None             <none>        5432/TCP                       21h
flightdeck    service/flightdeck-redis-headless                        ClusterIP   None             <none>        6379/TCP                       21h
flightdeck    service/flightdeck-redis-master                          ClusterIP   10.100.218.209   <none>        6379/TCP                       21h
kube-system   service/aws-load-balancer-webhook-service                ClusterIP   10.100.234.60    <none>        443/TCP                        20h
kube-system   service/eks-extension-metrics-api                        ClusterIP   10.100.158.225   <none>        443/TCP                        26h
kube-system   service/kube-dns                                         ClusterIP   10.100.0.10      <none>        53/UDP,53/TCP,9153/TCP         26h
kube-system   service/kube-prometheus-stack-coredns                    ClusterIP   None             <none>        9153/TCP                       20h
kube-system   service/kube-prometheus-stack-kube-proxy                 ClusterIP   None             <none>        10249/TCP                      20h
kube-system   service/kube-prometheus-stack-kubelet                    ClusterIP   None             <none>        10250/TCP,4194/TCP,10255/TCP   20h
kube-system   service/metrics-server                                   ClusterIP   10.100.168.165   <none>        443/TCP                        26h
monitoring    service/alertmanager-operated                            ClusterIP   None             <none>        9093/TCP,9094/TCP,9094/UDP     20h
monitoring    service/alloy                                            ClusterIP   10.100.228.196   <none>        12345/TCP                      19h
monitoring    service/kube-prometheus-stack-alertmanager               ClusterIP   10.100.90.155    <none>        9093/TCP,8080/TCP              20h
monitoring    service/kube-prometheus-stack-grafana                    ClusterIP   10.100.155.202   <none>        80/TCP                         20h
monitoring    service/kube-prometheus-stack-kube-state-metrics         ClusterIP   10.100.109.233   <none>        8080/TCP                       20h
monitoring    service/kube-prometheus-stack-operator                   ClusterIP   10.100.20.46     <none>        443/TCP                        20h
monitoring    service/kube-prometheus-stack-prometheus                 ClusterIP   10.100.118.202   <none>        9090/TCP,8080/TCP              20h
monitoring    service/kube-prometheus-stack-prometheus-node-exporter   ClusterIP   10.100.227.247   <none>        9100/TCP                       20h
monitoring    service/loki                                             ClusterIP   10.100.155.238   <none>        3100/TCP,9095/TCP              19h
monitoring    service/loki-headless                                    ClusterIP   None             <none>        3100/TCP                       19h
monitoring    service/loki-memberlist                                  ClusterIP   None             <none>        7946/TCP                       19h
monitoring    service/prometheus-operated                              ClusterIP   None             <none>        9090/TCP                       20h

NAMESPACE     NAME                                                            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR              AGE
kube-system   daemonset.apps/aws-node                                         2         2         2       2            2           <none>                     26h
kube-system   daemonset.apps/dcgm-server                                      0         0         0       0            0           kubernetes.io/os=linux     26h
kube-system   daemonset.apps/ebs-csi-node                                     2         2         2       2            2           kubernetes.io/os=linux     21h
kube-system   daemonset.apps/ebs-csi-node-windows                             0         0         0       0            0           kubernetes.io/os=windows   21h
kube-system   daemonset.apps/eks-node-monitoring-agent                        2         2         2       2            2           kubernetes.io/os=linux     26h
kube-system   daemonset.apps/eks-pod-identity-agent                           2         2         2       2            2           <none>                     26h
kube-system   daemonset.apps/kube-proxy                                       2         2         2       2            2           <none>                     26h
monitoring    daemonset.apps/alloy                                            2         2         2       2            2           <none>                     19h
monitoring    daemonset.apps/kube-prometheus-stack-prometheus-node-exporter   2         2         2       2            2           kubernetes.io/os=linux     20h

NAMESPACE     NAME                                                       READY   UP-TO-DATE   AVAILABLE   AGE
flightdeck    deployment.apps/flightdeck-flights                         2/2     2            2           21h
flightdeck    deployment.apps/flightdeck-gateway                         2/2     2            2           21h
flightdeck    deployment.apps/flightdeck-notifier                        1/1     1            1           21h
kube-system   deployment.apps/aws-load-balancer-controller               2/2     2            2           20h
kube-system   deployment.apps/coredns                                    2/2     2            2           26h
kube-system   deployment.apps/ebs-csi-controller                         2/2     2            2           21h
kube-system   deployment.apps/metrics-server                             2/2     2            2           26h
monitoring    deployment.apps/kube-prometheus-stack-grafana              1/1     1            1           20h
monitoring    deployment.apps/kube-prometheus-stack-kube-state-metrics   1/1     1            1           20h
monitoring    deployment.apps/kube-prometheus-stack-operator             1/1     1            1           20h

NAMESPACE     NAME                                                                  DESIRED   CURRENT   READY   AGE
flightdeck    replicaset.apps/flightdeck-flights-5df6f4848b                         0         0         0       15h
flightdeck    replicaset.apps/flightdeck-flights-6cd5fc8f54                         0         0         0       3h41m
flightdeck    replicaset.apps/flightdeck-flights-999bc5647                          2         2         2       15h
flightdeck    replicaset.apps/flightdeck-flights-dcdc9f9dd                          0         0         0       15h
flightdeck    replicaset.apps/flightdeck-gateway-5ddf74dd79                         0         0         0       3h41m
flightdeck    replicaset.apps/flightdeck-gateway-688575dcf                          0         0         0       21h
flightdeck    replicaset.apps/flightdeck-gateway-6b6dc84c57                         0         0         0       19h
flightdeck    replicaset.apps/flightdeck-gateway-7b84d447fc                         2         2         2       15h
flightdeck    replicaset.apps/flightdeck-notifier-567c86467                         0         0         0       21h
flightdeck    replicaset.apps/flightdeck-notifier-5948d4fddf                        0         0         0       19h
flightdeck    replicaset.apps/flightdeck-notifier-74dd944d46                        1         1         1       15h
flightdeck    replicaset.apps/flightdeck-notifier-9d6f99ddd                         0         0         0       3h41m
kube-system   replicaset.apps/aws-load-balancer-controller-65d5559bff               2         2         2       20h
kube-system   replicaset.apps/coredns-687dddfb64                                    2         2         2       26h
kube-system   replicaset.apps/ebs-csi-controller-699795c679                         2         2         2       21h
kube-system   replicaset.apps/metrics-server-54fc76cd9f                             2         2         2       26h
monitoring    replicaset.apps/kube-prometheus-stack-grafana-5bcb85d96b              0         0         0       20h
monitoring    replicaset.apps/kube-prometheus-stack-grafana-5c954854f5              1         1         1       19h
monitoring    replicaset.apps/kube-prometheus-stack-grafana-7576c4d57b              0         0         0       20h
monitoring    replicaset.apps/kube-prometheus-stack-kube-state-metrics-55bb9fff6c   1         1         1       20h
monitoring    replicaset.apps/kube-prometheus-stack-operator-978f5b6f9              1         1         1       20h

NAMESPACE    NAME                                                               READY   AGE
flightdeck   statefulset.apps/flightdeck-postgresql                             1/1     21h
flightdeck   statefulset.apps/flightdeck-redis-master                           1/1     21h
monitoring   statefulset.apps/alertmanager-kube-prometheus-stack-alertmanager   1/1     20h
monitoring   statefulset.apps/loki                                              1/1     19h
monitoring   statefulset.apps/prometheus-kube-prometheus-stack-prometheus       1/1     20h

NAMESPACE    NAME                                                     REFERENCE                       TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
flightdeck   horizontalpodautoscaler.autoscaling/flightdeck-gateway   Deployment/flightdeck-gateway   cpu: 2%/70%   2         5         2          21h
```

