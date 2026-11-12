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
{{- /* Существующий ключ не пересчитываем. */ -}}
{{- $key = index $existing.data "secret" | b64dec -}}
{{- else if .Values.etcd.encryptionSeed -}}
{{- $key = sha256sum (printf "%s:%s-encryption-key" (toString .Values.etcd.encryptionSeed) .Release.Name) | trunc 32 -}}
{{- else -}}
{{- $cc := lookup "cluster.shturval.tech/v1beta1" "ClusterConfig" .Release.Name .Release.Name -}}
{{- if and $cc $cc.spec -}}
{{- /* Апгрейд существующего кластера: ключ не меняем. */ -}}
{{- $key = sha256sum (printf "%s-encryption-key" .Release.Name) | trunc 32 -}}
{{- else -}}
{{- fail (printf "новый кластер %s: задайте etcd.encryptionSeed в values (случайная строка, например `openssl rand -base64 32`). Без seed шифрование etcd не будет безопасным." .Release.Name) -}}
{{- end -}}
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
Fail on a value that is not a Yandex Compute image ID.
Input: dict "value" <value> "source" <field name>.
*/}}
{{- define "capy-cluster.validateImageID" -}}
{{- $value := toString .value -}}
{{- if not (regexMatch "^fd[a-z0-9]+$" $value) -}}
{{- fail (printf "%s: expected Yandex Compute image ID like fd8c094339ic6igfku8s, got %q (use `yc compute image list`)" .source $value) -}}
{{- end -}}
{{- end }}

{{/*
Resolve Yandex Compute image ID for the effective kubeVersion from capy.kubeTemplates.
*/}}
{{- define "capy-cluster.defaultImageID" -}}
{{- $kubeVersion := include "capy-cluster.effectiveKubeVersion" . | toString | trim -}}
{{- $normalizedVersion := ternary $kubeVersion (printf "v%s" $kubeVersion) (hasPrefix "v" $kubeVersion) -}}
{{- $templates := .Values.capy.kubeTemplates | default dict -}}
{{- range $version, $templateImageID := $templates -}}
{{- if $templateImageID -}}
{{- $_ := include "capy-cluster.validateImageID" (dict "value" $templateImageID "source" (printf "capy.kubeTemplates[%s]" $version)) -}}
{{- end -}}
{{- end -}}
{{- $imageID := get $templates $normalizedVersion -}}
{{- if not $imageID -}}
{{- $imageID = get $templates (trimPrefix "v" $normalizedVersion) -}}
{{- end -}}
{{- required (printf "capy.kubeTemplates[%s] is required" $normalizedVersion) $imageID -}}
{{- end }}

{{/*
YandexMachineSpec YAML merged from group overrides and capy defaults.
Input: dict "root" $ "group" <master|workerGroup> "name" <group name>
*/}}
{{- define "capy-cluster.yandexMachineSpec" -}}
{{- $root := .root -}}
{{- $group := .group | default dict -}}
{{- $groupName := .name | default "group" -}}
{{- $capy := $root.Values.capy -}}
{{- $zoneID := $group.zoneID | default $capy.zoneID -}}
{{- $platformID := $group.platformID | default $capy.platformID -}}
{{- $cores := $group.cores | default $capy.cores | default 4 -}}
{{- $memory := $group.memory | default $capy.memory | default "8Gi" -}}
{{- $coreFraction := $group.coreFraction | default $capy.coreFraction | default 100 -}}
{{- $volumeSize := $group.volumeSize | default $capy.volumeSize | default "100Gi" -}}
{{- $volumeType := $group.volumeType | default $capy.volumeType | default "network-ssd" -}}
{{- $imageID := $group.imageID | default "" -}}
{{- if $imageID -}}
{{- $_ := include "capy-cluster.validateImageID" (dict "value" $imageID "source" (printf "%s.imageID" $groupName)) -}}
{{- else -}}
{{- $imageID = include "capy-cluster.defaultImageID" $root -}}
{{- end -}}
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
{{- /* Ключи новее текущего kubeVersion — из дефолтов чарта при merge values, в аннотации не пишем. */}}
{{- $active := include "capy-cluster.effectiveKubeVersion" . }}
{{- $tplAnnotations := list }}
{{- range $kubeVersion, $imageID := $capy.kubeTemplates }}
{{- if and $imageID (semverCompare (printf "<=%s" $active) (trimPrefix "v" $kubeVersion)) }}
{{- $tplAnnotations = append $tplAnnotations (printf "template.shturval.tech/%s: %q" $kubeVersion $imageID) }}
{{- end }}
{{- end }}
{{- range $tplAnnotations }}
{{ . }}
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
cluster-autoscaler image.
Тег из профиля релиза, не из kubeVersion: 2.15.0 — v1.36.1-325745, 2.14.x — v1.35.1.
Реестр — systemregistry. Полный образ переопределяется images.clusterAutoscaler.
*/}}
{{- define "capy-cluster.clusterAutoscalerImage" -}}
{{- if and .Values.images .Values.images.clusterAutoscaler -}}
{{- .Values.images.clusterAutoscaler -}}
{{- else -}}
{{- $p := include "capy-cluster.releaseProfile" . | fromYaml -}}
{{- $tag := $p.clusterAutoscalerTag | default (printf "v%s" (include "capy-cluster.effectiveKubeVersion" .)) -}}
{{- printf "%s/autoscaling/cluster-autoscaler:%s" .Values.systemregistry $tag -}}
{{- end -}}
{{- end -}}

