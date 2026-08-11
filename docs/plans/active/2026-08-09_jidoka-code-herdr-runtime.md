# Jidoka Code: runtime agente visibile in Herdr

**Status:** in-progress
**Origin:** decisione in-session del 2026-08-09 dopo il merge della PR #9
**Base:** `origin/main@ec2e17a8f6436dda6619a1165b359fd07fc6cb3e`
**Branch:** `feat/jidoka-code-herdr-production-integration`
**Goal:** eseguire ogni ruolo Pi production di Jidoka Code come agente top-level osservabile nella singola sessione Herdr globale dell'utente, preservando l'autorità durabile di Jidoka su dispatch, approval, mutation, completion, pause e recovery.

## Analysis, verificata il 2026-08-09

### Comportamento corrente

- `PiRPCProcessRequest` contiene executable, argv, ambiente, prompt, identità terminale, allowlist tool e limiti; `PiRPCProcessRunner` avvia direttamente il processo e ne interpreta lo stream RPC (`Sources/JidokaCodeCore/Pi/PiRPCProcess.swift:10-124`). Il processo non possiede un terminale Herdr visibile.
- L'invocazione corrente forza `--mode rpc`, disabilita discovery di estensioni e skill, carica risorse exact-path e limita i tool (`Sources/JidokaCodeCore/Pi/PiRPCProcess.swift:950-999`). L'ambiente è costruito da zero, credentialless e con `PI_CODING_AGENT_DIR` isolato (`Sources/JidokaCodeCore/Pi/PiRPCProcess.swift:1002-1032`).
- `PiRPCWorkflowExecutor` prepara workspace, directory private, runtime configuration, modello, sessione e prompt, poi considera autorevole solo il risultato RPC decodificato con workflow, ruolo e artifact digest esatti (`Sources/JidokaCodeCore/Pi/PiRPCWorkflowExecutor.swift:47-107`, `Sources/JidokaCodeCore/Pi/PiRPCWorkflowExecutor.swift:109-235`).
- L'estensione packaged espone tool chiusi, verifica l'inventario e termina il turno solo dopo un unico `jidoka_code_result` schema-valid (`Resources/Pi/extensions/jidoka-code.ts:251-288`, `Resources/Pi/extensions/jidoka-code.ts:350-388`). Questa è la seam corretta per inviare un completion envelope fuori dal TUI senza analizzare il terminale.
- La composizione production costruisce separatamente reviewer, triage, planner e orchestrator, tutti con runner RPC diretto (`Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift:260-420`). Non esiste ancora un runtime condiviso che coordini pane e processi.
- `pi_runs` registra soltanto identità basilare, session path, accepted, settled, result digest e outcome (`Sources/JidokaCodeCore/State/DatabaseSchema.swift:148-161`). Non può provare ownership di workspace, tab, pane, terminale o host Herdr.
- Startup recovery disattiva tutte le lease e riconcilia ogni job non terminale prima di dispatch (`Sources/JidokaCodeCore/State/DurableJobStore.swift:444-529`; `Sources/JidokaCodeCore/Jobs/JobCoordinator.swift:135-160`). L'eventuale rebind di un host ancora vivo deve quindi avvenire prima della recovery totale o diventare un nuovo input esplicito della recovery.
- Pause persiste prima la configurazione e chiude il dispatch gate; quit persiste pause, checkpointa il runtime e poi SQLite (`Sources/JidokaCodeCore/Application/EngineService.swift:268-278`, `Sources/JidokaCodeCore/Application/EngineService.swift:346-363`). Il runtime Herdr deve preservare lo stesso ordine e non fermare il server globale.

### Evidenza Herdr osservata

- Client e server installati: Herdr `0.8.0`, protocollo `19`, schema JSON SHA-256 osservato offline `88ff414aa996e390c2db05a37b95d28dbe4e81b98329f6ed7f7a2cc5c6ebf51a`.
- Il digest schema è provenance offline del CLI installato, non un'identità autenticata dal socket. H1 valida un handshake fixed; l'attestation del binary/schema Herdr resta un gate H5 separato.
- `ping` restituisce version, protocol e capability `live_handoff` e `detached_server_daemon`.
- Il socket default osservato è un Unix socket owner-current-user con mode `0600`; il config root è `0755`. Questo è un boundary same-user, non un'identità server crittografica.
- L'integrazione Pi Herdr v8 è lifecycle authority e rende non necessaria la screen detection, ma pubblica anche la session reference. Herdr può quindi auto-ripristinare con una propria argv.
- In Herdr 0.8.0 `agent.start` seleziona il canonical executable `pi`; il native restore usa `pi --session <path-or-id>`. Nessuno dei due conserva l'exact Node/Pi path, estensioni, skill, tool, modello e ambiente locked di Jidoka.
- `agent prompt --wait`, `idle`, `done` e pane output descrivono stato semantico o presentazione, non una specifica turn identity o un completion envelope.
- Metadata e label sono display-only, limitati e modificabili da processi same-user. Gli opaque ID e l'identità di processo devono essere persistiti da Jidoka.
- `terminal session observe` fornisce frame ANSI read-only e consente osservatori multipli senza input ownership.

### Design gap

