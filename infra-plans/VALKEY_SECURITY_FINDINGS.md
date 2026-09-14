# What the adversarial review found in the Valkey ACL plan

Four models reviewed `VALKEY_SECURE_PLAN.md` against the code it claims to derive from. This file
records what they found, what I verified, and what I rejected. The plan itself has been rewritten
against these findings, so read this one for the reasoning and that one for the design.

Reviewers: fable (10 findings), sonnet (4), haiku (9), opus (11). Each got the same prompt, the same
rubric, and read-only access to the repository. They are all Anthropic models, so treat agreement as
good signal rather than as independent confirmation.

Every claim below that I mark verified, I checked myself against the source or the binary. A later
pass re-checked the parts that needed a running server against Valkey 9.1.2 in Docker; that pass
overturned one of my own dismissals, which is noted where it happened. The reviewers were wrong about
three things, and those are at the bottom.

## Act on

### The grant table was wrong in four ways

All four reviewers. Verified.

`ValkeyCache` has four instantiations, not one. `src/utils/ory.py:129`, `:135` and `:141` build
caches under the namespaces `ory:whoami:`, `ory:identity` and `ory:check`. The original key patterns
were `~LIMITS:*` and `~media:get-url:*`, which cover none of them. Every session lookup, identity
fetch and Keto permission check would have gone permanently cold, silently, because
`cached_method.get_from_cache` swallows `GlideError` (`src/utils/cache.py:212-222`).

`OryClient._invalidate_resource` (`src/utils/ory.py:171-173`) calls `_check_cache.clear(namespace=prefix)`,
which takes the `scan` branch in `ValkeyCache._clear` (`src/utils/cache.py:452-459`). It is called
from `grant` (`:571`) and `revoke` (`:650`). The plan said `scan` has "no caller on a request path".
That was false. fable diagnosed the cause exactly: the plan inventoried files, not instantiations.

`ValkeyCache.__multi_set_ttl` uses `transaction.pexpire` for a float TTL (`src/utils/cache.py:406`).
The plan granted `+expire` and not `+pexpire`, in a function it claimed to have read end to end.

The Glide client's own handshake has no Python call site, so reading `storage.py` and `cache.py`
could never reveal it. `strings` on `glide.cpython-315-x86_64-linux-gnu.so` returns `GlidePySETINFO`,
`LIB-NAME`, `ClientSetInfo`, `HELLO` and `Discovered primary at`. The client needs `+client|setinfo`,
and probably `+info` for role discovery.

In the other direction, `KanaeLimiter` hard-codes `FixedWindowRateLimiter` (`src/utils/limiter/extension.py:304`).
That strategy calls only `storage.incr`, `storage.get`, `storage.get_expiry` and `storage.clear`, so
`moving_window.lua`, `acquire_moving_window.lua`, `sliding_window.lua` and `acquire_sliding_window.lua`
never run. The grants `lindex`, `lpush`, `ltrim`, `pttl` and `rename` existed for scripts that no
configuration reaches. About 14 of 23 verbs had no reachable caller, excluded under the same test the
plan used to withhold `keys`.

### The nominated verification could not fail

fable and opus, independently. Verified.

The plan called "run the integration suite and confirm no route returns a 500 from a `NOPERM`" the
check that mattered most. Both consumers are built to hide storage errors:

- `KanaeLimiter._check_request_limit` catches bare `Exception` (`extension.py:555`), sets
  `_storage_dead`, and re-runs against `MemoryStorage`. The response is 200.
- `get_from_cache` and `set_in_cache` catch `GlideError` (`cache.py:212-227`). `NOPERM` is a
  `GlideError`. The response is 200.

The recovery probe cannot see it either. `ValkeyStorage.check()` is `client.ping()`
(`storage.py:268-279`), and `PING` is the one command every user holds under this ACL. The limiter
marks storage dead, pings successfully, marks it recovered, fails the next real command, and
oscillates. That is not a bug in `check()`. Upstream `limits` probes the same way
(`limits/storage/redis.py:295-302`), and a probe that issued a real command would need a key it is
allowed to write, which is a bigger change than the problem justifies. It stays as it is. The
consequence is the point: the loop is silent, so no test can fail on it.

`tests/integration/init.sh:81` sets `.kanae.limiter.enabled = false`, so the suite does not exercise
the limiter at all.

