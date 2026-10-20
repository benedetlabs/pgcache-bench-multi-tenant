# Relatório de Benchmark PgCache 0.7.0: Perfil Padrão vs. Otimizado em um Cluster de 3 Nós na Nuvem

> 🇺🇸 **[Read in English](README.md)**

Este relatório documenta a verificação da versão **PgCache v0.7.0** (`pgcache/pgcache:0.7.0`) no nosso cluster **DigitalOcean Kubernetes de 3 nós (DOKS)** (`3× s-4vcpu-8gb` na mesma zona), comparando a configuração padrão com o perfil otimizado de rede Linux e engine de 1 até 2.000 tenants ativos.

> **Por que mostramos apenas números do cluster de 3 nós**: O Docker Compose local é usado exclusivamente para montar o ambiente e testar a corretude do SQL; todos os números de performance vêm do cluster Kubernetes de 3 nós na nuvem.

---

## 1. Principais Conclusões

- **100,0% de Acerto no Cache até 2.000 Tenants**: Tanto no perfil padrão quanto no otimizado, o PgCache 0.7.0 manteve 100,0% de acerto em todas as faixas de 1 a 2.000 clientes ativos.
- **Perfil Padrão (+38% a +64% de Ganho)**: Reduziu o tempo do dashboard de 8 consultas de **23,3–28,5 ms** no PostgreSQL para **15,6–18,8 ms** no PgCache (chegando a **513 telas/s**).
- **Perfil Otimizado Melhora a Escala em 2.000 Tenants (+38% → +67%)**: Distribuir as interrupções de rede pelas 4 vCPUs (`rps_cpus=f`), usar roteamento direto por IP (sem passar pelo CoreDNS) e dobrar os workers para 8 elevou o ganho relativo em 1.000–2.000 tenants para **+67% a +68%**.

---

## 2. Configuração Padrão vs. Otimizada (3 VMs Dedicadas na Nuvem)

| Ajuste | DOKS 3 Nós (Padrão) | DOKS 3 Nós (Otimizado / Tuned) |
|---|---|---|
| **Máquinas Virtuais** | 3× `s-4vcpu-8gb` (`sfo3` single-AZ, `--ha=false`) | 3× `s-4vcpu-8gb` (`sfo3` single-AZ, `--ha=false`) |
| **Isolamento Físico** | `podAntiAffinity` estrito + `hostNetwork: true` | `podAntiAffinity` estrito + `hostNetwork: true` |
| **Pilha de Rede Linux** | Padrão do sistema | `tcp_slow_start_after_idle=0`, `somaxconn=65535`, `tcp_tw_reuse=1`, VirtIO RPS (`rps_cpus=f`) |
| **Resolução de Nomes** | DNS interno (`CoreDNS`) | Roteamento direto por IP da máquina |
| **Workers do PgCache** | `NUM_WORKERS=4` | `NUM_WORKERS=8`, `PGCACHE_POPULATION_WORKERS_MIN=4`, `MEMO_CACHE_SIZE=1073741824` |

---

## 3. Escalando de 1 até 2.000 Tenants (8 Clientes Simultâneos)

| Tenants Ativos | Origem Padrão | PgCache 0.7.0 Padrão | Ganho Padrão | Origem Otimizada | PgCache 0.7.0 Otimizado | Ganho Otimizado | Taxa de Acerto | Passos Warmup |
|---:|---|---|---:|---|---|---:|---:|---:|
| **1** | 23,3 ms · 343 telas/s | **15,6 ms · 513 telas/s** | **+50%** | 30,4 ms · 263 telas/s | **24,0 ms · 333 telas/s** | **+27%** | 100,0% | 2 |
| **10** | 23,9 ms · 335 telas/s | **22,9 ms · 349 telas/s** | **+4%** | 33,1 ms · 242 telas/s | **22,0 ms · 363 telas/s** | **+50%** | 100,0% | 2 |
| **50** | 28,5 ms · 281 telas/s | **17,3 ms · 462 telas/s** | **+64%** | 32,7 ms · 245 telas/s | **21,5 ms · 371 telas/s** | **+51%** | 100,0% | 2 |
| **100** | 26,0 ms · 307 telas/s | **17,2 ms · 465 telas/s** | **+51%** | 33,0 ms · 243 telas/s | **19,3 ms · 414 telas/s** | **+70%** | 100,0% | 2 |
| **500** | 25,7 ms · 311 telas/s | **18,7 ms · 428 telas/s** | **+38%** | 30,0 ms · 266 telas/s | **22,3 ms · 359 telas/s** | **+35%** | 100,0% | 3 |
| **1.000** | 26,0 ms · 307 telas/s | **17,2 ms · 466 telas/s** | **+52%** | 33,2 ms · 241 telas/s | **19,7 ms · 405 telas/s** | **+68%** | 100,0% | 3 |
| **2.000** | 25,9 ms · 309 telas/s | **18,8 ms · 425 telas/s** | **+38%** | 34,2 ms · 234 telas/s | **20,5 ms · 390 telas/s** | **+67%** | 100,0% | 4 |

---

## 4. Arquivos Brutos

- TSV DOKS (3 Nós): [`results-doks.tsv`](results-doks.tsv)
- Log Bruto da Varredura de Tenants (DOKS): [`run-tenants-doks.txt`](run-tenants-doks.txt)
- Relatório do Perfil Otimizado: [`../tuned/README-pt.md`](../tuned/README-pt.md)
