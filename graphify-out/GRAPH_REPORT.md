# Graph Report - .  (2026-06-11)

## Corpus Check
- Corpus is ~40,263 words - fits in a single context window. You may not need a graph.

## Summary
- 298 nodes · 350 edges · 29 communities (23 shown, 6 thin omitted)
- Extraction: 82% EXTRACTED · 18% INFERRED · 0% AMBIGUOUS · INFERRED: 64 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Staging App Cloudflare Tunnels|Staging App Cloudflare Tunnels]]
- [[_COMMUNITY_Databases + L2 LB Services|Databases + L2 LB Services]]
- [[_COMMUNITY_Infrastructure Helm Controllers|Infrastructure Helm Controllers]]
- [[_COMMUNITY_Finance, Feed + Dashboard Apps|Finance, Feed + Dashboard Apps]]
- [[_COMMUNITY_Infrastructure Staging Overlays|Infrastructure Staging Overlays]]
- [[_COMMUNITY_Media Stack (Arr + VPN)|Media Stack (Arr + VPN)]]
- [[_COMMUNITY_Cluster Architecture Concepts|Cluster Architecture Concepts]]
- [[_COMMUNITY_Media Request + Streaming Apps|Media Request + Streaming Apps]]
- [[_COMMUNITY_Graphify + Dev Tooling|Graphify + Dev Tooling]]
- [[_COMMUNITY_Prometheus Monitoring Stack|Prometheus Monitoring Stack]]
- [[_COMMUNITY_FluxCD GitOps Bootstrap|FluxCD GitOps Bootstrap]]
- [[_COMMUNITY_Jellyfin Media Server|Jellyfin Media Server]]
- [[_COMMUNITY_Navidrome Music Server|Navidrome Music Server]]
- [[_COMMUNITY_Audiobookshelf App|Audiobookshelf App]]
- [[_COMMUNITY_Linkding Bookmarks|Linkding Bookmarks]]
- [[_COMMUNITY_n8n Automation Staging|n8n Automation Staging]]
- [[_COMMUNITY_Stremio Streaming|Stremio Streaming]]
- [[_COMMUNITY_Suwayomi Manga Reader|Suwayomi Manga Reader]]
- [[_COMMUNITY_Suwayomi + FlareSolverr|Suwayomi + FlareSolverr]]
- [[_COMMUNITY_Renovate Dependency Bot|Renovate Dependency Bot]]
- [[_COMMUNITY_Comet App|Comet App]]
- [[_COMMUNITY_n8n Staging Config|n8n Staging Config]]
- [[_COMMUNITY_Suwayomi Storage|Suwayomi Storage]]
- [[_COMMUNITY_SpotDL Staging|SpotDL Staging]]
- [[_COMMUNITY_Dev Container|Dev Container]]
- [[_COMMUNITY_Jellyfin Config Storage|Jellyfin Config Storage]]
- [[_COMMUNITY_Prowlarr Namespace|Prowlarr Namespace]]
- [[_COMMUNITY_qBittorrent Media PVC|qBittorrent Media PVC]]
- [[_COMMUNITY_Radarr Media PVC|Radarr Media PVC]]

## God Nodes (most connected - your core abstractions)
1. `Cloudflare Tunnel Pattern` - 15 edges
2. `Pineapple-Cluster README` - 14 edges
3. `Graphify Skill` - 10 edges
4. `qBittorrent Deployment` - 7 edges
5. `Apps Staging Root Kustomization` - 7 edges
6. `Tunnel Credentials Secret` - 7 edges
7. `Cilium LB IP Pool (pineapple-pool)` - 7 edges
8. `Controllers Staging Root Kustomization` - 7 edges
9. `Commafeed Deployment` - 6 edges
10. `Firefly III Deployment` - 6 edges

## Surprising Connections (you probably didn't know these)
- `Claude Code Settings (hooks)` --references--> `YAML Lint Configuration`  [INFERRED]
  .claude/settings.json → .yamllint.yaml
- `Renovate Bot Configuration` --implements--> `Renovate Dependency Automation`  [INFERRED]
  renovate.json → README.md
