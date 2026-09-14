# Securing Valkey with ACL users and least privilege

Valkey in `deploy/kubernetes/` runs with no password, no ACL, no TLS, and no NetworkPolicy. The pod
spec is already hardened the way the Postgres StatefulSet is: non-root, read-only root filesystem,
every capability dropped, `RuntimeDefault` seccomp. What is left is the part a pod spec cannot
express, which is who may connect and what they may run.

This plan adds an ACL file with three users, turns off RDB snapshotting, and caps both client count
and client memory. It does not add TLS. It does not add a NetworkPolicy.

Most of it has shipped. "What shipped" records what landed, what landed in a different shape, and
what did not land at all. Read that section before the design sections below, because the ACL that
shipped has two users rather than the three described here.

An adversarial review rewrote most of this document. `VALKEY_SECURITY_FINDINGS.md` records what the
reviewers found, what I verified, and what I rejected. Read it for the reasoning behind the choices
below.

## Protected mode is already off, and not because of anything we set

One fact gates this whole plan, and the source code gets it wrong.

The accept-time check in `src/networking.c:1827` is two terms:

```c
if (server.protected_mode && DefaultUser->flags & USER_FLAG_NOPASS) {
    if (connIsLocal(conn) != 1) {
```

The default user is `nopass` today, because `valkey.yml` passes arguments with no `requirepass` and
no `aclfile`. The compiled-from-source default for `protected-mode` is `1` (`src/config.c:3272`), and
the image entrypoint adds nothing but `$VALKEY_EXTRA_FLAGS`. Read together, those say Valkey should
already be refusing every connection that does not come from loopback.

It does not. Measured against the pinned image, started with the exact arguments `valkey.yml` passes
today, with a second container on the same Docker network standing in for another pod:

```
$ valkey-cli -h vk1 PING
PONG
$ valkey-cli -h vk1 CONFIG GET maxmemory
maxmemory
134217728
$ docker exec vk1 valkey-cli CONFIG GET protected-mode
protected-mode
no
```

The image is why. `valkey-container`'s Dockerfile rewrites the default out of the source before it
compiles, under the comment `disable Valkey protected mode [1] as it is unnecessary in context of
Docker`:

```
sed -ri 's!^( *createBoolConfig[(]"protected-mode",.*, *)1( *,.*[)],)$!\10\2!' ./src/config.c
```

The startup banner agrees: `Valkey version=9.1.2, bits=64, commit=00000000, modified=1`.

Two things follow. The threat model in the next section holds exactly as written, because there is no
accept-time control in front of it. And `--protected-mode no` in the args is not a concession; it is
already the running state. Writing it down stops the deployment from depending on a `sed` in somebody
else's Dockerfile.

## What any pod in the namespace can read today

The worst of it is not an administrative command. It is a plain `GET`.

`ValkeyCache` holds four caches, and three of them back authentication:

| Namespace | Built at | Holds |
| --- | --- | --- |
| `media:get-url` | `src/core.py:592` | Presigned S3 GET URLs |
| `ory:whoami:` | `src/utils/ory.py:129` | Kratos session lookups |
| `ory:identity` | `src/utils/ory.py:135` | Kratos identities |
| `ory:check` | `src/utils/ory.py:141` | Keto permission decisions |

A presigned URL is a bearer credential with a clock on it. `KEYS 'media:get-url:*'` followed by
`MGET` returns working links to private media. The reader never touches Kanae, Kratos, or Keto, and
nothing lands in an application log.

Writing is the other direction, and it is narrower than it first looks. The key is not
`media:get-url:<hash>`. aiocache builds it from the module name, the function name, and the `repr` of
the arguments, so the real key is closer to
`media:get-url:coreget_url('<hash>', '<content_type>')[]`. The value is `orjson`, so a bare URL is
not a valid entry. Poisoning the cache needs the BLAKE3 hash, the exact content type, and correct
JSON framing. Reaching the key space at all is still the problem.

The rest is the usual list:

- `FLUSHALL` drops every rate-limit counter and all four caches.
- `CONFIG SET maxmemory-policy noeviction`, plus writes until 128mb, turns every later `SET` into an
  error. The limiter falls back to `MemoryStorage`. `StorageClient` has no fallback.
- `CONFIG SET dir` and `CONFIG SET dbfilename` is the Redis file-write primitive. RDB snapshotting is
  on today, so there is a real `bgsave` to aim.
- `REPLICAOF` points the instance at an attacker's primary and replaces the dataset.
- `MONITOR` streams every command from every client.

None of this needs a credential, so rotating one stops none of it.

`DEBUG` and `MODULE LOAD` are already unavailable. `enable-debug-command`, `enable-module-command`,
and `enable-protected-configs` all default to `no`, and nothing in the chart turns them on.

## The scanners cannot see any of this

I ran the repository's own scanner against the two rendered Valkey manifests:

```
kubescape scan framework all /tmp/vk --controls-config .kubescape/controls.json --severity-threshold low
```

Seven controls fail: CPU limits (C-0009, C-0050, C-0270), image signing (C-0236, C-0237), and network
posture (C-0030, C-0260). `.kubescape/exceptions.json` already disables all seven by name, so
`mise run k8s:scan` passes. kube-linter passes too.

None of those controls asks whether the database inside the container wants a password. Kubescape
reads the pod spec. The exposure is in the server config. So the tooling in this repository cannot
catch this and will not start catching it, which argues for writing the decision down rather than for
adding a fourth scanner.

## Use an ACL file, not `requirepass`

`requirepass` sets a password on the `default` user and leaves that user holding `+@all`. A leaked
password is then a leaked administrator, which is the thing this plan exists to prevent. `aclfile` is
the only option that lets you name users and scope them.

