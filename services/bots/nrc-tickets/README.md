# NRC Tickets

Separately deployable German customer portal, backed exclusively by NRC Ticket
and TicketEntry assets. Ticket-scoped attachments use NRC's private blob service;
there is no local ticket database, public registration, generic asset/file proxy,
or dependency on the staff web client. Branding uses operator CSS/logo/footer
configuration in the same style as Publish.

See [deployment, provisioning, security and test instructions](../../../docs/TICKETS.md).

```sh
go test -race ./...
go build -o /tmp/nrc-tickets .
```