- `Renovate Staging Kustomization Overlay` --conceptually_related_to--> `kube-prometheus-stack Base Kustomization`  [INFERRED]
  infrastructure/controllers/staging/renovate/kustomization.yaml → monitoring/controllers/base/kube-prometheus-stack/kustomization.yaml
- `Comet Deployment` --references--> `Traefik Ingress Controller`  [INFERRED]
  apps/base/comet/deployment.yaml → README.md
- `Audiobookshelf Storage PVCs` --references--> `Longhorn Distributed Storage`  [EXTRACTED]
  apps/base/audiobookshelf/storage.yaml → README.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Audiobookshelf Application Manifests** — audiobookshelf_deployment, audiobookshelf_service, audiobookshelf_storage, audiobookshelf_configmap, audiobookshelf_namespace [EXTRACTED 1.00]
- **Graphify Full Build Pipeline Steps** — graphify_skill, references_extraction_spec, references_update, references_exports [EXTRACTED 1.00]
- **Pineapple Cluster Core Infrastructure** — readme_cilium, readme_traefik, readme_longhorn, readme_cloudnativepg, readme_cert_manager, readme_external_dns [EXTRACTED 1.00]
- **Longhorn-backed PVCs (commafeed, firefly-iii, homarr)** — commafeed_storage_commafeed_pvc, firefly_storage_firefly_upload_pvc, homarr_storage_homarr_appdata_pvc, concept_longhorn_storage [INFERRED 0.95]
- **Kustomize base pattern (namespace+deployment+service+storage+secrets)** — commafeed_kustomization_commafeed_app, firefly_kustomization_firefly_app, homarr_kustomization_homarr_app, jellyfin_kustomization_jellyfin_app [INFERRED 0.95]
- **Apps running as UID/GID 33 (www-data)** — commafeed_deployment_commafeed_deployment, firefly_deployment_firefly_deployment [INFERRED 0.85]
- **Shared media-pvc across Jellyfin, qBittorrent, and Radarr for hardlink-compatible media storage** — jellyfin_storage_media_pvc, qbittorrent_deployment_qbittorrent, radarr_deployment_radarr, shared_concept_media_pvc [EXTRACTED 1.00]
- **qBittorrent and Radarr both pinned to urial-lab node via nodeAffinity for co-located media-pvc access** — qbittorrent_deployment_qbittorrent, radarr_deployment_radarr, shared_concept_urial_lab_affinity [EXTRACTED 1.00]
- **Prowlarr + qBittorrent + Radarr form an automated media acquisition pipeline (arr stack)** — prowlarr_deployment_prowlarr, qbittorrent_deployment_qbittorrent, radarr_deployment_radarr, shared_concept_arr_stack [INFERRED 0.95]
- ***arr Media Automation Stack (Sonarr+Radarr+Seerr)** — sonarr_deployment_sonarr, radarr_service_radarr, seerr_deployment_seerr [INFERRED 0.85]
- **Sonarr pinned to urial-lab with shared media-pvc** — sonarr_deployment_sonarr, sonarr_deployment_urial_lab, sonarr_deployment_media_pvc [EXTRACTED 1.00]
- **Longhorn PVC Pattern across apps** — radarr_storage_radarr_config_pvc, sonarr_storage_sonarr_config_pvc, seerr_storage_seerr_config_pvc [EXTRACTED 1.00]
- **Cloudflare Tunnel Deployment Pattern** — concept_cloudflare_tunnel_pattern, concept_tunnel_credentials_secret, audiobookshelf_cloudflare_tunnel, commafeed_cloudflare_tunnel, firefly_iii_cloudflare_tunnel, homarr_cloudflare_tunnel, jellyfin_cloudflare_tunnel, linkding_cloudflare_tunnel, navidrome_cloudflare_tunnel, prowlarr_cloudflare_tunnel, comet_cloudflare_tunnel [INFERRED 0.95]
- **PostgreSQL-backed App Config Pattern** — commafeed_configmap_db, firefly_iii_configmap_db, commafeed_configmap_postgresql, firefly_iii_configmap_postgresql [INFERRED 0.85]
- **Staging Kustomize App Overlay Pattern** — staging_kustomization_root, audiobookshelf_kustomization_overlay, commafeed_kustomization_overlay, firefly_iii_kustomization_overlay, homarr_kustomization_overlay, jellyfin_kustomization_overlay, linkding_kustomization_overlay, navidrome_kustomization_overlay [EXTRACTED 1.00]
- **Arr-stack Apps in movietime Namespace** —  [INFERRED 0.95]
- **FluxCD Kustomizations using SOPS Decryption** —  [INFERRED 0.95]
- **Cloudflare Tunnel Deployments Across Staging Apps** —  [INFERRED 0.95]
- **CNPG Database Pattern: Cluster + LoadBalancer Service + External-DNS** —  [INFERRED 0.95]
- **Cilium LoadBalancer Network Stack: IP Pool + L2 Policy + Service Label** —  [INFERRED 0.90]
- **Databases Kustomize Tree: Root -> App Kustomizations -> Resources** —  [EXTRACTED 1.00]
- **Service Exposure Pattern: Cilium LB + ExternalDNS + FlareSolverr** — cilium_values_l2announcements, externaldns_release_helmrelease, flaresolverr_service_svc [INFERRED]
- **ExternalDNS Helm Deployment Flow** — externaldns_release_helmrelease, externaldns_repository_helmrepository, externaldns_values_cloudflare [INFERRED]
- **CloudNativePG Bootstrap Resources** — cloudnativepg_kustomization_base, cloudnativepg_namespace_cnpgsystem, cloudnativepg_release_helmrelease [INFERRED]
- **Renovate CronJob + ConfigMap + Secret runtime config** —  [EXTRACTED 1.00]
- **Spotdl CronJob reads playlist config and writes to music PVC** —  [EXTRACTED 1.00]
- **n8n exposed via cloudflared tunnel with staging configmap** —  [EXTRACTED 1.00]
- **kube-prometheus-stack deployment chain: repository -> release -> namespace** — monitoring_controllers_base_kps_repository, monitoring_controllers_base_kps_release, monitoring_controllers_base_kps_namespace [INFERRED]
- **Monitoring staging overlay: controllers staging kustomization -> kps staging overlay -> kps base** — monitoring_controllers_staging_kustomization, monitoring_controllers_staging_kps_kustomization, monitoring_controllers_base_kps_kustomization [INFERRED]
- **Grafana TLS ingress: release -> ingress concept -> tls secret** — monitoring_controllers_base_kps_release, monitoring_grafana_ingress, monitoring_grafana_tls_secret [INFERRED]

