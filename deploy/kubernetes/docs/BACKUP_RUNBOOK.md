# Back up and restore kanae

This runbook covers setting up the backup repository once, then backing up, testing, and restoring the `kanae`, `kratos`, and `keto` databases.

Run every command from the root of the repo, in a shell with mise activated.

## Before you start

You need:

- kubectl pointed at the production cluster, with the `kanae` namespace created. Check it with `kubectl config current-context`.
- A BorgBase account.
- A local copy of this repo with `mise install` done, plus Docker.
- Your age key at `~/.config/sops/age/keys.txt`, listed in `.sops.yaml`.

## Check the node

Do this once, and again every time the node is replaced.

```sh
kubectl -n kanae run uid-map --rm -i --restart=Never \
	--image=ghcr.io/borgmatic-collective/borgmatic:2.1.10@sha256:25a97d84a2371c385c0031a02b64f7167de85631a85b84ef46dc01a80010d19e \
	--overrides='{"apiVersion":"v1","spec":{"hostUsers":false}}' \
	--command -- cat /proc/self/uid_map
```

The output is `0`, then a number other than `0`, then `65536`, such as `0 2419720192 65536`. If it prints `0 0 4294967295`, stop. The node ignores `hostUsers`, and the backups can't run on it.

## Set up the backup repository

Do these steps once, before the first `mise run k8s:apply`. The first deploy takes a backup before the migrations run.

1. Generate the backup passphrase and SSH key:

   ```sh
   deploy/kubernetes/init.sh
   ```

   It asks for every value that `secrets.sops.yml` doesn't have yet. Press enter at **BorgBase Repository URL** and **BorgBase Host Key**.

   The last line is `==> wrote .../deploy/kubernetes/secrets.sops.yml`.

2. Print the public SSH key:

   ```sh
   sops decrypt --extract '["secrets"]["borgSshKey"]' deploy/kubernetes/secrets.sops.yml | ssh-keygen -y -f /dev/stdin
   ```

   In BorgBase, add the `ssh-ed25519 AAAA...` line under **Account > SSH Keys**.

3. In BorgBase, create a repository and give the key from step 2 **Full Access**. Copy its URL from the **Name** column: `ssh://<id>@<id>.repo.borgbase.com/./repo`.

4. Create the Borg repository:

   ```sh
   deploy/kubernetes/scripts/borg.sh
   ```

   Paste the URL at **BorgBase Repository URL**. It prints the host key fingerprint. In BorgBase, hover over the fingerprint icon next to the repository. Confirm only if the two match.

   It ends by printing the repository key. Store it with the break-glass age key, outside the cluster and off any one officer's laptop.

5. Commit `deploy/kubernetes/secrets.sops.yml`, open a pull request, and merge it.

## Check the first backup

Do these steps once, after the first `mise run k8s:apply`.

1. List the archives with `deploy/kubernetes/scripts/borg.sh list --short`. It shows one `kanae-db-snapshot-...` archive.

