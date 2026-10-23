{{/*
Expand the name of the chart.
*/}}
{{- define "capy-cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "capy-cluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "capy-cluster.labels" -}}
helm.sh/chart: {{ include "capy-cluster.chart" . }}
{{ include "capy-cluster.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "capy-cluster.selectorLabels" -}}
app.kubernetes.io/name: {{ include "capy-cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
YandexIdentity name — defaults to Release.Name if capy.identityName is empty.
*/}}
{{- define "capy-cluster.identityName" -}}
{{- default .Release.Name .Values.capy.identityName }}
{{- end }}

{{/*
Credentials Secret name for Yandex SA key.
Defaults to <identityName>-sa-key unless capy.credentialsSecretName is set.
*/}}
{{- define "capy-cluster.credentialsSecretName" -}}
{{- if .Values.capy.credentialsSecretName -}}
{{- .Values.capy.credentialsSecretName -}}
{{- else -}}
{{- printf "%s-sa-key" (include "capy-cluster.identityName" .) -}}
{{- end -}}
{{- end }}

{{/*
Key name inside the credentials Secret (default YandexCloudSAKey).
*/}}
{{- define "capy-cluster.credentialsKeyName" -}}
{{- .Values.capy.credentialsKeyName | default "YandexCloudSAKey" -}}
{{- end }}

{{/*
Resolve Yandex SA authorized key JSON content.
Priority: capy.saKeyFile (.Files.Get) → capy.saKey (string or map).
Fails if value looks like a file path instead of JSON.
Returns empty string when neither is set (Secret template is skipped).
*/}}
{{- define "capy-cluster.saKey" -}}
{{- $saKey := "" -}}
{{- if .Values.capy.saKeyFile -}}
{{- $saKey = .Files.Get .Values.capy.saKeyFile -}}
{{- $_ := required (printf "capy.saKeyFile %q not found in chart" .Values.capy.saKeyFile) $saKey -}}
{{- else if .Values.capy.saKey -}}
{{- if kindIs "map" .Values.capy.saKey -}}
{{- $saKey = .Values.capy.saKey | toJson -}}
{{- else -}}
{{- $saKey = .Values.capy.saKey | toString -}}
{{- end -}}
{{- end -}}
{{- if $saKey -}}
{{- $trimmed := $saKey | trim -}}
{{- if and (not (hasPrefix "{" $trimmed)) (not (hasPrefix "[" $trimmed)) -}}
{{- fail (printf "capy.saKey does not look like JSON (starts with %q). If you meant a chart file, set capy.saKeyFile: conf/sa.json instead of capy.saKey." ($trimmed | trunc 20)) -}}
{{- end -}}
{{- $saKey -}}
{{- end -}}
{{- end }}

{{/*
Read the ClusterConfig secret value
*/}}
{{- define "capy-cluster.clusterConfig" -}}
{{- tpl (.Files.Get .Values.clusterConfigFile) . | b64enc | quote }}
{{- end }}

{{/*
etcd external CA cert
*/}}
{{- define "capy-cluster.etcd.caCrt" -}}
{{- if .Values.etcd.external.caCrt }}
{{- .Files.Get .Values.etcd.external.caCrt | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
etcd external client cert
*/}}
{{- define "capy-cluster.etcd.apiCrt" -}}
{{- if .Values.etcd.external.apiCrt }}
{{- .Files.Get .Values.etcd.external.apiCrt | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
etcd external client key
*/}}
{{- define "capy-cluster.etcd.apiKey" -}}
{{- if .Values.etcd.external.apiKey }}
{{- .Files.Get .Values.etcd.external.apiKey | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
Raw encryption key material (32 chars). Same contract as backend/cluster-manager/capsm:
  Secret.data["secret"] (after decode) == raw key
  EncryptionConfiguration aescbc.keys[].secret == base64(raw key)

Cached in Values._encryptionKey for one helm render so Secret and NCI always match.
*/}}
{{- define "capy-cluster.encryptionKeyMaterial" -}}
{{- if not .Values._encryptionKey -}}
{{- $key := "" -}}
{{- $secretName := printf "%s-encryption-configuration" .Release.Name -}}
{{- $existing := lookup "v1" "Secret" .Release.Name $secretName -}}
{{- if and $existing $existing.data $existing.data.secret -}}
{{- /* Helm lookup returns API base64 form; decode to raw key */ -}}
{{- $key = index $existing.data "secret" | b64dec -}}
{{- else -}}
{{- /* Deterministic 32-char material unique per release (AES-CBC key length) */ -}}
{{- $key = sha256sum (printf "%s-encryption-key" .Release.Name) | trunc 32 -}}
{{- end -}}
{{- $_ := set .Values "_encryptionKey" $key -}}
{{- end -}}
{{- .Values._encryptionKey -}}
{{- end -}}

{{/*
Backward-compatible alias: raw key material (NOT base64).
*/}}
{{- define "capy-cluster.encryptionKey" -}}
{{- include "capy-cluster.encryptionKeyMaterial" . -}}
{{- end -}}

{{/*
Content of /etc/kubernetes/secrets_encryption.yaml — format matches cluster-manager
pkg/nodeconfig/generator/security.go encryptionConfiguration().
*/}}
{{- define "capy-cluster.secretsEncryptionContent" -}}
---
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
    - secrets
    providers:
    - aescbc:
        keys:
          - name: key1
            secret: {{ include "capy-cluster.encryptionKeyMaterial" . | b64enc }}
    - identity: {}
{{- end -}}

{{/*
Generate nci.json (ShturvalInit) as base64-encoded JSON.
Usage: include "capy-cluster.nci.json.b64" (dict "ctx" . "controlplane" true)
  controlplane=true  — adds secrets_encryption, audit_policy, etcd certs
  controlplane=false — directories and system config only (workers)
*/}}
{{- define "capy-cluster.nci.json.b64" -}}
{{- $ctx := .ctx -}}
{{- $nciCtx := dict
  "Values"       $ctx.Values
  "Files"        $ctx.Files
  "Release"      $ctx.Release
  "Chart"        $ctx.Chart
  "controlplane" .controlplane
-}}
{{- tpl ($ctx.Files.Get "conf/nci.yaml") $nciCtx | fromYaml | toJson | b64enc -}}
{{- end }}

{{/*
Generate monitoringid
*/}}
{{- define "capy-cluster.monitoringid" -}}
{{ adler32sum .Release.Name | int }}
{{- end }}

{{/*
Minimal KubeletConfiguration YAML — base64-encoded for injection via preKubeadmCommands.
*/}}
{{- define "capy-cluster.kubelet.b64" -}}
{{- $cfg := `---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
protectKernelDefaults: true
` -}}
{{- $cfg | b64enc }}
{{- end }}

{{/*
Node role label suffix for a worker group.
*/}}
{{- define "capy-cluster.nodeRole" -}}
{{- if eq . "default" -}}workers{{- else -}}{{ . }}{{- end -}}
{{- end -}}

{{/*
Filename for a kubeadm patch in kubeadmPatches.directory.
patch.filename, otherwise kubeapi → kube-apiserver.yaml, otherwise <name>.yaml.
*/}}
{{- define "capy-cluster.kubeadmPatchFilename" -}}
{{- $name := .name -}}
{{- $patch := .patch | default dict -}}
{{- if $patch.filename -}}
{{- $patch.filename -}}
{{- else if eq $name "kubeapi" -}}
kube-apiserver.yaml
{{- else -}}
{{- printf "%s.yaml" $name -}}
{{- end -}}
{{- end -}}

{{/*
Convert worker group labels (list of "key=value" or "key=") to YAML label lines.
Skips node-role.kubernetes.io/* — that role is set separately via nodeRole helper.
*/}}
{{- define "capy-cluster.nodeLabelsFromValues" -}}
{{- $labels := .labels | default list -}}
{{- if kindIs "map" $labels -}}
{{- range $k, $v := $labels }}
{{- if not (hasPrefix "node-role.kubernetes.io/" $k) }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end }}
{{- else }}
{{- range $labels }}
{{- $pair := splitList "=" . }}
{{- $key := index $pair 0 }}
{{- if and $key (not (hasPrefix "node-role.kubernetes.io/" $key)) }}
{{- $val := "" }}
{{- if gt (len $pair) 1 }}{{ $val = index $pair 1 }}{{ end }}
{{ $key }}: {{ $val | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
kube-apiserver extra args.
Audit/encryption args only when secure=true.
*/}}
{{- define "capy-cluster.apiserver" -}}
extraArgs:
{{- if .Values.secure }}
- name: audit-log-maxage
  value: "30"
- name: audit-log-maxbackup
  value: "10"
- name: audit-log-maxsize
  value: "100"
- name: audit-log-mode
  value: batch
- name: audit-log-path
  value: /var/log/kube-api-audit/audit.log
- name: audit-policy-file
  value: "{{ .Values.auditPolicy.location }}"
- name: encryption-provider-config
  value: /etc/kubernetes/secrets_encryption.yaml
{{- end }}
- name: authorization-mode
  value: Node,RBAC
- name: default-not-ready-toleration-seconds
  value: "30"
- name: default-unreachable-toleration-seconds
  value: "30"
- name: kubelet-certificate-authority
  value: /etc/kubernetes/pki/ca.crt
- name: profiling
  value: "false"
- name: request-timeout
  value: 60s
- name: tls-min-version
  value: VersionTLS13
{{- end }}

{{/*
kube-controller-manager extra args
*/}}
{{- define "capy-cluster.controllerManager" -}}
controllerManager:
  extraArgs:
  - name: bind-address
    value: 0.0.0.0
  - name: node-monitor-grace-period
    value: 20s
  - name: node-monitor-period
    value: 2s
  - name: profiling
    value: "false"
  - name: terminated-pod-gc-threshold
    value: "10"
  - name: tls-min-version
    value: VersionTLS13
{{- end }}

{{/*
kube-scheduler extra args
*/}}
{{- define "capy-cluster.scheduler" -}}
scheduler:
  extraArgs:
  - name: bind-address
    value: 0.0.0.0
  - name: profiling
    value: "false"
{{- end }}

{{/*
Resolve default Yandex Compute image ID from capy.kubeTemplates by kubeVersion.
Fallback: capy.imageID.
*/}}
{{- define "capy-cluster.defaultImageID" -}}
{{- $kubeVersion := .Values.kubeVersion | toString | trim -}}
{{- $normalizedVersion := ternary $kubeVersion (printf "v%s" $kubeVersion) (hasPrefix "v" $kubeVersion) -}}
{{- $templates := .Values.capy.kubeTemplates | default dict -}}
{{- $imageID := get $templates $normalizedVersion -}}
{{- if not $imageID -}}
{{- $imageID = get $templates (trimPrefix "v" $normalizedVersion) -}}
{{- end -}}
{{- if not $imageID -}}
{{- $imageID = .Values.capy.imageID -}}
{{- end -}}
{{- required (printf "capy.kubeTemplates[%s] or capy.imageID is required" $normalizedVersion) $imageID -}}
{{- end }}

{{/*
YandexMachineSpec YAML merged from group overrides and capy defaults.
Input: dict "root" $ "group" <master|workerGroup>
*/}}
{{- define "capy-cluster.yandexMachineSpec" -}}
{{- $root := .root -}}
{{- $group := .group | default dict -}}
{{- $capy := $root.Values.capy -}}
{{- $zoneID := $group.zoneID | default $capy.zoneID -}}
{{- $platformID := $group.platformID | default $capy.platformID -}}
{{- $cores := $group.cores | default $capy.cores | default 4 -}}
{{- $memory := $group.memory | default $capy.memory | default "8Gi" -}}
{{- $coreFraction := $group.coreFraction | default $capy.coreFraction | default 100 -}}
{{- $volumeSize := $group.volumeSize | default $capy.volumeSize | default "100Gi" -}}
{{- $volumeType := $group.volumeType | default $capy.volumeType | default "network-ssd" -}}
{{- $imageID := $group.imageID | default (include "capy-cluster.defaultImageID" $root) -}}
{{- $subnetID := $group.subnetID | default $capy.subnetID -}}
{{- $hasPublicIP := false -}}
{{- if hasKey $group "hasPublicIP" -}}
{{- $hasPublicIP = $group.hasPublicIP -}}
{{- else if hasKey $capy "hasPublicIP" -}}
{{- $hasPublicIP = $capy.hasPublicIP -}}
{{- end -}}
zoneID: {{ $zoneID | quote }}
platformID: {{ $platformID | quote }}
resources:
  cores: {{ $cores }}
  memory: {{ $memory | quote }}
  coreFraction: {{ $coreFraction }}
{{- if or $group.gpus $capy.gpus }}
  gpus: {{ $group.gpus | default $capy.gpus }}
{{- end }}
bootDisk:
  imageID: {{ $imageID | quote }}
  size: {{ $volumeSize | quote }}
  typeID: {{ $volumeType | quote }}
networkInterfaces:
- subnetID: {{ required "capy.subnetID (or group.subnetID) is required" $subnetID | quote }}
  hasPublicIP: {{ $hasPublicIP }}
{{- end }}

{{/*
Annotations for YandexIdentity (used by Shturval backend).
*/}}
{{- define "capy-cluster.providerAnnotations" -}}
{{- $capy := .Values.capy -}}
{{- $lb := $capy.loadBalancer | default dict -}}
{{- $listener := $lb.listener | default dict -}}
{{- $volumeTypes := $capy.allowedVolumeTypes | default (list) -}}
{{- if and (eq (len $volumeTypes) 0) $capy.volumeType -}}
{{- $volumeTypes = list $capy.volumeType -}}
{{- end -}}
{{- $platforms := $capy.allowedPlatformIDs | default (list) -}}
{{- if and (eq (len $platforms) 0) $capy.platformID -}}
{{- $platforms = list $capy.platformID -}}
{{- end -}}
shturval.tech/folder-id: {{ $capy.folderID | quote }}
shturval.tech/network-id: {{ $capy.networkID | quote }}
shturval.tech/subnet-id: {{ $capy.subnetID | quote }}
shturval.tech/zone-id: {{ $capy.zoneID | quote }}
shturval.tech/volume-types: {{ join "," $volumeTypes | quote }}
shturval.tech/allowed-platform-ids: {{ join "," $platforms | quote }}
shturval.tech/load-balancer-type: {{ $lb.type | default "ALB" | quote }}
{{- $lbInternal := true }}
{{- if hasKey $listener "internal" }}
{{- $lbInternal = $listener.internal }}
{{- end }}
shturval.tech/load-balancer-internal: {{ $lbInternal | toString | quote }}
shturval.tech/template-net-interface: {{ $capy.templateNetInterface | default "eth0" | quote }}
{{- range $kubeVersion, $imageID := $capy.kubeTemplates }}
{{- if $imageID }}
template.shturval.tech/{{ $kubeVersion }}: {{ $imageID | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
True if any workerNodes group has autoscaling.enabled.
*/}}
{{- define "capy-cluster.autoscalingEnabled" -}}
{{- $enabled := false -}}
{{- range $k, $v := .Values.workerNodes -}}
{{- if and $v.autoscaling $v.autoscaling.enabled -}}
{{- $enabled = true -}}
{{- end -}}
{{- end -}}
{{- $enabled -}}
{{- end -}}

{{/*
Resolve scale params for a worker MachineDeployment group.
Input: dict "root" $ "name" <groupKey> "group" <groupValues>
Output (YAML): enabled, minSize, maxMachines (if enabled), replicas

При autoscaling.enabled чарт не выставляет MachineDeployment.spec.replicas
(см. machinedeployment.yaml) — иначе helm template / helm-diff всегда
показывают drift относительно живого значения, которым владеет cluster-autoscaler.
replicas из values при этом остаётся min-size (пол автоскейлера);
фактический размер группы догоняет autoscaler (--enforce-node-group-min-size).
*/}}
{{- define "capy-cluster.workerGroupScale" -}}
{{- $name := .name -}}
{{- $group := .group -}}
{{- $autoscaling := $group.autoscaling | default dict -}}
{{- $enabled := $autoscaling.enabled | default false -}}
{{- $minSize := $group.replicas -}}
{{- $replicas := $group.replicas -}}
{{- if $enabled -}}
{{- $_ := required (printf "workerNodes.%s.replicas is required when autoscaling.enabled" $name) $group.replicas -}}
{{- $_ := required (printf "workerNodes.%s.autoscaling.maxMachines is required when autoscaling.enabled" $name) $autoscaling.maxMachines -}}
{{- if gt (int $minSize) (int $autoscaling.maxMachines) -}}
{{- fail (printf "workerNodes.%s.replicas (%v) must be <= autoscaling.maxMachines (%v)" $name $minSize $autoscaling.maxMachines) -}}
{{- end -}}
{{- end -}}
enabled: {{ $enabled }}
minSize: {{ $minSize }}
{{- if $enabled }}
maxMachines: {{ $autoscaling.maxMachines }}
{{- end }}
replicas: {{ $replicas }}
{{- end -}}

{{/*
cluster-autoscaler image: <systemregistry>/autoscaling/cluster-autoscaler:v<kubeVersion>
Override via images.clusterAutoscaler when needed.
*/}}
{{- define "capy-cluster.clusterAutoscalerImage" -}}
{{- if and .Values.images .Values.images.clusterAutoscaler -}}
{{- .Values.images.clusterAutoscaler -}}
{{- else -}}
{{- printf "%s/autoscaling/cluster-autoscaler:v%s" .Values.systemregistry .Values.kubeVersion -}}
{{- end -}}
{{- end -}}

{{/*
pause image for NCI (images.pause, fallback nodeInit.pauseImage)
*/}}
{{- define "capy-cluster.pauseImage" -}}
{{- $images := .Values.images | default dict -}}
{{- if $images.pause -}}
{{- $images.pause -}}
{{- else -}}
{{- $ni := .Values.nodeInit | default dict -}}
{{- required "images.pause (or nodeInit.pauseImage) is required" $ni.pauseImage -}}
{{- end -}}
{{- end -}}
