# Sidecar, History und Zustellung betreiben

Inhalt: Evaluator-Zuordnung; History-Zugang; Dateninterpretation; Webhook-Lanes; gezielte Fehlersuche.

## Evaluator-Zuordnung und Start

Der Sidecar ist ein eigener Go-Prozess, kein Teil des CLI-Befehls. Für ein ausdrücklich gewünschtes Deployment lautet die Startform:

```sh
nrc-incidents -server wss://nrc-bot.internal.example.net -workspace operations \
  -nickname nrc-incidents -history /private/data/history.duckdb \
  -history-listen 127.0.0.1:8095
```

Das ist ein Startbeispiel, keine Aufforderung, einen zweiten Evaluator neben einer bestehenden Installation zu starten. Builds benötigen Linux, Go 1.26+ und den C/C++-Buildpfad für DuckDB CGO; Build-Anweisungen stehen in `services/bots/nrc-incidents/README.md` ab Repository-Root. Bestehende Service-/Containerverwaltung benutzen, Deployment und Neustart nur im angeforderten Umfang.

`-server` muss auf den bestehenden, für Bot-Authentifizierung vorgesehenen NRC-Zugang zeigen; der Host im Beispiel ist ein Platzhalter. Nicht ungeprüft die CLI-/Tailscale-Proxy-Adresse übernehmen: Der Benutzerproxy entfernt die Bot-Header und setzt stattdessen die Tailscale-Benutzeridentität. `NRC_BOT_SECRET` muss zur Serverkonfiguration passen. Einen geeigneten privaten bzw. TLS-geschützten Servicezugang verwenden; dafür weder den Benutzerproxy abschwächen noch den NRC-Backendport öffentlich freigeben. Einen fehlenden Servicezugang als Deployment-Voraussetzung klären, nicht durch Umbenennen des Evaluators umgehen.

- `NRC_BOT_SECRET` kommt aus der Prozessumgebung, nie aus einer Kommandozeilenoption. Der authentifizierte Nickname muss dem `evaluator` der Monitore entsprechen.
- Ohne `-monitors` entdeckt der Sidecar zugeordnete Monitore beim Start und 30 Sekunden nach jeder Discovery-Runde, einschließlich deaktivierter Monitore für Zustellung und Availability. Das ist keine sofortige Live-Subscription.
- `-monitors 456,457` setzt eine feste Allowlist und verhindert automatische Aufnahme weiterer Monitore. Für Discovery diese Option im Deployment entfernen, nicht zusätzlich einen zweiten Prozess starten.
- Eine unvollständige Discovery behält den letzten vollständigen Satz. Grenzen sind 1024 Monitore, 128 Seiten, 16 MiB und 30 Sekunden pro Runde.
- Ein Evaluatorprozess pro Monitorsatz. Die lokale DuckDB-Dateisperre ist keine verteilte Leader-Wahl. Zwei Dateien machen doppelte Evaluatoren nicht sicher.
- `-workers` standardmäßig 8, erlaubt 1–64. Derselbe Monitor überlappt sich nicht, verpasste Intervalle werden nicht als Burst nachgeholt.

Der Sidecar öffnet keine NRC-SQLite-Datei. Eine DuckDB-Störung kann History verlieren, darf aber keine NRC-Evaluation zurückweisen. Abschalten/Neustart und Produktionsalarmtests sind keine Voraussetzung für eine reine CLI-Konfigurationsprüfung.

## History-Zugang konfigurieren

Es gibt keinen CLI-History-Unterbefehl. Die optional aktivierte Sidecar-HTTP-API ist für direkte Servicezugriffe; der Browser verwendet den authentifizierten Proxy.

Sidecar:

- `-history-listen 127.0.0.1:8095` aktiviert den sonst ausgeschalteten Listener.
- `NRC_HISTORY_SECRET`: eigener zufälliger Token mit mindestens 32 Zeichen. Nicht mit dem Bot- oder Quellen-Token gleichsetzen.
- Listener nur Loopback oder kontrolliertes privates Netz. Er spricht HTTP; außerhalb eines vertrauten verschlüsselten Netzes TLS am Proxy verwenden. Kein CORS.

Tailscale-Proxy:

- `NRC_MONITOR_HISTORY_BACKEND`: HTTP(S)-Origin des Sidecars ohne Pfad.
- `NRC_MONITOR_HISTORY_WORKSPACE`: genau dessen Workspace.
- `NRC_HISTORY_SECRET`: derselbe History-Service-Token wie im Sidecar, ausschließlich serverseitig.
- Gatewaypfad `/monitoring/history/<monitor-id>/<samples|runs|uptime>`. Der Client sendet `X-NRC-Workspace` passend zur Konfiguration. Benutzerzugriff folgt `NRC_WORKSPACE_ACCESS`; nicht ausdrücklich eingeschränkte Workspaces sind tailnet-offen.

Ein Gateway bedient derzeit einen Sidecar-Workspace, kein Multi-Evaluator-Routing. Den History-Token niemals im Browser ablegen oder an Benutzer als Ersatz für deren Workspace-Berechtigung verteilen. Er erlaubt Servicezugriff auf den Deployment-Workspace und dessen aktuell entdeckte/konfigurierte Monitor-IDs. Nicht mehr entdeckte Monitore können 404 liefern, obwohl Daten noch gespeichert sind.

## History lesen und korrekt interpretieren

Direkte Endpunkte: `GET /v1/history/<monitor-id>/samples`, `/runs`, `/uptime`. Direkter Zugriff braucht `Authorization: Bearer <service-token>`. Verwende vorhandene authentifizierte HTTP-Werkzeuge und schütze den Token vor Prozesslisten, Debuglogs und Ausgaben; Tokens nicht in kopierfertige URLs einfügen.

Alle Abfragen verlangen `from`, `to` als RFC3339 und `resolution`. Das Intervall ist `[from,to)`, maximal 400 Tage; Aggregatgrenzen müssen UTC-bucketgenau ausgerichtet sein. IDs, Revisionen, Zeiten und Zähler in Antworten sind Dezimalstrings.

Für `/samples` und `/runs` ist zusätzlich `acceptance` verpflichtend; es gibt keinen Default. Bei `/uptime` ist dieser Parameter verboten.

- `samples`: Rohmessungen oder aggregierte Messwerte; `resolution=raw|5m|1h` und `acceptance=confirmed|rejected|unknown|all`.
- `runs`: Ausführungsversuche, auch bei Fehlern/leeren Ergebnissen; gleiche Auflösungs- und Akzeptanzparameter.
- `uptime`: Zeitanteile; nur `resolution=5m|1h`, kein `acceptance`.
- `samples` und `uptime` erlauben `identity` als exakten URL-encodierten Identitätsstring. Keine Workspace-Overrides, unbekannten oder doppelten Parameter senden.

Beispiel eines geheimnisfreien Request-Pfads für eine abgeschlossene UTC-Stunde; Datum und Monitor-ID an die tatsächliche Untersuchung anpassen:

```text
/v1/history/456/samples?from=2026-11-16T00:00:00Z&to=2026-11-16T01:00:00Z&resolution=5m&acceptance=confirmed
```

`confirmed` heißt von NRC bestätigt, `rejected` abgewiesen und `unknown` unbestätigt nach unklarer Übermittlung. Unknown ist nicht rejected. History und NRC sind nicht crash-atomar gekoppelt; ein akzeptierter Run kann ohne History bleiben. Leere Zeilen bedeuten keine passenden erhaltenen Daten, nicht Nullmessungen oder 100 % Uptime.

HTTP-Einzelbedingungen stehen bei rohen `/runs`-Antworten in `rows[].diagnostics` mit Version, Bedingungsindex, Ergebnis und skalarem Istwert; numerische Sollwerte stehen präzise in `expected_number`. Texte können als `truncated` gekürzt sein, der Vergleich verwendete den Originalwert. Keine Objekte oder kompletten HTTP-Bodies erwarten. TCP hat keine Bedingungsliste, Victoria verwendet Messwerte/Schwellen statt HTTP-Diagnostik.

Eine Diagnose nur bei gleicher Revision der Definition zuordnen; als aktuelle Evaluation nur bei `confirmed` und passender Revision und Sequenz des NRC-Instanzzustands bezeichnen. Historische Bedingungen nicht anhand inzwischen geänderter Definitionen umbenennen. Diagnosewerte können vertraulich sein; nur im erlaubten Workspace-Kontext weitergeben.