Il gap falsificabile è che il runner RPC preserva il contract machine-readable ma rende il lavoro invisibile, mentre il launch e il resume Herdr standard rendono il lavoro visibile ma non preservano l'exact launch descriptor né la terminalità strutturata. Il design è valido soltanto se un host packaged Jidoka crea un Pi TUI visibile nel pane, mantiene Herdr fuori dall'autorità di completion e consegna a Jidoka un envelope replayable e digest-bound prima di qualsiasi avanzamento del job.

### Scope

- In: client Herdr NDJSON tipizzato; handshake fail-closed; topology e naming; host packaged; Pi TUI exact-path; custom lifecycle relay; result channel; durability e recovery; pause/quit; readiness UI; package e operations.
- In: una sola sessione Herdr default condivisa con tutti i terminali dell'utente; un workspace per repository; tab Jidoka dentro workspace condivisi; un agente top-level per ruolo.
- In: visibilità nel TUI Herdr, metadata leggibili, observer read-only, move/rename/close manuali e reconnect.
- Out: sessione Herdr privata production, fallback RPC invisibile, agenti child nascosti, parsing del transcript, terminal emulator dentro la menu bar, modifica automatica della config Herdr, update/install/stop Herdr, protezione da processo same-user malevolo.
- Out: provider live, GitHub live, Keychain reale, ServiceManagement installato e default-session canary fino ai checkpoint espliciti.
- Test: fake socket e server Herdr temporaneo isolato. I gate automatici non contattano mai il socket default reale.

### Candidate approaches

| Approccio | Decisione | Evidenza e trade-off |
|---|---|---|
| Mantenere RPC e mostrare soltanto eventi sintetici | rejected | Non offre piena visione del transcript e degli agenti nel TUI Herdr. |
| Avviare con `herdr agent.start --kind pi` | rejected | Risolve `pi` dal runtime Herdr/PATH e perde l'exact launch descriptor Jidoka. |
| Usare l'integrazione Pi Herdr ufficiale completa | rejected per i pane Jidoka | Pubblica session identity e abilita auto-resume globale con argv non attestata. L'integrazione ufficiale resta valida per gli agenti personali non Jidoka. |
| Disabilitare globalmente `resume_agents_on_restore` | rejected | Modificherebbe il comportamento di tutti gli agenti nella sessione unica dell'utente. |
| Sessione Herdr nominata privata per Jidoka | rejected dal project owner | Riduce blast radius ma spezza la vista unica che sostituisce tmux. |
| Host packaged Jidoka avviato con argv tipizzata, Pi TUI child exact-path, lifecycle custom senza session ref | chosen, spike-gated | Mantiene visibilità e impedisce auto-resume Herdr dei pane Jidoka; richiede host, side channel e recovery espliciti. |
| Transcript marker o `done` Herdr come completion | rejected | Output e lifecycle non identificano in modo univoco il turno né provano result settlement. |
| Result tool packaged con envelope locale e ack durabile | chosen | Riusa schema, nonce, artifact digest e single-result gate già presenti. |

### Independent opinion

Tre sessioni Pi read-only separate sono state avviate come agenti Herdr visibili nel tab `j/herdr-runtime/g1`:

- `jc-herdr-g1-arch`: integration seams, topology, launch e recovery;
- `jc-herdr-g1-sec`: shared-socket threat model e fail-closed controls;
- `jc-herdr-g1-test`: spike, acceptance e packaging.

Hanno concordato sui blocker `agent.start`, native auto-resume, metadata-as-authority e terminal-output completion. Il parent ha verificato i finding contro il tree e il protocollo Herdr installato. Nessun source file è stato modificato dagli analisti. Un lock `.pi-loop.json.lock` creato dal runtime Pi è scomparso dopo l'uscita ordinata dei tre agenti.

### H1 review outcome

Due round fresh architecture/security/test sono stati eseguiti come sei agenti Pi top-level nei pane Herdr dedicati. Il primo round ha trovato e fatto correggere: bypass pubblici del compatibility manifest e snapshot trust object, owner override pubblico, validazione parent insufficiente, `FD_CLOEXEC` ignorato, claim errato sul digest schema, assunzioni flaky su packetization e scheduling. Il secondo round ha verificato i fix e ha fatto rimuovere l'ultimo initializer pubblico di `HerdrHandshake` e le ultime sleep nei test fail-before-connect. Architecture e test hanno risposto `FIX VERIFIED`; security ha riportato `NO CRITICAL OR MAJOR FINDINGS`. Tutti gli agenti sono usciti e nessun lock transitorio resta.

## Locked decisions

Append-only. Una modifica futura aggiunge una decisione che nomina quella superseded.