The check that works is `ACL LOG`. It records every denied command, including commands issued inside
Lua and inside the client's own connect sequence. Assert it is empty after a run.

### The threat model and the protected-mode section contradicted each other

opus raised it, fable explained it, and Docker settled it. Both were right about something.

The accept-time check is two terms with no bind test (`src/networking.c:1827`):

```c
if (server.protected_mode && DefaultUser->flags & USER_FLAG_NOPASS) {
    if (connIsLocal(conn) != 1) {
```

The default user is `nopass` today, because `valkey.yml` passes args with no `requirepass` and no
`aclfile`. The compiled default for `protected-mode` is `1` (`src/config.c:3272`), and the image
entrypoint adds nothing but `$VALKEY_EXTRA_FLAGS`. So both of the plan's claims cannot hold:

- If the check rejects remote clients, it rejects them now, and the plan's opening threat list is
  false. No pod in the namespace can reach Valkey today.
- If it does not, `--protected-mode no` changes nothing and the section justifying it is wrong.

Measured: `valkey-cli -h vk1 PING` from a second container answers `PONG`, and `CONFIG GET
protected-mode` returns `no`. The second branch is the true one. The plan's threat list stands, and
the section justifying `--protected-mode no` was wrong and has been rewritten.

The mechanism is the one fable named and I dismissed. `valkey-container`'s Dockerfile runs

```
sed -ri 's!^( *createBoolConfig[(]"protected-mode",.*, *)1( *,.*[)],)$!\10\2!' ./src/config.c
```

before it compiles, under the comment `disable Valkey protected mode [1] as it is unnecessary in
context of Docker`. The startup banner reports `modified=1`. Reading `config.c` from the upstream
tree and the entrypoint from the image was not enough, because the patch sits between the two.

### Nobody could administer or rotate the result

fable and opus. Verified.

No user held `+acl`, so `ACL LOAD` was unrunnable from anywhere, including `kubectl exec`. Valkey
reads `aclfile` once at startup. The plan added no `checksum/` annotation to the pod template, though
`jobs-migrate.yml:69`, `:165` and `:259` establish that pattern in this chart.

Rotating `valkeyPassword` therefore updates the plaintext in `kanae-config`, leaves the running
server on the old hash, and produces `WRONGPASS` on every connection. By the finding above, that
failure is silent.

The plan's own verification block was the evidence for the missing admin user. It grepped pod logs
for `DB saved on disk` because `CONFIG GET save` returns `NOPERM` for everyone.

### Two mechanical errors would have crash-looped the pod

fable, sonnet and opus between them. Both correct.

