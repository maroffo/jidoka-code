# Jidoka Code: app macOS per workflow GitHub autonomi tramite Pi

**Status:** active
**Origin:** bootstrap pubblico del 2026-08-05
**Base:** `origin/main@688feb5f87e04e572fffc8b3cac624ad1541379f`; approved pre-execution plan SHA-256 `fe25406e15cd894bd37bc212fb59b447c4a75d261943caa1f212c2eb3b7ab2cc`
**Complexity:** complex
**Goal:** distribuire un’app personale macOS da menu bar, installabile e attiva al login, che gestisca repository GitHub configurabili, recensisca PR per head SHA, faccia triage delle issue e porti le issue idonee fino a una PR verificata, senza mai effettuare merge e senza affidare credenziali GitHub a Pi.

## Analysis (public planning baseline, verified 2026-08-05)

### Repository and product baseline

- Il repository pubblico standalone nasce con `README.md`, licenza MIT e questo ExecPlan. Non contiene ancora `Package.swift`, progetto Xcode, codice applicativo, installer o release; nessuna funzionalità è dichiarata disponibile.
- `README.md` fissa il prodotto come automazione personale macOS con qualità incorporata, arresto per giudizio umano, token GitHub fuori dai processi modello e mutazioni remote attribuibili e recuperabili.
- Il nome richiama *jidoka*, automazione che rileva anomalie, si ferma e coinvolge una persona invece di propagare difetti. Il progetto dichiara esplicitamente di non essere affiliato o approvato da Toyota.
- Gli input di progetto includono failure mode da riprodurre come test, non dipendenze da sorgenti private: identità PR troppo debole, terminalità da exit code, retry cieco dopo risposta persa, errori discovery nascosti, credenziali ereditate dal processo agente e workflow che pubblicano direttamente.
- Pi deve essere installato e autenticato separatamente sul sistema. Progetto e package canonici: `https://github.com/earendil-works/pi` e `https://www.npmjs.com/package/@earendil-works/pi-coding-agent`; setup iniziale in `README.md`. W0 deve rilevare versione, entrypoint, Node runtime, semantica RPC, resource loading e tool gating dalle risorse installate; il piano non assume una PATH da shell per processi avviati da Finder o login item.
- Il completamento Pi richiede output strutturato e un evento terminale osservabile, non il solo ack del prompt. Skill ed estensioni project-local dei repository target sono input non fidati e non diventano execution capability.
- `MenuBarExtra`, Keychain, `SMAppService`, Swift concurrency, SQLite, code signing e packaging macOS devono essere provati nel contesto bundle reale. Fonti API iniziali: `https://developer.apple.com/documentation/swiftui/menubarextra` e `https://developer.apple.com/documentation/servicemanagement/smappservice`.
- La descrizione OpenAPI GitHub ufficiale usata come baseline è version `1.1.4`, commit `66c7249d69f9aa013abda010658d15eefbacd0a3`: `https://github.com/github/rest-api-description/commit/66c7249d69f9aa013abda010658d15eefbacd0a3`. W0 deve ricontrollare versione, operation id, status e permission prima di implementare.
- Xcode `26.6` build `17F113` è installato in `/Applications/Xcode.app`; `xcode-select` resta intenzionalmente su Command Line Tools. Con exact per-process `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, SDK macOS `26.5`, Swift `6.3.3`, XCTest e Swift Testing hanno compilato ed eseguito un probe temporaneo. W0 deve ripetere questa evidence senza cambiare la configurazione globale.
- Un probe di availability ha richiesto macOS 14 per `@Observable`; il target minimo 14 resta una decisione testabile. Un probe Git ha inoltre mostrato che config globale, credential helper, SSH agent e hook devono essere neutralizzati come composizione, senza pubblicarne valori.

### Root cause or design gap

Il problema non è un singolo poller. Discovery, esecuzione agente, pubblicazione e stato terminale devono essere separati da identità per revisione, journal delle mutazioni, read-back delle side effect e confine credenziali. Una V1 corretta richiede un engine durabile con transizioni esplicite, un broker GitHub unico, workflow Pi adattati a input/output strutturati e gate composti nel vero contesto pacchettizzato. Se una crash window o un percorso Git non può essere classificato come `safe retry`, `attributable effect` o `escalation`, il design non è pronto per l’implementazione ampia.

### Scope

- In: package Swift standalone; engine, SQLite, scheduler, repository mirror e workspace; GitHub REST client; Keychain; Pi RPC; risorse Pi versionate nell’app; menu bar e settings; login item; build `.app`; installer `.pkg`; test offline, fault injection e canary supervisionato.
- In: workflow app-specific e credentialless per PR review, issue triage, planning e implementation orchestration. Preservano commit narrative, review indipendente, safety rubric, evidence, claim, hook e no-merge contract, ma non invocano `gh` né ricevono token.
- In: rilevamento di una seconda istanza/servizio Jidoka Code e collisioni remote di claim/marker. Onboarding documenta il rischio di automazioni esterne, senza assumere bundle id privati né scaricare processi non propri.
- Out: dashboard, servizio hosted, multiutente, aggiornamento automatico, Pi bundled, container, sandbox resistente a un processo same-user malevolo, GitHub Enterprise, merge o auto-merge, release/tag, gestione CI, creazione automatica di follow-up issue e modifica di checkout di sviluppo.
- Out: disinstallazione distruttiva dello stato o del token. Eventuali azioni esplicite separate non appartengono alla V1.
- Recover excluded context from: nessuno. README, questo piano, fonti pubbliche citate e artifact prodotti durante l’esecuzione devono bastare a riprendere il lavoro.

### Candidate approaches

| Approach | Decision | Evidence and trade-off |
|---|---|---|
| Poller Bash più UI script | rejected | Mantiene coupling e stato best-effort; non produce un bundle nativo con Keychain, ServiceManagement e recovery affidabili. |
| App SwiftUI nativa con engine logico, SQLite e broker | chosen | Consente strict concurrency, Keychain, login item e packaging; aggiunge lavoro iniziale ma rende osservabili i confini. |
| Embed dell’SDK Node Pi | rejected | Richiederebbe distribuire o vincolare Node packages nell’app e contraddice il requisito di Pi installato dal sistema. |
| Pi subprocess in RPC con risorse esplicite | chosen | Permette preflight, provenance delle skill, sessioni durabili e abort controllato senza includere Pi nel bundle. |
| `gh` o token nell’ambiente Pi | rejected | Viola il confine credenziali e rende non verificabili le side effect. |
| Broker REST più subprocess Git autenticato one-shot | chosen, spike-gated | Centralizza le precondizioni e consente publication dell’oggetto esatto; askpass e login context devono essere provati prima di espandere. |
| SwiftData | rejected | Non offre il controllo esplicito richiesto per journal, unique constraint, transazioni e crash recovery. |
| SQLite single-writer actor | chosen | Piccolo e adatto a journal, idempotenza e lock per repository. |
| Helper durabile separato | provisional | Ipotesi preferita per crash restart e continuità, reversibile finché login, signing, Keychain, IPC e autenticazione Pi non passano comparativamente. |
| Solo processo tray | provisional fallback | Più semplice; accettabile soltanto se dimostra la stessa continuità o un relaunch affidabile. |
| Review esterna interattiva per ogni piano | rejected for runtime | Spezza l’autonomia e richiede consenso per ogni invio. |
| Fleet Pi headless fresh-context per i piani | chosen by project owner | Mantiene review indipendente configurabile; i piani complex restano bloccati in attesa umana. |
| Xcode project manuale | rejected for V1 | SwiftPM più script di bundle è più riproducibile; Xcode completo resta richiesto per test e lifecycle verification. |

### Independent review history

Una review indipendente a quattro prospettive ha restituito `revise`, confidence alta. Ha richiesto una spike integrata nel vero contesto signed/login-item per provare insieme resource loading Pi, neutralizzazione del trasporto Git e fedeltà dei workflow, più una tabella di riconciliazione con soli tre esiti normativi.

Tre blocker review fresh-context successive hanno trovato zero Critical e, rispettivamente, undici, otto e quattro Major di specifica. Le correzioni incorporate includono ordering delle autorizzazioni, falsificatori W1, recovery per stato, disposition durabili contro rediscovery, multipart byte-exact, issue revision stabile, provider consent, command registry chiuso senza generic Bash, classifier autorevole, topology-neutral `EngineClient`, identità review contract-independent e call cap del canary. Nessun finding è considerato chiuso per sola opinione; W0/W1 devono produrre executable evidence.

## Locked decisions

Append only. Reverse a decision with a new row that names the superseded row.

| # | Decision | Choice | Evidence/rationale | Revisit if |
|---|---|---|---|---|
| 1 | Prodotto | App personale macOS da menu bar, bundle più `.pkg` | Requisito accettato; niente servizio hosted | cambia il pubblico o serve multiutente |
| 2 | Nome tecnico | `Jidoka Code`, bundle id `com.maroffo.JidokaCode` | Identità stabile per Keychain, login item e Application Support | serve una firma o un brand con altro namespace |
| 3 | Minimum OS | macOS 13 | `MenuBarExtra` e `SMAppService` sono disponibili; V1 personale | la macchina target richiede una versione inferiore |
| 4 | Toolchain | Swift 6 strict concurrency, SwiftPM, nessuna dependency Swift terza | Riduce supply-chain e usa framework presenti | un gate dimostra che una dependency è necessaria |
| 5 | Runtime agente | Pi installato dal sistema via RPC, compatibilità versionata | Requisito e API verificata | Pi rimuove RPC o il contract richiesto |
| 6 | Risorse Pi | Discovery disabilitata, estensione e skill app-versioned caricate per path esplicito | Evita drift da risorse global/project | il preflight non può provare la provenance |
| 7 | Project trust | `--no-approve`; context files del repository restano dati non fidati ma disponibili | Blocca estensioni e settings project-local, preserva convenzioni | Pi cambia la semantica del flag |
| 8 | Output Pi | Solo tool result schema-valid più `agent_settled` può completare una fase | `prompt success` non è completion | RPC introduce un ack terminale equivalente e provato |
| 9 | Threat model | Native same-user cooperativo, non sandbox anti-malevolo | Accettato; non riaprire come difetto | cambia il requisito di isolamento |
| 10 | Token GitHub | Import in Keychain, mai DB, file, argv, env Pi, log o sessioni | Confine principale | GitHub impone un meccanismo incompatibile |
| 11 | Provider auth | Gestita esclusivamente da Pi; l’app non copia credenziali modello | Mantiene il system Pi come autorità | preflight login-context non funziona |
| 12 | Repository | Mirror app-managed in Application Support, job workspace da mirror locale | Non tocca checkout di sviluppo e rimuove remote GitHub dal cwd Pi | un repository non può essere materializzato così |
| 13 | Base branch | Default branch GitHub letto e registrato a inizio job | Nessuna configurabilità speculativa | un repo richiede un integration branch diverso |
| 14 | Git Pi | `origin` locale, global/system config neutralizzate, prompt e SSH disabilitati, extension gate sui comandi di pubblicazione | Best effort coerente con threat model | composition gate trova un bypass involontario |
| 15 | Git broker | Solo HTTPS GitHub, askpass one-shot o equivalente; publication primitive atomic create-only con expected-old absent e exact new SHA, senza update o force semantics | Token fuori da Pi; un normale refspec non è assunto atomic create-only | spike di trasporto trova un primitive diverso e provato |
| 16 | Branch | Solo `agent/issue-<N>-<slug>`, nuovo ref o ref già allo stesso SHA; mai aggiornare ref divergente | accepted safety rail | project owner amplia esplicitamente il protocollo |
| 17 | Merge | Mai merge, auto-merge, force-push, tag, release o push su altri branch | Requisito hard | mai in V1 |
| 18 | Stato | SQLite in WAL, foreign keys, single-writer actor, transizioni append-only | Crash recovery e lock osservabili | benchmark mostra un problema reale |
| 19 | Terminalità | Nessun `done` da exit status; solo marker e read-back o prova locale verificata | Corregge il difetto predecessore | nessuna |
| 20 | Mutazioni | Ogni operazione termina in `safe retry`, `attributable effect` o `escalation` | Recovery invariant richiesto dalla review indipendente | nessuna |
| 21 | PR eligibility | Open, non-draft | Requisito accettato | project owner cambia policy |
| 22 | Review identity | Repository node id, PR node id/numero, exact head SHA, marker app e digest body | Nuovo SHA equivale a nuova review | GitHub espone identity più forte mantenendo SHA |
| 23 | Repeat review | Ogni head SHA nuovo riceve un nuovo commento; stesso SHA mai duplicato | Requisito accettato | nessuna |
| 24 | PR create dall’app | Non esentate; review indipendente post-open con fresh session | Evita self-approval | nessuna |
| 25 | Triage eligibility | Open issue senza `agent:*` o `plan:*`, non una PR; marker terminale impedisce re-triage dopo veto umano | Preserva domain labels e veto | project owner richiede re-triage automatico |
| 26 | Label protocol | `agent:ready`, `agent:needs-spec`, `agent:human`, `agent:wip`, `agent:plan-review`, `plan:approved`, `agent:blocked`, `agent:qa` | V1 protocol self-contained; W3/W6 e transition matrix devono validare ogni uso | nuova transizione richiede una label |
| 27 | Label ownership | Non rimuovere domain label; modificare solo workflow label previste dalla transizione e con precondizione esatta | Evita perdita di metadata utente | nessuna |
| 28 | Safety rubric | Security core, data-loss migration, release/tag, infra ampia, cross-repo, design irrisolto e lavoro non verificabile diventano human-owned | accepted safety rail | project owner approva una classe specifica |
| 29 | Piano | Writer con profilo planning, reviewer fresh-context architecture/security/test con profilo review, synthesis e massimo 3 round | Scelta A e bounded workflow budget | evidenza costi/qualità richiede un routing diverso |
| 30 | Complessità | Simple/moderate procede solo senza Critical/Major irrisolti; complex attende `plan:approved` | accepted safety rail più fleet headless | project owner cambia autonomia |
| 31 | Orchestrazione | Engine coordina Pi writer, verify deterministico, reviewer fleet, fix, re-verify; un writer, massimo 3 round | Bundled implementation workflow contract | il contratto bundled cambia deliberatamente |
| 32 | Concorrenza | Un job attivo per repository, massimo globale configurabile, default 2 | Decisione accettata | misure mostrano starvation o collisioni |
| 33 | Priorità | Recovery, complex approvato, PR review, issue implementation, triage | Decisione accettata | dati operativi mostrano starvation |
| 34 | Costi | Nessun budget monetario app-level; usage osservabile, round limit skill autorevole | Decisione accettata | project owner richiede un budget |
| 35 | Topologia fisica | Logica app/client, engine e broker separata; helper vs monolite deciso solo dal gate comparativo | Independent architecture e adversarial review | gate concluso e decisione registrata qui |
| 36 | Login | Abilitato per default alla fine dell’onboarding; app e helper, se scelto, usano `SMAppService` | Requisito; registrazione richiede user context | macOS rifiuta firma scelta |
| 37 | Signing | Ad-hoc ammesso solo se passa login, Keychain e relaunch; altrimenti stop e richiesta identità Apple/Developer ID | Nessun certificato verificato | spike produce evidenza |
| 38 | UI | Menu bar, onboarding e settings; niente dashboard o history browser | Hold Scope | richiesta esplicita |
| 39 | Concurrent automation | Bloccare duplicate app/helper Jidoka Code e claim collision; chiedere disclosure di automazioni esterne, senza probe di job id non documentati | Self-contained e non modifica processi altrui | un’integrazione pubblica definisce un protocollo di coesistenza |
| 40 | Live writes | Nessun canary GitHub, login registration, Keychain mutation, provider prompt o `.pkg` install senza checkpoint precedente e target esatto | Regole side-effect e finding indipendente | autorizzazione specifica di project owner |
| 41 | Minimum OS, supersedes #3 | macOS 14 | Probe `@Observable` fallisce su target 13 e passa su 14; V1 personale gira su macOS 26.5 | serve supportare macOS 13, usando un observation model compatibile |
| 42 | Polling | Tick fisso 600 s, immediate pass dopo recovery/start/wake/network regain, overlap coalesced | Autonomia deve avere bound osservabile e cadenza prudente | dati rate/costo richiedono modifica |
| 43 | Pi compatibility iniziale | Fail-closed su exact Pi `0.83.0`; ampliare il range solo con contract test delle versioni boundary | È l’unica versione osservata | almeno due versioni boundary passano la stessa suite |
| 44 | Verification execution | `VerificationCommandRunner` credentialless, argv-only, cwd-contained e plan-digest-bound | I comandi DoD e gli hook sono un secondo execution boundary | un repo richiede una capability incompatibile e project owner la approva |
| 45 | Remote branch creation | W1 deve provare CAS create-only atomico; se l’unico meccanismo usa force-class semantics, stop e decisione project owner | Evita race tra read e push e preserva “never force-push” | Git/GitHub offre una primitive documentata equivalente |
| 46 | Pi execution tools, supersedes la parte command-gate di #14 | Nessun generic Bash o file tool built-in; `jidoka_code_read/edit/write` exact-path app-owned, fixed read-only workspace query e result tool per ruolo | Impedisce alias path, bootstrap di tool non attestati, bypass del command runner e remote command path | un workflow indispensabile non è esprimibile e project owner approva una nuova registry capability |
| 47 | Ambiguous object disposition | Stessa job/object revision non viene rediscovered dopo unknown create; late read o humanRetryAuthorized soltanto | Evita duplicate indirette attraverso poll/restart | GitHub offre idempotency key documentata |
| 48 | Complexity authority | Deterministic max severity dopo plan review; unknown/disagreement è complex, hard rail è humanOwned | Il triage guess non può bypassare `plan:approved` | rubric versionata cambia con evidence |
| 49 | Contract bump and review identity | Un contract/app/skill bump non rivede lo stesso PR head SHA e non azzera disposition | Decisione #23 è contract-independent | project owner autorizza esplicitamente una one-off re-review campaign |
| 50 | Xcode selection | Non modificare global `xcode-select`; build, test e command runner usano exact per-process `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` | Xcode 26.6 e i due test framework passano con l’override, mentre CLT resta il default scelto | il bundle si sposta o il probe exact fallisce |
| 51 | Signing gate, applica #37 | L’helper non può essere approvato con firma ad-hoc: W1 resta bloccato finché un’identità Apple Development o Developer ID valida non firma e ripete S2-S4/S8 | Dopo un S2 iniziale verde, qualunque rebuild con nuovo code identity è stato respinto da AMFI con `OS_REASON_CODESIGNING`; ripristinare il bundle byte-identico torna verde, mentre incrementare `CFBundleVersion` non basta | una firma valida supera update, relaunch, Keychain e packaged Pi context senza reset BTM |
| 52 | Firma locale W1, soddisfa il gate #51 | Usare l’identità locale Apple Development Hikma tramite exact SHA-1 `SIGN_IDENTITY`, hardened runtime e timestamp disabilitato per i probe; non riutilizzare le label contaminate dai run ad-hoc | Un fresh signed probe passa S1, S2 completo incluso update generation, e S3 completo con stesso TeamIdentifier; cleanup exact passa senza reset BTM | il certificato scade, manca la chiave privata, cambia team o una build firmata fallisce i gate |
| 53 | Topologia W1, supersedes #35 | Selezionare il LaunchAgent helper; rimuovere il probe monolith dal bundle finale W1 | Il monolith fallisce crash restart entro 30 s; il helper Apple Development passa exactly-one, XPC, restart, reconciliation-first, graceful reopen, Keychain, Pi, S5 composition e cleanup | il helper fallisce un threshold lifecycle/security o una topologia più semplice passa l'intera stessa matrice |
| 54 | Pi compatibility corrente, supersedes #43 per il runtime futuro | Accettare versioni `>=0.84.0 <0.90.0` soltanto se la build esatta è presente nell'allowlist digest-pinned; inizialmente è attestata solo `0.84.0` | Decisione project owner; separa il range di API accettabile dalla provenance obbligatoria di ogni build | una build allowlisted fallisce i contract offline, oppure il project owner modifica il range |

## Architecture contract

### Component boundaries

```text
JidokaCodeApp (SwiftUI/MenuBarExtra, @MainActor)
    -> EngineClient protocol
        -> in-process Engine, oppure NSXPC helper dopo gate W1
            -> Scheduler actor
            -> SQLiteStore actor, unico writer
            -> GitHubBroker actor, unico possessore del token
            -> RepositoryStore/GitTransport
            -> VerificationCommandRunner, argv-only credentialless
            -> PiJobRunner, subprocess RPC credentialless
            -> ArtifactStore e Reconciler