| # | Decisione | Scelta | Evidenza/rationale | Revisit if |
|---|---|---|---|---|
| H1 | Sessione production | Unica sessione Herdr default globale | Requisito project owner; Herdr sostituisce tmux sulle macchine target | Herdr introduce capability namespace equivalenti mantenendo una vista unificata |
| H2 | Workspace | Uno per repository canonico | Rollup per progetto e convivenza con tab manuali | un repo richiede isolamento operativo separato |
| H3 | Job topology | Un tab per job generation | Evita confusione tra retry e conserva correlation visibile | Herdr aggiunge grouping nativo per generation |
| H4 | Ruoli | Un agente top-level per pane, nessun child agent nascosto | Piena visibilità richiesta | Herdr rende i child pane first-class e Jidoka li registra tutti |
| H5 | Autorità | Jidoka engine resta autorità durabile | Herdr lifecycle non equivale ad acceptance | Herdr offre transaction/result protocol equivalente e provato |
| H6 | Launch | Host packaged Jidoka via raw argv, mai `agent.start` | `agent.start` usa canonical bare executable | Herdr supporta exact executable più immutable argv digest |
| H7 | Pi runtime | Exact Node, Pi tree, resources, model, tool e environment attestati | Preserva W5/W6 | contract Pi cambia deliberatamente |
| H8 | Pi mode | TUI visibile con initial prompt da file privato digest-bound | Evita 4 MiB in argv e conserva transcript | Pi offre un canale TUI machine-readable più forte |
| H9 | Lifecycle | Host riferisce custom lifecycle senza session reference Herdr | Evita native auto-resume e non espone il socket globale a Pi | Herdr offre per-pane restore policy exact-argv |
| H10 | Resume | Solo Jidoka può autorizzare exact resume dopo recovery | Recovery deve precedere rilancio | per-pane restore Herdr passa la stessa suite |
| H11 | Completion | Unico result envelope dal packaged tool, ack durabile e idempotente | Riusa nonce/artifact/result schema | nessuna |
| H12 | Herdr state | `working/blocked/idle/done` è telemetry | Wait non segue una turn identity | Herdr aggiunge run-scoped completion IDs |
| H13 | Ownership | DB mapping più opaque IDs, terminal identity, run nonce e process identity | Label, cwd e metadata sono display-only | Herdr introduce capability token non forgeable per pane |
| H14 | Shared socket | Client tipizzato con method allowlist e target revalidation | Il socket non ha ACL per workspace | Herdr aggiunge ACL/capability per client |
| H15 | Global lifecycle | Jidoka non starta, stoppa, aggiorna o riconfigura Herdr | La sessione contiene terminali non Jidoka | project owner modifica esplicitamente la responsabilità |
| H16 | Fallback | Nessun fallback invisibile a RPC o sessione privata | Violerebbe la piena visibilità | project owner autorizza una modalità degradata visibile |
| H17 | User topology edits | Rename e move vengono seguiti, non annullati; close active è interruption unknown | L'utente possiede la sessione | Herdr offre lock esplicito scelto dall'utente |
| H18 | Manual input | Tool e mutation rail restano chiusi; input non può produrre acceptance senza exact envelope | La sessione è osservabile e interattiva | una policy takeover più restrittiva viene richiesta |
| H19 | Test boundary | Fake o sessione temporanea, mai socket default nei gate | Evita side effect sui terminali reali | manual canary esplicitamente autorizzato |
| H20 | Distribution | Herdr è prerequisito esterno compatibile, non bundled | È già runtime globale delle macchine target | serve distribuire Jidoka su host senza Herdr |

## Nomenclatura e presentazione

Le label sono per persone e non vengono mai analizzate per autorizzare un'azione.

| Entità | Forma | Esempio |
|---|---|---|
| Session | default | `herdr` |
| Workspace | `<owner>/<repo>` oppure slug locale canonicale | `maroffo/jidoka-code` |
| Tab | `j/<flow>/<object>/<job4>/g<generation>` | `j/imp/i42/k7m2/g2` |
| Pane label | ruolo o processo | `plan`, `impl`, `review`, `checks` |
| Agent alias | `<repo>-<flow>-<object>-<job4>-gN-<role>`, massimo 32 | `jc-imp-i42-k7m2-g2-impl` |

Flow code: `prr`, `tri`, `imp`, `qa`. Alias collision-safe con short job suffix; full UUID resta nel DB e in metadata bounded.

Metadata pane, massimo 16 token per report:

```text
managed_by=jidoka
job_id=<uuid>
repo_id=<uuid>
workflow=<enum>
object=<kind-number>
generation=<integer>
role=<enum>
round=<integer>
run_id=<uuid>
model=<profile>
summary=<closed-state-label>
```

`display_agent`, `title` e state labels restano a vocabolario chiuso e secret-free. Jidoka non persiste il transcript Herdr nei log applicativi.

## Architecture contract

```text
Jidoka Engine helper
  | durable prepare + target validation
  | typed NDJSON over default Herdr socket
  v
Herdr default session
  workspace <repo>
    tab <job generation>
      pane <role>
        JidokaCodeHerdrHost
          | exact launch descriptor + private result socket
          v
        exact Node + Pi TUI + packaged Jidoka extensions/skills
          | lifecycle/result envelope, no HERDR_* access
          v
        JidokaCodeHerdrHost
          | display-only lifecycle report to own pane
          | idempotent result delivery to Engine
          v
        durable PiRunStore / JobCoordinator
```

### Herdr client contract

- Endpoint production fisso al default socket risolto nel user context; nessun valore da issue, repository, modello o UI diventa socket path.
- Prima e dopo la connessione: absolute path, parent canonicale current-user non group/other-writable, `lstat`, socket type, current uid e mode privo di group/other access; il peer uid connesso deve essere lo stesso. Poi `ping` valida la sola compatibility fixed `0.8.0`/protocol `19` e le due capability richieste.
- NDJSON UTF-8 con LF, request ID random e univoco, record massimo 1 MiB, output totale bounded, timeout monotonic e zero retry automatico per mutation response-lost.
- Read allowlist iniziale: `ping`, `session.snapshot`, get/list/process-info necessari, event subscribe.
- Mutation allowlist iniziale: creazione workspace/tab/layout owned, metadata owned, agent rename owned e cleanup exact-owned. Vietati generic input, `server.stop`, config/update, session delete, force worktree remove e target non registrati.
- Dopo EOF, timeout, unknown response, protocol drift o event gap: chiudere il dispatch, resnapshot completo e revalidare prima di una nuova mutation.
- Ogni mutation topology viene preparata durablemente prima dell'invio. Una response persa richiede snapshot e exact attribution, non un secondo create.