The two cannot be combined. Valkey rejects a configuration that defines `user` directives inline and
also points at an external `aclfile`.

The file goes through the Secret machinery Postgres already uses. Render `users.acl` into a
`valkey-acl` Secret, mount the `/etc/valkey` **directory** with `items`, and set
`defaultMode: 0440`. Mounting at the file path `/etc/valkey/users.acl` would create a directory
instead of a file, and Valkey would abort at startup. `postgres.yml:206-210` shows the shape to copy:
it mounts `/run/secrets` and lets the Secret key become the filename inside it.

The container runs as uid 999 and gid 1000, and the pod already sets `fsGroup: 1000`, so group-read
is enough. I confirmed the identifiers against the image, which does
`addgroup -S -g 1000 valkey` and `adduser -S -G valkey -u 999 valkey`.

Store the password as a sha256 hash, using Helm's `sha256sum`, so `users.acl` holds `#<hex>` and
never the plaintext. The plaintext then appears in one rendered place, the `storage_uri` inside
`kanae-config`.

## Three users, and what each one may run

Write each `user` directive on one physical line. The ACL loader splits on newline and tokenises each
line, so a trailing backslash becomes an argument, the load fails, and the pod crash-loops. Build the
line in the template with `join " "` over a list if you want the source to stay readable.

```
user default on nopass -@all +ping
user kanae on #<sha256 of valkeyPassword> ~LIMITS:* ~media:get-url:* ~ory:* -@all +ping +client|setinfo +info +get +set +del +ttl +incrby +expire +evalsha +script|load
user admin on #<sha256 of valkeyAdminPassword> ~* &* +@all
```

`default` stays reachable and can do one thing. That keeps the liveness and readiness probes exactly
as they are, `["valkey-cli", "PING"]`, with no credential plumbed into a probe.

I checked that rather than assuming it. `valkey-cli` sends no `CLIENT SETINFO` handshake, and the
string appears nowhere in `src/valkey-cli.c`. It sends `COMMAND DOCS` only under
`if ((!config.eval_ldb) && isatty(fileno(stdin)))` at line 3313, and a kubelet exec probe has no tty.
So `valkey-cli PING` puts one command on the wire and `+ping` is the whole requirement.

`admin` exists because the first draft had no way to diagnose itself. Without it, nobody can run
`ACL LOG`, `INFO`, `CONFIG GET`, `CLIENT LIST`, or `ACL LOAD`, from anywhere, including
`kubectl exec`. That matters most in exactly the situation where the grant list turns out to be
incomplete. Generate `valkeyAdminPassword` in `init.sh`, store it in sops, and mount it into nothing.
It costs one line and one secret. The Postgres plan reached the same conclusion in its
"How to actually administer this" section.

### Pass `--protected-mode no` even though the image already sets it

The image compiles the default to `0`, so the flag changes nothing today. Pass it anyway, and put the
reason next to it.

The reason is not that protected mode would otherwise bite. It is that the setting we depend on lives
in an upstream `sed` we do not control, and the default user stays `nopass` under this plan so that
the probe can `PING` without a credential. If a future image drops the patch, the accept-time check
fires, reads only the default user, and rejects the kanae pod before it can send `AUTH kanae`. The
flag makes that a non-event instead of a rollout that fails in a way nobody predicted.

`--protected-mode no` still reads badly in a diff. Protected mode exists to stop an instance that
answers every command to everybody. Once `default` holds `-@all +ping`, that instance no longer
exists, and the flag is guarding nothing.

The alternative is `user default off resetpass`, which clears the `nopass` flag and would let
`protected-mode yes` mean something. It costs a probe that authenticates as a fourth user with a
password read out of the mounted file by a shell wrapper. That is three moving parts to restore a
directive whose job `-@all +ping` already does.

### Derive the grant list from what opens a connection

The first draft read `storage.py` and `cache.py` and called the result a trace. It missed three
caches, one command, and the client library's entire handshake. The method has to start from
connections, not from files.

Four things talk to Valkey:

1. **The Glide client's connect sequence.** It has no Python call site, so no amount of reading
   `storage.py` reveals it. Read off `MONITOR` while a real `GlideClient` connects, it is four
   commands:

   ```
   "HELLO" "3" "AUTH" "(redacted)" "(redacted)"
   "CLIENT" "SETINFO" "LIB-NAME" "GlidePy"
   "CLIENT" "SETINFO" "LIB-VER" "0.1.0"
   "INFO" "REPLICATION"
   ```

   `HELLO` is a no-auth command and needs no grant. `+info` is mandatory: withhold it and
   `GlideClient.create` raises `ClosingError`, so the kanae pod never finishes starting.
   `+client|setinfo` is not mandatory, because glide ignores the denial, but withholding it writes
   two `ACL LOG` entries per connection and blanks `lib-name` in `CLIENT LIST`. Grant both.
2. **The rate limiter.** `KanaeLimiter` hard-codes `FixedWindowRateLimiter`
   (`src/utils/limiter/extension.py:304`), which calls only `storage.incr`, `storage.get`, and
   `storage.get_expiry`. Those map to `EVALSHA` of `incr_expire.lua` (which runs `INCRBY` and
   `EXPIRE`), `GET`, and `TTL`.
3. **The four caches.** `cached_method` reaches `GET`, `SET`, and `DEL`.
4. **The probes.** `PING`, on `default`.

`EVALSHA` alone does not cover the limiter. On `MONITOR`, the first `invoke_script` after a server
restart is three commands, because glide caches the digest client-side and only learns the server
does not have it from the reply:

