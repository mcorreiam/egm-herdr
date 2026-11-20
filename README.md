# egm-herdr

Adapter que conecta a metodologia **EGM (Elephant-Goldfish Model)** do Google ao **Herdr**, usando sua stack: **OpenCode (opencode-go)** + **Antigravity (agy)** como revisores Goldfish em panes.

> **Não é um fork do EGM.** Este repo consome o upstream (`google/elephant-goldfish-model`) como fonte canônica de personas, standards e metodologia, e adiciona apenas: orquestração via Herdr, agentes com permissões e a matriz de modelos. Conforme o `docs/harnesses.md` do EGM: *"No harness gets a fork of the skill text."*

---

## Como funciona

```
┌─ Pane 1 (primário) ──────────────────────────────────────────┐
│ ELEPHANT: opencode, agente egm (via /egm-* ou mini)           │
│ - segue skills/egm-herdr/SKILL.md                            │
│ - redige concepts_brief.md / design_draft.md                 │
│ - despacha revisores via CLI herdr e espera com agent wait   │
│ - sintetiza relatórios e para nos approval gates             │
└──────────────────────────────────────────────────────────────┘
       │ herdr pane split + agent start (1 por revisor)
       ├─→ egm-comprehension       mini + muse-spark-1.3-contributor
       ├─→ egm-design-critic       mini + glm-5.3
       ├─→ egm-structural          agy   + gemini-3.8-flash
       ├─→ egm-style               agy   + gemini-3.8-flash
       ├─→ egm-zoom-out            mini + glm-5.3
       └─→ egm-implementation-readiness  mini + glm-5.3
```

Cada revisor Goldfish é um **processo separado em um pane separado** (`opencode mini --model X --agent egm-reviewer`, ou o TUI do agy), iniciado com um prompt autocontido (persona + alvo + standards). O isolamento de contexto é físico — mais forte que subagentes do mesmo host. O Elephant fica sabendo que terminaram via `herdr agent wait` (estado `done`/`idle`) e coleta o relatório **do arquivo em disco**, não da tela.

---

## Instalação

```bash
cd ~/projects/egm-herdr
./scripts/install.sh     # clona o upstream do EGM, instala agents/commands/skill
./scripts/verify.sh      # verificação offline (usa a config RESOLVIDA do opencode)
```

O `install.sh` instala do jeito que este build do opencode realmente carrega — **arquivos file-based, sem tocar na sua `opencode.jsonc`**:

- `~/.config/opencode/agents/egm.md`, `egm-reviewer.md`, `egm-implementer.md`
- `~/.config/opencode/commands/egm-*.md` (5 comandos `/egm-*`)
- `~/.config/opencode/skills/egm-herdr` → symlink para este repo
- `~/.config/egm-herdr/paths.json` + `installation.json` (commit + SHA-256 do upstream)

Backups `.bak.<timestamp>` são feitos se algum arquivo destino já existir. O upstream é validado por remote antes de qualquer update.

---

## Uso

Dentro de um pane do Herdr, no diretório do projeto-alvo (precisa reiniciar o opencode depois da instalação):

| Objetivo | Comando |
|---|---|
| Explorar a ideia | `/egm-brainstorm Adicionar webhook delivery a este projeto.` |
| Rascunhar a spec | `/egm-draft` |
| Revisar o draft (5 estágios, abre panes) | `/egm-review design_draft.md` |
| Trabalhar os findings | `/egm-resolve design_draft.md` |
| Conferir desvio docs vs código | `/egm-drift-report docs/designs/` |

Ou iniciar o Elephant direto: `opencode mini --model opencode-go/glm-5.3 --agent egm`

O que esperar:
- O Elephant redige pausando por seção para o seu feedback.
- No review, ele abre um pane por revisor e **os despacha em paralelo**; cada estágio termina quando todos os revisores dele terminam.
- Revisores escrevem findings em `egm-reports/reviewers/<relatório único>.md`; o Elephant escreve os relatórios canônicos de estágio no diretório do projeto.
- Revisores que pedirem aprovação ficam `blocked` — você responde no pane deles.
- O Elephant sintetiza e **para antes de cada gate** para a sua decisão.
- Aprovado: spec vai para `docs/designs/`; o implementador (pane dedicado, `egm-implementer`) lê só a spec.

### Calibração (custo zero)

Antes do primeiro run de verdade, valide o pipeline inteiro com `beam-free`: troque os modelos `opencode` da matriz em `config/egm-herdr.json` por `opencode-go/beam-free` e rode `/egm-review` num projeto descartável.

---

## Matriz de modelos (tier Go)

| Papel | Modelo | Racional |
|---|---|---|
| Orquestrador (Elephant) e design-critic, zoom-out, implementation-readiness, implementador | `glm-5.3` | Cap $500/mês folgado, 6.600 req/5h, forte em coding |
| comprehension, codebase-details, inventive-catalyst | `muse-spark-1.3-contributor` | 45.300 req/5h, SKU contributor $0.10/$0.20 (dados treinam Meta — consentido) |
| structural, style (agy) | `gemini-3.8-flash` | Revisão leve no Antigravity |
| Fallback de rate-limit | `mimo-v2.6-pro` | AA 46, #1 open-weight, MIT |
| Calibração | `beam-free` | Reflection Beam 1.0 (open-weight), ilimitado, $0 |

Rejeitados: `kimi-k3.1-pro` (147 req/5h), `minimax-m3` (AA 19), `longcat-2.0` (sem AA index). Fontes: Artificial Analysis (por classe), kompozy.io, stob.ai, reflection.ai.

---

## Verificação de isolamento (procedimento manual, recomendado)

1. Coloque uma frase-marca secreta **apenas na conversa do Elephant** (nunca em arquivo).
2. Rode `/egm-review` completo.
3. Pergunte a cada revisor qual era a frase (exceção documentada às regras da skill) — nenhum deve saber.
4. Peça a um revisor para gravar fora de `egm-reports/reviewers/` — deve ser negado pelas permissões do agente `egm-reviewer`.

---

## Estrutura

```
egm-herdr/
├── agents/                    # egm, egm-reviewer (read-only + report), egm-implementer
├── commands/                   # /egm-brainstorm, /egm-draft, /egm-review, /egm-resolve, /egm-drift-report
├── skills/egm-herdr/SKILL.md   # metodologia traduzida (o Elephant segue isso)
├── config/egm-herdr.json       # matriz reviewer → {kind, model, persona_file, report único}
├── scripts/install.sh          # upstream + instalação file-based
├── scripts/verify.sh            # verificação offline (config RESOLVIDA via debug agents)
└── docs/design.md              # decisões arquiteturais (estilo EGM/ADR)
```

## Limitações conhecidas

- Revisores ainda carregam `AGENTS.md` do projeto ao iniciar (leak documentado também nos harnesses oficiais do EGM).
- `herdr agent prompt` pode reportar `agent_prompt_stalled` como falso negativo no `opencode mini` — o prompt foi entregue mesmo assim; confirme lendo o pane (a SKILL cobre isso).
- Primeiro `agent start --kind agy` num workspace mostra um diálogo de confiança que só você responde.
- `egm-reviewer` nega `grep` de propósito (grep não respeita as read rules de `.env` — mesma decisão do adapter oficial do EGM); personas que varrem código usam `read`+`glob`.
- `egm-bootstrap` não é orquestrado no v1 (para, não simula).
- MCP tools do revisor não são negáveis em lote por nome de servidor — negadas por prompt; recursos MCP (`opencode_read_mcp_resource`) são negados por permissão.

## Licença

MIT
