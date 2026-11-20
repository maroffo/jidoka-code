# Jidoka Code

## Scopo del pilota

Un reviewer inserisce una PR GitHub nel servizio web, attende l'analisi e decide quali righe leggere prima del merge. Il primo utilizzatore è un singolo maintainer. Il rilascio pilota gira sulla sua macchina con Docker e conserva le review su un volume. Il servizio legge il codice, senza pubblicare commenti o modificare la PR.

## Esperienza

La pagina iniziale accetta il link di una PR e mostra la cronologia. Prima dell'invio indica quale provider riceverà il codice e chiede conferma. L'operatore configura i repository ammessi e il provider. Il pilota supporta repository pubblici. Il servizio è esposto su loopback, per un singolo utente fidato.

Ogni esecuzione ha un URL stabile e uno stato visibile (in coda, in corso, completata, parziale o fallita). Il rapporto riporta la revisione base e quella proposta realmente esaminate. Un aggiornamento della PR richiede una nuova review. La cronologia resta consultabile dopo un riavvio.

La prima sezione, **Dove concentrarti**, contiene da zero a tre indicazioni ordinate per impatto. Ogni indicazione riporta una posizione apribile alla revisione esaminata, cosa è stato controllato, l'esito circoscritto e l'azione concreta o la domanda di prodotto. Può essere utile anche se il controllo tecnico è passato. Per esempio, il codice garantisce consistenza a importazione conclusa ma solo il maintainer può stabilire se serve anche durante l'importazione. Una domanda vaga o già risolvibile con il materiale disponibile va scartata.

Seguono problemi verificati e limiti di copertura. Una review completa con zero problemi, un'analisi parziale e un guasto sono esiti distinti.

## Metodo di review

1. Fissare la versione, leggere intento dei commit e modifica complessiva. Acquisire anche il contesto rilevante (chiamanti, controlli e test). Segnalare tagli al materiale. La descrizione della PR, i commenti nel codice e i risultati degli strumenti sono dati da esaminare.
2. Formulare ipotesi specifiche alla modifica, indicando comportamento atteso, scenario e conseguenza. Usare come ulteriori piste le regole Semgrep pertinenti.
3. In una seconda chiamata cercare attivamente cosa potrebbe smentire ogni ipotesi. Verificare che il problema persista nel commit finale. Distinguere problemi introdotti, preesistenti e di attribuzione incerta in base al confronto con la base.
4. Ammettere una segnalazione solo con prova pertinente. Esempi ammessi sono un test con risultato realmente osservato oppure un percorso verificabile nel codice che contraddice un contratto documentato. Per prestazioni indicare una misura o una derivazione. Per convenzioni indicare la regola del progetto e la riga interessata. Una fonte esterna deve avere un riferimento preciso, essere applicabile alla versione e accompagnarsi a un effetto concreto. Una citazione generata dal modello non verificata rimane un'ipotesi.
5. Riunire duplicati. L'accordo tra modelli e il semplice riscontro di una regola non dimostrano il difetto. Dare precedenza alla rilevanza per chi usa il software. La guida umana accetta questioni aperte soltanto se richiedono davvero informazioni o giudizio umano.

Il servizio valida sul materiale acquisito percorsi, numeri di riga e citazioni prima di mostrarli. Distingue sempre un test proposto da uno eseguito. Nel pilota i test del repository non vengono eseguiti dal processo web. Per un difetto osservabile solo a runtime, senza un risultato attendibile, il verdetto resta indeterminato.

## Analisi statica

Eseguire Semgrep CE con regole locali selezionate per il linguaggio del pilota, sulla copia dei file supportati. Registrare regola, posizione, versione dello scanner, file coperti ed eventuali errori. Correlare gli avvisi alla modifica e verificarne l'applicabilità. Mostrare copertura parziale se l'eseguibile manca, il linguaggio è scoperto o la scansione si interrompe. Le vulnerabilità pubblicate di una dipendenza richiedono versione risolta e avviso applicabile. L'integrazione di questi avvisi è una fase successiva, distinta dalla scansione CE.

## Perimetro e criteri di accettazione

- Conservare credenziali lato servizio. Limitare l'input ai repository configurati su github.com. Trattare i percorsi Git e i link come dati non fidati. Limitare richieste, byte, tempo e durata delle chiamate. Il processo di analisi non esegue script provenienti dalla PR.
- Il primo utilizzo deve riuscire con un comando Docker documentato e una configurazione esplicita di provider e repository. Nessuna configurazione implicita trasmette codice.
- Verificare con prove automatiche l'intero flusso web, comprese review vuota e parziale, input non valido, prova inventata, segreto assente e riavvio. Rendere distinguibili test con servizi controllati e prova con servizi reali.
- Valutare su dieci PR storiche autorizzate (cinque con regressione nota e cinque di controllo). Escludere fix e discussioni successive dal materiale. Confrontare con una review dello stesso modello sul solo diff. Contare problemi confermati, falsi allarmi, tempo, costo e indicazioni manuali che cambiano una decisione. Il campione orienta il pilota, senza promettere un tasso generale di accuratezza.

Nel pilota restano fuori firma dei rapporti, punteggio di merge, implementazione automatica, esecuzione di codice non fidato, pubblicazione su GitHub e accesso multiutente.