Uptime ist `healthy / (healthy + failing)`, nicht der Anteil erfolgreicher Checks und nicht die Dauer ohne offenen Incident. Coverage bewertet bekannte gegen erwartete nicht pausierte Zeit. Im DuckDB-Summary ist sie `(healthy + failing) / (healthy + failing + unknown)`; die UI berücksichtigt zusätzlich fehlende Buckets im angezeigten Fenster. Daher Kennzahlen nur bei gleichem Fenster, Revision, Identitätssatz und Coverage-Nenner vergleichen. Die Registeransicht gewichtet die über das Fenster beobachteten Identitäten und ist keine Whole-Service-SLA.

Zeiten vor der ersten Beobachtung werden im Backend nicht erfunden. Pausen sind ausgeschlossen, solange ihre Evidenz gültig ist; fehlende/stale Evidenz wird Unknown. Zero-Denominator ist unbekannt/NULL. Bei mehreren Buckets oder Instanzen erst Dauern summieren, dann den Quotienten bilden; niemals Prozentwerte mitteln. Bei Victoria heißt die Kennzahl sinnvollerweise Condition Satisfaction.

Retention-Ziele: Rohdaten 14 Tage, 5-Minuten-Buckets 90 Tage, Stunden-Buckets 13 Kalendermonate. Wartungsrückstand kann diese Zeiträume verlängern. Keine automatische Auflösungsmischung, keine garantierte Dateiverkleinerung nach Löschung. `pending_rollup_hours_global` gilt für die gesamte DuckDB-Datei, nicht nur den Monitor; Null beweist keine Vollständigkeit. `dropped_process_total` zählt Drops seit Prozessstart, nicht dauerhaft oder für das Abfragefenster. `uptime_last_maintenance_ns` ist kein Vollständigkeits-Wasserstand.

Pro API höchstens zwei parallele Reads; Ergebnis maximal 5000 Zeilen/4 MiB, keine Pagination. Abfragen sequenziell durchführen. Bei 422 Zeitraum eingrenzen, Identität auswählen oder gröbere Auflösung mit passenden Grenzen wählen; keine abgeschnittene Erfolgsantwort annehmen. Bei 503 Busy/Unavailable nicht mit parallelen Retries verstärken.

401 bedeutet fehlende/falsche Authentifizierung am angesprochenen Endpunkt. 403 am Gateway bedeutet einen fehlenden/falschen `X-NRC-Workspace`-Header oder verweigerten Workspace-Zugriff. 400 bedeutet ungültige Parameter, einschließlich eines verbotenen `workspace`-Queryparameters; 404 eine unbekannte oder nicht zugelassene Monitor-ID. Gateway-502 kann durch einen Backend-Verbindungsfehler, eine ungültige/nicht passende Antwort oder einen nicht durchgereichten Backend-Status entstehen, etwa Backend-401 bei falschem History-Service-Token. Diese Fehler nicht als Ziel-Down interpretieren.

## Webhook-Zustellung untersuchen

```sh
nrc monitor webhook list 456
nrc monitor webhook list 456 --cursor '<next_route>'
nrc monitor webhook get 456 789
```

`list` verwendet `next_route`, nicht `next_cursor`, und umfasst die gespeicherten Lanes, auch entfernte Route-Versionen und blockierte Lanes. `get` liefert den Zustand des Kopfereignisses einschließlich ID und Generation. Diese Befehle geben JSON aus, auch wenn man sonst `--human` verwendet.

Bei `list` die Routen aus `routes` lesen und mit `--cursor '<next_route>'` fortsetzen, solange `next_route` nicht leer ist. Bei `get` bedeutet `state=0`: kein Kopfereignis, `state=1`: vorhandener, nicht-dead Kopf, gegebenenfalls bereits geleast, und `state=3`: dead. `get` liefert keinen gesonderten Leased-Zustand; für eine noch gültige Lease `lease_until` gegen die aktuelle Zeit prüfen (Unix-Nanosekunden, Uhren synchron halten). `state=2` gehört zu Claim-Antworten, nicht zur CLI-Leseoperation. Nur `state=3` kommt für Discard infrage. `id` und `generation` sind Dezimalstrings und müssen unverändert übernommen werden. `payload` ist ein JSON-String, kein bereits dekodiertes Objekt; einen vorhandenen Payload bei Bedarf separat als Daten dekodieren.