```
"EVALSHA" "628bd136..." "1" "LIMITS:test" "60" "1"     -> NOSCRIPT
"SCRIPT" "LOAD" "local current\nlocal amount = ..."
"EVALSHA" "628bd136..." "1" "LIMITS:test" "60" "1"     -> 1
```

Subsequent calls are a bare `EVALSHA`. Withhold `+script|load` and every `invoke_script` fails with
`NOPERM ... 'script|load'`, so the grant is load-bearing on exactly one request in the lifetime of
each server process, which is the worst kind to leave out. The Lua body runs under the caller's ACL,
and `MONITOR` shows its inner calls as `[0 lua] "incrby"` and `[0 lua] "expire"`. That is where
`+incrby` and `+expire` are spent; `expire` only fires on the call that creates the key.

That is eleven verbs. The first draft granted twenty-three. `lindex`, `lpush`, `ltrim`, `pttl`, and
`rename` were there for `moving_window.lua` and the two sliding-window scripts, which
`FixedWindowRateLimiter` never invokes. `mget`, `mset`, `multi`, `exec`, `discard`, `persist`,
`exists`, and `eval` had no reachable caller either.

Two consequences follow. If you later switch the limiter to a moving-window strategy, the ACL is the
thing that breaks, so the strategy choice now has an ACL consequence and belongs in a comment. And
`+pexpire` is deliberately absent: `ValkeyCache.__multi_set_ttl` uses it for float TTLs
(`src/utils/cache.py:406`), and nothing calls `multi_set`. Adding the grant without the caller is how
the first draft got to twenty-three.

### `SCAN` is the one thing an ACL cannot scope, and Ory needs it

`OryClient._invalidate_resource` (`src/utils/ory.py:171-173`) calls
`_check_cache.clear(namespace=prefix)`, which takes the `scan` branch of `ValkeyCache._clear`
(`src/utils/cache.py:452-459`). `grant` (`:571`) and `revoke` (`:650`) both call it, and five
route handlers reach those: `routes/members.py:473` and `:475`, `routes/projects.py:626` and `:629`,
and `routes/events.py:357` and `:360`. Those are request paths.

`SCAN` takes a cursor and a pattern, not a key, so ACL key patterns do not constrain it. Granting
`+scan` hands back full key-space enumeration and undoes `~LIMITS:*`, `~media:get-url:*`, and
`~ory:*` in one token. Withholding it turns every permission grant and revoke into a `NOPERM`, and
neither call site wraps the exception.

Pick one before this ships:

1. **Grant `+scan`.** One token, works today, and concedes that a compromised kanae credential can
   list every key. The key patterns still stop it from reading or writing outside its three
   namespaces, which is most of the value.
2. **Stop invalidating by scan.** Give `_check_cache` a key that encodes a version, bump the version
   instead of deleting a namespace, and let the old entries expire. This is application work, and it
   is the only option that keeps the key scoping honest.

Take option 1 now and option 2 as a follow-up. Option 2 is correct and it is not a Kubernetes change.

### `_clear` only scans once, so option 2 is not the only thing owed here

Noted, not fixed. `ValkeyCache._clear` (`src/utils/cache.py:459-467`) passes a literal `b"0"` cursor
and throws the returned cursor away:

```python
_, keys = await self.client.scan(b"0", f"{namespace}:*")
```

`SCAN` is a cursor iterator. One call returns whatever it examined in that slice, and `COUNT` bounds
keys examined rather than keys returned, so `MATCH` filters what is left. Stopping after the first
call clears a fraction of the namespace and reports `True`. Measured against the pinned image with
500 namespaced keys and 500 keys of noise: the one-shot call returned cursor `b'64'` and matched 8 of
500, and a full cursor loop matched 500 of 500.

This is inherited, not original. `aiocache/backends/valkey.py:147-155` upstream is the same logic,
same hardcoded `b"0"`, same discarded cursor. The local copy differs only in the `== "OK"` comparison
on `flushdb`, the `isinstance` narrowing, and the `list(keys)` cast. Nothing in the aiocache issue
tracker reports the single-scan defect, though #472 and #479 cover other faults in the same method.

The blast radius is local even if the bug is not. `OryClient._invalidate_resource` is kanae's code,
and it depends on `_clear` actually clearing, so a revoked permission keeps being served from cache
until the entry expires on its own. The fix is a `while` loop that carries the cursor until it comes
back `b"0"`. It wants its own commit and its own test, and it does not belong in the ACL change.

Option 2 above deletes this method's only caller, which would retire the bug instead of fixing it.
Whichever lands first, do not let the other be forgotten.

### The grant list is tied to the fixed-window strategy

`extension.py:299` constructs a `FixedWindowRateLimiter` and nothing else. `storage.py:28-37` still
loads six Lua scripts, so the file reads as though moving and sliding windows are live. They are not.
Only `incr_expire.lua` and `clear_keys.lua` ever reach the server.

That matters because Lua does not get a free pass. Every `redis.call` inside a script is checked
against the ACL of the user that ran the `EVALSHA`. Loading a script that calls `keys` and running it
as `kanae` gives:

    ERR ACL failure in script: User kanae has no permissions to run the 'keys' command

So the grant list has to cover what the scripts call, not just what Python calls. Today that is
`incrby` and `expire`, from `incr_expire.lua`, and both are granted.

If anyone swaps the strategy, the ACL needs more verbs and the failure will be quiet: the script
error surfaces as a `GlideError`, the limiter swallows it, and every request silently falls through
to `MemoryStorage`. Check this list before changing `extension.py:299`.