## Communities (29 total, 6 thin omitted)

### Community 0 - "Staging App Cloudflare Tunnels"
Cohesion: 0.06
Nodes (47): audiobooks.amdhql.org Hostname, Audiobookshelf Cloudflare Tunnel, Audiobookshelf Staging Kustomization, comet.amdhql.org Hostname, Comet Cloudflare Tunnel, Comet Staging Kustomization, commafeed.amdhql.org Hostname, Commafeed Cloudflare Tunnel (+39 more)

### Community 1 - "Databases + L2 LB Services"
Cohesion: 0.11
Nodes (27): Cilium LB IP Pool (pineapple-pool), Cilium Configs Staging Kustomization, Cilium L2 Announcement Policy (pineapple-policy), Commafeed CNPG Cluster, Commafeed Database Kustomization, Commafeed DB LoadBalancer Service, Cilium LoadBalancer IP Pool Concept, CloudNativePG PostgreSQL Cluster Pattern (+19 more)

### Community 2 - "Infrastructure Helm Controllers"
Cohesion: 0.10
Nodes (25): Cilium Kustomize ConfigMap Name Reference, Cilium HelmRelease, Cilium HelmRepository, Cilium Helm Values (ConfigMap), Cilium Hubble Observability, Cilium IPAM Kubernetes Mode, Cilium kube-proxy Replacement, Cilium L2 Announcements (+17 more)