Eine Lane ist die geordnete Zustellungsfolge eines Monitors an eine Route. Ein Dead Head blockiert nachfolgende Zustellungen in dieser Lane. Erst Empfänger, Konfiguration und Ursache prüfen; das Entfernen der Route aus der Monitorliste entfernt keine alten Zustellungen.

Nur wenn der Verlust genau dieser Benachrichtigung akzeptiert wurde:

```sh
nrc monitor webhook discard 456 789 --event 901 --generation 4 --confirm
nrc monitor webhook get 456 789
```

Event und Generation unmittelbar aus `get` übernehmen. Discard akzeptiert nur den Dead Head, löst keinen Incident auf und sendet die verlorene Transition nicht erneut. Es fordert Zustandsresynchronisation an. Bei unklarem Ergebnis Lane erneut lesen; nur dasselbe Event-/Generationspaar kann als Wiederholung infrage kommen, nie blind den inzwischen nächsten Kopf verwerfen. Leasing und ACK bleiben Evaluator-Aufgaben.

Empfängervertrag:

- POST-JSON hat Version 1 und `kind`, Workspace, Monitor, Route und Delivery-ID. `incident_transition` enthält den gespeicherten Snapshot in `event`.
- `webhook_resync` liefert `incident_ids`: den kompletten offenen Satz für Workspace/Monitor/Route ersetzen, auch wenn `[]` geliefert wird. Kein inkrementelles Addieren. Der Sidecar sendet keine absichtlich unvollständigen Resync-Seiten.
- `Idempotency-Key` ist SHA-256 aus Workspace, NUL-Byte und Delivery-ID. Empfänger müssen deduplizieren; Wiederholung nach Crash oder verlorener Bestätigung ist möglich.
- 2xx bestätigt Zustellung; Netzwerkfehler, 408, 429 und 5xx führen zum begrenzten Server-Retry. Andere Statuscodes, einschließlich Redirects, machen den Kopf dead.
- Auth-/Secret-Probleme können die Lane vor dem Claim stoppen. Der Sidecar scannt auch deaktivierte Monitore und alte Routen; Zustellung besitzt ein vom Check-Budget getrenntes Workerbudget.

## Gezielte Fehlersuche

- Neue Regel ohne Instanz: `monitor get` auf `enabled`, `evaluator`, Quellenpin prüfen; feste `-monitors`-Allowlist und letzte vollständige Discovery prüfen. Danach Sidecar-Fehler und Query-Ergebnis ansehen. Ein fehlgeschlagener Run kann ohne Instanzen existieren.
- Nach Quellenänderung keine akzeptierten Runs: aktuelle Quellenrevision gegen `check.source_revision` prüfen. Nur nach beabsichtigter Änderung `monitor update <id> --refresh-source` ausführen.
- Ressourcen werden Missing statt Healthy: Query blendet gesunde Zeilen aus, Labels haben sich geändert oder es gibt tatsächlich keine aktuelle Beobachtung. Keine automatische Zero-/Recovery-Erfindung.
- FIRING trotz gutem Messwert: Recovery-Schwelle und aufeinanderfolgende Erfolge prüfen; ACK/Assign sind keine Entwarnung.
- NRC aktuell, History leer: Berechtigung/Discovery, Zeitfenster, Revision, Akzeptanz, Retention, Rollup-Rückstand und Drops prüfen. NRC-Zustand nicht durch History ersetzen.
- Benachrichtigung fehlt: Lane und Kopfereignis prüfen, dann Sidecar-Zuordnung und Empfänger. Ein gespeicherter Incident beweist keine ausgelieferte Benachrichtigung.

Bei jeder Untersuchung belegte Beobachtung, mögliche Ursache und vorgenommene Änderung getrennt berichten. Keine Produktionsdatenbank öffnen, migrieren oder verändern, nur um CLI- oder History-Zugriff zu reparieren.
