#

MySQL binlog
   ↓
Debezium connector
   ↓
Structured CDC event (Kafka Connect record)
   ↓
Outbox Event Router SMT
   ↓
Domain event (Kafka record)

### Relationship between binlog and CDC events

binlog entry → interpreted → normalized → enriched → serialized
