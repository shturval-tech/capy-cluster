# capy-cluster

Helm-чарт для развёртывания клиентского (или platform) кластера Штурвал с
инфраструктурным провайдером **CAPY (Cluster API Provider Yandex Cloud)** и
ресурсом `ClusterConfig`. Структура и bootstrap (kubeadm / NCI) аналогичны
`capsm-cluster` / `capos-cluster`, но VM поднимаются в Yandex Cloud.

## Что создаёт чарт

- Namespace релиза (= имя кластера)
- `YandexCluster` + `Cluster` (Cluster API)
- `KubeadmControlPlane` + `YandexMachineTemplate` для control-plane
- `MachineDeployment` + `KubeadmConfigTemplate` +
  `YandexMachineTemplate` на каждую worker-группу из `values.yaml`
- `ClusterConfig` (Shturval) и связанные Secret (encryption, etcd, cluster-config)
- `YandexIdentity` + Secret с ключом SA в `capy-system` (опционально)
- MachineHealthCheck / cluster-autoscaler (по values)
- Сабчарты мониторинга в management-кластере (`capy-cluster-vm` /
  `capy-cluster-grafana`)

> Балансировщик API — **ALB** в Yandex Cloud (NLB в CAPY пока не поддерживается
> нашим контуром). По умолчанию listener **internal**, порты **6443**
> (backend/Shturval convention).

## Предварительные требования

1. Management-кластер с:
   - Cluster API (CAPI);
   - `cluster-api-provider-yandex` (CAPY), CRD
     `infrastructure.cluster.x-k8s.io/v1alpha1`
     (`YandexCluster`, `YandexMachineTemplate`, `YandexIdentity`).

2. В Yandex Cloud:
   - folder, VPC network и subnet (зона совпадает с `capy.zoneID`);
   - образ Compute Image под целевую версию Kubernetes
     (`capy.kubeTemplates` / `capy.imageID`);
   - Service Account с ролями не ниже **compute.editor** и **alb.editor**,
     authorized key (JSON).

3. Каталог `charts/` с зависимостями `capsm-cluster-vm` /
   `capsm-cluster-grafana` (как в исходном capos/capsm), если включаете сабчарты.

## Быстрый старт

Не коммитьте реальный SA key. Передавайте через `--set-file` или локальный
`values-local.yaml` (в `.gitignore`).

> **SA key:** не указывайте путь в `capy.saKey` — туда кладётся само содержимое JSON.
> Варианты:
> - `capy.saKeyFile: conf/sa.json` (файл внутри чарта, читается `.Files.Get`);
> - `--set-file capy.saKey=/path/to/sa-key.json`;
> - YAML block scalar `|` в локальном values-файле.
> Ошибка `invalid character 'c'...` обычно значит, что в Secret попала строка `conf/sa.json`, а не JSON.


```bash
helm upgrade --install mycluster ./capy-cluster \
  --namespace mycluster --create-namespace \
  --set licensetoken=XXXX \
  --set systemregistry=myregistry.domain.tld \
  --set ingress=app.cluster.example.com \
  --set capy.folderID=b1gxxxxxxxx \
  --set capy.networkID=enpxxxxxxxx \
  --set capy.subnetID=e9xxxxxxxx \
  --set capy.zoneID=ru-central1-a \
  --set capy.kubeTemplates.v1.35.1=fd8xxxxxxxx \
  --set-file capy.saKey=/path/to/sa-key.json
```

## Ключевые values

### `capy` — глобальные настройки Yandex Cloud

