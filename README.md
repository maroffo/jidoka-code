# Jidoka Code

Servizio web personale per la review di pull request pubbliche. Mostra dove concentrare una review manuale, i problemi verificati al commit esaminato e i limiti dell’analisi.

## Avvio

Serve Docker Compose. In un file locale `.env` configura il repository autorizzato e il servizio che può riceverne il codice. Il provider deve accettare Chat Completions con output JSON. Usa il suo URL completo.

```dotenv
JIDOKA_REPOS=organizzazione/progetto
JIDOKA_PROVIDER_URL=https://provider.example/v1/chat/completions
JIDOKA_MODEL=modello-abilitato
JIDOKA_API_KEY=
```

```sh
docker compose up --build
```

Apri [Jidoka sul tuo computer](http://localhost:8080), incolla la PR e verifica il destinatario prima di inviare. SQLite conserva la cronologia nel volume Docker `reviews`. Il pilota è pensato per un solo utente su loopback. La scansione locale applica le regole distribuite con il progetto. Un controllo incompleto compare nei limiti della review.

## Sviluppo

Con Python 3.12 o successivo, esporta le stesse variabili nella shell ed esegui `python -m jidoka.app`. Semgrep CE deve essere disponibile sul PATH per usare lo scanner. L’immagine Docker lo include. Per i test offline:

```sh
uv run --no-project python -m unittest discover -s tests -v
```

[Specifiche](docs/specifiche.md) · [Piano di implementazione](docs/piano.md)

Il pilota include una regola Semgrep per le chiamate Python a subprocess con shell abilitata. Segnala il punto da verificare e mostra i limiti per gli altri linguaggi. Il collector usa le API pubbliche di GitHub senza token e limita il numero di file, le richieste e i byte per review. PR ampie o la quota GitHub esaurita possono dare un esito parziale o fallito.
