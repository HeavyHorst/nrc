# Quellen und Regeln konfigurieren

Inhalt: Einrichtungsablauf; gemeinsame Policy; HTTP/TCP; Victoria-Quellen und Queries; Änderungen und Revisionen; ausgehende Routen.

## Einrichtung mit überprüfbaren Schritten

1. Workspace, Ziel, Evaluator und gewünschten Alarmumfang klären. Für Victoria die bestehende Quelle wiederverwenden, wenn Endpoint, Tenant und Authentifizierung passen. Quellen über `monitor source list/get` nach ID auflösen.
2. Regel lokal vorbereiten. Identitätslabels müssen genau die Ressourcen unterscheiden, deren Fehler und Recovery unabhängig zählen sollen.
3. Create/Update zunächst mit `--dry-run` prüfen. Das braucht weiterhin eine NRC-Verbindung und gegebenenfalls lesbare Quellen; es ist kein Offline- oder Erreichbarkeitstest.
4. Nach Freigabe denselben Befehl ohne `--dry-run` ausführen. ID aus der Mutation übernehmen und mit `get` nachlesen.
5. Tatsächliche Evaluation über `monitor instances` und Sidecar-Zustand prüfen. Ein erfolgreicher Create belegt weder laufenden Evaluator noch Query-Korrektheit. Keine synthetischen Produktionsalarme zum Testen auslösen.

## Gemeinsame Policy

HTTP-, TCP- und Victoria-Regeln teilen diese Optionen:

- `--interval 1m`, `--timeout 10s`: Standardwerte; positiv, Timeout höchstens Intervall. Go-Dauern wie `30s`, `2m`, `72h` verwenden, nicht `3d`.
- `--failures 5`, `--recoveries 5`, `--missing 3`: positive Anzahlen aufeinanderfolgender Beobachtungen, keine Sekunden.
- `--evaluator nrc-incidents`: muss zum authentifizierten Sidecar-Nickname passen.
- `--enabled=true`: Standard bei Create; deaktivierte Regeln evaluieren nicht.
- `--webhooks 789,790`: höchstens acht unterschiedliche IDs unveränderlicher Webhook-Quellen; ersetzt die Liste vollständig. `--webhooks ''` leert sie.
- `--name 'Neue Bezeichnung'` bei Update; bei Create ist der Name das Positionsargument.

Update ändert nur explizit gesetzte Felder. Die CLI schützt die Mutation mit der gelesenen Revision. Schwellen- oder Konfigurationsänderungen sind nicht neutral für laufende Qualifikation: neue Revisionen setzen Qualifikationsserien zurück. Nach einem Konflikt nicht die komplette alte Definition zurückschreiben.

## HTTP und TCP

```sh
nrc monitor create 'API health' --kind http --url https://api.example.net/health \
  --status 200 --max-latency 2s --certificate-valid-for 72h \
  --interval 1m --failures 5 --recoveries 5 --dry-run
nrc monitor create 'Database port' --kind tcp --address db.internal:5432 --dry-run
```

HTTP ist GET, standardmäßig Status 200, verifiziertes TLS, keine Redirects. `--follow-redirects` und `--insecure-tls` ändern diese Sicherheitsentscheidung ausdrücklich; nicht als automatische Fehlerbehebung setzen. HTTP-URLs dürfen keine eingebetteten Zugangsdaten oder Fragmente enthalten. Der TCP-Check prüft ausschließlich Verbindungsaufbau, weder TLS noch Datenbankprotokoll.

Beide Checks erzeugen eine stabile Identität `{"target":"default"}`, Wert 1 für Pass und 0 für Fail. Netzwerkfehler und Timeouts sind Fehler, nicht fehlende Instanzen. Ein falscher Regelaufbau kann dagegen schon vor der Übermittlung scheitern.

Für mehrere HTTP-Bedingungen eine JSON-Datei anlegen, beispielsweise `conditions.json`:

```json
[
  {"field":"status","op":"==","value":200},
  {"field":"json","path":"/healthy","op":"==","value":true},
  {"field":"latency_ns","op":"<=","value":2000000000}
]
```

```sh
nrc monitor create 'API checks' --kind http --url https://api.example.net/health \
  --conditions-file conditions.json --dry-run
nrc monitor update 456 --conditions-file conditions.json --dry-run
nrc monitor update 456 --max-latency 0 --dry-run
```

Alle Bedingungen müssen bestehen. `--conditions-file` ersetzt die gesamte Liste; deshalb den Statuscheck ausdrücklich aufnehmen, wenn er verlangt ist. Die Datei darf 32 KiB und 1–32 Bedingungen enthalten; `-` liest stdin. Nicht mit `--status`, `--max-latency` oder `--certificate-valid-for` kombinieren. Diese Kurzflags ersetzen nur Bedingungen ihres Feldes und erhalten andere Felder; Dauer 0 entfernt die entsprechende Dauerbedingung.

Felder: `status`, `json`, `latency_ns`, `certificate_remaining_ns`. JSON-Pfade sind JSON Pointer (`/checks/db/healthy`, `~1` für `/`, `~0` für `~`), kein JSONPath. Numerische Werte unterstützen `==`, `!=`, `<`, `<=`, `>`, `>=`; Strings und Booleans nur `==`/`!=`. Fehlendes Feld und falscher Typ scheitern auch bei `!=`. Numerische Bedingungen verwenden Nanosekunden für Dauerfelder und exakte Dezimalvergleiche. Der HTTP-Body ist nach Dekompression auf 1 MiB begrenzt.

Nur unkritische skalare Felder auswählen: deren Werte können als Diagnostik für Workspace-Leser gespeichert werden. Keine Passwörter, Tokens oder personenbezogenen Response-Inhalte in Bedingungen aufnehmen. Ein Check kann private Netzziele erreichen; Regeln und Sidecar-Egress entsprechend begrenzen.

## Victoria-Datenquellen

```sh
nrc monitor source create metrics --kind victoriametrics \
  --url http://metrics.internal:8428 --dry-run
nrc monitor source create logs --kind victorialogs \
  --url http://logs.internal:9428 --retention 7d --dry-run
nrc monitor source create metrics-private --kind victoriametrics \
  --url https://metrics.example.net/select/0/prometheus \
  --secret-ref METRICS_READ --dry-run
```

`--url` ist die Servicebasis, nicht die fertige Query-URL. Der Adapter ergänzt `/api/v1/query` für Metrics bzw. `/select/logsql/stats_query` für Logs. Bei Metrics-Clustern den Tenant-Prefix `/select/<tenant>/prometheus` einschließen. Quellen-URLs erlauben keine Userinfo, Queryparameter oder Fragmente. Tenant-spezifische Logs-Header sind nicht implementiert; bei Bedarf eine passende Proxy-Quelle verwenden.

`--retention 7d` beschreibt die Quelle. Es stellt keine Retention im entfernten System ein, setzt kein Query-Zeitfenster und garantiert keine Datenvollständigkeit.

Auth ist optional, etwa bei Zugriffskontrolle über Tailscale-ACLs. `--secret-ref METRICS_READ` speichert nur den Namen. Der Sidecar liest `NRC_MONITOR_SECRET_METRICS_READ` aus seiner Umgebung und sendet den Wert als Bearer-Token. Erlaubt sind Großbuchstaben, Ziffern und Unterstriche, maximal 64 Zeichen. Ein fehlendes Secret verhindert die Query; kein anonymer Fallback. Token nicht in Assets, URLs, Shell-History oder Skill-Dateien ablegen. Umgebung/Secret-Verwaltung des bestehenden Deployments verwenden.

TLS bleibt verifiziert, außer bei ausdrücklich gesetztem `--insecure-tls`; Redirects werden nicht verfolgt. Secret-Referenzen wirken im Sidecar, nicht im CLI-Prozess. Sources und Monitore müssen im gleichen Workspace liegen.