- `moving_window.lua` needs `lindex`.
- `acquire_moving_window.lua` needs `lindex`, `lpush`, `ltrim`, `expire`.
- `sliding_window.lua` needs `get`, `pttl`, `rename`, `set`.
- `acquire_sliding_window.lua` needs `pttl`, `rename`, `set`, `get`, `exists`, `incrby`.

None of `lindex`, `lpush`, `ltrim`, `pttl`, `rename`, or `exists` is granted, and none should be
until something uses them.

`clear_keys.lua` is the one exception worth stating explicitly. It calls `keys`, which is not
granted and should not be. `reset()` at `storage.py:276` is the only caller, it is reached only
through `LimiterExtension._reset` at `extension.py:371`, and the only callers of that are
`tests/conftest.py:420` and `:473`. Nothing in `src/` resets the limiter. Granting `+keys` to make a
test-only path work would hand the application user an O(N) blocking command for no gain, and the
tests run against a container with no ACL anyway.

### The rate-limit keys had no prefix, and the fix is two lines of code

`ValkeyStorage._prefixed_key` was `f"{self.key_prefix}:{key}"`, and `key_prefix` comes from
`config.dist.yml`, where it is `""`. Every rate-limit key was therefore `:LIMITER/...`, and
`~LIMITS:*` matched none of them.

Setting `key_prefix: LIMITS` in the config is the obvious fix and it is the wrong one. That single
value feeds two layers. It is the storage prefix, and at `extension.py:434-435` it is also spliced
into the logical key as an extra identifier. Set it and every key becomes
`LIMITS:LIMITER/LIMITS/mock/...`, with the prefix in there twice, which breaks `test_key_style`
(`tests/test_limiter.py:353`) because those assertions carry no prefix at all.

The insertion line is inherited from slowapi (`slowapi/extension.py:513-514`), where it is harmless:
slowapi never hands `key_prefix` to its storage. Kanae does, at `extension.py:305`, so the value
lands twice. `scripts/repro-limiter-key-prefix.py` drives the real middleware and `_evaluate_limits`
through the `test_key_style` scenario and prints both key spaces.

So `config.dist.yml` keeps `key_prefix: ""` and two lines of code change instead:

- `storage.py:82-85` returns the bare key when the prefix is empty, rather than `:key`.
- `extension.py:300-307` hands the storage `key_prefix or ValkeyStorage.PREFIX`, so the storage is
  never prefixless.

The second one is not cosmetic. `reset()` feeds `_prefixed_key("*")` to `clear_keys.lua`, which is
`KEYS <glob>` followed by `DEL`. An empty prefix turns that glob into `*`, and `KanaeLimiter._reset()`
runs from the `client` fixture teardown at `tests/conftest.py:418`. Without the fallback, every test
teardown would delete every key in the database, Ory caches included. With it the glob stays
`LIMITS:*`.

Net effect: keys stay `LIMITS:LIMITER/...`, `~LIMITS:*` matches, `test_key_style` passes untouched,
and no config file changes. `scripts/check-limiter-keys.py` checks each of those.

## Hardening that is not about authentication

### Turn off RDB snapshotting

The container runs `valkey-server` with arguments and no config file, so the compiled-in save points
apply: 3600 seconds with one change, 300 with a hundred, 60 with ten thousand. Valkey is snapshotting
a pure cache to an `emptyDir`. Pass `--save ''` and three things follow:

- No on-disk copy of the dataset, so `kubectl cp` out of `/data` stops being a path to it.
- No `bgsave` fork. The fork briefly doubles the resident set against a 256Mi limit with
  `maxmemory 128mb`, which surfaces as an unexplained OOMKill.
- No write stall. `valkey.conf` puts it plainly: "the server will stop accepting writes if RDB
  snapshots are enabled and the latest background save failed." `/data` is an `emptyDir` under a
  512Mi ephemeral-storage limit, so a failed save is reachable, and a Valkey that refuses writes
  takes the media cache down with it.

Keep the `emptyDir` mount. `/data` is the image's WORKDIR and the root filesystem is read-only.

### Cap the client count and the client memory

Two defaults are unbounded, and they fail in different ways.

`client-output-buffer-limit normal 0 0 0` is the shipped default. CVE-2025-21605 was exactly this:
unauthenticated clients growing output buffers until the server died. The advisory's stated
workaround is that directive. The code fix is in our build, but the knob bounds the next one. Set
`--maxmemory-clients 32mb`. Against `maxmemory 128mb` inside a 256Mi container limit, that is the
difference between client eviction and an OOMKill.

`maxclients` defaults to 10000. `maxmemory-clients` caps the memory clients hold and evicts the
largest ones. It does not cap how many connections exist. An attacker who can reach the port opens
connections instead of filling buffers, and none of that needs `AUTH`. Set `--maxclients` to the
worker count with headroom. Two granian workers plus probes need single digits.

Both are one argv element. The second was missing from the first draft, which is odd, because it was
already reasoning about the same pre-authentication attacker.

## The ACL file has to survive a password change

Valkey reads `aclfile` once at startup, and after this change no user except `admin` can run
`ACL LOAD`. Nothing in the first draft rolled the pod when the Secret changed.

The failure is concrete. Rotate `valkeyPassword` and re-apply. kapp updates both Secrets in place.
The kanae pods pick up the new plaintext from `kanae-config`. The Valkey pod keeps the old hash in
memory, because its Deployment spec did not change. Every connection then fails `WRONGPASS`, and
that failure is silent for the reasons in the verification section below.

Annotate the pod template with a checksum of the rendered ACL file, so a password change rolls the
pod. The chart already does this at `jobs-migrate.yml:69`, `:165`, and `:259`. Hash the rendered
file, not the raw password, because the raw password's sha256 is the credential `users.acl` holds and
it does not belong in a pod annotation.