```

- `JidokaCodeApp` non legge direttamente SQLite né Keychain e non esegue GitHub/Git/Pi. Invia intenti UI all’`EngineClient` e rende snapshot immutabili `Sendable`.
- `Engine` non importa SwiftUI/AppKit. Tutte le dipendenze esterne sono protocolli iniettati, così mock e topologia in-process/XPC condividono lo stesso contract.
- `GitHubBroker` è l’unico componente che chiama `SecItemCopyMatching` per il token e l’unico che effettua REST write o crea una capability askpass one-shot.
- `PiJobRunner` non riceve un riferimento al broker e non dispone di un tool GitHub. Le sue uniche uscite autorevoli sono artefatti locali e `jidoka_code_result`.
- Keychain production service: `com.maroffo.JidokaCode.github`, account: canonical GitHub login. Probe service: `com.maroffo.JidokaCode.test.github`, con account UUID mostrato per intero al CHECKPOINT A. Helper candidate bundle id: `com.maroffo.JidokaCode.Engine`; qualunque probe id diverso viene anch’esso mostrato prima di register.
- I dati da GitHub, repository, issue, PR, diff, hook e log sono input non fidati. Non possono modificare allowlist, modello, schema, host, branch policy o mutation precondition.

### Filesystem contract

```text
~/Library/Application Support/JidokaCode/
  jidoka-code.sqlite3
  Repositories/<repo-id>/mirror.git
  Workspaces/<job-id>/repo/             # effimero, nessun remote GitHub
  Sessions/<job-id>/<run-id>/           # Pi JSONL, redatto in UI
  Artifacts/<job-id>/                    # input/output/diff/verify/review
  Logs/                                  # rotazione e redazione
  IPC/                                   # solo se helper, directory 0700