### Host e Pi contract

- Herdr avvia soltanto il signed `JidokaCodeHerdrHost` con argv bounded contenente un run ID, non prompt, token, path repository non validato o command string.
- Il host apre un descriptor/launch file privato già preparato dall'engine, ne verifica run nonce e digest, quindi lancia exact Node più Pi CLI.
- Pi usa TUI regular, initial prompt da file privato `0600`, `--no-approve`, `--no-context-files`, `--no-extensions` con sole estensioni explicit, `--no-skills` con sole skill explicit e tool allowlist corrente.
- Il child Pi non eredita `HERDR_*`; il host è l'unico reporter Herdr del pane.
- La custom extension invia a host eventi lifecycle bounded e un solo result envelope canonicale. Non invia session reference a Herdr.
- Il host consegna il result all'engine con run ID, nonce, workflow, role, round, artifact digest, result digest e monotonic sequence. L'engine scrive result e settlement in una transazione prima dell'ack.
- Ack perso: il medesimo envelope può essere replayed; un digest diverso per lo stesso run blocca.
- `done`, exit 0 o output terminale non completano il job. Result valido senza settlement resta recoverable, non succeeded.
- Il host non possiede GitHub token, Keychain capability, Git remote credential o generic mutation API.

### Durability e recovery

Persistire almeno:

- Herdr compatibility manifest usato;
- repository/workspace binding;
- job generation e tab binding;
- role, round, run ID e nonce;
- workspace/tab/pane/terminal IDs correnti;
- host executable/signing digest, PID e start identity;
- exact launch descriptor digest;
- Pi session path/ID, conservato da Jidoka e non Herdr;
- lifecycle sequence, result digest, settlement digest e outcome.

Recovery order:

1. bloccare discovery e nuovi dispatch;
2. connettersi e attestare Herdr;
3. resnapshot completo;
4. correlare soltanto record durable con terminal/process/run identity univoca;
5. importare idempotentemente result già validi;
6. rebind di host provatamente vivo senza nuovo prompt;
7. pane mancante, sostituito o non provabile diventa `piInterruptedUnknown` e reconciliation;
8. solo dopo completare la recovery totale dei job e riaprire il dispatch.

Move aggiorna il pane ID solo se terminal e run identity restano uguali. Rename non cambia ownership. Close active non autorizza respawn. Cold restart Herdr non auto-riprende i pane Jidoka; il resume exact è una nuova mutation preparata da Jidoka dopo recovery.

### Pause e quit

- Pause persiste e blocca subito nuove topology mutation, host launch, prompt e resume.
- Host e Pi già in flight possono terminare; result e reconciliation restano accettabili.
- Quit non chiama mai `server.stop` e non tocca risorse estranee.
- Quit aspetta bounded settlement dei run in flight oppure ne registra l'interruzione; poi chiude soltanto host/pane exact-owned, checkpointa SQLite e lascia la sessione Herdr attiva.

## Acceptance criteria

- [x] Herdr `0.8.0` protocol `19` passa l'handshake fixed; mismatch produce zero mutation. H5 attesta executable e full schema CLI offline prima del socket; il digest schema non viene usato come identità crittografica del peer.
- [x] Tutti i test automatici provano zero connessioni al socket default reale.
- [x] Ogni logical Pi role production è visibile come agente top-level in un pane Herdr; nessun child agent nascosto.
- [x] Una repository usa un solo workspace adottato o creato con identity exact; Jidoka non chiude mai il workspace condiviso.
- [x] Ogni job generation ha un tab distinto e ogni role run un pane distinto.
- [x] Creazione, metadata e agent launch non rubano il focus.
- [x] Exact Node/Pi/resources/model/tools/environment coincidono con il launch descriptor durable.
- [x] `agent.start`, bare `pi`, native Herdr session restore e fallback RPC invisibile non compaiono nei path production.
- [x] Pi non riceve `HERDR_SOCKET_PATH` o altra capability globale Herdr.
- [x] Observer Herdr mostra stato e transcript live del Pi TUI.
- [x] Herdr `idle`, `done`, wait success, pane output ed exit code non possono completare un run.
- [x] Un solo result envelope schema-valid e digest-bound più durable settlement completa il run.
- [x] Response e ack persi non producono un secondo pane, prompt o Pi call.
- [x] Reconnect resnapshotta prima di mutation; duplicate, stale e reordered event non avanzano il job.
- [x] Move e rename manuali sono seguiti senza ripristino forzato; close active produce interruption unknown.
- [x] Pause avvia zero nuovi host e lascia terminare i run in flight.
- [x] Quit lascia il server Herdr e tutti i terminali non Jidoka invariati.
- [x] Secret sentinel assente da argv, env, metadata, log, SQLite, artifact non autorizzati e history persisted da Jidoka.
- [x] Package contiene e firma il host prima dell'app; Herdr non è incluso nel bundle.
- [x] Onboarding dichiara Herdr come runtime globale osservabile e fail-closed se assente/incompatibile.

