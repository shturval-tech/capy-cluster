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
| `kubeTemplates` | Карта `v<kubeVersion>` → Compute image ID. **Обязательно** заполнить для используемой версии Kubernetes |
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
- CSI по умолчанию: `shturval-local-csi`. `capy.enableCSI: true` ставит `shturval-capy-csi` и Secret `yc-csi-ssc` (`folderId` + `saKey`) в namespace кластера. `providerSecretRef` указывать не нужно
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

## Обновление чарта с 2.14 на 2.15

Чарт `2.15` ставит новый кластер Штурвала **2.15.0** (Kubernetes 1.36.5).
Уже работающий кластер 2.14 этим чартом обновляется только как Helm-релиз:
машины не пересоздаются и обновление платформы не стартует, если values
по-прежнему описывают 2.14.

1. Сначала обновите менеджмент-кластер до Штурвала 2.15 (CRD `InfrastructureProvider`, CAPI v1beta2). Потом обновляйте чарты клиентских кластеров.
2. Возьмите values, которыми кластер ставился (`helm get values <release> -n <namespace> -o yaml`), а не дефолты нового чарта.
3. Не используйте `--reuse-values` вслепую и не подставляйте голый `--reset-values`: новый чарт по умолчанию содержит `shturvalReleaseVersion: 2.15.0`, `kubeVersion: 1.36.5`, новые теги etcd, pause и kube-vip. Для обновления только чарта оставьте прежние версии.
4. Предпочтительно `helm upgrade --reset-then-reuse-values` вместе с файлом старых values, затем `helm diff upgrade` (если плагин установлен) или `helm template` / `helm upgrade --dry-run`.
5. `shturvalReleaseVersion` меняйте только вместе с `platformUpgrade: true`. Иначе при живом кластере чарт останавливает рендер: смена `spec.releaseVersion` запускает обновление платформы. `helm template` и Argo CD не видят объекты кластера (`lookup` пустой), поэтому проверку нужно сделать до apply.
6. `enabledServices` и `disabledServices` у существующего ClusterConfig чарт не переписывает: webhook запрещает их менять, списки читаются из живого объекта.
7. **Новые поля ClusterConfig к существующему объекту не применяются.** Если ClusterConfig уже есть, чарт берёт его `spec` из кластера и меняет только `releaseVersion`. Поэтому `update.strategy`, `deletePersistentVolumes`, `ingressControllerType` и `vault` на существующем кластере **молча игнорируются** — ошибки не будет, но и значения из values не попадут в объект. Это сделано намеренно: webhook запрещает менять `spec` существующего ClusterConfig. Чтобы задать эти поля, их нужно прописать в живой ClusterConfig отдельно (или пересоздать кластер).
8. `InfrastructureProvider` создаётся только если CRD уже есть (`infrastructureProvider.create: auto`) и объект с тем же именем не принадлежит другому релизу. Нативные секреты и аннотации `shturval.tech/*` чарт не удаляет: они нужны менеджмент-кластеру 2.14 и миграции 2.15.
9. Поле `services.disablesservices` — явный список. Значение `all` в ClusterConfig не работает (его понимает только REST API backend и нельзя совместить с `enabledServices`). Некритичный сервис, которого нет ни в одном списке и у которого режим по умолчанию `auto`, будет установлен.

10. **Шаблон ВМ привязан к `kubeVersion`.** `capy.kubeTemplates` в values содержит запись только для версии 2.15 (`v1.36.5`). Если оставить старый `kubeVersion`, чарт остановит рендер с ошибкой «kubeTemplates must contain image/template». Для апгрейда только чарта оставьте и `kubeVersion`, и запись `kubeTemplates` для своей версии; для апгрейда платформы обновите `kubeVersion` до `1.36.5`.

## Шифрование etcd (encryption-at-rest)

`etcd.encryptionSeed` — обязательное поле для нового кластера с `secure: true`. Без него чарт останавливает рендер: без seed ключ шифрования etcd не будет безопасным.

```yaml
etcd:
  encryptionSeed: "своя-случайная-строка"   # openssl rand -base64 32
```

При апгрейде уже установленного кластера seed не требуется — чарт определяет апгрейд по наличию `ClusterConfig` с тем же именем и сохраняет прежний ключ. При `secure: false` шифрование не включается, seed тоже не нужен.

> **Важно.** Seed храните вместе с паролями от кластера. При пересоздании кластера с другим seed ранее зашифрованные Secret прочитать не получится. У работающего кластера менять seed бессмысленно: пока существует ключ в кластере, используется он.


Платформенное обновление клиентского кластера 2.14 → 2.15 делайте отдельно, через shturval-update / `platformUpgrade: true`, а не как побочный эффект `helm upgrade`.
