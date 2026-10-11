# pgcache-multi-tenant

**Um benchmark reproduzível que mede quanto vale um cache de leitura na frente do
banco de um SaaS multi-tenant — e o relato completo do que ele mediu.**

Tudo o que é preciso para rodar está aqui: o esquema, a carga, o ambiente, os
drivers e os números que obtivemos. A seção 2 é um início rápido de quatro
comandos; o resto é o raciocínio, incluindo as partes em que erramos.

> 🇬🇧 **[English version](README.md)**

---

## Índice

1. [O que é isto](#1-o-que-é-isto)
2. [Início rápido](#2-início-rápido)
3. [A pergunta](#3-a-pergunta)
4. [Contexto: o fato que decide tudo](#4-contexto-o-fato-que-decide-tudo)
5. [Por que multi-tenant, e o que esperávamos](#5-por-que-multi-tenant-e-o-que-esperávamos)
6. [O truque: um script do pgbench é uma requisição](#6-o-truque-um-script-do-pgbench-é-uma-requisição)
7. [**O ambiente, exatamente**](#7-o-ambiente-exatamente)
8. [Passo 1 — o esquema](#8-passo-1--o-esquema)
9. [Passo 2 — denormalizar o tenant](#9-passo-2--denormalizar-o-tenant)
10. [Passo 3 — a requisição](#10-passo-3--a-requisição)
11. [Passo 4 — o protocolo de medição](#11-passo-4--o-protocolo-de-medição)
12. [Varredura 1 — o número de tenants quebra o cache?](#12-varredura-1--o-número-de-tenants-quebra-o-cache)
13. [Varredura 2 — separando cache de saturação](#13-varredura-2--separando-cache-de-saturação)
14. [Varredura 3 — escrita](#14-varredura-3--escrita)
15. [Por que a forma da query decide tudo](#15-por-que-a-forma-da-query-decide-tudo)
16. [O que isto não prova](#16-o-que-isto-não-prova)
17. [Apêndice: todos os arquivos](#17-apêndice-todos-os-arquivos)

---

## 1. O que é isto

Duas coisas num repositório só.

**Uma ferramenta.** Um benchmark que modela um dashboard de SaaS multi-tenant
contra o PostgreSQL, com e sem um cache de leitura na frente, e mede a diferença
em três eixos: número de tenants, concorrência e proporção de escrita.

**Um relato.** A história completa de rodá-lo — por que cada decisão foi tomada
do jeito que foi, no que os números deram, e os erros cometidos no caminho.
Escrito para quem nunca viu isto antes; nada assume contexto prévio.

**O resultado, em uma linha:** o cache respondeu um dashboard de oito statements
entre **6,4× e 12,6× mais rápido** que o banco sem cache, com **100% de taxa de
acerto em todas as células**, e a vantagem sobreviveu a 10% de escrita.

A seção 16 é onde esse número deve parar de ser esticado. Uma coisa em
particular: **nunca rodamos um gate de correção diferencial contra esta carga**,
e até que isso aconteça, todo número aqui carrega esse asterisco.

O cache testado é o [PgCache](https://www.pgcache.com). Nada aqui tem vínculo com
ele — é uma medição independente, inclusive nas partes desfavoráveis.

---

## 2. Início rápido

Você precisa de um cluster Kubernetes com **três nós escalonáveis** (o motivo
está na seção 7 e não é negociável) e do `kubectl`.

```bash
# 1. Sobe os três componentes mais um leitor de métricas.
kubectl apply -f infra/k8s/

# 2. Espera, e confirma que caíram em três nós DIFERENTES.
kubectl -n pgcache-mt rollout status deploy/loadgen --timeout=10m
kubectl -n pgcache-mt rollout status deploy/pgcache --timeout=10m
kubectl -n pgcache-mt get pods -o wide

# 3. Esquema, seed, denormalização do tenant, carga. Cerca de um minuto.
./scripts/00-setup.sh

# 4. As três varreduras. 15 a 25 minutos cada.
./scripts/01-tenant-sweep.sh      | tee data/run-tenants.txt
./scripts/02-concurrency-sweep.sh | tee data/run-clients.txt
./scripts/03-write-sweep.sh       | tee data/run-writes.txt
```

Antes de acreditar em qualquer saída, confira duas coisas:

```bash
# Três nós distintos, de preferência numa mesma zona de disponibilidade.
kubectl -n pgcache-mt get pods -o wide
kubectl get nodes -L topology.kubernetes.io/zone

# Nenhuma preempção dentro de uma janela de medição. Em instâncias spot, uma
# evicção no meio da janela invalida aquela célula -- descarte e rode de novo.
kubectl -n pgcache-mt get events --sort-by=.lastTimestamp \
  | grep -iE 'preempt|evict|NodeNotReady'
```

Há também um setup para laptop em [`infra/docker-compose.yml`](infra/docker-compose.yml).
Ele reproduz a *forma* dos resultados, mas não as magnitudes — a seção 7.6
explica por quê, e isso importa mais do que parece.

### Deploy com Helm

Você pode fazer o deploy no Kubernetes ou Docker Desktop usando o Helm chart em [`infra/helm/pgcache-mt`](infra/helm/pgcache-mt/) ou com o utilitário [`scripts/helm-deploy.sh`](scripts/helm-deploy.sh):

```bash
# Cluster Kubernetes de produção (3 nós dedicados):
helm install pgcache-mt infra/helm/pgcache-mt \
  --namespace pgcache-mt --create-namespace \
  --set image.pgcache.tag="0.7.0"

# Clusters de produção ARM64 (ex: AWS Graviton):
helm install pgcache-mt infra/helm/pgcache-mt \
  --namespace pgcache-mt --create-namespace \
  --set image.pgcache.tag="0.7.0-arm64"

# Kubernetes local no Docker (Docker Desktop / kind / k3d):
./scripts/helm-deploy.sh --docker 0.7.0-arm64
# Ou manualmente com Helm:
helm install pgcache-mt infra/helm/pgcache-mt \
  -f infra/helm/pgcache-mt/values-docker.yaml \
  --namespace pgcache-mt --create-namespace \
  --set image.pgcache.tag="0.7.0-arm64"
```

### Resultados de múltiplas versões e verificação local no Docker

Os resultados de verificação do benchmark estruturados por tag de versão (`0.6.3`, `0.6.4` e `0.7.0`) estão disponíveis na pasta [`results/`](results/) com relatórios dedicados em inglês e português.

Para rodar a verificação local no Docker para qualquer tag:

```bash
./scripts/run-tag-verification.sh 0.7.0 5
```

---

## 3. A pergunta

O **PgCache** é um cache de leitura que fica entre a aplicação e o PostgreSQL.
Ele fala o protocolo do PostgreSQL, então a aplicação não sabe que ele existe —
você aponta a string de conexão para o cache em vez do banco e não muda mais
nada.

O que o torna interessante é a *coerência*. A maioria dos caches fica velha e
depende de TTL: você aceita servir dado com até N segundos de atraso. O PgCache,
em vez disso, acompanha o log de replicação do banco de origem e invalida as
entradas afetadas quando as linhas mudam. Em tese, é a velocidade de um cache sem
o problema clássico de um cache.

A pergunta que este benchmark responde:

> Colocar um cache de leitura na frente do banco realmente deixa uma aplicação
> multi-tenant mais rápida — e sob que condições isso deixa de valer a pena?

As duas metades importam. Um benchmark que só produz a primeira é marketing.

---

## 4. Contexto: o fato que decide tudo

Eis a coisa sobre o PgCache que parece detalhe de implementação e acaba
determinando todos os resultados deste documento:

> **Um acerto de cache não é uma leitura de memória. É uma consulta SQL
> completa.**

A imagem do PgCache embute um PostgreSQL próprio, e é nele que as entradas ficam.
Quando o cache "acerta", o que acontece é uma consulta completa a esse banco
local — parse, execução, transporte das linhas de volta. Mais barato que ir à
origem, mas não de graça, e nem de longe os nanossegundos de um `GET` de Redis.

Isso dá ao PgCache um **piso**: um custo mínimo por consulta abaixo do qual ele
não consegue ir. E produz uma regra fácil de enunciar e fácil de esquecer:

> Se o banco de origem já responde mais rápido que esse piso, nenhuma
> configuração ajuda. O cache vira puro custo adicional.

Aprendemos isso do jeito caro, num sujeito anterior do mesmo laboratório — um
serviço de autorização cujo banco servia cada consulta em **39,5 a 42,2
microssegundos**, contra **41,9 a 47,0** do PgCache. Cerca de 5 µs de sobrecarga
por consulta, o que para um proxy de rede é comportamento genuinamente bom — mas
com o **sinal errado**. Multiplicado pelas 104 a 171 consultas que aquele serviço
emitia por requisição, aqueles 5 µs viravam uma penalidade visível.

Por que a origem era tão rápida? O conjunto de dados inteiro cabia na memória,
com **99,93% de acerto no buffer pool**. Tínhamos construído um cache de leitura
na frente de um banco que já servia inteiramente da RAM.

Guarde isso para a seção 7.2, onde você vai nos ver fazer de novo, de propósito.

### Os dois caminhos

O benchmark compara duas pilhas idênticas que diferem em exatamente uma coisa:

- **Caminho A — a linha de base.** O cliente fala direto com o PostgreSQL.
- **Caminho B — PgCache.** O cliente fala com o PgCache, que fala com o
  PostgreSQL.

Mesmo binário, mesmos dados, mesma classe de máquina, mesma rede. **O host e a
porta da conexão são a única diferença.** Qualquer outra coisa diferente torna a
comparação sem sentido, e a seção 7 existe em boa parte para defender essa frase.

---

## 5. Por que multi-tenant, e o que esperávamos

Três formatos de aplicação eram candidatos: um catálogo de e-commerce, um SaaS
multi-tenant e um site de conteúdo. Rodamos o multi-tenant primeiro **de
propósito, porque esperávamos que fosse o pior deles.**

Num SaaS multi-tenant, toda query é escopada à organização do cliente:

```sql
SELECT ... FROM orders WHERE tenant_id = 47 ...
```

Sob o protocolo simples — que é o que o PgCache precisa, e a seção 7.5 explica
por quê — o literal é escrito no texto do SQL antes do envio. Então
`tenant_id = 47` e `tenant_id = 48` são duas *strings de query diferentes*, e
portanto duas entradas de cache diferentes.

Com 200 tenants ativos, cada statement se multiplica em 200 entradas distintas.
Acrescente paginação e filtros e multiplica de novo. A hipótese era que essa
**explosão do espaço de consultas** derrubaria a taxa de acerto até o chão.

Se o cache sobrevivesse ao caso mais difícil, os mais fáceis não precisariam de
defesa.

**A hipótese estava errada**, e a seção 12 mostra por quanto. Vale dizer de
saída: este benchmark foi desenhado para achar um limite e não achou — o que é
diferente, e menos confortável, do que um desenhado para achar uma vitória.

---

## 6. O truque: um script do pgbench é uma requisição

A ferramenta é o **pgbench**, que vem junto com o PostgreSQL.

O pgbench tem uma fraqueza aparente: foi feito para martelar um banco com
statements isolados. Aplicações reais não fazem isso — elas emitem oito, ou
vinte, ou cem statements para renderizar uma tela. Essa propriedade se chama
**amplificação de consultas**, e é o maior fator isolado em saber se um cache
ajuda, porque o que quer que o cache faça por consulta é multiplicado por ela.

O truque que torna este benchmark possível:

> **Um script `-f` do pgbench é uma transação, e o pgbench reporta a latência
> dela como um número só.**

Então um script com oito statements é uma **requisição** com oito statements, e o
que o pgbench mede é latência por requisição — a unidade que o usuário sente, e a
unidade em que uma decisão de adoção é tomada.

A amplificação deixa de ser propriedade de alguma aplicação que você precisa ir
procurar, e vira um parâmetro que você escreve.

---

## 7. O ambiente, exatamente

Toda configuração aqui faz parte da medição. Mudar uma muda o que os números
significam, então cada uma vem com o seu motivo.

Manifestos: [`infra/k8s/`](infra/k8s/).

### 7.1 Máquinas

| papel | o que roda | requests | nó usado nos números publicados |
|---|---|---|---|
| `origin` | `postgres:17` | 6 CPU / 20 GiB | Standard_D8as_v5 — 8 vCPU, 32 GiB |
| `pgcache` | `pgcache/pgcache:latest` | 6 CPU / 24 GiB | o mesmo |
| `loadgen` | `postgres:17` (pgbench) | 6 CPU / 8 GiB | o mesmo |
| `metrics-reader` | `alpine:3.20` | 50m / 64 MiB | pool de sistema, ocioso |

**Três nós separados, garantidos por `podAntiAffinity`.** Esta é a decisão de
infraestrutura mais importante e não tem nada a ver com organização.

O caminho B roda *tanto* a origem *quanto* o PgCache. O caminho A roda só a
origem. Se dividissem um nó, o caminho B teria menos CPU disponível para a origem
do que o caminho A teve — **exatamente na concorrência em que a comparação se
decide**. O resultado seria artefato da colocação, não propriedade do cache.

**Só requests, sem limites de CPU.** Um limite de CPU no Kubernetes vira cota CFS
aplicada em janelas de 100 ms: um pod que estoura fica congelado até a janela
virar. Esse congelamento aparece como pico de p99 **indistinguível de um cache
miss** — precisamente o sinal que estamos lendo. Com um pod por nó, o isolamento
vem do nó e nenhuma cota é necessária.

**Limites de memória trazem uma armadilha específica.** Se você adicionar
`resources.limits.memory` ao pod do PgCache, precisa também definir
`MEMORY_LIMIT` abaixo dele. O PgCache assume 80% da RAM que *detecta*, e dentro
de um cgroup ele tende a detectar os 32 GiB inteiros do nó — então vai tentar
usar ~25 GB dentro de um limite de 4 GiB e morrer por OOM.

**As zonas de disponibilidade foram verificadas, não presumidas.** Os três nós
caíram na mesma zona. Uma divisão entre zonas acrescenta dezenas de
microssegundos a um dos caminhos e poderia explicar sozinha um resultado deste
tamanho:

```bash
kubectl get nodes -L topology.kubernetes.io/zone
```

**Instâncias spot servem, com uma regra.** Estes rodaram em nós spot. Uma evicção
*dentro* de uma janela de medição invalida aquela célula — confira depois de cada
varredura e refaça a repetição afetada.

### 7.2 PostgreSQL — cada flag, e por quê

```
postgres
  -c wal_level=logical
  -c max_wal_senders=10
  -c max_replication_slots=10
  -c shared_preload_libraries=pg_stat_statements
  -c pg_stat_statements.track=all
  -c shared_buffers=1GB
  -c max_connections=500
  -c work_mem=32MB
  -c maintenance_work_mem=512MB
  -c random_page_cost=1.1
  -c track_io_timing=on
```

| flag | por que está aí |
|---|---|
| `wal_level=logical` | **Obrigatória.** O PgCache acompanha o stream de replicação para saber o que invalidar. Sem decodificação lógica não há feed de mudanças nem coerência. |
| `max_wal_senders`, `max_replication_slots` | Folga para o slot de replicação do cache e o que mais estiver conectado. |
| `pg_stat_statements` | Permite inspecionar o que a carga *de fato* emitiu, statement a statement. Suposições sobre SQL gerado costumam estar erradas. |
| **`shared_buffers=1GB`** | **A configuração mais consequente daqui.** Ver abaixo. |
| `max_connections=500` | A varredura de concorrência chega a 32 clientes por caminho, cada um segurando uma conexão. Folga, não tuning. |
| `work_mem=32MB` | Suficiente para o `GROUP BY` e o `ORDER BY` do dashboard ordenarem em memória. Uma carga derramando em disco mediria arquivos temporários. |
| `random_page_cost=1.1` | Armazenamento em SSD. O padrão 4.0 assume disco mecânico e empurra o planejador para varreduras sequenciais que ele não deveria escolher. |
| `track_io_timing=on` | Torna "a origem está servindo da memória?" uma medição em vez de uma suposição. |

**Sobre o `shared_buffers=1GB`.** O conjunto de dados tem ~463 MB, então cabe
inteiro. A origem nunca toca o disco.

Isso é deliberado, e é o caso **mais difícil** para o cache: ele não pode ganhar
evitando I/O de disco — a história fácil — e tem que ganhar em trabalho
economizado ou não ganha. É também exatamente a condição que tornou o sujeito
anterior da seção 4 impossível de vencer. Qualquer resultado aqui é conservador
nesse eixo.

### 7.3 PgCache — cada variável, e uma que arruína a rodada

```yaml
UPSTREAM_URL:       postgres://bench:benchpass@origin...:5432/bench
LISTEN_PORT:        "6432"
METRICS_PORT:       "9090"
NUM_WORKERS:        "4"
ALLOWED_TABLES:     "product,category,seller,customer,orders,order_item,review"
PGCACHE_TELEMETRY:  "off"
```

**`ALLOWED_TABLES` é a configuração que arruína uma rodada em silêncio.** O
PgCache só cacheia as tabelas listadas. Erre e toda consulta vira miss, o cache
parece inútil, e **nada dá erro em lugar nenhum**.

Perdemos uma sonda inteira de dez células exatamente assim. A lista foi passada
com `helm --set`, que quebra vírgulas não escapadas em atribuições separadas, e o
valor inteiro foi descartado. Toda forma de query reportou **0,0% de acerto** —
inclusive um lookup simples de chave primária, que deveria ser trivialmente
cacheável — e o cache estava funcionando perfeitamente. Só não tinha recebido
tabela nenhuma.

Seja qual for a ferramenta de deploy, **verifique que o valor chegou**:

```bash
kubectl -n pgcache-mt exec deploy/pgcache -- printenv ALLOWED_TABLES
```

`PGCACHE_TELEMETRY: off` porque telemetria anônima é tráfego de rede não
controlado dentro de uma janela de medição.

**Três configurações ficam deliberadamente sem definir**, para que o benchmark
meça os padrões do produto e não o nosso tuning: `PINNED_TABLES` (pré-carrega
tabelas e as mantém atualizadas no lugar em vez de invalidar),
`ADMISSION_THRESHOLD` (quantas ocorrências antes de admitir uma entrada) e
`MEMORY_LIMIT`. Ligá-las é um experimento seguinte legítimo — mas é um
experimento *diferente*, e precisa ser rotulado como tal.

### 7.4 O caminho de rede

Os Services são **headless** (`clusterIP: None`) e os pods usam
**`hostNetwork: true`**. Sob hostNetwork o IP do pod *é* o IP do nó, então o DNS
resolve direto para o nó e a conexão pula kube-proxy, NAT e overlay.

Em torno de 1.000 requisições por segundo com oito statements cada, o custo por
pacote de um overlay é fração mensurável do resultado. Incluí-lo significaria
medir Kubernetes em vez de medir o cache.

**Se o seu cluster proíbe hostNetwork** — Pod Security admission frequentemente
proíbe — remova o `clusterIP: None` dos dois Services e as linhas
`hostNetwork`/`dnsPolicy` dos pod specs. Tudo continua funcionando. Os dois
caminhos pagam o custo do overlay igualmente, então a *comparação* segue justa;
as latências absolutas é que serão maiores que as publicadas aqui.

### 7.5 Por que pgbench, e não as quatro alternativas

O fator decisivo em todos os casos foi **como a ferramenta fala com o
PostgreSQL**, verificado lendo o código-fonte de cada uma, não a documentação.

O PgCache precisa do **protocolo simples**: valores interpolados no texto do SQL
em vez de enviados separadamente como parâmetros vinculados. O pgbench faz isso
**por padrão** — `-M simple` é o modo default e nada precisa ser forçado.

Isso parece pequeno e não é. Numa campanha anterior contra uma aplicação real, o
protocolo simples teve que ser forçado *apenas no caminho com cache*. Então o
caminho B não era "caminho A mais um cache" — era "caminho A com prepared
statements desligados, mais um cache", e os dois efeitos não podiam ser
separados. **Nove células da conclusão daquela campanha tiveram que ser
retratadas.** Com o pgbench não há esse confundimento a criar, porque os dois
caminhos rodam o default da própria ferramenta.

As outras tinham, cada uma, um bloqueio:

- O **BenchBase** — o mais atraente no papel, com workloads reais de Wikipedia e
  Twitter — chama `setAutoCommit(false)` no **construtor** do seu `Worker`, uma
  vez, para toda a vida da conexão. Toda leitura de todo workload roda portanto
  dentro de um `BEGIN…COMMIT` explícito, e o **PgCache repassa tudo que está
  dentro de uma transação**. Não é flag, não é ajustável.
- O **HammerDB** roda as transações TPC-C como funções PostgreSQL no servidor. O
  cliente manda uma chamada opaca; o cache nunca vê os statements.
- O **YCSB** duplica o que o pgbench já faz, num protocolo pior.
- O **sysbench** é viável mas exige duas flags não-padrão, e uma delas
  (`--db-ps-mode=disable`) deixa a *origem* mais lenta e lisonjearia o cache pelo
  motivo errado.

### 7.6 Rodando num laptop

O [`infra/docker-compose.yml`](infra/docker-compose.yml) sobe os mesmos três
componentes localmente. A *forma* dos resultados se reproduz; as *magnitudes*
não.

No Kubernetes os três componentes ficam em três máquinas e toda consulta cruza um
salto de rede real. No Docker eles dividem um host e um kernel: o salto é quase
grátis e os três disputam as mesmas CPUs. Medimos essa diferença diretamente numa
campanha anterior — a mesma consulta custou **77 µs num laptop e 167 µs entre nós
no cluster**.

Use o Docker para desenvolver a carga e confirmar que o efeito existe. Use um
cluster para produzir números.

---

## 8. Passo 1 — o esquema

**Arquivo: [`sql/01-schema.sql`](sql/01-schema.sql)**

Sete tabelas com formato de aplicação, não de benchmark.

| tabela | linhas | tamanho | papel |
|---|---:|---:|---|
| `order_item` | 2.000.000 | 184 MB | itens de pedido — a tabela-fato grande |
| `orders` | 500.000 | 48 MB | o centro da carga, escopado por tenant |
| `review` | 300.000 | 41 MB | presente para nem todo join bater nas mesmas tabelas |
| `product` | 200.000 | 22 MB | alvo do join a partir de `order_item` |
| `customer` | 100.000 | 9,6 MB | carrega o `tenant_id` nativo |
| `seller` | 500 | 96 kB | referência pequena |
| `category` | 50 | 32 kB | referência pequena |
| **total** | | **463 MB** | |

### As cardinalidades não são arbitrárias

Cada proporção controla uma propriedade específica da carga:

- **100.000 clientes sobre 200 tenants** = 500 clientes por tenant.
- **500.000 pedidos sobre 100.000 clientes** = 5 cada, ou seja, **2.500 pedidos
  por tenant**. Este é o número que mais importa: é sobre ele que as agregações do
  dashboard rodam, e portanto é ele que define quanto trabalho a origem faz por
  requisição. Poucos demais e a query é trivial; muitos demais e ela deixa de
  parecer um dashboard.
- **2.000.000 de itens sobre 500.000 pedidos** = 4 por pedido, dando cerca de
  10.000 itens por tenant para o statement de join com agregação.

O seed usa `generate_series` e roda inteiramente dentro do servidor — bem menos
de um minuto, sem carregador externo.

Um detalhe deliberado:

```sql
INSERT INTO order_item
SELECT g, 1 + (g % 500000), 1 + (g * 7 % 200000), ...
```

O `g * 7 % 200000` espalha os produtos pelos pedidos. Um `g % 200000` ingênuo
correlacionaria o id do item com o id do produto, tornando o join artificialmente
local e mais barato do que deveria ser.

### Toda chave estrangeira está preenchida

Nenhum NULL em coluna de FK. Não é cosmético: com uma FK toda nula, planejadores
e ORMs pulam o join inteiro, e a carga silenciosamente deixa de exercitar aquilo
que foi escrita para exercitar.

### Os índices são os que um ORM criaria

Um em cada chave estrangeira, mais as colunas por onde a carga filtra. Nada
ajustado à mão.

Isso corta para os dois lados, e é justamente o ponto. Um esquema indexado
*melhor* que uma aplicação real faria a origem parecer artificialmente boa;
indexado *pior*, entregaria uma vitória fácil ao cache. "O que o ORM teria feito"
é o único padrão defensável.

---

## 9. Passo 2 — denormalizar o tenant

**Arquivo: [`sql/02-tenant.sql`](sql/02-tenant.sql)**

Depois do passo 1, só `customer` carrega `tenant_id`. Descobrir o tenant de um
pedido exige voltar via join em `customer`; para um item, dois joins.

Aplicações multi-tenant reais não fazem isso. Elas **copiam o `tenant_id` para
todas as tabelas**, exatamente para que toda query possa filtrar direto, com um
índice e sem join.

```sql
ALTER TABLE orders     ADD COLUMN IF NOT EXISTS tenant_id int;
ALTER TABLE order_item ADD COLUMN IF NOT EXISTS tenant_id int;

UPDATE orders SET tenant_id = 1 + ((customer_id - 1) % 200) WHERE tenant_id IS NULL;
UPDATE order_item oi SET tenant_id = o.tenant_id
  FROM orders o WHERE o.id = oi.order_id AND oi.tenant_id IS NULL;
```

Isso não é só realismo — **protege o experimento**. Se o filtro por tenant
exigisse um join, toda medição incluiria o custo desse join, e a pergunta em
questão (o número de tenants explode o espaço de consultas?) ficaria confundida
por ele.

Leva cerca de 45 segundos: um `UPDATE` sobre 500.000 linhas e outro sobre
2.000.000.

### Os índices compostos, e uma decisão de justiça

```sql
CREATE INDEX orders_tenant_created ON orders(tenant_id, created_at DESC);
CREATE INDEX orders_tenant_status  ON orders(tenant_id, status);
CREATE INDEX oitem_tenant_product  ON order_item(tenant_id, product_id);
```

O primeiro se justifica sozinho. A query de pedidos recentes do dashboard é "os
pedidos deste tenant, mais novos primeiro, os 20 primeiros". Com um índice
simples em `tenant_id`, o banco acha as 2.500 linhas do tenant e depois
**ordena**. Com `(tenant_id, created_at DESC)` o índice já está na ordem
necessária, então o planejador percorre e para em 20 linhas.

**Esta decisão favorece o caminho A.** Sem esses índices a origem seria mais
lenta e o cache pareceria melhor. Adicioná-los é o tipo de vantagem acidental que
um benchmark tem que recusar — você indexa a favor da origem, porque a origem é o
que você diz estar batendo.

Verifique:

```sql
SELECT count(DISTINCT tenant_id) AS tenants,
       count(*) / count(DISTINCT tenant_id) AS orders_per_tenant FROM orders;
--  tenants | orders_per_tenant
--      200 |              2500
```

---

## 10. Passo 3 — a requisição

**Arquivo: [`workload/dashboard.sql`](workload/dashboard.sql)**

Oito statements, todos escopados a um tenant: cartões de resumo, lista de pedidos
recentes, painel de produtos mais vendidos, página de itens.

### As variáveis

```
\set t    random(1, :tenants)     -- qual tenant
\set off  random(0, 9)            -- qual página (10 páginas)
\set st   random(1, 4)            -- qual filtro de status (4 valores)
```

`:tenants` é a variável independente da varredura. `:off` e `:st` são a
variabilidade que uma aplicação real tem *além* do tenant — um usuário navega
pelas páginas e filtra por status, e sob protocolo simples cada combinação é uma
string SQL diferente e portanto uma entrada de cache diferente.

Sem elas, o espaço de consultas seria de 200 entradas por statement e o teste
seria trivialmente fácil. Com elas é 200 × 10 × 4 sobre oito statements —
milhares de entradas distintas. **Esse era o ponto: dar à explosão do espaço de
consultas uma chance real de acontecer.**

### Statement a statement

**1 — Contagem de pedidos por status.** `GROUP BY` sobre os 2.500 pedidos do
tenant.

```sql
SELECT status, count(*) FROM orders WHERE tenant_id = :t GROUP BY status;
```

**2 — Faturamento e contagem.** Duas agregações sobre as mesmas linhas.

**3 — Contagem de clientes.** Outra tabela por outro índice, para que a
requisição não seja atendida inteiramente pelas páginas em cache de uma relação
só.

**4 — A página de pedidos recentes.** Aquilo para o que o índice composto existe.
O `OFFSET` faz de cada página uma entrada distinta.

```sql
SELECT id, status, total, created_at FROM orders WHERE tenant_id = :t
 ORDER BY created_at DESC LIMIT 20 OFFSET :off * 20;
```

**5 — Uma contagem filtrada.** O número ao lado de uma aba de status. `COUNT(*)`
é o alvo clássico de cache: **caro de computar, minúsculo de guardar.**

**6 — Pedidos recentes com o nome do cliente.** Um join de duas tabelas — o que
um ORM emite quando uma listagem mostra um campo de um registro relacionado.

**7 — Produtos mais vendidos.** O statement mais caro: join sobre ~10.000 itens,
`GROUP BY` e ordenação sobre o agregado. Nenhum índice atende isso percorrendo; a
origem tem que fazer o trabalho.

```sql
SELECT p.name, sum(oi.qty)
  FROM order_item oi JOIN product p ON p.id = oi.product_id
 WHERE oi.tenant_id = :t GROUP BY p.name ORDER BY 2 DESC LIMIT 10;
```

**8 — Uma página de itens com nomes de produto.** Join e paginação combinados.

### Não há BEGIN, e isso sustenta o experimento

O pgbench roda com `-M simple` e o script não tem transação, então cada statement
é sua própria transação implícita.

Não é estilo. **O PgCache repassa tudo que está dentro de `BEGIN…COMMIT`** — um
script embrulhado em transação mediria exatamente nada. É a mesma propriedade que
desqualificou o BenchBase na seção 7.5, e vale checar em qualquer aplicação real
antes de assumir que um cache pode ajudá-la.

### Quanto custa antes de qualquer cache

Um cliente, sem concorrência, direto na origem:

```
latency average = 39.511 ms
tps = 25.31
```

**Cerca de 40 milissegundos por requisição.** Não é query de brinquedo — é o que
um dashboard real custa, e três ordens de grandeza mais caro que os point selects
de 0,19 ms que a maioria dos benchmarks de banco usa.

---

## 11. Passo 4 — o protocolo de medição

As medições valem apenas o que vale o protocolo em volta delas.

### Aquecimento: o erro cometido três vezes

**Arquivo: [`scripts/lib.sh`](scripts/lib.sh), função `warm_until_settled`**

Um cache começa frio. Meça cedo demais e você mede o aquecimento, não o cache.
Óbvio — e já produziu resultado publicado errado três vezes distintas neste
laboratório.

- **A campanha retratada.** Existia código de aquecimento adaptativo, que roda
  até a taxa de acerto estabilizar, e a flag que o ligava nunca foi passada. As 52
  execuções registraram 45 segundos de aquecimento enquanto a taxa de acerto ainda
  subia aos dois minutos e meio. **Nove células foram retratadas.**
- **Uma sonda de formas de query**, semanas depois. Um único passe de 15 segundos
  fez um lookup simples de chave primária parecer atingir **19,5%** de acerto e
  perder por 42%. Com aquecimento adequado, a mesma célula chega a **100%** e ganha
  por 38%. O ranking que quase publicamos media velocidade de aquecimento, não
  cacheabilidade.

Então este benchmark não usa aquecimento fixo. Ele repete passes de 30 segundos,
mede a taxa de acerto de cada um, e para quando dois passes consecutivos diferem
por menos de um ponto percentual:

```bash
warm_until_settled() {
  local prev=0 cur
  for p in 1 2 3 4 5; do
    read -r h0 m0 <<<"$(scrape)"
    run "$host" "$port" "$DURATION" "$@" >/dev/null
    read -r h1 m1 <<<"$(scrape)"
    cur=$(awk -v h=$((h1-h0)) -v m=$((m1-m0)) 'BEGIN{printf "%.4f", (h+m)?h/(h+m):0}')
    if awk -v c="$cur" -v q="$prev" 'BEGIN{exit !(c-q < 0.01 && c-q > -0.01)}'; then
      echo "$p"; return 0
    fi
    prev="$cur"
  done
  echo 5
}
```

O número de passes aparece em toda tabela de resultado, para o leitor ver em vez
de confiar.

> **Um passe fixo de aquecimento é um palpite fantasiado de protocolo.**

### Lendo as métricas

O PgCache expõe métricas Prometheus. As duas que importam:

```
pgcache_queries_cache_hit    <contador cumulativo>
pgcache_queries_cache_miss   <contador cumulativo>
```

São **cumulativas** desde o início do processo, então toda medição tira um
*delta* em torno da janela em vez de ler o valor absoluto.

O scrape não sai do gerador de carga: a imagem `postgres:17` não traz `curl` nem
`wget`, e instalar um no start do pod é a fragilidade que matou uma campanha
anterior com `exit 127` no meio. É por isso que
[`infra/k8s/04-metrics-reader.yaml`](infra/k8s/04-metrics-reader.yaml) existe —
um pod Alpine minúsculo cuja única função é servir de ponto de exec para o
scrape.

Mais uma lição de uma rodada anterior: um único scrape com timeout de 10 segundos
estourou sob carga e registrou `ratio=0.0000` em três células. Coletado à mão
depois, o mesmo cache estava a **99,25%**. Uma latência sem a taxa de acerto é
ininterpretável, então um scrape que falha precisa **abortar** a célula, não
gravar um zero que se lê como falha do cache.

### Repetibilidade, medida em vez de presumida

Três células compartilham a mesma configuração nominal — 8 clientes, 200 tenants,
sem escrita — e foram medidas de forma independente, em três varreduras
diferentes:

| medida em | origem | PgCache |
|---|---:|---:|
| varredura de tenants | 83,265 ms | 7,085 ms |
| varredura de concorrência | 83,052 ms | 7,088 ms |
| varredura de escrita | 83,177 ms | 7,100 ms |

**Dispersão de 0,3% na origem e 0,2% no cache.** Essa é a régua para julgar toda
diferença pequena mais adiante — e é o que faz o argumento da seção 14 sobre
concentração de escrita ser outra coisa que não uma afirmação.

---

## 12. Varredura 1 — o número de tenants quebra o cache?

**Script: [`scripts/01-tenant-sweep.sh`](scripts/01-tenant-sweep.sh)**

A hipótese: toda query carregando `WHERE tenant_id` multiplica o espaço de
consultas pelo número de tenants, então a taxa de acerto deve cair conforme os
tenants aumentam.

Concorrência fixa em 8 clientes, para que o número de tenants seja a única
variável.

| tenants ativos | origem | PgCache | ganho | acerto | passes |
|---:|---|---|---:|---:|---:|
| 1 | 79,2 ms · 101 rps | 6,96 ms · 1.149 rps | +1038% | 100% | 2 |
| 10 | 81,2 ms · 99 rps | 7,00 ms · 1.143 rps | +1055% | 100% | 2 |
| 50 | 82,5 ms · 97 rps | 7,07 ms · 1.131 rps | +1066% | 100% | 2 |
| 200 | 83,3 ms · 96 rps | 7,09 ms · 1.129 rps | +1076% | 100% | 3 |

### Como ler isto

Olhe primeiro a coluna de acerto. **Ela não se move.** De um tenant para
duzentos, o cache responde toda consulta do próprio store.

Depois a latência do PgCache: 6,96 ms para 7,09 ms — alta de **1,8%** frente a um
aumento de 200× no número de tenants.

O ganho move 38 pontos percentuais, de +1038% para +1076%, o que sobre uma base
de mil é menos de 4% em termos relativos. E note a direção: move **para cima**,
porque a origem desacelera um pouco mais rápido que o cache.

O único custo visível dos 200 tenants está na última coluna: o aquecimento levou
três passes em vez de dois.

### A hipótese estava errada

Duzentos tenants × dez offsets × quatro status, sobre oito statements, é um
espaço de consultas na casa dos milhares. Foi suficiente para exigir um passe de
aquecimento a mais e nada além disso.

**O espaço de consultas de um SaaS com este formato é grande, mas não grande na
escala que importaria a este cache.**

É um resultado desconfortável de reportar. O cenário foi escolhido para expor um
limite e não expôs. A seção 16 diz até onde essa conclusão pode ser honestamente
esticada — 200 tenants não são 20.000.

---

## 13. Varredura 2 — separando cache de saturação

**Script: [`scripts/02-concurrency-sweep.sh`](scripts/02-concurrency-sweep.sh)**

Um número grande em alta concorrência é **dois efeitos somados**, e só um deles
acompanha o leitor até a casa dele.

| clientes | origem | PgCache | ganho |
|---:|---|---|---:|
| 1 | 32,2 ms · 31 rps | 5,07 ms · 197 rps | **+535%** |
| 4 | 53,5 ms · 75 rps | 5,63 ms · 711 rps | +848% |
| 8 | 83,1 ms · 96 rps | 7,09 ms · 1.129 rps | +1076% |
| 16 | 148,7 ms · 108 rps | 11,80 ms · 1.356 rps | +1156% |
| 32 | 290,6 ms · 110 rps | 23,35 ms · 1.370 rps | +1145% |

### A primeira linha é cache puro

Com um cliente não há fila em lugar nenhum — nem na origem, nem no proxy. Nada
espera por nada. E mesmo assim o PgCache responde em 5,07 ms contra 32,2 ms.

**São 6,4× mais rápido, sem nenhuma ajuda da concorrência.**

Este é o número que se transfere. Quem tem um banco que não está sob pressão deve
esperar algo com esta forma, não a linha de baixo.

### O resto é a origem caindo

Leia a coluna da origem de cima para baixo: 31 para 110 requisições por segundo,
e então para. De 16 para 32 clientes ela ganha **duas** requisições por segundo
enquanto a latência quase dobra, de 148,7 para 290,6 ms.

Saturação de manual: passado o joelho, mais concorrência compra fila, não vazão.

O PgCache, no mesmo intervalo, vai de 1.356 para 1.370 rps, com latência de 11,8
para 23,4 ms. Está se aproximando do próprio limite, mas não virou.

Um dashboard a **290 ms** é um dashboard que o usuário sente como quebrado. O
mesmo dashboard pelo cache responde em **23 ms**.

### Por que os dois efeitos precisam ser reportados separados

Cite só a linha de baixo — "12× mais rápido!" — e você está descrevendo um banco
que já está falhando. É uma situação real e comum, mas é uma afirmação diferente
de "o cache deixa as requisições mais rápidas", e confundir as duas é como
benchmarks enganam.

As duas são verdadeiras. Respondem perguntas diferentes:

- *"Isso deixa meu dashboard mais rápido?"* → **6,4×**, a linha de um cliente.
- *"Isso me salva quando meu banco chega no limite?"* → **12×**, a linha de
  baixo.

---

## 14. Varredura 3 — escrita

**Script: [`scripts/03-write-sweep.sh`](scripts/03-write-sweep.sh)**
**Carga: [`workload/write.sql`](workload/write.sql)**

Uma campanha anterior deste laboratório tinha produzido um resultado
aparentemente devastador, e esta varredura existe para descobrir se ele
generalizava.

### O que a campanha anterior achou

Aquela campanha misturou leitura e escrita sobre uma carga de point select numa
tabela só:

| escrita | origem | PgCache | ganho |
|---:|---:|---:|---:|
| 0% | 36.376 tps | 49.690 tps | **+37%** |
| 10% | 12.573 tps | 12.308 tps | **−2%** |

Numa proporção OLTP perfeitamente banal, a vantagem tinha **sumido**.

### A hipótese testada aqui

Naquela campanha, leituras e escritas batiam nas **mesmas 1.000 chaves** — o pior
caso possível para invalidação. Aplicações reais escrevem num subconjunto pequeno
e leem de um conjunto muito maior.

Então o `write.sql` recebe uma segunda variável:

```
\set t random(1, :wtenants)
```

As leituras sorteiam tenants de `1..200`; as escritas, de `1..:wtenants`. Com
`wtenants=1` toda escrita se concentra num tenant enquanto as leituras varrem os
200.

Se a concentração fosse a explicação, `wtenants=1` deveria parecer muito melhor.

### Os resultados

| escrita | tenants c/ escrita | origem | PgCache | ganho | acerto |
|---:|---:|---|---|---:|---:|
| 0% | — | 83,2 ms · 96 rps | 7,10 ms · 1.127 rps | +1074% | 100% |
| 5% | 1 | 79,0 ms · 101 rps | 7,20 ms · 1.111 rps | +1000% | 100% |
| 5% | 10 | 79,9 ms · 100 rps | 7,30 ms · 1.096 rps | +996% | 100% |
| 5% | 200 | 79,8 ms · 100 rps | 7,50 ms · 1.067 rps | +967% | 100% |
| 10% | 1 | 78,5 ms · 102 rps | 7,42 ms · 1.079 rps | +958% | 100% |
| 10% | 200 | 77,9 ms · 103 rps | 7,55 ms · 1.060 rps | **+929%** | 100% |

**Com 10% de escrita o ganho ainda é +929%**, onde a campanha anterior deu −2%.

### A hipótese da concentração também estava errada

Compare as duas linhas de 10%: concentrada num tenant, **+958%**; espalhada pelos
200, **+929%**.

Vinte e nove pontos percentuais sobre um ganho de cerca de 950 — e a seção 11
mediu a dispersão entre execuções deste benchmark em torno de 0,3%. A diferença é
real mas minúscula. **Concentração não foi o que decidiu a campanha anterior.**

### O que de fato decide: a fatia do relógio

A variável real é a **razão entre custo de leitura e custo de escrita**, e a
aritmética cabe numa linha.

Na campanha anterior, uma leitura custava **0,191 ms** e uma escrita
**4,879 ms** — cerca de 25× mais. Com 10% das transações escrevendo:

```
        0,10 × 4,879
──────────────────────────────  =  0,488 / 0,660  ≈  74%
0,10 × 4,879 + 0,90 × 0,191
```

**Três quartos do relógio eram escrita.** E escritas passam pelos dois caminhos
*identicamente* — o cache não as acelera nem as atrasa. Então ele só podia
competir pelo quarto restante, e nenhuma aceleração de leitura apareceria no
total.

A evidência mais clara de que isso nunca foi efeito de cache: o caminho **sem
cache** também colapsou, de 36.376 tps para 12.573, quando uma transação em dez
virou escrita. O gargalo tinha deixado de ser a leitura para *ambos* os caminhos
ao mesmo tempo.

Aqui a razão está invertida. Uma leitura é um dashboard de oito statements
custando ~79 ms à origem; uma escrita é um `UPDATE` indexado. Na mesma proporção
de 10%, as escritas consomem uma fatia desprezível do relógio.

> **A regra não é "que fração das transações escreve". É "que fração do tempo as
> escritas consomem".** As duas só coincidem quando as leituras são baratas.

O teste corrigido: meça seus custos de leitura e escrita separadamente, calcule
`w·W / (w·W + (1−w)·R)`, e se der acima de mais ou menos a metade, o cache não
alcança a parte da requisição que importa — qualquer que seja a taxa de acerto.

---

## 15. Por que a forma da query decide tudo

Uma sonda rodada logo antes deste benchmark mediu dez formas de query
isoladamente, cada uma contra os dois caminhos:

| forma | origem | PgCache | ganho |
|---|---:|---:|---:|
| lookup por chave primária | 0,228 ms | 0,165 ms | +38% |
| `COUNT(*)` com `WHERE` | 0,241 ms | 0,162 ms | +48% |
| `ORDER BY … LIMIT` | 0,258 ms | 0,174 ms | +48% |
| `GROUP BY` + agregado | 0,259 ms | 0,168 ms | +54% |
| `IN (10 ids)` | 0,261 ms | 0,182 ms | +44% |
| `LEFT JOIN` | 0,292 ms | 0,173 ms | +69% |
| join de duas tabelas | 0,330 ms | 0,171 ms | +92% |
| `EXISTS` correlacionado | 0,392 ms | 0,176 ms | +123% |
| join de três tabelas | 0,431 ms | 0,179 ms | +141% |
| listagem por FK + `LIMIT` | 0,429 ms | 0,163 ms | +163% |

Leia a coluna do PgCache de cima a baixo: **0,162 a 0,182 ms**. Doze por cento de
variação entre a consulta mais barata e a mais cara do conjunto.

Agora a da origem: **0,228 a 0,431 ms**. Oitenta e nove por cento.

> **O PgCache cobra um preço praticamente fixo por resposta. A origem cobra pelo
> trabalho. O ganho é, quase exatamente, quanto trabalho a consulta custa à
> origem.**

Todo o resto decorre dessa única frase.

- Um dashboard multi-tenant — oito statements, agregações, joins sobre milhares
  de linhas de um tenant — custa à origem de 32 a 83 ms e custa ao cache o mesmo
  que qualquer outra resposta. Daí a ordem de grandeza.
- O serviço de autorização da seção 4 era o inverso exato: ~40 µs por consulta na
  origem, nenhum trabalho a economizar, só sobrecarga de proxy multiplicada pela
  amplificação.

Isso também explica por que tantos benchmarks de banco acham caches
decepcionantes. Eles rodam lookups por chave primária, que são a **última linha**
daquela tabela. **A consulta mais barata é o pior caso de um cache.**

---

## 16. O que isto não prova

Cinco limites, e o primeiro é sério.

### O gate de correção não rodou nesta carga

Outras campanhas deste laboratório bloqueavam a publicação de qualquer número de
desempenho até comparar, consulta a consulta, a resposta da origem com a do
cache. **Esta publicou sem isso.**

Aqueles gates sempre passaram — milhares de comparações em três sujeitos, zero
divergências, incluindo um teste que amostrou leituras *enquanto* escritas
estavam em voo e achou 1.931 comparações conclusivas, nenhuma divergente.

Mas esta carga contém formas que aqueles gates nunca exercitaram: joins de duas
tabelas, `GROUP BY` com `ORDER BY`, paginação com `OFFSET`. É precisamente onde
uma divergência seria mais plausível, e está sem teste.

**Rodar um gate diferencial contra esta carga é o item pendente.** Até lá, todo
número aqui está sujeito a ele.

### Só latência média

O pgbench reporta a média nativamente; percentis exigem registro por transação,
que esta rodada não coletou. Para uma afirmação sobre latência, a média é a
estatística mais fraca disponível, porque o dano de um cache mora na cauda — um
miss custa várias vezes um hit.

Duas regras que valem carregar, se você acrescentar percentis: filtre-os para o
script de leitura quando houver escrita na mistura (senão você está descrevendo
flush de WAL), e **recuse** reportar abaixo de algumas centenas de amostras. Essa
segunda regra foi aprendida do jeito honesto — uma célula lenta produziu um "p99"
de 296 ms contra uma **média de 794 ms**, aritmeticamente impossível, e foi o
sinal de que quatro amostras não são medição.

### Um só tamanho de dados, e ele cabe na memória

463 MB contra 1 GB de `shared_buffers`. Como a seção 7.2 explicou, esse é o caso
mais difícil para o cache e o resultado é conservador nesse eixo — mas nada aqui
diz o que acontece quando o conjunto de dados excede a memória da origem.

### Duzentos tenants não são vinte mil

A curva ficou plana de 1 a 200. Nada garante que continue plana em 20.000, onde o
espaço de consultas é duas ordens de grandeza maior. **A planura desta curva não
é licença para extrapolar.**

### Não há cache de aplicação na comparação

Isto mede um cache contra um banco *sem cache*. Muitas aplicações reais já
cacheiam no próprio processo ou no Redis, e um cache desses **elimina** a
consulta em vez de acelerá-la — coisa diferente e frequentemente mais forte.

Este benchmark não consegue fazer essa comparação, porque não há aplicação aqui.
Ele mede o envelope do produto sob carga com formato de aplicação. **Não é um
veredito de adoção.**

---

## 17. Apêndice: todos os arquivos

```
pgcache-multi-tenant/
├── README.md                        versão em inglês
├── README-pt.md                     este documento
├── infra/
│   ├── k8s/
│   │   ├── 00-namespace-and-secret.yaml
│   │   ├── 01-origin.yaml           PostgreSQL, cada flag explicada
│   │   ├── 02-pgcache.yaml          o cache, cada variável explicada
│   │   ├── 03-loadgen.yaml          pgbench + volume de resultados
│   │   └── 04-metrics-reader.yaml   o pod que consegue ler as métricas
│   ├── helm/
│   │   └── pgcache-mt/              Helm chart para deploy no Kubernetes
│   └── docker-compose.yml           setup de laptop (forma, não magnitudes)
├── sql/
│   ├── 01-schema.sql                7 tabelas, seed, índices estilo ORM
│   └── 02-tenant.sql                denormalização do tenant_id + índices
├── workload/
│   ├── dashboard.sql                a requisição de 8 statements
│   └── write.sql                    a escrita, com :wtenants
├── scripts/
│   ├── lib.sh                       scrape, run, warm_until_settled, cell
│   ├── 00-setup.sh                  aplica o esquema, copia a carga para o pod
│   ├── 01-tenant-sweep.sh
│   ├── 02-concurrency-sweep.sh
│   ├── 03-write-sweep.sh
│   └── run-tag-verification.sh      script automatizado de verificação por tag
├── data/
│   └── results.tsv                  as 15 células, legível por máquina
└── results/                         resultados por versão/tag
    ├── README.md                    comparação entre versões (inglês)
    ├── README-pt.md                 comparação entre versões (português)
    ├── 0.6.3/                       resultados para PgCache 0.6.3
    ├── 0.6.4/                       resultados para PgCache 0.6.4
    └── 0.7.0/                       resultados para PgCache 0.7.0
```

### Uma nota sobre os scripts

A campanha, como de fato rodou, foi dirigida por bash ad-hoc digitado num prompt,
e o SQL vivia em `/tmp` dentro de um pod. Os scripts aqui são equivalentes limpos
que executam as mesmas medições, com os mesmos parâmetros, na mesma ordem — não
são transcrição literal.

Essa lacuna vale registrar por si só. Um benchmark cujos artefatos existem apenas
dentro de um pod em execução não é reproduzível, e ninguém percebe até o pod
sumir. Este repositório existe em parte para fechá-la.
