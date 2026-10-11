# Resultados da Verificação de Múltiplas Versões do PgCache

> 🇺🇸 **[English version](README.md)**

Este diretório contém as execuções de verificação comparando as novas versões do **PgCache**:
- [**PgCache 0.6.3**](0.6.3/README-pt.md)
- [**PgCache 0.6.4**](0.6.4/README-pt.md)
- [**PgCache 0.7.0**](0.7.0/README-pt.md)

Todos os testes foram executados com a carga de trabalho multi-tenant de SaaS (500 mil pedidos, 2 milhões de itens de pedidos, 200 tenants, 8 instruções SQL por requisição de dashboard) utilizando o protocolo de aquecimento dinâmico (`warm_until_settled`).

---

## 1. Resumo Comparativo Entre Versões

| Métrica / Cenário | Origem (Caminho A) | PgCache 0.6.3 (200t) | PgCache 0.6.4 (200t) | PgCache 0.7.0 (1.000t) |
|---|---|---|---|---|
| **Taxa de Acerto (Hit Ratio)** | N/A | **100,0%** | **100,0%** | **100,0%** (1..500t) / **99,7%** (1.000t) |
| **Latência com 1 Cliente** | 11,5–24,8 ms | **3,36 ms** (7,4× mais rápido) | **3,02 ms** (7,1× mais rápido) | **5,55 ms** (2,1× mais rápido) |
| **Latência com 8 Clientes (Leitura)** | 36,5–86,7 ms | **7,68 ms** (+1032%) | **7,73 ms** (+1012%) | **14,90 ms** (+145%) |
| **Vazão Máxima (16-32 clientes)** | ~100–297 rps | **1.371 rps** (+1299%) | **1.266 rps** (+1153%) | **626 rps** (+111%) |
| **Resiliência a Escrita (5% esc, 1 wt)** | ~95–246 rps | **1.066 rps** (+1022%) | **1.058 rps** (+991%) | **408 rps** (+66%) |
| **Resiliência a Escrita (10% esc, máx wt)** | ~101–257 rps | **814 rps** (+706%) | **911 rps** (+744%) | **318 rps** (+24%) |

---

## 2. Observações Principais

1. **Cacheabilidade e Dispersão de Chaves (até 1.000 tenants)**:
   Todas as consultas do dashboard de 8 instruções atingiram **100,0% de acerto** até 500 tenants. Com 1.000 tenants na versão 0.7.0, a taxa sustentou-se em **99,7%** com 5 passes de aquecimento, provando forte retenção mesmo após multiplicar o espaço de chaves por 5×.

2. **Escala de Vazão**:
   As versões **0.6.3** e **0.6.4** apresentaram perfis de altíssima vazão sob a carga de 200 tenants. A versão **0.7.0** foi aferida sob a carga expandida de 1.000 tenants, mantendo ganhos sólidos em todos os níveis de concorrência.

3. **Comportamento do PgCache 0.7.0**:
   A versão **0.7.0** passou em todos os testes de compatibilidade e retenção de cache. Em testes locais no Docker Desktop com 1.000 tenants, a invalidação concorrente do CDC gerou maior consumo de CPU na máquina compartilhada. O ambiente oficial de 3 nós dedicados no Kubernetes oferecerá isolamento ideal para os números finais de produção.

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
