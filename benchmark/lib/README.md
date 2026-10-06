# JDBC drivers go here (they are gitignored; run `./build.sh` to fetch them).

| backend | driver | notes |
|---|---|---|
| `--backend pg` | `org.postgresql:postgresql:42.7.4` | vanilla PostgreSQL |
| `--backend og` | `org.opengauss:opengauss-jdbc:5.0.0` | preferred for openGauss |

## If the openGauss driver cannot be downloaded

openGauss speaks the PostgreSQL wire protocol, so the stock PostgreSQL driver
usually works -- but only if the server hashes passwords with **md5** rather
than its default `sha256`, which `libpq`/pgjdbc does not implement.
`sql/guc/og_guc.sql` therefore sets:

```sql
ALTER SYSTEM SET password_encryption_type = 0;   -- md5
```

After a restart, reset the password so it is re-hashed with the new algorithm:

```sql
ALTER USER gaussdb IDENTIFIED BY 'Bench@123' REPLACE 'Bench@123';
```

Then run the openGauss backend with the PostgreSQL driver and a `postgresql://`
URL:

```bash
./run.sh --backend og --jdbc jdbc:postgresql://127.0.0.1:5433/bench ...
```

Record in the report which driver was used: it is part of the measurement
apparatus, and the two engines are then not being driven by an identical client
stack.
