(
GCP Infrastructure Reproduction Prompt
Prompt for AI agents (Claude Code, OpenCode, etc.): Execute the steps below using
the gcloud CLI to reproduce this infrastructure exactly. Do not create scripts —
run each gcloud command directly. Authenticate with the service-account key file
gcp_sa.json located in the working directory. Run steps in order; later steps depend
on earlier ones. Verify each command succeeds before continuing.
Target state
Resource	Name	Key properties
VPC	gsa-vpc	custom subnet mode
Subnet	gsa-subnet-1	10.0.1.0/24, us-central1, Private Google Access ON
Service account	vm-sa-01	role roles/storage.admin on the project
GCS bucket	gsa-bucket-1725	us-central1
VM	gsa-vm	us-central1-a, e2-standard-2, on gsa-subnet-1, vm-sa-01 attached, SSH open from 0.0.0.0/0
Filestore	gsa-file-store	Basic HDD, zonal (us-central1-a), 1 TiB, on gsa-vpc, mounted on gsa-vm at /mnt/gsa-file-store (fstab, rw)
Cloud SQL	gsa-sql-instance	POSTGRES_18, Enterprise edition, db-custom-2-8192, HDD 10 GB, zonal, us-central1, private IP on gsa-vpc + public IP authorized for 109.75.34.101/32
SQL database	gsa-database	charset UTF8, collation en_US.UTF8
Redis	gsa-redis	Memorystore for Redis, Basic tier, 1 GB, redis_7_2, on gsa-vpc
Custom image	gsa-image	debian-12 + nginx, postgresql-client, redis-tools, nfs-common
Instance template	gsa-mig-template	e2-standard-2, gsa-subnet-1, startup script (nginx page with VM IP + NFS mount at /mnt/nfs)
MIG & Autoscaler	gsa-mig	regional us-central1, min size 2, max size 5, autoscaling on 80% average CPU, named port http:80
ALB	gsa-alb (URL map) + gsa-alb-proxy + gsa-target-pool (backend service) + gsa-hc (health check)	global external Application LB
Forwarding rule	gsa-forwarding-rule	global, port 80
Step 0 — Authenticate
gcloud auth activate-service-account --key-file=gcp_sa.json
gcloud config set project picsartacademy

Step 1 — VPC and subnet
gcloud compute networks create gsa-vpc --subnet-mode=custom

gcloud compute networks subnets create gsa-subnet-1 \
  --network=gsa-vpc \
  --region=us-central1 \
  --range=10.0.1.0/24 \
  --enable-private-ip-google-access

Step 2 — Service account, IAM role, GCS bucket
gcloud iam service-accounts create vm-sa-01 --display-name="vm-sa-01"
# NOTE: if this fails with "already exists", that is fine — continue.

gcloud projects add-iam-policy-binding picsartacademy \
  --member="serviceAccount:vm-sa-01@picsartacademy.iam.gserviceaccount.com" \
  --role="roles/storage.admin" \
  --condition=None

gcloud storage buckets create gs://gsa-bucket-1725 --location=us-central1

Step 3 — VM with service account attached + SSH firewall rule
gcloud compute instances create gsa-vm \
  --zone=us-central1-a \
  --machine-type=e2-standard-2 \
  --subnet=gsa-subnet-1 \
  --service-account=vm-sa-01@picsartacademy.iam.gserviceaccount.com \
  --scopes=cloud-platform \
  --tags=gsa-vm-ssh

gcloud compute firewall-rules create gsa-allow-ssh \
  --network=gsa-vpc \
  --allow=tcp:22 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=gsa-vm-ssh

Step 4 — Filestore (Basic HDD, zonal)
Basic HDD with a standard file share requires a 1 TiB minimum capacity
(100 GiB only applies to GKE-enabled tiers). Creation takes several minutes.
gcloud filestore instances create gsa-file-store \
  --zone=us-central1-a \
  --tier=BASIC_HDD \
  --file-share=name=gsa_share,capacity=1TiB \
  --network=name=gsa-vpc

Get the Filestore IP (needed for the mount step):
gcloud filestore instances describe gsa-file-store --zone=us-central1-a \
  --format="value(networks[0].ipAddresses[0],fileShares[0].name)"

Step 5 — Mount Filestore on gsa-vm (with fstab auto-mount)
Replace FILESTORE_IP with the IP from Step 4 (the share name is gsa_share):
gcloud compute ssh gsa-vm --zone=us-central1-a --command="\
  sudo apt-get update -qq && \
  sudo apt-get install -y -qq nfs-common && \
  sudo mkdir -p /mnt/gsa-file-store && \
  sudo mount -t nfs FILESTORE_IP:/gsa_share /mnt/gsa-file-store && \
  echo 'FILESTORE_IP:/gsa_share /mnt/gsa-file-store nfs defaults,_netdev 0 0' | sudo tee -a /etc/fstab && \
  sudo chmod 777 /mnt/gsa-file-store && \
  df -h /mnt/gsa-file-store"

Verify the df -h output shows the share mounted at /mnt/gsa-file-store.
Step 6 — Private Services Access (required for Cloud SQL & Redis)
gcloud compute addresses create google-managed-services-gsa-vpc \
  --global \
  --purpose=VPC_PEERING \
  --prefix-length=16 \
  --network=gsa-vpc

gcloud services vpc-peerings connect \
  --service=servicenetworking.googleapis.com \
  --ranges=google-managed-services-gsa-vpc \
  --network=gsa-vpc

Step 7 — Cloud SQL instance + database
GOTCHA: POSTGRES_18 defaults to the Enterprise Plus edition, which rejects
db-custom-* tiers and HDD storage. You MUST pass --edition=enterprise.
gcloud sql instances create gsa-sql-instance \
  --database-version=POSTGRES_18 \
  --edition=enterprise \
  --tier=db-custom-2-8192 \
  --region=us-central1 \
  --storage-type=HDD \
  --storage-size=10GB \
  --availability-type=zonal \
  --network=projects/picsartacademy/global/networks/gsa-vpc \
  --assign-ip \
  --authorized-networks=109.75.34.101/32 \
  --root-password='jJnCh:)RJ`yL<2U,'

The password contains shell-special characters (`, (, ), <, ,) —
keep it wrapped in single quotes.
gcloud sql databases create gsa-database \
  --instance=gsa-sql-instance \
  --charset=UTF8 \
  --collation=en_US.UTF8

Step 8 — Cloud Memorystore (Redis)
gcloud redis instances create gsa-redis \
  --region=us-central1 \
  --network=projects/picsartacademy/global/networks/gsa-vpc \
  --tier=basic \
  --size=1 \
  --redis-version=redis_7_2

Step 9 — PostgreSQL & Redis clients on gsa-vm
gcloud compute ssh gsa-vm --zone=us-central1-a \
  --command="sudo apt-get install -y -qq postgresql-client redis-tools && psql --version && redis-cli -v"

Debian 12 ships psql v15; it connects to the Postgres 18 server fine. Install
postgresql-client-18 from the PGDG apt repo if an exact version match is needed.
Step 10 — Custom image gsa-image (debian-12 + nginx + db clients)
Build via a temporary VM (GCP has no direct "install packages into image" command):
gcloud compute instances create gsa-image-builder \
  --zone=us-central1-a \
  --machine-type=e2-medium \
  --subnet=gsa-subnet-1 \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --tags=gsa-vm-ssh

Wait ~20s for boot, then install packages:
NOTE: nfs-common is added beyond the spec because the
MIG startup script in Step 11 must mount the Filestore NFS share.
gcloud compute ssh gsa-image-builder --zone=us-central1-a \
  --command="sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx postgresql-client redis-tools nfs-common && /usr/sbin/nginx -v && psql --version && redis-cli -v"

Stop the VM, create the image, delete the builder:
gcloud compute instances stop gsa-image-builder --zone=us-central1-a
gcloud compute images create gsa-image --source-disk=gsa-image-builder --source-disk-zone=us-central1-a
gcloud compute instances delete gsa-image-builder --zone=us-central1-a --quiet

Step 11 — Instance template + managed instance group (MIG) + Autoscaling
The startup script writes an HTML page containing the VM's IP into nginx's default
directory and mounts the Filestore at /mnt/nfs. Replace FILESTORE_IP with the IP
from Step 4.
GOTCHA: keep the startup script free of commas — gcloud's --metadata parser
splits on commas. Multiline values inside quotes are fine.
gcloud compute instance-templates create gsa-mig-template \
  --machine-type=e2-standard-2 \
  --image=gsa-image \
  --region=us-central1 \
  --network=gsa-vpc \
  --subnet=gsa-subnet-1 \
  --tags=gsa-vm-ssh,gsa-http \
  --metadata=startup-script='#!/bin/bash
IP=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
echo "<html><body><h1>VM IP: $IP</h1></body></html>" > /var/www/html/index.html
mkdir -p /mnt/nfs
mount -t nfs FILESTORE_IP:/gsa_share /mnt/nfs
systemctl restart nginx'

Create the MIG with a minimum of 2 instances:
gcloud compute instance-groups managed create gsa-mig \
  --region=us-central1 \
  --template=gsa-mig-template \
  --size=2

Configure named ports for HTTP routing:
gcloud compute instance-groups managed set-named-ports gsa-mig \
  --region=us-central1 \
  --named-ports=http:80

Configure autoscaling based on 80% average CPU utilization:
gcloud compute instance-groups managed set-autoscaling gsa-mig \
  --region=us-central1 \
  --max-num-replicas=5 \
  --min-num-replicas=2 \
  --target-cpu-utilization=0.8 \
  --mode=on

Step 12 — Firewall for load balancer health checks / proxies
gcloud compute firewall-rules create gsa-allow-lb-hc \
  --network=gsa-vpc \
  --allow=tcp:80 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=gsa-http

Step 13 — Application load balancer gsa-alb (port 80)
NOTE: "target pools" are a legacy Network LB concept and do not exist in
Application LBs. The functional equivalent is a backend service, so the backend
service is named gsa-target-pool to honor the requested name.
gcloud compute health-checks create http gsa-hc --port=80 --check-interval=10s --timeout=5s

gcloud compute backend-services create gsa-target-pool \
  --protocol=HTTP \
  --port-name=http \
  --health-checks=gsa-hc \
  --global \
  --load-balancing-scheme=EXTERNAL_MANAGED

gcloud compute backend-services add-backend gsa-target-pool \
  --instance-group=gsa-mig \
  --instance-group-region=us-central1 \
  --global

gcloud compute url-maps create gsa-alb --default-service=gsa-target-pool

gcloud compute target-http-proxies create gsa-alb-proxy --url-map=gsa-alb

gcloud compute forwarding-rules create gsa-forwarding-rule \
  --global \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --target-http-proxy=gsa-alb-proxy \
  --ports=80

Get the LB IP and wait for it to start serving (frontend programming takes 1–3 min
after backends turn HEALTHY):
gcloud compute forwarding-rules describe gsa-forwarding-rule --global --format="value(IPAddress)"
gcloud compute backend-services get-health gsa-target-pool --global

Then verify round-robin across both instances (expect both backend IPs to appear):
for i in $(seq 1 8); do curl -s --max-time 5 http://LB_IP/ | grep -o "10\.0\.1\.[0-9]*"; done | sort | uniq -c

Final verification
gcloud compute networks subnets describe gsa-subnet-1 --region=us-central1 --format="value(ipCidrRange,privateIpGoogleAccess)"
gcloud storage buckets describe gs://gsa-bucket-1725 --format="value(location)"
gcloud compute instances describe gsa-vm --zone=us-central1-a --format="value(serviceAccounts[0].email,status)"
gcloud filestore instances describe gsa-file-store --zone=us-central1-a --format="value(state)"
gcloud sql instances describe gsa-sql-instance --format="value(state,ipAddresses[].ipAddress)"
gcloud sql databases list --instance=gsa-sql-instance
gcloud redis instances describe gsa-redis --region=us-central1 --format="value(state,host,port)"
gcloud compute ssh gsa-vm --zone=us-central1-a --command="df -h /mnt/gsa-file-store && grep gsa-file-store /etc/fstab && psql --version && redis-cli -v"
gcloud compute images describe gsa-image --format="value(status)"
gcloud compute instance-groups managed list-instances gsa-mig --region=us-central1
gcloud compute instance-groups managed describe gsa-mig --region=us-central1 --format="value(autoscaler.name)"
gcloud compute backend-services get-health gsa-target-pool --global --format="value(status.healthStatus[].healthState)"
curl -s http://$(gcloud compute forwarding-rules describe gsa-forwarding-rule --global --format="value(IPAddress)")/

Teardown order (for a destroy flow)
1. gcloud compute forwarding-rules delete gsa-forwarding-rule --global --quiet
2. gcloud compute target-http-proxies delete gsa-alb-proxy --quiet
3. gcloud compute url-maps delete gsa-alb --quiet
4. gcloud compute backend-services delete gsa-target-pool --global --quiet
5. gcloud compute health-checks delete gsa-hc --quiet
6. gcloud compute instance-groups managed delete gsa-mig --region=us-central1 --quiet
7. gcloud compute instance-templates delete gsa-mig-template --quiet
8. gcloud compute images delete gsa-image --quiet
9. gcloud redis instances delete gsa-redis --region=us-central1 --quiet
10. gcloud sql instances delete gsa-sql-instance --quiet
11. gcloud filestore instances delete gsa-file-store --zone=us-central1-a --quiet
12. gcloud compute instances delete gsa-vm --zone=us-central1-a --quiet
13. gcloud storage buckets delete gs://gsa-bucket-1725 --quiet
14. gcloud iam service-accounts delete vm-sa-01@picsartacademy.iam.gserviceaccount.com --quiet
15. gcloud services vpc-peerings delete --service=servicenetworking.googleapis.com --network=gsa-vpc --quiet
16. gcloud compute addresses delete google-managed-services-gsa-vpc --global --quiet
17. gcloud compute networks subnets delete gsa-subnet-1 --region=us-central1 --quiet
18. gcloud compute firewall-rules delete gsa-allow-ssh gsa-allow-lb-hc --quiet
19. gcloud compute networks delete gsa-vpc --quiet )