## What changes where

- `deploy/kubernetes/src/templates/valkey.yml`: `--aclfile`, `--protected-mode no`, `--save ''`,
  `--maxmemory-clients 32mb`, `--maxclients`, the `acl` volume and its directory mount, and the
  `checksum/acl` annotation
- `deploy/kubernetes/src/templates/secrets.yml`: the `valkey-acl` Secret holding `users.acl`, and the
  `storage_uri` override on `$config.kanae.limiter`
- `deploy/kubernetes/src/templates/_helpers.tpl`: `kanae.valkeyUri` and `kanae.valkeyAcl`, alongside
  `kanae.postgresUri`
- `deploy/kubernetes/src/values.yaml` and `values.schema.json`: `secrets.valkeyPassword` and
  `secrets.valkeyAdminPassword`
- `deploy/kubernetes/secrets.dist.yml`: both keys, set to `REPLACE`
- `deploy/kubernetes/init.sh`: `generate valkeyPassword 32` and `generate valkeyAdminPassword 32`
- `deploy/kubernetes/scripts/check-policy.sh`: add `valkey:6379` to the hardcoded-address rule, which
  today catches `database:5432` and `kanae:8000` only
- `src/utils/limiter/storage.py`: `_prefixed_key` drops the separator when the prefix is empty
- `src/utils/limiter/extension.py`: the storage gets `key_prefix or ValkeyStorage.PREFIX`
- `deploy/kubernetes/docs/DECISIONS.md`: a new entry for the ACL, and an edit to "Valkey's
  `maxmemory` is half its memory limit", which says client buffers do not count against `maxmemory`.
  `--maxmemory-clients` qualifies that sentence
- Run `mise run k8s:render`, then commit `deploy/kubernetes/dist/`

`check-policy.sh` rejects a service address typed into a template, so `kanae.valkeyUri` reads
`.Values.serviceNames.valkey`, the way `kanae.postgresUri` reads `.Values.serviceNames.database`.

The URI is `valkey://kanae:<password>@<service>:6379/`. I checked that it parses the way
`GlideManager` needs, against the installed `limits`:

```
'valkey://kanae:s3cr3t@valkey:6379/' -> user='kanae' pass='s3cr3t' loc=[('valkey', 6379)] path='/'
```

`GlideManager.__init__` turns that into `ServerCredentials(username='kanae', password='s3cr3t')`.
`path='/'` strips to `''`, which is not a digit, so `database_id` stays `None`. No application code
changes.

## How to verify it

Read `ACL LOG`, not HTTP status codes. Both consumers are built to hide storage errors, so a missing
grant produces a 200:

- `KanaeLimiter._check_request_limit` catches bare `Exception`
  (`src/utils/limiter/extension.py:555`), marks storage dead, and re-runs against `MemoryStorage`.
- `get_from_cache` and `set_in_cache` catch `GlideError` (`src/utils/cache.py:212-227`), and `NOPERM`
  is a `GlideError`.

The recovery probe cannot see it either. `ValkeyStorage.check()` is `client.ping()`
(`src/utils/limiter/storage.py:268-279`), and `PING` is the one command every user holds. The limiter
marks storage dead, pings successfully, marks it recovered, fails the next real command, and
oscillates without raising anything. The probe stays as it is, because upstream `limits` probes the
same way (`limits/storage/redis.py:295-302`) and a probe issuing a real command would need a key it
is allowed to write.

`ACL LOG` records every denial, including denials inside Lua and inside the client's connect
sequence, and it records the ones the client swallows as well as the ones it raises. That is what
makes it the right assertion here. Assert that it is empty.

```
kubectl -n kanae exec deploy/valkey -- valkey-cli PING                                   # PONG
kubectl -n kanae exec deploy/valkey -- valkey-cli FLUSHALL                                # NOPERM
kubectl -n kanae exec deploy/valkey -- valkey-cli --user kanae -a "$PW" ACL WHOAMI        # kanae
kubectl -n kanae exec deploy/valkey -- valkey-cli --user kanae -a "$PW" GET other:key     # NOPERM
kubectl -n kanae exec deploy/valkey -- valkey-cli --user admin -a "$ADMIN" ACL LOG        # empty
kubectl -n kanae exec deploy/valkey -- valkey-cli --user admin -a "$ADMIN" CONFIG GET save # ""
```

Then run the integration suite against a Valkey started with this ACL file and check `ACL LOG` again.
Note that `tests/integration/init.sh:81` sets `.kanae.limiter.enabled = false`, so the suite as it
stands never exercises the limiter. Flip it to `true` for this run, or the `EVALSHA`, `INCRBY`, and
`TTL` grants go untested.

## What this breaks

`OryClient.grant` and `OryClient.revoke` break unless you take one of the two `SCAN` options above.
Neither call site catches the exception, so both become 500s.

`KanaeLimiter.reset()` and `ValkeyCache.clear()` start raising `NOPERM`. Neither has a caller. If one
grows a caller, the fix is a decision about that caller, not a `+keys` or a `+flushdb` on the
application user.

`ValkeyCache.multi_set` with a float TTL raises `NOPERM` inside `EXEC`. Nothing calls it.

The probes are unchanged, the Service is unchanged, and the application reads its URI from config it
already reads.

## What shipped

Commit `36d5176` carries the Kubernetes work. The Docker Compose work sits uncommitted on
`secure-valkey` across nine files. Three parts of the design landed in a different shape, the ACL
grew a second consumer the plan never mentioned, and five items are missing.

### The ACL has two users, not three

`docker/valkey/users.acl` is two lines:

```
user default on nopass -@all +ping +info +acl|log +acl|whoami
user kanae on resetpass ~RATELIMIT:* ~media:get-url:* ~ory:* -@all +ping +client|setinfo +info +get +set +del +ttl +incrby +expire +evalsha +script|load +scan
```

The `admin` user is gone. Its only job was reading `ACL LOG` and `CONFIG GET`, and every assertion
in the verification section above is an `ACL LOG` read. `default` holds `+acl|log` and `+acl|whoami`
instead, so the audit trail stays readable and there is no second credential to generate, store, and
rotate. `default` still cannot run `CONFIG GET`, so the `CONFIG GET save` line in the command list
above does not work as written.

The key prefix landed as `RATELIMIT`, not `LIMITS`. `ValkeyStorage.PREFIX`
(`src/utils/limiter/storage.py:25`) is a fixed class constant and `_prefixed_key` (`:79`) always
prepends it. That drops the empty-prefix branch the plan proposed, because no caller ever passes an
empty prefix. Commit `1e40ace` carries the change.

`+scan` is granted, which is option 1 from the `SCAN` section above. Option 2 is still owed, and so
is the `_clear` cursor loop.

### The password goes in as plaintext, not a hash

`secrets.yml:117` swaps a token instead of hashing one:

```gotemplate
users.acl: |
  {{- include "kanae.file" (list . "valkey/users.acl") | replace "resetpass" (printf ">%s" $secrets.valkeyPassword) | nindent 4 }}
```

The committed file holds the literal word `resetpass` where the password goes. A checkout therefore
carries no credential, and the file still parses as valid ACL syntax on its own. Helm's `replace`
puts `>` and the plaintext password in its place at render time.

A sha256 hash would keep the plaintext out of the rendered Secret. It buys little here, because the
same plaintext already sits in `kanae-config` inside the connection URI and both Secrets have the
same reader set. The plaintext form is also what lets one file serve both the chart and Compose,
because `sed` cannot compute a hash.

Rename the token on either side and the substitution stops matching in silence. `resetpass` is a real
ACL directive, so a file that keeps it still loads, the pod still boots, and the `PING` probe still
answers, while `kanae` ships with no password. `check-policy.sh:31-33` rejects that:

```bash
grep -Fq resetpass "$ACL" || reject "..."
grep -Fq resetpass "$TEMPLATES/secrets.yml" || reject "..."
grep -Fq resetpass "$INIT" || reject "..."
```

`scripts/powershell/check-policy.ps1:28-30` checks the same three files. It passes `-CaseSensitive`,
because `Select-String` matches case-insensitively by default while `grep -F` and sprig `replace` do
not. Without that flag, a file holding `RESETPASS` passes on Windows and fails on Linux.

Three plain `grep -Fq` statements do the work rather than the `grep -L ... | grep .` idiom used higher
up in the same script. `grep -L` exits 1 when no file matched the pattern, even while it prints
filenames, so under `set -o pipefail` the case where every file lost the token passes. The existing
`find ... | grep .` lines are safe only because `find` always exits 0.

### One ACL file feeds both stacks

`deploy/kubernetes/files.map:9` maps `valkey/users.acl` to `docker/valkey/users.acl`, and
`deploy/kubernetes/src/files/valkey/users.acl` is the symlink. The chart reads it through
`kanae.file`. `deploy/docker/init.sh` reads the same path directly. The grant list exists once.

`deploy/kubernetes/src/templates/valkey.yml:69` passes the file and mounts it:

```yaml
args: ["valkey-server", "--aclfile", "/run/secrets/users.acl", "--protected-mode", "no",
       "--maxmemory", "{{ .Values.valkey.maxmemory }}", "--maxmemory-policy", "volatile-ttl"]
```

The mount is a projected volume at `/run/secrets` with `defaultMode: 0440`, matching what
`postgres.yml` does for its own credentials. The `valkey-acl` Secret carries
`kapp.k14s.io/delete-strategy: "orphan"` and no versioning annotation, because the chart has no
versioned-resource strategy to match.

`.github/workflows/kubernetes.yml:42` adds `docker/valkey/**` to the path filter, so editing the ACL
triggers the Kubernetes job.

### The Compose stacks

`deploy/docker/` is the deployment stack, so it gets the same ACL. `init.sh` generates
`VALKEY_PASSWORD` alongside the other secrets, then writes two derived things on every run:

```bash
VALKEY_URI="valkey://kanae:${VALUES[VALKEY_PASSWORD]}@valkey:6379/" \
	run_yq -i '.kanae.limiter.storage_uri = strenv(VALKEY_URI)'

[[ -f $ACL_DIST_FILE ]] || abort "no ACL to render from: $ACL_DIST_FILE"
sed "s/resetpass/>${VALUES[VALKEY_PASSWORD]}/" "$ACL_DIST_FILE" >"$ACL_FILE"
chmod 644 "$ACL_FILE"
```

The URI carries the password, so `init.sh` rewrites it on every run rather than storing it. The
assignment sits in front of the command instead of in an `export`, and it still reaches the
`--env VALKEY_URI` that `run_yq` passes to `docker run` at `init.sh:79`.

`ACL_FILE` is `deploy/docker/.valkey.acl`, gitignored at `.gitignore:189`. The dot matches
`.deploy.env`, the other file `init.sh` renders. The name differs from its source on purpose, because
two files named `users.acl` in one repository make every grep ambiguous.

The `sed` is safe only because `openssl rand -hex` emits `[0-9a-f]` and nothing else. No character in
a generated password can close the expression or back-reference the match. A different generator
breaks that property.