```

- Permessi directory app `0700`; file sensibili `0600`.
- Nessun path deriva direttamente da owner, repo, issue title o branch. Usare UUID e slug sanitizzato soltanto per display.
- Il token non viene mai serializzato. Gli artifact contengono fingerprint e status HTTP, non header Authorization.
- Cleanup di workspace avviene soltanto dopo stato riconciliato o escalation con artifact preservato. All’avvio, workspace orfani vengono associati al job prima di qualsiasi rimozione.

### SQLite contract

Le tabelle possono essere suddivise in file diversi, ma devono preservare questi vincoli:

| Table | Required invariant |
|---|---|
| `schema_migrations` | versione monotona; migration transazionale; backup prima di migration non reversibile |
| `repositories` | GitHub repository node id unique; owner/name canonicali; default branch; tre toggle; enabled |
| `model_profiles` | ruolo unique tra review/triage/planning/orchestration; provider/model/thinking, mai secret |
| `jobs` | UUID; repo; kind; object node id/numero; revision key; contract version used come metadata; priority; state; current step; attempt; `not_before`; timestamps; terminal reason; unique logical identity `(repo, kind, object, revision)` indipendente dal contract version |
| `job_steps` | job + ordinal unique; kind; state; input/output digest; mutation id opzionale; acceptance evidence; append-only completion record |
| `job_transitions` | append-only da/a con reason e artifact reference; transition event key unique impedisce doppio attempt increment |
| `object_dispositions` | unique logical identity contract-independent come `jobs`; `inFlight/attributed/ambiguous/humanRetryAuthorized/superseded`; contract version used, last job/mutation/evidence; blocca rediscovery automatica |
| `repository_leases` | unique repo id; job id; lease generation; heartbeat; una sola lease attiva |
| `pi_runs` | job/run, role, resource version/hash, model, session path, accepted, settled, structured-result digest, outcome |
| `workspaces` | job, path, base branch/SHA, local head SHA, cleanup state |
| `mutation_intents` | idempotency key unique, operation, target, expected state, request digest, `prepared/sendStarted/reconcileRequired/attributed/retryAllowed/escalated`, send epoch, read-back evidence |
| `reviewed_revisions` | unique `(repo_node_id, pr_node_id, head_sha)`; `review_contract_version_used` è metadata; comment id/url/digest |
| `issue_claims` | issue + generation; al massimo una active; marker, expected labels, plan digest, prior generation, state |
| `artifacts` | typed relative path, SHA-256, redaction classification, producer run |
| `reconciliation_events` | append-only probe, observation, classification e reason |

Revision key per kind: PR review usa exact head SHA; triage usa constant initial-triage epoch per issue; implementation usa workflow/claim generation; complex plan resume conserva plan generation. Contract/app/skill version è audit metadata e non crea una nuova logical identity. Una deliberate re-review campaign richiede una nuova locked decision e un explicit disposition supersede, mai un semplice version bump.

Transizioni runtime normative:

| From | Event/precondition | To | Lease, attempt and step effect |
|---|---|---|---|
| `discovered` | logical identity e disposition inserted | `queued` | attempt iniziale 1, no lease |
| `queued` | scheduler wins repo/global slots | `leased` | create new lease generation, attempt invariato |
| `leased` | local inputs validated | `preparing` | retain lease |
| `preparing` | next step selected | `runningPi` or `executing` | retain lease |
| `preparing` | transient setup failure, zero side effect | `retryBackoff` | release; set `not_before` e increment attempt una volta in transaction |
| `preparing` | permanent or unsupported setup | `blocked` | release; preserve evidence |
| `runningPi` | one schema-valid settled result | `executing` | advance current step once |
| `runningPi` | transient provider/process failure, workspace digest unchanged | `retryBackoff` | release; set deadline/increment once |
| `runningPi` | interruption con workspace digest changed o completion unknown | `reconciliationQueued` | clear stale lease; inspect local state before another Pi run |
| `runningPi` | auth, schema or compatibility permanent failure | `blocked` | release; disable affected profile |
| `executing` | local verified step finished and more work remains | `preparing` | advance step once, retain lease |
| `executing` | mutation send began or local completion needs attribution | `reconciling` | retain lease |
| `executing` | command/test failure within round budget | `preparing` | next step is writer feedback/fix; no attempt increment |
| `executing` | permanent failure or round ceiling | `blocked` | release; preserve evidence |
| `reconciling` | effect attributable and more steps remain | `preparing` | advance step once, retain lease |
| `reconciling` | all acceptance evidence present | `succeeded` | release, deactivate claim, disposition attributed |
| `reconciling` | exact human gate published | `waitingHuman` | release, deactivate active claim, preserve generation/disposition inFlight |
| `reconciling` | safe retry classified | `retryBackoff` | release; set `not_before` e increment attempt exactly once |
| `reconciling` | ambiguous create outcome | `awaitingResolution` | release; disposition ambiguous; soltanto read-only late checks |
| `reconciling` | hard conflict/permanent failure | `blocked` | release; preserve evidence |
| `retryBackoff` | clock reaches persisted `not_before` | `queued` | deadline cleared, increment già avvenuto |
| `waitingHuman` | approval event and issue/base fresh | `queued` | increment attempt once; next step `claimApprovedPlan` |
| `waitingHuman` | approval event and issue/base stale | `queued` | increment once; next step `consumeStaleApproval`, non `replan` diretto |
| `awaitingResolution` | late read proves exact effect | `reconciliationQueued` | mutation attributed; continue same step, no attempt increment |
| `awaitingResolution` | explicit `humanRetryAuthorized` | `queued` | new mutation generation, increment attempt once |
| `awaitingResolution` | explicit human abort | `blocked` | disposition remains ambiguous with abort evidence |
| `reconciliationQueued` | recovery scheduler reacquires repo/global slot | `reconciling` | new lease generation; attempt e step invariati |

Recovery function separata e totale, eseguita prima del scheduler normale:

| Persisted state at process start | Recovery result |
|---|---|
| `discovered` | `queued`, attempt inizializzato una volta |
| `queued` | resta `queued`, no lease/attempt change |
| `retryBackoff` | resta con exact persisted `not_before` e attempt; se deadline già passata diventa `queued` senza increment |
| `waitingHuman` | resta `waitingHuman`; read-only discovery osserva approval/staleness |
| `awaitingResolution` | resta tale; programma soltanto bounded read-only late checks, nessun mutation intent |
| `leased`, `preparing`, `runningPi`, `executing`, `reconciling` | stale lease cleared, `reconciliationQueued`, nessun attempt/step change |
| `reconciliationQueued` | resta tale finché ottiene recovery lease |
| `succeeded`, `blocked` | invariati |

- La runtime transition function e la recovery function sono totali sugli enum; ogni coppia/caso non elencato viene rifiutato e testato.
- Il job multi-step continua dal current step, non salta direttamente a terminale.
- Un candidato `agent:ready` usa expected workflow labels `{agent:ready}` e desired `{agent:wip}` dopo claim marker.
- Un candidato complex approvato usa expected `{agent:plan-review, plan:approved}` e desired `{agent:wip}`. Il broker pubblica un resume marker, rimuove entrambe le label consumate soltanto con quella precondizione, crea una nuova `issue_claims.generation` e lascia la precedente inactive.
- Stale approval segue obbligatoriamente: `consumeStaleApproval` mutation, attribution della rimozione `plan:approved` mantenendo `agent:plan-review`, `replan`, publish/attribute nuovo piano, `waitingHuman`. Nessun replan parte prima dell’attribution.
- Discovery consulta `object_dispositions` prima di creare un job. `inFlight`, `attributed` e `ambiguous` sopprimono un nuovo intent per la stessa logical identity attraverso poll, restart e app/skill contract bump. Una disposition ambiguous mantiene il job `awaitingResolution`; può diventare attributed da read-only late reconciliation e continuare, oppure `humanRetryAuthorized` da un dialog esplicito che mostra target/evidence e richiede conferma; soltanto allora una nuova mutation generation è permessa. Un nuovo PR head SHA è una nuova revision identity.
- `succeeded` richiede acceptance evidence specifica. Una lease scaduta autorizza soltanto recovery reconciliation.

### GitHub marker and revision contract

Marker HTML non visibili, versionati e deterministici:

```text
<!-- jidoka-code:v1 kind=<kind> repo=<repo-node-id> object=<node-id> revision=<revision> key=<idempotency-key> payload=<part-sha256> document=<whole-sha256> part=<i>/<n> -->
```

Canonicalizzazione byte-level:

1. Il documento logico viene codificato UTF-8 una sola volta, converte CRLF e CR in LF, rimuove trailing LF e aggiunge esattamente un LF finale. Non applica Unicode normalization e non trimma whitespace interno.
2. `document` è SHA-256 degli exact canonical document bytes.
3. Split algorithm exact: da `start`, porre `limit = min(start + 55_000, count)`. Se `limit == count`, emettere `[start..<count]`. Altrimenti scegliere il massimo indice `end` in `(start...limit]` con `bytes[end-1] == 0x0A`, così LF appartiene alla slice precedente. Se non esiste, scegliere il massimo `end <= limit` maggiore di start tale che `bytes[end]` non sia un UTF-8 continuation byte (`bytes[end] & 0xC0 != 0x80`); emettere `[start..<end]` e ripetere da `end`. Nessun altro split è conforme. Non viene aggiunto/rimosso/ricannonicalizzato alcun byte. Massimo 9.999 parti; oltre, escalation locale.
4. `payload` è SHA-256 dell’exact slice, anche se non termina con LF. Il marker viene costruito dopo digest e part count come prima riga ASCII, seguito da un solo LF e dall’exact slice. Il marker è limitato a 1.024 byte, quindi il body resta sotto 56.025 byte e il sizing non dipende ricorsivamente dalla capacità.
5. Il read-back accetta il marker soltanto come prima riga exact, rimuove marker più il suo unico LF senza normalizzare lo slice, verifica part SHA e concatena gli exact slice in ordine. La concatenazione deve uguagliare gli original canonical document bytes e il whole document SHA. Author, target, key e revision devono combaciare.

I commenti sono create-only. Non editare o cancellare commenti in V1. Golden vector obbligatori: LF/CRLF, Unicode composto/decomposto, trailing whitespace, marker spoof nel body, long line, slice senza trailing LF, multipart missing/duplicate/reordered e boundary 55.000/55.001 byte.

L’esclusione marker usa due pass: prima parse/author/target/payload/document vengono verificati e `key + revision` devono combaciare con un persisted mutation intent creato prima del commento; soltanto quel commento viene escluso. Poi si calcola la current `issue_revision` sui restanti dati e la si confronta con l’expected revision dell’intent. Nessun marker senza intent attribuibile viene escluso.

`issue_revision` è SHA-256 di un sottoinsieme RFC 8785 JCS documentato e testato: UTF-8, object keys ordinate per Unicode code point, JSON string escaping deterministico, integer base-10, nessun float. Contiene issue node id, title/body canonical bytes rappresentati come stringhe, author id, created timestamp, domain labels ordinate per `(node_id,name)`, commenti ordinati per numeric immutable comment id e linked inputs ordinati per canonical URL/node id. Ogni commento include id/node id, author id/login, created/updated timestamp e body canonical bytes. Esclude soltanto un commento che passa la full marker attribution; un commento non marcato dello stesso GitHub login resta incluso. Esclude aggregate issue `updated_at` e tutte le workflow label, perché app comment/label mutation può cambiarli. Ogni linked input include canonical identity, retrieval revision e content digest. `plan:approved` è approval event separato. `base_revision` è default branch name più exact SHA. Edit di title/body, commento umano/unmarked, domain label o linked digest rende stale; app marker/transition label no.

### Mutation reconciliation contract

Definizioni normative:

- `safe retry`: l’intent è provatamente mai inviato, oppure l’operazione ha una proprietà server-side idempotente/unique/CAS già provata e tutte le precondizioni restano vere.
- `attributable effect`: il read-back prova che l’effetto esatto richiesto da quell’intent esiste.
- `escalation`: stato diverso, ambiguo, conflittuale, duplicato o non attribuibile. Nessun retry automatico.

Prima di qualunque write, SQLite commit-a l’intent `prepared`; immediatamente prima del network send lo porta a `sendStarted`. Un crash tra questi due stati può essere safe retry. Da `sendStarted` in poi, un timeout o lost response è unknown. Per create non idempotenti, l’assenza al read-back non prova non-esistenza: dopo letture a 1, 2, 5, 10 e 30 secondi, l’effetto exact è attributable, altrimenti escalation. I retry su 429/rate reset possono differire la reconciliation, ma non cambiano questa regola.

| Operation | Idempotency key and precondition | Read-back | Classification after no/unknown send |
|---|---|---|---|
| Bootstrap label | repo node + label name + contract version; nome unique | GET label per nome | `prepared` e assente: safe; unknown e exact presente: attributable; unknown e assente: safe soltanto perché il nome è server-unique e un retry 422 viene riconciliato; metadata semantici conflittuali: escalation |
| Create marker comment | target + kind + revision + document digest + part | paginazione completa dei commenti dell’author identity | `prepared` e assente: safe; unknown e exact presente: attributable; unknown e assente, duplicate o digest mismatch: escalation, mai recreate |
| Add/remove workflow labels | expected full workflow subset e desired subset | GET labels | desired exact: attributable; expected exact: safe perché add/remove è state-idempotent; altro subset: escalation |
| Claim issue | claim comment più label operations, con collision reread | commenti, label e active claim generation | ogni sotto-operazione usa la propria regola; unknown claim comment assente escala l’intero claim; claim concorrente o label inattese: escalation |
| Publish branch | branch regex, local exact SHA, atomic expected-old absent | GET ref più local object/ancestry | same SHA: attributable; ref absent: safe soltanto con CAS create-only provato; altro SHA/ancestry: escalation |
| Create PR | repo/base/head/exact SHA/body marker | list PR per head/base più GET PR | `prepared` e nessuna: safe; unknown ed exact PR: attributable; unknown e nessuna/multiple/mismatch: escalation, mai recreate |
| PR/issue workflow label | expected e desired workflow subset | GET labels | regola state-idempotent delle label |
| Link PR on issue | marker con PR node id e head SHA | issue comments | regola create marker comment; unknown absent escala |
| Complex plan publication | document digest, issue/base revision, parti determinate | tutte le parti più workflow labels | parti e label exact: attributable; una parte unknown assente/mismatch: escalation; nessuna blind recreation |
| Block/escalate issue | finding digest, expected workflow labels | commento più label `agent:blocked` | label si riconcilia idempotentemente; unknown comment assente escala e preserva artifact locale |

Fault injection obbligatoria per ogni riga: crash in `prepared`, tra `sendStarted` e socket write, dopo write prima della risposta, dopo 2xx prima del commit SQLite, durante ogni read-back e dopo read-back prima della transition. Aggiungere delayed-visibility fixture oltre la finestra di lettura. La property attesa è un solo esito normativo, zero seconda create dopo unknown send e zero `succeeded` senza attribution.

### Git transport contract

1. Il broker mantiene un mirror app-managed con remote GitHub; Pi lavora in una clone/worktree creata dal mirror con `origin` locale.
2. Fetch e publish di rete passano da `/usr/bin/git` o da una primitive Git smart-HTTP scelta dalla spike, sempre con config system/global neutralizzata e configurazione esplicita.
3. Il token viene fornito al solo transport child tramite helper one-shot brokered, con nonce a uso singolo, timeout, socket in directory `0700` e host/path attesi. Token mai in argv, file o env.
4. Il broker importa dal workspace nel mirror un ref locale namespaced per job e verifica branch, base ancestry, tree, changed-file allowlist, commit, hook success ed exact SHA.
5. La publication primitive deve inviare una compare-and-swap con expected old ref `absent/zero` e new exact SHA nello stesso server transaction. Un normale pre-read seguito da refspec non è evidence sufficiente. La fixture inserisce il branch al base SHA tra preflight e receive: il push deve essere rifiutato e il ref non deve avanzare. Se l’unica soluzione disponibile usa una force-class flag o può fast-forward un ref apparso nella race, W1 fallisce e project owner decide, senza reinterpretare “never force-push”.
6. Se il ref remoto è già all’exact SHA, read-back lo attribuisce e non invia. Qualunque altro SHA escala.
7. Per review, il broker fetch-a `refs/pull/<N>/head` e verifica che l’oggetto ottenuto sia l’head SHA restituito da GitHub REST.
8. Submodule consentiti vengono mirrorati dal broker e materializzati con override URL locale prima di Pi. Private submodule non materializzabili causano escalation, non accesso credenziale da Pi.
9. Ogni child process Pi o workspace-query riceve almeno: `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=/usr/bin/false`, `GIT_SSH_COMMAND=/usr/bin/false`; `SSH_AUTH_SOCK`, `GH_TOKEN`, `GITHUB_TOKEN` e varianti vengono rimosse.
10. Generic `bash` non è un active Pi tool. L’estensione espone soltanto `jidoka_code_workspace_query` con enum read-only chiuso (`status`, `diff`, `log`, `show`, `search`, `list`) e argomenti/path validati; nessun remote/config/fetch/push/commit, shell o executable libero.
11. Hook repository e l’eventuale `core.hooksPath` utente vengono rilevati e passati al command runner tramite config Git sicura che esclude credential helper e URL rewrite. Nessun `--no-verify`. Il push resta un processo broker separato.

### Verification command runner contract

I comandi DoD, setup, build, test e `git commit` non vengono eseguiti direttamente da stringhe del modello. Il piano strutturato contiene array:

```text
ApprovedCommand {
  id: String,
  registryKind: Enum,
  executableOrRepositoryScript: String,
  arguments: [String],
  workingDirectory: RelativePath,
  environmentOverrides: [AllowlistedKey: String],
  timeoutSeconds: Int,
  rationale: String,
  definitionDigest: SHA256
}
```

- La fonte autorevole è l’ExecPlan revisionato dalla fleet, congelato con digest prima dell’implementation. Issue body, commenti e output Pi non diventano comandi senza schema, plan review e digest lock.
- Pi non invia argv al runner e non possiede generic Bash. Il writer termina una fase con `jidoka_code_result` contenente soltanto approved command id. L’engine risolve id e digest, esegue, poi invia exit/digest ed excerpt redatto in un nuovo RPC prompt al writer per l’eventuale fix.
- Registry chiuso e bundled, estendibile soltanto da una release dell’app: `makeTargets`, `swiftBuildTest`, `xcodebuildBuildTest`, `repositoryScript`, `gitRead`, `gitStage`, `gitCommit`. Unsupported toolchain/shape escala human-owned.
- `makeTargets` accetta soltanto target token senza `=`, `-f`, `--eval` o makefile override. Swift/xcodebuild accettano soltanto subcommand build/test e option allowlist con path/scheme/destination value validati. `gitRead` è limitato a status/diff/log/show/rev-parse/merge-base. `gitStage` e `gitCommit` argv sono costruiti dall’engine da file allowlist e validated Conventional Commit message.
- Vietati per ogni system executable: `-c`, `--config`, `--config-env`, remote/fetch/push/merge/tag/worktree/config verbs, `--no-verify`, hook/signing override, shell/interpreter/process launcher (`sh`, `bash`, `zsh`, `env`, `xargs`, `osascript`, `open`, `curl`, `ssh`, `gh`) e nested command execution.
- `repositoryScript` deve essere un exact relative regular file nel workspace, senza symlink escape, con content digest incluso nel frozen plan. Può eseguire codice nativo same-user, ma riceve lo stesso env credentialless; script cambiato dopo review viene rifiutato.
- Nessuna shell, pipe, redirection, command substitution o string interpolation nel runner. `workingDirectory` deve risolvere dentro il workspace.
- Environment allowlist, PATH costruita, HOME di job dove possibile, GitHub/model token e Git/SSH credentials assenti. `makeTargets`, `swiftBuildTest` e `xcodebuildBuildTest` ricevono l’exact `DEVELOPER_DIR` locked e una PATH con toolchain Xcode attestata; issue, repository e Pi non possono sovrascriverli. Una config Git generata include soltanto identity commit e hook path approvati, escludendo credential helper, `url.*.insteadOf`, signing command e remote rewrite.
- Timeout monotonic, process group cancellation, bounded stdout/stderr, artifact completo locale con redazione e nessun log di environment values. Exit, signal, duration e output digest diventano acceptance evidence.
- Hook vengono eseguiti dal normale engine-generated `git commit`. Un hook che fallisce blocca; un hook o command che richiede capability non disponibile escala invece di ereditare credenziali utente.
- Fixture obbligatorie: metacharacter resta singolo argomento, cwd/symlink escape, forbidden Git flags/verbs, nested launcher, arbitrary command id, changed digest, timeout descendants, huge output, hook fail e credential lookup.

### GitHub REST inventory and status contract

Fonte normativa iniziale: OpenAPI ufficiale GitHub version `1.1.4`, commit `66c7249d69f9aa013abda010658d15eefbacd0a3`, più guide ufficiali `https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens` e `https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api`. W0 ricontrolla la versione prima di implementare. Ogni request usa `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28` e host exact `api.github.com`.

| App operation | Method and path | OpenAPI operation id | Declared success/errors relevant | Minimum fine-grained capability |
|---|---|---|---|---|
| authenticated identity | `GET /user` | `users/get-authenticated` | 200; 304/401/403 | Metadata read |
| repository/default branch | `GET /repos/{owner}/{repo}` | `repos/get` | 200; 301/403/404 | Metadata read |
| list PR | `GET /repos/{owner}/{repo}/pulls` | `pulls/list` | 200; 304/422 | Pull requests read |
| exact PR/head | `GET /repos/{owner}/{repo}/pulls/{pull_number}` | `pulls/get` | 200; 304/404/406/500/503 | Pull requests read |
| create PR | `POST /repos/{owner}/{repo}/pulls` | `pulls/create` | 201; 403/422 | Pull requests write, Contents write for head |
| list issue candidates | `GET /repos/{owner}/{repo}/issues` | `issues/list-for-repo` | 200; 301/404/422; responses with `pull_request` are filtered | Issues read |
| exact issue | `GET /repos/{owner}/{repo}/issues/{issue_number}` | `issues/get` | 200; 301/304/404/410 | Issues read |
| list issue/PR comments | `GET /repos/{owner}/{repo}/issues/{issue_number}/comments` | `issues/list-comments` | 200; 404/410 | Issues or Pull requests read |
| create issue/PR comment | `POST /repos/{owner}/{repo}/issues/{issue_number}/comments` | `issues/create-comment` | 201; 403/404/410/422 | Issues or Pull requests write |
| list labels on issue/PR | `GET /repos/{owner}/{repo}/issues/{issue_number}/labels` | `issues/list-labels-on-issue` | 200; 301/404/410 | Issues or Pull requests read |
| add workflow labels | `POST /repos/{owner}/{repo}/issues/{issue_number}/labels` | `issues/add-labels` | 200; 301/404/410/422 | Issues or Pull requests write |
| remove one workflow label | `DELETE /repos/{owner}/{repo}/issues/{issue_number}/labels/{name}` | `issues/remove-label` | 200; 301/404/410 | Issues or Pull requests write |
| list/get repo labels | `GET /repos/{owner}/{repo}/labels`, `GET /repos/{owner}/{repo}/labels/{name}` | `issues/list-labels-for-repo`, `issues/get-label` | 200; 404 | Issues read |
| bootstrap label | `POST /repos/{owner}/{repo}/labels` | `issues/create-label` | 201; 404/422 | Issues write |
| read exact branch ref | `GET /repos/{owner}/{repo}/git/ref/heads/{branch}` | `git/get-ref` | 200; 404/409 | Contents read |
| publish Git objects/ref | Git HTTPS transport selected by W1 | not REST | exact CAS result plus ref read-back | Contents write |

Il production client espone un enum chiuso con soltanto queste operation; contract test enumera request factory e prova l’assenza di endpoint merge, auto-merge, close, delete comment/label/repository, release e tag. Query allowlist: `state=open`, `per_page=100`, validated `page`; PR reconciliation può aggiungere exact `head` e `base`.

Classificazione cross-cutting, poi specializzata dalla mutation table:

- 2xx expected: parse e read-back; non basta da solo per terminalità write. 304 è successo read da cache validata.
- 301: consentito una volta soltanto su GET repository, stesso host, e solo se il node id conferma la canonical repo; write 301 ferma e ri-discovery, non replay automatico.
- 400/401: auth/config blocked. Non retry finché credential/config generation cambia.
- 403 con `X-RateLimit-Remaining: 0` o `Retry-After`: retry al reset; secondary-rate-limit: exponential backoff. Altro 403 è permission blocked.
- 404: absent soltanto dove la singola operation lo definisce; su mutation target è stale/conflict. DELETE label 404 è attributable solo dopo GET che prova desired subset.
- 406: client media/API configuration blocked. 409: reconcile e poi escalation se ref state non exact. 410: target gone, blocked.
- 422: prima read-back per write unknown; poi validation/semantic blocked. Non ritentare content create alla cieca. 429 usa `Retry-After`.
- Network timeout e 500/502/503/504: read retryable; write passa a `reconcileRequired` perché l’invio può essere avvenuto.
- Status non inventariato: fail-closed con artifact redatto e escalation. Nessun “4xx/5xx generico”.

Onboarding dichiara capability richieste per i repository target: Metadata read, Contents read/write, Issues read/write, Pull requests read/write. Le read capability vengono provate senza mutation; le write capability sono provate soltanto nel canary autorizzato. Nessuna scope header viene trattata come prova universale per token fine-grained.

### Pi RPC and resource contract

Invocazione concettuale, con path canonici risolti dal preflight:

```text
<node> <pi-cli-js>
  --mode rpc
  --no-approve
  --no-extensions --extension <bundle>/Contents/Resources/Pi/jidoka-code.ts
  --no-skills --skill <bundle>/Contents/Resources/Pi/skills/<job>/SKILL.md
  --no-prompt-templates --no-themes
  --model <provider/model:thinking>
  --session-dir <ApplicationSupport>/Sessions/<job>/<run>
  --name jidoka-code-<job-id>-<role>
  --tools <phase-allowlist>
