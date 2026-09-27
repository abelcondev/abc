# fx (fork): propuesta de fork de fx abierto a cualquier modelo

> Base: `vercel-labs/fx` @ `59bf437` (2026-09-25), Zig 0.16+, Apache-2.0.
> Modalidad: **hard fork**. Se corta el vínculo con upstream; no hay sincronización periódica.
> Nombre del proyecto y del binario: **`fx`** (se vuelve al nombre original; `abc` queda descartado, ver sección 10).
>
> Decisiones tomadas:
> - Hard fork, sin sincronizar con upstream.
> - ~~Nombre `abc`.~~ Se mantiene el nombre `fx` (2026-09-26). Este fork reemplaza al fx original en la máquina; el original no se usará más.
> - Jev (TypeSafe AI) entra como el componente que toma decisiones dentro del harness (sección 11).
> - Se eliminan Vercel AI Gateway, Codex y Grok. Solo quedan proveedores por API key o endpoints locales.
> Estado: borrador para arrancar. Las causas marcadas como **hipótesis** hay que confirmarlas con el error real (ver Fase 1).

## Estado (2026-09-26)

| Fase | Estado | Notas |
|---|---|---|
| 0. Fork | ✅ | Repo local con historial, binario `abc`, fingerprint nuevo, upgrades desactivados, CI mínima. Repo `abelcondev/abc` creado en GitHub (privado, Actions apagadas); **falta el push** (el token de `gh` no tiene scope `workflow`). |
| 1. Reproducir | 🟡 | Servidor falso con rarezas de stream + pruebas reales con DeepSeek. Con la API actual de DeepSeek incluso el lector estricto funciona; el error original no se pudo reproducir con DeepSeek hoy. Qwen/Kimi/GLM sin probar (sin keys). |
| 2. Lector tolerante | ✅ | `strict_stream` para volver al modo estricto. |
| 3. Opciones/capacidades | ✅ | `reasoning_format` (incluye `thinking_effort`), `reasoning_efforts`, fusión de `system`, HTTP en LAN, sin `UnsupportedProviderOption`. |
| 4. Presets | ✅ | 22 presets, autodetección por API key, `/provider` los lista, `abc login <preset>` guarda la key, catálogo desde `GET /models` con metadata. |
| 5. Búsqueda web | ✅ | Tavily / Brave / SearXNG para cualquier proveedor. Visión fallback y contabilidad local de uso: pendientes. |
| 6. Quitar Vercel | 🟡 | Codex y Grok eliminados (−13k líneas). `~/.abc`, `.abc.json`, `ABC_*`. Onboarding nuevo. **Pendiente:** eliminar el gateway de Vercel (sigue como fallback), textos "fx" restantes en ayuda y mensajes, Slack, SDK wasm. |
| 7. Anthropic Messages | ⬜ | No empezado. |
| 8. Volver al nombre `fx` | ✅ | Binario `fx`, `~/.fx`, `.fx.json`, `FX_*`; alias `ABC_*` eliminado; keys `ABC_PROVIDER_KEY_*` se migran solas al leerlas. |
| 9. Jev como decisor | 🟡 | Hecho: `fx jev`, transporte, registro `decisions.jsonl`, plan antes de cambios (hook `PreToolUse`) y cierre verificado (hook `Stop`). `/jev [on|off]` en el chat. Pendiente: acciones, `ask_user_question`, routing. |

## 1. Objetivo

Que fx trate a DeepSeek, Qwen, Kimi, GLM, MiniMax, Ollama/vLLM/llama.cpp, OpenRouter, etc. como proveedores de primera clase, con el mismo nivel de soporte que hoy tiene Vercel AI Gateway: tools, subagentes, compactación, razonamiento, caching, visión y búsqueda web. Sin depender de Vercel para nada.

No es objetivo reescribir el agente. El núcleo (orquestador, tools, sesiones, TUI, MCP, skills) funciona bien y se conserva. El trabajo se concentra en la capa de proveedores.

## 2. Diagnóstico: por qué fallan hoy los modelos custom

El camino "custom connection" (`~/.fx/settings.json` → proveedor `configured`) usa un único códec OpenAI Chat Completions: `src/gateway/chat_completions_protocol.zig`. Fue escrito como un validador **estricto** de la especificación de OpenAI. Cualquier desviación del proveedor aborta el turno. Los proveedores chinos y los servidores locales se desvían bastante.

