# Design: egm-herdr

* **Status:** v1 (escopo inicial)
* **Date:** 2026-11-19
* **Stack alvo:** Herdr + OpenCode (opencode-go) + Antigravity (agy)

## Contexto

A metodologia [EGM](https://github.com/google/elephant-goldfish-model) separa
redação de especificação (Elephant, com contexto) de revisão (Goldfish, sem
contexto). Os harnesses oficiais implementam os Goldfish como subagentes do
mesmo host — o que o próprio `docs/harnesses.md` do EGM admite ter vazamentos
de instruction files (issues #105, #106, #237).

Este adapter usa o Herdr para dar a cada Goldfish um **processo separado em um
pane separado**, com prompt autocontido. O isolamento deixa de ser simulado
pelo host e passa a ser físico.

## Decisões

### D1 — Adapter sobre upstream, não fork
`docs/harnesses.md` do EGM: *"No harness gets a fork of the skill text."*
Personas (`agents/`), standards (`resources/document_standards/`) e o
procedimento canônico são lidos direto do clone upstream, fixado por commit e
registrado com SHA-256 em `installation.json`. Este repo contém apenas glue:
agentes, skill de orquestração, matriz de modelos e scripts.

### D2 — Natureza: plugin (skill + agentes + config), não skill pura
Uma skill sozinha não registra agentes com permissões nem commands no
opencode. O `opencode.json` do repo define:
- `egm` (primary): orquestrador Elephant. `task: deny` — despacho é via CLI
  `herdr` no shell, não via task tool.
- `egm-reviewer` (subagent, read-only): espelha o adapter oficial do EGM para
  OpenCode V1 — `*: deny`, `read` com `.env` negado, `glob: allow`,
  `grep: deny` (grep ignora as read rules, então é negado para não expor
  `.env`).

### D3 — Revisores escrevem findings em disco
Cada Goldfish grava `egm-reports/<report>.md` e responde só o caminho.
Mais robusto que ler pane: sobrevive a output longo, scrollback de
alternate-screen e truncamento. (Fallback documentado da skill herdr.)

### D4 — Matriz de modelos por papel (tier Go)

| Papel | Modelo | Fonte/racional |
|---|---|---|
| Orquestrador + design-critic + zoom-out + implementation-readiness + implementer | `glm-5.3` | Cap $500/mês (folga), 6.600 req/5h, "matching models 3-4× its size" em coding (codepick). Verboso — vira relatório rico. |
| comprehension + codebase-details + inventive-catalyst | `muse-spark-1.3-contributor` | 45.300 req/5h, $0.10/$0.20 no SKU contributor (dados treinam Meta — consentido). AA 37. "Asks for input when stuck" (stob) combina com gates. |
| structural + style | `gemini-3.8-flash` (agy) | Revisão leve; único modelo disponível no Antigravity hoje. |
| Fallback rate-limit | `mimo-v2.6-pro` | AA 46, #1 open-weight, MIT, Terminal Bench 89.9% (kompozy). Cético no Reddit ("benchmaxxed") — por isso fallback, não titular. |
| Calibração | `beam-free` | Reflection Beam 1.0, open-weight 501B/23B, ∞ req, $0. "Competitive with GLM 5.2" (blog). Para validar o pipeline a custo zero. |

Rejeitados: `kimi-k3.1-pro` (147 req/5h — estoura em minutos),
`minimax-m3` (AA 19, abaixo da mediana 23), `longcat-2.0` (sem AA index,
"somewhat expensive" na classe, já superado pelo 2.5).

### D5 — Gates humanos preservados
O EGM exige aprovação humana em pontos fixos. No Herdr, revisores `blocked`
em dialogs de aprovação são respondidos pelo usuário no próprio pane; o
Elephant pergunta e espera — timeout ou conclusão de revisor nunca é aprovação.

### D6 — Implementador é um pane próprio, pós-aprovação
Quem programa não é o Elephant: a spec aprovada em `docs/designs/` é o
contrato. O `egm-implementer` lê só a spec + `AGENTS.md`, sem histórico da
conversa (espírito Goldfish aplicado ao dev).

## Limitações conhecidas (declarar, não esconder)

1. Revisores ainda carregam `AGENTS.md`/instructions do projeto ao iniciar
   (leak também presente nos harnesses oficiais; mitigável com profile limpo).
2. Read-only real no opencode (permissions); no agy é prompt-only até validação.
3. `egm-bootstrap` fora do escopo no v1 — para, não simula (igual ao adapter
   oficial do EGM para OpenCode).
4. Flags exatas de `--model` no `herdr agent start` de cada kind confirmadas
   no primeiro run.
5. Índices Artificial Analysis são medidos por classe/faixa de preço — não
   comparáveis entre modelos de classes diferentes.

## Verificação

Offline (`scripts/verify.sh`): ambiente, metadados, hashes, personas
upstream, matriz, config global. Manual (README): teste de marker secreto
(só na conversa do Elephant → nenhum Goldfish pode saber) e teste de negação
de escrita fora de `egm-reports/`.

## Roadmap

- v1.1: flags reais de modelo por kind validadas e documentadas.
- v1.2: `egm-drift-report` automatizado com `egm-codebase-details`.
- v2: evidências de isolamento gravadas (procedimento do `docs/opencode.md`
  upstream) e PR de harness "Herdr" para o `google/elephant-goldfish-model`
  (eles aceitam harnesses novos com evidências anexadas).