The ACL snippet spanned three lines with trailing backslashes. `aclfile` has no continuation syntax.
The loader splits on newline and tokenises each line, so a literal `\` reaches `ACLSetUser`, the load
fails, and the server aborts at startup.

"Mounted read-only at `/etc/valkey/users.acl`" describes a file path. A Secret volume mounted at a
file path creates a directory unless you set `subPath`, and `subPath` mounts do not receive updates.
The precedent the plan cited does the opposite of what the plan described: `postgres.yml:206-210`
mounts the `/run/secrets` directory and lets the Secret key become the filename inside it.

## Consider

**`key_prefix` belongs in `config.dist.yml`.** fable and haiku. The plan chose a chart-only override
to keep the compose stack byte-identical. Both reviewers pointed out that this makes the test stack
write a different key space than production, so a green suite says nothing about whether `~LIMITS:*`
matches. The first half of that argument holds and the prescription does not. Setting
`key_prefix: LIMITS` in any config file puts the prefix into the key twice, because the same value is
both the storage prefix and an extra identifier at `extension.py:434-435`, and that breaks
`test_key_style`. `scripts/repro-limiter-key-prefix.py` prints both key spaces. The fix moved into
`storage.py` and `extension.py` instead; see the plan's key_prefix section.

**`maxclients` is the missing knob.** opus. `maxmemory-clients` bounds aggregate client memory and
evicts the largest clients. It does not bound how many connections exist. An attacker who can reach
the port opens connections instead of filling buffers, and none of it needs `AUTH`. One argv element,
same cost as the knob the plan already added.

**The NetworkPolicy deferral leaned on a filename.** opus. The plan cited a kubescape exception named
`network-posture-lands-in-phase-8` as the reason for the schedule, which is circular. A valkey-scoped
policy is smaller than the ACL machinery it defers to.

**`DECISIONS.md` was missing from the file list.** opus. Its existing entry, "Valkey's `maxmemory` is
half its memory limit", states that client buffers count against the container limit and not against
`maxmemory`. Adding `--maxmemory-clients` qualifies that sentence and should edit it.

## Noted

`check-policy.sh:13` rejects `database:5432` and `kanae:8000` typed into a template but not
`valkey:6379` (sonnet). `sanitize-payload`, `resetkeys` and `resetchannels` are no-ops on a freshly
declared user (opus). The plan's "mutually incompatible" quote from the Valkey ACL page is about
config-file users versus an external `aclfile`, not about `requirepass` (opus). The decision to use
`aclfile` is still right, and the reason given after the quote is the real one.

## Dismissed

**Encrypt etcd, restrict RBAC, adopt an external secrets manager** (haiku). Generic advice that does
not follow from this change, and the repository already settled its secrets story. See "Secrets go
through kapp, decrypted in memory" in `deploy/kubernetes/docs/DECISIONS.md`.

**`RENAME` inside Lua could rename keys outside the granted pattern** (haiku). Both keys come from
`ValkeyStorage._prefixed_key`, and the script that calls `rename` never executes under
`FixedWindowRateLimiter`.

**Mirror the ACL into `docker-compose.dev.yml` and `docker-compose.test.yml`** (haiku). A reasonable
idea that widens a Kubernetes change into two other stacks. Worth its own commit if the ACL survives
first contact.

## What the pattern of agreement says

The two findings every model reached independently are the grant table and the untestable acceptance
check. Both trace to one mistake: the plan derived its ACL from files the author chose to read rather
than from the set of things that open a connection.

The reviewers diverged usefully by temperament. sonnet stayed on Helm and Kubernetes mechanics and
found the mount bug. opus attacked the reasoning and found the protected-mode contradiction. fable
traced the call graph hardest, found the `ory.py` instantiations, and was also right about the
protected-mode patch that I dismissed. haiku mostly restated the plan's own "What is not proven"
section, which is what reading the document more closely than the code looks like.

The dismissal is the one worth keeping. fable asserted a mechanism it could not point at a line for,
so I checked the two places that mechanism would live, found nothing, and called it wrong. The patch
was in a third place, the image's build recipe, which neither the upstream source nor the shipped
entrypoint shows. An unsourced claim can still be true, and "I looked where it would be" is only as
good as the list of places.

## One bug that has nothing to do with Valkey

`get_from_cache` catches `GlideError`, `TimeoutError` and pydantic's `ValidationError`
(`src/utils/cache.py:212-220`). `ORJSONSerializer.loads` calls `orjson.loads`, which raises
`orjson.JSONDecodeError` on a malformed value. That is not caught, so a corrupt entry becomes an
uncaught exception on a request path instead of a cache miss.

Reproduced in `scripts/repro-cache-decode.py`, which builds a real `ValkeyCache` behind a real
`@cached_method` and reads one poisoned value per case. Five cases, with the fake confined to what
the client hands back:

| stored value | serializer | outcome |
| --- | --- | --- |
| `b'true'` | ORJSON | returns `True`, method not called |
| `GlideError` | ORJSON | caught, degrades to a miss |
| `b'{not json'` | Pydantic | `ValidationError`, caught, degrades to a miss |
| `b'{not json'` | ORJSON | `orjson.JSONDecodeError` escapes from `cache.py:282` |
| `b'\xff\xfe'` | JsonSerializer | `UnicodeDecodeError` escapes from `cache.py:337` |

The Pydantic caches are safe because `model_validate_json` raises a `ValidationError`, which is in
the except clause. The two ORJSON caches are the media URL cache (`core.py:592-595`) and the Ory
permission-check cache (`ory.py:141-144`). Both exceptions subclass `ValueError`, so one clause
covers both.

What I could not show is a way to reach it from this repo. `orjson.dumps` is the only writer on both
paths and it always emits parseable JSON, so a value that fails to decode has to come from somewhere
else: a client holding `SET` on the key, a hand-run `valkey-cli` against the same database, or a
future serializer swap that leaves old entries in place. The fifth case needs a cache built without
an explicit serializer, and every cache in `src/` passes one.

So it is a real hole with no reachable trigger today. Widening the `except` is one line and it makes
a corrupt entry degrade the way every other fault in that function already does. Worth doing, not
worth blocking on.