### 2.1 Parser de streaming demasiado estricto (causa más probable)

Todas son rutas `return error.X` en `Reducer.accept` / `accept_tools` / `finish`:

| Chequeo estricto | Línea | Desviación real que lo dispara |
|---|---|---|
| `finish_reason == "tool_calls"` si y solo si hay tool calls, si no `InconsistentFinishReason` | ~976 | Muchos proveedores devuelven `"stop"` aunque haya tool calls (Qwen/DashScope en algunos modos, Ollama, vLLM, llama.cpp) |
| `finish_reason` solo acepta `stop`, `tool_calls`, `length`, `content_filter` | 764 | DeepSeek: `insufficient_system_resource`; otros: `tool_call`, `function_call`, `eos` |
| Después del chunk final, `delta` solo puede traer `role` y `content`, y el chunk debe repetir `finish_reason` y traer `usage` | 736-748 | Chunk de usage con `delta: {"reasoning_content": null}`, `finish_reason: null` o sin `usage` |
| El stream debe terminar en `[DONE]` | 710, `finish` | Algunos servidores cierran la conexión sin `[DONE]` |
| `choices: []` antes del final → `InvalidChunk` | 728 | Chunks iniciales vacíos (filtros de contenido, keep-alives) |
| `tool_calls[].index` obligatorio | 867 | Algunos servidores lo omiten (compat de Gemini, llama.cpp viejo) |
| El `id` de la tool call no puede cambiar ni venir vacío | 853-857 | Proveedores que mandan `id: ""` en deltas de continuación, o un id nuevo por delta |
| `function.name` se **concatena** en cada delta | 880-884 | Si el proveedor repite el nombre completo en cada delta queda `read_fileread_file` y falla con `InvalidToolName` |
| `id` y `model` del chunk no pueden cambiar entre chunks | 721-722 | Routers (OpenRouter) o balanceadores que varían el `model` |
| `total_tokens == prompt + completion` exacto | ~925 | Proveedores que suman tokens cacheados o de razonamiento aparte |
| Argumentos deben ser JSON válido | `validate_arguments` | `arguments: ""` para tools sin parámetros |

### 2.2 Opciones rechazadas en lugar de degradarse

`validate_request` (línea 168) devuelve `UnsupportedProviderOption` si llega `reasoning`, `fast` o `prompt_caching`, y `UnsupportedVision` si `vision_mode != .unavailable`. El orquestador intenta no mandarlas a proveedores sin capacidad, pero cualquier ruta secundaria (compactación, título, subagente, reviewer de permisos) que las mande rompe. **Hipótesis:** esto puede explicar los errores en subagentes.

### 2.3 Capacidades en `false` por defecto

`src/gateway/chat_completions.zig:205` (`metadata_entry`): si un modelo no está declarado en `model_metadata`, o no tiene `supports_tool_use: true`, queda con `has_tool_use = false`, `context_window = 0` y `max_tokens = 0`. **Hipótesis:** con eso el agente puede no ofrecer tools o calcular mal la compactación.

### 2.4 Funciones solo del gateway

`src/core/gateway/provider_set.zig:129` y `src/builtins/gateway.zig:159`: `fx_search` (búsqueda web), `vision_fallback` y `gateway_prompt_caching` solo existen para Vercel. Codex y Grok tienen su propio stream, catálogo y permission reviewer. `configured` no tiene nada de eso.

### 2.5 Acoplamiento a Vercel

Unos 40 archivos referencian `ai-gateway.vercel.sh`, `vercel.com` o `fx.sh`: login OAuth por dispositivo, uso y facturación de sesiones (`session_usage*`, `generation_usage_provider`), ACP, `fx ask`, upgrades (`src/core/upgrade/upgrade_helpers.zig:21` → `releases.fx.sh`), Slack y docs.

## 3. Principios del fork

1. **Tolerante al leer, estricto al ejecutar.** Normalizar las desviaciones del stream, pero nunca ejecutar una tool call con nombre desconocido o argumentos inválidos. Esas garantías de seguridad del upstream se mantienen.
2. **Quirks declarativos, no `if proveedor == ...` desparramados.** Cada proveedor es un *perfil* con flags de compatibilidad y mapeo de opciones.
3. **Degradar en vez de fallar.** Si el proveedor no soporta una opción, se omite y se registra en `FX_TRACE`; no se aborta el turno.
4. **Libertad para reestructurar, en pasos chicos.** Sin upstream que respetar, se puede mover, renombrar y borrar código. Aun así, cada cambio va en un commit acotado, con `zig build test` en verde y el binario probado, para no romper un código de ~700k líneas que no escribimos.
5. **Cada quirk entra con un fixture SSE real** grabado del proveedor y un test.

