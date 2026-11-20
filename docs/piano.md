# Piano di implementazione

## Decisioni di integrazione

Servizio Python 3.12+, SQLite, GitHub HTTPS in sola lettura, un provider con API chat compatibile con OpenAI, HTML lato server. Un processo di lavoro preleva una review dalla coda alla volta. Il coordinatore possiede i contratti, l'avvio, l'immagine Docker e il collaudo completo. I tre agenti Sol lavorano in parallelo con proprietà disgiunta dei file. Le fixture devono contenere solo codice sintetico. Un solo integratore crea i commit.

## Contratti comuni

Il modulo jidoka/contracts.py è di proprietà del coordinatore. I payload sono dati JSON. Le firme e gli esempi seguenti permettono lo sviluppo indipendente. Le liste sono sempre presenti, anche se vuote.

- source.collect(url, allowed_repos) restituisce Snapshot. allowed_repos è un insieme di stringhe owner/repo. Snapshot contiene url, repo, number, base, head, intent (lista di stringhe), files, limits. Ogni file contiene path, patch, before e after come testo. Le posizioni sono numerate da 1 sul testo after. base identifica la base comune del diff. Materiale non acquisito viene dichiarato in limits, lista di stringhe.
- scanner.scan(snapshot) restituisce un oggetto con signals (lista di oggetti con rule, path, line, message), limits (lista di stringhe), version (stringa), covered (lista di percorsi).
- engine.review(snapshot, scan, ask) restituisce report. ask(system, data) riceve una stringa e un oggetto JSON, restituisce un oggetto JSON. Il coordinatore implementa il trasporto HTTP e i timeout. report contiene focus, findings, limits. Ogni focus ha path, line, checked, outcome, action. Ogni finding ha path, line, title, impact, evidence, attribution. evidence è la spiegazione leggibile con citazioni verificate. attribution vale introduced, preexisting o unknown. Le posizioni puntano alla revisione head.
- web.create_app(db_path, provider_label) restituisce una applicazione WSGI. Il modulo web espone anche run_one(db_path, process), che preleva al massimo una richiesta dalla coda, chiama process(url) e salva il risultato o l'errore. process restituisce un oggetto con repo, base, head, focus, findings, limits e il risultato dello scanner. Il processo principale invoca web.recover(db_path, provider_label) una sola volta prima di avviare il worker. Una richiesta in coda per un destinatario diverso richiede un nuovo consenso. Le esecuzioni interrotte diventano visibilmente fallite. I testi delle eccezioni esterne non finiscono negli errori pubblici.

## Lavori paralleli

| Unità | Proprietario e file | Risultato osservabile | Verifica prima della consegna |
| --- | --- | --- | --- |
| A. Sorgenti e scanner | Sol A, jidoka/source.py, jidoka/scanner.py, rules/, tests/test_source.py e tests/test_scanner.py | Acquisizione PR e contesto con revisioni immutabili, gestione fork e limiti, scansione CE locale con budget | PR cambiata durante la lettura, percorsi anomali, paginazione e troncamento, regola positiva e negativa, scanner assente |
| B. Metodo di review | Sol B, jidoka/engine.py, tests/test_engine.py | Due passaggi, verifica delle citazioni, selezione delle priorità umane e rapporto | Scartare riga o fonte inventata, ipotesi smentita e falso OK. Accettare difetto documentato e domanda umana specifica. Distinguere output malformato da review pulita |
| C. Esperienza web | Sol C, jidoka/web.py, tests/test_web.py | Inserimento con consenso, cronologia SQLite, navigazione, stato persistente, recupero job interrotto e rapporto leggibile | Test WSGI attraverso form, coda, pagina esito, escape HTML, consenso mancante, dati persistenti e gestione errore |
| D. Avvio e integrazione | Coordinatore, jidoka/app.py, Dockerfile, compose.yaml, README, test integrati | Processo web e worker, provider configurato, scansione installata nell'immagine e una review navigabile | Avvio locale e da Docker, test HTTP con dati sintetici, verifica ripartenza, errore provider e assenza di pubblicazione esterna |

A, B e C partono dopo il congelamento dei contratti. D può preparare trasporto e packaging in parallelo. D collega i moduli solo dopo i test di A, B e C. Ogni agente segnala al coordinatore le variazioni di contratto prima di applicarle. Nessun agente effettua push o merge.

## Collaudo e rilascio

1. Eseguire unittest discovery, controllare che i test siano stati scoperti e che nessun test richieda credenziali, poi costruire l'immagine. Verificare che una regola reale di Semgrep rilevi la fixture positiva e ignori la negativa.
2. Avviare l'app, inviare una PR sintetica attraverso HTTP con trasporti di test, seguire il collegamento al rapporto e aprire la cronologia dopo un riavvio. Controllare che ogni riferimento punti a repo, revisione e riga giusti.
3. Eseguire la prima review esterna solo su repository e provider autorizzati. Annotare separatamente cosa è stato provato in locale, in Docker e dal vivo. Eseguire il confronto sulle dieci PR quando viene selezionato il campione.
4. Pubblicare il ramo con radice indipendente. La sostituzione della main esistente richiede conferma del riferimento, politica di conservazione e valore remoto atteso. Fermarsi se main cambia. Gli altri worktree e i loro file locali sono fuori dal perimetro della riscrittura.