## Victoria-Regeln und Instanzidentität

Beispielinhalt von `disk.metricsql`:

```text
100 * node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}
```

```sh
nrc monitor create 'Disk free percent' --source 123 --query-file disk.metricsql \
  --identity instance,mountpoint --trigger '<10' --recovery '>15' \
  --interval 1m --timeout 10s --failures 5 --recoveries 5 --dry-run
```

`--source` liest Kind und aktuelle Revision der Quelle und bindet beides an die Regel. Kein `--kind victoriametrics` am Monitor setzen; `--kind` dort ist für HTTP/TCP. `--query` für Inline-Text oder `--query-file` für UTF-8 bis 32 KiB verwenden, nicht beide. `--query-file -` liest stdin.

Für VictoriaLogs einen Logs-Source verwenden und eine passende LogsQL-Stats-Query in `errors.logsql` vorbereiten:

```sh
nrc monitor create 'Errors per host' --source 124 --query-file errors.logsql \
  --identity host --trigger '>5' --recovery '<=1' --dry-run
```

Die Logs-Query muss ihr Zeitfenster selbst enthalten; der Adapter ergänzt keines. Beim Schreiben einer Query die verfügbare LogsQL-Skill bzw. die VictoriaLogs-Dokumentation verwenden. Erst das tatsächliche Ergebnis auf Labels, gesunde Zeilen und Grenzen prüfen. Ein reiner Fehlerfilter mit Gruppierung liefert oft gar keine Zeile für gesunde Hosts; dann entsteht Missing statt Recovery. Nicht einfach einen fehlenden Host als Null ergänzen, wenn keine unabhängige Evidenz seiner Anwesenheit vorliegt.

Für beide Victoria-Arten gilt:

- Die Query liefert Messwerte für gesunde und fehlerhafte Ressourcen. Alarmvergleiche in `--trigger`, nicht als Filter in die Query schreiben.
- Jedes Ergebnis muss alle `--identity`-Labels besitzen. Die sortierte JSON-Kombination dieser Labels identifiziert eine Instanz; weitere Labels und Zeilenreihenfolge nicht. Doppelte Identitäten verwerfen die ganze Evaluation. Genügend Labels auswählen, um beispielsweise mehrere Geräte desselben Hosts zu unterscheiden.
- `--identity` ersetzt die vollständige Liste. Eine Änderung kann neue Instanzen erzeugen; alte werden Missing, nicht automatisch retired. Vorher bestehende Identitäten und beabsichtigte Zuordnung prüfen.
- Trigger unterstützt `<`, `<=`, `>`, `>=`. Die optionale Recovery muss in die entgegengesetzte Richtung zeigen und darf nicht überlappen. Bei `<10`/`>15` sind einschließlich 10 und 15 alle Werte dazwischen `Between`. Ohne Recovery ist jeder nicht triggernde Wert Pass. Vergleiche in Shell-Kommandos immer quoten.
- Die Schwelle entscheidet über eine Beobachtung; erst NRC zählt die Serien zum Öffnen/Schließen eines Incidents. Ein Wert im Recovery-Bereich ist noch kein geschlossener Incident.
- Leerer erfolgreicher Vektor bedeutet fehlende Instanzen, nicht Null oder Recovery. Fehler, Warnungen, Teilantworten, NaN/Inf, fehlende Labels und Grenzverletzungen führen zu einem fehlgeschlagenen Run ohne Teilübernahme.
- Grenzen: 4 MiB Queryantwort, 1024 Zeilen, 4096 Bytes je Identität und zusätzlich der 128-KiB-Protokollframe. Timestamp muss zum angefragten Evaluationszeitpunkt passen; das beweist nicht die Frische der zugrunde liegenden Scrapes.
- `allow_partial_response` ist in Logs-Queries nicht erlaubt. Vollständigkeit nicht zugunsten vermeintlich brauchbarer Teilergebnisse abschalten.

