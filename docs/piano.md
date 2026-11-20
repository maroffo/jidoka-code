# Piano della migrazione Rust

Il riferimento funzionale è il pilota Python al commit `75700b6`. Il prodotto mantiene il flusso di consenso, gli URL dei rapporti, la cronologia SQLite e i parametri Docker. L’applicazione è un singolo eseguibile Rust con un worker e pagine HTML rese dal server.

## Ordine del lavoro

| Fase | Responsabile | Consegna | Verifica |
| --- | --- | --- | --- |
| 1 | Coordinatore | Tipi condivisi per snapshot, controlli e rapporto, contratto JSON per il provider | Le tre unità compilano contro gli stessi tipi |
| 2A | Sol sorgenti | Raccolta GitHub a revisioni immutabili, scelta del contesto trasversale ai linguaggi e Semgrep opzionale | Limiti espliciti, percorsi sicuri e test con più stack |
| 2B | Sol motore | Due passaggi avversariali, controllo delle citazioni, attribuzione rispetto alla base e guida umana | Casi positivi, ipotesi smentite, riferimenti inventati e review senza segnali Semgrep |
| 2C | Sol web | Interfaccia Axum e coda SQLite con consenso legato al destinatario | Accesso loopback, protezione del modulo, riavvio, rapporti storici e stati distinti |
| 3 | Coordinatore | Provider, worker, Docker e integrazione | Confronto con il riferimento Python su risposte identiche, test HTTP, regola Semgrep reale e avvio del container |

Le unità 2A, 2B e 2C procedono in parallelo. Il coordinatore integra sul ramo della PR dopo la verifica comune. I test usano repository e risposte del modello sintetici. La valutazione della qualità del modello su dieci PR storiche autorizzate rimane un esperimento separato.