2. Do [Test a backup](#test-a-backup).

## Everyday tasks

### Back up the database

The `kanae-backup` CronJob backs up the `kanae`, `kratos`, and `keto` databases to BorgBase every day at 10:47 UTC. Each run keeps 7 daily and 4 weekly archives and deletes the rest. Every deploy that runs a migration takes a `kanae-db-snapshot-...` archive first.

- See the last runs: `kubectl -n kanae get jobs -l app=kanae-backup`
- Read a run's output: `kubectl -n kanae logs job/<name>`
- List the archives: `deploy/kubernetes/scripts/borg.sh list --short`
- Back up now:

  ```sh
  job=backup-$(date +%s)
  kubectl -n kanae create job --from=cronjob/kanae-backup "$job"
  kubectl -n kanae wait --for=condition=complete "job/$job" --timeout=600s
  ```

Nothing alerts on a failed run. Check the last runs once a week.

### Test a backup

Do this once a month, and after any change to the backups.

1. Back up now. See [Back up the database](#back-up-the-database).

2. Restore the backup next to the live databases and compare them:

   ```sh
   deploy/kubernetes/scripts/restore.sh --check
   ```

   It prints `<database>: the live database matches the backup` for `kanae`, `kratos`, and `keto`.

3. Drop the copies:

   ```sh
   kubectl -n kanae exec statefulset/database -c postgres -- psql -U postgres \
   	-c 'DROP DATABASE restore_kanae' -c 'DROP DATABASE restore_kratos' -c 'DROP DATABASE restore_keto'
   ```

### Restore the database

1. Restore from the newest archive:

   ```sh
   deploy/kubernetes/scripts/restore.sh
   ```

   To restore from an older archive, copy its name from `deploy/kubernetes/scripts/borg.sh list --short` and run `restore.sh --archive <name>`. To restore one database, add `--database kanae`, `kratos`, or `keto`.

   It asks before it changes anything. It stops kanae, Kratos, and Keto, takes a `kanae-db-pre-restore-...` archive, restores, then starts them again. It prints `success: ...` when it's done.

2. Check that the services are back:

   ```sh
   kubectl -n kanae get pods
   curl -fsS -o /dev/null -w '%{http_code}\n' https://api.ucmacm.dev/
   ```

   Every pod shows `Running` and is ready, except the Job pods, which show `Completed`. `curl` prints `200`.

3. Drop each old database that `restore.sh` printed:

   ```sh
   kubectl -n kanae exec statefulset/database -c postgres -- psql -U postgres \
   	-c 'DROP DATABASE <database>_before_restore_<stamp>'
   ```

### Change a backup secret

1. Replace the value:

   - `borgRepo` or `borgKnownHosts`: do step 4 of [Set up the backup repository](#set-up-the-backup-repository).
   - `borgSshKey`: delete the `borgSshKey` line, then generate a new key:

     ```sh
     sops edit deploy/kubernetes/secrets.sops.yml
     deploy/kubernetes/init.sh
     ```

     Do step 2 of [Set up the backup repository](#set-up-the-backup-repository). Edit the repository and give the new key **Full Access**.

2. Commit `deploy/kubernetes/secrets.sops.yml`. Open a pull request and merge it.

3. Deploy:

   ```sh
   git pull
   mise run k8s:apply
   ```

   The next backup reads the new value.

> [!WARNING]
> Never replace these values:
>
> - `borgPassphrase`. Every backup becomes unreadable.
> - `postgresBackupPassword`. Postgres keeps its own copy, and the backups lose access to the database.

## When something breaks

| Symptom | Fix |
| --- | --- |
| sops can't decrypt `secrets.sops.yml` | Have an officer add your age key to `.sops.yaml` and run `sops updatekeys deploy/kubernetes/secrets.sops.yml`. |
| `error: <tool> is required` | Run `mise install` and activate mise in your shell. Install Docker for `borg.sh`. |
| `kanae-snapshot` fails and the deploy stops | Read `kubectl -n kanae logs -l app.kubernetes.io/component=snapshot`, then find the error below. After the fix, run `mise run k8s:apply` again. |
| A backup Job shows `Failed` | Read `kubectl -n kanae logs job/<name>`, then find the error below. |
| `Repository ... does not exist.` | Do step 4 of [Set up the backup repository](#set-up-the-backup-repository). |
| `Host key verification failed.` | Replace `borgKnownHosts`. See [Change a backup secret](#change-a-backup-secret). |
| `Permission denied (publickey)` | In BorgBase, check that the key from step 2 of [Set up the backup repository](#set-up-the-backup-repository) is under **Account > SSH Keys** and has **Full Access** on the repository. |
| `error: ... is not a BorgBase repository URL` | Copy the URL from the **Name** column in BorgBase and run `borg.sh` again. |
| `error: ... did not return an ed25519 host key` | Check the URL, then run `borg.sh` again. |
| `error: the host key does not match, nothing was saved` | Stop. Check the URL. If it's correct, don't run `borg.sh` again until BorgBase confirms its fingerprint. |
| `Failed to create/acquire the lock` | If `kubectl -n kanae get pods -l app=kanae-backup` shows no `Running` pod, run `deploy/kubernetes/scripts/borg.sh break-lock`. |
| `error: a backup or snapshot is running ...` | Wait until `kubectl -n kanae get pods -l app=kanae-backup` shows no `Running` pod, then run `restore.sh` again. |
| `error: ... is not in the repository` | Copy the archive name from `deploy/kubernetes/scripts/borg.sh list --short`. |
| `error: ... holds no dump of <database>` | Pick another archive from `deploy/kubernetes/scripts/borg.sh list --short`. |
| `error: <database> did not restore, so every database was put back as it was` | Read the `pg_restore` error above it. The services are running again on the old data. |
