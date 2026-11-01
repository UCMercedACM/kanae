# Run kanae in production

This runbook covers setting up a new cluster, deploying, rolling back, rotating secrets, and handing the keys to new officers. For backups and restores, see [BACKUP_RUNBOOK.md](BACKUP_RUNBOOK.md).

Run every command from the root of the repo, in a shell with mise activated.

## Before you start

You need:

- kubectl pointed at the production cluster. Check it with `kubectl config current-context`.
- A local copy of this repo with `mise install` done.
- Your age key at `~/.config/sops/age/keys.txt`, listed in `.sops.yaml`. To get one, see [Add an officer](#add-an-officer).

## Set up a new cluster

Do these steps once, in order, on an empty cluster.

1. Create the storage class and the namespace:

   ```sh
   kubectl apply -f deploy/kubernetes/storage.yml
   kubectl create namespace kanae
   ```

2. Install Envoy Gateway and cert-manager, then the GatewayClass:

   ```sh
   helmfile -f deploy/kubernetes/helmfile.yaml sync -l tier=controllers
   kubectl apply -f deploy/kubernetes/envoy.yml -f deploy/kubernetes/gateway.yml
   ```

3. Do [Check the node](BACKUP_RUNBOOK.md#check-the-node).

4. Do [Set up the backup repository](BACKUP_RUNBOOK.md#set-up-the-backup-repository). At step 1, `init.sh` also asks for:

   - **SMTP URI**: the mail relay, as `smtps://user:pass@host:465`.
   - **S3 Access Key ID** and **S3 Secret Key ID**: the storage bucket's API key.

5. Deploy:

   ```sh
   git checkout main
   git pull
   mise run k8s:apply
   ```

   The last line is `Succeeded`.

6. Print the Gateway's address:

   ```sh
   kubectl -n kanae get gateway kanae
   ```

   Point an `A` record for `api.ucmacm.dev` at the `ADDRESS`.

7. Wait for the certificate:

   ```sh
   kubectl -n kanae wait --for=condition=Ready certificate/kanae-tls --timeout=30m
   ```

8. Check the API:

   ```sh
   curl -fsS -o /dev/null -w '%{http_code}\n' https://api.ucmacm.dev/
   ```

   It prints `200`.

9. Do [Check the first backup](BACKUP_RUNBOOK.md#check-the-first-backup).

> [!WARNING]
> Never replace `kratosSecretsCipher`. Every account becomes unreadable.

## Deploy a change

1. Merge the pull request.

2. Deploy:

   ```sh
   git checkout main
   git pull
   mise run k8s:apply
   ```

   kapp prints the diff and applies it without asking. The last line is `Succeeded`.

3. Check the services:

   ```sh
   kubectl -n kanae get pods
   curl -fsS -o /dev/null -w '%{http_code}\n' https://api.ucmacm.dev/
   ```

   Every pod shows `Running` and is ready, except the Job pods, which show `Completed`. `curl` prints `200`.

Deploy only with `mise run k8s:apply`. Never run `kapp deploy` by hand.

## Roll back a release

1. Revert the commit on a new branch:

   ```sh
   git checkout -b revert-<commit>
   git revert <commit>
   ```

2. Push the branch, open a pull request, and merge it.

3. Do [Deploy a change](#deploy-a-change).

> [!WARNING]
> If the commit changed `src/schema.sql`, the revert migrates the database again. A column the commit added is dropped with its data. A column the commit dropped comes back empty. To get its data back, see [Restore the database](BACKUP_RUNBOOK.md#restore-the-database) and pick the `kanae-db-snapshot-...` archive from before the deploy.

## Rotate a secret

### Find what the value needs

| Value                              | `ALTER ROLE`       | Restart                |
| ---------------------------------- | ------------------ | ---------------------- |
| `kanaePassword`                    | `kanae`            | `kanae`                |
| `kratosPassword`                   | `kratos`           | `kratos`               |
| `ketoPassword`                     | `keto`             | `keto`                 |
| `kanaeMigratePassword`             | `kanae_migrate`    | nothing                |
| `kratosMigratePassword`            | `kratos_migrate`   | nothing                |
| `ketoMigratePassword`              | `keto_migrate`     | nothing                |
| `postgresMonitorPassword`          | `postgres_monitor` | nothing                |
| `postgresBackupPassword`           | `kanae_backup`     | nothing                |
| `valkeyPassword`                   | none               | `valkey`, then `kanae` |
| `kratosWebhookMasterKey`           | none               | `kratos` and `kanae`   |
| `kratosSecretsCookie`              | none               | `kratos`               |
| `kratosSmtpUri`                    | none               | `kratos`               |
| `storageKeyId`, `storageSecretKey` | none               | `kanae`                |

Rotating `kratosSecretsCookie` signs everyone out. For `borgRepo`, `borgKnownHosts`, and `borgSshKey`, see [Change a backup secret](BACKUP_RUNBOOK.md#change-a-backup-secret).

> [!WARNING]
> Never rotate these values:
>
> - `kratosSecretsCipher`. Every account becomes unreadable.
> - `borgPassphrase`. Every backup becomes unreadable.
> - `dbPassword`. Nothing reads it after the database first starts.

### Rotate a value

1. Create a branch:

   ```sh
   git checkout -b rotate-<value>
   ```

2. Replace the value:

   - `kratosSmtpUri`, `storageKeyId`, or `storageSecretKey`: create the new credential at the provider first. Then run `deploy/kubernetes/init.sh --ask-all`, type the new value at its prompt, and press enter at every other prompt.
   - Any other value: remove it, then generate a new one:

     ```sh
     sops unset deploy/kubernetes/secrets.sops.yml '["secrets"]["<value>"]'
     deploy/kubernetes/init.sh
     ```

   The last line is `==> wrote .../deploy/kubernetes/secrets.sops.yml`.

3. Commit `deploy/kubernetes/secrets.sops.yml`, push the branch, open a pull request, and merge it.

4. Deploy:

   ```sh
   git checkout main
   git pull
   mise run k8s:apply
   ```

   kapp updates the Secrets. No pod restarts yet.

5. If the value has a role in the table, set the role's password. Replace `<value>` and `<role>`:

   ```sh
   password=$(sops decrypt --extract '["secrets"]["<value>"]' deploy/kubernetes/secrets.sops.yml) \
   	&& printf "ALTER ROLE <role> PASSWORD '%s';\n" "$password" \
   	| kubectl -n kanae exec -i statefulset/database -c postgres -- psql -U postgres -v ON_ERROR_STOP=1
   ```

   It prints `ALTER ROLE`.

6. Restart each pod in the table, in order. For each one, replace `<app>`:

   ```sh
   kubectl -n kanae delete pod -l app=<app>
   kubectl -n kanae wait --for=condition=Ready pod -l app=<app> --timeout=120s
   ```

   It prints `condition met`.

7. Check the services. See step 3 of [Deploy a change](#deploy-a-change).

8. If you replaced a provider credential, delete the old one at the provider.

> [!WARNING]
> Restart with `kubectl delete pod`, never `kubectl rollout restart`. kapp undoes `rollout restart` on the next deploy and restarts the pod again.

### Rotate a leaked value

Do [Rotate a value](#rotate-a-value), but deploy before the pull request merges:

1. Do steps 1 and 2.
2. Commit `deploy/kubernetes/secrets.sops.yml`, and push the branch.
3. Run `mise run k8s:apply` from the branch.
4. Do steps 5 to 8.
5. Open a pull request and merge it.

## Hand over the keys

### Add an officer

1. The new officer creates a key and sets a passphrase for it:

   ```sh
   mkdir -p ~/.config/sops/age
   age-keygen | age -p -o ~/.config/sops/age/keys.txt
   ```

   It prints `Public key: age1...`. The officer sends that line to an officer who already has a key.

2. The existing officer adds the key to `.sops.yaml`, under `keys` and under `age`:

   ```yaml
   keys:
     - &noelle age1...
     - &<name> age1...

   creation_rules:
     - path_regex: '\.sops\.yml$'
       key_groups:
         - age:
             - *noelle
             - *<name>
   ```

3. The existing officer re-encrypts the file to the new list:

   ```sh
   sops updatekeys deploy/kubernetes/secrets.sops.yml
   ```

   It shows the added key and asks to confirm. Press `y`. It prints `File ... synced with new keys`.

4. Commit `.sops.yaml` and `deploy/kubernetes/secrets.sops.yml`, open a pull request, and merge it.

5. The new officer checks their key:

   ```sh
   git checkout main
   git pull
   sops decrypt deploy/kubernetes/secrets.sops.yml >/dev/null && echo ok
   ```

   It prints `ok`.

### Remove an officer

1. Delete the officer's two lines from `.sops.yaml`.

2. Re-encrypt the file to the new list:

   ```sh
   sops updatekeys deploy/kubernetes/secrets.sops.yml
   ```

   It shows the removed key and asks to confirm. Press `y`.

3. Commit `.sops.yaml` and `deploy/kubernetes/secrets.sops.yml`, open a pull request, and merge it.

The removed key still decrypts every older commit of `secrets.sops.yml`. To lock the officer out, also rotate every value. See [Rotate a secret](#rotate-a-secret).

### Create the break-glass key

Do this once.

1. Create the key and set a passphrase for it:

   ```sh
   age-keygen | age -p -o break-glass.age
   ```

   It prints `Public key: age1...`.

2. Do steps 2 to 4 of [Add an officer](#add-an-officer), with the name `breakglass` and the public key from step 1.

3. Store `break-glass.age` and its passphrase in two separate places, outside the cluster and off any officer's laptop. Store the Borg repository key from [Set up the backup repository](BACKUP_RUNBOOK.md#set-up-the-backup-repository) with them.

4. Delete `break-glass.age` from your machine.

### Use the break-glass key

Do this only when no officer has a working key.

1. Unwrap the key. It asks for the passphrase:

   ```sh
   age -d -o break-glass.txt break-glass.age
   ```

2. Create your own key. See step 1 of [Add an officer](#add-an-officer).

3. Add your key to `.sops.yaml` and remove the keys of officers who have left. Then re-encrypt with the break-glass key:

   ```sh
   SOPS_AGE_KEY_FILE=break-glass.txt sops updatekeys deploy/kubernetes/secrets.sops.yml
   ```

4. Delete `break-glass.txt`.

5. Commit `.sops.yaml` and `deploy/kubernetes/secrets.sops.yml`, open a pull request, and merge it.

## When something breaks

| Symptom                                                                                                    | Fix                                                                                                                                                                                                                                                                                                 |
| ---------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apply: no age key at ...`                                                                                 | Put your age key at `~/.config/sops/age/keys.txt`, or run `SOPS_AGE_KEY_FILE=<path> mise run k8s:apply`.                                                                                                                                                                                            |
| sops can't decrypt `secrets.sops.yml`                                                                      | Have an officer add your key. See [Add an officer](#add-an-officer).                                                                                                                                                                                                                                |
| `Error: execution error at (kanae/templates/secrets.yml:4:10): secrets.<value> is required`                | Run `deploy/kubernetes/init.sh`. For a `borg*` value, see [Change a backup secret](BACKUP_RUNBOOK.md#change-a-backup-secret).                                                                                                                                                                       |
| `at '/secrets/<value>': ... does not match pattern ...`                                                    | Replace the value. See [Rotate a value](#rotate-a-value).                                                                                                                                                                                                                                           |
| `kapp: Error: Expected to find kind 'gateway.networking.k8s.io/v1/Gateway', but did not`                   | Do step 2 of [Set up a new cluster](#set-up-a-new-cluster), then run `mise run k8s:apply` again.                                                                                                                                                                                                    |
| `kapp: Error: Ownership errors:` ... `is already associated with a different app '<app>'`                  | Something was deployed as `<app>` instead of `kanae`. List what it owns with `kapp inspect -a <app> -n kanae`. Delete it with `kapp delete -a <app> -n kanae`, then run `mise run k8s:apply`. The Postgres claim and the Secrets stay, and `kanae` takes them over.                                 |
| `kapp: Error: waiting on reconcile job/<job>-ver-<n>` ... `BackoffLimitExceeded`                           | Read `kubectl -n kanae logs job/<job>-ver-<n>` and fix the cause. If the fix changed nothing in the repo, run `kubectl -n kanae delete job <job>-ver-<n>`. Then run `mise run k8s:apply` again. For `kanae-snapshot`, see [BACKUP_RUNBOOK.md](BACKUP_RUNBOOK.md#when-something-breaks).             |
| kapp stays on `waiting on <n> changes`                                                                     | In another terminal, run `kubectl -n kanae get pods`. Find the pod that isn't ready, then find its error in this table. kapp gives up after 15 minutes.                                                                                                                                             |
| `kubectl -n kanae describe pvc database-data` shows `storageclass.storage.k8s.io "kanae-retain" not found` | Run `kubectl apply -f deploy/kubernetes/storage.yml`.                                                                                                                                                                                                                                               |
| A pod shows `ErrImagePull` or `ImagePullBackOff`                                                           | Copy the image from `kubectl -n kanae describe pod <pod>`. Run `docker --config "$(mktemp -d)" manifest inspect <image>`. If it prints `manifest unknown`, fix the tag in `deploy/kubernetes/src/values.yaml`. If it prints `denied`, check the image name, then make the package public on GitHub. |
| `database-0` shows `Init:Error` or `Init:CrashLoopBackOff`                                                 | Read `kubectl -n kanae logs database-0 -c check-version`. If it prints `... does not exist, but ... does.`, revert the commit that changed `postgres.image.tag` in `deploy/kubernetes/src/values.yaml`. See [Roll back a release](#roll-back-a-release).                                            |
| `chown: .: Operation not permitted` in `kubectl -n kanae logs deployment/valkey`                           | Put `runAsUser: 999` and `runAsGroup: 1000` back in the pod `securityContext` of `deploy/kubernetes/src/templates/valkey.yml`. Run `mise run k8s:render`, then merge and deploy.                                                                                                                    |
| `password authentication failed for user "<role>"`                                                         | Do steps 5 and 6 of [Rotate a value](#rotate-a-value) for that role.                                                                                                                                                                                                                                |
| `[Errno -5] No address associated with hostname` or `no such host`                                         | Run `kubectl -n kanae get services`. If a Service is missing, run `mise run k8s:apply`.                                                                                                                                                                                                             |
| `[Errno -3] Temporary failure in name resolution` or `i/o timeout` on port 53                              | Run `kubectl -n kanae get networkpolicy allow-dns`. If it's missing, run `mise run k8s:apply`. Then check that `kubectl -n kube-system get pods -l k8s-app=kube-dns` shows `Running`.                                                                                                               |
| A pod shows `OOMKilled` in `kubectl -n kanae describe pod <pod>`                                           | Run `mise run k8s:measure`. Raise the container's memory request and limit, set equal, in its template under `deploy/kubernetes/src/templates/`. Run `mise run k8s:render`, then merge and deploy.                                                                                                  |
| `kubectl -n kanae get certificate kanae-tls` shows `READY` `False`                                         | Check that `dig +short api.ucmacm.dev` prints the `ADDRESS` from `kubectl -n kanae get gateway kanae`. Then read `kubectl -n kanae describe challenges`.                                                                                                                                            |