## Workstreams

### H0: Plan, protocol evidence e safe topology

- Scope: docs e osservazione read-only della sessione globale.
- [x] Verificare merge PR #9, base exact e worktree pulito.
- [x] Creare workspace `maroffo/jidoka-code` e tab `j/herdr-runtime/g1` senza focus.
- [x] Eseguire tre analisi read-only visibili e verificare cleanup del lock transitorio.
- [x] Congelare decisioni, naming, acceptance e side-effect boundary in questo piano.

### H1: Typed Herdr protocol, nessuna composition production

- Scope: `Sources/JidokaCodeCore/Herdr/`, test fake socket.
- [x] Implementare envelope Codable chiusi per ping, snapshot, errori e subset iniziale.
- [x] Implementare Unix socket client bounded con endpoint iniettato e zero fallback.
- [x] Validare owner/mode/type del socket, request correlation, size, LF, UTF-8, timeout e close.
- [x] Fake NDJSON: fragmentation, coalescing, malformed, duplicate/wrong ID, oversize, typed error e protocol mismatch.
- [x] Nessun metodo mutation production ancora composto.

### H2: Topology e host synthetic

- Scope: coordinator Herdr, target `JidokaCodeHerdrHost`, fixture Pi sintetica, S11.
- [x] Preparare topology intent prima di create; snapshot read-back attribuisce response-lost.
- [x] Creare/adottare workspace exact, tab generation e pane role con naming e metadata chiusi.
- [x] Avviare host exact-path tramite raw argv/layout, mai shell string o `agent.start`.
- [x] Host lancia una fixture TUI sintetica e riferisce lifecycle senza session ref.
- [x] Observer read-only mostra entrambi i role pane.
- [x] Verificare move, rename, close, reconnect e focus invariato.

### H3: Pi TUI parity e structured side channel

- Scope: invocation builder TUI, extension lifecycle/result, host relay.
- [x] Provare initial prompt file, fresh/resume exact, tool inventory e result terminate.
- [x] Result envelope e ack idempotente con crash in ogni boundary.
- [x] Unexpected/manual input non bypassa tool, mutation o acceptance rail.
- [x] Extension error, missing settlement, timeout e host loss classificati come current RPC equivalents.
- [x] Confrontare byte-for-byte profile, resources, prompt digest e tool contract con W5 replay.

### H4: Durable ownership e recovery-first integration

- Scope: schema migration, PiRunStore, JobCoordinator e production composition.
- [x] Migration con backup aggiunge binding e append-only lifecycle/result records.
- [x] Rebind live run precede `recoverAtStartup`; stato non provabile resta reconciliation.
- [x] Iniettare un shared Herdr runner nei quattro workflow senza cambiare result schemas.
- [x] Pause, quit, helper crash, Herdr crash e event gap passano fault matrix.
- [x] Rimuovere ogni production direct-RPC fallback; conservare RPC soltanto per replay/probe offline.

### H5: Readiness, package e operations

- Scope: EngineProtocol/UI, package, operations e W8 integration.
- [x] Herdr readiness compare in onboarding/settings e blocca dispatch se incompatibile.
- [x] `Open in Herdr` o focus esplicito solo su azione utente; observer resta read-only by default.
- [x] Package firma il host e verifica inventory/provenance; Herdr resta esterno.
- [x] Documentare shared-session disclosure, transcript visibility, manual close/takeover e recovery.
- [x] S11 fake/isolated entra nei gate; default-session canary resta manuale e separato.

## Verification matrix

| # | Surface | Scenario | Expected evidence | Depth |
|---|---|---|---|---|
| 1 | Socket boundary | regular, symlink, wrong owner/mode/type, long path | solo exact safe socket connette | behavior+error |
| 2 | NDJSON | split/coalesced/invalid/oversize/EOF | parser bounded, no response confusion | behavior+edge+error |
| 3 | Handshake | exact, version drift, protocol drift, missing capability | exact passa; drift zero mutation | behavior+error |
| 4 | Request IDs | wrong, duplicate, stale | nessun waiter errato completa | behavior+edge |
| 5 | Snapshot | empty, foreign panes, Jidoka panes | foreign topology mai adottata | behavior+error |
| 6 | Workspace | existing exact, label collision, user rename | adopt solo identity exact | behavior+edge+error |
| 7 | Job tab | first create, lost response, retry generation | exactly one tab per generation | behavior+edge+error |
| 8 | Role pane | parallel roles, duplicate role, moved pane | one active pane; terminal identity preserved | behavior+edge |
| 9 | Launch | exact host, PATH shadow, shell metacharacter | solo exact argv launches | behavior+error |
| 10 | Pi parity | fresh, resume, writer, reviewer | current workflow schemas invariati | behavior+edge |
| 11 | Result | valid, duplicate same, duplicate divergent, missing ack | idempotent same; divergent block | behavior+edge+error |
| 12 | Lifecycle | working, blocked, settled, done viewed | display only; no job completion | behavior+edge |
| 13 | Events | reorder, duplicate, gap, reconnect | resnapshot before mutation | behavior+error |
| 14 | User action | focus, rename, move, close, input | rails e recovery table preserved | behavior+edge+error |
| 15 | Crash | engine, host, Pi, Herdr before/after result | no duplicate dispatch o false success | behavior+error |
| 16 | Pause | before create, during run, during result | zero new launch; in-flight settles | behavior+edge |
| 17 | Quit | idle, working, blocked, foreign panes | checkpoint; global session untouched | behavior+edge+error |
| 18 | Privacy | sentinel in forbidden surfaces | zero leak attribuibile a Jidoka | behavior+error |
| 19 | Package | host inventory/signature/minOS | exact nested signing green | behavior+error |
| 20 | Default canary | explicitly authorized only | pre-existing topology/focus unchanged | supervised E2E |

