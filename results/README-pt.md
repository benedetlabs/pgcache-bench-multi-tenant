# Resultados da Verificação de Múltiplas Versões do PgCache

> 🇺🇸 **[English version](README.md)**

Este diretório contém as execuções de verificação comparando as novas versões do **PgCache**:
- [**PgCache 0.6.3**](0.6.3/README-pt.md)
- [**PgCache 0.6.4**](0.6.4/README-pt.md)
- [**PgCache 0.7.0**](0.7.0/README-pt.md)

Todos os testes foram executados com a carga de trabalho multi-tenant de SaaS (500 mil pedidos, 2 milhões de itens de pedidos, 200 tenants, 8 instruções SQL por requisição de dashboard) utilizando o protocolo de aquecimento dinâmico (`warm_until_settled`).

---

## 1. Resumo Comparativo Entre Versões

| Métrica / Cenário | Origem (Caminho A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 |
|---|---|---|---|---|
| **Taxa de Acerto (Hit Ratio)** | N/A | **100,0%** | **100,0%** | **100,0%** |
| **Latência com 1 Cliente** | 20,8–24,8 ms | **3,36 ms** (7,4× mais rápido) | **3,02 ms** (7,1× mais rápido) | **4,00 ms** (5,2× mais rápido) |
| **Latência com 8 Clientes (Leitura)** | 80,8–86,7 ms | **7,68 ms** (+1032%) | **7,73 ms** (+1012%) | **8,84 ms** (+814%) |
| **Vazão Máxima (16-32 clientes)** | ~100–107 rps | **1.371 rps** (+1299%) | **1.266 rps** (+1153%) | **1.046 rps** (+896%) |
| **Resiliência a Escrita (5% esc, 1 wt)** | ~95–103 rps | **1.066 rps** (+1022%) | **1.058 rps** (+991%) | **516 rps** (+401%) |
| **Resiliência a Escrita (10% esc, 200 wt)** | ~101–108 rps | **814 rps** (+706%) | **911 rps** (+744%) | **198 rps** (+83%) |

---

## 2. Observações Principais

1. **Cacheabilidade Perfeita das Consultas**:
   Todas as consultas geradas pelo dashboard de 8 instruções atingiram **100,0% de taxa de acerto** após o aquecimento nas três versões. A dispersão das consultas entre 200 tenants não degradou a retenção do cache.

2. **Escala de Vazão**:
   As versões **0.6.3** e **0.6.4** demonstraram perfis de vazão muito semelhantes, alcançando até ~1.370 rps em leituras e sustentando acima de 800–900 rps sob proporção de 10% de escrita.

3. **Comportamento do PgCache 0.7.0**:
   A versão **0.7.0** passou em todos os testes de compatibilidade e cache com 100% de hit ratio. Em testes locais no Docker Desktop (onde origem e cache disputam os mesmos núcleos de CPU locais), escritas concorrentes exigiram maior consumo de CPU na replicação CDC em segundo plano. A execução oficial no cluster Kubernetes de 3 nós dedicados fornecerá isolamento físico para aferição das grandezas definitivas.

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