Dezimalvergleiche sind exakt (höchstens 128 Zeichen, Exponent −308 bis 308); gespeicherte Messwerte und Browserzahlen sind Float64. Aus gerundeten UI-Werten keine Grenzfallentscheidung rekonstruieren. Nicht darstellbare Schwellen werden in der UI nicht auf die Skala projiziert.

## Quelle oder Regel ändern

```sh
nrc monitor update 456 --interval 30s --dry-run
nrc monitor update 456 --recovery '' --dry-run
nrc monitor source update 123 --url http://replacement.internal:8428 --dry-run
```

Vor einer echten Quellenänderung alle Monitor-Konfigurationsseiten mit `nrc monitor list` und `--cursor` vollständig lesen. Für jede zurückgegebene Monitor-ID `nrc monitor get <id>` abrufen und dort `check.source_id` mit der Quellen-ID vergleichen. `monitor list` enthält nur Preview-Konfiguration, keinen `check`-Payload; ein fehlendes `check` in der Liste beweist deshalb keine fehlende Abhängigkeit. Bei unvollständiger Inventur oder fehlgeschlagenem Detailabruf die Prüfung nicht als abgeschlossen behandeln und die Quellenänderung zurückstellen. Diese vollständige Prüfung ist vor einer gemeinsamen Quellenmutation erforderlich, auch wenn zur normalen Triage begrenzte Listen genügen.

Es gibt keinen automatischen abhängigen Refresh. Jede Quellenänderung erzeugt eine neue Revision; alte Pins werden einschließlich laufender Runs abgewiesen. Auch eine Änderung beschreibender Quellenfelder ist nicht revisionsneutral.

Nach der autorisierten Quellenänderung jeden betroffenen Monitor ausdrücklich umstellen:

```sh
nrc monitor source get 123
nrc monitor update 456 --refresh-source --dry-run
nrc monitor update 456 --refresh-source
nrc monitor get 456
nrc monitor instances 456
```

Ein unabhängiges Monitorupdate übernimmt die neue Quellenrevision nicht stillschweigend. `--source <andere-id>` bindet eine andere Quelle. Wechsel zwischen HTTP, TCP und Victoria erfordern über diese CLI einen neuen Monitor. Bei einem bestehenden Victoria-Monitor übernehmen `--source` und `--refresh-source` hingegen auch den Kind der geladenen Quelle: Ein Wechsel zwischen Metrics und Logs ist möglich, erfordert aber eine ausdrückliche Prüfung von Query und Identitätssemantik. `--secret-ref ''`, `--retention ''`, `--recovery ''` und `--webhooks ''` löschen das jeweilige optionale Feld. Kein automatisches Failover, kein automatisches Umschreiben von Referenzen.

## Ausgehende Webhook-Routen konfigurieren

```sh
nrc monitor source create ops-v1 --kind webhook \
  --url https://receiver.example.net/nrc --secret-ref OPS --dry-run
nrc monitor update 456 --webhooks 789 --dry-run
```

Erst die neue Route wirklich anlegen und ihre zurückgegebene ID nachlesen, dann diese an Monitore binden. Eine Route ist eine unveränderliche `MonitorSource`-Version. Weder Update noch Delete sind zulässig, auch nicht über generische Assets oder Transaktionen. Für URL-/Auth-/TLS-Änderungen eine neue Route erstellen. Bereits eingereihte Ereignisse behalten die alte Route; ein Listenwechsel zieht sie nicht um.

`NRC_MONITOR_SECRET_OPS` liefert optional den Bearer-Token. Ziele müssen NRCs JSON- und Resync-Vertrag unterstützen; dies ist kein Slack-/Teams-Adapter. Vor dem Aktivieren tatsächliche Empfänger, Datenumfang und Zustellungsfreigabe klären. Lieferzustand und Dead-Head-Behandlung stehen in der Betriebsreferenz.
