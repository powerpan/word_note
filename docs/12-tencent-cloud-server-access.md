# Tencent Cloud Server Access

## Purpose

Word Note uses a project-local SSH key and wrapper script to access its Tencent Cloud server. The login flow is self-contained in this repository checkout and has no external project dependency.

## Connection details

- Public IP: `134.175.182.221`
- SSH user: `ubuntu`
- Private key: `.local_secrets/ssh/word_note_tencent_cloud_ed25519`
- Project-local host key store: `.local_secrets/ssh/known_hosts`
- Login script: `script/tencent_cloud_ssh.sh`

The entire `.local_secrets/` directory is ignored by Git. The private key must retain owner-only permissions (`600`) and must never be committed.

## Interactive login

From the project root:

```bash
./script/tencent_cloud_ssh.sh
```

The script resolves the repository root from its own location, so it can also be called from any working directory:

```bash
/Users/ericpan/game_project/word_note/script/tencent_cloud_ssh.sh
```

## Run a remote command

Pass the remote command and its arguments after the script path:

```bash
./script/tencent_cloud_ssh.sh systemctl is-active classbridge-gateway
```

For shell expressions such as pipes or redirects, pass the full remote command as one quoted argument:

```bash
./script/tencent_cloud_ssh.sh 'systemctl status classbridge-gateway --no-pager | head'
```

## Direct SSH fallback

If the wrapper script is unavailable, use the Word Note key directly:

```bash
ssh \
  -i /Users/ericpan/game_project/word_note/.local_secrets/ssh/word_note_tencent_cloud_ed25519 \
  -o IdentitiesOnly=yes \
  ubuntu@134.175.182.221
```

Always use the Word Note key path above so the login flow remains project-local.
