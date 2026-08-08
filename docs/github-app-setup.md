# GitHub App setup

One-time. Produces the three values that go into SSM: the **App ID**, the **installation ID**, and the
**private key PEM**.

Why a GitHub App and not a personal access token: installation tokens expire in one hour, they are scoped
to exactly the repositories you install the App on, and the bot gets its own identity so every
machine-authored commit, PR and comment is visibly `openbuilder-bot`. See
[architecture.md](architecture.md#github-app-instead-of-a-personal-access-token).

This is a **personal** github.com account (`artemkurylo`). Create the App under your user account, not
under an organisation.

## 1. Create the App

1. Go to <https://github.com/settings/apps> — or click your avatar → **Settings** → **Developer settings**
   → **GitHub Apps**.
2. Click **New GitHub App**.
3. **GitHub App name**: `openbuilder-bot`. This must be globally unique across GitHub; if it is taken,
   use `openbuilder-bot-<yourname>`. The name determines the commit author you will see, which will be
   `<app-name>[bot]`.
4. **Homepage URL**: `https://github.com/artemkurylo/openbuilder` (any valid URL is accepted; this field
   is required and cosmetic).
5. **Webhook**: **uncheck "Active"**.

   This system has no webhook endpoint by design. The instance polls `api.github.com` every 60 seconds from
   an instance with zero inbound network rules — no public listener, no TLS certificate, no webhook
   secret to rotate. Leaving the webhook active would just queue undeliverable events. See
   [architecture.md](architecture.md#poll-loop-instead-of-webhooks).

6. Leave **Callback URL**, **Setup URL** and **Post installation** empty. This App never performs a
   user-facing OAuth flow.
7. Under **Where can this GitHub App be installed?** choose **Only on this account**.

## 2. Set the permissions

Still on the create/edit form, expand **Permissions** → **Repository permissions** and set exactly these.
Everything else stays **No access**.

| Permission | Access | Why the agent needs it |
|---|---|---|
| **Contents** | Read and write | clone the target repo, push `openbuilder/work/<slug>`, commit `worklog.md` |
| **Pull requests** | Read and write | `gh pr create`, read the PR body, read review comments and threads, post comment summaries |
| **Issues** | Read and write | labels live on the Issues API — `openbuilder:in-progress`, `:awaiting-review`, `:blocked` etc. are set through it, and so is `gh label create` |
| **Metadata** | Read-only | mandatory; GitHub selects it automatically as soon as you pick any other permission |
| **Workflows** | Read and write | required if a story ever touches `.github/workflows/**`; without it, a push containing a workflow change is rejected outright with a confusing 403 |

**Organization permissions**: none. **Account permissions**: none.

Then click **Create GitHub App**.

## 3. Read the App ID

You land on the App's **General** settings page. Near the top:

```
App ID: 1234567
```

That number is the value for `/openbuilder/github_app_id`. Copy it now.

The page URL is `https://github.com/settings/apps/openbuilder-bot` — bookmark it; you will come back for
the PEM.

## 4. Generate and download the private key

1. On the same **General** page, scroll to **Private keys**.
2. Click **Generate a private key**.
3. Your browser downloads `openbuilder-bot.YYYY-MM-DD.private-key.pem`. GitHub shows it to you exactly
   once — there is no way to re-download it. If you lose it, generate a new one and delete the old.
4. It is an RSA key in PKCS#1 form. Confirm it looks right:

   ```sh
   head -1 ~/Downloads/openbuilder-bot.*.private-key.pem
   # -----BEGIN RSA PRIVATE KEY-----
   ```

   `ob-token` signs the App JWT with `openssl dgst -sha256 -sign` against this file's contents, so the
   PEM must go into SSM byte-for-byte, newlines included.

Keep the file only until step 6 is done, then delete it:

```sh
rm ~/Downloads/openbuilder-bot.*.private-key.pem
```

## 5. Install the App and read the installation ID

1. Left sidebar → **Install App** (or `https://github.com/settings/apps/openbuilder-bot/installations`).
2. Click **Install** next to your account.
3. Choose **Only select repositories** and pick every repo you listed in `repos` in
   `infra/terraform.tfvars`. If your control repo is private, add `artemkurylo/openbuilder` here too so
   `ob-selfupdate` can pull it with an App token.

   Do **not** choose "All repositories". The installation token's write scope is exactly this list, and
   that list is the agent's entire blast radius.
4. Click **Install**.
5. You are redirected to a URL that ends in the installation ID:

   ```
   https://github.com/settings/installations/87654321
                                            ^^^^^^^^
   ```

   That trailing number is the value for `/openbuilder/github_app_installation_id`.

   Missed the redirect? Go back to **Install App**, click the **gear/Configure** button next to your
   account, and read the same number off the address bar. Or ask the API, if you have a `gh` login with
   admin rights on the account:

   ```sh
   gh api /users/artemkurylo/installation --jq .id
   ```

When you add a new repository to `OPENBUILDER_REPOS` later, you must also add it to this installation.
The installation ID does not change.

## 6. Put the values into SSM

`make secrets` prints these with placeholders; here they are in full. Use the same `--region` as
`var.region`, and the same prefix as `var.ssm_prefix` (default `/openbuilder`).

```sh
aws ssm put-parameter --overwrite \
  --name /openbuilder/github_app_id \
  --type String \
  --value '1234567' \
  --region eu-central-1

aws ssm put-parameter --overwrite \
  --name /openbuilder/github_app_installation_id \
  --type String \
  --value '87654321' \
  --region eu-central-1

aws ssm put-parameter --overwrite \
  --name /openbuilder/github_app_private_key \
  --type SecureString \
  --value "$(cat ~/Downloads/openbuilder-bot.2026-08-08.private-key.pem)" \
  --region eu-central-1
```

Notes on that last command, because it is the one that goes wrong:

- `--value "$(cat key.pem)"` with **double quotes** is what preserves the newlines. Single quotes around
  the substitution would prevent it from running at all; leaving it unquoted would collapse the PEM into
  one line and `openssl` would reject it. Never paste the PEM body into your shell by hand.
- Command substitution puts the key in your shell process's argv, which is visible to `ps` on a shared
  machine and lands in your shell history. On a personal laptop that is acceptable; if you care, prefix
  the command with a space (with `HISTCONTROL=ignorespace`) or use
  `--value "$(cat key.pem)" > /dev/null` in a subshell you then exit.
- `--overwrite` is required because Terraform already created the parameter with the placeholder value
  `REPLACE_ME`. Terraform declares these parameters with `lifecycle { ignore_changes = [value] }`, so a
  later `terraform apply` will never overwrite what you just put here.

While you are here, the fourth parameter — the model key, unrelated to the App:

```sh
aws ssm put-parameter --overwrite \
  --name /openbuilder/openrouter_api_key \
  --type SecureString \
  --value 'sk-or-v1-REPLACE_ME' \
  --region eu-central-1
```

Confirm all four exist and none still says `REPLACE_ME`:

```sh
aws ssm get-parameters-by-path --path /openbuilder --recursive \
  --query 'Parameters[].Name' --output table --region eu-central-1
```

That query deliberately does not pass `--with-decryption`, so it prints names only.

## 7. Verify with `ob-doctor`

`ob-doctor` is the only real proof that the App works, because it mints a token on the instance with the
instance role and the SSM values you just set:

```sh
make doctor
```

or equivalently, from anywhere the CLI is on your `PATH`:

```sh
openbuilder doctor
```

or from a shell on the instance itself:

```sh
openbuilder shell
sudo -u openbuilder /opt/openbuilder/bin/ob-doctor
```

The rows that matter here are the ones for each SSM parameter being readable, the App token minting and
`gh api user` succeeding, and each repo in `OPENBUILDER_REPOS` being reachable **and writable**. Any FAIL
exits non-zero.

To see the minted token's identity without printing the token:

```sh
openbuilder shell
sudo -u openbuilder bash -lc 'GH_TOKEN=$(/opt/openbuilder/bin/ob-token) gh api user --jq .login'
# openbuilder-bot[bot]
```

`ob-token` caches the token JSON at `/opt/openbuilder/cache/gh-token.json` (mode 0600) and reuses it
while it is more than five minutes from `expires_at`. If you rotate the PEM, delete that cache file so
the next call mints fresh:

```sh
sudo -u openbuilder rm -f /opt/openbuilder/cache/gh-token.json
```

## Failure modes and what they mean

| Symptom | Cause | Fix |
|---|---|---|
| `ob-doctor` App token row FAILs with 401 `A JWT could not be decoded` | wrong App ID, or the PEM in SSM is mangled (newlines lost) | re-put the PEM with `--value "$(cat key.pem)"`, delete the token cache |
| 404 from `/app/installations/<id>/access_tokens` | wrong installation ID — you used the App ID by mistake | re-read the number from the `settings/installations/<id>` URL |
| Token mints, but a repo row FAILs "not writable" | the App is installed but that repo is not in the selected list | **Install App** → Configure → add the repo |
| `git push` from the instance fails 403 on a story that touches `.github/workflows/` | Workflows permission missing | add Workflows: Read and write, then accept the permission request under **Install App** → Configure |
| Everything worked yesterday, 401 today | nothing expires that you own — the *cached* token expired and something is reusing it wrongly | delete `/opt/openbuilder/cache/gh-token.json`, re-run `ob-doctor` |
| You changed permissions and nothing took effect | permission changes on an installed App require approval | go to **Install App** → Configure and accept the pending request |
