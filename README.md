# fx

**Español** | [English](README.en.md)

Un agente de programación rápido para tu terminal que funciona con **el modelo
que quieras**: DeepSeek, Qwen, Kimi, GLM, MiniMax, OpenRouter, OpenAI, Gemini,
o un modelo local en Ollama, LM Studio, llama.cpp o vLLM.

fx es un fork de [fx](https://github.com/vercel-labs/fx) (commit `59bf437`)
que elimina la dependencia del Vercel AI Gateway y añade **Jev**, un revisor
independiente que mantiene al agente honesto.

> Estado: experimental, en desarrollo activo. Ver [PROPOSAL.md](PROPOSAL.md).

## Contenido

- [Por qué fx](#por-qué-fx)
- [Inicio rápido](#inicio-rápido)
- [Cómo funciona](#cómo-funciona)
- [Proveedores y modelos](#proveedores-y-modelos)
- [Jev: el revisor del agente](#jev-el-revisor-del-agente)
- [SDD: specs antes de los cambios grandes](#sdd-specs-antes-de-los-cambios-grandes)
- [TDD: primero los tests](#tdd-primero-los-tests)
- [Permisos y reglas del proyecto](#permisos-y-reglas-del-proyecto)
- [Dónde vive la configuración](#dónde-vive-la-configuración)
- [Referencia](#referencia)

## Por qué fx

- **Tu modelo, tu factura.** Usa cualquier proveedor compatible con OpenAI, o
  todo en local. Sin gateway en el medio.
- **Tool calls que funcionan de verdad.** Un lector de streams tolerante maneja
  las rarezas de los modelos que no son de OpenAI (finish reasons extraños,
  `[DONE]` que falta, tool deltas sin índice) que rompen los tool calls y los
  subagentes en otros agentes.
- **Una segunda opinión en cada turno.** Jev comprueba que los cambios grandes
  tengan un plan, que "listo" signifique listo y que cada afirmación esté
  respaldada por la salida real de las herramientas.
- **Specs siempre al día.** SDD (opcional) mantiene una carpeta `sdd/` liviana
  con reglas y propuestas de cambio, y avisa cuando el código las contradice.
- **Nativo y rápido.** Un solo binario en Zig que arranca en milisegundos. Las
  keys se guardan en el Keychain de macOS.

## Inicio rápido

**1. Instalar** (macOS, Apple Silicon o Intel):

```bash
curl -fsSL https://raw.githubusercontent.com/abelcondev/fx/main/install.sh | sh
```

Se instala en `~/.local/bin`. `FX_INSTALL_DIR` cambia la carpeta y
`FX_VERSION=v0.1.0` fija una versión. En otras plataformas,
[compila desde el código](#compilar-desde-el-código). fx usa el nombre `fx` y
la carpeta `~/.fx`, así que primero desinstala el fx original de Vercel.

**2. Conectar un proveedor** (la key se guarda en el Keychain):

```bash
fx login deepseek        # o qwen, openrouter, moonshot, zai, ...
```

Los modelos locales no necesitan key: `fx provider ollama` (o `lmstudio`,
`llamacpp`, `vllm`).

**3. A trabajar:**

```bash
cd mi-proyecto
fx                                  # sesión interactiva
fx ask "explica este repositorio"   # un pedido, sin sesión
```

Eso es todo. Lo demás es opcional: elige un modelo con `/model`, activa
[Jev](#jev-el-revisor-del-agente) y activa [SDD](#sdd-specs-antes-de-los-cambios-grandes)
por proyecto.

Para actualizar más adelante: `fx update`.

## Cómo funciona

```
   tú ──► fx (loop del agente) ──► tu modelo (DeepSeek, Qwen, local, ...)
              │    ▲
              │    └── resultados: archivos, shell, web, subagentes
              ▼
        permisos         ← qué puede hacer el agente sin preguntarte
        Jev (opcional)   ← ¿hay un plan? ¿está realmente terminado?
        SDD (opcional)   ← ¿este cambio necesita una spec o una propuesta?
```

El modelo hace el trabajo. fx ejecuta las herramientas, aplica los permisos y,
si los activas, le pide a Jev y a SDD que revisen el trabajo en momentos clave.

## Proveedores y modelos

### Elegir un proveedor

```bash
fx login <preset>        # guarda la key y selecciona ese proveedor
fx provider <preset>     # cambia de proveedor
fx logout <preset>       # olvida la key
fx status                # muestra proveedor, modelo, credenciales y permisos
```

Dentro de una sesión, `/provider` lista los presets y cambia entre ellos.

También puedes saltarte `login` y exportar la key. Una variable exportada gana
sobre una guardada:

```bash
export DEEPSEEK_API_KEY=...
FX_PROVIDER=deepseek fx
```

Si no hay proveedor elegido, fx usa el primer preset cuya variable de key esté
definida.

### Presets incluidos

| Preset | Variable de la key | Endpoint |
| --- | --- | --- |
| `deepseek` | `DEEPSEEK_API_KEY` | api.deepseek.com (`deepseek-flash`, `deepseek-v4-pro`; probado de punta a punta) |
| `qwen`, `qwen-cn` | `DASHSCOPE_API_KEY` | DashScope modo compatible (internacional / China) |
| `qwen-plan` | `QWEN_TOKEN_PLAN_API_KEY` | Model Studio Token Plan, Singapur (key de plan `sk-sp-…`; modelos qwen3.8, GLM y DeepSeek; probado de punta a punta) |
| `moonshot`, `moonshot-cn` | `MOONSHOT_API_KEY` | Kimi (internacional / China) |
| `zai`, `zhipu` | `ZAI_API_KEY`, `ZHIPUAI_API_KEY` | GLM (Z.ai / BigModel) |
| `minimax` | `MINIMAX_API_KEY` | api.minimax.io |
| `muse` | `MUSE_API_KEY` | Meta Model API, api.meta.ai (`muse-spark-1.3`, `muse-spark-1.3-contributor`; sirve con la key de un plan de Muse Code; probado de punta a punta) |
| `stepfun` | `STEPFUN_API_KEY` | api.stepfun.ai (`step-5-preview`, `step-3.7-flash`, `step-3.5-flash`, `step-3.5-flash-2603`; probado de punta a punta) |
| `openrouter` | `OPENROUTER_API_KEY` | openrouter.ai |
| `openai`, `anthropic`, `gemini`, `xai`, `mistral` | `<NOMBRE>_API_KEY` | endpoints compatibles con OpenAI de cada proveedor |
| `groq`, `together`, `fireworks`, `siliconflow` | `<NOMBRE>_API_KEY` | endpoints compatibles con OpenAI de cada proveedor |
| `ollama`, `lmstudio`, `llamacpp`, `vllm` | ninguna | localhost, puertos por defecto |

Los endpoints y los ids de modelo siguen la documentación pública de cada
proveedor y pueden cambiar. Para ajustar uno, define un proveedor con el mismo
nombre (ver abajo).

### Elegir un modelo

```bash
fx models                # modelos que reporta el proveedor
fx --model deepseek-v4-pro --effort high
```

Dentro de una sesión, `/model` elige el modelo y su nivel de razonamiento, y la
elección se guarda. `FX_MODEL` lo cambia solo para esa shell. Si el `GET /models`
del proveedor reporta `context_window`, `max_output_tokens`, niveles de
razonamiento o tipos de entrada, fx los toma automáticamente.

### Añadir tu propio proveedor

Cualquier endpoint compatible con OpenAI sirve. Agrégalo a `~/.fx/settings.json`:

```jsonc
{
  "providers": {
    "mi-proveedor": {
      "protocol": "openai-chat-completions",
      "base_url": "https://api.ejemplo.com/v1",
      "auth": { "type": "bearer", "env": "MI_PROVEEDOR_API_KEY" },
      "default_model": "mi-modelo"
    }
  }
}
```

Luego `fx provider mi-proveedor`. `http://` sin TLS funciona para localhost y
redes privadas (RFC 1918, Tailscale, `.local`). Todos los campos están en
[Campos del proveedor](#campos-del-proveedor).

## Jev: el revisor del agente

[Jev](https://docs.typesafe.ai) es el modelo de decisiones de TypeSafe AI.
**No escribe código.** Responde preguntas cortas y tipadas ("¿este plan está
completo?", "¿cada afirmación está respaldada por un resultado de herramienta?")
con probabilidades calibradas. fx le pregunta en momentos clave de cada turno,
así un segundo modelo, independiente, revisa el trabajo del modelo principal.

### Qué hace Jev en un turno

```
 tú: "agrega pagos parciales"
   │
   ▼
 ┌─────────────────────── turno del agente ───────────────────────┐
 │                                                                │
 │  el agente te hace una pregunta                                │
 │     └─► ASK: Jev la responde si el contexto ya la resuelve,    │
 │              si no, te llega a ti                              │
 │                                                                │
 │  primer cambio de archivos del turno                           │
 │     ├─► PLAN: ¿pedido grande? se frena hasta que el agente     │
 │     │         escriba un plan con pasos y criterios            │
 │     └─► SDD:  (si está activo) ruta fix / spec / change        │
 │                                                                │
 │  cada edición o comando (opcional)                             │
 │     └─► ACTION: ¿es parte de la tarea? ¿sin daños no pedidos?  │
 │                                                                │
 │  subagente sin modelo asignado (opcional)                      │
 │     └─► ROUTING: Jev elige un modelo liviano o potente         │
 │                                                                │
 │  el agente dice "listo"                                        │
 │     ├─► STOP:  ¿el trabajo está hecho? ¿las afirmaciones       │
 │     │          tienen respaldo en la salida de herramientas?   │
 │     │          si no, el agente sigue una vez y lo verifica    │
 │     └─► DRIFT: (si SDD está activo) ¿el código contradice una  │
 │                regla de la spec? el agente la actualiza        │
 └────────────────────────────────────────────────────────────────┘
   │
   ▼
 respuesta
```

En palabras simples:

| Chequeo | Qué evita | Por defecto |
| --- | --- | --- |
| **Plan** | Cambios grandes sin un plan claro. Los pedidos chicos pasan. Frena como máximo dos veces por turno. | activo |
| **Ask** | Que te pregunte cosas que el código ya responde (por ejemplo, una versión fijada). Las preferencias te siguen llegando a ti. | activo |
| **Stop** | "¡Listo!" cuando no está listo, o afirmaciones ("los tests pasan") que ninguna salida muestra. | activo |
| **Drift** | Specs y registros de decisiones desactualizados tras un cambio. Solo con SDD activo. | activo |
| **Ruteo SDD** | Cambios grandes sin propuesta. Solo con SDD activo. | activo |
| **Checkpoint** | Mezclar trabajos distintos en un solo commit. Cuando un pedido nuevo no es parte del trabajo sin commitear de turnos anteriores, el agente commitea primero ese trabajo (solo sus archivos, sin push). Solo fuera de la rama principal y con tests o build en verde sobre el código actual. | activo |
| **Action** | Borrar, sobrescribir, publicar o salir del proyecto sin que lo pidas. Suma ~0,5 s por llamada. | inactivo |
| **Routing** | Usar un modelo caro para una tarea trivial de un subagente. | inactivo |

Jev no reemplaza el sistema de permisos, se suma a él. Las llamadas frenadas
aparecen como "Held" en el transcript, no como "Failed". Si Jev no responde o
no hay key, el turno sigue normal.

### Configurar Jev

Consigue una key en [TypeSafe AI](https://docs.typesafe.ai) y luego:

```bash
fx jev key       # pega la key (se guarda en el Keychain)
fx jev check     # una llamada real para confirmar que funciona
fx jev on        # lo activa para las sesiones nuevas
fx jev           # estado: chequeos, umbrales, origen de la key
fx jev off       # lo desactiva
```

Dentro de una sesión, `/jev on` y `/jev off` lo cambian y guardan la elección.

**Opcional: ruteo de modelos.** Deja que Jev elija el modelo del subagente
según la tarea:

```json
"jev": {
  "enabled": true,
  "routing": {
    "light": { "model": "deepseek-flash", "effort": "low" },
    "heavy": { "model": "deepseek-v4-pro" }
  }
}
```

**Opcional: drift en CI.** `fx jev drift [<rango-git>]` compara un diff con tus
specs o registros de decisiones y termina con error si alguno puede estar
desactualizado.

Cada decisión de Jev queda registrada en `~/.fx/sessions/<id>/decisions.jsonl`.

**Recibos de verificación.** Al terminar cada turno, fx guarda en
`~/.fx/sessions/<id>/receipts.jsonl` las corridas de tests y de build que
vinieron después del último cambio de archivos, junto con una huella del código
(el commit actual más el contenido de cada archivo cambiado o nuevo, sin contar
`sdd/`). En los turnos siguientes, el chequeo de terminado acepta esas corridas
como respaldo mientras la huella no cambie: "los tests pasan" de hace tres
turnos sigue valiendo hasta que se toque el código, y una corrida que falló
nunca respalda un "todo en verde".

Todas las opciones están en [Configuración de Jev](#configuración-de-jev).

## SDD: specs antes de los cambios grandes

SDD (desarrollo guiado por specs) mantiene una descripción pequeña y viva de
cómo se comporta tu proyecto, y hace que el agente proponga los cambios grandes
antes de programarlos. **Los arreglos chicos pasan directo, sin papeleo.**

Viene desactivado y se activa **por proyecto**. Necesita Jev activo.

### Activarlo

```bash
cd mi-proyecto
fx sdd on        # solo este proyecto; los demás siguen libres
fx sdd           # estado: specs, cambios abiertos, chequeos activos
fx sdd off
```

La barra de estado muestra `sdd` mientras está activo. Haz commit de la carpeta
`sdd/` junto con tu código.

### Qué crea

```
sdd/
├── specs/                        cómo se comporta el sistema HOY
│   └── reservas.md               cada título "## " es una regla
└── changes/                      un archivo por cambio propuesto
    └── 2026-09-27-pagos-parciales.md
```

Un archivo de cambio es corto. fx maneja el front matter:

```markdown
---
status: proposed
specs: [reservas]
---
# Pagos parciales

## Why
## What
## Tasks
- [ ] Schema
## Notes
```

### Cómo se clasifica un pedido

Antes del primer cambio de archivos, Jev pone el pedido en una de tres rutas:

```
                       tu pedido
                           │
          ┌────────────────┼───────────────────┐
          ▼                ▼                   ▼
         FIX              SPEC               CHANGE
   ninguna regla      cambio chico a     schema, dinero, auth,
   cambia             una regla que      pipeline de IA, pantalla
                      ya existe          nueva, o trabajo grande
          │                │                   │
          ▼                ▼                   ▼
    se programa     código + actualizar   propuesta en sdd/changes/,
    directo         la regla en el        espera tu "sí" y
                    mismo cambio          después se programa
```

- Los pedidos ambiguos vuelven a ti como pregunta.
- Di "no hagas propuesta" (o "skip the spec") para forzar un fix.
- Entregar trabajo terminado (commit, push, PR, notas de versión) nunca se
  clasifica.

### Vida de un cambio

```
  proposed ──(tú apruebas)──► approved ──(tú cierras)──► done
     │                           │
  el agente escribe       el agente programa, marca tareas
  la propuesta            y escribe las reglas nuevas en sdd/specs
```

Aprueba respondiendo "sí" / "sí, dale", o con `/sdd approve`. Cuando todas las
tareas están marcadas, el agente te muestra lo que hizo y te pide que lo revises;
cierra respondiendo "ok" / "perfecto, cerralo", o con `/sdd done`. Solo tú
apruebas y cierras: si el agente corre esos comandos por su cuenta, fx los frena.
Si cambias un estado con `/sdd`, fx se lo avisa al agente en su siguiente turno.

```bash
fx sdd new <slug>          # crea un archivo de cambio a mano
fx sdd approve [<nombre>]  # proposed → approved
fx sdd done [<nombre>]     # approved → done
```

Después de los turnos que cambian archivos, el chequeo de drift compara el
código con cada regla de `sdd/specs` y le pide al agente que actualice las
reglas que el código ya contradice.

## TDD: primero los tests

TDD es un complemento de SDD. Con él, los cambios de comportamiento (rutas spec
y change, y arreglos de bugs) tienen que empezar con un test que falle.

```bash
fx sdd tdd auto     # por defecto: Jev decide en cada pedido si va primero el test
fx sdd tdd on       # primero el test, siempre
fx sdd tdd strict   # además: cada regla cambiada debe citarse en un test
fx sdd tdd off
```

En modo **auto**, antes del primer cambio de código del turno Jev clasifica el
pedido: lógica o datos (`behavior`), un bug (`regression`), solo cómo se ve
(`presentation`) o algo sin comportamiento (`trivial`), y si un test unitario
podría comprobarlo sin leer el código como texto. Los cambios de lógica y los
bugs van con test primero; los de presentación y los triviales no, pero los
tests igual tienen que pasar después del último cambio. Si Jev no responde o
duda, el cambio va con test primero, como en `on`. La decisión queda en el
registro de Jev de la sesión.

### Qué exige fx

```
  1. ROJO     cambiar un test, correrlo y verlo FALLAR
                  │   (los cambios al código se frenan hasta que pase esto)
                  ▼
  2. CÓDIGO   cambiar el código
                  │
                  ▼
  3. VERDE    correr los tests otra vez y verlos PASAR
                  │   (la respuesta se frena hasta que pase esto)
                  ▼
  4. JEV      ¿el test nuevo fallaría sin este comportamiento?
```

fx lo lee de la salida de las herramientas del propio turno, así que el agente
no puede solo decirlo. Reconoce `bun test`, `npm test`, `pytest`, `go test`,
`cargo test`, `zig build test` y otros. Para cualquier otro, define
`"test": "<comando>"` dentro de `sdd` en la configuración.

En modo **strict**, cada test cita la regla que cubre:

```ts
// spec: reservas › Saldo es el monto pendiente
test("resta los pagos", () => { ... });
```

Una regla cuyo título termina en `(manual)`, o un cambio con `tdd: manual`, se
comprueba en la app corriendo. fx relee esas marcas antes de frenar un cambio,
así que agregarlas a mitad de turno también cuenta. Un fix o actualización de spec que crece a más
de 8 archivos de código se frena una vez para que el agente proponga un cambio.

## Permisos y reglas del proyecto

**Permisos.** `/permissions` cambia entre:

| Modo | Comportamiento |
| --- | --- |
| `ask` | Pide confirmación para acciones sensibles |
| `auto` | Decide una revisión de seguridad |
| `full-access` | Sin chequeos de fx |

`fx ask --auto` o `--full-access` aplican a una sola ejecución.

**Reglas del proyecto.** fx lee `AGENTS.md` en la raíz del proyecto, más
`~/.fx/AGENTS.md` para reglas que aplican en todos lados. Mantenlo corto: qué
es la app, el stack y las convenciones que el código no muestra (idioma de
respuesta, gestor de paquetes, dónde viven los tests).

## Dónde vive la configuración

| Qué | Dónde | Se sobrescribe con |
| --- | --- | --- |
| Keys de proveedores y de Jev | Keychain de macOS (`fx login`, `fx jev key`) | `DEEPSEEK_API_KEY`, `DASHSCOPE_API_KEY`, `TYPESAFE_API_KEY`, ... |
| Proveedor, modelo, permisos, Jev | `~/.fx/settings.json` | `FX_PROVIDER`, `FX_MODEL`, `FX_PERMISSION_MODE`, `FX_JEV=on\|off` |
| SDD y TDD, por proyecto | `~/.fx/settings.json` → `workspaces["<ruta>"].sdd` | `FX_SDD=on\|off` |
| Valores del proyecto que se pueden commitear | `<proyecto>/.fx.json` | |
| Sesiones, registro de decisiones, recibos y trabajo de Jev | `~/.fx/sessions/<id>/` (`decisions.jsonl`, `receipts.jsonl`, `work.jsonl`) | |

Fuera de macOS, las keys guardadas van a un archivo privado en
`~/.fx/provider-keys`. La configuración de Jev y SDD vive solo en tu perfil: el
`.fx.json` de un proyecto no puede activarlos.

## Referencia

### Compilar desde el código

Requiere Zig 0.16.0.

```bash
zig build                              # genera zig-out/bin/fx
zig build test                         # corre los tests unitarios
zig build test -Dtest-filter="preset"  # corre un subconjunto
./zig-out/bin/fx                       # abre una sesión interactiva
```

### Campos del proveedor

```jsonc
{
  "providers": {
    "deepseek": {
      "protocol": "openai-chat-completions",
      "base_url": "https://api.deepseek.com",
      "auth": { "type": "bearer", "env": "DEEPSEEK_API_KEY" },
      "tool_choice_mode": "send",
      "default_model": "deepseek-flash",
      "reasoning_format": "thinking_effort",
      "model_metadata": {
        "deepseek-flash": { "context_window": 1048576, "max_output_tokens": 393216, "supports_tool_use": true, "reasoning_efforts": ["none", "low", "high", "max"] }
      }
    }
  }
}
```

| Campo | Significado |
| --- | --- |
| `reasoning_format` | Cómo se envía `--effort`: `reasoning_effort` (por defecto), `thinking`, `thinking_effort` (DeepSeek V4), `enable_thinking`, `openrouter` o `none` |
| `model_metadata.<id>.reasoning_efforts` | Niveles que acepta el modelo; activa el selector de razonamiento |
| `default_model` | Modelo que se usa cuando ni `FX_MODEL` ni las preferencias guardadas eligen uno |
| `merge_system_messages` | Une mensajes de sistema contiguos (por defecto `true`) |
| `strict_stream` | Exige el formato de stream estricto de OpenAI (por defecto `false`) |
| `tool_choice_mode` | `send` envía `tool_choice`; `omit` (por defecto) no lo envía |

### Configuración de Jev

Dentro de `jev` en `~/.fx/settings.json`:

| Campo | Significado |
| --- | --- |
| `enabled` | Activa las decisiones de Jev (por defecto `false`) |
| `model` | Modelo de Jev (por defecto `jev-latest`) |
| `gates.ask` | Deja que Jev responda preguntas que el contexto ya resuelve (por defecto `true`) |
| `gates.plan` | Exige un plan antes de cambios en pedidos grandes (por defecto `true`) |
| `gates.drift` | Marca registros de decisiones que el cambio contradice (por defecto `true`) |
| `gates.sdd` | Con SDD activo, clasifica el primer cambio como fix, spec o change (por defecto `true`) |
| `gates.checkpoint` | Commitea el trabajo verificado de turnos anteriores antes de empezar un trabajo distinto (por defecto `true`) |
| `gates.action` | Revisa cambios de archivos y comandos de shell (por defecto `false`) |
| `gates.stop` | Corre el chequeo de finalización (por defecto `true`) |
| `thresholds.ask` | Confianza y respaldo mínimos para responder (por defecto `0.8`) |
| `thresholds.plan` | Probabilidad mínima que deben alcanzar los chequeos del plan (por defecto `0.5`) |
| `thresholds.action` | Probabilidad de daño no pedido que frena una acción (por defecto `0.6`) |
| `thresholds.stop` | Probabilidad mínima de cada chequeo de finalización (por defecto `0.5`) |
| `routing.<nombre>` | `model`, `effort` opcional y `description` de una ruta de subagente |

`TYPESAFE_API_KEY`, `FX_JEV=on|off`, `FX_JEV_MODEL` y `FX_JEV_BASE_URL`
sobrescriben los valores guardados.

Rutas: `light` y `heavy` traen descripción incluida; otros nombres necesitan
`description`. El ruteo necesita al menos dos rutas con modelos del proveedor
activo.

Fuentes de drift: `sdd/specs` (cada regla `## ` se revisa por separado), o un
archivo Markdown por decisión en `sdd/decisions`, `docs/decisions`, `docs/adr`
o `decisions` (front matter `title`/`status`/`description` opcional). Cada
registro se marca una vez por sesión.

`fx jev eval [stop|plan|action|ask|routing|sdd|close|tdd|checkpoint]` corre casos etiquetados con las
mismas preguntas y umbrales que los chequeos reales, para probar cambios de
umbral o de modelo antes de usarlos.

### Configuración de SDD

Por proyecto en `~/.fx/settings.json` → `workspaces["<ruta>"].sdd`: `enabled`,
`tdd` (`off`, `auto`, `on`, `strict`; `auto` por defecto) y `test` (un comando de tests propio). Un
`"sdd": {"enabled": true}` en el nivel superior define el valor por defecto
para todos los proyectos. `FX_SDD=on|off` lo sobrescribe para una shell o una
ejecución de CI.

### Búsqueda web

La herramienta `web_search` funciona con cualquier proveedor una vez que
configuras una API de búsqueda:

| Backend | Variable |
| --- | --- |
| Tavily | `TAVILY_API_KEY` (admite dominios permitidos/bloqueados) |
| Brave Search API | `BRAVE_API_KEY` |
| SearXNG (propio, con formato JSON activado) | `FX_SEARXNG_URL=http://host:8080` |

Si hay varios, se prefieren en ese orden; `FX_WEB_SEARCH_BACKEND` fija uno.
`web_fetch` funciona sin configuración.

### Qué cambió respecto al fx original

- Un lector de streams tolerante acepta las desviaciones comunes de las APIs
  compatibles con OpenAI (tool calls terminados con `stop`, `[DONE]` que falta,
  tool deltas sin índice, finish reasons propios) y sigue rechazando
  herramientas desconocidas y argumentos mal formados.
- Presets de proveedores, controles de razonamiento y descubrimiento de modelos
  para proveedores configurados.
- Decisiones con Jev y los procesos SDD y TDD.
- Se quitaron los proveedores por suscripción de Codex y Grok.
- Las keys se guardan por preset en el Keychain (`FX_PROVIDER_KEY_<id>`) o en
  `~/.fx/provider-keys`.
- `fx upgrade` y las actualizaciones automáticas están desactivadas; usa
  `fx update`.

El README original se conserva en [docs/UPSTREAM_README.md](docs/UPSTREAM_README.md).
Partes de él (login de Vercel, ruteo por gateway, Slack) no aplican a este fork.

## Licencia

Apache-2.0. Ver [LICENSE](LICENSE) y [NOTICE](NOTICE). Este fork no está
afiliado ni respaldado por Vercel, Inc.
