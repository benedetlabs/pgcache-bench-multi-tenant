# Benchmark do PgCache 0.7.1 em um SaaS Multi-Tenant: O Que Realmente Acontece em um Cluster de 3 Nós na Nuvem

> 🇺🇸 **[Read in English](README.md)**

Quando alguém mostra um benchmark de cache de banco de dados, os números geralmente parecem bons demais para ser verdade. Na maioria das vezes, isso acontece porque o teste rodou em um único notebook — onde o cliente, o cache e o banco dividiam a mesma CPU e conversavam via `localhost` em microssegundos — ou porque o teste avaliou apenas 1 cliente fazendo buscas simples por chave primária.

Este relatório conta, de forma direta e transparente, o que acontece quando colocamos o **PgCache 0.7.1** na frente do **PostgreSQL 17** sob condições reais de um SaaS multi-tenant:
- **Isolamento físico real na nuvem**: 3 nós dedicados no DigitalOcean Kubernetes (`s-4vcpu-8gb`, sendo uma VM exclusiva para o PostgreSQL, uma para o PgCache e uma para o gerador de carga). O Docker local é usado exclusivamente para testar a corretude do SQL, nunca para publicar números de performance.
- **Telas reais de SaaS**: Desde um dashboard operacional leve de 8 consultas até telas corporativas pesadas com busca textual por substring (`ILIKE '%...%'`), `INNER JOIN` e `LEFT JOIN` entre 4 a 6 tabelas, e agregações analíticas com `GROUP BY` e `HAVING`.
- **Sem sorte de corrida única**: Cada cenário da nossa bateria estatística foi executado **5 vezes independentes (`TRIALS=5`)**, destruindo e recriando todos os pods (`origin`, `pgcache` e `loadgen`) antes de cada rodada para medir tanto o **ganho médio** quanto a **variação real** entre execuções.

---

## 1. Resumo Direto ao Ponto (TL;DR)

1. **Zero Respostas Erradas**: Antes de medir velocidade, nosso script de verificação ([`scripts/verify-correctness.sh`](../../scripts/verify-correctness.sh)) compara o resultado de cada consulta byte a byte entre o PostgreSQL e o PgCache. Todas as **8 consultas do dashboard básico** e todas as **12 consultas complexas** retornaram linhas 100% idênticas — tanto antes quanto imediatamente após escritas ao vivo (`UPDATE` e `INSERT`).
2. **Consultas Simples vs. Consultas Pesadas (1,9× vs. 29× mais rápido)**:
   - No **dashboard operacional leve** (`dashboard.sql`), o PostgreSQL já responde rápido (~58 ms para 8 consultas). Ainda assim, o PgCache praticamente **dobra a capacidade (+98%, subindo de 146 para 273 telas/s)**.
   - Nas **telas corporativas pesadas** (joins de 4 a 6 tabelas, buscas com `ILIKE` e relatórios analíticos), o PostgreSQL sofre varrendo e juntando tabelas (130 a 308 ms por tela). O PgCache pré-computa essas visões em memória (Materialized Views) e entrega a tela inteira em **7 a 23 ms** — um salto de **15× a 29× mais vazão (+1.400% a +2.839%)**.
3. **Por que a Regra 80/20 do Mundo Real Salva Clusters com Muitos Tenants**:
   - Se mais de 1.000 tenants dispararem consultas pesadas com probabilidade 100% uniforme a partir de um cache frio, o cache passa o tempo todo tentando popular todos os tenants de uma vez.
   - Mas o tráfego real de um SaaS segue a **regra de Pareto 80/20** (20% dos clientes geram 80% dos acessos). Quando testamos **2.000 tenants** com distribuição Zipfian 80/20, os tenants mais ativos aqueceram rápido (**64,1% de acerto no cache**) e o PgCache manteve vantagem mesmo partindo do zero.
4. **Onde o Cache Sofre (Partida Fria com Escritas Pesadas)**:
   - Quando o cache já está aquecido, ele lida bem com 5% a 10% de atualizações (`UPDATE`), mantendo **63% a 75% de acerto**.
   - Porém, se você reiniciar o cache **totalmente frio** enquanto bombardeia o banco simultaneamente com `UPDATE orders` e `INSERT INTO order_item`, as invalidações contínuas de replicação brigam com o carregamento inicial do cache, derrubando a vazão abaixo do PostgreSQL puro (**-85%**). **Lição prática**: aqueça o cache com leituras antes de virar a chave de um tráfego intenso de escrita + leitura.