Mode 644 is deliberate and it is a real cost. Valkey reads the file as uid 999 through a bind mount,
and a mode the container cannot read crash-loops it. On a shared host, every local user can read the
password. `init.sh:102` and `:123` already accept the same trade for `config.yml`.

The Valkey service in `deploy/docker/docker-compose.yml` loses its published port and gains the file:

```yaml
command: >
  valkey-server --aclfile /run/secrets/users.acl --protected-mode no
  --maxmemory 256mb --maxmemory-policy volatile-ttl
volumes:
  - ./.valkey.acl:/run/secrets/users.acl:ro
```

Keep every argument in that folded string free of `#` and `>`. Compose splits a folded scalar the way
a shell does, so a `#` drops the rest of the command without an error. The list form does not split.

Run `init.sh` before `docker compose up`. Docker creates an empty directory at a missing bind source,
and Valkey then dies on a file-open error that does not mention `init.sh`.

The three development stacks (`docker/docker-compose.yml`, `docker/docker-compose.dev.yml`, and
`docker/docker-compose.test.yml`) get no ACL. They bind `127.0.0.1:6379:6379` instead, which is what
the `database` service in each of those files already did. They hold throwaway data on a developer
machine, so the port was the whole exposure.

### What is missing

- `--save ''`, `--maxclients`, and `--maxmemory-clients`. RDB snapshotting is still on and both
  client caps are still at their defaults. Nothing from "Hardening that is not about authentication"
  landed.
- The `checksum/acl` annotation on the pod template. Rotating `valkeyPassword` updates the Secret in
  place and leaves the running Valkey holding the old password, which is the failure "The ACL file
  has to survive a password change" describes. Close this one first.
- `valkey:6379` in the hardcoded-address rule at `check-policy.sh:15`. `kanae.valkeyUri` reads
  `.Values.serviceNames.valkey`, so no template violates the rule today. Nothing stops the next one.
- Rotating with `deploy/docker/init.sh -r` writes a new password into the ACL file and the config,
  then leaves the container running with the old one. Kanae gets `WRONGPASS` until you recreate the
  stack, and the script does not say so.
- A run of the integration suite with `.kanae.limiter.enabled = true`
  (`tests/integration/init.sh:81`).

## What is still open

Authentication does not close the pre-authentication surface. Three of the ten advisories Valkey has
published are reachable before `AUTH`: GHSA-fq2f-crmw-q97r (unauthenticated use-after-free of the Lua
interpreter state), GHSA-93p9-5vc7-8wgr, which is CVE-2026-27623 (pre-authentication denial of
service from a malformed RESP request, 9.0.0 through 9.0.2, fixed in 9.0.3), and
GHSA-24vm-hv6g-2mj5, which is CVE-2025-21605. Our build is affected by none of the three. The class
keeps recurring, and an ACL does not touch it.

What closes that class is not being able to reach the port. That is a NetworkPolicy, and deferring it
to phase 8 on the strength of a kubescape exception named `network-posture-lands-in-phase-8` is
circular reasoning: the exception is an artifact somebody wrote, not a reason. The honest position is
that a Valkey-scoped policy, one `podSelector` on `app: valkey` and one ingress rule from
`app: kanae` on 6379, is smaller than the ACL machinery in this plan and helps against the threat
this plan says is live. Either ship it here or write down a real blocker, such as the CNI not
enforcing policy yet.

`default` can still `PING` from anywhere in the namespace, so Valkey remains a liveness oracle. That
is the price of a probe with no credential, and it is a fair one.

"What is missing" lists the rest of what is open. Close the password rotation gap first, because it
turns a routine rotation into an outage.

## Deliberate omissions

**No TLS.** Traffic stays inside the cluster, which is the reasoning the Postgres plan used, and the
cost is a CA, a certificate, a rotation story, and a mount. There is a second reason here.
CVE-2026-56684 is a use-after-free in `connTLSClose` that exists only when a TLS listener is running.
Turning TLS on in a namespace with no eavesdropper adds a remote-code-execution path that plaintext
does not have. Our 9.1.2 has the fix, so this is a note rather than a blocker: TLS here is not free
in the direction people assume.

**No `timeout`.** `timeout 0` means Valkey never drops idle clients. `--timeout 300` would close
them, but the Glide client holds one long-lived connection per process. Trading a reconnect storm for
a limit on idle sockets is a bad deal in a namespace where every client is ours.

**No second read-only user.** Kanae reads and writes through one `GlideClient`. Splitting it means
two clients and a decision at every call site, which is application work with no isolation to show
for it while there is one consumer.

**No image bump.** I checked, expecting to find one. The pinned digest `sha256:ccfa19b0...` is
`VALKEY_VERSION=9.1.2` on alpine-minirootfs-3.24.1, built 2026-09-03. The current `9-alpine` is
`sha256:a0dbf4c1...`, also 9.1.2 on alpine-minirootfs-3.24.1, built 2026-09-07. Same binary, an apk
set four days newer. Nothing here is worth a commit.

## Is this more machinery than the problem needs

Partly, and the honest answer got worse after the review.

Six of the seven attacks in the threat list die the moment `default` loses `+@all`. That is one line
in one file. The per-command list, the key patterns, the `key_prefix` change, and the `SCAN` decision
are a second layer that pays off only if the kanae pod itself is compromised, and the kanae pod is
phase 7.

I would still write the second layer now, for one reason. Deriving the grant list is cheap while
there are four consumers and two files of storage code. It gets expensive once there are twelve call
sites and somebody has to reconstruct it from production `NOPERM` entries. The key patterns are the
same argument: `~ory:*` is free to add before the keys exist and awkward to add after.

