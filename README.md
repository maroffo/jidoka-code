# Jidoka Code

Servizio web personale in Rust per revisionare pull request pubbliche su GitHub. La guida **Dove concentrarti** mette in evidenza il codice da leggere, il controllo già svolto e le decisioni che richiedono un maintainer.

Il motore legge modifiche testuali di qualsiasi stack. In due passaggi formula ipotesi e cerca nel codice elementi che le smentiscano. Verifica percorsi, righe e citazioni sulle revisioni esaminate. Semgrep fornisce indizi aggiuntivi quando esiste una regola applicabile. Il pilota include una regola per Python. La review generale funziona anche su un repository senza Python e su PR che attraversano più linguaggi.

## Avvio

Crea un file locale `.env` con i repository pubblici ammessi e il provider autorizzato a ricevere il codice. Il provider deve accettare Chat Completions con output JSON. Inserisci il suo URL completo.

```dotenv
JIDOKA_REPOS=organizzazione/progetto
JIDOKA_PROVIDER_URL=https://provider.example/v1/chat/completions
JIDOKA_MODEL=modello-abilitato
JIDOKA_API_KEY=
```

```sh
docker compose up --build
```

Apri [Jidoka](http://localhost:8080), inserisci la PR e conferma il destinatario. La cronologia rimane nel volume SQLite `reviews`, compatibile con il pilota precedente. Il servizio è destinato a un solo utente su loopback.

## Sviluppo

Il pilota è verificato con Rust 1.100. Per compilare e avviare il binario, esporta nella shell le variabili sopra ed esegui `cargo run --locked`. Per eseguire lo scanner in locale serve anche Semgrep CE sul PATH. L’immagine Docker lo include. La raccolta da GitHub usa le API pubbliche senza token e limita file, byte, richieste e tempo. Il rapporto espone eventuali lacune.

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```

Con Semgrep installato, `cargo test --locked -- --include-ignored` esegue anche la regola reale sui file di controllo.

[Specifiche](docs/specifiche.md) · [Piano di implementazione](docs/piano.md)