---

## 2. Como Ler as Tabelas

Cada "requisição" neste benchmark não é uma consulta SQL isolada — é o **carregamento completo de uma tela de SaaS**, composta por **4 a 8 consultas SQL executadas em sequência**:
- **Caminho A (PostgreSQL Direto)**: A aplicação conversa direto com o PostgreSQL.
- **Caminho B (PgCache 0.7.1)**: A aplicação conversa com o PgCache.
- **Telas/s (RPS)**: Quantas telas completas o sistema entregou por segundo com 8 clientes simultâneos.
- **Variação (`-Δ/+Δ` e `sd`)**: Nas 5 rodadas com recriação completa dos pods, `-Δ/+Δ` mostra o quanto a pior e a melhor rodada variaram em relação à média, e `sd` é o desvio padrão.

---

## 3. Resultados Multi-Trial: 5 Rodadas Recriando Todos os Pods (`TRIALS=5`)

Nesta bateria, antes de cada uma das 5 rodadas, o script limpou os registros inseridos e reiniciou do zero os pods do PostgreSQL, do PgCache e do gerador de carga.

Logs brutos: [`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt) · [`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt) · [`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt)

| O Que Testamos (200 Tenants, 8 Clientes) | PostgreSQL Direto (Caminho A) | PgCache 0.7.1 (Caminho B) | Taxa de Acerto (Hit) | Ganho Médio (Faixa nas 5 Rodadas) |
|---|---|---|---:|---|
| **Dashboard Operacional Leve** (`dashboard.sql`, 8 consultas) | 57,8 ms · **146 telas/s** *(±40,5 sd)* | **29,4 ms · 273 telas/s** *(±16,3 sd)* | **100,0%** | **1,98× mais rápido (+98%)** *(-68% / +69%)* |
| **Busca Textual por Substring** (`complex-search.sql`, 4 `ILIKE` + joins) | 129,6 ms · **63 telas/s** *(±9,2 sd)* | **6,9 ms · 1.170 telas/s** *(±126,1 sd)* | **100,0%** | **18,8× mais rápido (+1.778%)** *(-266% / +243%)* |
| **Joins Profundos de 4 a 6 Tabelas** (`complex-joins.sql`, `INNER` e `LEFT JOIN`) | 238,9 ms · **34 telas/s** *(±2,8 sd)* | **8,2 ms · 991 telas/s** *(±160,6 sd)* | **100,0%** | **29,4× mais rápido (+2.839%)** *(-666% / +443%)* |
| **Analytics Multidimensional** (`complex-analytics.sql`, `GROUP BY / HAVING`) | 175,3 ms · **46 telas/s** *(±4,1 sd)* | **9,0 ms · 905 telas/s** *(±122,1 sd)* | **100,0%** | **19,8× mais rápido (+1.883%)** *(-395% / +267%)* |
| **Tela Corporativa Completa (Uniforme)** (`complex-dashboard.sql`, 8 consultas pesadas) | 307,5 ms · **26 telas/s** *(±1,2 sd)* | **23,4 ms · 389 telas/s** *(±132,6 sd)* | **100,0%** | **15,0× mais rápido (+1.400%)** *(-766% / +684%)* |
| **Tela Corporativa (Pareto 80/20, 200 Tenants)** (`complex-dashboard-zipfian.sql`) | 339,2 ms · **24 telas/s** *(±4,1 sd)* | **76,0 ms · 267 telas/s** *(±191,3 sd)* | **97,5%** | **11,5× mais rápido (+1.051%)** *(-1.016% / +917%)* |
| **Tela Corporativa (Pareto 80/20, 2.000 Tenants)** (`complex-dashboard-zipfian.sql`) | 373,1 ms · **22 telas/s** *(±1,9 sd)* | **351,2 ms · 24 telas/s** *(±5,4 sd)* | **64,1%** | **1,09× mais rápido (+9%)** *(-26% / +30%)* |
| **Partida Fria + 5% Escritas (`UPDATE` + `INSERT`)** (`complex-dashboard` + `write.sql`) | 327,9 ms · **25 telas/s** *(±2,7 sd)* | 2.995,5 ms · **3 telas/s** *(±2,6 sd)* | **32,4%** | **0,15× (-85% mais lento)** *(-8% / +23%)* |

### O Que Esses Números de 5 Rodadas Nos Ensinam

- **Por que a diferença entre consultas leves e pesadas é tão grande**: Em 3 VMs separadas na nuvem, cada consulta SQL paga ~0,7 ms só para atravessar a rede. Uma tela de 8 consultas paga **~5,6 ms de puro trânsito de rede**, não importa quão rápido seja o banco. No dashboard leve (`57,8 ms` no PostgreSQL), o trânsito de rede e o parse básico do SQL consomem metade da economia possível, então o PgCache entrega **+98%**. Já nos joins de 4 a 6 tabelas (`238,9 ms` no PostgreSQL), as Materialized Views do PgCache transformam árvores pesadas de join em uma leitura simples de memória (`8,2 ms`), saltando para **29,4× mais velocidade (+2.839%)**.
- **Como duas pequenas expressões SQL estavam escondendo o ganho do baseline**: Nas rodadas antigas, duas consultas em `dashboard.sql` faziam contas dentro do SQL (`OFFSET :off * 20` e `(ARRAY[...])[:st]`). O PgCache marcava essas duas consultas como não-cacheáveis e as repassava ao PostgreSQL, travando o ganho do baseline. Ao pré-calcular esses dois números antes de enviar o SQL, a taxa de acerto subiu para **100,0% reais** e a vazão dobrou para **273 telas/s (+98%)**.
- **Por que rodar 5 vezes faz toda a diferença**: No teste Zipfian com 200 tenants, 4 das 5 rodadas bateram **99,3% a 100% de acerto (166 a 472 telas/s)**, enquanto a Rodada 4 estabilizou um pouco antes com **88,3% (31 telas/s)**. Se tivéssemos rodado apenas 1 vez, poderíamos ter publicado 472 telas/s ou 31 telas/s por pura sorte; com 5 rodadas independentes, enxergamos a média real (**267 telas/s, 11,5× mais rápido**) e a faixa honesta de variação.

---

## 4. Análise Detalhada: Varreduras de Escala no Cluster de 3 Nós (DOKS)

Além da bateria de 5 trials acima, executamos varreduras completas variando a quantidade de tenants, o número de usuários simultâneos e a taxa de escrita.

### 4.1 Escalando de 1 até 2.000 Tenants no Dashboard Leve

Multiplicar o número de clientes ativos por 2.000 derruba o cache em consultas operacionais? Não — após o aquecimento, o PgCache mantém **100,0% de acerto** de 1 até 2.000 tenants.

Log bruto: [`run-tenants-doks.txt`](run-tenants-doks.txt) · TSV: [`results-doks.tsv`](results-doks.tsv)

| Tenants Ativos | PostgreSQL Direto (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Taxa de Acerto | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| **1** | 23,3 ms · 343 telas/s | **16,6 ms · 481 telas/s** | **+40%** | 100,0% | 2 |
| **10** | 22,9 ms · 350 telas/s | **21,7 ms · 369 telas/s** | **+5%** | 100,0% | 2 |
| **50** | 25,4 ms · 315 telas/s | **17,0 ms · 470 telas/s** | **+49%** | 100,0% | 3 |
| **100** | 26,5 ms · 302 telas/s | **16,3 ms · 491 telas/s** | **+63%** | 100,0% | 3 |
| **500** | 24,4 ms · 329 telas/s | **16,3 ms · 490 telas/s** | **+49%** | 100,0% | 4 |
| **1.000** | 24,0 ms · 333 telas/s | **16,9 ms · 473 telas/s** | **+42%** | 100,0% | 4 |
| **2.000** | 23,3 ms · 343 telas/s | **16,5 ms · 485 telas/s** | **+41%** | 100,0% | 6 |

---

### 4.2 Escalando Tenants na Tela Corporativa Pesada (`1` a `1.000` Tenants Uniformes)

Na tela corporativa pesada de 8 consultas (`complex-dashboard.sql`), cada tenant cria 8 Materialized Views multi-tabela. De **1 até 500 tenants ativos (4.000 visões)**, o PgCache aquece 100% dos dados e entrega **12× a 22× mais vazão**.

Log bruto: [`run-complex-tenants-doks.txt`](run-complex-tenants-doks.txt)

| Tenants Ativos (Uniforme) | PostgreSQL Direto (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Taxa de Acerto | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| **1** | 206,8 ms · 39 telas/s | **9,2 ms · 871 telas/s** | **22,3× (+2.133%)** | 100,0% | 2 |
| **10** | 198,2 ms · 40 telas/s | **9,6 ms · 835 telas/s** | **20,9× (+1.988%)** | 100,0% | 2 |
| **50** | 227,5 ms · 35 telas/s | **10,8 ms · 740 telas/s** | **21,1× (+2.014%)** | 100,0% | 6 |
| **200** | 212,8 ms · 38 telas/s | **11,2 ms · 712 telas/s** | **18,7× (+1.774%)** | 100,0% | 7 |
| **500** | 223,9 ms · 36 telas/s | **18,4 ms · 435 telas/s** | **12,1× (+1.108%)** | 100,0% | 8 |
| **1.000** *(teto de 8 passes)* | 210,1 ms · 38 telas/s | 251,4 ms · 32 telas/s | 0,84× (-16%) | 68,1% | 4 |

> **Por que o sorteio 100% uniforme desacelera em 1.000 tenants (e por que testamos 2.000 tenants com Pareto 80/20 na Seção 3)**: Quando sorteamos 1.000 tenants com probabilidade exatamente igual em janelas curtas de 15 segundos, o cache precisa construir 8.000 visões pesadas ao mesmo tempo, chegando a 68,1% de acerto antes do limite de aquecimento. Quando o tráfego segue a regra real 80/20 (`z_tenants=2000` na Seção 3), os clientes mais ativos aquecem primeiro e mantêm o PgCache na frente mesmo com **2.000 tenants**.

---

### 4.3 Escalando Usuários Simultâneos (`1` a `32` Clientes na Tela Pesada)

O que acontece quando o tráfego sobe de 1 usuário para 32 usuários simultâneos?
- Com **1 cliente**, não há fila de CPU em lugar nenhum: o PgCache responde uma tela de 100,6 ms em **7,1 ms (14,0× mais rápido)**.
- Com **32 clientes**, as 4 vCPUs do PostgreSQL saturam em **38 telas/s** e o tempo de resposta dispara para **835,5 ms** (quase 1 segundo inteiro por tela). O PgCache absorve a leitura em memória e entrega **1.020 telas/s (mais de 8.160 consultas SQL complexas por segundo)** a **31,4 ms (26,8× mais rápido)**.

Log bruto: [`run-complex-clients-doks.txt`](run-complex-clients-doks.txt)

| Clientes Simultâneos | PostgreSQL Direto (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Taxa de Acerto |
|---:|---|---|---:|---:|
| **1** | 100,6 ms · 10 telas/s | **7,1 ms · 140 telas/s** | **14,0× (+1.300%)** | 100,0% |
| **4** | 129,5 ms · 31 telas/s | **8,6 ms · 465 telas/s** | **15,0× (+1.400%)** | 100,0% |
| **8** | 212,8 ms · 38 telas/s | **10,5 ms · 763 telas/s** | **20,1× (+1.908%)** | 100,0% |
| **16** | 406,9 ms · 39 telas/s | **18,1 ms · 886 telas/s** | **22,7× (+2.172%)** | 100,0% |
| **32** | 835,5 ms · 38 telas/s | **31,4 ms · 1.020 telas/s** | **26,8× (+2.584%)** | 100,0% |

---

### 4.4 O Que Acontece Quando os Dados Mudam? (Cache Aquecido vs. Escritas ao Vivo)

Quando o cache **é aquecido primeiro** e depois recebe 5% ou 10% de tráfego de escrita (`UPDATE orders`), vemos um comportamento muito interessante dentro das 8 consultas da tela corporativa:
- **5 das 8 consultas (`62,5%`) usam `INNER JOIN`**: Como elas filtram diretamente por `WHERE o.tenant_id = :t`, o PgCache atualiza os dados daquele tenant diretamente na memória via replicação lógica (CDC) e reconstrói apenas a visão daquele tenant em segundo plano. Essas 5 consultas continuam com **100% de acerto no cache**.
- **3 das 8 consultas (`37,5%`) usam `LEFT JOIN`**: Para preservar clientes que ainda não têm nenhum pedido (`LEFT JOIN orders o ON ... AND o.tenant_id = :t`), o filtro do tenant fica dentro da cláusula `ON` do join externo. Sempre que a tabela `orders` recebe uma escrita, o PgCache invalida de forma conservadora essas 3 consultas.

Por isso, a taxa de acerto global se estabiliza entre **63% e 75%**:

Log bruto: [`run-complex-writes-doks.txt`](run-complex-writes-doks.txt)

| Proporção de Escrita | Tenants Recebendo Escrita | PostgreSQL Direto (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho / Perda | Taxa de Acerto |
|---:|---:|---|---|---:|---:|
| **0% (Só Leitura)** | — | 189,8 ms · 42 telas/s | **11,1 ms · 719 telas/s** | **+1.612% (17,1×)** | 100,0% |
| **5% Escrita** | 1 tenant quente | 186,7 ms · 43 telas/s | **166,2 ms · 48 telas/s** | **+12%** | 75,0% |
| **5% Escrita** | 10 tenants | 182,4 ms · 44 telas/s | 194,4 ms · 41 telas/s | -7% | 65,4% |
| **5% Escrita** | Todos os 200 tenants | 191,2 ms · 42 telas/s | 201,5 ms · 40 telas/s | -5% | 65,7% |
| **10% Escrita** | 1 tenant quente | 177,7 ms · 45 telas/s | **154,7 ms · 52 telas/s** | **+16%** | 63,1% |
| **10% Escrita** | Todos os 200 tenants | 167,9 ms · 48 telas/s | 191,8 ms · 42 telas/s | -12% | 64,8% |

---

## 5. Verificação de Corretude em 3 Estágios (Zero Respostas Diferentes)

Antes de confiar em qualquer número de performance, o script [`scripts/verify-correctness.sh`](../../scripts/verify-correctness.sh) executa três verificações rigorosas ([`verify-correctness-doks.txt`](verify-correctness-doks.txt)):

| Estágio | O Que é Verificado | Resultado no DOKS (3 Nós) |
|---|---|---|
| **Estágio 1: Consultas Básicas (8/8)** | Roda todas as 8 consultas do `dashboard.sql` no PostgreSQL e no PgCache e compara cada linha byte a byte. | **APROVADO (8/8 idênticas, 0 fora do cache)** |
| **Estágio 2: Consultas Complexas Estáticas (12/12)** | Roda todas as 12 consultas complexas em 3 passagens (miss inicial, hit na tabela-base e hit na Materialized View). | **APROVADO (12/12 idênticas, 100% hit em MV)** |
| **Estágio 3: Mutação CDC ao Vivo (`UPDATE` + `INSERT`)** | Executa `UPDATE orders`, `UPDATE order_item` e `INSERT INTO order_item` ao vivo no PostgreSQL, aguarda a replicação CDC e confere novamente as 12 consultas complexas no PgCache. | **APROVADO (12/12 idênticas após escritas)** |

---

## 6. Arquivos Brutos e Logs do Benchmark

- **Logs da Bateria Multi-Trial (`TRIALS=5`, com Recriação Completa dos Pods)**:
  - Cenários Complexos (`TRIALS=5`): [`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt)
  - Distribuição Pareto/Zipfian 80/20 (`TRIALS=5`): [`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt)
  - Escrita Concorrente `UPDATE + INSERT` em Partida Fria (`TRIALS=5`): [`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt)
- **Logs de Varredura e Corretude no Cluster DOKS (3 Nós)**:
  - Saída do Gate de Corretude: [`verify-correctness-doks.txt`](verify-correctness-doks.txt)
  - Varredura de Tenants Baseline (`1..2000`): [`run-tenants-doks.txt`](run-tenants-doks.txt) · [`results-doks.tsv`](results-doks.tsv)
  - Comparativo de Cenários Complexos: [`run-complex-scenarios-doks.txt`](run-complex-scenarios-doks.txt) · [`results-complex-doks.tsv`](results-complex-doks.tsv)
  - Escala de Tenants Complexos (`1..1000`): [`run-complex-tenants-doks.txt`](run-complex-tenants-doks.txt)
  - Escala de Concorrência (`1..32` clientes): [`run-complex-clients-doks.txt`](run-complex-clients-doks.txt)
  - Escritas com Cache Aquecido: [`run-complex-writes-doks.txt`](run-complex-writes-doks.txt)