```

- Impostare `PI_SKIP_VERSION_CHECK=1`; nessun update check estraneo al job.
- Il preflight risolve symlink Pi, shebang e Node, verifica semver e intero package tree Pi contro il manifest bundled, attesta executable e closure Mach-O non-system Node nell'ordine dyld, lancia RPC nel contesto pacchettizzato, chiama `get_commands` e controlla path/provenance della sola skill esplicita.
- Un probe modello schema-valid verifica anche auth reale. Un modello non autenticato disabilita soltanto i job associati e mostra errore actionable; non produce skip terminali.
- Parser JSONL custom su byte LF, limite record, stderr separato, backpressure, timeout, abort RPC, grace period e terminate process tree.
- `prompt success` registra `accepted`; soltanto `agent_settled`, assenza di `extension_error`, un unico result schema-valid e digest artifact possono registrare `settled` e successo.
- Sessioni nuove per triage, reviewer e review post-open. Ripresa di una writer session soltanto all’interno dello stesso job e round, mai come prova di recovery dopo mutation ambigua.
- L’estensione registra `jidoka_code_preflight`, `jidoka_code_workspace_query` e `jidoka_code_result`. `jidoka_code_result` usa schema specifico per job, approved command ids, nonce non segreto ma univoco, artifact digest e `terminate: true`.
- Tool allowlist reviewer: `jidoka_code_preflight`, `jidoka_code_read`, fixed `jidoka_code_workspace_query` e `jidoka_code_result`. Planning/implementation writer aggiungono `jidoka_code_edit/write`. I built-in read/find/grep/ls/edit/write, generic Bash, broker e GitHub tool non sono attivi; `get_state/get_commands`, tool lifecycle RPC ed extension attestation lo provano.

### Scheduler and polling contract

- Dopo startup, l’engine completa migration e reconciliation, poi avvia una discovery pass entro 30 secondi se non paused e i preflight sono ready.
- Tick periodico fisso ogni 600 secondi su clock monotonic. Non è configurabile in V1; `Poll now` richiede un tick coalesced.
- Wake da sleep e network regain enqueue-ano una pass debounced entro 30 secondi. Tick persi non vengono replayed uno per uno.
- Mai due discovery pass simultanee per lo stesso repository. Se arriva un trigger durante una pass, resta un solo `pollPending` boolean e parte una pass dopo la corrente.
- Recovery e mutation reconciliation precedono qualunque discovery. Una pass produce candidate durable e poi lascia allo scheduler le lease e le priorità locked.
- Discovery read failure usa backoff per repo 60 s, 120 s, 240 s fino a 1.800 s con jitter deterministico testabile; successo resetta. Rate limit usa il reset server se successivo. Nessun failure crea terminal skip.
- Pause ferma trigger e nuovi dispatch, non interrompe mutation/reconciliation in flight. Resume enqueue-a una pass immediata.
- Tutto il comportamento temporale usa un protocol `Clock`; virtual-clock test prova startup, overlap, pause/resume, sleep/wake, network flap, rate reset e bound di 30 secondi.

### Headless workflow fidelity contract

| Existing invariant | App-specific owner | Required preservation |
|---|---|---|
| Open non-draft PR at exact head | discovery + broker | fixture per open/draft/closed e head change |
| Isolated clone and original checkout untouched | RepositoryStore | job workspace da mirror, cleanup provato |
| Commit narrative oldest-first | `jidoka-code-pr-review` Pi role | structured commit map e finding attribution |
| Architecture/security/test routing | engine review router | fresh Pi sessions, artifact slice, no shared transcript |
| Critical/Major evidence | evidence verifier role | executable test where practical, otherwise taxonomy esplicita; unproven non pubblicato come fatto |
| Final review format | synthesis role | severity, exact location, evidence, recommendation, marker aggiunto dal broker |
| Triage hard rails | deterministic prefilter più `jidoka-code-issue-triage` | security/data loss/release/infra/cross-repo/debate/unverifiable mai `ready` |
| Triage rationale | triage schema | verdict, quattro rubric answers, rationale, questions, complexity guess |
| Human label veto | discovery/state | marker terminale e `agent:human` mai rimosso automaticamente |
| Claim collision | engine + broker | marker-first intent, workflow labels, reread e conflict escalation |
| Independent plan counterweight | planning router | architecture/security/test fresh-context, synthesis, max 3 round |
| Complex human gate | engine | plan comment digest, `agent:plan-review`, attesa `plan:approved` |
| Worktree and plan-first | RepositoryStore + planner | branch isolato; ExecPlan è primo file committed prima dell’implementation commit |
| One writer and hook-on | orchestration engine | writer unico, engine commit senza bypass |
| Verify-review-fix ceiling | orchestration engine | fresh final checks, routed fleet, massimo 3 round, poi blocked |
| Branch and no merge | Git broker | exact regex, exact SHA, endpoint allowlist privo di merge |
| PR body and QA | PR synthesis + broker | summary, closes issue, plan path, evidence, manual QA non verificabile |
| App-generated PR review | scheduler | discoveribile subito dopo create, fresh review job, nessuna esenzione |

La spike di fedeltà deve produrre una tabella precondition, action, postcondition, evidence per ogni riga. Una stringa nel prompt o un transcript plausibile non prova che il workflow abbia preservato i rail; servono fixture, side-effect denial ed evidence osservabile.

### Authoritative complexity classifier

Il `complexity guess` del triage è solo un hint. Dopo plan review, ogni planning writer e reviewer emette flags più una proposta. L’engine applica deterministic maximum severity `humanOwned > complex > moderate > simple`; disagreement o missing evidence diventa almeno `complex`. Class, flags, reporter evidence e classifier version entrano nel plan artifact/document digest e nella job row.

| Class | Normative criteria |
|---|---|
| `simple` | un solo bounded implementation workstream; comportamento e file localizzati; nessuna public API/schema/concurrency/operational change; verify completamente meccanico; tutti reviewer concordano |
| `moderate` | 2-4 bounded workstream nello stesso repo; design settled; change reversibile; verification meccanica più al massimo QA manuale locale; nessun trigger complex/human |
| `complex` | più di 4 workstream, public API o non-destructive schema evolution, cross-module concurrency, operational behavior con rollback, più alternative di design valide, reviewer disagreement, unknown classification o verification gap che un umano può decidere |
| `humanOwned` | security/auth/crypto/secret core, data-loss-capable migration, release/tag, infra blast radius ampia, cross-repo coordination, unresolved issue-thread design debate o lavoro non verificabile; transizione a `agent:human`/blocked, non implementazione |

- Un writer non può abbassare un reviewer flag. La synthesis può soltanto mantenere o alzare la severity con evidence.
- `complex` pubblica plan e attende `plan:approved`. `humanOwned` pubblica rationale e non usa approval come bypass del safety rail.
- Fixture: almeno una per ogni criterio, boundary 1/2/4/5 workstream, disagreement, unknown, hard-risk scoperto dopo triage e tentativo di downgrade.

### Runtime workflow

#### PR review

1. Discovery pagina tutte le PR open e scarta draft.
2. Per ogni head SHA, cerca marker GitHub, `reviewed_revisions` e `object_dispositions` sulla stessa logical identity.
3. Enqueue soltanto se non esiste disposition `inFlight/attributed/ambiguous`. `ambiguous` attiva solo late read reconciliation o dialog di risoluzione umana, mai un nuovo comment intent automatico.
4. Broker fetch-a exact head nel mirror; workspace isolato senza remote GitHub.
5. Pi review roles producono report strutturato; synthesis scarta claim non provati.
6. Broker crea commento marker e legge indietro tutte le parti.
7. Solo allora inserisce `reviewed_revisions` e chiude il job.

#### Issue triage

1. Discovery pagina open issues, elimina entries PR e issue con qualunque `agent:*` o `plan:*`.
2. Se esiste un marker triage attribuibile o disposition `attributed`, tratta una rimozione label come veto e non ripete. Una disposition `ambiguous/inFlight` sopprime rediscovery e consente soltanto late read o risoluzione umana.
3. Pi riceve issue, commenti, link risolti consentiti e snapshot repository; non accede a GitHub.
4. Engine valida schema e hard rails; broker bootstrap-a label mancanti senza sovrascrivere metadata esistenti.
5. Broker pubblica rationale marker e applica esattamente una verdict label.
6. Read-back di commento e label chiude il job; failure transient entra `retryBackoff` per read/idempotent operation oppure reconciliation/escalation per unknown create, mai terminal skip.

#### Issue plan and implementation

1. Candidate: `agent:ready`, oppure `agent:plan-review` più `plan:approved`, secondo priorità.
2. Ready claim: expected `{agent:ready}`, claim marker, desired `{agent:wip}` e nuova active claim generation. Approved claim: expected `{agent:plan-review, plan:approved}`, resume marker, desired `{agent:wip}` e nuova generation collegata al piano. Ogni collision o unknown create comment escala, non viene rubato o ricreato.
3. Crea workspace da default branch SHA registrato e branch locale conforme.
4. Planning writer produce ExecPlan. Architecture, security e test reviewer partono in sessioni Pi fresh-context con profilo review. Synthesis e writer possono fare al massimo 3 round.
5. Complex: pubblica piano digestato, passa a `agent:plan-review`, disattiva la claim, libera lease e pulisce workspace dopo aver persistito artifact. Se `issue_revision` o `base_revision` è cambiata all’approvazione, consuma l’approvazione con precondizione esatta, rigenera e richiede nuova approvazione.
6. Simple/moderate senza Critical/Major: ricrea o conserva workspace, scrive il piano e congela il plan digest. `VerificationCommandRunner` committa il piano per primo con hook attivi.
7. Orchestration writer implementa workstream bounded. Soltanto il command runner esegue gli argv DoD revisionati, costruisce evidence e alimenta la review fleet fresh-context. Fix e re-verify massimo 3 round.
8. Se gate passa, engine stage-a file specifici e il command runner crea implementation commit Conventional Commits con hook attivi e config Git credentialless.
9. Broker verifica exact head e usa la primitive CAS create-only scelta da W1. Crea PR verso default branch soltanto dopo ref read-back e riconcilia la response prima di eventuale escalation.
10. Broker applica `agent:qa`, collega PR all’issue, rimuove `agent:wip` soltanto dopo tutte le prove.
11. Scheduler enqueue-a una review indipendente della PR appena aperta.
12. Infeasible, round exhausted, ambiente non verificabile o stato ambiguo: artifact locale evidence-backed; commento remoto soltanto se la sua mutation diventa attribuibile, workflow label riconciliata, `agent:blocked`, cleanup sicuro. Mai abbassare il gate.

## Acceptance criteria

- [ ] W0 risolve e registra l’exact `origin/main` SHA approvato dopo fetch, prova che working tree e plan blob sono puliti e usa quello stesso SHA per il worktree. Qualunque drift successivo ferma i source edit e richiede revalidation.
- [ ] Ogni target compila in Swift 6 con deployment target macOS 14 usando l’exact per-process `DEVELOPER_DIR`; un explicit macOS 13 typecheck del probe `@Observable` resta una prova negativa documentata. Global `xcode-select` non viene modificato.
- [ ] Da un checkout pulito, `make jidoka-code-package` produce `Jidoka Code.app` e un `.pkg`; bundle, risorse Pi, helper eventuale e askpass sono code-signed e verificati.
- [ ] Dopo autorizzazione dell’install esatto, il `.pkg` installa in `/Applications`; una package build ripetuta in un disposable staging checkout viene lanciata dopo la rimozione di quel solo staging path, con cwd `/`, e funziona senza Pi/Node bundled o path di sviluppo.
- [ ] Alla fine del primo onboarding il login item è enabled per default oppure mostra `requiresApproval` con istruzione esplicita; una prova login supervisionata rilancia tray ed engine.
- [ ] Il topology gate registra una decisione append-only usando i threshold W1: exactly one engine, crash restart entro 30 s, reconciliation prima del dispatch, graceful quit senza crash-loop, Keychain/IPC/Pi auth validi. Se nessuna topologia passa, W2 non parte.
- [ ] Token GitHub importato e sostituito tramite Keychain; scansione argv/env/log/SQLite/session/artifact non trova il token o il sentinel.
- [ ] Prima del primo provider prompt sono dichiarati e autorizzati provider/model, categorie payload, numero massimo di probe e costo stimato. Pi preflight passa dal bundle/login context per i quattro profili o disabilita i job interessati senza stato terminale falso.
- [ ] Settings permette owner/repo e toggle indipendenti review, triage e implementation; l’app usa solo mirror/workspace in Application Support.
- [ ] Scheduler garantisce una lease per repository, massimo globale configurabile default 2 e priorità recovery, approved plan, review, implementation, triage.
- [ ] Startup, wake, network regain e resume avviano discovery entro 30 s; tick 600 s, overlap coalesced e backoff non producono skip terminali.
- [ ] Una PR open non-draft senza marker/disposition all’head corrente riceve una review; draft e closed no. Stesso SHA attributed o ambiguous non crea nuovi job attraverso poll, restart o contract bump; nuovo SHA è nuova identity e genera una nuova review.
- [ ] Marker, multipart, `issue_revision` e `base_revision` passano golden vector byte-level; app marker/label non rende stale un piano, edit/commento umano sì.
- [ ] Una PR aperta dall’app entra nello stesso review path in sessione fresh-context.
- [ ] Una issue open senza label workflow/disposition riceve una sola verdict label e rationale marker; domain labels restano immutate. Ambiguous comment create sopprime rediscovery fino a late attribution o human retry; read failure transient non diventa terminal skip.
- [ ] Le otto label workflow vengono create idempotentemente se assenti e mai sovrascritte se esistenti.
- [ ] Authoritative classifier aggrega writer/reviewer evidence: simple/moderate/complex/humanOwned secondo rubric, unknown/disagreement almeno complex, downgrade rifiutato. Hard-risk diventa humanOwned; complex attende `plan:approved`; simple/moderate richiede zero Critical/Major.
- [ ] Ready claim e approved-complex claim hanno precondition/desired label distinte, claim generation distinte e transition test complete; collision/stale state non causa doppia implementation.
- [ ] Implementation usa branch `agent/issue-<N>-<slug>`, hook attivi, plan commit prima del codice, massimo 3 review/fix round e final checks dopo l’ultimo edit.
- [ ] Pi non dispone di generic Bash e richiede command id. Tutti i DoD, setup e commit passano dal registry-closed `VerificationCommandRunner`; forbidden Git flag/verb, nested launcher, arbitrary id, cwd escape, changed digest, timeout e hook failure vengono rifiutati o bloccano.
- [ ] Branch publish usa una primitive atomic create-only che rifiuta una ref apparsa al base SHA nella race. Nessun force-class fallback viene introdotto senza nuova decisione project owner.
- [ ] Broker rifiuta branch, ref, base, SHA, host, REST operation o changed-file set fuori precondizione; request-factory enumeration prova l’assenza di endpoint merge/auto-merge/close/delete/release/tag.
- [ ] Status 401, classi 403, 404, 409, 410, 422, 429, 5xx e timeout seguono la classification table e non un retry generico.
- [ ] Lost-response fault injection per commenti, label, claim, push e PR create produce sempre uno dei tre esiti normativi; unknown create assente escala, crea disposition ambiguous e zero poll/restart/human-unapproved path la ricrea.
- [ ] Composed-context test dal bundle/login context prova insieme exact skill provenance, output schema, env credentialless, direct push blocked, credential helper/SSH/URL rewrite neutralizzati, hook attivi e submodule localizzato o escalated.
- [ ] Quit/crash/relaunch riconcilia ogni job non terminale prima di far partire nuovo lavoro; nessun `succeeded` senza evidence.
- [ ] Menu bar mostra active/paused/running/warning, poll now, pause/resume, settings, log e quit; non introduce dashboard. VoiceOver, keyboard e contrast evidence sono registrati.
- [ ] Una seconda app/helper Jidoka Code o una claim remota incompatibile blocca il dispatch e produce evidence; onboarding avverte sulle automazioni esterne e l’app non scarica processi non propri.
- [ ] Unit, integration, offline E2E, actual package install, package-independent user flow e review finale sono verificati dopo l’ultimo edit; nessun Critical/Major irrisolto.
- [ ] Un canary GitHub su repository dedicato e target esplicitamente autorizzato prova review, triage, issue-to-PR e post-open review senza merge. L’head update è effettuato da un fixture actor esterno separatamente autorizzato, non dal broker Jidoka Code. Senza canary la release resta `blocked`, non “verified”.

## Workstreams

### W0: Execution environment, base and isolation gate

- Scope: toolchain, plan/base validation e worktree, nessun source edit applicativo.
- Excluded: installazione automatica di Xcode, modifica di `xcode-select`, credenziali o LaunchAgent.
- [x] Nel checkout pubblico corrente eseguire `git fetch origin main`, richiedere working tree/index puliti e calcolare exact `origin/main` SHA più SHA-256 di questo piano. Catturare i valori nell’artifact di esecuzione fuori dal repository, senza editare il checkout validato. Se local `main`, remote o plan blob differiscono, fermarsi e revalidare.
- [x] Verificare che branch/worktree `feat/jidoka-code-macos-app` non esista. Se esiste, fermarsi e ispezionarlo, mai cancellarlo. Altrimenti creare un worktree pulito dedicato dall’exact approved SHA e verificare che il plan digest sia identico.
- [x] Soltanto nel nuovo worktree appendere exact base SHA, plan digest e command evidence a Progress. Questo living-plan edit avviene dopo la base validation e non modifica il checkout pubblico validato.
- [x] Il bootstrap non possiede ancora root gates. Registrare questa assenza senza inventare un pass; come primo scaffold W1 aggiungere target truthful `make check` e `make test-e2e`, poi eseguirli prima di espandere oltre le spike.
- [x] Registrare il default globale con `(unset DEVELOPER_DIR; xcode-select -p)`, perché `xcode-select` riflette l’override quando presente; non cambiarlo. Validare exact `/Applications/Xcode.app/Contents/Developer`, poi verificare con quel `DEVELOPER_DIR`: `xcodebuild -version`, `xcrun swift --version`, SDK, XCTest/Swift Testing, `codesign`, `pkgbuild`, `productbuild`, `git`, `pi`, `node`.
- [x] Se il bundle exact manca, first-launch status fallisce o il probe XCTest/Swift Testing non passa con l’override per-process, fermarsi `blocked`. Non eseguire `sudo xcode-select` e non sostituire i test con script custom.
- [x] Verificare Pi exact `0.83.0`. Versione diversa è fail-closed finché la contract suite non viene eseguita e una nuova locked decision amplia il range.
- [x] Ricontrollare OpenAPI GitHub e documentare eventuale drift di operation/status prima di W3.

### W1: Stop/go spikes in the packaged launch context

- Scope: `Package.swift`, target probe minimali, `scripts/spikes/`, `docs/evidence/spike-report.md`.
- Excluded: feature UI completa, scheduler produttivo, real token e live GitHub writes non autorizzati.
- [x] Creare lo scheletro SwiftPM con Swift 6 mode, platform macOS 14, `JidokaCodeCore`, probe app `MenuBarExtra`, probe engine/helper e test target. Nessuna dependency esterna. Aggiungere root `make check` e `make test-e2e` truthful che impostano l’exact per-process `DEVELOPER_DIR`, poi provarli prima di S1.
- [x] S1 packaging locale, senza install/register: costruire `.app` minimale con Info.plist `LSUIElement`, firma ad-hoc, nested executables e verifica `plutil` più `codesign --verify --strict --deep`; copiare il bundle in un temp path fuori checkout e lanciare con cwd `/`.
- [x] CHECKPOINT A, prima di S2/S3/S4/S8 e di qualunque provider call: project owner ha autorizzato il 2026-08-05 la matrice esatta presentata, con probe app/helper, SMAppService lifecycle, Keychain sentinel temporaneo, payload esclusivamente sintetici e 19 model call massime. Nessun logout automatico.
- [x] S2 lifecycle autorizzato: la firma ad-hoc è stata falsificata sugli update; un fresh probe firmato Apple Development Hikma passa registration/status, launch, graceful quit/reopen, SIGKILL/restart, exactly-one engine, XPC, generation 1→2 ri-firmata con lo stesso team e cleanup. Monolith resta scartato.
- [x] S3 Keychain autorizzato: item sentinel temporaneo seedato dall’harness via stdin con ACL esatta app/helper; app read/replace e helper read passano, Pi direct Bash è bloccato pre-spawn dall’estensione SHA-pinned, cleanup exact passa. Nessun token reale.
- [x] S4 Pi RPC autorizzato: exact Pi/Node, `get_commands`, skill/extension path/hash, strict JSON result, `agent_settled`, timeout/abort e quattro profili passano con 4 call, SSE e zero retry.
- [x] S5 composed security: credential helper, host `insteadOf`/SSH agent redatti, fake SSH, tracked hook e submodule passano; Pi resta credentialless, remote receive zero, hook non bypassato e submodule network escalated.
- [x] S6 Git transport locale: smart-HTTP autenticato più askpass one-shot passa exact create/read-back, same SHA attributable e divergent escalation. La race after-advertisement/before-receive rifiuta CAS expected-old zero senza avanzare e senza force-class semantic.
- [x] S7 mutation recovery: fake GitHub stateful attraversa 10 operation x 6 crash window x 2 visibility scenario. Unknown comment/PR assente escala; zero second create e zero success senza attribution.
- [x] S8 workflow fidelity autorizzato: 15 sessioni Pi fresh-context completano la matrice 4 review/synthesis, 1 triage, 5 planning e 5 orchestration con 29 mapping invariant-evidence. Ledger totale 19/19, ogni request count 1 e zero retry.
- [x] S9 topology decision: decisione locked #53 seleziona helper e supersede #35; il probe monolith è rimosso dal bundle W1 finale.

Pass/falsifier/disposition normativi:

| Spike | Pass condition | Falsifier | Required disposition |
|---|---|---|---|
| S1 package | build/plist/signature green; bundle copied fuori checkout avvia e trova tutte le risorse; `otool` mostra min OS 14 | path checkout, unsigned nested code, missing resource o launch failure | block W2 e correggere packaging |
| S2 lifecycle | status enabled; exactly one engine entro 10 s; crash nonzero restart entro 30 s; prima transition post-restart è reconciliation; graceful quit exit 0 non crash-loopa e reopen riavvia; 100 `EngineClient` round trip senza duplicate, via XPC per helper e direct protocol per monolith | due engine, dispatch prima di reconciliation, restart oltre 30 s, EngineClient/signing failure; XPC-only assertion è N/A per monolith | scartare la topologia che fallisce; se nessuna passa, block W2 |
| S3 Keychain | app e topologia scelta leggono sentinel dopo consenso; Pi child e leak scans non lo vedono; exact cleanup confermato | prompt non gestibile, helper senza accesso, leak o cleanup ambiguo | block W2 oppure richiedere signing identity e ripetere |
| S4 Pi | exact 0.83.0; ogni profilo autorizzato produce un solo result schema-valid e settled entro 120 s; provenance exact | auth/resource drift, provider error, malformed/multiple result, timeout cleanup fallisce | block il profilo e W2 finché tutti i profili richiesti passano |
| S5 composition | remote receive count resta zero per Pi; Git credential/SSH/URL rewrite sono neutralizzati; hook fail blocca commit; submodule usa URL locale o explicit escalation | qualunque direct publication, secret visibility, hook bypass o network submodule involontario | block W2 e ridisegnare boundary |
| S6 transport | exact create e read-back; race con ref al base viene rifiutata; no force semantic; same/different SHA classificati correttamente | fast-forward del ref concorrente, token leak, non-atomic create | block issue implementation e W2; presentare opzioni a project owner |
| S7 mutation | ogni operation x crash window ha un solo esito; zero second create dopo unknown; delayed visibility non induce retry | blind retry, duplicate, unclassified state, false success | block W2 e correggere reconciliation model |
| S8 fidelity | exact Pi real run su fixture sintetiche entro call matrix A più golden evidence per tutte le righe; zero hard rail perso | invariant senza owner/test, generic Bash/remote side effect disponibile, o real run non strutturato | block il workflow e W2 |
| S9 topology | una topologia soddisfa S1-S5 e i threshold lifecycle; decisione e residual risk registrati | scelta per preferenza o risultato incompleto | block W2 |

- [x] Scrivere `docs/evidence/spike-report.md` con setup/command, output redatto, pass/fail/falsifier per S1-S9, autorizzazioni ricevute, cleanup e rischi residui.
- [x] CHECKPOINT B: accettato esplicitamente dal project owner in-session il 2026-08-06 dopo review e correzione dei documenti. Tutti S1-S9 passano senza categorie omitted. W2 è stato successivamente avviato su worktree dedicato.

### W2: Durable core, persistence and scheduler

- Scope: `Sources/JidokaCodeCore/State/`, `Scheduler/`, `Configuration/`, relativi test.
- Excluded: REST reale, Pi reale e SwiftUI; recuperabili dai protocolli e fixture.
- [x] Implementare migration runner, schema e `SQLiteStore` actor con WAL, foreign keys, busy timeout, backup e typed transactions.
- [x] Scrivere runtime e recovery state machine totali, `job_steps`, claim generation e transition validation append-only. Testare ogni riga, illegal pairs, process restart per stato, attempt/deadline preservation, multi-step continuation e stale-approval sequence.
- [x] Implementare `object_dispositions` e unique contract-independent logical job identity. Poll/restart e contract/app/skill bump dopo attributed/ambiguous devono produrre zero nuovo intent; late attribution ed exact human retry dialog hanno transition dedicate.
- [x] Implementare repository lease e global semaphore; property test per una lease per repo e max concurrency.
- [x] Implementare priority queue e starvation observation senza cambiare l’ordine locked.
- [x] Implementare scheduler con injected `Clock`, tick 600 s, immediate/debounced triggers, overlap coalescing e per-repo backoff; virtual-clock matrix completa.
- [x] Startup reconciler classifica job non terminali prima di dispatch. Test crash snapshot per ogni stato e assert della prima transition.
- [x] Config persistence per repository, toggle, profili modello e max concurrency; nessun secret.
- [x] Artifact store con digest, path containment, permission e redaction classification.

### W3: GitHub broker and operation reconciliation

- Scope: `Sources/JidokaCodeCore/GitHub/`, `Keychain/`, `Reconciliation/`, fixture HTTP e test.
- Excluded: Git object transport e Pi workflows.
- [x] Implementare Keychain store con service/account stabili, replace atomico e zero logging del payload.
- [x] Implementare `URLSession` GitHub REST client con request enum chiuso, host allowlist `api.github.com`, API version header, redirect policy, pagination, rate/abuse limit, Retry-After, timeout e typed status classification.
- [x] Implementare soltanto l’inventario read per identity, repository/default branch, PR/head/draft, issues, comments, labels, refs e PR lookup; contract test method/path/query/operation id.
- [x] Implementare soltanto l’inventario write per label bootstrap, comment create, workflow label mutation e PR create più read-back. Nessun metodo merge, auto-merge, close, delete comment/label/repo, release o tag; enum snapshot test.
- [x] Implementare marker builder/parser, canonical bytes, multipart e `issue_revision`; golden/fuzz test per HTML/body ostile, line ending, Unicode, size boundary, marker spoof, author mismatch e linked digest.
- [x] Implementare `mutation_intents` prepared-before-send, unknown-send state, delayed reconciliation schedule e operation-specific outcomes secondo la tabella normativa.
- [x] Fault test tutte le crash windows e status classes. Assert zero second create after unknown, zero false success e classification esatta.
- [x] Implementare discovery PR/issue con full pagination e terminal evidence, non timestamp window.

### W4: Repository store, Git transport and exact publication

- Scope: `Sources/JidokaCodeCore/Git/`, askpass target, fixture repositories e test.
- Excluded: development checkout corrente e GitHub live non autorizzato.
- [x] Creare mirror per repository id in Application Support; clone/fetch via broker; validare owner/name/default branch.
- [x] Materializzare workspace da mirror con `origin` locale, permission e branch state registrati.
- [x] Implementare review fetch di `refs/pull/<N>/head` con exact SHA assertion.
- [x] Implementare submodule inventory, mirror e local URL override; unsupported/private failure escala prima di Pi.
- [x] Implementare askpass one-shot scelto da W1 con nonce, timeout, host/path binding e zero token persistence.
- [x] Implementare import local ref, ancestry/tree/changed-file validation e publication exact-SHA con pre-push old-zero guard più CAS old-zero server-side. Un pre-read seguito dal solo ordinary push resta insufficiente.
- [x] Implementare `VerificationCommandRunner` argv-only, plan-digest lock, safe Git config, process-tree timeout, output bounds e evidence; usarlo anche per staging e commit hook-on.
- [x] Test branch traversal, shell metacharacter title, symlink/cwd escape, SHA mismatch, preexisting branch same/different, base-ref race, changed command digest, hook fail e concurrent publish.
- [x] Cleanup idempotente soltanto dopo reconciliation; test interruption in ogni fase.

### W5: Pi runner and app-versioned workflows

- Scope: `Sources/JidokaCodeCore/Pi/`, `Resources/Pi/`, golden fixture e contract test.
- Excluded: global `~/.pi` modification e project-local extension loading.
- [x] Implementare resolver Pi/Node robusto per Finder/launchd, compatibility manifest, intero package-tree Pi, exact ordered Mach-O closure Node e actionable preflight.
- [x] Implementare RPC byte parser LF, correlation, causal tool lifecycle, strict prompt/result/end/settled ordering, SIGPIPE-safe full-duplex I/O, exit-status validation, timeout, abort e process-tree cleanup.
- [x] Implementare extension `jidoka-code.ts`: resource attestation, generic Bash e file/discovery built-in inattivi, file tool app-owned exact-path/no-follow, fixed read-only workspace-query con metadata prune, approved-command-id result schema e terminal result.
- [x] Scrivere skill app-specific: `jidoka-code-pr-review`, `jidoka-code-issue-triage`, `jidoka-code-plan`, `jidoka-code-orchestrate`, reviewer roles e synthesizer. Ogni skill dichiara GitHub input come untrusted data e vieta side effect remote.
- [x] PR review router preserva commit narrative, domain routing, evidence e output format; synthesis non trasmette raw reviewer output al broker.
- [x] Planning router esegue writer più architecture/security/test fresh-context e synthesis, massimo 3 round. Il planner può proporre command definitions soltanto dai registry kind bundled; engine valida/canonicalizza in `ApprovedCommand`, reviewer approva candidate plan e definition/source digest, poi l'identità finale lega plan bytes, comandi ordinati, decisione di complessità completa e record di approvazione.
- [x] Orchestration router mantiene un writer e richiede l'intera sequenza ordinata di approved command id già congelati; non emette/modifica argv. Un veto writer esegue zero comandi, un comando fallito ferma i successivi, e l'engine usa il command runner per checks, review routing, fix e re-verify massimo 3 round.
- [x] Triage schema include rubric completa, hard-risk flags, verdict, rationale, questions e non-authoritative complexity guess. Planning/reviewer schema include authoritative classifier flags/evidence.
- [x] Implementare deterministic complexity aggregation e fixture simple/moderate/complex/humanOwned/disagreement/unknown/downgrade.
- [x] Contract test controlla provenance path/hash, exact tool allowlist per role, generic Bash assente, workspace-query enum, nessun `gh`/broker tool e nessun secret env.
- [x] Golden E2E W5/W6 usa deterministic fake provider e replay dei transcript S8 per default; output non strutturato, extension error o `agent_settled` mancante fallisce. Qualunque nuovo real-provider run oltre CHECKPOINT A richiede un nuovo checkpoint con exact provider/model/payload/call cap/costo.

### W6: End-to-end job coordinators

- Scope: `Sources/JidokaCodeCore/Jobs/`, integration test.
- Excluded: SwiftUI rendering.
- [x] Implementare un preparer che fornisce soltanto dati applicativi compatibili con il launch descriptor canonico W5; `PiRPCWorkflowExecutor` deve continuare a risolvere runtime, catalogo, argv, environment, provenance, config, workspace e sessione prima del runner.
- [x] Derivare per ogni PR l'esatto set commit REST e, indipendentemente, il set base-to-head dal clone fetched; passarli entrambi al router W5 insieme a base/head e narrativa topologica completa.
- [x] Implementare PR review job dalla discovery al marker read-back e `reviewed_revisions`.
- [x] Implementare issue triage job con marker, verdict label e veto persistence.
- [x] Implementare ready claim e approved-complex claim come step/generation distinti, plan artifact, complex wait/resume/staleness, approval consumption e cleanup.
- [x] Implementare simple/moderate implementation loop, plan-digest lock, command-runner plan-first commit, final implementation commit, atomic publication, PR create, QA label e issue link.
- [x] Implementare post-open review enqueue senza exemption.
- [x] Implementare blocked escalation con evidence e senza cleanup prematuro.
- [x] Scenario E2E offline con fake GitHub, real local Git e deterministic Pi fixture/replayed RPC, inclusi crash/relaunch ai boundary. Real provider e source non sintetico sono riservati al CHECKPOINT D o a un nuovo consenso equivalente.

### W7: Menu bar, onboarding and lifecycle

- Scope: `Sources/JidokaCodeApp/`, helper/XPC target scelto, UI testable view models.
- Excluded: dashboard, updater e history browser.
- [ ] `MenuBarExtra` con status active/paused/running/warning, ultime attività concise, Poll now, Pause/Resume, Settings, Open Logs, Quit.
- [ ] `@Observable @MainActor` view models e protocol DI; niente network/DB nelle view.
- [ ] Onboarding: duplicate-instance check, disclosure di automazioni esterne, Pi path/preflight, token SecureField/import/validation, provider/source disclosure, repository add, toggle e login enabled default. Unit/UI flow usa Keychain, GitHub, Pi e ServiceManagement fake finché una side effect non è autorizzata.
- [ ] Settings: repository/toggle, quattro model profile, max concurrency, login status, replace/delete token con conferma e diagnostics redatti. Un warning per disposition ambiguous offre soltanto late recheck o dialog `Authorize retry` con exact repo/object/revision/evidence; non è un dashboard.
- [ ] Pause non interrompe mutation in flight: ferma nuovi dispatch e lascia reconciliation completare. Quit richiede checkpoint durabile; con LaunchAgent `KeepAlive` distinguere exit 0 intenzionale da crash nonzero e provare niente crash-loop.
- [ ] Implementare topology scelta W1 dietro `EngineClient`; XPC message types versionati e `Sendable` se helper.
- [ ] Verificare VoiceOver labels, keyboard navigation, Dynamic Type ragionevole, contrasto e nessun token copiato in accessibility/log.
- [ ] Eseguire prima un user flow bundle con injected fakes. Il flow con Keychain/SMAppService/Pi reali riusa soltanto l’autorizzazione esatta del CHECKPOINT A o richiede una nuova autorizzazione se payload/target sono cambiati. Catturare screenshot redatti e crash/runtime logs; nessun claim UI-only da unit test.

### W8: Packaging, installer, documentation and repository gates

- Scope: `Packaging/`, `scripts/`, `docs/operations.md`, `Makefile`, `.gitignore` se necessario.
- Excluded: updater, notarization automatica e migrazione automatica di tool esterni.
- [ ] Script deterministico costruisce release binaries, `.app` layout, resource copy, nested signing in ordine e `codesign` verify.
- [ ] `Info.plist` dichiara bundle id/version/LSUIElement/minimum OS; LaunchAgent plist bundle-relative soltanto se scelto.
- [ ] `pkgbuild`/`productbuild` produce installer locale. Nessun postinstall root tenta di registrare login item; il primo onboarding user-context lo registra per default.
- [ ] Supportare `SIGN_IDENTITY` esplicita; ad-hoc default soltanto se W1 l’ha approvata. Notarization è fuori scope e documentata come rischio distribuzione.
- [ ] Verificare bundle e pkg non contengano path checkout, token sentinel, sessioni o artifact test.
- [ ] Ripetere package build in un disposable staging checkout creato per il test, registrare il target e rimuovere soltanto quel path dopo build. Il bundle deve poi avviarsi con cwd `/`; il normale implementation worktree non viene spostato o nascosto.
- [ ] CHECKPOINT C prima di `installer`: presentare exact pkg path e SHA-256, package/receipt id, target `/Applications/Jidoka Code.app`, firma, eventuale app preesistente e rollback. Dopo autorizzazione, installare, provare risorse bundled e disinstall/restore soltanto se separatamente autorizzato.
- [ ] Documentare install, primo avvio, token capability, Pi auth, repo toggle, pause, logs, recovery, conflitto con automazioni concorrenti, uninstall manuale e no-merge contract.
- [ ] Aggiungere target `jidoka-code-check`, `jidoka-code-test`, `jidoka-code-app`, `jidoka-code-package`; integrare build/test macOS nei root gate con exact `DEVELOPER_DIR`, in modo esplicito e non silenzioso.
- [ ] Su host non-macOS il gate deve dichiarare che la release macOS non è verificabile; nessuna release può basarsi soltanto su quel risultato.

### W9: Final verification, review and supervised canary

- Scope: tree finale, review artifact, package e repository canary esatto.
- Excluded: merge, production repository non nominati e qualunque publish non autorizzato.
- [ ] Rerun dopo l’ultimo edit: `make check`, `make test-e2e`, `make jidoka-code-package`, package verification e offline fault matrix.
- [ ] Costruire review artifact redatto con architecture contract, diff, schema/migrations, mutation matrix, threat model, Pi invocation, package manifest e test output.
- [ ] Lanciare tutti i reviewer dichiarati sotto, consolidare e verificare ogni Critical/Major con source ed executable evidence; massimo 3 fix round.
- [ ] Re-run completo dopo l’ultimo fix.
- [ ] CHECKPOINT D side effects: chiedere repository canary exact, repository node id, issue/PR numeri, expected labels, branch names, provider/model per ruolo, payload source privato, exact workflow/role call matrix con hard cap 48 model call e stop prima del call 49, costo massimo stimato, mutation list, cleanup; confermare che merge/close/delete non saranno eseguiti. Qualunque variazione richiede nuovo consenso.
- [ ] Sul canary autorizzato: issue triage, `agent:ready` simple issue, plan fleet, implementation branch, PR create, `agent:qa` e post-open review. Per repeat review, un fixture actor esterno a Jidoka Code effettua un head update separatamente autorizzato; il broker app non aggiorna mai il ref esistente. Verificare che non esista merge.
- [ ] Riconciliare e pulire solo artifact locali di test; non chiudere issue, PR o cancellare branch canary senza autorizzazione separata.
- [ ] Aggiornare Progress, Surprises, Execution decisions e Outcomes con evidenza osservabile.

## Verification matrix

| # | Surface/path | Scenario | Expected evidence | Depth |
|---|---|---|---|---|
| 1 | Base | clean plan-bearing `origin/main`/local same o drift | exact SHA+plan digest registrati; drift ferma e revalida | behavior+error |
| 2 | Toolchain | Xcode bundle exact, CLT machine-wide default, per-process override | global path letto con override unset; env-scoped `xcodebuild -version` e XCTest/Swift Testing probe exit 0 | behavior+error |
| 3 | Deployment target | `@Observable` target 13 e 14 | 13 fail di availability, 14 pass; ogni binary `minos 14` | behavior+edge |
| 4 | Swift package | debug/release strict concurrency | build senza warning/error | happy |
| 5 | App bundle | layout, plist, nested signature | `plutil`, resource manifest, `codesign --verify --strict --deep` | behavior+error |
| 6 | Bundle independence | build in disposable staging checkout poi rimosso, cwd `/` | app/preflight trova soltanto Bundle resources, zero staging path | behavior+error |
| 7 | Installer payload | expand/audit | no Pi/Node/token/dev path/session; receipt e target exact | behavior+edge |
| 8 | Actual package install | pkg autorizzato in `/Applications` | install exit 0, launched app operational, rollback evidence | behavior+error |
| 9 | Login item | register/status/approval/login relaunch | enabled o actionable requiresApproval; tray+engine relaunch | behavior+error |
| 10 | Topology | SIGKILL, quit/reopen, IPC, single engine | threshold S2: <=30 s restart, first reconcile, no duplicates | behavior+edge+error |
| 11 | Keychain | add/read/replace/delete exact sentinel | app/helper round trip, Pi denial, zero leak, cleanup exact | security+error |
| 12 | SQLite migrations | empty, upgrade, interrupted migration | schema correct, rollback/backup | behavior+edge+error |
| 13 | State machine | ogni listed/illegal transition | total transition suite e rejected illegal pairs | behavior+edge+error |
| 14 | Multi-step recovery | snapshot di ogni nonterminal e mutation state | reconcile, continue next step o terminal classified | behavior+edge+error |
| 15 | Claim generations | ready, approved, stale approval | expected/desired labels e prior generation correct | behavior+edge+error |
| 16 | Repo lease | stesso repo e repo diversi | max uno per repo, globale <= config | behavior+edge |
| 17 | Priority | tutte le queue class insieme | ordine locked e starvation metric | behavior+edge |
| 18 | Polling | startup/tick/overlap/pause/wake/network/backoff | virtual clock, immediate <=30 s, tick 600 s, one pending | behavior+edge+error |
| 19 | REST inventory | request enum e factory | method/path/query/version exact; no forbidden operation | security+behavior |
| 20 | REST statuses | 2xx/301/304/400/401/403 classes/404/406/409/410/422/429/5xx/timeout | operation-specific classification, no generic retry | behavior+edge+error |
| 21 | Redirect/auth | same-host canonical GET e cross-host redirect | node-id validated canonicalization; Authorization never cross-host | security+error |
| 22 | Token capability | read-only setup e write canary | read capabilities proved; write only on authorized canary | security+behavior |
| 23 | PR eligibility | open/draft/closed, full pagination | soltanto open non-draft queued | behavior+edge |
| 24 | PR revision | stesso SHA, contract bump e nuovo SHA | zero duplicate su same SHA/version drift; nuova review solo su nuovo SHA | behavior+edge |
| 25 | Marker bytes | line endings, Unicode, spoof, size, multipart | golden payload/document digest e strict attribution | security+edge+error |
| 26 | Issue revision | app marker/label vs human edit/comment/link/base | app effects stable; human/source change stale | behavior+edge |
| 27 | App-generated PR | PR appena creata | fresh review job enqueue e marker read-back | behavior |
| 28 | Issue eligibility | workflow labels, domain labels, PR entry | triage solo issue senza workflow label | behavior+edge |
| 29 | Triage verdict | ready/needs-spec/human e hard risk | exact label/comment, domain labels intatte | behavior+edge+error |
| 30 | Triage unknown send | response lost, delayed visibility, repeated poll/restart | attributable o ambiguous disposition/escalation; zero second comment | behavior+edge+error |
| 31 | Ready claim | race e partial mutation | una active generation o escalation | behavior+edge+error |
| 32 | Approved claim | plan-review+approved, fresh/stale revision | resume generation oppure replan/reapproval | behavior+edge+error |
| 33 | Plan fleet/classifier | class fixtures, disagreement, downgrade e finding | authoritative max class; revise fino a clean o gated/blocked | behavior+edge+error |
| 34 | Complex plan | multipart publish, wait, approval | exact wait/resume; unknown part no recreate | behavior+edge+error |
| 35 | Command runner | registry kind/id, forbidden flags/verbs/launcher, cwd, env, digest, timeout | closed resolution, no credentials, child kill, evidence | security+edge+error |
| 36 | Hook/commit | hook pass/fail e safe Git config | hook runs; fail blocks; no `--no-verify`/credential helper | behavior+error |
| 37 | Orchestration | verify fail, review Major, round ceiling | fix/reverify o `agent:blocked`, mai lower gate | behavior+error |
| 38 | Git workspace | mirror/local origin/cleanup | dev checkout hash/status invariati | behavior+error |
| 39 | Submodule | localizable/private unsupported | local URL materialized o escalation prima di Pi | behavior+edge+error |
| 40 | Pi resource loading | global/project collision | soltanto bundled path/hash in `get_commands` | security+edge |
| 41 | Pi RPC | accepted then error, timeout, malformed JSONL | non-success, abort/cleanup, session evidence | behavior+edge+error |
| 42 | Pi output | zero/one/multiple result calls | solo un schema-valid settled result accettato | behavior+edge+error |
| 43 | Provider disclosure | S4+S8 exact call matrix | exact consent record, <=24 synthetic calls, per-role usage captured | security+behavior |
| 44 | Credential boundary | Keychain sentinel e packaged Pi context | token assente da Pi env/argv/log/session/artifact | security+error |
| 45 | Pi tool surface | generic Bash/unknown tool/direct runner argv/remote attempt | tool absent or schema blocked; receive count zero | security+edge+error |
| 46 | Atomic branch create | absent, same SHA, divergent, base-ref injected race | exact create/attribution; race rifiutata senza ref update | behavior+edge+error |
| 47 | PR create | prepared, response lost, exact/mismatch/multiple | safe solo before send; unknown absent escalation | behavior+edge+error |
| 48 | Mutation property suite | tutte le op x crash/delayed-visibility windows | un esito normativo, zero blind second create | behavior+edge+error |
| 49 | Workflow fidelity | golden PR/triage/planning/orchestration fixture | ogni invariant ha executable evidence | behavior+edge+error |
| 50 | Menu/onboarding fake flow | first run, invalid token/Pi/repo, pause | actionable UI, no false enabled state, no real side effect | behavior+edge+error |
| 51 | Accessibility | VoiceOver, keyboard, labels, contrast, secret fields | manual/accessibility inspection artifact | behavior+edge |
| 52 | Concurrent automation | duplicate app/helper, active claim e external-automation disclosure | dispatch blocked con evidence; nessun unload di processi altrui | behavior+error |
| 53 | Offline E2E | fake GitHub + local Git + packaged Pi fixture | review, triage, issue-to-PR, crash recovery complete | behavior+edge+error |
| 54 | Installed user flow | authorized app/pkg/SMAppService, cwd fuori checkout | menu, preflight, pause/relaunch e resources operational | behavior+error |
| 55 | Live canary | exact repo, call/mutation matrix e external head actor | <=48 calls, real comments/labels/branch/PR/repeat review, no merge | smoke+behavior |
| 56 | Root/final gates | final source tree | `make check && make test-e2e && make jidoka-code-package` green dopo last edit | behavior |

**Coverage mapping:** 56 identified paths, 56 righe mappate. Questo non è execution evidence. Allo status draft nessuna riga applicativa è eseguita. Le righe 8-11, la write portion della 22, 43-44, la real-provider portion della 49 e 54-55 sono authorization-gated e restano gap finché eseguite; la riga 55 non può essere sostituita da inferenza o fake. Il piano finale resta `blocked` se una riga richiesta non passa.

**Exhaustiveness rationale:** i path sono l’unione di base/toolchain, lifecycle/package, persistence/state, scheduler, GitHub reads/writes, Git transport, command execution, Pi process/resources, quattro workflow, UI/accessibility e concurrent-automation handling. Crash e status non vengono moltiplicati a mano: suite parametrica attraversa operation x boundary e operation x status class. UI usa equivalence classes valid/invalid/transient/ambiguous, più un flow installato reale.

## Review plan

- Routed roles: fresh-context architecture, security, test, database, dependency, performance e developer-experience reviewer. I runtime agent name sono scelti dall’harness disponibile e registrati nell’artifact.
- Review artifact: goal e acceptance; locked decisions; topology spike report; changed-file roster; diff per dominio; schema/runtime+recovery transition/object-disposition/migration; marker e issue-revision golden vector; complexity classifier; mutation and REST inventories; command registry/runner; Pi argv ed env key names redatti; extension gates; atomic Git transport; package manifest; polling tests; accessibility; test/fault output; consent records senza secrets; live canary evidence soltanto se autorizzato. Issue text, source e log esterni sono delimitati come untrusted data.
- Critical/Major evidence gate: il parent verifica ogni claim contro source reale e, quando pratico, aggiunge o esegue un test che fallisce per il motivo dichiarato. Un finding non riprodotto resta un gap, non viene chiuso per consenso. Security token claims richiedono sentinel scan più process/session evidence. Recovery claims richiedono fault injection. Packaging claims richiedono bundle installato, non soltanto `swift build`.
- Routing: architecture su boundaries/topology/state; security su token, prompt injection, path/Git/API allowlist; test su matrix/faults/UI; database su migration/constraints/transactions; dependency su Package.swift, Node/Pi compatibility e packaging inputs; performance su scheduler, SQLite, pagination, process output/backpressure; DX su onboarding, installer, diagnostics e docs.

## Budget

- Fix rounds: 3 per checkpoint e 3 finali. Il gate W1 non consuma round di “fix by weakening”; un falsifier architetturale richiede stop e nuova decisione.
- Delegated launches: massimo 18 durante source implementation, più i 7 final reviewer. Qualunque modello/provider diverso dal parent richiede disclosure e consenso secondo il bounded implementation workflow.
- Writer concurrency: 1 per worktree.
- Runtime app: nessun budget monetario; massimo 3 planning review round e 3 implementation review/fix round per issue; usage registrato.
- Final evidence: `make check`, `make test-e2e`, `make jidoka-code-package`, `codesign --verify --strict --deep "build/Jidoka Code.app"`, package manifest audit, offline fault matrix, installed login/user flow, accessibility evidence, reviewer consolidation e canary autorizzato.

## Risks and rollback

- Risk: successi isolati falliscono quando Pi, Git, Keychain e launchd sono composti. Mitigation: W1 esegue il gate nello stesso bundle/login context e blocca W2.
- Risk: helper aumenta signing, Keychain e IPC complexity. Mitigation: engine/client protocol comune, confronto misurato e decisione append-only; nessun helper “per principio”.
- Risk: monolith non riparte dopo crash. Mitigation: accettarlo soltanto con relaunch provato equivalente; altrimenti helper o stop.
- Risk: token leggibile da altro processo same-user. Mitigation: Keychain, memoria minima, socket 0700, nonce one-shot, niente env/file; rischio residuo accettato dal threat model cooperativo.
- Risk: prompt injection induce Pi a pubblicare. Mitigation: Pi senza token/remote, env neutralizzato, tool gate, broker assente dal toolset, branch/API validation. Non dichiarare sandbox.
- Risk: credential helper, SSH key, hook o submodule riapre rete. Mitigation: composed fixture, global config nullo, SSH command false, submodule broker-local, escalation su unsupported.
- Risk: GitHub lost response o eventual consistency duplica, anche via rediscovery. Mitigation: unknown create assente crea disposition ambiguous, sopprime poll/restart intent, late-read o exact human authorization soltanto; operazioni provatamente idempotenti/unique/CAS possono essere safe retry.
- Risk: issue/plan diventa stale durante attesa. Mitigation: issue revision e base SHA precondition, nuova review e nuova approvazione.
- Risk: Pi upgrade rompe schema o resource loading. Mitigation: compatibility manifest, startup preflight e feature-disabled state visibile.
- Risk: app installer ad-hoc non soddisfa SMAppService/Keychain. Mitigation: W1; se fallisce, richiedere identity firmata. Non aggirare ServiceManagement con un plist installato silenziosamente.
- Risk: Jidoka Code e un’automazione esterna pubblicano entrambi. Mitigation: exactly-one app/helper, claim/marker preconditions, onboarding disclosure e hard block su collisione; automazioni arbitrarie same-user restano rischio dichiarato.
- Risk: root Make gate diventa non portabile. Mitigation: target macOS esplicito, release verificabile solo su macOS, nessun silent pass.
- Risk: full Xcode manca o il per-process developer directory drifta. Mitigation: W0 attesta bundle/versione/framework e i root gate impostano l’exact path; nessuna modifica globale a `xcode-select`.
- Risk: un ordinary Git push aggiorna una ref apparsa nella race. Mitigation: atomic expected-old-absent è un falsifier W1; nessun force-class fallback implicito.
- Risk: Pi, DoD o hook bypassa il runner. Mitigation: generic Bash assente da Pi, approved command ids, registry/subcommand/flag chiuso, reviewed plan/script digest, safe Git config e process cleanup.
- Risk: GitHub REST status/permission drift. Mitigation: pinned OpenAPI evidence ricontrollata in W0, request enum chiuso e operation-specific classification.
- Rollback runtime: Pause impedisce nuovi job; unregister del servizio soltanto su azione esplicita; chiusura app/helper dopo checkpoint; workspace app-managed può essere rimosso soltanto dopo reconciliation.
- Rollback install: rimuovere `/Applications/Jidoka Code.app` e unregister login service con procedura documentata. Non cancellare automaticamente Application Support, Keychain, branch, issue o PR.
- Rollback source: rimuovere il worktree dedicato o revert locale dopo autorizzazione; non toccare main né untracked preesistenti.

## External side effects

- Bootstrap pubblico iniziale: autorizzato separatamente dal project owner e limitato a `README.md`, `LICENSE` e questo ExecPlan sanitizzato su `main` di `maroffo/jidoka-code`.
- Local branch `feat/jidoka-code-macos-app`, worktree dedicato e source edit necessari a W0/W1: autorizzati dall’invocazione implementation del 2026-08-05.
- Commit, push e PR della tranche W0/W1 S1 sulla branch dedicata: autorizzati esplicitamente dal project owner il 2026-08-05. Issue e merge restano non autorizzati; CHECKPOINT C/D restano separati.
- CHECKPOINT A autorizza esclusivamente i side effect S2/S3 nominati: probe app/helper `com.maroffo.JidokaCode.Probe` e `com.maroffo.JidokaCode.EngineProbe`, register/status/unregister SMAppService, lifecycle test, Keychain service `com.maroffo.JidokaCode.test.github` con account `eabf21b6-02df-4854-b9a8-c8a21eafdbca` e cleanup. Installazione Xcode, cambio `xcode-select`, certificati, login/logout e installazione `.pkg` restano non autorizzati.
- Il 2026-08-05 il project owner ha autorizzato la creazione e l’uso di una identità locale Apple Development Hikma e, dopo il constraint storico della label ad-hoc, i target temporanei esatti `com.maroffo.JidokaCode.SignedProbe` e `com.maroffo.JidokaCode.SignedEngineProbe`. Il probe è stato disregistrato e rimosso; il certificato locale resta intenzionalmente nel login Keychain.
- Provider model prompt dal processo app: CHECKPOINT A autorizza esclusivamente 19 call senza retry a `openai-codex/gpt-5.6-sol:max`, per i quattro profili e workflow S4/S8, con soli workflow pubblici e fixture sintetiche, envelope stimato 152k token input e 39,5k output, costo metadata massimo stimato 2,15 USD.
- GitHub canary comments, labels, branch e PR, incluso l’head update del fixture actor: non autorizzati; richiedono repository, object e target esatti. Merge non autorizzabile da questa V1.
- Nessun deploy, publication, release o notarization autorizzato.

## Progress

- [x] 2026-08-05: failure mode, Pi RPC/resources, GitHub API e macOS toolchain analizzati.
- [x] 2026-08-05: requirements refinement e adversarial analysis completate.
- [x] 2026-08-05: review indipendente a quattro prospettive completata, verdict `revise`, Major composto incorporato.
- [x] 2026-08-05: project owner ha scelto la fleet Pi headless fresh-context per plan review unattended.
- [x] 2026-08-05: public bootstrap payload e draft ExecPlan preparati.
- [x] 2026-08-05: Xcode 26.6 installato; exact `DEVELOPER_DIR` probe con XCTest e Swift Testing verde, global `xcode-select` lasciato su CLT per decisione #50.
- [x] 2026-08-05: W0 base/isolation gate, `origin/main@688feb5f87e04e572fffc8b3cac624ad1541379f`, approved plan digest `fe25406e15cd894bd37bc212fb59b447c4a75d261943caa1f212c2eb3b7ab2cc`, worktree `feat/jidoka-code-macos-app` creato e verificato.
- [x] 2026-08-05: W0 toolchain, Xcode 26.6 build 17F113, SDK 26.5, Swift 6.3.3, XCTest/Swift Testing, Pi 0.83.0, Node v26.6.0 e SQLite 3.51.0 pass. Root `make check`/`make test-e2e` assenti con exit 2, gap assegnato al primo scaffold W1.
- [x] 2026-08-05: OpenAPI head `e50419c4bb8f2d1d34735044bb3b410863dc0a10`, version 1.1.4; projection operation/status rilevante invariata rispetto al pin, SHA-256 `b2633d14f2527ebf9a8fa2db1b8b51e97d5e31e0eca3f34d4343149d0d8f6eb9`.
- [x] 2026-08-05: W1 scaffold e S1 local package completati. Clean rebuild prova Swift 6 debug/release, XCTest e 10 Swift Testing cases, app/helper min OS 14, exact inventory/provenance, portable Mach-O, nested/outer signature, copied execution da `/`, manifest digest/mutation e fail-closed assenza/schema.
- [x] 2026-08-05: implementation review round 1, architecture/security senza finding; test e dependency hanno riportato 4 Major verificati, più 3 Minor. Corretti output/digest deboli, consumo manifest non provato, payload provenance, toolchain pin, negative matrix, cleanup e W1 README.
- [x] 2026-08-05: implementation review round 2 fresh-context su architecture/security/test/dependency/DX, zero Critical e zero Major.
- [x] 2026-08-05: CHECKPOINT A autorizzato con target S2/S3 esatti e hard cap 19 provider call S4/S8; commit, push e PR della tranche W0/W1 S1 autorizzati separatamente.
- [x] 2026-08-05: S2 live completato con cleanup verificato. `SMAppService.mainApp` passa enabled, direct EngineClient 100 e graceful/reopen ma non crash-restart entro 30 s, quindi monolith scartato. LaunchAgent helper passa enabled/exactly-one, XPC 100, crash-restart entro 30 s, reconciliation-first, graceful no-loop per 31 s, on-demand reopen e generation 1→2 unregister/update/re-register.
- [x] 2026-08-05: review S2 iniziale fresh-context architecture/security/test, zero Critical e zero Major; postcondizioni indipendenti confermano target, job e processi assenti dopo cleanup. La review precede il successivo falsifier di code-identity update e non lo chiude.
- [x] 2026-08-05: primo review indipendente del draft, 0 Critical e 11 Major; incorporati.
- [x] 2026-08-05: secondo review fresh-context, 0 Critical e 8 Major residui; incorporati.
- [x] 2026-08-05: terzo blocker review, 0 Critical e 4 Major residui; incorporati.
- [x] Implementation approval per local source edit/worktree; commit, push e PR della tranche W0/W1 S1 autorizzati successivamente. Gli altri side effect restano gated come documentato.
- [x] 2026-08-05: S3 live passa con item sintetico da 32 byte, ACL app/helper senza prompt, app read/replace, helper XPC read, Pi `user_bash` blocked con exit 126, zero provider prompt e cleanup verificato. Un run precedente ha dimostrato che `--no-tools` da solo non blocca il comando RPC `bash`; il blocker packaged è quindi obbligatorio.
- [x] 2026-08-05: Apple Development Hikma locale creato e verificato con firma hardened-runtime. Il fresh signed probe autorizzato passa S1, S2 completo e S3 completo; app/helper hanno lo stesso TeamIdentifier. Le label, il target, i processi, il sentinel e la copia temporanea sono assenti dopo cleanup.
- [x] W0 environment gate.
- [x] 2026-08-06: W1 S4-S9 passano. S4 consuma 4 call, S8 15, ledger 19/19 tutto `settled` con request count 1 e zero retry. S5-S7 passano local-only; locked decision #53 seleziona il helper e rimuove il monolith. Spike report completo, STOP a Checkpoint B.
- [x] 2026-08-06: review documentale Checkpoint B inizialmente `revise`: corretti i claim troppo ampi su commit/push fixture, aggiunta matrice setup/command/rerun, registrata evidenza S1 e creato manifest redatto versionabile con digest. S9 Apple Development è stato ripetuto sulla decisione corrente byte-identica.
- [x] 2026-08-06: project owner approva esplicitamente Checkpoint B in-session. W2 è sbloccato; commit e push restano separatamente gated.
- [x] 2026-08-06: W2 durable core implementato su `feat/jidoka-code-w2-core`: SQLite WAL/schema/migration backup, state e recovery totali, disposition contract-independent, lease/semaphore, scheduler virtual-clock, configurazione e artifact containment. Suite funzionale, AddressSanitizer, ThreadSanitizer e package E2E passano senza provider call.
- [x] W2 durable core, persistence and scheduler.
- [x] 2026-08-06: W3 GitHub broker implementato su `feat/jidoka-code-w3-github-broker` da `origin/main@97b1fad`: Keychain boundary, inventario REST chiuso, fixture HTTP offline, marker/revision byte-exact, mutation intents e reconciliation delayed, read-back e discovery. Suite funzionale, AddressSanitizer, ThreadSanitizer e package E2E passano senza provider call, credential access o GitHub live.
- [x] W3 GitHub broker and operation reconciliation.
- [x] 2026-08-06: W4 repository/Git transport implementato su `feat/jidoka-code-w4-git-transport`: mirror e workspace app-managed, review exact-SHA, submodule localizzati, askpass packaged one-shot, pre-push old-zero guard, command registry frozen, import verificato e publication CAS durevole. `make check`, package E2E, ASan, TSan e preflight S4/S5-S7/S8 passano con Pi `0.84.0`, senza provider, credenziali reali o GitHub live.
- [x] W4 repository store, Git transport and exact publication.
- [x] 2026-08-07: W5 Pi runner e workflow app-versioned implementati su `feat/jidoka-code-w5-pi-workflows` da `origin/main@23037624`: resolver Pi/Node attestato, RPC full-duplex bounded, estensione e skill packaged, router review/triage/planning/orchestration, classifier deterministico e replay fake-provider. Verifica locale offline documentata in `docs/evidence/w5-pi-workflows-report.md`; zero provider, credenziali reali o GitHub live.
- [x] 2026-08-07: review indipendenti hanno riprodotto blocker non coperti dai primi gate: SIGPIPE, alias read, bootstrap find/grep, piano non vincolato, veto/synthesis/command order, causalità e status RPC, package/dylib closure, metadata case/nested, lifecycle reale Pi post-result, late child PGID e preparer arbitrario. Tutti hanno ricevuto falsificatori permanenti. Un secondo ciclo ha inoltre chiuso lifecycle iniziale/multi-turn, decisione planning opaca, hard link e fixture processi scheduling-sensitive; la matrice finale offline passa XCTest 1/1 e Swift Testing 232/232 in 38 suite, package E2E, S4/S8 con `providerCalls=0`, ASan e TSan.
- [x] W5 Pi runner and app-versioned workflows.
- [x] 2026-08-08: W6 coordinator end-to-end implementati su `feat/jidoka-code-w6-job-coordinators` da `origin/main@12f49a2`: PR review dual-source, triage, claim/piano/implementation, mutation generation, recovery SQLite, exact-head publication, post-open review e cleanup. Verifica offline documentata in `docs/evidence/w6-job-coordinators-report.md`; `make check`, 302 test standard, ASan, TSan, package E2E e preflight packaged S4/S5-S7/S8 passano con Pi `0.84.1` exact-attested e `providerCalls=0`.
- [x] W6 end-to-end job coordinators.
- [ ] W7-W8 implementation.
- [ ] W9 final verification, review e canary autorizzato.

## Surprises and discoveries

- Command Line Tools compila il core SwiftUI/ServiceManagement/SQLite probe ma non offre i moduli test; full Xcode li offre tramite per-process `DEVELOPER_DIR`, senza richiedere uno switch globale.
- Pi installato via Homebrew è JavaScript con shebang `env node`; il contesto Finder/launchd deve risolvere Node esplicitamente.
- Un review path esterno che richiede consenso interattivo per ogni invio non può essere il reviewer unattended del runtime. La fleet fresh-context è una decisione di prodotto, non un dettaglio di implementazione.
- La review architetturale indipendente non ha scelto helper o monolith; ha richiesto una prova composta prima della decisione.
- SwiftPM 6.3 ha aggiunto un LC_RPATH verso la toolchain Xcode anche al release binary; S1 ora lo rimuove prima della firma e fallisce su qualunque dependency/rpath non portabile.
- Un preflight positivo con grep di frammenti non prova consumo o integrità della risorsa. S1 ora muta, corrompe e rimuove il manifest nel bundle ri-firmato, valida JSON exact-key e confronta digest indipendente.
- Su questo host un servizio SMAppService assente può riportare `notFound`, incluso dopo un unregister riuscito; S2 lo considera inerte soltanto insieme ad assenza del launchd job e dei processi esatti.
- `plutil -replace` su un indice array ha inserito il nuovo valore senza rimuovere il precedente. S2 usa remove+insert e un preflight exact-arity prima dell’update.
- `SMAppService.mainApp` non supervisiona il processo dopo SIGKILL nel contesto provato; il monolith non soddisfa il topology gate lifecycle.
- La neutralizzazione Git non può basarsi soltanto su `origin`: credential helper, SSH, URL rewrite, hook e submodule fanno parte della superficie reale.
- `@Observable` rende macOS 14, non 13, il minimum coerente con l’UI scelta; il typecheck locale lo dimostra.
- Un read-back vuoto dopo un send incerto non prova assenza. Per comment/PR create il solo comportamento sicuro è attribution successiva o escalation.
- Ordinary pre-read più push non esprime da solo la regola branch absent in modo atomicamente dimostrato; la primitive CAS è ora un gate, non un dettaglio W4.
- I comandi DoD e gli hook sono un execution boundary distinto da Pi e richiedono un runner credentialless dedicato.
- L’OpenAPI ufficiale rende enumerabile l’assenza di endpoint merge e impedisce la categoria falsa “4xx/5xx generic retry”.
- Pi RPC espone il comando diretto `bash` anche con `--no-tools`; soltanto un handler packaged `user_bash` che termina con exit 126 ha impedito lo spawn nel probe popolato.
- Il prompt ACL Keychain manuale non è automatizzabile. S3 usa `security add-generic-password` con valore sintetico via stdin, creator escluso e trust ristretto a exact app bundle e helper; il prodotto dovrà usare la strategia del signing spike.
- `SMAppService` più firma ad-hoc accetta il bundle già registrato ma AMFI respinge una nuova code identity con `OS_REASON_CODESIGNING`, anche dopo unregister e incremento di `CFBundleVersion`. Il ritorno all’exact bundle precedente ripassa, isolando il problema alla firma/update e non alla lifecycle logic.
- Xcode ha inizialmente creato un certificato Apple Development senza chiave locale corrispondente. Una build automatica di un command-line tool senza bundle id o provisioning profile ha creato la coppia locale; `codesign` e il fresh signed lifecycle ne provano l’uso.
- Il constraint BTM storico sopravvive a `SMAppService.unregister()`: passare da ad-hoc a Apple Development sulla stessa label resta bloccato. Una label mai registrata, firmata Hikma fin dal primo run, accetta rebuild e generation update con lo stesso team.
- Pi/Codex con transport `auto` può tentare WebSocket e poi SSE dietro un solo `before_provider_request`; W1 impone SSE, provider retry zero e attesta i digest runtime per mantenere una request per reservation.
- Il direct Git smart protocol invia old SHA zero per una create osservata assente. Una fixture actor che crea il ref dopo advertisement ma prima di receive causa rifiuto CAS e lascia il ref concorrente invariato, senza flag force-class.
- Il ledger provider canonico è un authorization boundary durabile: 19 tentativi unici, tutti settled, nessun replay di attempt o fixture e nessun ventesimo tentativo possibile.
- Il PID del subshell launcher non prova cleanup di un'app AppKit: il primo S9 lasciava tre processi exact-path reparented. Il gate corretto enumera l'executable path, usa graceful quit riconosciuto e richiede zero processi esatti.
- Un `Retry-After` mancante o malformato non autorizza un delay arbitrario: il broker usa il reset di rate limit se valido, altrimenti escalation.
- Gli status GitHub `404/406/409/410/422` non sono categorie globali. L’operation inventory deve autorizzare ogni coppia operation/status; una coppia non dichiarata escala.
- Un initializer pubblico per iniettare token provider o transport trasformerebbe una seam di test in un bypass del Keychain/host boundary. Le seam restano `internal` e il package le prova con `@testable`.
- Un process group non basta contro un child che esegue `setsid()`: il runner W4 conserva identità PID più timestamp di avvio, termina i discendenti osservati e abbandona pipe ostili entro il deadline senza colpire PID riutilizzati.
- Il socket Unix askpass ha un limite di path molto inferiore ai path temporanei standard di macOS; il provider richiede una directory privata breve e fallisce prima di esporre il token.
- Il system Pi è avanzato esternamente a `0.84.0` e include breaking changes RPC. La decisione #54 accetta il range `>=0.84.0 <0.90.0` senza fiducia semver cieca: solo build con digest esatti nell'allowlist packaged possono partire; oggi è presente soltanto `0.84.0`.
- Il packet trace old-zero da solo copriva soltanto la race dopo advertisement: una ref fast-forwardable apparsa prima dell'advertisement veniva avanzata dall'ordinary push. W4 aggiunge un helper pre-push compilato che rifiuta ogni old SHA nonzero prima del transfer; la CAS old-zero del receive copre la finestra successiva.
- Il Pi RPC writer può inviare prompt molto più grandi della pipe. W5 rende anche stdin nonblocking e include il write nel deadline monotonic; un fake child che smette di leggere non può bloccare il runner oltre timeout, abort e cleanup bounded.
- Un digest che concatenava argomenti e environment senza domain count permetteva collisioni semantiche. W5 usa framing tipizzato con count e indice prima che reviewer e plan congelino la definizione.
- Pi `0.84.0` emette dopo il terminal tool end anche il tool-result `message_start/message_end` e `turn_end`; saltare quel suffisso rendeva impossibile un risultato reale. La state machine e le fixture ora richiedono l'ordine completo.
- Per `@rpath`, attestare un candidato valido successivo non basta: dyld carica il primo file esistente. Resolver Swift e probe JS falliscono sul primo shadow non allowlisted.
- Un leader può uscire subito dopo `agent_settled` lasciando un child non ancora osservato nello stesso PGID. Il cleanup ora termina sempre il process group dedicato prima della verifica finale.
- I pathspec Git root-only non escludono metadata nested mixed-case. Status e diff usano exclusion `glob,icase` a ogni profondità; search/list applicano prune app-owned equivalente.
- Containment lessicale, `realpath` e `O_NOFOLLOW` non fermano un hard link verso un inode esterno. Read/edit/search rifiutano file regolari con `nlink != 1` e il contratto contiene un falsificatore con sentinel esterno.
- Un hash planning non opaco non dimostra approvazione. Il piano finale contiene la decisione di complessità e i cinque role result ordinati; constructor, orchestration e command runner rivalidano candidate digest, payload, command definitions, approval digests e record identity.
- Le deadline da 0.2/0.3 secondi misuravano anche startup Node e potevano scadere prima del falsificatore. Le fixture pubblicano readiness prima del blocco e usano tre secondi; gli eventi fixture usano write sincrone prima dell'exit. Il runner ridrena output/error dopo aver osservato l'exit prima di classificare un settlement mancante. La suite processi passa dieci ripetizioni standard e dieci ASan consecutive oltre ai gate completi.
- `humanOwned` deve restare non eseguibile anche se cinque payload appaiono coerenti e `pass`. La validazione strutturale del planning decision lo rifiuta prima di creare un piano finale, oltre al gate del planning router.
- Una sequenza PR oldest-first non è necessariamente una catena lineare: merge e branch sibling sono validi. Il digest ora richiede ordine topologico dei parent inclusi e raggiungibilità di tutti i commit dalla head esatta.
- Verificare solo il file finale di una skill permette ancestor symlink. Swift apre ogni componente con `openat` no-follow e richiede `nlink == 1`; il contratto JS applica lo stesso vincolo a manifest e risorse.
- Bloccare hard link in read/search non protegge `git diff`, che legge direttamente il working tree. Ogni diff esegue prima un inventario bounded e rifiuta qualsiasi file regolare multiply linked.
- Prunare `.git` dall'output non vincola la repository che Git scopre. Query e command gate richiedono `.git` directory interna, metadata recursively contained, nessun hard/symlink, common-dir, alternates, include o `core.worktree`, poi usano git-dir/work-tree espliciti.
- `--no-ext-diff` e `--no-textconv` non disattivano i clean filter. Prima di Git, il contratto legge la config locale con includes disabilitati e ammette soltanto le chiavi benign allowlisted; un filter che scrive un marker viene rifiutato prima dello spawn.
- Anche `git status` può eseguire `post-index-change` durante refresh. Git read/stage forzano `core.hooksPath=/dev/null`, read aggiunge `--no-optional-locks`; solo commit può abilitare un path hook esatto, presente in config e approvato nel piano.
- Head-last e topologia non provano completezza della narrativa. Il router richiede ora base/head, uguaglianza esatta tra set narrativa, commit REST e traversal Git fetched, e almeno un percorso parent dalla head alla base dichiarata; W6 deve produrre le due fonti indipendentemente.
- Una query `find` con path `-delete` e un Git diff con textconv/config locale sono execution surfaces, non semplici letture. W5 prefissa path relativi ostili, disabilita textconv, fsmonitor, hook, external diff e optional locks, e prova che il file `-delete` sopravvive.
- Le risorse installate possono essere root-owned, mentre configurazione, workspace e directory Pi temporanee devono essere user-owned e private. L'attestation W5 distingue esplicitamente i due trust boundary.
- Uno step completato e durable deve essere l'autorità di recovery: rieseguire Pi o una mutation dopo il commit dello step crea duplicate side effect. W6 avanza lo step già completato e conserva artifact, intent e attribution prima di appendere completion.
- Una mutation generation autorizzata non rende invisibili le generazioni precedenti: marker e PR devono leggere ogni intent storico esistente prima di un resend, saltando soltanto le generazioni che non hanno mai preparato quell'operazione.
- Il Pi globale è avanzato esternamente da `0.84.0` a `0.84.1` durante la verifica W6. La policy ha prima bloccato sia il test JavaScript del package tree sia il resolver Swift. Su indicazione del project owner, una copia isolata con policy temporanea exact-digest ha poi superato `make check`, package E2E e preflight packaged S4/S5-S7/S8 senza provider; soltanto dopo quella prova l'allowlist versionata ha aggiunto l'exact build 0.84.1 mantenendo 0.84.0.

## Execution decisions

Append-only.

- 2026-08-05: implementation invocation autorizza local source edit e worktree soltanto; commit, push, provider call, Keychain, ServiceManagement, installer e GitHub mutation restano non autorizzati.
- 2026-08-05: W0 usa `origin/main@688feb5f87e04e572fffc8b3cac624ad1541379f` e worktree `feat/jidoka-code-macos-app`; global `xcode-select` resta CLT e tutti i comandi Apple usano l’exact per-process developer directory.
- 2026-08-05: OpenAPI head è avanzato rispetto al pin, ma la projection di operation id e response status usata dal piano è byte-identica; nessuna locked decision cambia.
- 2026-08-05: W1 anticipa `.gitignore` da W8 perché i gate scaffold producono `.build`, `build` e artifact harness; nessun output generato entra nel changed-file set.
- 2026-08-05: review round 1 ha dimostrato che presenza file, grep output e filename blacklist non erano evidence sufficiente. S1 usa ora exact inventory, normalized binary provenance, Mach-O allowlist, JSON schema/key set, independent SHA e dynamic packaged-resource mutation.
- 2026-08-05: project owner autorizza commit, push e PR della tranche W0/W1 S1 e approva CHECKPOINT A come presentato. S2/S3 sono limitati agli exact target registrati; S4/S8 hanno hard cap 19 call senza retry e payload sintetici.
- 2026-08-05: S2 scarta il monolith per assenza di crash restart entro 30 s. LaunchAgent helper resta l’unico candidato lifecycle, ma non diventa decisione #35 definitiva prima di S3-S5 e S9.
- 2026-08-05: per cleanup e precondition SMAppService, `notFound` equivale a stato inerte soltanto quando il job agent e i processi app/helper sono anch’essi assenti; `enabled` resta obbligatorio durante la prova registrata.
- 2026-08-05: S3 non delega il valore sintetico a argv o env. L’harness lo passa due volte via stdin a `security -w`, esclude il creator con `-T ""`, autorizza exact app/helper, conserva soltanto SHA-256, e richiede read/replace/helper/Pi-gate più cleanup.
- 2026-08-05: il falsifier AMFI attiva la decisione #37. Nessun reset BTM è stato usato; il project owner ha poi autorizzato certificato locale e fresh signed labels esatte per ripetere i gate packaged.
- 2026-08-05: il fresh signed probe differisce dal sorgente operativo soltanto per i due identifier autorizzati. Usa `SIGN_IDENTITY` exact SHA-1, hardened runtime, nested-before-outer signing e stessa identità sul generation update; S2/S3 passano e gli artifact redatti sono conservati sotto `build/evidence/signed-hikma-fresh-probe/`.
- 2026-08-06: S4 usa un `PI_CODING_AGENT_DIR` isolato, solo auth `openai-codex`, SSE, tool disabilitati e provider hook `reserved -> issued`; quattro profili passano e il falsifier locale blocca la seconda request prima del provider.
- 2026-08-06: S5-S7 passano nel bundle firmato. S6 prova CAS create-only old-zero con race al receive e nessun force-class flag; S7 classifica 120 casi senza seconda create.
- 2026-08-06: S8 consuma le 15 call residue, tutte fresh-context e schema-valid. Il ledger raggiunge esattamente 19/19. Decisione #53 seleziona il LaunchAgent helper; il monolith probe è rimosso. W2 resta bloccato in attesa di Checkpoint B.
- 2026-08-06: il primo S9 cleanup basato sul launcher PID è falsificato da tre processi app reparented. Terminati solo gli exact target, il test passa a exact-path inventory più acknowledged graceful quit; run ad-hoc e Apple Development chiudono a zero processi.
- 2026-08-06: W3 parte soltanto dopo fetch e prova che W2 `9df46a6c00ff8057ee04ae98ace141d577548422` è antenato di `origin/main@97b1fad`; branch e worktree dedicati non toccano il checkout di sviluppo.
- 2026-08-06: W3 è fixture-only. Il Security backend e il transport production compilano, ma token provider/transport injection restano internal; non viene letto alcun Keychain reale e non parte alcuna request GitHub o provider.
- 2026-08-06: pagination e marker input hanno ceiling espliciti con escalation, non truncation; una create con send iniziato non può mai essere inviata una seconda volta automaticamente.
- 2026-08-06: il project owner autorizza un singolo commit W3 e il push non-force del branch dedicato; merge e ulteriori side effect restano non autorizzati.
- 2026-08-06: W4 parte soltanto dopo fetch e prova che W3 `f635ceea10150de8618608d240ed4d5aa40f80c2` è antenato di `origin/main@2ab0cbfe4db43a22e970e53c122af18875d41263`; il worktree dedicato non tocca checkout di sviluppo.
- 2026-08-06: W4 resta offline/local. La publication usa intent SQLite `prepared -> sendStarted -> settled`, pre-push guard sull'old SHA advertised, packet old-zero e read-back; recovery da send unknown è read-only. Nessun commit del worktree, push remoto, Keychain reale, request GitHub o provider call è autorizzato o eseguito.
- 2026-08-06: il project owner approva la decisione #54. Il range Pi è `>=0.84.0 <0.90.0`, ma ogni build richiede provenance digest-pinned; `0.84.0` passa i preflight packaged S4, S5-S7 e S8 con auth isolata vuota, zero credential access, zero provider call e ledger canonico invariato 19/19.
- 2026-08-07: W5 parte soltanto dopo fetch e verifica del merge PR #6 in `origin/main@23037624`; branch e worktree dedicati non modificano i checkout di sviluppo.
- 2026-08-07: W5 mantiene un solo writer per job, reviewer e synthesis fresh, massimo tre round, e approvazioni command digest esatte. L'app canonicalizza argv e plan; nessun output modello può introdurre executable, argv, session resume o remote capability.
- 2026-08-07: la verifica W5 resta offline. Il preflight usa HOME e agent directory isolati, auth vuota e `PI_OFFLINE=1`; fake-provider e replay sostituiscono call reali. Nessun provider, Keychain reale, GitHub, commit, push o firma Apple Development viene eseguito.
- 2026-08-08: W6 parte dal merge W5 `12f49a2499c8ddc29311d19577b4b1dd06955950` in branch/worktree dedicati. Workflow production e recovery vengono verificati soltanto con fake GitHub, deterministic Pi fixture, SQLite temporanei e Git locali; nessun provider, credential reale o mutation GitHub live viene eseguito.
- 2026-08-08: completed step, mutation intent e exact read-back sono le autorità di recovery. Retry umano incrementa la generation ma controlla tutte le generazioni precedenti; workspace con stato writer ignoto e modifiche locali viene bloccato e conservato.
- 2026-08-08: il project owner autorizza un singolo commit W6, push non-force del branch dedicato e apertura PR. Il merge resta al project owner. Dopo il fail-closed sul Pi globale 0.84.1, autorizza integration test locali: la policy temporanea e poi quella versionata legano l'exact package tree e passano i gate offline senza credential o provider call.

## Outcomes and retrospective

W0, W1 S1-S9 e W2-W6 sono eseguiti. Ad-hoc è definitivamente scartato per le prove lifecycle; Apple Development Hikma soddisfa package, lifecycle update, Keychain, Pi e workflow fidelity. Il helper è l'unica topologia che passa tutti i threshold ed è locked dalla decisione #53; il monolith è rimosso. Checkpoint B è accettato. Il budget provider resta esaurito esattamente a 19/19 senza retry. Durable core, broker/reconciliation GitHub, transport Git app-managed, workflow Pi W5 e coordinator W6 sono verificati localmente. La policy ammette le exact build Pi `0.84.0` e `0.84.1`; per 0.84.1 passano root gate, package e preflight offline senza provider call. W7-W9, UI/lifecycle, credential e GitHub canary, installer e final review restano aperti.