## 4. Arquitectura propuesta

```
settings.json / catálogo integrado
          │
          ▼
  ProviderProfile ──────────────┐
  (id, base_url, auth, protocol,│
   compat flags, option mapping,│
   capacidades por modelo)      │
          │                     │
          ▼                     ▼
  Protocolo              Servicios opcionales
  ├─ openai-chat  (existe, + modo compat)   ├─ web_search (Tavily/Brave/Exa/SearXNG)
  ├─ anthropic-messages (nuevo)             ├─ vision fallback (modelo de visión configurable)
  └─ openai-responses (reusar responses_protocol.zig)  └─ permission reviewer (modelo configurable)
```

### 4.1 `ProviderProfile` (extiende `configured_provider.Definition`)

Campos nuevos en settings, todos opcionales, con defaults según el preset:

```jsonc
{
  "providers": {
    "deepseek": {
      "preset": "deepseek",                 // hereda compat + mapeo de opciones
      "protocol": "openai-chat-completions",
      "base_url": "https://api.deepseek.com/v1",
      "auth": { "type": "bearer", "env": "DEEPSEEK_API_KEY" },
      "compat": {
        "lenient_stream": true,
        "finish_reason_from_tool_calls": true,  // inferir tool_calls aunque diga "stop"
        "tool_name_mode": "concat" | "replace", // cómo se acumula function.name
        "require_done": false,
        "empty_arguments_as_object": true,
        "strict_usage": false
      },
      "options": {
        "reasoning": { "param": "reasoning_effort" }, // o "thinking": {...}, "enable_thinking", etc.
        "prompt_caching": "auto" | "cache_control" | "none",
        "max_tokens_param": "max_tokens" | "max_completion_tokens"
      },
      "models": "auto",                     // GET /models + defaults del preset
      "model_metadata": { "…": { "context_window": 128000, "supports_tool_use": true } }
    }
  }
}
```

Presets iniciales: `generic`, `deepseek`, `qwen` (DashScope intl/cn), `moonshot` (Kimi), `zhipu` (GLM), `minimax`, `openrouter`, `ollama`, `vllm`, `llamacpp`, `lmstudio`. Los valores exactos de cada preset salen de los fixtures de la Fase 1, no de suposiciones.

### 4.2 Protocolo `anthropic-messages` (fase posterior)

Varios proveedores (DeepSeek, Kimi, GLM y MiniMax, entre otros) exponen además endpoints compatibles con Anthropic Messages. Su tool calling y su caching suelen ser más fieles ahí que en el modo OpenAI. Tener este protocolo también habilita Claude directo, sin gateway.

## 5. Plan por fases

### Fase 0: preparar el fork (0,5-1 día)
- [ ] **No usar el botón "Fork" de GitHub**, porque mantiene el vínculo de red y el "forked from". En su lugar: `git clone` del original, borrar el remoto `origin` y hacer push a un repo nuevo propio. Recomendado conservar el historial (sirve para `git blame`); alternativa: squash a un commit inicial.
- [ ] Anotar en el README el commit base (`59bf437`) del que se partió.
- [ ] Renombrar a `abc`: binario (`zig-out/bin/abc`), `.name` en `build.zig.zon` y README. "fx" y la marca Vercel no están cubiertos por la licencia (Apache-2.0 §6 no otorga derechos de marca). Quitar logos y badges de Vercel.
  - El directorio de config (`~/.fx`) y el prefijo de variables (`FX_*`, usado en ~56 archivos) se renombran a `~/.abc` y `ABC_*` en la Fase 6, no ahora, para que la Fase 0 sea solo "compila y corre".
- [ ] Instalar Zig 0.16.x (hoy no está instalado en esta máquina), con la versión exacta que pide `build.zig.zon`.
- [ ] Obligaciones de Apache-2.0: conservar `LICENSE` y `THIRD_PARTY_NOTICES.md`, mantener los avisos de copyright existentes y dejar constancia de que los archivos fueron modificados (p. ej. una sección en el README y el historial de git).
- [ ] Regenerar `.fingerprint` en `build.zig.zon` (lo pide el propio archivo para forks) y cambiar `.name`.
- [ ] Apuntar `fx upgrade` a tus releases o deshabilitarlo (`upgrade_helpers.zig:21`). Si no, bajaría binarios del original encima del tuyo.
- [ ] Verificar `zig build`, `zig build test` y `./zig-out/bin/fx` en macOS arm64.
- [ ] CI mínima: build y tests unitarios (recortar los workflows de PGSO, firma y CDN de Vercel).

