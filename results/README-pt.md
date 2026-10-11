# Resultados da Verificação Multi-Versão do PgCache

> 🇺🇸 **[English version](README.md)**

Este diretório contém os resultados das execuções de benchmark comparando versões do **PgCache** executadas em um cluster real no **DigitalOcean Kubernetes (DOKS)**:
- [**PgCache 0.6.3**](0.6.3/README-pt.md)
- [**PgCache 0.6.4**](0.6.4/README-pt.md)
- [**PgCache 0.7.0**](0.7.0/README-pt.md)

Todos os testes foram executados na carga multi-tenant de SaaS (500k pedidos, 2M itens, distribuídos em 2.000 tenants, 8 declarações por consulta de dashboard, 8 clientes concorrentes) utilizando o protocolo de aquecimento dinâmico (`warm_until_settled`).

---

## 1. Infraestrutura Cloud e Especificações

- **Provedor Cloud**: DigitalOcean Kubernetes (DOKS)
- **Região**: `sfo3` (topologia de zona única / single-AZ, colocando os 3 nós no mesmo datacenter)
- **Nós**: 3 Droplets dedicados tamanho `s-4vcpu-8gb` (4 vCPUs AMD64, 8 GB RAM cada, ~$0,071/hora cada = ~$0,21/hora total)
- **Alta Disponibilidade**: `--ha=false` (taxa de control plane a $0)
- **Sistema Operacional dos Nós**: Debian GNU/Linux 13 (trixie), kernel 6.12.96, containerd 2.3.3
- **Armazenamento**: Provisionador CSI `do-block-storage` (`dobs.csi.digitalocean.com`)
- **Isolamento de Pods**: `podAntiAffinity` estrito no Kubernetes garantindo nós físicos separados para `origin`, `pgcache` e `loadgen`
- **Rede**: `hostNetwork: true` (ligação direta ao IP do nó, evitando encapsulamento e overhead de overlay de rede)
- **PostgreSQL Origem**: Versão 17 (`postgres:17`), requests: 2500m CPU / 5Gi RAM, `shared_buffers=512MB`, `max_connections=500`, `work_mem=16MB`, `maintenance_work_mem=256MB`, `random_page_cost=1.1`, `wal_level=logical`
- **Configuração PgCache**: Requests: 2500m CPU / 5Gi RAM, 4 threads de trabalho, porta 6432, `METRICS_PORT=9091` (ajustado para evitar conflito com a porta 9090 do Cilium no DO), tabelas permitidas: `product,category,seller,customer,orders,order_item,review`
- **Gerador de Carga**: `postgres:17` com pgbench rodando protocolo simples (`-M simple`), sem transações explícitas (`BEGIN...COMMIT`), 8 clientes concorrentes, 4 threads, janelas de medição de 30s

---

## 2. Comparativo de Varredura de Tenants (1 a 2.000 Tenants)

O Sweep 1 avaliou a explosão do espaço de chaves à medida que os tenants ativos escalaram de 1 para 2.000:

| Tenants Ativos | Origem (Caminho A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | Hit Ratio (Todos) | Passos de Aquecimento |
|---|---|---|---|---|---|---|
| **1 Tenant** | 23,3–27,5 ms (291–343 rps) | **17,6 ms** (455 rps, +56%) | **16,8 ms** (476 rps, +61%) | **15,6 ms** (513 rps, +50%) | **100,0%** | 2 |
| **10 Tenants** | 23,9–27,7 ms (288–335 rps) | **17,8 ms** (451 rps, +52%) | **21,0 ms** (382 rps, +33%) | **22,9 ms** (349 rps, +4%) | **100,0%** | 2 |
| **50 Tenants** | 28,5–29,9 ms (267–281 rps) | **17,5 ms** (456 rps, +66%) | **15,8 ms** (506 rps, +90%) | **17,3 ms** (462 rps, +64%) | **100,0%** | 2 |
| **100 Tenants** | 25,2–30,3 ms (264–317 rps) | **19,4 ms** (412 rps, +56%) | **16,3 ms** (492 rps, +55%) | **17,2 ms** (465 rps, +51%) | **100,0%** | 2 |
| **500 Tenants** | 25,7–32,2 ms (248–311 rps) | **16,7 ms** (478 rps, +93%) | **15,7 ms** (510 rps, +71%) | **18,7 ms** (428 rps, +38%) | **100,0%** | 3 |
| **1.000 Tenants** | 24,5–26,2 ms (305–326 rps) | **17,5 ms** (458 rps, +50%) | **16,8 ms** (476 rps, +46%) | **17,2 ms** (466 rps, +52%) | **100,0%** | 3 |
| **2.000 Tenants** | 25,6–26,0 ms (308–313 rps) | **18,3 ms** (438 rps, +40%) | **15,5 ms** (515 rps, +67%) | **18,8 ms** (425 rps, +38%) | **100,0%** | 4 |

---

## 3. Principais Descobertas

1. **Taxa de Acerto de 100,0% Ininterrupta até 2.000 Tenants**:
   Todas as versões avaliadas (0.6.3, 0.6.4, 0.7.0) mantiveram uma taxa de acerto perfeita de **100,0%** em todas as faixas de tenants até 2.000 tenants ativos. A expansão de 2.000× no espaço de chaves multi-tenant não saturou a memória nem causou thrashing no cache.

2. **Crescimento Previsível de Aquecimento**:
   O protocolo de aquecimento adaptativo (`warm_until_settled`) se ajustou automaticamente ao tamanho do conjunto de chaves:
   - De 1 a 100 tenants foram necessários **2 passos** (60 segundos).
   - De 500 a 1.000 tenants foram necessários **3 passos** (90 segundos).
   - Com 2.000 tenants foram necessários **4 passos** (120 segundos).
   Nenhuma célula necessitou do limite máximo de 5 passos para estabilizar a variação abaixo de 1%.

3. **Performance entre as Versões**:
   - O **PgCache 0.6.4** obteve a maior vazão com 2.000 tenants: **515 rps (15,5 ms)** vs 308 rps (26,0 ms) na origem (**+67% de ganho de vazão**).
   - O **PgCache 0.7.0** alcançou a menor latência com 1 tenant: **15,6 ms (513 rps)**, mantendo ganhos de +38% a +64% em grupos maiores de tenants.
   - O **PgCache 0.6.3** atingiu o maior ganho de pico com 500 tenants: **478 rps (16,7 ms)** vs 248 rps (32,2 ms) na origem (**+93% de ganho de vazão**).

---

## 4. Estrutura de Diretórios por Tag

- [`0.6.3/`](0.6.3/README-pt.md): Resultados completos, TSV e logs brutos da tag `0.6.3`.
- [`0.6.4/`](0.6.4/README-pt.md): Resultados completos, TSV e logs brutos da tag `0.6.4`.
- [`0.7.0/`](0.7.0/README-pt.md): Resultados completos, TSV e logs brutos da tag `0.7.0`.
