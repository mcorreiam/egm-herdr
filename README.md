# egm-herdr

Adapter que conecta a metodologia **EGM (Elephant-Goldfish Model)** do Google ao **Herdr**, usando sua stack: **OpenCode (opencode-go)** + **Antigravity (agy)** como revisores Goldfish em panes.

> **Não é um fork do EGM.** Este repo consome o upstream (`google/elephant-goldfish-model`) como fonte canônica de personas, standards e metodologia, e adiciona apenas: orquestração via Herdr, agentes com permissões e a matriz de modelos. Conforme o `docs/harnesses.md` do EGM: *"No harness gets a fork of the skill text."*

---

## Como funciona

```
┌─ Pane 1 (primário) ──────────────────────────────────────────┐
│ ELEPHANT: opencode --agent egm                               │
│ - segue skills/egm-herdr/SKILL.md                            │
│ - redige concepts_brief.md / design_draft.md                 │
│ - despacha revisores via CLI herdr                           │
│ - sintetiza relatórios e para nos approval gates             │
└──────────────────────────────────────────────────────────────┘
       │ herdr pane split + agent start (1 por revisor)
       ├─→ egm-comprehension       opencode + muse-spark-1.3-contributor
       ├─→ egm-design-critic       opencode + glm-5.3
       ├─→ egm-structural          agy      + gemini-3.8-flash
       ├─→ egm-style               agy      + gemini-3.8-flash
       ├─→ egm-zoom-out            opencode + glm-5.3
       └─→ egm-implementation-readiness  opencode + glm-5.3
```

Cada revisor Goldfish é um **processo separado em um pane separado**, iniciado com um prompt autocontido (persona + alvo + standards). O isolamento de contexto é físico — mais forte que subagentes do mesmo host.

---

## Instalação

```bash
cd ~/projects/egm-herdr

# 1. Clona o upstream do EGM, registra hashes e integra sua config do opencode
./scripts/install.sh

# 2. Verificação offline
./scripts/verify.sh

# 3. Reinicie o opencode e abra uma sessão dentro do Herdr
```

O `install.sh`:
1. Clona `google/elephant-goldfish-model` para `~/tools/elephant-goldfish-model` (fixando o commit de `EGM_COMMIT`, default `main`).
2. Grava `~/.config/egm-herdr/paths.json` (caminhos absolutos) e `installation.json` (commit + SHA-256).
3. Faz merge dos agentes `egm` e `egm-reviewer` e do path da skill na sua config global do opencode (`~/.config/opencode/opencode.json`), com backup `.bak` antes de alterar.

---

## Uso

Dentro de um pane do Herdr, no diretório do projeto-alvo:

```bash
opencode --agent egm
```

Depois, no chat:

| Objetivo | Mensagem |
|---|---|
| Explorar a ideia | `/egm-brainstorm Adicionar webhook delivery a este projeto.` |
| Rascunhar a spec | `/egm-draft` |
| Revisar o draft (5 estágios, abre panes) | `/egm-review design_draft.md` |
| Trabalhar os findings | `/egm-resolve design_draft.md` |
| Conferir desvio docs vs código | `/egm-drift-report docs/designs/` |

O que esperar:
- O Elephant redige pausando por seção para o seu feedback.
- No review, ele abre um pane por revisor (você vê cada Goldfish trabalhando).
- Revisores escrevem findings em `egm-reports/<persona>.md` do projeto-alvo.
- Revisores que pedirem aprovação ficam `blocked` — você responde no pane deles.
- O Elephant sintetiza os relatórios canônicos e **para antes de cada gate** para a sua decisão.
- Aprovado: spec vai para `docs/designs/`. O implementador (pane dedicado, lê só a spec) roda por último.

### Calibração (custo zero)

Antes do primeiro run de verdade, valide o pipeline inteiro com `beam-free`:

```bash
# edite config/egm-herdr.json → substitua temporariamente os modelos
# "opencode" por "opencode-go/beam-free" e rode /egm-review
```

---

## Matriz de modelos (tier Go)

| Papel | Modelo | Racional |
|---|---|---|
| Orquestrador (Elephant) | `glm-5.3` | Mais forte da conta; cap $500/mês folgado |
| design-critic, zoom-out, implementation-readiness | `glm-5.3` | Julgamento profundo; rate próprio (6.600 req/5h) |
| comprehension, codebase-details, inventive-catalyst | `muse-spark-1.3-contributor` | 45.300 req/5h, $0.10/$0.20 (SKU contributor: dados treinam Meta) |
| structural, style (agy) | `gemini-3.8-flash` | Revisão leve no Antigravity |
| Implementador (dev) | `glm-5.3` | "Matching models 3-4× its size" em coding |
| Fallback de rate-limit | `mimo-v2.6-pro` | AA 46, #1 open-weight, cap $15 |
| Calibração | `beam-free` | Open-weight (Reflection), ilimitado, $0 |

Fontes: Artificial Analysis (índices por classe), kompozy.io (MiMo), stob.ai (Muse Spark), reflection.ai (Beam). Notas de AA não são comparáveis entre classes/faixas de preço.

---

## Verificação de isolamento (procedimento manual, recomendado)

1. Coloque uma frase-marking secreta **apenas na conversa do Elephant** (nunca em arquivo).
2. Rode `/egm-review` completo.
3. Ao final, pergunte a cada revisor (via `herdr agent prompt`) qual era a frase secreta — nenhum deve saber.
4. Peça a um revisor para gravar fora de `egm-reports/` — deve ser negado pelas permissões do agente.

---

## Estrutura

```
egm-herdr/
├── README.md
├── opencode.json            # agentes egm + egm-reviewer (placeholders de path)
├── skills/egm-herdr/SKILL.md # metodologia traduzida (o Elephant segue isso)
├── config/egm-herdr.json    # matriz reviewer → {kind, model, persona_file}
├── scripts/install.sh        # upstream + merge da config opencode
├── scripts/verify.sh         # verificação offline
└── docs/design.md           # decisões arquiteturais (estilo EGM/ADR)
```

## Limitações conhecidas

- Revisores ainda carregam `AGENTS.md` do projeto ao iniciar (leak documentado também nos harnesses oficiais do EGM).
- Read-only real existe no opencode (permissions do agente `egm-reviewer`); no agy, depende de flags — trate como prompt-only até validar.
- `egm-bootstrap` não é orquestrado no v1 (para, não simula — igual ao adapter oficial).
- Flags exatas de `--model` no `agent start` de cada kind devem ser confirmadas no primeiro run.

## Licença

MIT