### Fase 1: reproducir y capturar (1-2 días) ← primero, antes de tocar código
- [ ] Reproducir el error original con `FX_TRACE=1 FX_TRACE_LOG=… ./zig-out/bin/fx` para cada proveedor objetivo: turno simple, tool call, varias tools en paralelo, subagente, compactación.
- [ ] Anotar el `error.X` exacto y la ruta (principal / subagente / título / reviewer / compactación).
- [ ] Grabar los streams SSE crudos (un proxy local o `curl -N`) como fixtures en `tests/fixtures/providers/<preset>/*.sse`.
- [ ] Armar la matriz de la sección 6 con el resultado real.

### Fase 2: modo compat en el códec Chat Completions (3-5 días)
- [ ] Agregar `Compat` a `codec.Limits` (o una struct hermana) y pasarlo desde la `Definition`.
- [ ] Con `lenient_stream`: aceptar `choices: []` intermedios, chunks finales sin usage o con campos nulos extra, ausencia de `[DONE]` si hubo `finish_reason`, `id`/`model` variables y usage inexacto.
- [ ] Normalizar `finish_reason`: inferir `tool_calls` cuando hay tool calls; mapear valores desconocidos a `stop` o a un error legible.
- [ ] Tool calls: `index` implícito por orden, `id` vacío en continuación, `tool_name_mode: replace`, generar un id si falta y `arguments: ""` → `{}`.
- [ ] Mantener estrictos: nombre de tool conocido, JSON válido al final, límites de tamaño.
- [ ] Tests con los fixtures de la Fase 1.

### Fase 3: degradar opciones y capacidades (2-3 días)
- [ ] `validate_request`: con perfil que no soporta la opción, **omitirla** (con trace) en vez de `UnsupportedProviderOption`.
- [ ] Mapeo de razonamiento por preset (`reasoning_effort`, `thinking`, `enable_thinking`, presupuesto de tokens…).
- [ ] Prompt caching: `auto` (sin campos; DeepSeek cachea solo) o `cache_control` donde el proveedor lo soporte.
- [ ] Defaults sensatos cuando falta metadata: asumir `supports_tool_use: true` y un `context_window` conservador (p. ej. 32k) en vez de 0, configurable.
- [ ] Auditar las rutas secundarias (compactación, título, subagentes, reviewer) para que usen las capacidades del perfil.

### Fase 4: proveedores de primera clase (3-4 días)
- [ ] Presets integrados en `provider_catalog.zig` y `builtins/providers.zig`, siguiendo el patrón de `xai_grok*`.
- [ ] `fx login <preset>`: pedir la API key y guardarla en el secret store existente (`src/core/auth/secret.zig`).
- [ ] Catálogo automático vía `GET {base_url}/models`, enriquecido con metadata del preset.
- [ ] Selector de modelos (`/model`) y `fx provider` mostrando los presets.

### Fase 5: reemplazar funciones que hoy solo da el gateway (3-5 días)
- [ ] Búsqueda web enchufable implementando `web_search_provider.Provider`: Tavily, Brave, Exa y SearXNG (self-hosted).
- [ ] Vision fallback: permitir configurar un modelo de visión de cualquier proveedor.
- [ ] Permission reviewer: ya existe `reviewer_model`; extenderlo a cualquier preset.
- [ ] Contabilidad de uso local (tokens por sesión) sin depender de la API de uso de Vercel.