| Параметр | Описание |
|---|---|
| `createIdentity` | Создавать `YandexIdentity` (+ Secret) в `identityNamespace` |
| `identityName` | Имя identity; по умолчанию `Release.Name` |
| `identityNamespace` | Namespace identity (по умолчанию `capy-system`) |
| `credentialsSecretName` / `credentialsKeyName` | Secret и ключ с SA JSON (`YandexCloudSAKey`) |
| `saKeyFile` | Путь к SA JSON относительно корня чарта (`conf/sa.json`) |
| `saKey` | Содержимое authorized key (строка/map JSON); альтернатива `saKeyFile` |
| `folderID`, `networkID`, `subnetID`, `zoneID` | Обязательные параметры размещения |
| `platformID` | Платформа VM (`standard-v3` и т.д.) |
| `volumeSize`, `volumeType` | Boot disk (quantity вроде `100Gi`, тип `network-ssd`) |
| `imageID` | Fallback image ID, если нет записи в `kubeTemplates` |
| `hasPublicIP` | Публичный IP на сетевом интерфейсе VM |
| `templateNetInterface` | Интерфейс в образе (для backend UI), обычно `eth0` |
| `loadBalancer.*` | ALB: type, name, backendPort, listener (internal/port/address), securityGroups, healthcheck |
| `allowedPlatformIDs` / `allowedVolumeTypes` | Списки для аннотаций backend |
| `kubeTemplates` | Карта `v<kubeVersion>` → Compute image ID |
| `labels` | Метки YC-ресурсов в `YandexCluster.spec.labels` |
| `identityRef` | Внешний identity при `createIdentity: false` |

Аннотации на `YandexIdentity` (совместимость с backend):

- `shturval.tech/folder-id`, `network-id`, `subnet-id`, `zone-id`
- `shturval.tech/volume-types`, `allowed-platform-ids`
- `shturval.tech/load-balancer-type`, `load-balancer-internal`
- `shturval.tech/template-net-interface`
- `template.shturval.tech/<kubeVersion>`

### Control plane / workers

Размеры задаются через **`cores` / `memory`** (quantity: `8Gi`), не через flavor.
Группы `master` и `workerNodes.<name>` могут переопределять
`platformID`, `volumeSize`, `volumeType`, `imageID`, `zoneID`, `cores`,
`memory`, `coreFraction`, `gpus`, `subnetID`, `hasPublicIP`.

`MachineDeployment.failureDomain` = `group.zoneID | default capy.zoneID`.

### Сеть и endpoint

| Параметр | Поведение |
|---|---|
| `clusterAPI` | Пусто → endpoint появится после создания ALB; задано → `Cluster.controlPlaneEndpoint` и certSANs |
| `podCIDR` / `serviceCIDR` | Сети кластера |
| `useExternalIngressLB` | По умолчанию `true` (как у capos) |
| `secure` | По умолчанию `true` (audit + encryption) |

### ClusterConfig / CSI / CCM

- `deployKeepAlived: false`
- CSI по умолчанию: `shturval-local-csi` (отдельного Yandex CSI нет)
- **CCM `providerSecretRef` не задаётся** — для CAPY backend не передаёт cloud-config secret

### Сабчарты

```yaml
capy-cluster-vm:
  enable: false
capy-cluster-grafana:
  enable: false
```

Имена пакетов зависимостей остаются `capsm-cluster-vm` /
`capsm-cluster-grafana`; меняются только alias/condition.

## Identity уже существует в `capy-system`

```yaml
capy:
  createIdentity: false
  identityRef:
    name: my-identity
    namespace: capy-system
```

## Обновление / масштабирование

`helm upgrade` обновляет CAPI-ресурсы. Смена `YandexMachineTemplate` обычно
требует rolling update MachineDeployment / KCP. При autoscaling CAPY создаёт
новые VM из образа — нужны квота и корректный `kubeTemplates` / `imageID`.

## Удаление

```bash
helm uninstall mycluster -n mycluster
# при необходимости удалите namespace кластера и связанные identity/secret в capy-system
```

VM и LB удаляются контроллерами CAPI/CAPY после удаления соответствующих CR.

## Troubleshooting

1. Проверьте `folderID` / `networkID` / `subnetID` / `zoneID` и права SA.
2. ALB listener: internal=true требует маршрутизации до VPC; для внешнего
   доступа выставьте `capy.loadBalancer.listener.internal: false`.
3. Статусы `YandexCluster`, `YandexMachine` и события CAPY-контроллера.
4. Образ в `kubeTemplates` должен соответствовать `kubeVersion`.