What the review changed is my confidence in the derivation, not in the design. The first draft's
grant list was wrong in four independent ways, and every one of them came from reading files instead
of following connections. The list above is smaller, better sourced, and now measured: a real
`GlideClient` runs the limiter and cache paths against this exact ACL file with an empty `ACL LOG`.

## Evidence

- Probe safety: `src/valkey-cli.c` at 9.1 contains no `CLIENT SETINFO`. `cliInitHelp()` is guarded by
  `isatty(fileno(stdin))` at line 3313, and the only other call sites are `testHint` and
  `testHintSuite`.
- Protected mode: `clientAcceptHandler` in `src/networking.c:1827`, quoted above. Compiled default in
  `src/config.c:3272`. Image entrypoint adds only `$VALKEY_EXTRA_FLAGS`. Measured `no` on the pinned
  image, with the `sed` in `valkey-container`'s Dockerfile as the cause and `modified=1` in the
  startup banner as corroboration.
- Glide handshake and script path: `MONITOR` on a 9-alpine server while valkey-glide 2.5.2, the
  pinned version, connects and runs the limiter path. Traces quoted above.
- Limiter strategy: `FixedWindowRateLimiter` in
  `.venv/lib/python3.15/site-packages/limits/aio/strategies.py` calls `storage.incr`, `storage.get`,
  and `storage.get_expiry`, and nothing else.
- Defaults in `valkey.conf` at 9.1: `protected-mode yes` (112), `enable-protected-configs no`,
  `enable-debug-command no`, `enable-module-command no` (133 to 135), `timeout 0` (171),
  `save 3600 1 300 100 60 10000` (575), `client-output-buffer-limit normal 0 0 0` (2449),
  `maxmemory-clients 0` (2481).
- Image identity: registry config blob
  `sha256:793f59d5064974d427d0e5604875cc932642d68b49f832bedf615bb55282e9fa` carries
  `VALKEY_VERSION=9.1.2`.
- URI parsing: run against the installed `limits`, output quoted above.
- Scanner output: `kubescape scan framework all` over the two rendered Valkey manifests. Seven
  failures, all seven already excepted.
- ACL behaviour: the three-user file below, loaded with `--aclfile` on the pinned image. `ACL LIST`
  returns all three users. `default` answers `PING` and refuses `CONFIG GET`, `FLUSHALL`, and `GET`.
  `kanae` runs every granted verb, is refused `other:x` with `PermissionDenied: No permissions to
  access a key`, and is refused `scan` by command. Grants withheld one at a time confirm each is
  reachable: no `+info` is a fatal `ClosingError`, no `+script|load` is a failed `invoke_script`, no
  `+client|setinfo` is two silent `ACL LOG` entries.
- Argument parsing: `--save ''` in the args yields an empty `CONFIG GET save`. `--maxclients 128` and
  `--maxmemory-clients 32mb` read back as `128` and `33554432`.
- `resetchannels`: the server writes it into `ACL LIST` output on its own, which confirms the token
  was a no-op in the file.

## What was not proven, and now is

All five open items ran against Valkey 9.1.2 in Docker, on the pinned image, with the ACL file and
arguments this plan proposes. Four changed something in the text above.

1. **Does protected mode reject remote clients today?** No. `PING` from another container answers
   `PONG`, and `CONFIG GET protected-mode` returns `no`. The threat model holds, and the reasoning
   for `--protected-mode no` changed: nothing forces it, the image already sets it, and passing it
   removes a dependency on an upstream `sed`.
2. **Does the Glide connect sequence need more than `+client|setinfo` and `+info`?** No, and the two
   are not equal. `INFO REPLICATION` is fatal if denied; `CLIENT SETINFO` is ignored. There is no
   `SELECT`, because the URI carries no database.
3. **Does `--save ''` as an argv element parse like `save ""` in a file?** Yes. `CONFIG GET save`
   returns empty.
4. **Is `+script|load` the right grant?** Yes. Glide sends `EVALSHA`, takes `NOSCRIPT`, sends
   `SCRIPT LOAD`, and retries. Without the grant, every `invoke_script` fails.
5. **Does the ACL file load?** Yes. Clean startup, three users in `ACL LIST`, `default` correctly
   fenced to `PING`.

The chart properties then ran on k3d, against the templates that shipped. `kapp deploy` reported 26
of 26 resources succeeded and the Valkey pod went Ready. The Secret renders each directive on one
physical line, and the projection mounts as a directory the read-only root filesystem accepts. In
the cluster, `default` gets `NOPERM` on `FLUSHDB` and `PONG` on `PING`, `kanae` reads and writes its
three namespaces, `GET RATELIMIT:probe` returns `1`, `kanae` is refused `FLUSHDB` and every
out-of-namespace key, and a wrong password gets `WRONGPASS`. Every gate passes: `helm lint` with 0
failures, `kubeconform` over 15 of 15 files, `kube-linter`, `check-symlinks`, and `kubescape` across
137 controls.

The Compose stack ran the same way. `docker compose up valkey` reports `running health=healthy`,
`docker port kanae_valkey` prints nothing, and `docker inspect` shows `Cmd` split into separate
arguments with no element carrying a space. The same ACL checks pass inside the container. Three runs
of `deploy/docker/init.sh` against a scratch directory kept the password across runs, rotated it
under `-r`, and left `.deploy.env`, `.valkey.acl`, and `kanae.limiter.storage_uri` carrying the same
64 hex characters.

The `checksum/` annotation is still unproven because it was never added. See "What is missing".

The integration suite also still needs a pass with `.kanae.limiter.enabled = true`
(`tests/integration/init.sh:81`). The limiter path above was exercised by hand, not by the suite.