### Fase 6: eliminar Vercel (3-5 días)
- [ ] Proveedor por defecto configurable; el primer arranque ofrece los presets.
- [ ] Borrar el proveedor `gateway` y su protocolo (`src/builtins/gateway*`, `src/gateway/vercel_*`, `src/core/gateway/gateway_provider.zig`), el login OAuth de Vercel, la API de uso y facturación, la integración de Slack y el CDN de `fx.sh`. Si algún día hace falta, el AI Gateway sigue siendo usable como un preset `generic` OpenAI-compatible.
- [ ] Borrar Codex y Grok: `src/gateway/openai_codex*.zig`, `src/gateway/xai_grok*.zig`, `src/core/auth/chatgpt_*.zig`, `src/core/auth/grok_*.zig`, sus entradas en `provider_catalog.zig` y `builtins/providers.zig`, los comandos `login codex` / `login grok` y sus tests. Conservar `src/gateway/responses_protocol.zig` si se quiere soportar el protocolo OpenAI Responses de forma genérica.
- [ ] Revisar si el login OAuth genérico (`src/core/auth/oauth*.zig`) sigue haciendo falta: MCP lo usa para autenticar servidores, así que probablemente se queda.
- [ ] Renombrar `~/.fx` → `~/.abc` y `FX_*` → `ABC_*` (config, variables de entorno, `.fx.json` del proyecto → `.abc.json`).
- [ ] Limpiar las referencias restantes a `vercel.com`/`fx.sh` en ACP, `fx ask`, sesiones, SDK wasm (`libfx`), ejemplos y docs.
- [ ] Recortar CI: fuera los workflows de PGSO, firma y notarización, CDN y publicación en npm de Vercel.
- [ ] README propio y changelog del fork.

Conviene hacer esta fase **después** de la 3: primero que los modelos nuevos funcionen, después borrar el camino viejo.

### Fase 7: protocolo `anthropic-messages` (opcional, 4-6 días)
- [ ] Nuevo códec con tool_use, thinking con firma y `cache_control`.
- [ ] Presets `*-anthropic` para los proveedores que lo expongan, más Anthropic directo.

Estimación total sin la Fase 7: **~3-4 semanas** de una persona. El orden permite usar el fork desde el final de la Fase 3.

## 6. Matriz de pruebas por proveedor

Completar en la Fase 1 y mantener actualizada:

| Preset | Texto | 1 tool | Tools paralelas | Subagente | Compactación | Razonamiento | Caching | Visión |
|---|---|---|---|---|---|---|---|---|
| deepseek | | | | | | | | |
| qwen | | | | | | | | |
| moonshot | | | | | | | | |
| zhipu | | | | | | | | |
| ollama | | | | | | | | |
| openrouter | | | | | | | | |

Y una prueba E2E real por preset con el binario (`./zig-out/bin/fx ask`), como exige `AGENTS.md`.

## 7. Mantenimiento sin upstream

- Todo el mantenimiento es propio: bugs del agente, TUI, MCP, sesiones y compatibilidad con nuevas versiones de Zig.
- Mirar de vez en cuando el changelog de `vercel-labs/fx` solo por **parches de seguridad** (permisos, ejecución de shell, MCP) y portarlos a mano si aplican. Es opcional, no un proceso fijo.
- Como ya no importa chocar con upstream, conviene ir simplificando: borrar módulos que no se usen reduce lo que hay que mantener.
- Los fixtures por proveedor y `zig build test` son la red de seguridad de cada cambio.

## 8. Riesgos

- **Mantenimiento en solitario:** ~700k líneas que pasan a ser responsabilidad propia, sin los arreglos que siga haciendo Vercel. Mitigación: borrar lo que no se use (Fase 6) y la sección 7.
- **Marca y licencia:** usar un nombre propio y cumplir Apache-2.0 (Fase 0).
- **Zig 0.16:** toolchain joven; fijar la versión exacta en CI.
- **Seguridad:** relajar el parser no debe permitir ejecutar tool calls malformadas; se mantienen las validaciones finales.
- **Deriva de proveedores:** los proveedores cambian su compat sin avisar; los fixtures versionados ayudan a detectarlo.

## 9. Próximos pasos inmediatos

1. Pasar el `settings.json` que usaste y el texto exacto del error (o un trace con `FX_TRACE=1`).
2. Definir los 2-3 proveedores prioritarios para la Fase 1.
3. Instalar Zig 0.16.x.
4. Ejecutar la Fase 0 (repo nuevo `abc` + build local).

## 10. Nombre: se mantiene `fx`

**Decisión (2026-09-26):** el fork deja de llamarse `abc` y vuelve a llamarse `fx`. Este fork pasa a ser *el* fx de esta máquina: el fx original de Vercel no se va a usar más, así que no importa que ambos choquen.

### Consecuencias aceptadas