### Community 3 - "Finance, Feed + Dashboard Apps"
Cohesion: 0.11
Nodes (24): commafeed-configmap ConfigMap, Commafeed Deployment, athou/commafeed:latest-postgresql, commafeed-container-env Secret, Commafeed App Kustomization, Commafeed Namespace, Commafeed Service (port 8082), Commafeed Data PVC (256Mi, longhorn) (+16 more)

### Community 4 - "Infrastructure Staging Overlays"
Cohesion: 0.13
Nodes (20): Cilium Staging Kustomization, CloudNativePG Staging Kustomization, External-DNS Staging Kustomization, Flaresolverr Staging ConfigMap, Flaresolverr Staging Kustomization, Renovate ConfigMap, Renovate Container Env Secret (SOPS), Renovate CronJob (+12 more)

### Community 5 - "Media Stack (Arr + VPN)"
Cohesion: 0.13
Nodes (19): Media PVC (Jellyfin), Prowlarr Deployment, Prowlarr Kustomization, Prowlarr Service, Prowlarr Config PVC, Gluetun VPN Sidecar Container, Gluetun VPN Credentials Secret, qBittorrent Init Container (init-dirs) (+11 more)

### Community 6 - "Cluster Architecture Concepts"
Cohesion: 0.15
Nodes (17): Comet Deployment, cert-manager TLS Certificates, Cilium CNI, CloudNativePG PostgreSQL Operator, external-dns Cloudflare Sync, FluxCD GitOps Engine, Grafana Dashboard, hippo-lab Control Plane Node (+9 more)

### Community 7 - "Media Request + Streaming Apps"
Cohesion: 0.15
Nodes (15): Radarr Namespace, Radarr Service (ClusterIP:7878), Radarr Config PVC (2Gi Longhorn), Seerr Deployment, Seerr Kustomization, Seerr Namespace, Seerr Service (ClusterIP:5055), Seerr Config PVC (1Gi Longhorn) (+7 more)

### Community 8 - "Graphify + Dev Tooling"
Cohesion: 0.17
Nodes (13): Claude Code Settings (hooks), Claude Code Local Permissions, Graphify Knowledge Graph Build Pipeline, Graphify Skill, Graphify Add URL and Watch Reference, Graphify Extra Exports Reference, Graphify Extraction Subagent Prompt Spec, Graphify GitHub Clone and Cross-Repo Merge Reference (+5 more)

### Community 9 - "Prometheus Monitoring Stack"
Cohesion: 0.18
Nodes (13): Monitoring Configs Staging kube-prometheus-stack Kustomization, Monitoring Configs Staging Kustomization, kube-prometheus-stack Base Kustomization, Monitoring Namespace, kube-prometheus-stack HelmRelease, kube-prometheus-stack HelmRepository, kube-prometheus-stack Staging Kustomization Overlay, Monitoring Controllers Staging Kustomization (+5 more)

### Community 10 - "FluxCD GitOps Bootstrap"
Cohesion: 0.27
Nodes (10): FluxCD GitOps Reconciliation, Infrastructure-Configs DependsOn Infrastructure-Controllers, SOPS + Age Secret Encryption, FluxCD GitRepository and Sync Kustomization, Flux-System Kustomize Entry Point, FluxCD Apps Kustomization, FluxCD Databases Kustomization, FluxCD Infrastructure Kustomizations (+2 more)

### Community 11 - "Jellyfin Media Server"
Cohesion: 0.25
Nodes (8): jellyfin-config-pvc PVC, Jellyfin Deployment, jellyfin/jellyfin:latest, Jellyfin Node Affinity (urial-lab), media-pvc Shared PVC, Jellyfin App Kustomization, Jellyfin Namespace, Jellyfin Service (port 8096)

### Community 12 - "Navidrome Music Server"
Cohesion: 0.33
Nodes (7): Navidrome Deployment, Navidrome Kustomization, Navidrome Namespace, Navidrome Service, Navidrome Data PVC, Navidrome Music PVC, SpotDL Config PVC

