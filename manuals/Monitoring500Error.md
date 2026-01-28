DevOps Project: Monitoring and Alerting System
Technologies: Spring Boot + Prometheus + Alertmanager + ArgoCD + Helm
Environment: Azure Kubernetes Service (AKS) in GitOps model

The system detects HTTP 500 errors in the Spring Boot application and automatically sends alerts to the Gmail address: adrian.dmytryk@gmail.com.

Key Components

Application
Spring Boot with Actuator enabled - exposes Prometheus metrics via /actuator/prometheus.

Monitoring
Prometheus (metrics collection) + Alertmanager (notification management).

Orchestration
ArgoCD (GitOps) + Helm (configuration and version management).

Instructions after deploying new infrastructure

If you are configuring the infrastructure from scratch, perform the following steps:

1. Synchronization and configuration cache clearing
- Create the alertmanager-gmail Secret in the monitoring namespace.
- Perform synchronization with the Replace option in ArgoCD.
- Restart Prometheus:
kubectl rollout restart deployment prometheus-server -n monitoring

2. Exposing services (Port-Forwarding)
Run in separate terminals:

- Application:
kubectl -n environment-dev port-forward svc/devops-project 8080:80
-> localhost:8080

- Prometheus:
kubectl -n monitoring port-forward svc/prometheus-server 9090:80
-> localhost:9090

- Alertmanager:
kubectl -n monitoring port-forward svc/alertmanager 9093:9093
-> localhost:9093

3. Error generation (Load test)
Run the loop:
while true; do
curl -s http://localhost:8080/api/error500 > /dev/null
echo "Error request sent: $(date)"
sleep 2
done

Checklist: Verification of correct operation

Application metrics
-> http://localhost:8080/actuator/prometheus
-> Search for: http_server_requests_seconds_count{status="500",...} - the counter must increase.

Prometheus -> Alertmanager connection
-> http://localhost:9090/status
-> Alertmanagers section: http://alertmanager:9093/...
If you see an IP (e.g. 10.0.x.x) - restart Prometheus!

Alert status
-> http://localhost:9090/alerts
-> Alert DevopsProjectHttp500 = Firing (red)

Email sending logs
kubectl logs alertmanager-0 -n monitoring --tail=20
Search: component=dispatcher msg="Notify success" receiver=gmail

Gmail: adrian.dmytryk@gmail.com
Check Inbox and SPAM.