- **No se puede tener el fx original instalado al mismo tiempo.** Los dos usan el binario `fx`, el directorio `~/.fx`, el archivo `.fx.json` y las variables `FX_*`. Se desinstala el original (`~/.fx/bin/fx` y cualquier copia en el `PATH`) y se usa solo este fork.
- **La configuración se comparte con lo que haya dejado el original en `~/.fx`.** Antes del primer arranque, revisar `~/.fx/settings.json` y borrar lo que sea del gateway de Vercel, Codex o Grok (ya no existen en el fork).
- **Nada de upgrades del original.** `fx upgrade` y el auto-upgrade siguen apuntando a los releases propios (o desactivados). Si apuntaran a `releases.fx.sh` reemplazarían el fork por el original.
- **Marca.** Apache-2.0 §6 no da derechos sobre el nombre "fx" ni la marca Vercel. Para uso personal y un repo privado no hay problema; si algún día el fork se publica o distribuye, hay que volver a decidir el nombre. Los logos y badges de Vercel siguen fuera.

### Qué se revierte (Fase 8)

- Binario `zig-out/bin/abc` → `zig-out/bin/fx`, `.name` en `build.zig.zon`, banner y pistas de "resume".
- `~/.abc` → `~/.fx`, `.abc.json` → `.fx.json`.
- Variables `ABC_*` → `FX_*`. El alias que acepta `ABC_X` además de `FX_X` (`src/core/shared/io.zig:415`) se elimina.
- Keys guardadas: servicio de Keychain `ABC_PROVIDER_KEY_<id>` → `FX_PROVIDER_KEY_<id>` y `~/.abc/provider-keys/` → `~/.fx/provider-keys/`. Migrar las keys existentes una sola vez (leer la ubicación vieja si la nueva no existe) o volver a cargarlas con `/provider`.
- Comandos y textos (`abc login`, `abc update`, ayuda, README, instalador curl, workflow de release de macOS).
- Repo en GitHub: puede seguir siendo `abelcondev/abc` o renombrarse; no afecta al binario.

Se hace como un commit acotado, con `zig build test` en verde y `./zig-out/bin/fx` probado, igual que el resto de las fases.

## 11. Jev como el que toma decisiones

### Qué es Jev