{{/*
pause image for NCI.
images.pause, иначе conf/releases, иначе nodeInit.pauseImage.
*/}}
{{- define "capy-cluster.pauseImage" -}}
{{- $images := .Values.images | default dict -}}
{{- if $images.pause -}}
{{- $images.pause -}}
{{- else -}}
{{- $p := include "capy-cluster.releaseProfile" . | fromYaml -}}
{{- if $p.pauseImage -}}
{{- $p.pauseImage -}}
{{- else -}}
{{- $ni := .Values.nodeInit | default dict -}}
{{- required "images.pause (или профиль релиза, или nodeInit.pauseImage) is required" $ni.pauseImage -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Профиль релиза: conf/releases/<shturvalReleaseVersion>.yaml.
Явные values важнее. Профиль нужен для полей, которых не было в 2.14 (CoreDNS),
и как запасной источник, если kubeVersion пустой.
*/}}
{{- define "capy-cluster.releaseProfile" -}}
{{- $ver := .Values.shturvalReleaseVersion | default "2.15.0" -}}
{{- $path := printf "conf/releases/%s.yaml" $ver -}}
{{- $raw := .Files.Get $path -}}
{{- if not $raw -}}
{{- fail (printf "нет профиля релиза %s (%s). Ожидаются 2.14.0, 2.14.1 или 2.15.0" $ver $path) -}}
{{- end -}}
{{- $raw -}}
{{- end -}}

{{- define "capy-cluster.effectiveKubeVersion" -}}
{{- if .Values.kubeVersion -}}
{{- .Values.kubeVersion -}}
{{- else -}}
{{- (include "capy-cluster.releaseProfile" . | fromYaml).kubeVersion -}}
{{- end -}}
{{- end -}}

{{/*
Тег CoreDNS. Пустая строка для 2.14.x — блок dns в KubeadmControlPlane не пишется.
Переопределение: images.coreDNS.
*/}}
{{- define "capy-cluster.coreDNSTag" -}}
{{- if and .Values.images (index .Values.images "coreDNS") -}}
{{- index .Values.images "coreDNS" -}}
{{- else -}}
{{- $p := include "capy-cluster.releaseProfile" . | fromYaml -}}
{{- $p.coreDNSImageTag | default "" -}}
{{- end -}}
{{- end -}}

{{/*
Тег etcd. Явный etcd.local.imageTag важнее профиля релиза.
*/}}
{{- define "capy-cluster.etcdImageTag" -}}
{{- $local := .Values.etcd.local | default dict -}}
{{- if $local.imageTag -}}
{{- $local.imageTag -}}
{{- else -}}
{{- $p := include "capy-cluster.releaseProfile" . | fromYaml -}}
{{- required "etcd.local.imageTag (или etcdImageTag в профиле релиза) is required" $p.etcdImageTag -}}
{{- end -}}
{{- end -}}

{{/*
Списки сервисов.
Если ClusterConfig уже есть — берём списки из него (webhook запрещает правку).
Иначе values и, для controllerType=gateway, та же нормализация, что ApplyIngressControllerServiceLists.
*/}}
{{- define "capy-cluster.serviceLists" -}}
{{- $enabled := .Values.services.enabledservices | default (list) -}}
{{- $disabled := .Values.services.disablesservices | default (list) -}}
{{- $cc := lookup "cluster.shturval.tech/v1beta1" "ClusterConfig" .Release.Name .Release.Name -}}
{{- if and $cc $cc.spec $cc.spec.systemServicesConfig -}}
{{- $ssc := $cc.spec.systemServicesConfig -}}
{{- if hasKey $ssc "enabledServices" -}}
{{- $enabled = $ssc.enabledServices | default (list) -}}
{{- end -}}
{{- if hasKey $ssc "disabledServices" -}}
{{- $disabled = $ssc.disabledServices | default (list) -}}
{{- end -}}
{{- else -}}
{{- $gateway := eq (.Values.ingressControllerType | default "nginx") "gateway" -}}
{{- $install := "shturval-ingress-controller" -}}
{{- $remove := "shturval-gateway-api-crds" -}}
{{- if $gateway -}}
{{- $install = "shturval-gateway-api-crds" -}}
{{- $remove = "shturval-ingress-controller" -}}
{{- end -}}
{{- $newEnabled := list -}}
{{- $hasInstall := false -}}
{{- range $enabled -}}
{{- if ne . $remove -}}
{{- $newEnabled = append $newEnabled . -}}
{{- if eq . $install }}{{- $hasInstall = true }}{{- end -}}
{{- end -}}
{{- end -}}
{{- if not $hasInstall -}}
{{- $newEnabled = append $newEnabled $install -}}
{{- end -}}
{{- $enabled = $newEnabled -}}
{{- $newDisabled := list -}}
{{- $hasRemove := false -}}
{{- range $disabled -}}
{{- if ne . $install -}}
{{- $newDisabled = append $newDisabled . -}}
{{- if eq . $remove }}{{- $hasRemove = true }}{{- end -}}
{{- end -}}
{{- end -}}
{{- if and $gateway (not $hasRemove) -}}
{{- $newDisabled = append $newDisabled $remove -}}
{{- end -}}
{{- $disabled = $newDisabled -}}
{{- end -}}
enabled:
{{ toYaml $enabled | nindent 2 }}
disabled:
{{ toYaml $disabled | nindent 2 }}
{{- end -}}