**Coverage:** 20 surface families: transport, protocol, correlation, topology, launch, Pi parity, result, lifecycle, recovery, user interaction, privacy e package. Il matrix parametrizza failure boundary invece di moltiplicare ogni workflow per ogni errore; i quattro workflow riusano lo stesso runtime contract e hanno già fixture schema-specifiche W5/W6.

## Review plan

- Ogni review agent viene avviato come agente Herdr top-level visibile, fresh session e read-only.
- Routing: architecture per boundary/composition, security per shared socket/host/result, test per fault matrix/package.
- Review artifact: goal, locked decisions, changed-file roster, diff, schema, protocol manifest e output gate fresh.
- Il parent verifica ogni Critical/Major contro source o executable evidence.
- Massimo tre review/fix round; un solo writer nel worktree.

## Budget

- Writer concurrency: 1.
- Review/fix round: massimo 3 per tranche H1-H5.
- Agent visibility: zero subagent nascosti; ogni delega è un pane Herdr nominato.
- Provider/GitHub/Keychain/ServiceManagement: zero durante H1-H4 automatici; fixture e replay soltanto.
- Final evidence per tranche: source hash, `make check`, `make test-e2e`, sanitizer proporzionati, protocol/spike target e `git diff --check`, tutti dopo l'ultimo edit.

## Risks and rollback

- Risk: il socket globale consente controllo di terminali estranei. Mitigation: typed allowlist, target mapping e revalidation; nessuna API generica esposta.
- Risk: Herdr update rompe protocollo. Mitigation: handshake fixed fail-closed in H1 e binary/schema attestation in H5; nessuna modifica automatica del runtime globale.
- Risk: host/TUI non raggiunge parity RPC. Mitigation: H3 è stop/go; RPC resta invariato finché parity non passa.
- Risk: native restore rilancia bare Pi. Mitigation: nessuna session ref Herdr per pane Jidoka; custom lifecycle dal host.
- Risk: transcript contiene dati sensibili. Mitigation: disclosure, no Jidoka persistence, prompt/tool secret boundary; non promettere secure erasure.
- Risk: user close/move/input crea drift. Mitigation: terminal identity, event/snapshot reconciliation e no blind retry.
- Risk: global Herdr assente al login. Mitigation: readiness/reconnect; dispatch chiuso, nessun private-session fallback.
- Rollback: disabilitare composition Herdr prima del cutover e mantenere W7 tree; dopo cutover, una revert autorizzata ripristina il runner precedente. Nessun rollback stoppa la sessione globale o rimuove tab manuali.

## External side effects

- Autorizzati e già eseguiti in H0-H4: branch/worktree dedicati, analisi allora visibili nella sessione Herdr, sessioni nominate isolate S11/S12, commit e pubblicazione H1-H4. Gli agenti precedenti sono usciti e nessun lock Pi transitorio resta.
- Autorizzati e già eseguiti in H5: branch/worktree `feat/jidoka-code-herdr-readiness-package-operations` dalla base merge exact, package verification locale e import delle preesistenti chiavi Developer ID Application/Installer corrispondenti ai certificati Hikma nel login Keychain. Il package non è stato installato.
- Autorizzati il 2026-08-10 dopo la verifica H5: commit con hook attivi, push non-force del branch dedicato e creazione della relativa pull request.
- Autorizzati successivamente: firma Developer ID Application/Installer, trusted timestamp, invio del package privo di segreti a Apple Notary Service, attesa `Accepted`, stapling e Gatekeeper assessment. La chiave App Store Connect resta locale con mode `0600`.
- Non autorizzati in H5: amend, force-push, merge, deployment, package install, ServiceManagement, credential GitHub applicative, provider live, install/update/config/stop Herdr, default-session production canary o focus reale, e altre mutation GitHub.

## Progress