### Community 13 - "Audiobookshelf App"
Cohesion: 0.53
Nodes (6): Audiobookshelf ConfigMap, Audiobookshelf Deployment, Audiobookshelf Kustomization, Audiobookshelf Namespace, Audiobookshelf Service, Audiobookshelf Storage PVCs

### Community 14 - "Linkding Bookmarks"
Cohesion: 0.47
Nodes (6): Linkding Deployment, Linkding Container Env Secret, Linkding Kustomization, Linkding Namespace, Linkding Service, Linkding Data PVC

### Community 15 - "n8n Automation Staging"
Cohesion: 0.33
Nodes (6): Cloudflared ConfigMap (n8n staging), Cloudflared Deployment (n8n staging), Cloudflare Tunnel: automation, n8n Staging ConfigMap, n8n PostgreSQL Database (n8n-db.amdhql.org), n8n Data PVC

### Community 16 - "Stremio Streaming"
Cohesion: 0.53
Nodes (6): Stremio Deployment, stremio-auth Secret, Stremio Kustomization, Stremio Namespace, Stremio Service (port:8080), Stremio Data PVC (1Gi Longhorn)

### Community 17 - "Suwayomi Manga Reader"
Cohesion: 0.50
Nodes (5): Suwayomi Deployment, suwayomi-configmap ConfigMap, Suwayomi Kustomization, Suwayomi Namespace, Suwayomi Service (ClusterIP:4567)

### Community 18 - "Suwayomi + FlareSolverr"
Cohesion: 0.50
Nodes (4): FlareSolverr Integration for Suwayomi, Suwayomi Cloudflare Tunnel Deployment, Suwayomi ConfigMap (Staging), Suwayomi Staging Kustomization Overlay

### Community 19 - "Renovate Dependency Bot"
Cohesion: 0.50
Nodes (3): kubernetes, fileMatch, $schema

### Community 20 - "Comet App"
Cohesion: 0.67
Nodes (3): Comet App Kustomization, Comet Namespace, Comet Service (port 8000)

### Community 21 - "n8n Staging Config"
Cohesion: 0.67
Nodes (3): n8n Cloudflare Config, n8n Cloudflare Secret, n8n Staging Kustomization Overlay

### Community 22 - "Suwayomi Storage"
Cohesion: 0.67
Nodes (3): Suwayomi Downloads PVC, Suwayomi Files PVC, Longhorn Storage Class

## Knowledge Gaps
- **117 isolated node(s):** `$schema`, `fileMatch`, `Claude Code Local Permissions`, `Dev Container Configuration`, `Renovate Bot Configuration` (+112 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **6 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Cloudflare Tunnel Pattern` connect `Staging App Cloudflare Tunnels` to `Suwayomi + FlareSolverr`?**
  _High betweenness centrality (0.020) - this node is a cross-community bridge._
- **Why does `Commafeed Database Kustomization` connect `Databases + L2 LB Services` to `Finance, Feed + Dashboard Apps`?**
  _High betweenness centrality (0.017) - this node is a cross-community bridge._
- **Are the 15 inferred relationships involving `Cloudflare Tunnel Pattern` (e.g. with `Audiobookshelf Cloudflare Tunnel` and `Comet Cloudflare Tunnel`) actually correct?**
  _`Cloudflare Tunnel Pattern` has 15 INFERRED edges - model-reasoned connections that need verification._
- **What connects `$schema`, `fileMatch`, `Claude Code Local Permissions` to the rest of the system?**
  _117 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Staging App Cloudflare Tunnels` be split into smaller, more focused modules?**
  _Cohesion score 0.058279370952821465 - nodes in this community are weakly interconnected._
- **Should `Databases + L2 LB Services` be split into smaller, more focused modules?**
  _Cohesion score 0.11396011396011396 - nodes in this community are weakly interconnected._
- **Should `Infrastructure Helm Controllers` be split into smaller, more focused modules?**
  _Cohesion score 0.09666666666666666 - nodes in this community are weakly interconnected._