Jev (`jev-latest`, hoy `jev-1.13.0`) es el modelo "System One" de TypeSafe AI (https://docs.typesafe.ai). No genera texto: recibe un `state` y un conjunto de preguntas tipadas y devuelve respuestas con probabilidades calibradas.

- `noul`: sí/no, devuelve una probabilidad de 0 a 1.
- `choice`: una opción entre hasta 255, con `probabilities` y `confidence`.
- `score`: un nivel dentro de una escala de 2 a 10 niveles.

API propia (no es compatible con OpenAI): `POST https://api.typesafe.ai/v1/systemone` con `Authorization: Bearer <key>`. Cuesta $0.042 por millón de tokens de entrada (la salida es gratis), 64k de contexto, 1200 requests por minuto. Una prueba real con una decisión del harness respondió en ~390 ms con ~500 tokens.

Los propios docs dicen que **no reemplaza al modelo del agente**: el modelo principal (DeepSeek, Qwen, etc.) sigue escribiendo código y llamando tools. Jev solo contesta preguntas atómicas que arma el código del harness, y el código combina las respuestas.

**Límites que el diseño respeta:** es malo en matemáticas, conteo y fechas; empeora con `state` grande y ruidoso; el texto con prompt injection dentro del `state` puede moverlo. Por eso las reglas duras y la seguridad siguen en código y en el sistema de permisos existente. Jev juzga significado, no autoriza por sí solo acciones peligrosas.

### Qué se aprende de waliki1

En waliki1, Mimi ya usa Jev para elegir el skill (`choice`) y para validar cada escritura (`apply_ok`, un `noul`). Y el SDD de waliki1 muestra los problemas a resolver:

- Specs que quedan desactualizados respecto al código, sin nada que lo detecte.
- Criterios Gherkin que nadie ejecuta; "done" se marca a mano.
- Todo el registro es manual (numerar, mover la propuesta a una decisión, `log.md`, relabelar tras el merge).
- `log.md` + `context.md` crecen sin límite (~1900 líneas leídas en cada sesión).
- Jev falla abierto: si la llamada falla o el parser lee mal, la escritura pasa igual. Ya ocurrió un bug así que nadie notó. Los umbrales (0.6, 0.5) están puestos a ojo.

### La idea: un SDD vivo dentro del harness

En vez de markdown mantenido a mano, el harness guarda el contrato de cada tarea (pedido + criterios de aceptación atómicos) y Jev lo valida en cada etapa:

| Etapa | Pregunta a Jev | Dónde se enchufa |
|---|---|---|
| 1. Triage | `choice`: ¿trivial, pequeño o sustancial? | Inicio del turno |
| 2. Plan | Si es sustancial: modo `plan` de solo lectura; el agente propone plan + criterios. `noul`: ¿cubre el pedido?, ¿agrega trabajo no pedido?, ¿cada criterio es verificable? | Nuevo `ModeSpec` en `src/builtins/modes.zig` (hoy no hay plan mode) |
| 3. Acciones | `noul`: ¿los argumentos de la tool reflejan lo pedido? (el `apply_ok` de Mimi) | Hook `PreToolUse` (`src/core/hooks/`). Complementa al revisor de seguridad, no lo reemplaza |
| 4. Cierre | Un `noul` por criterio: ¿la evidencia real (salida de tests, diff) demuestra que se cumple? Si alguno queda bajo, el agente sigue con la lista de lo que falta | Hook `Stop` con `continue_once` (hoy no hay ninguno registrado) |
| 5. Preguntas al usuario | `ask_user_question` se convierte en un `choice`: con confianza alta decide Jev, si no se pregunta al humano | `ask_question_batch` en `src/core/tooling/tool_dispatch.zig` |
| 6. Routing | `choice`: qué proveedor/modelo y esfuerzo usar para una subtarea | Subagentes |

Además:

- **Registro automático de decisiones:** cada llamada (preguntas, probabilidades, umbral, resultado) se guarda en `~/.fx/sessions/<id>/decisions.jsonl`. Reemplaza el `log.md` manual; las decisiones importantes se pueden exportar al repo como archivos cortos.
- **Detección de specs desactualizados:** un `choice` sobre los títulos de las decisiones previas elige cuáles aplican a un diff, y un `noul` pregunta si el cambio contradice alguna.

### Configuración

Solo en el perfil (`~/.fx/settings.json`), nunca en el `.fx.json` del proyecto (se agrega a `isProfileOnlySettingKey`):

```jsonc
"jev": {
  "enabled": true,
  "model": "jev-latest",
  "base_url": "https://api.typesafe.ai",
  "gates": { "triage": true, "plan": true, "action": false, "stop": true, "ask": true },
  "thresholds": { "plan": 0.7, "stop": 0.6, "ask_auto": 0.8 },
  "on_error": "ask"          // "ask" (escalar al humano) | "open" | "closed"
}
```

- **Key:** en el Keychain con `provider_keys` (id `typesafe`); `TYPESAFE_API_KEY` exportada tiene prioridad. Nunca en archivos del repo.
- **`/jev`:** muestra el estado, pide la key con campo enmascarado (como `/provider`) y prende o apaga cada etapa. Variables `FX_JEV_*` para overrides.
- **Si Jev falla:** por defecto se escala al humano, no se deja pasar en silencio como en Mimi.

### Arquitectura

- `src/gateway/typesafe.zig`: transporte HTTP (patrón de `src/builtins/web_search_api.zig`), con reintentos para 429/529/5xx y timeout corto.
- `src/core/decisions/`: contrato tipado de preguntas y respuestas, umbrales, registro `decisions.jsonl`.
- Etapas enchufadas en los hooks, modos y dispatch existentes; nada de lógica nueva en `main.zig`.
- Tests: parser de respuestas con fixtures reales (para no repetir el bug de waliki), y un set de evals en `tests/evals/` para calibrar los umbrales.

### Fases

1. ✅ Configuración, `fx jev`, transporte, registro y etapa 4 (cierre verificado). Implementado como comando de CLI (`fx jev [on|off|key|forget|check]`); el `/jev` dentro del chat queda para después. Sin `on_error` por ahora: si Jev falla, el turno termina normal y el registro lo anota.
2. ✅ Triage y etapa 2, sin modo nuevo: el hook `PreToolUse` retiene el primer `write_file`/`edit_file` de un pedido sustancial hasta que el agente presenta un plan que Jev aprueba (máximo 2 retenciones por turno). Más simple que un modo `plan` de solo lectura y no cambia cómo se usa fx.
3. Alineación de acciones y respuestas automáticas a `ask_user_question`.
4. Routing de modelos, detección de specs desactualizados y evals de umbrales.