- [x] 2026-08-09: PR #9 verificata `MERGED` nel merge commit `282e849bdb4fdf573a1cf4f9bddb35c6fffebeed`.
- [x] 2026-08-09: local `main` fast-forwarded a `origin/main`; branch/worktree `feat/jidoka-code-herdr-runtime` creati dalla stessa base.
- [x] 2026-08-09: Herdr 0.8.0/protocol 19/schema digest osservati; default socket mode/owner verificati.
- [x] 2026-08-09: workspace/tab e tre review agent visibili creati senza focus; analisi raccolte e agenti usciti.
- [x] 2026-08-09: piano H0-H5 scritto.
- [x] 2026-08-09: H1 typed protocol e fake socket completati con 11 test, 10 ripetizioni valide, full gate, E2E e sanitizer; nessuna composition o mutation Herdr production aggiunta. Evidence: [`docs/evidence/herdr-h1-protocol-boundary-report.md`](../../evidence/herdr-h1-protocol-boundary-report.md).
- [x] 2026-08-09: due round architecture/security/test visibili hanno chiuso tutti i finding Critical/Major; fix finali confermati dagli stessi reviewer e agenti usciti.
- [x] 2026-08-09: H2 topology e host synthetic completati con 26 test in 3 suite, S11 real two-role ripetuto cinque volte, full gate, E2E e sanitizer. Evidence: [`docs/evidence/herdr-h2-topology-host-report.md`](../../evidence/herdr-h2-topology-host-report.md).
- [x] 2026-08-09: due round H2 architecture/security/test visibili hanno chiuso tutti i finding Critical/Major; architecture e security finali non hanno finding aperti e test ha confermato `FIXES VERIFIED`.
- [x] 2026-08-09: H3 Pi TUI parity, private runtime snapshot e structured result/ack/release completati con 396 test, S12 real TUI causal crash/resume, full E2E, 83 test ASAN, 83 test TSAN e manifest retained exact-run verificato. Evidence: [`docs/evidence/herdr-h3-pi-tui-settlement-report.md`](../../evidence/herdr-h3-pi-tui-settlement-report.md).
- [x] 2026-08-09: review finali H3 architecture, security e test hanno riportato PASS senza finding aperti dopo la chiusura del replay downgrade e della lineage evidence S12.
- [x] 2026-08-10: H4 durable ownership e production integration completati con schema v4, shared visible Herdr runtime, exact 1/4/5-role topology, recovery-first startup, command authority, pause/quit barriers, moved-host rebind e nessun production RPC fallback. Full gate, E2E, 434-test ASan, 434-test TSan e quattro review closure sono verdi. Evidence: [`docs/evidence/herdr-h4-production-integration-report.md`](../../evidence/herdr-h4-production-integration-report.md).
- [x] 2026-08-10: H5 readiness, focus esplicito, package e operations completati da `origin/main@8cf8033e38e1710ecac23b1621051e9a73ed417f`. Binary/schema drift, dispatch regain, pane takeover, XPC status, nested signing e payload installer hanno falsificatori permanenti. Evidence: [`docs/evidence/herdr-h5-readiness-package-operations-report.md`](../../evidence/herdr-h5-readiness-package-operations-report.md).
- [x] 2026-08-10: focused closure, S1/S10/S11/S12, 445-test ASan, 445-test TSan e package audit firmato sono verdi. Review H5 parent completata; review agent indipendenti non avviati per il boundary no-hidden/no-default-session.

## Surprises and discoveries

- Herdr Pi integration è più forte dello screen scraping per lifecycle, ma proprio la session reference ufficiale rende l'auto-resume globale incompatibile con l'exact launch Jidoka.
- `agent.start` e native resume sono convenience API, non execution boundary adatto al contract W5.
- Il runtime Pi globale crea `.pi-loop.json.lock` nel cwd quando più agenti usano la stessa directory; il lock è transitorio ma i pane production devono usare working directory app-managed e non il checkout del prodotto.
- Herdr metadata è utile per sidebar e filtri, ma è esplicitamente display-only e non sopravvive come durable ownership authority.
- Una sessione globale massimizza visibilità e insieme amplia il blast radius del client Jidoka a terminali estranei; il metodo allowlist è quindi un security boundary applicativo.
- Il config root Herdr reale è `0755`: il client deve validare la directory parent immediata del socket come canonicale, current-user e non scrivibile da group/other, non imporre mode `0700`.
- Un timeout Swift cancellation-only non interrompe una syscall bloccante; H1 usa deadline monotonic native su connect/read/write e chiude il descriptor su ogni uscita.
- Il digest dello schema CLI Herdr non autentica il peer socket: H5 lega il full schema all'executable approvato e poi richiede l'handshake fixed, ma same-UID peer substitution resta fuori threat model.
- Un server Herdr nominato headless espone `detached_server_daemon=false`; S11 usa quindi una TUI nominata attached con PTY dimensionato e non contatta il socket default.
- `pane.report_agent` non accetta `done`: il host riferisce `idle` o `blocked`, mentre `done` resta uno stato osservato derivato e non può completare il job.
- Gli observer emettono frame terminali strutturati, ma lo screen corrente autorevole per S11 è `pane read --source visible`; concatenare history ANSI produce falsi positivi.
- La topology mutation deve essere serializzata per repository, non per job generation, perché due job distinti possono osservare e creare lo stesso workspace.
- Un launch descriptor parziale deve essere rimosso prima di riusare il run ID; un child launch fallito deve pubblicare `blocked` prima che il host termini.
- Attestare Homebrew non basta come execution authority: Node, Pi e l'intera closure dylib non-system devono essere copiati e riverificati in uno snapshot privato prima del launch.
- Same-run crash recovery e reuse cross-run della sessione non possono condividere un resume nullable senza provenance: `session.json` conserva origin mode e boundary immutabili, mentre ogni round successivo presenta il digest del terminal result precedente.
- Un `agent wait` avviato dopo l'ack può perdere una transizione già osservata; S12 arma il waiter prima dell'ack e usa result/ack/release, non il wait, come autorità.
- Un offscreen `NSHostingView` usato da S10 può restare sottoscritto al view model dopo `orderOut`; mutare poi un `.alert` può far correre AppKit contro la sheet nascosta. Il fixture usa view model snapshot immutabili per il rendering e mantiene separati i modelli operativi.

