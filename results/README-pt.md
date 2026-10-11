# Resultados da Verificação de Múltiplas Versões do PgCache

> 🇺🇸 **[English version](README.md)**

Este diretório contém as execuções de verificação comparando as novas versões do **PgCache**:
- [**PgCache 0.6.3**](0.6.3/README-pt.md)
- [**PgCache 0.6.4**](0.6.4/README-pt.md)
- [**PgCache 0.7.0**](0.7.0/README-pt.md)

Todos os testes foram executados com a carga de trabalho multi-tenant de SaaS (500 mil pedidos, 2 milhões de itens de pedidos, 200 tenants, 8 instruções SQL por requisição de dashboard) utilizando o protocolo de aquecimento dinâmico (`warm_until_settled`).

---

## 1. Resumo Comparativo Entre Versões (Carga de 1.000 Tenants)

| Métrica / Cenário | Origem (Caminho A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 |
|---|---|---|---|---|
| **Taxa de Acerto (Hit Ratio)** | N/A | **100,0%** | **100,0%** | **100,0%** (1..500t) / **99,7%** (1.000t) |
| **Latência com 1 Cliente** | 10,5–11,5 ms | **5,53 ms** (2,0× mais rápido) | **5,15 ms** (2,1× mais rápido) | **5,55 ms** (2,1× mais rápido) |
| **Latência com 8 Clientes (Leitura)** | 35,4–38,1 ms | **14,62 ms** (+142%) | **15,34 ms** (+149%) | **14,90 ms** (+145%) |
| **Vazão Máxima (32 clientes)** | 297–307 rps | **711 rps** (+138%) | **748 rps** (+144%) | **626 rps** (+111%) |
| **Resiliência a Escrita (5% esc, 1 wt)** | 239–249 rps | **575 rps** (+141%) | **598 rps** (+140%) | **408 rps** (+66%) |
| **Resiliência a Escrita (10% esc, 1000 wt)** | 251–268 rps | **603 rps** (+140%) | **631 rps** (+135%) | **318 rps** (+24%) |

---

## 2. Observações Principais

1. **Cacheabilidade das Consultas em 1.000 Tenants**:
   Todas as versões avaliadas demonstraram excelente retenção de cache sob o espaço ampliado de 1.000 tenants. As versões **0.6.3** e **0.6.4** sustentaram **100,0% de hit ratio** em todos os 1.000 tenants. Na versão **0.7.0**, o hit ratio atingiu **100,0%** até 500 tenants e **99,7%** em 1.000 tenants com 5 passes de aquecimento.

2. **Escala de Vazão e Concorrência**:
   O ganho em leituras foi altamente consistente entre as três versões (~522–547 rps com 8 clientes, até ~626–748 rps com 32 clientes), reduzindo a latência à metade em todos os níveis de concorrência.

3. **Perfis de Invalidação de Escrita por CDC**:
   As versões **0.6.3** e **0.6.4** sustentaram mais de 600 rps sob proporção de 10% de escrita. A versão **0.7.0** apresentou maior consumo de CPU em segundo plano na máquina local compartilhada no Docker durante o CDC sob escritas concorrentes (sustentando 318 rps), cenário que terá isolamento pleno no cluster Kubernetes com 3 nós físicos dedicados.

---

## 3. Estrutura de Diretórios por Tag

- [`0.6.3/`](0.6.3/): Resultados detalhados, TSV e saídas brutas da versão `0.6.3`.
- [`0.6.4/`](0.6.4/): Resultados detalhados, TSV e saídas brutas da versão `0.6.4`.
- [`0.7.0/`](0.7.0/): Resultados detalhados, TSV e saídas brutas da versão `0.7.0`.

---

## 4. Reproduzindo Verificações Locais

Para executar a verificação local de qualquer tag:

```bash
./scripts/run-tag-verification.sh <tag> [duracao_segundos]
# Exemplo:
./scripts/run-tag-verification.sh 0.7.0 5
```