{{- define "capy-cluster.validateIngressCerts" -}}
{{- $n := 0 -}}
{{- if .Values.ingressCert }}{{- $n = add $n 1 }}{{- end -}}
{{- if .Values.caCert }}{{- $n = add $n 1 }}{{- end -}}
{{- if .Values.acme }}
{{- if or .Values.acme.serverURL .Values.acme.rootCA .Values.acme.rootCABundle .Values.acme.email }}
{{- $n = add $n 1 }}
{{- end }}
{{- end -}}
{{- if .Values.vault }}
{{- if or .Values.vault.server .Values.vault.path .Values.vault.token .Values.vault.caBundle .Values.vault.rootCA }}
{{- $n = add $n 1 }}
{{- end }}
{{- end -}}
{{- if gt (int $n) 1 -}}
{{- fail "укажите только один способ сертификата ingress: ingressCert, caCert, acme или vault" -}}
{{- end -}}
{{- $ct := .Values.ingressControllerType | default "nginx" -}}
{{- if not (or (eq $ct "nginx") (eq $ct "gateway")) -}}
{{- fail "ingressControllerType должен быть nginx или gateway" -}}
{{- end -}}
{{- if and .Values.update .Values.update.strategy -}}
{{- if not (or (eq .Values.update.strategy "InPlace") (eq .Values.update.strategy "RollingUpdate")) -}}
{{- fail "update.strategy должен быть InPlace или RollingUpdate" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "capy-cluster.assertCompatibleUpgrade" -}}
{{- $cc := lookup "cluster.shturval.tech/v1beta1" "ClusterConfig" .Release.Name .Release.Name -}}
{{- if and $cc $cc.spec $cc.spec.releaseVersion -}}
{{- $live := $cc.spec.releaseVersion | toString -}}
{{- $want := .Values.shturvalReleaseVersion | toString -}}
{{- if and $live (ne $live $want) (not .Values.platformUpgrade) -}}
{{- fail (printf "ClusterConfig %s уже имеет spec.releaseVersion=%s, в values указано %s. Смена версии запускает обновление платформы. Чтобы обновить только чарт, оставьте shturvalReleaseVersion=%s. Чтобы обновить платформу, задайте platformUpgrade=true. При helm template и в Argo CD lookup пустой, проверка не срабатывает — сверяйте values с живым ClusterConfig до apply." .Release.Name $live $want $live) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "capy-cluster.preflight" -}}
{{- include "capy-cluster.validateIngressCerts" . -}}
{{- include "capy-cluster.assertCompatibleUpgrade" . -}}
{{- end -}}

{{- define "capy-cluster.csiSecretName" -}}
yc-csi-ssc
{{- end -}}

{{- define "capy-cluster.csiConfigYaml" -}}
{{- $sa := include "capy-cluster.saKey" . -}}
{{- if not $sa -}}
{{- fail "для shturval-capy-csi нужен capy.saKey или capy.saKeyFile" -}}
{{- end -}}
{{- if not .Values.capy.folderID -}}
{{- fail "для shturval-capy-csi нужен capy.folderID" -}}
{{- end -}}
folderId: {{ .Values.capy.folderID | quote }}
saKey: {{ $sa | quote }}
{{- end -}}

{{- define "capy-cluster.csiSecretWanted" -}}
{{- $root := . -}}
{{- $name := include "capy-cluster.csiSecretName" $root -}}
{{- $on := false -}}
{{- if $root.Values.csi -}}
{{- range $root.Values.csi -}}
{{- if eq .serviceConfigName "shturval-capy-csi" -}}
{{- if not .providerSecretRef -}}
{{- $on = true -}}
{{- else if and (eq .providerSecretRef.name $name) (or (not .providerSecretRef.namespace) (eq .providerSecretRef.namespace $root.Release.Name)) -}}
{{- $on = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- else if $root.Values.capy.enableCSI -}}
{{- $on = true -}}
{{- end -}}
{{- if $on }}true{{ end -}}
{{- end -}}