## Execution decisions

- 2026-08-09: il project owner sceglie una sola sessione Herdr globale e piena visibilità di ogni agente; una sessione Jidoka privata è esclusa.
- 2026-08-09: il parent mantiene un solo writer; architecture/security/test sono stati agenti Herdr read-only distinti.
- 2026-08-09: il finding native restore viene risolto senza cambiare la config globale: host custom lifecycle, nessuna session identity Herdr e resume solo Jidoka.
- 2026-08-09: H1 non cambia ancora la composition production; stabilisce prima il protocol boundary con fake socket.
- 2026-08-09: l'API pubblica H1 congela Herdr `0.8.0`, protocollo `19` e capability richieste; owner override, raw snapshot decode ed exchange hooks restano internal test seams.
- 2026-08-09: `HerdrHandshake` è leggibile ma non costruibile fuori dal modulo; solo il client validato può produrlo.
- 2026-08-09: i test fail-before-connect usano un observer sincrono interno posto immediatamente prima di `socket/connect`, eliminando sleep e false negative scheduler-dependent.
- 2026-08-09: ogni request successiva a un ping attestato riceve l'exact socket identity e il system exchanger la verifica prima di connect/write; una verifica soltanto post-response sarebbe troppo tarda per le mutation.
- 2026-08-09: H2 usa un gate process-wide per repository sotto il W7 single-instance contract; lo store degli intent resta l'autorità cross-restart di H4.
- 2026-08-09: S11 crea un workspace e un split plan/review reali in una sessione nominata, usa lifecycle custom senza session reference, verifica due screen autorevoli e prova la rimozione della sessione prima del PASS.
- 2026-08-09: H3 esegue soltanto il `dist/cli.js` attestato da uno snapshot privato riverificato di Node, Pi e tutte le dylib non-system; le sorgenti Homebrew restano input di attestazione, non autorità di reopen.
- 2026-08-09: un resume senza boundary è autorizzato soltanto da un'identità sessione schema 2 originata dal fresh launch dello stesso run; un round cross-run conserva e ripresenta sempre l'exact `sessionBoundarySHA256` precedente.
- 2026-08-09: il result side channel canonicale resta completion authority; child exit, pane output, Herdr lifecycle e `agent wait` restano telemetry anche quando risultano `done`.
- 2026-08-09: H3 espone il boundary validato a H4 ma non modifica ancora la production composition RPC; cutover, DB ownership, pause e quit restano gate H4.
- 2026-08-10: H4 usa un solo `HerdrPiWorkflowRuntime` production per review, triage, planning e orchestration; le classi RPC restano soltanto nelle seam offline, probe e replay.
- 2026-08-10: persistent role host e logical Pi run sono identità distinte; ogni process attempt ha un `launchAttemptID`, una queue sequence monotona e prove child PID/PGID/start prima di cleanup.
- 2026-08-10: startup importa result, ricostruisce/rebind topology e recupera approved-command authority prima della generic job recovery; un binding non provabile blocca soltanto il relativo job.
- 2026-08-10: pause chiude e drena topology, Pi e command admission; quit chiude un pane soltanto dopo una nuova prova completa di ownership corrente.
- 2026-08-10: un approved command `started` senza exact accepted evidence diventa `unknown` e non viene mai rieseguito automaticamente; un result accepted può essere replayed soltanto sul repository state esatto.
- 2026-08-10: H5 accetta una sola policy arm64 per Herdr `0.8.0`, executable digest e full `api schema --json` byte-identico; version, schema e CLI sono verificati con argv credentialless prima di qualsiasi handshake.
- 2026-08-10: readiness è autorità di dispatch sia nell'engine sia nel runtime production. Un regain ricostruisce recovery prima del pass, mentre result import e command recovery locali non dipendono dalla disponibilità del socket.
- 2026-08-10: `Open in Herdr` non accetta target UI. Rivalida binding, terminale, PID/start, executable e argv, poi concentra workspace, tab e pane soltanto per comando utente.
- 2026-08-11: il package richiede identità Application e Installer separate, firma nested-before-outer con trusted timestamp, chiude payload e destinazione, supporta notarization esplicita fail-closed e non esegue install o lifecycle script.
- 2026-08-11: Apple Notary Service accetta il package, `stapler validate` passa e Gatekeeper riporta `Notarized Developer ID`; app installata e receipt restano assenti.

## Outcomes and retrospective

H1-H5 sono completati sulla base merge H4. Il runtime production usa agenti Pi top-level visibili, mantiene result/ack/release e SQLite come sola autorità, recupera ownership e command evidence prima dei job generici, e ora chiude dispatch su ogni drift Herdr binary/schema/socket. Package e operations rendono verificabili host, provenance, shared-session disclosure e recovery senza installare o mutare la sessione globale.

Restano W8/W9 separati: bundle identifier production senza suffisso `.Probe`, reproduction in disposable staging checkout, installazione, ServiceManagement, runtime accessibility, credential GitHub/provider e canary sulla sessione default. Ognuno richiede il checkpoint specifico già definito.
